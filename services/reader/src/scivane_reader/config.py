"""集中配置：项目路径、运行时路径、端口、识别参数。

改这里就够，不要散落到别处。所有值都可以用环境变量覆盖，
变量名统一以 SCIVANE_ 开头，和 scripts/start_backend.sh 里的一致。
"""

from __future__ import annotations

import os
import pwd
from pathlib import Path

from . import paths

__all__ = [
    "SOURCE_ROOT",
    "LLAMA_HOST", "LLAMA_PORT", "LLAMA_BASE_URL", "API_HOST", "API_PORT",
    "VAR_DIR", "LOGS_DIR", "JOBS_DIR", "RUN_DIR", "PID_FILE",
    "PIPELINE_VERSION", "LAYOUT_DEVICE", "VL_BACKEND",
    "VL_MAX_CONCURRENCY", "LLAMA_CTX_SIZE",
    "LLM_PROVIDERS_PATH", "LLM_CONNECT_TIMEOUT", "LLM_FIRST_TOKEN_TIMEOUT",
    "LLM_TOTAL_TIMEOUT", "LLM_MAX_RETRIES", "LLM_CONCURRENCY", "LLM_KEEPALIVE",
    "TIMING", "TIMING_LOG",
    "PROJECTS_DIR",
    "AGENT_RUNTIME_DIR", "ANALYSIS_ENV_DIR", "PYTHON_DIR", "SANDBOX_DIR", "SANDBOX_HOOKS_DIR",
    "RUNTIME_OVERRIDE", "OCR_COMPONENT_DIR", "LEGACY_RUNTIME_DIR", "PADDLEX_CACHE_DIR",
    "OCR_HF_MIRRORS", "OCR_PYPI_INDEXES", "DOWNLOADS_DIR", "PIP_CACHE_DIR",
    "SANDBOX_TIMEOUT", "SANDBOX_DENY_READ", "USER_HOME", "SANDBOX_PRIVATE_ROOTS",
    "NETPROXY_CONNECT_TIMEOUT", "NETPROXY_IDLE_TIMEOUT", "NETPROXY_AUDIT_LIMIT",
]


#: 仓库根。**打包安装时是 None** —— 只用来判断开发模式，不参与任何产物定位。
SOURCE_ROOT = paths.SOURCE_ROOT

# --- 端口 ---------------------------------------------------------------
# llama-server（VLM 识别，Metal 加速）
LLAMA_HOST = os.environ.get("SCIVANE_LLAMA_HOST", "127.0.0.1")
LLAMA_PORT = int(os.environ.get("SCIVANE_LLAMA_PORT", "8111"))
LLAMA_BASE_URL = f"http://{LLAMA_HOST}:{LLAMA_PORT}/v1"

# FastAPI 编排层（App 直接对话的对象）
API_HOST = os.environ.get("SCIVANE_API_HOST", "127.0.0.1")
API_PORT = int(os.environ.get("SCIVANE_API_PORT", "8710"))

# --- 运行期产物 ----------------------------------------------------------
# 日志、pidfile、OCR 抠图、沙箱策略 —— 「整个删掉也不影响代码」的那一类。
#
# **在用户目录下，不在源码树里。** 从前它是 `<仓库>/var`，于是：
# 打包安装的机器上根本没有仓库；从源码跑时 agent 的沙箱策略会写进你的工作副本；
# 而 `PROJECT_ROOT` 认不出仓库时还会安静地落到 cwd（见 paths.py）。
# 三种毛病同一个根因 —— 产物不该跟着代码走。
#
# 与 `~/.scivane/projects` 同族但**性质相反**：那边是不可丢的用户数据，
# 这边整个删掉只会让下次重建。`SCIVANE_VAR_DIR` 仍可覆盖（验证脚本靠它隔离）。
#
# 注意：`var/build` 与 `var/app`（编译中间产物与成品 .app）仍然留在仓库里，
# 由 build_app.sh 与 Makefile 管，Python 这一侧从不引用它们。
VAR_DIR = Path(os.environ.get("SCIVANE_VAR_DIR", "~/.scivane/var")).expanduser()
LOGS_DIR = VAR_DIR / "logs"
RUN_DIR = VAR_DIR / "run"
PID_FILE = RUN_DIR / "backend.pids"

# 每个识别任务的抠图产物落在这里，供 WebView 通过 /assets 引用
JOBS_DIR = Path(os.environ.get("SCIVANE_JOBS_DIR", str(VAR_DIR / "jobs")))

# --- 识别参数 -----------------------------------------------------------
PIPELINE_VERSION = os.environ.get("SCIVANE_PIPELINE_VERSION", "v1.6")
# macOS 上 PaddlePaddle 无 Metal 后端，版面分析只能走 CPU。
# GPU 加速发生在 llama-server 那一层。
LAYOUT_DEVICE = os.environ.get("SCIVANE_LAYOUT_DEVICE", "cpu")
VL_BACKEND = os.environ.get("SCIVANE_VL_BACKEND", "llama-cpp-server")
# llama-server 默认开 4 个 slot，可以并行跑 4 个请求。
# 密集排版的论文一页能切出几十个元素，串行发只能吃到 1/4 的算力。
# 这个值要和 start_backend.sh 里 llama-server 的 slot 数保持一致。
VL_MAX_CONCURRENCY = int(os.environ.get("SCIVANE_VL_CONCURRENCY", "4"))

# 上下文不足会导致输出截断或重复字符，这个值不要往下调。
LLAMA_CTX_SIZE = int(os.environ.get("SCIVANE_LLAMA_CTX", "16384"))


# --- 大模型接入 ----------------------------------------------------------
# 这一层与上面的本地 OCR 引擎彼此独立：读论文时本地负责把 PDF 变成 Markdown，
# 云端负责在这份 Markdown 之上理解与推理。云端问答不需要加载 OCR 模型。

# provider 配置（协议、base_url、模型）。凭据不在这个文件里 —— 见 llm/credentials.py。
LLM_PROVIDERS_PATH = Path(
    os.environ.get("SCIVANE_LLM_PROVIDERS_PATH", "~/.scivane/providers.json")
).expanduser()

# 三段分离的超时。用单一总超时是不行的：能容纳长回答的总超时，
# 会让一次 DNS 故障也要等同样久才报错。
LLM_CONNECT_TIMEOUT = float(os.environ.get("SCIVANE_LLM_CONNECT_TIMEOUT", "10"))
LLM_FIRST_TOKEN_TIMEOUT = float(os.environ.get("SCIVANE_LLM_FIRST_TOKEN_TIMEOUT", "120"))
LLM_TOTAL_TIMEOUT = float(os.environ.get("SCIVANE_LLM_TOTAL_TIMEOUT", "1800"))

LLM_MAX_RETRIES = int(os.environ.get("SCIVANE_LLM_MAX_RETRIES", "5"))
# 同时在飞的请求上限，防止批量任务把厂商配额打爆。
LLM_CONCURRENCY = int(os.environ.get("SCIVANE_LLM_CONCURRENCY", "4"))
# 到厂商的空闲连接留多久（秒）。**不是 httpx 默认的 5 秒** —— 那个值让每一问之间的连接都断掉：
# 用户读完回答再问，下一问要重新握手、再把二三十万字节的请求体从 TCP 慢启动开始传上去，
# 实测每问多 2.5–6.5 秒（M5/16GB 到 OpenRouter 实测）。
# 同一条连接空闲 240 秒后服务端仍然接着用，所以取 300。
LLM_KEEPALIVE = float(os.environ.get("SCIVANE_LLM_KEEPALIVE", "300"))

# 分段计时（`llm/timing.py`）：每一轮把「时间花在哪一段」写进 logs/timing.jsonl。
# **默认关**；排查「对话慢」时打开。只记时刻与计数，不记内容与凭据。
TIMING = os.environ.get("SCIVANE_TIMING", "") == "1"
TIMING_LOG = LOGS_DIR / "timing.jsonl"


# --- 项目 ----------------------------------------------------------------
# 一个 PDF 就是一个项目：原稿副本、作为静态上下文的正文、会话历史。
#
# 刻意不放在 var/ 下：var/ 在本项目的文档里被定义为「整个删掉也不影响代码」，
# make clean 会清里面的东西。对话历史不是可丢弃的运行期产物。
PROJECTS_DIR = Path(
    os.environ.get("SCIVANE_PROJECTS_DIR", "~/.scivane/projects")
).expanduser()


# --- 沙箱与执行 ----------------------------------------------------------
# agent 在项目目录里跑命令时用到的东西。

# 运行时的家：自带解释器（python/）、共享分析环境（analysis/）、本地 OCR 组件（ocr/）
# 都住在这下面，删了都会重建。**python/ 与 analysis/ 在沙箱里必须读得到** —— 它们在被拒读的
# home 里，由 `workspace.sandbox_policy()` 显式开回来（见下面 SANDBOX_PRIVATE_ROOTS）。
AGENT_RUNTIME_DIR = Path(
    os.environ.get("SCIVANE_AGENT_RUNTIME_DIR", "~/.scivane/runtime")
).expanduser()

# 共享分析环境：matplotlib / pandas / numpy 这类画图与数据处理的常用库，
# 所有项目共用，装一次。论文代码需要独立依赖时才在项目内按需建 venv ——
# 不同论文的依赖必然互相冲突，那是唯一干净的解法。
ANALYSIS_ENV_DIR = AGENT_RUNTIME_DIR / "analysis"

# App 自带的解释器首次启动时从 .app 拷到这里（start_backend.sh 的 stage_python，
# 算好之后经 SCIVANE_AGENT_RUNTIME_DIR 传过来，两边是同一个值）。
PYTHON_DIR = AGENT_RUNTIME_DIR / "python"


# --- 本地 OCR（可选组件）---------------------------------------------------
# 没装 OCR 时项目管理、阅读、云端问答照常；它在哪由 runtime.py 按三档发现。
# 这里只放三档的**位置**（配置只在一处），发现逻辑与组件表在 runtime.py。

#: 第一档：显式覆盖。**设了就只看它** —— 不齐就是不齐，不往下找别的。
RUNTIME_OVERRIDE: Path | None = (
    Path(os.environ["SCIVANE_RUNTIME_ROOT"]).expanduser()
    if os.environ.get("SCIVANE_RUNTIME_ROOT") else None
)
#: 第二档：App 装的（或从旧部署迁来的）组件。带 runtime.json，格式从第一天就带版本号。
OCR_COMPONENT_DIR = AGENT_RUNTIME_DIR / "ocr"
#: 第三档：旧部署 —— 手工搭的模型部署目录（venv + bin + models）。**没有默认位置**：
#: 设了才有这一档，只作为最后一档被发现、报成 legacy，App 可以把它一键迁成组件。
LEGACY_RUNTIME_DIR: Path | None = (
    Path(os.environ["SCIVANE_LEGACY_RUNTIME_DIR"]).expanduser()
    if os.environ.get("SCIVANE_LEGACY_RUNTIME_DIR") else None
)
#: 旧部署的版面模型不在部署目录里，paddlex 把它缓存在用户目录下。
PADDLEX_CACHE_DIR = Path("~/.paddlex").expanduser()


def _list(name: str, default: tuple[str, ...]) -> tuple[str, ...]:
    raw = os.environ.get(name)
    return tuple(x.strip() for x in raw.split(",") if x.strip()) if raw else default


# 下载安装 OCR 组件时的来源：**上游优先，失败或太慢自动换镜像**。
# 每个文件都按组件表的 sha256 校验、Python 依赖按锁文件的哈希装 —— 换来源不影响完整性，
# 只影响装不装得上。国内直连 HuggingFace 往往不通或极慢，这是有镜像这一层的原因。
# GitHub（llama.cpp，11MB）没有官方镜像，只走上游。
#: 替换 https://huggingface.co 的镜像，按顺序试
OCR_HF_MIRRORS = _list("SCIVANE_HF_MIRRORS", ("https://hf-mirror.com",))
#: pip 的索引，第一个是上游，之后是镜像
OCR_PYPI_INDEXES = _list(
    "SCIVANE_PYPI_INDEXES", ("https://pypi.org/simple", "https://pypi.tuna.tsinghua.edu.cn/simple")
)
#: 断点续传的下载缓存与 pip 的 wheel 缓存。装成之后删掉；装到一半断了留着，下次接着下。
DOWNLOADS_DIR = VAR_DIR / "downloads"
PIP_CACHE_DIR = VAR_DIR / "pip-cache"

# 沙箱的运行期产物（.sb 策略文件、给 git 用的空 hooks 目录）。
# 放 var/ 下：这些整个删掉也不影响任何东西，下次执行会重建。
SANDBOX_DIR = Path(os.environ.get("SCIVANE_SANDBOX_DIR", str(RUN_DIR / "sandbox")))
SANDBOX_HOOKS_DIR = SANDBOX_DIR / "empty-hooks"

SANDBOX_TIMEOUT = float(os.environ.get("SCIVANE_SANDBOX_TIMEOUT", "120"))

# 沙箱内一律拒读的路径（除项目自己的 .lumen/ 之外）。
#
# OCR 的三档位置都是「只装不改」的工具，agent 对它们连读权限
# 都不需要 —— 不是论文的一部分，出现在这里只会让 agent 以为自己该去动它。
# 三档**全部**拒读，不管当前用的是哪一档：哪一档都不该出现在 agent 视野里。
#
# **只能是具体的 OCR 目录，绝不能是 AGENT_RUNTIME_DIR 本身** —— 自带解释器（python/）
# 与共享分析环境（analysis/）也住在那下面，agent 的 python 工具必须读得到它们；
# 拒读打宽一级，每次 `python` 调用都会报「二进制起不来」。
SANDBOX_DENY_READ: tuple[Path, ...] = tuple(
    p for p in (RUNTIME_OVERRIDE, OCR_COMPONENT_DIR, LEGACY_RUNTIME_DIR) if p is not None
)

#: 用户真正的 home。**取密码库里的，不取 `$HOME`** —— 启动环境能把 `$HOME` 改掉，
#: 钥匙、令牌和别的项目却还在真 home 里。
USER_HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)

# 沙箱里**整个拒读**的私人区域。
#
# 用户的 home：SSH 钥匙、云服务凭据、各种令牌、浏览器数据、文稿，还有 `~/.scivane/projects/`
# 下**别的项目**与本产品自己的日志，全在这下面。沙箱通网之后，读得到就发得出去 ——
# 审计簿只会留下一个主机名。在它里面开回来的只有 agent 真要读的几处：这个项目的根、
# 自带解释器、共享分析环境、git 的空 hooks 目录（`workspace.sandbox_policy()` 里）。
#
# **没有环境变量能改它**：边界不留开关，与代理的目的地判定同一条规矩 ——
# 留一个开关，它迟早会被当成「跑不通时先关掉试试」。测试直接替换这个模块属性。
SANDBOX_PRIVATE_ROOTS: tuple[Path, ...] = (USER_HOME,)

# --- 本地审计代理 ---------------------------------------------------------
# 沙箱那个针孔后面站着的东西（netproxy/）。**端口不在这里** —— 它由内核在
# 绑定时给（`127.0.0.1:0`），写死端口在别人的机器上会撞。

# 连上游的超时。比命令超时短得多：连不上要尽快让 agent 知道，
# 而不是把一次工具调用的 120 秒全耗在一个不通的主机上。
NETPROXY_CONNECT_TIMEOUT = float(os.environ.get("SCIVANE_NETPROXY_CONNECT_TIMEOUT", "15"))

# 读请求头的超时。防的是「连上来不说话」把连接一直挂着。
NETPROXY_IDLE_TIMEOUT = float(os.environ.get("SCIVANE_NETPROXY_IDLE_TIMEOUT", "30"))

# 审计簿的条数上限，满了丢最旧的。一个跑疯了的循环不该把后端内存吃光。
NETPROXY_AUDIT_LIMIT = int(os.environ.get("SCIVANE_NETPROXY_AUDIT_LIMIT", "2000"))
