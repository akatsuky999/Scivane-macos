"""把本地 OCR 组件装进 ~/.scivane/runtime/ocr/。

两条来路，一个出口（`install()`）：

- **migrate**  从旧部署迁移 —— 本机克隆，不联网；
- **download** 从网上装 —— 上游优先，失败或太慢自动换镜像。

共用的纪律：

- 先在旁边的 `ocr.partial-<pid>` 里装齐、校验，**最后**写 runtime.json，
  再整体换上去 —— 装到一半断掉，留下的是 .partial，不是一个看起来完整的组件；
- 有固定内容的文件（模型、版面模型、llama.cpp 压缩包）按组件表里的大小与 sha256 校验，
  Python 依赖按锁文件的哈希装（`--require-hashes`）。**所以换来源不影响完整性** ——
  镜像给错一个字节，校验就不过；
- 下载先落进 `config.DOWNLOADS_DIR`（断点续传的缓存），装成之后才删 ——
  装到一半断了，下次从断点接着下，而不是 2 GB 从头来。
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Callable
from urllib.parse import urlparse

import httpx

from . import config, runtime
from .i18n import ui
from .runtime import COMPONENT, LEGACY, Artifact, Candidate

#: 进度回调：(种类, 载荷)。种类是 step / progress / source / log，路由把它们映射成
#: `sse.RuntimeEvent` —— 事件名是跨语言契约，归 sse.py 管，这一层不知道 SSE 的存在。
Report = Callable[[str, dict], None]

#: 锁文件随代码一起进包（build_backend.sh lock 生成）
OCR_LOCK = Path(__file__).with_name("requirements-ocr.txt")

# 「太慢就换源」：传了这么多秒之后平均速度还低于这个数，就换下一个来源（最后一个来源除外 ——
# 慢总比装不上好）。国内直连 HuggingFace 常见的样子是连得上、每秒几十 KB，
# 光靠超时抓不住它：936 MB 按这个速度要下好几个小时。
SLOW_AFTER_SECONDS = 20.0
SLOW_BYTES_PER_SECOND = 150_000

# 磁盘预估。文件从下载缓存**克隆**进组件（APFS 上不占新块），所以模型只算一份；
# Python 依赖解开之后约 1.1 GB（旧部署 venv 实测），wheel 本身约 270 MB（锁文件实测）。
SITE_ESTIMATE_BYTES = 1_100_000_000
WHEELS_ESTIMATE_BYTES = 270_000_000
DISK_MARGIN_BYTES = 512_000_000


class InstallError(Exception):
    def __init__(self, message: str, code: str) -> None:
        super().__init__(message)
        self.code = code


class Cancelled(InstallError):
    def __init__(self) -> None:
        super().__init__(ui("安装已取消（已下载的部分留在缓存里，下次接着下）",
                            "Install canceled (what's downloaded stays cached; next time it resumes)"),
                         "CANCELLED")


def _quiet(_kind: str, _payload: dict) -> None:
    pass


def install(method: str, dest: Path, *, report: Report = _quiet,
            should_stop: Callable[[], bool] = lambda: False) -> Path:
    """两条来路的唯一出口。"""
    if method == "migrate":
        # 旧部署没有默认位置（config.LEGACY_RUNTIME_DIR）。没设就没有可迁的，
        # 与「设了但不齐」是同一种具名失败 —— 界面只认错误码
        if config.LEGACY_RUNTIME_DIR is None:
            raise InstallError(ui("没有可迁的旧部署（没有设 SCIVANE_LEGACY_RUNTIME_DIR）",
                                  "There's no old deployment to migrate (SCIVANE_LEGACY_RUNTIME_DIR isn't set)"),
                               "LEGACY_INCOMPLETE")
        return migrate_legacy(config.LEGACY_RUNTIME_DIR, dest,
                              log=lambda msg: report("log", {"message": msg}))
    if method == "download":
        return install_download(dest, report=report, should_stop=should_stop)
    raise InstallError(ui(f"不认识的安装方式：{method!r}", f"Unknown install method: {method!r}"),
                       "BAD_METHOD")


def migrate_legacy(source: Path, dest: Path, *, log: Callable[[str], None] = lambda _msg: None) -> Path:
    """把旧布局的部署拷成组件布局。旧部署一个字节都不改（它是「只装不改」的）。"""
    legacy = Candidate("legacy", source, LEGACY)
    problem = legacy.problem()
    if problem is not None:
        raise InstallError(ui(f"旧部署不齐，没法迁：{problem}",
                              f"The old deployment is incomplete, so it can't be migrated: {problem}"),
                           "LEGACY_INCOMPLETE")

    stage = _fresh_stage(dest)
    try:
        target = Candidate("component", stage, COMPONENT)
        for item in runtime.COMPONENTS:
            src, dst = _copy_pair(legacy, target, item)
            log(ui(f"拷贝 {item.label}", f"Copying {item.display_label}"))
            dst.parent.mkdir(parents=True, exist_ok=True)
            _clone(src, dst)
        # 旧部署的版面模型是 paddlex 从 HuggingFace 拉的，带着它的下载缓存；那不是模型的一部分
        shutil.rmtree(target.layout_dir / ".cache", ignore_errors=True)
        verify(target, log=log)
        _write_manifest(stage, source=f"migrated:{source}")
        leftover = target.problem()
        if leftover is not None:
            raise InstallError(ui(f"拷完之后仍然不齐：{leftover}",
                                  f"Still incomplete after copying: {leftover}"), "STAGE_INCOMPLETE")
        _swap_in(stage, dest)
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    log(ui(f"已就位：{dest}", f"In place: {dest}"))
    return dest


def verify(target: Candidate, *, log: Callable[[str], None] = lambda _msg: None) -> None:
    """按组件表逐个核对有固定内容的文件：先比大小（便宜），再比 sha256。"""
    for item in runtime.COMPONENTS:
        base = target.location(item)
        for artifact in item.artifacts:
            path = base / artifact.path if artifact.path else base
            if not path.is_file():
                raise InstallError(ui(f"{item.label} 缺文件：{path}",
                                      f"{item.display_label} is missing a file: {path}"), "ARTIFACT_MISSING")
            size = path.stat().st_size
            if size != artifact.size:
                raise InstallError(
                    ui(f"{item.label} 大小不对：{path} 是 {size} 字节，清单是 {artifact.size}",
                       f"{item.display_label} has the wrong size: {path} is {size} bytes, "
                       f"the manifest says {artifact.size}"), "SIZE_MISMATCH")
            log(ui(f"校验 {path.name}（{size / 1e6:.0f} MB）", f"Verifying {path.name} ({size / 1e6:.0f} MB)"))
            digest = _sha256(path)
            if digest != artifact.sha256:
                raise InstallError(
                    ui(f"{item.label} 的 sha256 对不上：{path}\n  实际 {digest}\n  清单 {artifact.sha256}",
                       f"{item.display_label} fails its sha256 check: {path}\n"
                       f"  actual {digest}\n  manifest {artifact.sha256}"),
                    "SHA256_MISMATCH")


def _copy_pair(legacy: Candidate, target: Candidate, item: runtime.Component) -> tuple[Path, Path]:
    """一项在旧布局里从哪拷、在组件布局里落到哪。"""
    if item.key == "python":
        # 旧布局记的是 venv 的解释器；要拷的是它的 site-packages —— 组件里没有解释器，
        # 完整模式用 App 自带的那个，把这里接在 PYTHONPATH 末尾（两者同为 CPython 3.12）
        found = sorted((legacy.root / ".venv" / "lib").glob("python3.*/site-packages"))
        if len(found) != 1:
            raise InstallError(ui(f"在 {legacy.root}/.venv 里找不到唯一的 site-packages：{found}",
                                  f"Couldn't find exactly one site-packages in {legacy.root}/.venv: {found}"),
                               "NO_SITE_PACKAGES")
        return found[0], target.location(item)
    if item.key == "llama":
        # llama-server 旁边那一堆 libggml*.dylib 是它按 @loader_path 找的，整个 bin/ 一起走
        return legacy.location(item).parent, target.location(item).parent
    return legacy.location(item), target.location(item)


def _clone(src: Path, dst: Path) -> None:
    # cp -c：同一 APFS 卷上是 clonefile —— 2.9GB 几乎瞬间拷完、几乎不占新空间；
    # 跨卷时 cp 自己退回普通拷贝。-p 保留时间戳与权限（llama-server 要保住可执行位）。
    result = subprocess.run(["cp", "-Rpc", str(src), str(dst)], capture_output=True, text=True)
    if result.returncode != 0:
        raise InstallError(ui(f"拷贝失败：{src} → {dst}\n{result.stderr.strip()}",
                              f"Copy failed: {src} → {dst}\n{result.stderr.strip()}"), "COPY_FAILED")


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _write_manifest(stage: Path, *, source: str, sources: dict | None = None) -> None:
    manifest = {
        "schema": runtime.SCHEMA,
        "bundle": runtime.BUNDLE,
        "source": source,
        "installed_at": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
    }
    if sources:
        manifest["sources"] = sources  # 每一项实际是从哪个主机来的 —— 排障时第一个要问的
    (stage / "runtime.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _fresh_stage(dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    # 以前断在半路的（别的进程号）一并扫掉
    for stale in dest.parent.glob(f"{dest.name}.partial-*"):
        shutil.rmtree(stale, ignore_errors=True)
    stage = dest.parent / f"{dest.name}.partial-{os.getpid()}"
    stage.mkdir()
    return stage


def _swap_in(stage: Path, dest: Path) -> None:
    """整体换上去。旧的先挪开再删，换的那一下只是两次 rename。"""
    old = dest.parent / f"{dest.name}.old-{os.getpid()}"
    if dest.exists():
        dest.rename(old)
    stage.rename(dest)
    shutil.rmtree(old, ignore_errors=True)


# --- 下载安装 --------------------------------------------------------------------


def install_download(dest: Path, *, report: Report = _quiet,
                     should_stop: Callable[[], bool] = lambda: False,
                     client: httpx.Client | None = None,
                     pip_install: Callable[..., str] | None = None) -> Path:
    """从网上装一份组件。`client` 与 `pip_install` 只为测试留的缝。"""
    cache = config.DOWNLOADS_DIR
    cache.mkdir(parents=True, exist_ok=True)
    plan = _plan()
    _check_disk(dest, sum(_remaining(cache, a) for _item, a, _to in plan))

    owns_client = client is None
    client = client or httpx.Client(
        follow_redirects=True, timeout=httpx.Timeout(30.0, connect=15.0),
        headers={"User-Agent": "Scivane-OCR-Installer"},
    )
    stage = _fresh_stage(dest)
    target = Candidate("component", stage, COMPONENT)
    used: dict[str, str] = {}
    cached: list[Path] = []
    try:
        steps = _steps(plan)
        for index, (key, label) in enumerate(steps, start=1):
            report("step", {"index": index, "total": len(steps), "key": key, "label": label})
            if key == "python":
                used["python"] = (pip_install or _pip_install)(
                    target.location(runtime.component("python")), report=report, should_stop=should_stop)
                continue
            for item, artifact, to in (entry for entry in plan if entry[0].key == key):
                file = cache / _cache_name(artifact)
                used[f"{key}:{Path(urlparse(artifact.url).path).name}"] = fetch(
                    _sources(artifact.url), file, artifact.size, artifact.sha256,
                    key=key, report=report, should_stop=should_stop, client=client)
                cached.append(file)
                if item.archive is artifact:
                    _unpack(file, target.location(item).parent)
                else:
                    to_path = target.location(item) / to if to else target.location(item)
                    to_path.parent.mkdir(parents=True, exist_ok=True)
                    _clone(file, to_path)
        _strip_quarantine(stage)
        verify(target, log=lambda msg: report("log", {"message": msg}))
        _write_manifest(stage, source="download", sources=used)
        leftover = target.problem()
        if leftover is not None:
            raise InstallError(ui(f"装完之后仍然不齐：{leftover}",
                                  f"Still incomplete after installing: {leftover}"), "STAGE_INCOMPLETE")
        _swap_in(stage, dest)
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    finally:
        if owns_client:
            client.close()
    # 装成了才清缓存；失败时它们是下次续传的本钱
    for file in cached:
        file.unlink(missing_ok=True)
    shutil.rmtree(config.PIP_CACHE_DIR, ignore_errors=True)
    report("log", {"message": ui(f"已就位：{dest}", f"In place: {dest}")})
    return dest


def _plan() -> list[tuple[runtime.Component, Artifact, str]]:
    """要下载的每个文件：(属于哪一项, 清单条目, 在那一项里的相对位置)。"""
    out = []
    for item in runtime.COMPONENTS:
        if item.archive is not None:
            out.append((item, item.archive, ""))
        for artifact in item.artifacts:
            out.append((item, artifact, artifact.path))
    return out


def _steps(plan: list) -> list[tuple[str, str]]:
    """安装顺序：**小的、最能暴露网络问题的先来**。llama.cpp 11 MB 在 GitHub、版面模型
    131 MB 在 HuggingFace —— 网络不通在头一分钟就知道，而不是下完 1.8 GB 权重之后。"""
    order = ("llama", "layout", "python", "model", "mmproj")
    labels = {item.key: item.display_label for item, _a, _t in plan}
    labels["python"] = runtime.component("python").display_label
    return [(key, labels[key]) for key in order if key in labels]


def _cache_name(artifact: Artifact) -> str:
    # 用 sha256 打头：同名不同内容的文件（换了版本）不会接着彼此的断点续传
    return f"{artifact.sha256[:16]}-{Path(urlparse(artifact.url).path).name}"


def _remaining(cache: Path, artifact: Artifact) -> int:
    done = cache / _cache_name(artifact)
    if done.is_file():
        return 0
    part = done.with_name(done.name + ".part")
    have = part.stat().st_size if part.is_file() else 0
    return max(artifact.size - have, 0)


def _check_disk(dest: Path, download_bytes: int) -> None:
    """**开始前**查磁盘空间 —— 下到 1.5 GB 才发现盘满，是最让人恼火的那种失败。"""
    need = download_bytes + WHEELS_ESTIMATE_BYTES + SITE_ESTIMATE_BYTES + DISK_MARGIN_BYTES
    where = dest
    while not where.exists() and where != where.parent:
        where = where.parent
    free = shutil.disk_usage(where).free
    if free < need:
        raise InstallError(
            ui(f"装本地 OCR 大约要 {need / 1e9:.1f} GB 空间，{where} 所在的盘只剩 {free / 1e9:.1f} GB",
               f"Installing local OCR needs about {need / 1e9:.1f} GB, "
               f"but the disk holding {where} has only {free / 1e9:.1f} GB free"),
            "DISK_FULL")


def _sources(url: str) -> list[str]:
    """上游在前、镜像在后。只有 HuggingFace 有镜像；GitHub 只走上游。"""
    upstream = "https://huggingface.co"
    if url.startswith(upstream + "/"):
        return [url] + [mirror.rstrip("/") + url[len(upstream):] for mirror in config.OCR_HF_MIRRORS]
    return [url]


class _SourceFailed(Exception):
    pass


def fetch(sources: list[str], dest: Path, size: int, sha256: str, *, key: str,
          report: Report = _quiet, should_stop: Callable[[], bool] = lambda: False,
          client: httpx.Client) -> str:
    """把一个文件下到 `dest`，返回最后是从哪个主机拿齐的。

    断点续传：已下的部分在 `dest.part` 里，换来源也接着下（内容一样，最后按 sha256 验）。
    """
    if dest.is_file() and dest.stat().st_size == size and _sha256(dest) == sha256:
        report("log", {"message": ui(f"{dest.name} 已在下载缓存里，校验通过",
                                     f"{dest.name} is already in the download cache and checks out")})
        return "cache"
    part = dest.with_name(dest.name + ".part")
    errors: list[str] = []
    for index, url in enumerate(sources):
        host = urlparse(url).netloc
        last = index == len(sources) - 1
        try:
            _stream(url, part, size, key=key, host=host, report=report,
                    should_stop=should_stop, client=client, may_abandon=not last)
        except _SourceFailed as exc:
            errors.append(ui(f"{host}：{exc}", f"{host}: {exc}"))
            if not last:
                report("source", {"key": key, "from": host, "to": urlparse(sources[index + 1]).netloc,
                                  "reason": str(exc)})
            continue
        if part.stat().st_size != size:
            errors.append(ui(f"{host}：只拿到 {part.stat().st_size} / {size} 字节",
                             f"{host}: got only {part.stat().st_size} / {size} bytes"))
            continue
        if _sha256(part) != sha256:
            # 内容不对就整份作废（续传也是接在错的内容后面），下一个来源从头下
            part.unlink()
            errors.append(ui(f"{host}：sha256 对不上清单", f"{host}: sha256 doesn't match the manifest"))
            if not last:
                report("source", {"key": key, "from": host, "to": urlparse(sources[index + 1]).netloc,
                                  "reason": ui("sha256 对不上", "sha256 mismatch")})
            continue
        part.rename(dest)
        return host
    raise InstallError(ui(f"{dest.name} 下不下来：\n  ", f"Couldn't download {dest.name}:\n  ")
                       + "\n  ".join(errors), "DOWNLOAD_FAILED")


def _stream(url: str, part: Path, size: int, *, key: str, host: str, report: Report,
            should_stop: Callable[[], bool], client: httpx.Client, may_abandon: bool) -> None:
    offset = part.stat().st_size if part.is_file() else 0
    if offset > size:
        part.unlink()
        offset = 0
    if offset == size:
        return
    headers = {"Range": f"bytes={offset}-"} if offset else {}
    try:
        with client.stream("GET", url, headers=headers) as response:
            if response.status_code == 206:
                mode = "ab"
            elif response.status_code == 200:
                mode, offset = "wb", 0  # 不认 Range 的来源：只能从头来
            else:
                raise _SourceFailed(f"HTTP {response.status_code}")
            started = last_report = time.monotonic()
            received = 0
            with part.open(mode) as f:
                # 不指定块大小：httpx 会把数据攒满一块才交出来，慢来源就要等满 1 MB 才被发现、
                # 取消也要等到那时才生效。来多少交多少
                for chunk in response.iter_bytes():
                    if should_stop():
                        raise Cancelled()
                    f.write(chunk)
                    received += len(chunk)
                    now = time.monotonic()
                    if now - last_report >= 0.25:
                        last_report = now
                        report("progress", {"key": key, "file": part.name.removesuffix(".part"),
                                            "done": offset + received, "total": size, "source": host})
                    elapsed = now - started
                    if may_abandon and elapsed > SLOW_AFTER_SECONDS and received / elapsed < SLOW_BYTES_PER_SECOND:
                        speed = received / elapsed / 1000
                        raise _SourceFailed(ui(f"太慢（{speed:.0f} KB/s）", f"too slow ({speed:.0f} KB/s)"))
            report("progress", {"key": key, "file": part.name.removesuffix(".part"),
                                "done": offset + received, "total": size, "source": host})
    except httpx.HTTPError as exc:
        raise _SourceFailed(f"{type(exc).__name__}: {exc}" if str(exc) else type(exc).__name__) from exc


def _unpack(archive: Path, into: Path) -> None:
    """解开 llama.cpp 的压缩包，把唯一的顶层目录拍平进 `into`（组件的 bin/）。

    **过滤器用 "data"**：拒绝绝对路径、`..`、指向包外的链接 —— 一个被篡改过的压缩包
    不能借解压往组件目录外写东西（sha256 已经校验过，这是第二道）。
    """
    with tempfile.TemporaryDirectory(dir=into.parent if into.parent.exists() else None) as tmp:
        try:
            with tarfile.open(archive) as tar:
                tar.extractall(tmp, filter="data")
        except (tarfile.TarError, OSError) as exc:
            raise InstallError(ui(f"解不开 {archive.name}：{exc}", f"Couldn't unpack {archive.name}: {exc}"),
                               "UNSAFE_ARCHIVE") from exc
        entries = list(Path(tmp).iterdir())
        root = entries[0] if len(entries) == 1 and entries[0].is_dir() else Path(tmp)
        into.mkdir(parents=True, exist_ok=True)
        for entry in root.iterdir():
            entry.rename(into / entry.name)


def _strip_quarantine(path: Path) -> None:
    # 下载来的二进制带着隔离属性会被 Gatekeeper 拦住
    subprocess.run(["xattr", "-dr", "com.apple.quarantine", str(path)], capture_output=True)


def _installer_python() -> str:
    """用哪个解释器跑 pip。优先 App 自带的那个（完整模式也是它来 import 这些包）。

    开发模式的 venv 由 uv 建，**里面没有 pip** —— 所以得先试，而不是想当然用 sys.executable。
    """
    for candidate in (config.PYTHON_DIR / "bin" / "python3", Path(sys.executable)):
        if candidate.is_file() and subprocess.run(
                [str(candidate), "-m", "pip", "--version"], capture_output=True).returncode == 0:
            return str(candidate)
    raise InstallError(ui("找不到能装包的 Python（自带解释器还没拷出来，当前解释器里也没有 pip）",
                          "No Python that can install packages (the bundled interpreter isn't copied out yet, "
                          "and the current one has no pip)"), "NO_PIP")


def _pip_install(site: Path, *, report: Report = _quiet,
                 should_stop: Callable[[], bool] = lambda: False) -> str:
    """按锁文件把 OCR 依赖装进 `site`，索引上游优先、失败换镜像。返回用上的索引主机。

    --no-deps：锁文件已经列全了（基础层已有的那些被剔掉，运行时排在 PYTHONPATH 前面）。
    **不加 --no-compile**：运行时开着 PYTHONDONTWRITEBYTECODE，不在这里编好 .pyc，
    paddle 每次冷启动都要重编。
    """
    python = _installer_python()
    total = sum(1 for line in OCR_LOCK.read_text(encoding="utf-8").splitlines() if line[:1].isalpha())
    errors: list[str] = []
    indexes = list(config.OCR_PYPI_INDEXES)
    for index, url in enumerate(indexes):
        host = urlparse(url).netloc
        shutil.rmtree(site, ignore_errors=True)  # 换源从头装；已下好的 wheel 在 pip 缓存里，不会重下
        command = [
            python, "-m", "pip", "--isolated", "--disable-pip-version-check", "install",
            "--no-deps", "--require-hashes", "--only-binary=:all:", "--progress-bar", "off",
            "--target", str(site), "--cache-dir", str(config.PIP_CACHE_DIR),
            "--index-url", url, "--timeout", "30", "--retries", "2", "-r", str(OCR_LOCK),
        ]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        seen = 0
        tail: list[str] = []
        assert process.stdout is not None
        for line in process.stdout:
            if should_stop():
                process.terminate()
                process.wait()
                raise Cancelled()
            line = line.rstrip()
            tail = (tail + [line])[-8:]
            if line.startswith("Collecting "):
                seen += 1
                report("progress", {"key": "python", "done": seen, "total": total, "unit": "包", "source": host})
            if line.startswith(("Collecting ", "Installing ", "Successfully ")):
                report("log", {"message": line})
        if process.wait() == 0:
            return host
        errors.append(ui(f"{host}：\n    ", f"{host}:\n    ") + "\n    ".join(tail))
        if index < len(indexes) - 1:
            report("source", {"key": "python", "from": host, "to": urlparse(indexes[index + 1]).netloc,
                              "reason": tail[-1] if tail else ui("pip 失败", "pip failed")})
    raise InstallError(ui("OCR 的 Python 依赖装不上：\n  ", "Couldn't install the OCR Python packages:\n  ")
                       + "\n  ".join(errors), "DEPS_FAILED")
