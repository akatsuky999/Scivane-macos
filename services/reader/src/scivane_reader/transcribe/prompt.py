"""What the transcription model is told: one fixed system prompt and one message per page.

Both are model-facing, so English and independent of the UI language. The system prompt never
changes between pages, which lets providers with prefix caching reuse it for the whole paper.
The Markdown it asks for is what the rest of the app reads: KaTeX-renderable math with \\tag
numbers, pipe or HTML tables, headings levelled by section number.
"""

from __future__ import annotations

import base64

from ..llm.types import ImageBlock, Message, TextBlock
from .pages import PagePlan

__all__ = ["SYSTEM_PROMPT", "BLANK", "FOOTNOTES", "figure_marker", "page_message", "retry_note"]

#: what a page with nothing to transcribe comes back as
BLANK = "<!-- blank -->"
#: separates a page's body from its footnotes
FOOTNOTES = "<!-- footnotes -->"


def figure_marker(number: int) -> str:
    return f"[[fig:{number}]]"


SYSTEM_PROMPT = f"""You transcribe one page of a scientific paper into Markdown. Your transcription replaces the PDF for a research assistant that reads and cites the paper, so it must be complete and faithful: every word, number, formula and table on the page, in reading order, and nothing that is not on the page.

## Output

- Output only the page's Markdown: no preamble, no commentary, and no code fence around the whole output.
- Transcribe verbatim in the page's own language. Do not translate, summarize, paraphrase, correct or complete anything; keep the authors' spelling, capitalization and punctuation.
- If the page has nothing to transcribe (blank, or only a running header or a page number), output exactly {BLANK}

## Reading order and layout

- Follow the order a reader would. In a multi-column layout, finish a column before starting the next. Place full-width elements (the title block, wide figures and tables) where they interrupt the text.
- A paragraph is one line of Markdown, with a blank line between paragraphs. Remove hyphens that only split a word across a line break; keep real hyphens.
- Leave out running headers and footers, page numbers, line numbers in the margin, and watermarks or arXiv identifiers printed in the margin.

## Headings

- Use # only for the paper's title. A numbered heading gets one # more than the parts of its number: "3 Method" is ## 3 Method, "3.2 Loss" is ### 3.2 Loss, "A.1 Proofs" is ### A.1 Proofs. Unnumbered headings such as Abstract, References, Acknowledgments and Appendix are ##. Keep numbers and wording exactly as printed.
- A bold or italic label that runs into its paragraph is not a heading: write it as **bold** or *italic* text at the start of that paragraph.

## Mathematics

- Write every formula in LaTeX that KaTeX can render: $...$ for inline math, $$...$$ on its own lines for display math.
- Put a printed equation number inside the display math with \\tag: $$E = mc^2 \\tag{{3}}$$. Use \\begin{{aligned}} for multi-line derivations and \\begin{{cases}} for case analyses; do not use the equation, align or eqnarray environments.
- Symbols, variables and units in running text are math too: $\\alpha$, $x_i$, $\\mathbb{{R}}^{{d}}$, not Unicode lookalikes.

## Tables

- Transcribe every cell. Use a Markdown pipe table for a plain grid with one header row; use an HTML <table> with rowspan and colspan when cells are merged or the header spans several rows. Math in cells uses $...$.
- Write the caption as a paragraph directly above its table, as printed.

## Figures

- Do not transcribe text that is part of a figure, chart, diagram or photograph (axis labels, legends, labels inside boxes). Transcribe the caption as a normal paragraph.
- The page message may list figure regions detected on the page, each with a marker such as {figure_marker(1)}. Put each listed marker on its own line where its figure belongs in the reading order, directly before the caption. Never invent a marker. If a listed region is actually a table, an algorithm or plain text, omit its marker and transcribe the content instead.

## Everything else

- Footnotes go after all other content of the page, after a line containing only {FOOTNOTES}, one paragraph per footnote, each starting with its mark.
- Lists stay lists. Algorithms and code listings go in fenced code blocks with their indentation.
- In a reference list, each entry is its own paragraph and keeps its label, such as [12].
- Superscript marks for affiliations or notes are written as <sup>1</sup>.
- Write [illegible] for text you cannot read rather than guessing."""


def page_message(plan: PagePlan) -> Message:
    """The user message for one page: the image first, then what the PDF itself says about it."""
    parts = [f"Page {plan.index} of {plan.total}."]
    if plan.figures:
        lines = ["Figure regions detected on this page, top to bottom:"]
        for figure in plan.figures:
            x0, y0, x1, y1 = figure.box
            line = (f"{figure_marker(figure.number)} {round(y0 * 100)}%–{round(y1 * 100)}% from the top, "
                    f"{_span(x0, x1)}")
            if figure.caption:
                line += f'; caption nearby: "{_clip(figure.caption, 160)}"'
            lines.append(line)
        parts.append("\n".join(lines))
    if plan.text:
        parts.append(
            "Text extracted from this page's PDF text layer, for checking the exact spelling of words, "
            "names and numbers. It can be out of order, split words, or garble formulas and tables; "
            "the image decides the content and the layout.\n"
            f"<text_layer>\n{plan.text}\n</text_layer>"
        )
    image = ImageBlock(
        data=base64.b64encode(plan.image.data).decode("ascii"), media_type=plan.image.media_type)
    return Message("user", (image, TextBlock("\n\n".join(parts))))


def retry_note(reason: str) -> TextBlock:
    """Appended to a page message for a second attempt."""
    notes = {
        "short": ("Your previous transcription of this page left out most of its text. Transcribe "
                  "every line on the page this time."),
        "length": ("Your previous transcription of this page was cut off. Transcribe the whole page; "
                   "keep tables and formulas complete but do not repeat anything."),
    }
    return TextBlock(notes[reason])


def _span(x0: float, x1: float) -> str:
    if x1 - x0 > 0.6:
        return "spanning the page width"
    middle = (x0 + x1) / 2
    if middle < 0.42:
        return "in the left half"
    if middle > 0.58:
        return "in the right half"
    return "centred"


def _clip(text: str, limit: int) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"
