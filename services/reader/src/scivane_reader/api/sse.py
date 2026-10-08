"""SSE event names and encoding. Event names are a contract with the Swift client."""

from __future__ import annotations

import json
from typing import Final


class Event:
    META: Final = "meta"            # once at start: job_id, page count, file name
    PROGRESS: Final = "progress"    # page N started
    PAGE: Final = "page"            # page N result
    HEARTBEAT: Final = "heartbeat"  # every 5 s
    DONE: Final = "done"            # all pages, with the restructured Markdown
    ERROR: Final = "error"          # failure with a readable reason


class LlmEvent:
    """Event names for the raw model stream (/llm/chat).

    FINISH is the only terminal event, for success and failure alike
    (the terminal-chunk protocol in llm/types.py).
    """

    DELTA: Final = "delta"        # answer text
    THINKING: Final = "thinking"  # reasoning text, when the model provides it
    USAGE: Final = "usage"        # token usage, possibly reported more than once
    FINISH: Final = "finish"      # terminal: kind, optional failure, usage


class AgentEvent:
    """Event names for the agent stream. A contract with the Swift client: a mismatch does not
    error, the UI just waits forever.

    Terminal events are DONE (stop: stop / max_steps / aborted) and ERROR.
    """

    #: a model request begins: step, provider, model
    MESSAGE_START: Final = "message_start"
    #: answer text
    TEXT: Final = "text"
    #: reasoning text, when supported
    THINKING: Final = "thinking"
    #: call_id, name, arguments, human-readable summary
    TOOL_CALL: Final = "tool_call"
    #: call_id, preview, error flag, synthetic flag (filled in after a cancel)
    TOOL_RESULT: Final = "tool_result"
    #: call_id, tool, summary, seconds until it expires
    APPROVAL_REQUEST: Final = "approval_request"
    #: sandbox enforcement was only partial; must reach the UI, not just the log
    ENFORCEMENT: Final = "enforcement"
    #: the agent reached a host through the audit proxy: call_id, host, port, method, allowed,
    #: reason, first. Separate from ENFORCEMENT because networking is normal, not a warning.
    #: Never carries paths or query strings.
    NETWORK: Final = "network"
    #: per-step token usage including cache reads and writes; the turn total is in DONE
    USAGE: Final = "usage"
    #: how full the context is (projects/meter.ContextReport): before each step, after
    #: compaction, and at the end of a turn
    CONTEXT: Final = "context"
    #: phase start/done/failed, trigger auto/overflow/manual; done carries summary, turns,
    #: kept, before, after; failed carries code and message
    COMPACTION: Final = "compaction"
    #: turn finished: stop, steps, exhausted, full answer text
    DONE: Final = "done"
    #: turn failed: stable code and a readable reason, never credentials
    ERROR: Final = "error"
    #: every 5 s
    HEARTBEAT: Final = "heartbeat"


class RuntimeEvent:
    """Event names for the OCR install stream (POST /runtime/install). A Swift contract.

    Terminal events are DONE and ERROR; cancellation is ERROR with code=CANCELLED.
    """

    #: once at start: job_id, method (download / migrate)
    META: Final = "meta"
    #: step N begins: index, total, key, label
    STEP: Final = "step"
    #: progress within a step, about 4 per second: key, done, total, source
    PROGRESS: Final = "progress"
    #: switched download source: key, from, to, reason
    SOURCE: Final = "source"
    #: one line of detail (verification, pip)
    LOG: Final = "log"
    #: installed: root, tier, elapsed
    DONE: Final = "done"
    #: failed: stable code (DISK_FULL, DOWNLOAD_FAILED, DEPS_FAILED, CANCELLED...) and a reason
    ERROR: Final = "error"
    #: every 5 s: elapsed
    HEARTBEAT: Final = "heartbeat"


# internal: tells the stream to close; never sent to the client
EOF_SENTINEL: Final = "__eof__"

# Dense pages can take over ten seconds. Heartbeats keep idle timeouts from killing the
# connection and keep the elapsed timer moving.
HEARTBEAT_SECONDS: Final = 5.0


def encode(event: str, payload: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"
