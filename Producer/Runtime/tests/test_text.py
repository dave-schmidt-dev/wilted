"""Tests for wilted.text — cleaning, splitting, title extraction."""

from wilted.text import (
    clean_text,
    extract_title_from_paste,
    split_into_chunks,
    split_paragraphs,
)


class TestCleanText:
    def test_strips_apple_news_footer(self):
        text = "Article body here.\n\nExcerpt From\nSome Book Title\nBy Author"
        result = clean_text(text)
        assert "Excerpt From" not in result
        assert "Article body here." in result

    def test_strips_follow_on_apple_news(self):
        text = "Paragraph one.\nFollow The Atlantic on Apple News\nParagraph two."
        result = clean_text(text)
        assert "Follow" not in result
        assert "Paragraph one." in result
        assert "Paragraph two." in result

    def test_strips_copyright_notice(self):
        text = "Content here.\nThis material may be protected by copyright.\nMore content."
        result = clean_text(text)
        assert "copyright" not in result

    def test_collapses_blank_lines(self):
        text = "Para one.\n\n\n\n\nPara two."
        result = clean_text(text)
        assert "\n\n\n" not in result
        assert "Para one.\n\nPara two." == result

    def test_strips_whitespace(self):
        text = "  \n\nContent here.\n\n  "
        result = clean_text(text)
        assert result == "Content here."

    def test_passthrough_clean_text(self):
        text = "Already clean article text with no artifacts."
        assert clean_text(text) == text


class TestExtractTitleFromPaste:
    def test_extracts_all_caps_title(self):
        text = "POLITICS\nTHE BIG STORY ABOUT SOMETHING IMPORTANT\nBy John Smith\n2026-04-06\nBody text here."
        result = extract_title_from_paste(text)
        assert result == "The Big Story About Something Important"

    def test_first_line_title_when_no_category(self):
        text = "THE BIG STORY ABOUT SOMETHING IMPORTANT\nBy John Smith\nBody text."
        result = extract_title_from_paste(text)
        assert result == "The Big Story About Something Important"

    def test_returns_none_for_normal_text(self):
        text = "This is just a normal paragraph of text.\nAnd another line."
        result = extract_title_from_paste(text)
        assert result is None

    def test_returns_none_for_short_text(self):
        text = "Single line."
        result = extract_title_from_paste(text)
        assert result is None


class TestSplitIntoChunks:
    def test_short_paragraphs_stay_intact(self):
        text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        chunks = split_into_chunks(text)
        assert chunks == [
            "First paragraph.",
            "Second paragraph.",
            "Third paragraph.",
        ]

    def test_long_paragraph_splits_on_sentences(self):
        sentence = "This is a test sentence. " * 50  # ~1250 chars
        chunks = split_into_chunks(sentence.strip(), max_chars=800)
        assert len(chunks) >= 2
        for chunk in chunks:
            assert len(chunk) <= 800 + 50  # some slack for last sentence

    def test_empty_text(self):
        assert split_into_chunks("") == []

    def test_blank_lines_filtered(self):
        text = "Para one.\n\n\n\nPara two."
        chunks = split_into_chunks(text)
        assert chunks == ["Para one.", "Para two."]

    def test_respects_max_chars(self):
        text = "Short. " * 200
        chunks = split_into_chunks(text.strip(), max_chars=100)
        for chunk in chunks:
            # Allow some overshoot for the last sentence in a group
            assert len(chunk) <= 150


class TestSplitParagraphs:
    def test_single_newline_split(self):
        text = "Para one.\nPara two.\nPara three."
        result = split_paragraphs(text)
        assert result == ["Para one.", "Para two.", "Para three."]

    def test_filters_empty_lines(self):
        text = "Para one.\n\n\nPara two.\n\nPara three."
        result = split_paragraphs(text)
        assert result == ["Para one.", "Para two.", "Para three."]

    def test_strips_whitespace(self):
        text = "  Para one.  \n  Para two.  "
        result = split_paragraphs(text)
        assert result == ["Para one.", "Para two."]

    def test_empty_text(self):
        assert split_paragraphs("") == []
