"""Cloud transcription: a vision model reads each page of a document into Markdown.

    pages     page image, PDF text layer, figure regions and crops (pymupdf, no model)
    prompt    the fixed system prompt and the per-page message
    stitch    page answers into one paper: figures, footnotes, page breaks, heading levels
    harness   requests in flight, checks and retries, cancellation

Depends on llm/ for the model vocabulary only; the call itself is passed in. Knows nothing about
projects: the caller decides where the Markdown and the figure crops go.
"""

from .harness import FATAL, PageDone, Transcript, TranscriptionError, transcribe
from .pages import count as page_count

__all__ = ["transcribe", "Transcript", "PageDone", "TranscriptionError", "FATAL", "page_count"]
