"""Tests for BWS feed-reference resolution (feed_refs.py)."""

from __future__ import annotations

import pytest

from wilted.feed_refs import FeedReferenceError, resolve_enclosure_url, resolve_feed_url


class TestFeedReferences:
    def test_resolves_bws_reference_from_environment(self, monkeypatch):
        monkeypatch.setenv("WILTED_FEED_PRIVATE", "https://private.example/feed.xml")
        assert resolve_feed_url("bws:WILTED_FEED_PRIVATE") == "https://private.example/feed.xml"

    def test_invalid_resolved_bws_value_never_exposes_value(self, monkeypatch):
        private_value = "not-a-public-url-with-private-material"
        monkeypatch.setenv("WILTED_FEED_PRIVATE", private_value)
        with pytest.raises(FeedReferenceError) as exc_info:
            resolve_feed_url("bws:WILTED_FEED_PRIVATE")
        assert private_value not in str(exc_info.value)

    def test_enclosure_reference_re_resolves_without_persisting_url(self, monkeypatch):
        from wilted.feed_refs import make_bws_enclosure_reference

        private_url = "https://private.example/credential-material.mp3"
        monkeypatch.setenv("WILTED_FEED_PRIVATE", "https://private.example/feed.xml")
        private_guid = "episode-guid-with-private-material"
        reference = make_bws_enclosure_reference("bws:WILTED_FEED_PRIVATE", private_guid)
        entry = {"id": private_guid, "enclosures": [{"href": private_url, "type": "audio/mpeg"}]}
        parsed = type("Parsed", (), {"entries": [entry]})
        monkeypatch.setattr("wilted.feed_refs.feedparser.parse", lambda _: parsed)

        assert private_url not in reference
        assert private_guid not in reference
        assert resolve_enclosure_url(reference, "bws:WILTED_FEED_PRIVATE") == private_url

    def test_enclosure_refresh_exception_drops_secret_bearing_cause(self, monkeypatch):
        from wilted.feed_refs import make_bws_enclosure_reference

        private_url = "https://private.example/feed.xml?credential=hidden"
        monkeypatch.setenv("WILTED_FEED_PRIVATE", private_url)
        reference = make_bws_enclosure_reference("bws:WILTED_FEED_PRIVATE", "episode-guid")

        def fail_parse(_url):
            raise RuntimeError(private_url)

        monkeypatch.setattr("wilted.feed_refs.feedparser.parse", fail_parse)
        with pytest.raises(FeedReferenceError) as exc_info:
            resolve_enclosure_url(reference, "bws:WILTED_FEED_PRIVATE")

        assert private_url not in str(exc_info.value)
        assert exc_info.value.__cause__ is None
