"""Pure validation and bounded repair helpers for opening review responses."""
from __future__ import annotations

import hashlib
import json
import re
from copy import deepcopy
from typing import Any

from .ad_audit import ValidatedQuoteEvidence

MAX_QUOTE_WORDS = 12
MAX_QUOTE_CUES = 3
ROLES = ("paid_product_ad", "house_promo", "programme", "mixed", "unknown")

_WORD_RE = re.compile(r"[^\W_]+(?:['’][^\W_]+)*", re.UNICODE)
_URL_OR_DOMAIN_RE = re.compile(
    r"\b(?:https?://|www\.)|\b[a-z0-9-]+(?:\.[a-z0-9-]+)+\b|"
    r"[\w.+-]+@[\w.-]+\.[a-z]{2,}\b",
    re.IGNORECASE,
)
QUOTE_REPAIR_BLOCK = "\n\n[WILTED_OPENING_QUOTE_REPAIR_V1]\n"
QUOTE_REPAIR_INSTRUCTION = (
    "Repair only the quotes: choose one permitted exact quote for each listed "
    "commercial evidence ID. Preserve the classification and every evidence ID "
    "exactly. Do not invent or paraphrase quotes."
)


def response_schema(all_ids: list[int]) -> dict[str, Any]:
    """Build the bounded source-ID schema shared by generation and audit."""
    properties = {
        "classification": {"type": "string", "enum": list(ROLES)},
        "commercial_evidence_ids": {
            "type": "array", "items": {"type": "integer", "enum": all_ids},
        },
        "programme_evidence_ids": {
            "type": "array", "items": {"type": "integer", "enum": all_ids},
        },
        "commercial_quotes": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "integer", "enum": all_ids},
                    "quote": {"type": "string"},
                },
                "required": ["id", "quote"],
                "additionalProperties": False,
            },
        },
    }
    return {
        "type": "json_object",
        "schema": {
            "type": "object", "properties": properties,
            "required": list(properties), "additionalProperties": False,
        },
    }


def _source_excerpt_options(text: str) -> tuple[str, ...]:
    """Return at most two exact, bounded excerpts without URLs or domains."""
    words = list(_WORD_RE.finditer(text))
    candidates: list[tuple[int, int, str]] = []
    for length in range(3, 7):
        for start in range(0, len(words) - length + 1):
            excerpt = text[words[start].start():words[start + length - 1].end()]
            if not _URL_OR_DOMAIN_RE.search(excerpt):
                candidates.append((start, length, excerpt))
    if not candidates:
        return ()
    candidates.sort(key=lambda item: (item[0], -item[1]))
    selected = [candidates[0][2]]
    last = max(candidates, key=lambda item: (item[0] + item[1], item[1], item[0]))[2]
    if last not in selected:
        selected.append(last)
    return tuple(selected[:2])


def _validated_original_quote(item: Any, candidate_ids: tuple[int, ...], segments) -> str | None:
    if not isinstance(item, dict):
        return None
    quote = item.get("quote")
    anchor = item.get("id")
    if (not isinstance(quote, str) or not quote.strip()
            or len(_WORD_RE.findall(quote)) > MAX_QUOTE_WORDS
            or type(anchor) is not int
            or _quote_covered_ids(anchor, quote, candidate_ids, segments) is None):
        return None
    return quote


def _quote_repair_options(
    parsed: dict[str, Any], commercial_ids: tuple[int, ...], candidate_ids: tuple[int, ...], segments,
) -> tuple[dict[int, tuple[str, ...]], dict[int, tuple[tuple[str, str], ...]]] | None:
    original_quotes = {
        item["id"]: item for item in parsed["commercial_quotes"]
        if isinstance(item, dict) and type(item.get("id")) is int
    }
    options: dict[int, tuple[str, ...]] = {}
    descriptors: dict[int, tuple[tuple[str, str], ...]] = {}
    for evidence_id in commercial_ids:
        choices: list[tuple[str, str]] = []
        preserved = _validated_original_quote(
            original_quotes.get(evidence_id), candidate_ids, segments,
        )
        if preserved is not None:
            choices.append(("preserved", preserved))
        source_text = str(getattr(segments[evidence_id], "text", "") or "")
        for excerpt in _source_excerpt_options(source_text):
            if excerpt not in {quote for _kind, quote in choices}:
                choices.append(("source", excerpt))
            if len(choices) == 2:
                break
        if not choices:
            return None
        descriptors[evidence_id] = tuple(choices)
        options[evidence_id] = tuple(quote for _kind, quote in choices)
    return options, descriptors


def build_quote_repair_schema(
    base_schema: dict[str, Any],
    commercial_ids: tuple[int, ...],
    quote_options: dict[int, tuple[str, ...]],
) -> dict[str, Any]:
    """Narrow only commercial quote literals while preserving the base schema."""
    if (not commercial_ids or len(commercial_ids) != len(set(commercial_ids))
            or set(quote_options) != set(commercial_ids)):
        raise ValueError("quote repair metadata is incomplete")
    refined = deepcopy(base_schema)
    try:
        base_quotes = refined["schema"]["properties"]["commercial_quotes"]
        base_item = base_quotes["items"]
        allowed_ids = set(base_item["properties"]["id"]["enum"])
        if (base_quotes.get("type") != "array"
                or base_item.get("type") != "object"
                or base_item.get("additionalProperties") is not False
                or not {"id", "quote"}.issubset(base_item.get("required", ()))
                or any(type(evidence_id) is not int or evidence_id not in allowed_ids
                       for evidence_id in commercial_ids)):
            raise ValueError("base quote schema is not the bounded opening contract")
    except (KeyError, TypeError) as error:
        raise ValueError("base quote schema is not the bounded opening contract") from error

    prefix_items = []
    for evidence_id in commercial_ids:
        literals = quote_options[evidence_id]
        if (not literals or len(literals) > 2 or len(literals) != len(set(literals))
                or any(not isinstance(value, str) or not value for value in literals)):
            raise ValueError("quote repair literals are invalid")
        prefix_items.append({
            "type": "object",
            "properties": {
                "id": {"type": "integer", "const": evidence_id},
                "quote": {"type": "string", "enum": list(literals)},
            },
            "required": ["id", "quote"],
            "additionalProperties": False,
        })
    refined["schema"]["properties"]["commercial_quotes"] = {
        "type": "array",
        "minItems": len(prefix_items),
        "maxItems": len(prefix_items),
        "prefixItems": prefix_items,
    }
    return refined


def is_quote_repair_schema_refinement(
    base_schema: dict[str, Any], repair_schema: dict[str, Any],
    commercial_ids: tuple[int, ...], quote_options: dict[int, tuple[str, ...]],
) -> bool:
    """Accept only the canonical per-ID literal refinement of quote items."""
    try:
        all_ids = base_schema["schema"]["properties"]["commercial_evidence_ids"]["items"]["enum"]
        if base_schema != response_schema(all_ids):
            return False
        return repair_schema == build_quote_repair_schema(
            base_schema, commercial_ids, quote_options,
        )
    except (KeyError, TypeError, ValueError):
        return False


def build_quote_repair_request(
    base_prompt: str, original_raw: str, candidate_ids: tuple[int, ...],
    all_ids: list[int], segments,
) -> tuple[str, dict[str, Any], dict[int, tuple[str, ...]]] | None:
    """Build one source-bound literal repair request without echoing rejected text."""
    try:
        parsed = json.loads(original_raw)
    except (TypeError, json.JSONDecodeError):
        return None
    if (not quote_repair_allowed(original_raw, candidate_ids, all_ids)
            or not set(parsed["commercial_evidence_ids"]).issubset(candidate_ids)):
        return None
    commercial_ids = tuple(parsed["commercial_evidence_ids"])
    material = _quote_repair_options(parsed, commercial_ids, candidate_ids, segments)
    if material is None:
        return None
    options, descriptors = material
    base_schema = response_schema(all_ids)
    repair_schema = build_quote_repair_schema(base_schema, commercial_ids, options)
    lines = [
        "Original classification: " + parsed["classification"],
        "Original commercial evidence IDs: " + ",".join(map(str, commercial_ids)),
        "Original programme evidence IDs: " + ",".join(
            map(str, parsed["programme_evidence_ids"]),
        ),
        "Permitted exact quote literals by source ID:",
    ]
    for evidence_id in commercial_ids:
        encoded = json.dumps(
            [{"kind": kind, "quote": quote} for kind, quote in descriptors[evidence_id]],
            ensure_ascii=True, separators=(",", ":"),
        )
        lines.append(f"Commercial quote options for source ID {evidence_id}: {encoded}")
    repair_prompt = (
        base_prompt + QUOTE_REPAIR_BLOCK + QUOTE_REPAIR_INSTRUCTION
        + "\n" + "\n".join(lines)
    )
    return repair_prompt, repair_schema, options


def repair_quotes_match_literals(
    raw: str, commercial_ids: tuple[int, ...], quote_options: dict[int, tuple[str, ...]],
) -> bool:
    """Require repaired quote entries to match offered literals in fixed ID order."""
    try:
        parsed = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return False
    quotes = parsed.get("commercial_quotes") if isinstance(parsed, dict) else None
    if (not isinstance(quotes, list) or len(quotes) != len(commercial_ids)
            or set(quote_options) != set(commercial_ids)):
        return False
    for evidence_id, item in zip(commercial_ids, quotes):
        if (not isinstance(item, dict) or set(item) != {"id", "quote"}
                or type(item["id"]) is not int or item["id"] != evidence_id
                or not isinstance(item["quote"], str)
                or item["quote"] not in quote_options[evidence_id]):
            return False
    return True


def parse_quote_repair_request(
    user_content: str, candidate_ids: tuple[int, ...], all_ids: tuple[int, ...],
) -> dict[str, Any] | None:
    """Parse and validate the bounded metadata and literal map in a repair request."""
    marker_at = user_content.rfind(QUOTE_REPAIR_BLOCK)
    if marker_at < 0:
        return None
    base_prompt = user_content[:marker_at]
    suffix = user_content[marker_at + len(QUOTE_REPAIR_BLOCK):]
    lines = suffix.splitlines()
    if not lines or lines[0] != QUOTE_REPAIR_INSTRUCTION:
        return None
    fields = lines[1:]
    if len(fields) < 4 or fields[3] != "Permitted exact quote literals by source ID:":
        return None
    classification_match = re.fullmatch(r"Original classification: ([a-z_]+)", fields[0])
    commercial_match = re.fullmatch(r"Original commercial evidence IDs: ([0-9]+(?:,[0-9]+)*)", fields[1])
    programme_match = re.fullmatch(r"Original programme evidence IDs: ([0-9]*(?:,[0-9]+)*)", fields[2])
    if not classification_match or not commercial_match or not programme_match:
        return None
    classification = classification_match.group(1)
    commercial_ids = tuple(int(value) for value in commercial_match.group(1).split(","))
    programme_ids = tuple(
        int(value) for value in programme_match.group(1).split(",") if value
    )
    if (classification != "paid_product_ad" or not commercial_ids
            or len(commercial_ids) != len(set(commercial_ids))
            or len(programme_ids) != len(set(programme_ids))
            or not set(commercial_ids).issubset(candidate_ids)
            or set(programme_ids).intersection(candidate_ids)
            or not set((*commercial_ids, *programme_ids)).issubset(all_ids)):
        return None
    option_lines = fields[4:]
    if len(option_lines) != len(commercial_ids):
        return None
    quote_options: dict[int, tuple[str, ...]] = {}
    for expected_id, line in zip(commercial_ids, option_lines):
        match = re.fullmatch(r"Commercial quote options for source ID ([0-9]+): (.+)", line)
        if not match or int(match.group(1)) != expected_id:
            return None
        try:
            descriptors = json.loads(match.group(2))
        except json.JSONDecodeError:
            return None
        if not isinstance(descriptors, list) or not 1 <= len(descriptors) <= 2:
            return None
        quotes: list[str] = []
        preserved_count = source_count = 0
        for item in descriptors:
            if not isinstance(item, dict) or set(item) != {"kind", "quote"}:
                return None
            kind, quote = item["kind"], item["quote"]
            if kind not in {"preserved", "source"} or not isinstance(quote, str) or not quote:
                return None
            count = len(_WORD_RE.findall(quote))
            if kind == "preserved":
                preserved_count += 1
                if count > MAX_QUOTE_WORDS:
                    return None
            else:
                source_count += 1
                if not 3 <= count <= 6 or _URL_OR_DOMAIN_RE.search(quote):
                    return None
            if quote in quotes:
                return None
            quotes.append(quote)
        if preserved_count > 1 or source_count > 2 or not quotes:
            return None
        quote_options[expected_id] = tuple(quotes)
    return {
        "basePrompt": base_prompt,
        "classification": classification,
        "commercialIDs": commercial_ids,
        "programmeIDs": programme_ids,
        "quoteOptions": quote_options,
    }


def _quote_covered_ids(anchor: int, quote: str, candidate_ids: tuple[int, ...], segments) -> tuple[int, ...] | None:
    if anchor not in candidate_ids:
        return None
    words = _WORD_RE.findall(quote)
    if not words or len(words) > MAX_QUOTE_WORDS:
        return None
    position = {segment_id: index for index, segment_id in enumerate(candidate_ids)}[anchor]
    cue_ids = candidate_ids[position:position + MAX_QUOTE_CUES]
    texts = [str(getattr(segments[index], "text", "") or "") for index in cue_ids]
    source = " ".join(texts)
    anchor_end = len(texts[0])
    match_start = source.find(quote)
    while match_start >= 0:
        match_end = match_start + len(quote)
        if match_start < anchor_end:
            owners = []
            cue_start = 0
            for index, text in zip(cue_ids, texts):
                cue_end = cue_start + len(text)
                if cue_end > match_start and cue_start < match_end:
                    owners.append(index)
                cue_start = cue_end + 1
            if owners and owners[0] == anchor and len(owners) <= MAX_QUOTE_CUES:
                return tuple(owners)
        match_start = source.find(quote, match_start + 1)
    return None


def _usable_paid_metadata(parsed: Any, candidate_ids: tuple[int, ...], all_ids: list[int]) -> bool:
    if not isinstance(parsed, dict) or set(parsed) != {
        "classification", "commercial_evidence_ids", "programme_evidence_ids",
        "commercial_quotes",
    }:
        return False
    if parsed["classification"] != "paid_product_ad" or not isinstance(parsed["classification"], str):
        return False
    allowed = set(all_ids)
    values = {}
    for name in ("commercial_evidence_ids", "programme_evidence_ids"):
        value = parsed[name]
        if (not isinstance(value, list)
                or any(type(item) is not int or item not in allowed for item in value)
                or len(value) != len(set(value))):
            return False
        values[name] = value
    candidate = set(candidate_ids)
    if (not candidate.intersection(values["commercial_evidence_ids"])
            or not set(values["commercial_evidence_ids"]).issubset(candidate)):
        return False
    if candidate.intersection(values["programme_evidence_ids"]):
        return False
    quotes = parsed["commercial_quotes"]
    if not isinstance(quotes, list):
        return False
    quote_ids = set()
    for item in quotes:
        if (not isinstance(item, dict) or set(item) != {"id", "quote"}
                or type(item["id"]) is not int or item["id"] not in allowed
                or item["id"] in quote_ids):
            return False
        quote_ids.add(item["id"])
    return set(values["commercial_evidence_ids"]).issubset(quote_ids)


def validate_response(raw: str, candidate_ids: tuple[int, ...], all_ids: list[int], segments) -> dict[str, Any]:
    """Validate complete response shape, source IDs and exact quote provenance."""
    parsed = json.loads(raw)
    fields = {
        "classification", "commercial_evidence_ids", "programme_evidence_ids",
        "commercial_quotes",
    }
    if not isinstance(parsed, dict) or set(parsed) != fields:
        raise ValueError("whole-passage response has an invalid shape")
    if parsed["classification"] not in ROLES or not isinstance(parsed["classification"], str):
        raise ValueError("whole-passage classification is invalid")
    allowed_ids = set(all_ids)
    for name in ("commercial_evidence_ids", "programme_evidence_ids"):
        values = parsed[name]
        if (not isinstance(values, list)
                or any(type(value) is not int or value not in allowed_ids for value in values)
                or len(values) != len(set(values))):
            raise ValueError(f"{name} contains invalid or duplicate IDs")
    if not isinstance(parsed["commercial_quotes"], list):
        raise ValueError("commercial_quotes is not an array")

    quote_anchors: set[int] = set()
    quote_metadata = []
    for item in parsed["commercial_quotes"]:
        if (not isinstance(item, dict) or set(item) != {"id", "quote"}
                or type(item["id"]) is not int or item["id"] not in allowed_ids
                or item["id"] in quote_anchors):
            raise ValueError("commercial quote has an invalid or duplicate ID")
        quote, anchor = item["quote"], item["id"]
        if not isinstance(quote, str) or not quote.strip() or len(_WORD_RE.findall(quote)) > MAX_QUOTE_WORDS:
            raise ValueError("commercial quote is empty or exceeds 12 words")
        covered_ids = _quote_covered_ids(anchor, quote, candidate_ids, segments)
        if covered_ids is None:
            raise ValueError("commercial quote does not match exact candidate source words")
        quote_anchors.add(anchor)
        quote_metadata.append({
            "id": anchor, "coveredIDs": list(covered_ids),
            "wordCount": len(_WORD_RE.findall(quote)),
            "sha256": hashlib.sha256(quote.encode("utf-8")).hexdigest(),
        })

    commercial_ids = parsed["commercial_evidence_ids"]
    if not set(commercial_ids).issubset(quote_anchors):
        raise ValueError("commercial evidence ID has no validated exact quote")
    candidate_set = set(candidate_ids)
    candidate_commercial = sorted(candidate_set.intersection(commercial_ids))
    candidate_programme = sorted(candidate_set.intersection(parsed["programme_evidence_ids"]))
    return {
        "classification": parsed["classification"],
        "commercialEvidenceIDs": sorted(commercial_ids),
        "programmeEvidenceIDs": sorted(parsed["programme_evidence_ids"]),
        "candidateCommercialEvidenceIDs": candidate_commercial,
        "candidateProgrammeEvidenceIDs": candidate_programme,
        "validatedQuoteMetadata": quote_metadata,
        "eligiblePaidCandidate": (
            parsed["classification"] == "paid_product_ad"
            and bool(candidate_commercial) and not candidate_programme
        ),
    }


def quote_repair_allowed(raw: str, candidate_ids: tuple[int, ...], all_ids: list[int]) -> bool:
    """Gate a format retry without accepting the invalid quote as evidence."""
    try:
        return _usable_paid_metadata(json.loads(raw), candidate_ids, all_ids)
    except (TypeError, json.JSONDecodeError):
        return False


def validated_quote_evidence(metadata) -> tuple[ValidatedQuoteEvidence, ...]:
    """Freeze strictly validated quote metadata in source-ID order."""
    return tuple(sorted(
        (
            ValidatedQuoteEvidence(
                int(item["id"]), tuple(int(value) for value in item["coveredIDs"]),
                int(item["wordCount"]), str(item["sha256"]),
            )
            for item in metadata
        ),
        key=lambda item: item.id,
    ))
