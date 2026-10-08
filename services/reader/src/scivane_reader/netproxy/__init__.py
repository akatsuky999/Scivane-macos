"""Local audit proxy: the agent can reach the network, and every connection leaves a record.

Separate from sandbox/ because it knows about agents (attribution per tool call, hosts surfaced
in the UI), while the sandbox layer has to stay replaceable.

grants        who may use the proxy (per-call credentials)
destinations  where it may connect
server        the connections themselves (no MITM, byte counts only)
audit         what is recorded: host, port, method, bytes; never paths or query strings
access        the narrow slice the tool layer sees
"""

from .access import REASONS, CallNetwork, NetworkAccess, Refusal
from .audit import AuditLog, Entry, NetworkRecord
from .destinations import ForbiddenDestination, resolve, why_forbidden
from .grants import Grant, GrantBook
from .server import AuditProxy

__all__ = [
    "CallNetwork", "NetworkAccess", "Refusal", "REASONS",
    "AuditLog", "Entry", "NetworkRecord",
    "ForbiddenDestination", "resolve", "why_forbidden",
    "Grant", "GrantBook",
    "AuditProxy",
]
