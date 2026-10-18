"""Interval geometry utilities for robust float boundary comparison and containment."""
from __future__ import annotations

import math


def one_ulp_equal(a: float, b: float) -> bool:
    """Return whether two finite floats are equal within one ULP."""
    if not (math.isfinite(a) and math.isfinite(b)):
        return False
    if a == b:
        return True
    return math.nextafter(a, b) == b


def one_ulp_le(a: float, b: float) -> bool:
    """Return whether a <= b with one-ULP tolerance."""
    if not (math.isfinite(a) and math.isfinite(b)):
        return False
    return a <= b or one_ulp_equal(a, b)


def one_ulp_ge(a: float, b: float) -> bool:
    """Return whether a >= b with one-ULP tolerance."""
    if not (math.isfinite(a) and math.isfinite(b)):
        return False
    return a >= b or one_ulp_equal(a, b)


def is_valid_interval(start: float, end: float) -> bool:
    """Return whether (start, end) defines a finite, non-reversed interval."""
    if not (math.isfinite(start) and math.isfinite(end)):
        return False
    if start >= end:
        return False
    return True


def interval_contains(
    outer_start: float, outer_end: float, inner_start: float, inner_end: float
) -> bool:
    """Return whether outer interval contains inner interval with one-ULP boundary tolerance."""
    if not (is_valid_interval(outer_start, outer_end) and math.isfinite(inner_start)
            and math.isfinite(inner_end) and inner_start <= inner_end):
        return False
    return one_ulp_le(outer_start, inner_start) and one_ulp_ge(outer_end, inner_end)


def intervals_overlap(
    a_start: float, a_end: float, b_start: float, b_end: float
) -> bool:
    """Return whether intervals A and B have strictly positive overlap (> 1 ULP)."""
    if not all(math.isfinite(value) for value in (a_start, a_end, b_start, b_end)):
        return False
    if a_start == a_end and b_start < b_end:
        return b_start < a_start < b_end
    if b_start == b_end and a_start < a_end:
        return a_start < b_start < a_end
    if not (is_valid_interval(a_start, a_end) and is_valid_interval(b_start, b_end)):
        return False
    start = max(a_start, b_start)
    end = min(a_end, b_end)
    if start >= end:
        return False
    return not one_ulp_equal(start, end)
