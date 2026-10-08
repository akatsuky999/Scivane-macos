"""Local OCR component: what it is, where it lives, whether it is complete.

OCR is optional. Without it projects, reading and cloud Q&A still work and `reocr` is not
registered. COMPONENTS is the single source of truth for paths, sizes and hashes.

Discovery order, first complete tier wins:

    override   SCIVANE_RUNTIME_ROOT        when set, the only place searched
    component  ~/.scivane/runtime/ocr      installed or migrated by the app
    legacy     SCIVANE_LEGACY_RUNTIME_DIR  only when set; can be migrated

CLI: python -m scivane_reader.runtime {shell|status|migrate|install}
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

#: Bump when runtime.json changes shape; components already installed must stay readable.
SCHEMA = "scivane.ocr/1"
#: Identity of this component build; status reports older ones as outdated.
BUNDLE = "paddleocr-vl-1.6+llama-b10852+paddle-3.3.1"

COMPONENT = "component"
LEGACY = "legacy"


@dataclass(frozen=True)
class Artifact:
    """A fixed-content file, verified on install and on migration."""

    path: str  # relative to its item; empty means the item itself is the file
    size: int
    sha256: str
    url: str = ""


@dataclass(frozen=True)
class Component:
    key: str
    label: str
    #: layout -> location relative to the root; "$PADDLEX/" paths are relative to PADDLEX_CACHE_DIR
    paths: Mapping[str, str]
    #: layout -> file whose presence marks the item installed; defaults to the location itself
    probe: Mapping[str, str] = field(default_factory=dict)
    executable: bool = False
    artifacts: tuple[Artifact, ...] = ()
    #: archive fetched on install; its contents are not verified file by file
    archive: Artifact | None = None
    note: str = ""
    #: English UI names; label and note stay Chinese for CLI output and logs.
    label_en: str = ""
    note_en: str = ""

    @property
    def display_label(self) -> str:
        return ui(self.label, self.label_en or self.label)

    @property
    def display_note(self) -> str:
        return ui(self.note, self.note_en or self.note)


_HF = "https://huggingface.co/PaddlePaddle"

# Sizes and sha256 were checked byte for byte against upstream
# (HuggingFace LFS hashes, GitHub release digests).
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
    """One discovery tier: a root directory read with a given layout."""

    tier: str  # "override" | "component" | "legacy"
    root: Path
    layout: str  # COMPONENT | LEGACY

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
        """Parsed runtime.json, or None (legacy layout, or unreadable)."""
        try:
            data = json.loads((self.root / "runtime.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) else None

    def problem(self) -> str | None:
        """Why this tier is unusable, or None."""
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
        """Legacy layout: the venv holding the OCR dependencies."""
        return self.location(component("python")) if self.layout == LEGACY else None

    @property
    def site(self) -> Path | None:
        """Component layout: OCR dependencies, appended to PYTHONPATH in full mode."""
        return self.location(component("python")) if self.layout == COMPONENT else None


def _layout_of(root: Path) -> str:
    return COMPONENT if (root / "runtime.json").is_file() else LEGACY


def candidates() -> tuple[Candidate, ...]:
    """Tiers in priority order, recomputed on every call so a fresh install shows up without a restart."""
    if config.RUNTIME_OVERRIDE is not None:
        root = config.RUNTIME_OVERRIDE
        return (Candidate("override", root, _layout_of(root)),)
    tiers = [Candidate("component", config.OCR_COMPONENT_DIR, COMPONENT)]
    # No setting means no legacy tier, rather than reporting a missing directory.
    if config.LEGACY_RUNTIME_DIR is not None:
        tiers.append(Candidate("legacy", config.LEGACY_RUNTIME_DIR, LEGACY))
    return tuple(tiers)


def resolve() -> Candidate | None:
    return next((c for c in candidates() if c.usable), None)


def available() -> bool:
    return resolve() is not None


def preflight() -> list[str]:
    """Why OCR is unavailable; empty when usable. Checked up front instead of failing mid-recognition."""
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
        # Offer one-click migration only while the legacy tier is the active one.
        "migratable": active is not None and active.tier == "legacy",
        "candidates": listed,
    }


def describe() -> str:
    active = resolve()
    if active is None:
        return "ocr=未安装"
    return f"ocr={active.tier}:{active.root}"



def _shell() -> str:
    """Assignments for start_backend.sh to eval; every value is shlex-quoted."""
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
