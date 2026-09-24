"""本地 OCR 组件：它是什么、在哪、齐不齐。

本地 OCR 是**可选组件**：没装时项目管理、阅读、云端问答照常，读者 agent 的
`reocr` 退出工具注册表（给它看见再拒绝执行更糟）。

**`COMPONENTS` 是事实来源**：一件东西叫什么、在两种布局里的位置、有固定内容的
那几个文件多大、sha256 多少、从哪下载。`preflight()`、`status()`、启动脚本要的
路径都由它渲染出来 —— 同一个事实只在一处。

三档发现（位置在 config.py，逻辑在这里），第一个**齐的**算数：

    覆盖    SCIVANE_RUNTIME_ROOT            设了就只看它 —— 不齐就是不齐，不往下找
    组件    ~/.scivane/runtime/ocr          带 runtime.json；App 装的，或从旧部署迁来的
    旧部署  SCIVANE_LEGACY_RUNTIME_DIR      设了才有；报成 legacy，可以一键迁成组件

组件排在旧部署前面，但**齐的优先**：装到一半断掉的组件目录，不该让一套能用的
旧部署跟着失效。

两种布局：

    component  runtime.json · site/（Python 依赖）· bin/ · models/ · layout/PP-DocLayoutV3/
    legacy     .venv/（Python 依赖在 venv 里）· bin/ · models/ · 版面模型在 ~/.paddlex 下

命令行：

    python -m scivane_reader.runtime shell     给 start_backend.sh eval 的一组赋值
    python -m scivane_reader.runtime status    人读的一段体检
    python -m scivane_reader.runtime migrate   把旧部署迁成组件（见 runtime_install.py）
    python -m scivane_reader.runtime install   从网上装组件（上游优先，失败或太慢换镜像）
"""

from __future__ import annotations

import json
import os
import shlex
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping

from . import config
from .i18n import ui

#: runtime.json 的格式。改结构就升版本号 —— 用户磁盘上已经装好的组件得认得出来。
SCHEMA = "scivane.ocr/1"
#: 这一版组件的身份。换了模型、llama.cpp 或 paddle 的版本就改它，status 据此报「过期」。
BUNDLE = "paddleocr-vl-1.6+llama-b10852+paddle-3.3.1"

COMPONENT = "component"
LEGACY = "legacy"


@dataclass(frozen=True)
class Artifact:
    """一个内容固定的文件：装的时候按它校验，迁移的时候也按它校验。"""

    path: str  #: 相对于所属那一项的位置；"" 表示那一项本身就是这个文件
    size: int
    sha256: str
    url: str = ""


@dataclass(frozen=True)
class Component:
    key: str
    label: str
    #: 布局 → 这一项的位置（相对于根）。以 "$PADDLEX/" 开头的相对于 config.PADDLEX_CACHE_DIR
    paths: Mapping[str, str]
    #: 布局 → 「在不在」看位置下的哪个文件；没列的布局看位置本身
    probe: Mapping[str, str] = field(default_factory=dict)
    executable: bool = False
    artifacts: tuple[Artifact, ...] = ()
    #: 下载安装时取的压缩包（装好之后里面的文件不逐个校验，校验的是包本身）
    archive: Artifact | None = None
    note: str = ""
    #: 英文界面里的名字与备注（`i18n.py`）。`label` / `note` 本身仍是中文 ——
    #: 命令行与日志照旧用它们。
    label_en: str = ""
    note_en: str = ""

    @property
    def display_label(self) -> str:
        """给人看的名字，按这一次请求的界面语言。"""
        return ui(self.label, self.label_en or self.label)

    @property
    def display_note(self) -> str:
        return ui(self.note, self.note_en or self.note)


_HF = "https://huggingface.co/PaddlePaddle"

# 大小与 sha256 都是 2026-09-18 实测：与上游的文件逐字节核对过
# （HuggingFace 的 LFS 哈希、GitHub release 的 digest、小文件的 git blob 哈希）。
COMPONENTS: tuple[Component, ...] = (
    Component(
        key="python",
        label="OCR 的 Python 依赖（paddle / paddleocr）",
        label_en="OCR Python packages (paddle / paddleocr)",
        paths={COMPONENT: "site", LEGACY: ".venv/bin/python"},
        probe={COMPONENT: "paddleocr/__init__.py"},
    ),
    Component(
        key="llama",
        label="llama-server（llama.cpp b10852，Metal）",
        paths={COMPONENT: "bin/llama-server", LEGACY: "bin/llama-server"},
        executable=True,
        archive=Artifact(
            "", 11_136_905, "0a1bd66656354e43bc90fb7d7ce5a56c5683f338706e5d59fd4e38e7f44c4008",
            "https://github.com/ggml-org/llama.cpp/releases/download/b10852/llama-b10852-bin-macos-arm64.tar.gz"),
        note="下载来的二进制要去掉隔离属性（xattr -dr com.apple.quarantine），否则会被 Gatekeeper 拦住",
        label_en="llama-server (llama.cpp b10852, Metal)",
        note_en="downloaded binaries must have the quarantine attribute removed "
                "(xattr -dr com.apple.quarantine), or Gatekeeper will block them",
    ),
    Component(
        key="model",
        label="识别模型 PaddleOCR-VL-1.6（F16 GGUF）",
        label_en="Recognition model PaddleOCR-VL-1.6 (F16 GGUF)",
        paths={COMPONENT: "models/PaddleOCR-VL-1.6-GGUF.gguf", LEGACY: "models/PaddleOCR-VL-1.6-GGUF.gguf"},
        artifacts=(Artifact(
            "", 935_769_056, "f3ae46ec885050acf4b3d31944431e1fd90d50664fb09126af4a3c050ba14ee8",
            f"{_HF}/PaddleOCR-VL-1.6-GGUF/resolve/main/PaddleOCR-VL-1.6-GGUF.gguf"),),
    ),
    Component(
        key="mmproj",
        label="视觉投影 mmproj",
        label_en="Vision projector (mmproj)",
        paths={COMPONENT: "models/PaddleOCR-VL-1.6-GGUF-mmproj.gguf",
               LEGACY: "models/PaddleOCR-VL-1.6-GGUF-mmproj.gguf"},
        artifacts=(Artifact(
            "", 881_770_560, "204d757d7610d9b3faab10d506d69e5b244e32bf765e2bab2d0167e65e0a058a",
            f"{_HF}/PaddleOCR-VL-1.6-GGUF/resolve/main/PaddleOCR-VL-1.6-GGUF-mmproj.gguf"),),
        # 这个缺了不会报错，只会让模型吐一堆重复字符，排查起来很费时间
        note="缺它的表现是输出重复字符，不是报错",
        note_en="without it the output is repeated characters, not an error",
    ),
    Component(
        key="layout",
        label="版面模型 PP-DocLayoutV3",
        label_en="Layout model PP-DocLayoutV3",
        paths={COMPONENT: "layout/PP-DocLayoutV3", LEGACY: "$PADDLEX/official_models/PP-DocLayoutV3"},
        probe={COMPONENT: "inference.pdiparams", LEGACY: "inference.pdiparams"},
        artifacts=(
            Artifact("inference.json", 1_196_890,
                     "2b68367c5b312a03de5a6e1642c597c8f95165a7e40cd59c6700cf4a5042f4fd",
                     f"{_HF}/PP-DocLayoutV3/resolve/main/inference.json"),
            Artifact("inference.pdiparams", 130_806_572,
                     "70bd316b0582769ec968829fd1feb1a6a58b7c941b938327e551b6b12b45c137",
                     f"{_HF}/PP-DocLayoutV3/resolve/main/inference.pdiparams"),
            Artifact("inference.yml", 1_482,
                     "506fcfac13b3b546ae40d7886b44126420f392adb694e3f8bb6a6286a1f90fdc",
                     f"{_HF}/PP-DocLayoutV3/resolve/main/inference.yml"),
        ),
    ),
)


def component(key: str) -> Component:
    return next(c for c in COMPONENTS if c.key == key)


@dataclass(frozen=True)
class Candidate:
    """一档候选：某个根目录，按某种布局去看。"""

    tier: str  #: "override" | "component" | "legacy"
    root: Path
    layout: str  #: COMPONENT | LEGACY

    def location(self, item: Component) -> Path:
        raw = item.paths[self.layout]
        if raw.startswith("$PADDLEX/"):
            return config.PADDLEX_CACHE_DIR / raw.removeprefix("$PADDLEX/")
        return self.root / raw

    def present(self, item: Component) -> bool:
        where = self.location(item)
        probe = item.probe.get(self.layout)
        target = where / probe if probe else where
        if item.executable:
            return target.is_file() and os.access(target, os.X_OK)
        return target.exists()

    def manifest(self) -> dict | None:
        """runtime.json 的内容；旧布局没有它。读不懂也当没有 —— 由 problem() 说清楚。"""
        try:
            data = json.loads((self.root / "runtime.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) else None

    def problem(self) -> str | None:
        """为什么这一档用不了；能用返回 None。"""
        if not self.root.is_dir():
            return ui(f"{self.root} 不存在", f"{self.root} doesn't exist")
        if self.layout == COMPONENT:
            manifest = self.manifest()
            if manifest is None:
                return ui(f"{self.root} 下没有可读的 runtime.json（装到一半断了，或者不是 OCR 组件）",
                          f"{self.root} has no readable runtime.json "
                          "(an install was interrupted, or this isn't an OCR component)")
            if manifest.get("schema") != SCHEMA:
                return ui(f"{self.root}/runtime.json 的格式是 {manifest.get('schema')!r}，这个版本只认 {SCHEMA}",
                          f"{self.root}/runtime.json has format {manifest.get('schema')!r}; "
                          f"this version only reads {SCHEMA}")
        missing = self.missing()
        if missing:
            parts = [
                ui(f"{m.label}（{self.location(m)}）", f"{m.display_label} ({self.location(m)})")
                + (ui(f" —— {m.note}", f" — {m.display_note}") if m.note else "")
                for m in missing
            ]
            return ui(f"{self.root} 缺：" + "；".join(parts), f"{self.root} is missing: " + "; ".join(parts))
        return None

    def missing(self) -> tuple[Component, ...]:
        return tuple(c for c in COMPONENTS if not self.present(c))

    @property
    def usable(self) -> bool:
        return self.problem() is None

    # --- 启动与识别要的路径 ---------------------------------------------------

    @property
    def llama_server(self) -> Path:
        return self.location(component("llama"))

    @property
    def model(self) -> Path:
        return self.location(component("model"))

    @property
    def mmproj(self) -> Path:
        return self.location(component("mmproj"))

    @property
    def layout_dir(self) -> Path:
        return self.location(component("layout"))

    @property
    def venv_python(self) -> Path | None:
        """旧布局：OCR 依赖装在这个 venv 里，完整模式只能用它跑编排层。"""
        return self.location(component("python")) if self.layout == LEGACY else None

    @property
    def site(self) -> Path | None:
        """组件布局：OCR 依赖所在的目录，完整模式时接在 PYTHONPATH 末尾。"""
        return self.location(component("python")) if self.layout == COMPONENT else None


def _layout_of(root: Path) -> str:
    return COMPONENT if (root / "runtime.json").is_file() else LEGACY


def candidates() -> tuple[Candidate, ...]:
    """按优先级列出要看的几档。每次现算 —— 装完不重启后端也看得见。"""
    if config.RUNTIME_OVERRIDE is not None:
        root = config.RUNTIME_OVERRIDE
        return (Candidate("override", root, _layout_of(root)),)
    tiers = [Candidate("component", config.OCR_COMPONENT_DIR, COMPONENT)]
    # 旧部署没有默认位置：没设就没有这一档，而不是报一个不存在的目录
    if config.LEGACY_RUNTIME_DIR is not None:
        tiers.append(Candidate("legacy", config.LEGACY_RUNTIME_DIR, LEGACY))
    return tuple(tiers)


def resolve() -> Candidate | None:
    """第一个齐的那一档；都不齐返回 None。"""
    return next((c for c in candidates() if c.usable), None)


def available() -> bool:
    return resolve() is not None


def preflight() -> list[str]:
    """OCR 用不了的原因；空列表表示能用。

    宁可在启动前一次性说清哪里不对，也不要等到识别到一半才炸。
    """
    if available():
        return []
    reasons = []
    for c in candidates():
        problem = c.problem()
        if problem is not None:
            reasons.append(f"[{c.tier}] {problem}")
    return reasons


def unavailable_reason() -> str:
    reasons = preflight()
    head = ui("本地 OCR 不可用（可选组件，没装时阅读与问答不受影响）：",
              "Local OCR isn't available (it's an optional component; reading and Q&A work without it):")
    return head + "\n  " + "\n  ".join(reasons)


def status() -> dict:
    """给 `/runtime/status` 与界面用的结构化状态。"""
    active = resolve()
    listed = []
    for c in candidates():
        manifest = c.manifest() if c.layout == COMPONENT else None
        listed.append({
            "tier": c.tier,
            "root": str(c.root),
            "layout": c.layout,
            "exists": c.root.is_dir(),
            "usable": c.usable,
            "bundle": (manifest or {}).get("bundle"),
            "problem": c.problem(),
            "missing": [
                {"key": m.key, "label": m.display_label, "path": str(c.location(m)),
                 "note": m.display_note}
                for m in c.missing()
            ] if c.root.is_dir() else [],
        })
    return {
        "available": active is not None,
        "active": None if active is None else {
            "tier": active.tier,
            "root": str(active.root),
            "layout": active.layout,
            "legacy": active.tier == "legacy",
            "bundle": (active.manifest() or {}).get("bundle") if active.layout == COMPONENT else None,
        },
        "expected_bundle": BUNDLE,
        # 旧部署齐、组件还没有 —— 界面可以提供「一键迁移」（不下载，本机拷贝并校验）
        # （在用的是旧部署，就说明组件那一档不齐；覆盖生效时不提供迁移）
        "migratable": active is not None and active.tier == "legacy",
        "candidates": listed,
    }


def describe() -> str:
    """给日志用的一行摘要。"""
    active = resolve()
    if active is None:
        return "ocr=未安装"
    return f"ocr={active.tier}:{active.root}"


# --- 命令行 ---------------------------------------------------------------------


def _shell() -> str:
    """给 start_backend.sh `eval` 的赋值。每个值都 shlex.quote 过 —— 路径里有空格也不会拆开。"""
    active = resolve()
    values: dict[str, str] = {
        "OCR_TIER": "", "OCR_LAYOUT": "", "OCR_ROOT": "", "OCR_VENV_PYTHON": "", "OCR_SITE": "",
        "LLAMA_BIN": "", "MODEL": "", "MMPROJ": "", "OCR_PROBLEM": "",
    }
    if active is None:
        values["OCR_PROBLEM"] = unavailable_reason()
    else:
        values.update(
            OCR_TIER=active.tier, OCR_LAYOUT=active.layout, OCR_ROOT=str(active.root),
            OCR_VENV_PYTHON=str(active.venv_python or ""), OCR_SITE=str(active.site or ""),
            LLAMA_BIN=str(active.llama_server), MODEL=str(active.model), MMPROJ=str(active.mmproj),
        )
    return "\n".join(f"{k}={shlex.quote(v)}" for k, v in values.items())


def _status_text() -> str:
    data = status()
    lines = []
    active = data["active"]
    if active:
        tag = "（legacy：旧部署，只有这台机器有）" if active["legacy"] else ""
        lines.append(f"✓ 在用 {active['tier']} · {active['root']}{tag}")
    else:
        lines.append("- 没装（可选组件；阅读与问答不受影响）")
    for c in data["candidates"]:
        mark = "✓" if c["usable"] else "·"
        lines.append(f"  {mark} {c['tier']:9} {c['root']}" + ("" if c["usable"] else f"  ← {c['problem']}"))
    if data["migratable"]:
        lines.append("  可以把旧部署迁成组件（本机拷贝、不联网）：python -m scivane_reader.runtime migrate")
    elif not data["available"]:
        lines.append("  可以从网上装（约 2.2 GB，上游优先、不通换镜像）：python -m scivane_reader.runtime install")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    command = argv[0] if argv else "status"
    if command == "shell":
        print(_shell())
        return 0
    if command == "status":
        print(_status_text())
        return 0
    if command in ("migrate", "install"):
        from .runtime_install import InstallError, install

        shown: dict[str, float] = {}

        def report(kind: str, payload: dict) -> None:
            if kind == "progress":
                # 终端里每 5 秒报一次就够；界面那边另有节流
                key = payload["key"]
                if time.monotonic() - shown.get(key, 0) < 5 and payload["done"] != payload["total"]:
                    return
                shown[key] = time.monotonic()
                unit = payload.get("unit")
                amount = (f"{payload['done']}/{payload['total']} {unit}" if unit
                          else f"{payload['done'] / 1e6:.0f}/{payload['total'] / 1e6:.0f} MB")
                print(f"    {key} {amount} ← {payload.get('source', '')}", flush=True)
            elif kind == "step":
                print(f"[{payload['index']}/{payload['total']}] {payload['label']}", flush=True)
            elif kind == "source":
                print(f"    换来源：{payload['from']} → {payload['to']}（{payload['reason']}）", flush=True)
            else:
                print(f"    {payload['message']}", flush=True)

        try:
            dest = install("migrate" if command == "migrate" else "download",
                           config.OCR_COMPONENT_DIR, report=report)
        except InstallError as exc:
            print(f"没装成（{exc.code}）：{exc}", file=sys.stderr)
            return 1
        print(f"完成：{dest}")
        return 0
    print(f"用法：python -m scivane_reader.runtime [shell|status|migrate|install]（收到 {command!r}）",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
