"""SSE 事件的编码与名字。

事件名是 App 和服务端之间的契约，改名字要同步改 OCRClient.swift。
"""

from __future__ import annotations

import json
from typing import Final


class Event:
    META: Final = "meta"            # 开头一次：job_id、总页数、文件名
    PROGRESS: Final = "progress"    # 开始处理第 N 页
    PAGE: Final = "page"            # 第 N 页出结果
    HEARTBEAT: Final = "heartbeat"  # 5 秒一次，见下方说明
    DONE: Final = "done"            # 全部完成，带整理后的完整 Markdown
    ERROR: Final = "error"          # 失败，带可读原因


class LlmEvent:
    """大模型问答流的事件名。

    与 OCR 那套分开命名，因为两条链路的语义完全不同：OCR 是「一份文档逐页
    出结果」，问答是「一次回答逐 token 出内容」。共用事件名会让客户端难以
    分辨自己在听哪条流。

    终态只有 FINISH 一个 —— 正常结束与失败走同一个出口，客户端不必分别处理
    「流结束了」和「流出错了」两种收尾。这条契约来自 llm/types.py 的
    终止分片协议，改这里必须同步改那边。
    """

    DELTA: Final = "delta"          # 正文增量
    THINKING: Final = "thinking"    # 推理过程增量（支持的模型才有）
    USAGE: Final = "usage"          # token 用量上报，可能多次
    FINISH: Final = "finish"        # 唯一终态：kind + 可选 failure + 用量


class AgentEvent:
    """**agent 对话流的事件名 —— 跨语言契约，定下之后不要改。**

    这是 App 与服务端之间的契约：改这里必须同步改
    Swift 侧的客户端。对不上的表现不是报错，而是界面永远停在等待，
    所以命名一次定死。

    与 `LlmEvent` 分开命名：那一套是「裸的模型问答流」（`/llm/chat`，
    给命令行调试用），这一套是「agent 在项目里干活」，多出工具、批准、
    沙箱强度三类语义。共用名字会让客户端分不清自己在听哪条流。

    终态是 DONE 与 ERROR 两个，而不是 LlmEvent 那样只有一个 FINISH ——
    理由是 agent 一轮里可能既成功产出了内容又在某个工具上失败，客户端要能
    区分「整轮走完了」和「整轮没走完」。`DONE` 里带 stop 字段说明怎么停的
    （stop / max_steps / aborted）。
    """

    #: 一轮（一次模型请求）开始：step、provider、model
    MESSAGE_START: Final = "message_start"
    #: 正文增量
    TEXT: Final = "text"
    #: 推理过程增量（支持的模型才有）
    THINKING: Final = "thinking"
    #: 模型要调工具：call_id、name、arguments、人类可读摘要
    TOOL_CALL: Final = "tool_call"
    #: 工具结果：call_id、预览、是否出错、**是否是取消后补的合成结果**
    TOOL_RESULT: Final = "tool_result"
    #: 需要用户批准：call_id、tool、summary、还有多少秒过期
    APPROVAL_REQUEST: Final = "approval_request"
    #: 沙箱执行强度不足（partial）。**这是可报告的事实，必须冒到界面上**，
    #: 否则它只报告给了日志。
    ENFORCEMENT: Final = "enforcement"
    #: agent 经审计代理到达了一个主机：call_id、host、port、method、
    #: allowed、reason、**first**（这次调用的第一个主机，界面据此出一张显眼的卡）。
    #:
    #: **刻意不复用 ENFORCEMENT。** 那个事件的含义是「边界没兑现承诺」，
    #: 是一条警告；而 agent 联网是**正常行为**。混在一起等于给正常行为挂上
    #: 琥珀色警告，看几次之后两种都没人看了（狼来了喊多了）。
    #: **绝不带路径与查询串** —— 查询串是凭据最常见的藏身处。
    NETWORK: Final = "network"
    #: token 用量，含缓存命中与写入。缓存是否生效是本产品最关心的指标。
    USAGE: Final = "usage"
    #: 整轮结束：stop、steps、exhausted、完整回答文本
    DONE: Final = "done"
    #: 整轮失败：稳定 code + 可读原因（**绝不含凭据**）
    ERROR: Final = "error"
    #: 5 秒一次，同 OCR 那条链路的理由
    HEARTBEAT: Final = "heartbeat"


class RuntimeEvent:
    """**安装本地 OCR 组件那条流的事件名 —— 跨语言契约，定下之后不要改。**

    `POST /runtime/install`。与 `AgentEvent` 分开：那一套是「agent 在项目里干活」，
    这一套是「装一个 2 GB 的组件」，语义没有交集，共用名字只会让客户端分不清
    自己在听哪条流（同 `AgentEvent` 与 `LlmEvent` 分开的理由）。
    终态同样是 DONE 与 ERROR 两个；取消是 ERROR 里 code=CANCELLED。
    """

    #: 开头一次：job_id、method（download / migrate）
    META: Final = "meta"
    #: 进入第 N 步：index、total、key、label
    STEP: Final = "step"
    #: 一步里的进度（节流到每秒约 4 次）：key、done、total、source；pip 那一步的单位是「包」
    PROGRESS: Final = "progress"
    #: **换了下载来源**：key、from、to、reason。上游不通或太慢换镜像时发，界面要让人看得见
    SOURCE: Final = "source"
    #: 一行说明（校验、pip 的进展），界面可以折起来
    LOG: Final = "log"
    #: 装好了：root、tier、elapsed
    DONE: Final = "done"
    #: 没装成：稳定 code（DISK_FULL / DOWNLOAD_FAILED / DEPS_FAILED / CANCELLED …）+ 可读原因
    ERROR: Final = "error"
    #: 5 秒一次：elapsed
    HEARTBEAT: Final = "heartbeat"


# worker 线程用它通知流该收尾了，不发给客户端
EOF_SENTINEL: Final = "__eof__"

# 密集版面的单页可能要跑十几秒。定时发心跳，一是让客户端的空闲超时不会
# 误杀连接，二是界面上的已用时间能一直在走。
HEARTBEAT_SECONDS: Final = 5.0


def encode(event: str, payload: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"
