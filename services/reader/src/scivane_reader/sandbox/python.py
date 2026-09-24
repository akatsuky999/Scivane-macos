"""python 执行器 —— 用 App 自带的解释器建环境，在沙箱内跑脚本。

**两层环境，都不是模型部署那一个。** OCR 的三档位置都是「只装不改」的工具，
`config.SANDBOX_DENY_READ` 把它们全部列进了拒读名单 ——
agent 对它们连读权限都不需要。

两层按**住在哪**分两种建法：

- **共享分析环境**（`~/.scivane/runtime/analysis/`）—— numpy / pandas / matplotlib，
  所有项目共用，装一次。它**住在所有项目之外，沙箱写不到那里**，所以只能由宿主端建：
  第一次有人要用时建，加锁，完成标记最后写。这一半留在宿主端是被迫的。
- **每项目环境**（`<项目>/workbench/.venv`）—— 论文代码真的需要独立依赖时才建。
  它在可写根里，所以**建和装都在沙箱里**：pip 经本地审计代理出网，审计簿上看得到
  pypi.org，装坏了也只坏这一个项目。宿主端一个字节都不往项目环境里写。

**解释器是 App 自带的那一份**（`start_backend.sh` 首启拷到 `~/.scivane/runtime/python/`）。
不找 uv、不看 PATH：Finder 起的 App 里 launchd 给的 PATH 没有 homebrew，
`shutil.which("uv")` 在别人的机器上必然是 None —— 从前这里就是这么写的。

> 从前的判断是「建环境在沙箱外，跑脚本在沙箱内」，理由是沙箱内无网、装不了包。
> 沙箱通网之后，项目环境据此搬了进来；
> 共享环境仍在宿主端，理由换成了「它住在项目外」。
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

from .policy import SandboxPolicy
from .runner import ExecResult, Runner

__all__ = [
    "ANALYSIS_PACKAGES", "PythonEnv", "interpreter",
    "analysis_env", "analysis_ready", "ensure_analysis_env",
    "project_env", "create_project_env", "install_into_project",
    "python_argv", "run_python",
]

#: 共享分析环境预装什么。刻意只装「读论文时确实会用到」的几样 ——
#: 装成一个大杂烩既慢又让 agent 以为自己什么都能干。
ANALYSIS_PACKAGES: tuple[str, ...] = ("numpy", "pandas", "matplotlib")

#: 项目内按需环境的位置。放 workbench/ 下 —— 它本来就是 agent 的落点，
#: 而且在可写区域内；放 code/ 会和论文自己的仓库混在一起。
_PROJECT_ENV_SUBDIR = "workbench/.venv"

#: 产物默认落点。python 执行器的 cwd 就是它，所以脚本里
#: `savefig("fig.png")` 这种相对路径天然落在这里。
_OUTPUTS_SUBDIR = "workbench/outputs"

#: 共享分析环境建完之后才写的标记。**没有它就是没建完** —— 目录再全也不算，
#: 下次整个重来（同 OCR 组件的 `runtime.json`：最后写）。
_READY_MARKER = ".scivane-ready"

#: pip 装包的公共参数。
#:
#: `--no-input`：沙箱里没有人能回答提示，等下去只会等到超时。
#: `--no-cache-dir`：装好的环境就是产物。宿主端那一次若带缓存，写的是用户自己的
#: `~/Library/Caches/pip`（不是 App 的地方）；沙箱里那一次则会在项目目录里平白多存
#: 一份 wheel（实测 sympy 6.6 MB，torch 是这个的几十倍）—— 而项目目录是用户数据。
_PIP_INSTALL: tuple[str, ...] = (
    "-m", "pip", "install", "--disable-pip-version-check", "--no-input",
    "--no-cache-dir", "--progress-bar", "off",
)

#: 建一个空 venv 的上限。实测 0.9 秒（含 ensurepip，不联网），给足余量。
_VENV_TIMEOUT = 120.0

# 两个项目的 agent 同时第一次跑 python 时，共享环境只建一份。
# 后端是单进程（pidfile 管着），一把线程锁就够 —— 建环境跑在 to_thread 的工作线程里。
_ANALYSIS_LOCK = threading.Lock()


@dataclass(frozen=True)
class PythonEnv:
    """一个 venv 的位置。"""

    root: Path

    @property
    def python(self) -> Path:
        return self.root / "bin" / "python"

    @property
    def bin_dir(self) -> Path:
        return self.root / "bin"

    @property
    def exists(self) -> bool:
        return self.python.exists()


def interpreter() -> Path:
    """用哪个解释器建环境。**App 自带的那一份优先**，开发模式下还没拷出来时用当前进程的底座。

    不查 PATH、不找 uv（见模块说明）。退路取**底座**而不是 `sys.executable`：
    开发用的解释器是个 venv，住在旧部署目录里 —— 那是拒读名单上的地方。项目环境
    是在沙箱里建的，建出来的 `bin/python` 链接到哪，沙箱就得读得到哪。
    """
    from .. import config

    bundled = config.PYTHON_DIR / "bin" / "python3"
    if bundled.is_file():
        return bundled.resolve()
    return Path(getattr(sys, "_base_executable", sys.executable)).resolve()


def analysis_env(runtime_dir: Path | None = None) -> PythonEnv:
    """共享分析环境的位置（不保证已经建好）。"""
    if runtime_dir is not None:
        return PythonEnv(runtime_dir)
    from .. import config

    return PythonEnv(config.ANALYSIS_ENV_DIR)


def analysis_ready(
    packages: tuple[str, ...] = ANALYSIS_PACKAGES, *, runtime_dir: Path | None = None
) -> bool:
    """共享分析环境建完了没有，而且装的是不是这几样。

    标记里记着当时装了什么：将来 `ANALYSIS_PACKAGES` 多一样，老环境就不算建完，
    会重建 —— 否则工具描述说有、import 时没有，那是这个仓库最怕的那一类静默错。
    解释器换了小版本时 `bin/python` 的链接会断，`exists` 为假，同样会重建。
    """
    env = analysis_env(runtime_dir)
    if not env.exists:
        return False
    try:
        recorded = json.loads((env.root / _READY_MARKER).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return isinstance(recorded, dict) and set(packages) <= set(recorded.get("packages", ()))


def ensure_analysis_env(
    packages: tuple[str, ...] = ANALYSIS_PACKAGES,
    *,
    runtime_dir: Path | None = None,
    timeout: float = 600.0,
) -> PythonEnv:
    """建好共享分析环境；已经建好就什么都不做。**在宿主端做** —— 它住在所有项目之外。

    三条规矩：

    - **完成标记最后写。** 装到一半断掉的目录下次整个重来，而不是被当成能用的环境
      交给沙箱 —— 那样模型会撞上一个莫名其妙的 ModuleNotFoundError。
    - **加锁。** 两个项目同时第一次跑 python，只建一份。
    - **`-I` 起解释器。** 后端进程自己的 PYTHONPATH（安装包的 `site/`，完整模式下末尾
      还接着 OCR 组件的 `site/`，里面就有 numpy 和 pandas）不许漏进来：漏进来 pip 会把
      那些包当成「已经有了」跳过，**退出码照样是 0**，等到沙箱里干净的环境 import 时
      才炸。实测不加 `-I` 跳过了 6 个包，加了之后一个不漏。

    不加 `--isolated`：用户自己的 pip 配置（比如国内镜像）在这里是帮忙，不是污染 ——
    这一份没有哈希锁，与 OCR 组件按锁文件装是两回事。

    :raises subprocess.CalledProcessError: 建或装失败 —— 原样上抛，pip 的输出
        （网络、版本冲突）对用户是有用信息，不要吞掉。
    :raises subprocess.TimeoutExpired: 超时。
    """
    env = analysis_env(runtime_dir)
    if analysis_ready(packages, runtime_dir=runtime_dir):
        return env
    with _ANALYSIS_LOCK:
        if analysis_ready(packages, runtime_dir=runtime_dir):
            return env
        # 上次没建完的残骸（或者标记对不上的旧环境）。这个目录归 App 管，删了会重建。
        shutil.rmtree(env.root, ignore_errors=True)
        env.root.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [str(interpreter()), "-I", "-m", "venv", str(env.root)],
            check=True, capture_output=True, timeout=timeout,
        )
        if packages:
            subprocess.run(
                [str(env.python), "-I", *_PIP_INSTALL, *packages],
                check=True, capture_output=True, timeout=timeout,
            )
        (env.root / _READY_MARKER).write_text(
            json.dumps({"packages": list(packages)}, ensure_ascii=False), encoding="utf-8"
        )
    return env


def project_env(project_dir: Path | str) -> PythonEnv:
    """项目内按需环境的位置（不保证已经建好）。"""
    return PythonEnv(Path(project_dir).expanduser().resolve() / _PROJECT_ENV_SUBDIR)


def create_project_env(
    project_dir: Path | str, policy: SandboxPolicy, *, runner: Runner | None = None
) -> ExecResult:
    """在**沙箱里**给这个项目建一个空 venv（带 pip，ensurepip 不联网）。

    实测 `(deny file-link)` 不拦 venv 的解释器链接 —— 它只管硬链接；
    链接指向 `interpreter()`，那里在拒读名单之外。沙箱里的环境本来就是从零搭的，
    所以这里**不加 `-I`**：加了反而会丢掉 `build_env` 特意给的 `PYTHONIOENCODING`。

    :raises SandboxUnavailable: 沙箱不可用 —— 不建，也不退回宿主端建。
    """
    env = project_env(project_dir)
    active = runner if runner is not None else Runner()
    return active.run(
        (str(interpreter()), "-m", "venv", str(env.root)), policy, timeout=_VENV_TIMEOUT
    )


def install_into_project(
    project_dir: Path | str,
    packages: tuple[str, ...],
    policy: SandboxPolicy,
    *,
    runner: Runner | None = None,
    timeout: float = 900.0,
) -> ExecResult:
    """在**沙箱里**给这个项目装包：环境不在就先建，然后 pip install。

    两步用的是同一份策略 —— 这一次调用的边界与联网凭据，所以 pip 的流量在审计簿上
    归到这一次 python 调用名下。返回 pip 那一步的结果；建环境失败就返回建环境那一步。

    :raises SandboxUnavailable: 沙箱不可用 —— 不装，也不退回宿主端装。
    """
    env = project_env(project_dir)
    active = runner if runner is not None else Runner()
    if not env.exists:
        created = create_project_env(project_dir, policy, runner=active)
        if not created.ok:
            return created
    return active.run((str(env.python), *_PIP_INSTALL, *packages), policy, timeout=timeout)


def python_argv(env: PythonEnv, script: Path | None = None) -> tuple[str, ...]:
    """纯函数。`script` 为 None 时从 stdin 读程序。

    `-u` 是必须的：缓冲住的话长任务在跑完之前一个字都看不到，界面上像死了。
    """
    if script is not None:
        return (str(env.python), "-u", str(script))
    return (str(env.python), "-u", "-")


def run_python(
    code: str,
    policy: SandboxPolicy,
    *,
    env: PythonEnv | None = None,
    runner: Runner | None = None,
    script: Path | None = None,
    timeout: float | None = None,
) -> ExecResult:
    """在沙箱内跑一段 Python。

    cwd 设成 `workbench/outputs/` —— 「产物默认落在工作台」这句话要真的成立，
    就得让脚本里的相对路径天然指向那里，而不是靠提示词叮嘱模型。

    :param code: 程序文本，从 stdin 喂进去（`script` 给出时忽略）。
    :raises SandboxUnavailable: 沙箱不可用 —— 此时不执行，不降级。
    """
    target = env if env is not None else analysis_env()
    active = runner if runner is not None else Runner()

    outputs = policy.workspace_root / _OUTPUTS_SUBDIR
    if policy.mode == "workspace-write":
        outputs.mkdir(parents=True, exist_ok=True)

    return active.run(
        python_argv(target, script),
        policy,
        cwd=outputs if outputs.is_dir() else policy.workspace_root,
        timeout=timeout,
        extra_path=(str(target.bin_dir),),
        env_extra={
            # 没有显示器，交互式后端会直接崩。这是离屏画图的唯一正确选择。
            "MPLBACKEND": "Agg",
            # **不能叫 SCIVANE_PROJECT_ROOT。** 那个名字在 paths.py 与
            # start_backend.sh 里指的是**代码仓库根**；这里指的是**论文项目根**。
            # 同名不同义今天不炸，只因为沙箱子进程从不 import scivane_reader ——
            # 自带解释器之后它就会 import，那时再发现就晚了。
            "SCIVANE_WORKSPACE_ROOT": str(policy.workspace_root),
            "SCIVANE_OUTPUT_DIR": str(outputs),
        },
        stdin=None if script is not None else code,
    )
