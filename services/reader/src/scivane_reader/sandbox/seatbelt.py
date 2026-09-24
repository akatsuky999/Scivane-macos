"""Seatbelt（`sandbox-exec`）后端 —— 当前唯一的实现。

**它随时可能消失。** Apple 已把 `sandbox-exec` 标记为弃用且没给替代品，
所以这个文件里的一切都只对 `policy.py` 的接口负责：整份换掉不影响任何消费者。

生成的 SBPL 长这样（顺序有意义，**后写的规则覆盖先写的**）：

    (version 1)
    (allow default)            ; 读与执行默认放行，见下面「读」
    (deny network*)            ; 默认无网；通网时在它后面只开一个回环针孔
    (deny file-link)           ; 堵掉硬链接逃逸，见下面
    (deny mach-lookup …)       ; 钥匙串的系统服务一个都连不上
    (deny file-write*)         ; 先全禁写
    (allow file-write* …sinks) ; 放行 /dev/null 这类必需写入口
    (allow file-write* …roots) ; 再放行工作区
    (deny file-write* …carve)  ; 最后挖掉 .lumen/ 与 pdf/
    (deny|allow file-read* …)  ; 读：按路径从浅到深逐条写，最具体的那条说了算
    (allow file-read-metadata …) ; 开回来的目录，它的每一级父目录只给元数据

**写是白名单，读是「默认放行 + 拒掉用户的私人区域」—— 这两者强度不同，必须说清楚。**
写这一侧先 `deny file-write*` 再逐个放行，是真正的白名单，项目外一律写不进去
（实测：`/tmp`、`~/.local/bin`、`~/.cache`、`~/.npm`、`~/.zshrc` 全部 EPERM）。
读这一侧仍是 `allow default` 加拒读，**但拒读的是整个用户 home**，再按「最具体的那条说了算」
开回项目根、自带解释器、共享分析环境，并在项目根里把 `.lumen/` 拒回去。
系统目录（`/usr`、`/System`、`/Library`、`/Applications`）照旧读得到 —— 改成读白名单要枚举
dyld 缓存那一大串，漏一个就是「二进制起不来」。

> 从前这里写的是「读取不是主要风险（沙箱内无网，读到的东西出不去）」。沙箱通网之后，
> 那个前提就没了：`~/.ssh`、`~/.aws`、别的项目都读得到、发得出去，审计簿只留一个主机名。
> 2026-09-22 量过之后改成现在的形状。

**硬链接那个口子。** SBPL 按路径判定，而硬链接就是同一个 inode 的另一个名字：
项目内一个指向项目外文件的硬链接，写它就等于写项目外。实测确认过这条能绕过去。
`(deny file-link)` 挡住了 agent **自己创建**硬链接，把活的逃逸路径堵死；但沙箱
启动前就已经存在的硬链接仍然有效 —— 所以 `confine()` 会扫一遍可写区域，
发现 `st_nlink > 1` 的普通文件就把执行强度报成 `partial` 并说明是哪几个文件。
符号链接没有这个问题：实测 Seatbelt 会解析到真实路径再判定，指向项目外的
符号链接写不进去。
"""

from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path

from .policy import (
    REQUIRED_WRITE_SINKS,
    ConfinedCommand,
    RunnerFailureRule,
    SandboxPolicy,
    SandboxProvider,
    SandboxUnavailable,
)

__all__ = ["SANDBOX_EXEC", "KEYCHAIN_SERVICES", "SeatbeltProvider", "build_profile", "canonical_roots"]

#: 绝对路径，不走 PATH 查找 —— PATH 是可被污染的输入。
SANDBOX_EXEC = "/usr/bin/sandbox-exec"

#: Seatbelt 拒绝一次文件效果时 stderr 的样子。它把拒绝报成 EPERM，
#: 所以中英文环境下都是 "Operation not permitted"（errno 1 的标准文案）。
_DENIAL_SIGNATURES: tuple[str, ...] = (
    "operation not permitted",
    "errno 1",
)

#: 命中 EPERM 文案、但与 agent 无关的已知良性行。
#:
#: macOS 的 `/usr/bin/git` 是 xcrun 转发器，每次调用都想往**系统级**的
#: `/var/folders/…/T/xcrun_db-*` 写一份工具查找缓存 —— 那在项目外，被写白名单
#: 正确地拦住了。实测过 `XCRUN_NO_CACHE` / `XCRUN_CACHE_ENABLED` / `DEVELOPER_DIR`
#: 三个变量都关不掉它，而 git 本身功能完全正常（status / commit / log 都成）。
#:
#: **刻意不为它在写白名单上开口子**：那等于为了消一行噪音，放弃「项目外一律
#: 写不进去」这个绝对承诺。代价只是每次 git 调用重新解析一次工具路径（几毫秒）。
_INFORMATIONAL_DENIALS: tuple[str, ...] = ("xcrun_db",)

#: 「沙箱自己没起来」的证据：`sandbox-exec` 把自己的诊断都加上程序名前缀，
#: 退出码固定 65（EX_DATAERR）—— 实测过坏 profile 与 profile 不存在两种情况。
_RUNNER_FAILURE_RULES: tuple[RunnerFailureRule, ...] = (
    RunnerFailureRule(
        fatal_signatures=("sandbox-exec:",),
        allowed_exit_codes=(65,),
    ),
)

#: 钥匙串的系统服务（macOS 上 `launchctl print` 查到的名字）：
#: 旧式文件钥匙串 · 系统钥匙串 · 数据保护钥匙串（含 iCloud 钥匙串）· 弹解锁框的 SecurityAgent。
KEYCHAIN_SERVICES: tuple[str, ...] = (
    "com.apple.SecurityServer",
    "com.apple.securityd",
    "com.apple.securityd.xpc",
    "com.apple.security.agent",
)

#: 硬链接审计最多看多少个条目。克隆下来的仓库动辄上万文件，不设上限的话
#: 每执行一条命令就要走一遍全树。走不完就如实报 partial，不假装看过。
_AUDIT_LIMIT = 20000


def _sbpl_string(path: str) -> str:
    """按 SBPL 字符串字面量转义。"""
    return '"' + path.replace("\\", "\\\\").replace('"', '\\"') + '"'


def canonical_roots(paths: tuple[Path, ...] | list[Path]) -> list[str]:
    """规范化 + 去重，保持原顺序。

    必须先解析符号链接再交给 SBPL：macOS 上 `/tmp` 是指向 `/private/tmp` 的
    符号链接，直接把 `/tmp/x` 写进 `(subpath …)` 的话，进程实际跑在
    `/private/tmp/x`，规则**一条都匹配不上而且不会报错** —— 边界看起来配了，
    其实完全没生效。这与 `projects/workspace.py` 用 `Path.resolve()` 是同一个理由。
    """
    seen: dict[str, None] = {}
    for path in paths:
        seen.setdefault(str(Path(path).expanduser().resolve()), None)
    return list(seen)


def build_profile(policy: SandboxPolicy) -> str:
    """把策略翻成 SBPL 文本。**纯函数**，不碰文件系统之外的任何东西。

    单独抽出来是为了让测试能直接盯住生成结果，不必真的起进程 ——
    起进程那一层另有测试，两层都要覆盖。
    """
    forms: list[str] = [
        "(version 1)",
        "(allow default)",
        # **先一律拒掉**。开放时在后面补一条针孔 —— SBPL 后写覆盖先写，
        # 所以顺序不能反：这一条必须在针孔之前。
        "(deny network*)",
        # 挡住 agent 自己造硬链接逃逸口，理由见模块说明。
        "(deny file-link)",
        # **钥匙串的系统服务一个都连不上**。沙箱里没有一个工具需要用户的钥匙串，
        # 而连得上就意味着 `git credential-osxkeychain get` / `security find-*` 能替 agent 把
        # 用户存过的令牌取出来 —— 那不经过任何文件，拒读 home 拦不住它。
        # `security.agent` 是弹解锁框的那一个：连不上它，沙箱里的进程就弹不出框来吓用户。
        # **trustd 不在里面**：TLS 证书校验要它，实测拦掉这四个之后 curl / git / pip 照常。
        "(deny mach-lookup " + " ".join(
            f"(global-name {_sbpl_string(name)})" for name in KEYCHAIN_SERVICES) + ")",
        "(deny file-write*)",
    ]

    # 网络：**不是"给网"，是开一个针孔。**
    #
    # 只放行一个回环端口，别的地方一个 socket 都连不出去。域名策略与记账由
    # 那个端口后面的本地代理做 —— Seatbelt 看不见主机名，只看得见 ip:port，
    # 想按域名管就只能分两层。
    #
    # **绝不能写成 `localhost:*`。** 本机回环上还坐着 Scivane 自己的 API
    # （没有鉴权，`/llm/providers/{id}/credential` 会把 key 注入后端内存）
    # 与 llama-server。放开整个回环等于把 key 递给 agent。
    if policy.network.enabled:
        forms.append(
            f'(allow network-outbound (remote ip "localhost:{policy.network.proxy_port}"))'
        )

    sinks = " ".join(f"(literal {_sbpl_string(p)})" for p in REQUIRED_WRITE_SINKS)
    forms.append(f"(allow file-write* {sinks})")

    if policy.mode == "workspace-write":
        roots = canonical_roots(policy.files.allow_write or (policy.workspace_root,))
        if roots:
            grants = " ".join(f"(subpath {_sbpl_string(r)})" for r in roots)
            forms.append(f"(allow file-write* {grants})")

        carve = canonical_roots(policy.files.deny_write)
        if carve:
            denies = " ".join(f"(subpath {_sbpl_string(r)})" for r in carve)
            forms.append(f"(deny file-write* {denies})")

    # 读：**最具体的那条说了算**。`read_rules()` 已经按层数从浅到深排好，SBPL 后写覆盖先写，
    # 逐条照这个顺序写出去就是「更深的那条优先」—— home 拒掉、项目根开回、`.lumen/` 再拒回去。
    rules = policy.files.read_rules()
    for root, allow in rules:
        verb = "allow" if allow else "deny"
        forms.append(f"({verb} file-read* (subpath {_sbpl_string(str(root))}))")

    # 开回来的目录若在被拒的区域里，它的**每一级父目录只放行元数据**。实测（2026-09-22）：
    # 不放的话 git 在项目里找仓库时逐级 stat 父目录，直接 `fatal: failed to stat …`（放了之后是
    # 正常的「not a git repository」）；`realpath` / `pwd` / Python 的 `getcwd` 倒不受影响。
    # 目录内容（readdir）照旧拒 —— `ls ~` 仍然被拒。
    denied = [root for root, allow in rules if not allow]
    ancestors: dict[str, None] = {}
    for root, allow in rules:
        if not allow or not any(root != d and root.is_relative_to(d) for d in denied):
            continue
        for parent in root.parents:
            ancestors.setdefault(str(parent), None)
    if ancestors:
        forms.append(
            "(allow file-read-metadata "
            + " ".join(f"(literal {_sbpl_string(a)})" for a in sorted(ancestors)) + ")"
        )

    return "\n".join(forms) + "\n"


def audit_hardlinks(policy: SandboxPolicy, limit: int = _AUDIT_LIMIT) -> tuple[bool, str]:
    """扫可写区域里有没有"已存在的硬链接"，那是路径边界堵不住的口子。

    :returns: ``(完整, 说明)``。完整为 False 时说明里写清是哪几个文件 ——
        原样报给上层，不要吞掉。
    """
    if policy.mode != "workspace-write":
        return True, ""

    roots = canonical_roots(policy.files.allow_write or (policy.workspace_root,))
    skip = set(canonical_roots(policy.files.deny_write))
    found: list[str] = []
    seen = 0

    for root in roots:
        stack = [root]
        while stack:
            current = stack.pop()
            if current in skip:
                continue
            try:
                entries = list(os.scandir(current))
            except (NotADirectoryError, PermissionError, FileNotFoundError):
                continue
            for entry in entries:
                seen += 1
                if seen > limit:
                    return False, f"硬链接审计未跑完：可写区域超过 {limit} 个条目，剩下的没看"
                try:
                    if entry.is_dir(follow_symlinks=False):
                        if entry.path not in skip:
                            stack.append(entry.path)
                    elif entry.is_file(follow_symlinks=False):
                        if entry.stat(follow_symlinks=False).st_nlink > 1 and len(found) < 3:
                            found.append(entry.path)
                except OSError:
                    continue

    if found:
        listed = "、".join(found)
        return False, (
            f"可写区域内存在硬链接（{listed}）—— SBPL 按路径判定，"
            "经硬链接写入会落到项目外的同一个 inode 上"
        )
    return True, ""


class SeatbeltProvider(SandboxProvider):
    """用 `sandbox-exec -f <profile> <argv>` 包住调用方的 argv。

    **无状态。** 策略完全由 `confine()` 的参数决定，同一个实例可以被两个消费者
    在同一时刻用不同的边界调用而互不影响 —— 这条是 `SandboxPolicy` 按调用携带
    的直接后果，也有测试钉着。
    """

    name = "seatbelt"

    def __init__(
        self,
        *,
        profile_dir: Path | None = None,
        audit_limit: int = _AUDIT_LIMIT,
        sandbox_exec: str = SANDBOX_EXEC,
    ) -> None:
        self._profile_dir = profile_dir
        self._audit_limit = audit_limit
        self._sandbox_exec = sandbox_exec

    def available(self) -> bool:
        return os.path.isfile(self._sandbox_exec) and os.access(self._sandbox_exec, os.X_OK)

    def confine(
        self, argv: tuple[str, ...] | list[str], policy: SandboxPolicy
    ) -> ConfinedCommand:
        if not argv:
            raise ValueError("argv 不能为空")
        if not self.available():
            raise SandboxUnavailable(
                f"这台机器上没有可用的沙箱后端：{self._sandbox_exec} 不存在或不可执行。"
                "拒绝执行 —— 不受约束地跑等于没有边界。"
            )

        profile = build_profile(policy)
        path = self._write_profile(profile)
        complete, reason = audit_hardlinks(policy, self._audit_limit)

        return ConfinedCommand(
            argv=(self._sandbox_exec, "-f", str(path), *argv),
            enforcement="full" if complete else "partial",
            enforcement_reason=reason,
            denial_signatures=_DENIAL_SIGNATURES,
            informational_denials=_INFORMATIONAL_DENIALS,
            runner_failure_rules=_RUNNER_FAILURE_RULES,
            profile=profile,
            _cleanup=lambda: shutil.rmtree(path.parent, ignore_errors=True),
        )

    def _write_profile(self, profile: str) -> Path:
        """落盘成 .sb 文件。

        用文件而不是 `-p` 内联：策略文本里全是绝对路径，进程列表里摊开既难读
        又把项目路径暴露给同机的其它进程；落盘之后排障时还能直接看这次到底
        用了什么边界。目录权限 0700，执行完就整个删掉。
        """
        if self._profile_dir is not None:
            self._profile_dir.mkdir(parents=True, exist_ok=True)
        holder = Path(tempfile.mkdtemp(prefix="sandbox-", dir=self._profile_dir))
        holder.chmod(0o700)
        path = holder / "policy.sb"
        path.write_text(profile, encoding="utf-8")
        path.chmod(0o600)
        return path
