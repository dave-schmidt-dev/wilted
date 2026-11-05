"""Content-free reason codes for unanswered source-checked opening reviews."""
from __future__ import annotations

import json

from .ad_audit import is_context_capacity_error
from .commercial_preservation import _prompt_budget_values

_VALIDATION_REASONS = {
    "whole-passage response has an invalid shape": "response-shape",
    "whole-passage classification is invalid": "classification",
    "commercial_evidence_ids contains invalid or duplicate IDs": "evidence-ids",
    "programme_evidence_ids contains invalid or duplicate IDs": "evidence-ids",
    "commercial_quotes is not an array": "quote-shape",
    "commercial quote has an invalid or duplicate ID": "quote-ids",
    "commercial quote is empty or exceeds 12 words": "quote-length",
    "commercial quote does not match exact candidate source words": "quote-source-mismatch",
    "commercial evidence ID has no validated exact quote": "quote-missing",
    "opening quote repair changed decision": "quote-repair-decision",
    "opening quote repair used an unoffered literal": "quote-repair-literal",
    "opening quote repair failed": "quote-repair-failed",
    "opening quote repair has no safe exact literals": "quote-repair-source",
    "opening quote repair exceeds its text bound": "text-capacity",
    "opening nomination returned an invalid boundary ID": "boundary-id",
    "opening review requires a measured prompt budget": "measurement-unavailable",
    "backend cannot measure the loaded chat prompt budget": "measurement-unavailable",
    "commercial review measured an invalid chat prompt budget": "measurement-invalid",
    "opening review exceeds the measured model context": "context-capacity",
    "opening nomination exceeds the measured model context": "context-capacity",
    "opening nomination cannot fit two complete cues within its text bound": "text-capacity",
}


def opening_failure_reason(error: Exception) -> str:
    """Return an allowlisted code, never an exception message or model content."""
    if isinstance(error, json.JSONDecodeError):
        return "response-json"
    if isinstance(error, ValueError):
        if is_context_capacity_error(error):
            return "context-capacity"
        try:
            tokens, context, reserve = _prompt_budget_values(error)
        except ValueError:
            pass
        else:
            if tokens + reserve > context:
                return "context-capacity"
        return _VALIDATION_REASONS.get(str(error), "validation-unclassified")
    return "backend-unavailable" if isinstance(error, (RuntimeError, OSError, MemoryError)) else "unexpected-error"
