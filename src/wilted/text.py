"""Text processing — cleaning, splitting, and title extraction."""

import re


def clean_text(text: str) -> str:
    """Strip Apple News copy-paste artifacts and clean up for TTS."""
    # Remove Apple News footer block
    footer = re.search(r"\n\s*Excerpt From\s*\n.*$", text, flags=re.DOTALL)
    if footer:
        text = text[: footer.start()]

    # Remove "Follow X on Apple News" lines
    text = re.sub(r"Follow .+ on Apple News\s*\n?", "", text)

    # Remove copyright notices
    text = re.sub(r"This material may be protected by copyright\.?\s*\n?", "", text)

    # Collapse multiple blank lines
    text = re.sub(r"\n{3,}", "\n\n", text)

    return text.strip()


def extract_title_from_paste(text: str) -> str | None:
    """Try to pull a title from Apple News paste format.

    Format is typically:
        CATEGORY
        TITLE IN ALL CAPS
        Subtitle
        DATE
        Body...
    """
    lines = [line.strip() for line in text.split("\n") if line.strip()]
    if len(lines) >= 2:
        candidate = lines[1] if lines[0].isupper() and len(lines[0].split()) <= 3 else lines[0]
        if candidate.isupper() and len(candidate.split()) >= 3:
            return candidate.title()
    return None


def split_into_chunks(text: str, max_chars: int = 800) -> list[str]:
    """Split text into chunks on paragraph boundaries for CLI playback."""
    paragraphs = [p.strip() for p in text.split("\n") if p.strip()]

    chunks = []
    for para in paragraphs:
        if len(para) <= max_chars:
            chunks.append(para)
        else:
            sentences = re.split(r"(?<=[.!?])\s+", para)
            current = ""
            for sent in sentences:
                if len(current) + len(sent) > max_chars and current:
                    chunks.append(current.strip())
                    current = sent
                else:
                    current = f"{current} {sent}" if current else sent
            if current:
                chunks.append(current.strip())

    return chunks


def split_paragraphs(text: str) -> list[str]:
    """Split text into paragraphs for TUI playback.

    Splits on single newlines (trafilatura cached files use single newlines).
    Filters empty lines.
    """
    return [p.strip() for p in text.split("\n") if p.strip()]
