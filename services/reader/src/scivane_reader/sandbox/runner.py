"""统一的执行接口 —— 消费者只跟这一层打交道。

上面是 bash / python 两个执行器，下面是 `SandboxProvider`。换沙箱实现时改的是
下面，这一层与执行器都不动，这就是「能力缝」要换来的东西。

三条纪律，每条都有测试钉着：

**沙箱起不来就拒绝执行。** 没有「警告一下照跑」这个选项 —— 一个本该受约束却没受约束的
进程，比一个跑不起来的进程危险得多，而且用户看不出区别。

**「沙箱没起来」与「命令被拒绝」必须分开报。** 前者命令根本没跑，是基础设施
故障；后者是约束正常工作挡住了越界动作，是预期行为。两者都表现为非零退出，
只看退出码分不出来，所以先按 `runner_failure_rules` 判 runner 失败，
再按 `denial_signatures` 判拒绝。

**环境从零搭，不继承。** 不是过滤 `os.environ`，是根本不读它。过滤是黑名单，
永远会漏；从零搭是白名单，漏了顶多是命令跑不起来，看得见。
"""

from __future__ import annotations

import os
import signal
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from .policy import (
    ConfinedCommand,
    SandboxEnforcement,
    SandboxPolicy,
    SandboxProvider,
    SandboxRunnerFailed,
    SandboxUnavailable,
)
from .seatbelt import SeatbeltProvider

__all__ = ["ExecResult", "Runner", "MINIMAL_PATH", "build_env"]

#: 子进程的 PATH。**不是用户的 PATH** —— 那里面可能有 agent 不该碰的东西，
#: 而且顺序可被改写。只留系统目录，需要别的（比如 venv 的 bin）由调用方显式加。
MINIMAL_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

#: 项目内给子进程用的两个目录。放进 workbench/ 是因为那里本来就是 agent 的
#: 落点，而且在可写区域内 —— 否则 TMPDIR 指到 /tmp 会被沙箱拦掉（实测），
#: 多数工具会以一个难懂的报错失败。
_HOME_SUBDIR = "workbench/home"
_TMP_SUBDIR = "workbench/tmp"


@dataclass
class ExecResult:
    """一次受约束执行的结果。"""

    argv: tuple[str, ...]
    exit_code: int
    stdout: str
    stderr: str
    duration: float
    #: 这次约束兑现了多少。`partial` 时 `enforcement_reason` 说明少了什么。
    enforcement: SandboxEnforcement = "full"
    enforcement_reason: str = ""
    #: 命令被沙箱挡住过（stderr 里有本后端的拒绝方言）。**不是错误** ——
    #: 说明边界正常工作。上层据此给用户一句「它想写项目外，被拦了」。
    denied: bool = False
    #: 命中的那一行原文，便于说清被拦的是什么。分类不改写 stderr。
    denial_hint: str = ""
    timed_out: bool = False

    @property
    def ok(self) -> bool:
        return self.exit_code == 0 and not self.timed_out


def build_env(
    policy: SandboxPolicy,
    *,
    extra_path: tuple[str, ...] = (),
    hooks_dir: Path | None = None,
    extra: dict[str, str] | None = None,
) -> dict[str, str]:
    """从零搭一份最小环境。

    堵三个已知逃逸口中的两个（第三个「不给包管理器全局目录写权限」由 SBPL 的
    写白名单负责，不需要环境变量配合）：

    **dotfiles 不继承。** `HOME` 指到项目内的 `workbench/home`，用户的
    `~/.zshrc`、`~/.gitconfig`、`~/.npmrc` 这些都落不到子进程头上。配合 bash
    执行器的 `--noprofile --norc`，shell 启动路径上一个用户文件都不读。
    顺带的好处：工具往 `~/.cache` 写的东西全部落在项目里、受同一套边界约束。

    **git hooks 默认禁用。** `core.hooksPath` 指向一个空目录 —— clone 下来的
    仓库里的 hook 是现成的执行入口，`git status` 这种无害命令都可能触发它。
    同时把 `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` 指到 `/dev/null`，
    否则用户自己的全局配置（里面可能就有 `core.hooksPath` 或危险 alias）
    仍然会被读进来。**Apple 的 git 还多一层**，只有 `GIT_CONFIG_NOSYSTEM` 关得掉（见下）。
    """
    root = policy.workspace_root
    path = ":".join((*extra_path, MINIMAL_PATH)) if extra_path else MINIMAL_PATH

    env: dict[str, str] = {
        "PATH": path,
        "HOME": str(root / _HOME_SUBDIR),
        "TMPDIR": str(root / _TMP_SUBDIR),
        "PWD": str(root),
        "LANG": "en_US.UTF-8",
        "LC_CTYPE": "en_US.UTF-8",
        # 论文里中文、希腊字母、数学符号都有，编码必须钉死，
        # 否则同一段正文在不同机器上会出不同的乱码。
        "PYTHONIOENCODING": "utf-8",
        # 不要去捡用户的 ~/.local/lib/pythonX.Y/site-packages。
        # HOME 已经改了，这条是第二道。
        "PYTHONNOUSERSITE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        # **Apple 的 git 多一层配置，上面两条关不掉它**：Xcode / 命令行开发者工具里的
        # `share/git-core/gitconfig` 写着 `credential.helper = osxkeychain`（`git config
        # --show-scope` 报它的 scope 是 unknown）。于是沙箱里的每一条 git 都会去碰用户的钥匙串。
        # 实测（2026-09-22）：经审计代理 clone 一个 http 仓库，认证成功之后 git 起
        # `git credential-osxkeychain store` 想把代理凭据存进钥匙串 —— **锁着屏时它一直等下去**
        # （20 次全部卡到超时），不锁屏时约 10 秒后失败。
        # 只有 NOSYSTEM 关得掉这一层；关掉之后同一个 clone 0.1 秒。
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        # **告诉子进程它在沙箱里。**
        #
        # 脚本据此自适应，比让它撞一堵没有解释的墙好。变量名是外部工具与测试
        # 共同使用的契约，不能随意改动。
        #
        # **带值而不是布尔。** `DISABLED=0` 与"没设这个变量"之间的歧义，
        # 正是这个仓库被静默失败坑过好几次的那一类。
        "SCIVANE_SANDBOX": "seatbelt",
        "SCIVANE_SANDBOX_NETWORK": "proxy" if policy.network.enabled else "restricted",
    }
    if policy.network.enabled:
        # **凭据经 http_proxy 的用户名位送进去。**
        #
        # 选这个形状是因为 curl / pip / git / httpx / requests 全都认它，
        # 一个工具都不用单独配；自定义头则要每个客户端改一遍，漏一个就是
        # 「这个命令莫名其妙没网」。
        #
        # 大小写两套都给，因为客户端的口味不一致：**curl 刻意不认大写的
        # `HTTP_PROXY`**（那是 CGI 环境下 `Proxy:` 请求头能伪造的变量，
        # 认它是个历史漏洞），而别的工具只看大写。给全才不会有工具漏网。
        #
        # `no_proxy` 显式设空：**一个直连例外都不留。** 不设的话某些客户端
        # 会带着自己的默认例外（常见的就是 localhost）绕过代理 —— 那正好
        # 绕开审计，也绕开「不许连回环」那道判定。
        proxy_url = f"http://{policy.network.proxy_token}:@127.0.0.1:{policy.network.proxy_port}"
        env["http_proxy"] = proxy_url
        env["https_proxy"] = proxy_url
        env["HTTPS_PROXY"] = proxy_url
        env["all_proxy"] = proxy_url
        env["ALL_PROXY"] = proxy_url
        env["no_proxy"] = ""
        env["NO_PROXY"] = ""
    if hooks_dir is not None:
        env["GIT_CONFIG_COUNT"] = "1"
        env["GIT_CONFIG_KEY_0"] = "core.hooksPath"
        env["GIT_CONFIG_VALUE_0"] = str(hooks_dir)
    if extra:
        env.update(extra)
    return env


class Runner:
    """把 argv 交给 provider 包一层，然后在最小环境里起进程。"""

    def __init__(
        self,
        provider: SandboxProvider | None = None,
        *,
        hooks_dir: Path | None = None,
        disable_git_hooks: bool = True,
        default_timeout: float = 120.0,
    ) -> None:
        """:param disable_git_hooks: 默认开。关掉它需要一个明确的理由 ——
        clone 下来的仓库里的 hook 是现成的执行入口，连 `git status` 都可能触发。
        """
        # **策略文件要落在可审计的位置。** 从前这里是裸的 `SeatbeltProvider()`，
        # `_profile_dir` 于是恒为 None，`mkdtemp(dir=None)` 把 .sb 写进系统临时目录 ——
        # 而 `config.SANDBOX_DIR` 那个配置项从头到尾没有任何人传进来。
        # 排障时「这次用的到底是什么边界」要找得到，才谈得上排障。
        if provider is None:
            from .. import config

            provider = SeatbeltProvider(profile_dir=config.SANDBOX_DIR)
        self._provider = provider
        self._hooks_dir = hooks_dir
        self._disable_git_hooks = disable_git_hooks
        self._default_timeout = default_timeout

    def _hooks(self) -> Path | None:
        """空 hooks 目录。默认取 config 里的位置，第一次用到时才建。"""
        if not self._disable_git_hooks:
            return None
        if self._hooks_dir is None:
            from .. import config

            self._hooks_dir = config.SANDBOX_HOOKS_DIR
        self._hooks_dir.mkdir(parents=True, exist_ok=True)
        return self._hooks_dir

    @property
    def provider(self) -> SandboxProvider:
        return self._provider

    def preflight(self) -> None:
        """沙箱不可用就当场抛，让调用方在动手之前就知道。

        :raises SandboxUnavailable:
        """
        if not self._provider.available():
            raise SandboxUnavailable(
                f"沙箱后端 {self._provider.name} 不可用，拒绝执行。"
                "不受约束地跑一条命令等于没有边界，而用户不会察觉。"
            )

    def run(
        self,
        argv: tuple[str, ...] | list[str],
        policy: SandboxPolicy,
        *,
        cwd: Path | None = None,
        timeout: float | None = None,
        extra_path: tuple[str, ...] = (),
        env_extra: dict[str, str] | None = None,
        stdin: str | None = None,
    ) -> ExecResult:
        """在沙箱内跑一条命令。

        :param policy: **这次调用**的边界。按调用携带，provider 不持有它。
        :raises SandboxUnavailable: 没有可用后端。
        :raises SandboxRunnerFailed: 后端自己没起来，命令根本没跑。
        """
        self.preflight()
        workdir = Path(cwd) if cwd is not None else policy.workspace_root
        self._prepare_dirs(policy)

        env = build_env(
            policy, extra_path=extra_path, hooks_dir=self._hooks(), extra=env_extra
        )
        limit = timeout if timeout is not None else self._default_timeout

        with self._provider.confine(tuple(argv), policy) as confined:
            return self._spawn(confined, tuple(argv), workdir, env, limit, stdin)

    # --- 内部 ------------------------------------------------------------

    def _prepare_dirs(self, policy: SandboxPolicy) -> None:
        """HOME 与 TMPDIR 必须由宿主端先建好。

        沙箱内建不了 —— `workbench/home` 的父目录存在但目录本身不存在时，
        多数工具不会替你 mkdir，只会以「没有那个文件或目录」失败。
        `read-only` 下不建：那个模式的承诺就是不产生任何写。
        """
        if policy.mode != "workspace-write":
            return
        for sub in (_HOME_SUBDIR, _TMP_SUBDIR):
            (policy.workspace_root / sub).mkdir(parents=True, exist_ok=True)

    def _spawn(
        self,
        confined: ConfinedCommand,
        original: tuple[str, ...],
        workdir: Path,
        env: dict[str, str],
        timeout: float,
        stdin: str | None,
    ) -> ExecResult:
        started = time.monotonic()
        timed_out = False
        try:
            proc = subprocess.Popen(
                confined.argv,
                cwd=str(workdir),
                env=env,
                stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                # 自成进程组：超时时要连同子进程一起收掉，只杀 sandbox-exec
                # 会留下孤儿 —— agent 跑的脚本往往还会再起进程。
                start_new_session=True,
            )
        except OSError as exc:
            raise SandboxRunnerFailed(f"沙箱后端启动失败：{exc}") from exc

        try:
            stdout, stderr = proc.communicate(input=stdin, timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            self._terminate(proc)
            stdout, stderr = proc.communicate()
        duration = time.monotonic() - started
        exit_code = proc.returncode if proc.returncode is not None else -1

        # 顺序要紧：先判 runner 失败（命令根本没跑），再判拒绝（命令跑了被挡）。
        for rule in confined.runner_failure_rules:
            line = rule.matched_line(exit_code, stderr)
            if line is not None:
                raise SandboxRunnerFailed(
                    f"沙箱后端没能起来，命令未执行：{line.strip()}"
                )

        hint = self._first_denial(stderr, confined)

        return ExecResult(
            argv=original,
            exit_code=exit_code,
            stdout=stdout or "",
            stderr=stderr or "",
            duration=duration,
            enforcement=confined.enforcement,
            enforcement_reason=confined.enforcement_reason,
            denied=bool(hint),
            denial_hint=hint.strip(),
            timed_out=timed_out,
        )

    @staticmethod
    def _first_denial(stderr: str, confined: ConfinedCommand) -> str:
        """找出第一条真正的拒绝行。

        先剔掉已知良性的噪音再判 —— 否则系统工具自己那点无关紧要的写失败会让
        每次执行都报成「越界」，狼来了喊多了，真的越界就没人看了。
        **不改写 stderr**，只影响分类结果。
        """
        benign = tuple(b.lower() for b in confined.informational_denials)
        for line in stderr.splitlines():
            lowered = line.lower()
            if benign and any(b in lowered for b in benign):
                continue
            if any(sig.lower() in lowered for sig in confined.denial_signatures):
                return line
        return ""

    @staticmethod
    def _terminate(proc: subprocess.Popen[str]) -> None:
        """先礼后兵，和 BackendManager.reap() 一个路子。

        整个进程组一起收：agent 的脚本可能还起了子进程，只杀父进程会留孤儿。
        """
        try:
            group = os.getpgid(proc.pid)
        except OSError:
            group = None
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                if group is not None:
                    os.killpg(group, sig)
                else:
                    proc.send_signal(sig)
            except OSError:
                return
            try:
                proc.wait(timeout=2)
                return
            except subprocess.TimeoutExpired:
                continue
