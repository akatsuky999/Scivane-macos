"""界面语言：**给人看的字**用哪一种说。

App 的每个请求都带着 ``X-Scivane-Language``（``zh`` / ``en``）。`api/app.py` 的中间件
把它放进一个 ContextVar，给人看的文字写成 ``ui("中文", "English")``，按这一次请求
挑一种。**默认中文** —— 命令行、验证脚本、不带这个头的老客户端，看到的与从前逐字相同。

**给模型看的字不跟着它变**。提示词、工具描述、工具结果、历史收小
留下的说明都是模型的输入：跟着界面换语言，同一段历史在两种界面里就是两份不同的前缀，
缓存接不上，模型的行为也会跟着一个界面设置漂。所以：

- 这里只给**人**用：界面上的工具摘要、报错、安装步骤、状态说明；
- **工具执行期间语言钉成中文**（`tools/scheduler.py`）—— 工具里用到的共用报错
  （比如项目层的 `ProjectError`）即便写成了 ``ui()``，进到工具结果里的也永远是中文。
  这是结构上的保证，不靠每个写报错的人记得分清「这句会不会被模型读到」。

ContextVar 怎么跟到别处：``asyncio.create_task`` 与 ``asyncio.to_thread`` 会复制当前
上下文；**自己起的线程不会** —— 起线程的地方用 ``contextvars.copy_context().run``
包一层（`api/routes.py` 的识别与安装）。
"""

from __future__ import annotations

import contextlib
from contextvars import ContextVar
from typing import Iterator

__all__ = ["HEADER", "LANGUAGES", "DEFAULT", "parse", "current", "ui", "speaking"]

#: App 在每个请求上带的头。**不用 Accept-Language**：URLSession 会按系统偏好自己
#: 加一个，和设置里选的那一种可以不一样 —— 界面语言要由 App 明说，不能靠猜。
HEADER = "X-Scivane-Language"
LANGUAGES = ("zh", "en")
DEFAULT = "zh"

_language: ContextVar[str] = ContextVar("scivane_ui_language", default=DEFAULT)


def parse(value: str | None) -> str:
    """请求头的值 → ``zh`` / ``en``。

    宽进：``en-US``、``EN`` 都算英文；认不出来的一律回到默认的中文 ——
    一个拼错的头不该让界面变成第三种样子。
    """
    if value and value.strip().lower().startswith("en"):
        return "en"
    return DEFAULT


def current() -> str:
    """这一次请求的界面语言。"""
    return _language.get()


def ui(zh: str, en: str) -> str:
    """一句给人看的话的两种说法，按这一次请求的界面语言挑一种。

    **两种都必须写全。** 只写中文的话英文界面里就夹着中文；
    写成 ``ui(s, s)`` 的地方说明那句话本来就不分语言（路径、代号）。
    """
    return en if _language.get() == "en" else zh


@contextlib.contextmanager
def speaking(language: str) -> Iterator[None]:
    """在这一段里用某一种界面语言说话，出来之后恢复原样。

    中间件用它套住整个请求；调度器用 ``speaking("zh")`` 套住工具执行。
    """
    token = _language.set(language if language in LANGUAGES else parse(language))
    try:
        yield
    finally:
        _language.reset(token)
