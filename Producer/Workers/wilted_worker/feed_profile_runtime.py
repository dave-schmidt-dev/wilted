"""Use local feed placement observations as bounded recovery hints.

Profiles only choose which current cues receive an extra generic classification.
They never enter a model prompt, determine a boundary, or provide preservation
proof. All accepted candidates receive a fresh current-episode preservation
review before they can join the ordinary guarded detections.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

from .ad_audit import AuditingBackend
from .commercial_preservation import _commercial_envelope_preserved, _prompt_budget_values
from .nomination import _CallBudgetBackend
from .reporting import WorkerError

MAX_PROFILE_WINDOWS = 4
MAX_PROFILE_CALLS = 12
MAX_WINDOW_IDS = 64
MAX_WINDOW_CHARS = 12_000
MAX_PROFILE_CANDIDATE_IDS = 48

@dataclass(frozen=True)
class ProfileRecovery:
    """Result of one bounded profile-guided analysis."""

    detections: tuple[object, ...]
    windows: int
    requests: int
    failures: int = 0


def _normalized_phrase(value: str) -> str:
    return " ".join(re.findall(r"[^\W_]+", unicodedata.normalize("NFKC", value).casefold(), re.UNICODE))


def _slot_windows(profile: dict, segments, total_seconds: float, existing_detections):
    """Return at most four current cue windows selected by placement or literal markers."""
    windows = []
    for slot in profile.get("slots", ()):
        start_s = total_seconds * slot["startBasisPoints"] / 10_000
        end_s = total_seconds * slot["endBasisPoints"] / 10_000
        if not 0 <= start_s < end_s <= total_seconds:
            continue
        ids = [
            index for index, segment in enumerate(segments)
            if float(segment.end_s) > start_s and float(segment.start_s) < end_s
        ]
        if not ids:
            continue

        # Literal markers can locate a repeated placement when episode length or
        # insertion timing shifted. They select the window only; never enter a
        # prompt or authorize its boundaries.
        markers = [
            _normalized_phrase(phrase)
            for phrase in (*slot["entryPhrases"], *slot["returnPhrases"])
        ]
        marker_ids = [
            index for index, segment in enumerate(segments)
            if markers and any(marker in _normalized_phrase(str(segment.text)) for marker in markers)
        ]
        center_s = (start_s + end_s) / 2
        if marker_ids:
            expected_center = center_s
            center_id = min(
                marker_ids,
                key=lambda index: abs((float(segments[index].start_s) + float(segments[index].end_s)) / 2
                                      - expected_center),
            )
            if (float(segments[center_id].end_s) >= start_s - min(180.0, total_seconds * 0.08)
                    and float(segments[center_id].start_s) <= end_s + min(180.0, total_seconds * 0.08)):
                ids = [index for index in range(max(0, center_id - 24), min(len(segments), center_id + 25))]
        if len(ids) > MAX_WINDOW_IDS:
            center_index = min(
                ids,
                key=lambda index: abs((float(segments[index].start_s) + float(segments[index].end_s)) / 2
                                      - center_s),
            )
            ids = list(range(max(0, center_index - MAX_WINDOW_IDS // 2),
                             min(len(segments), center_index + MAX_WINDOW_IDS // 2)))
            ids = ids[:MAX_WINDOW_IDS]
        if not ids:
            continue
        if not _uncovered_ids(ids, segments, existing_detections, ()):
            # Existing source detections cover every cue in this window.
            continue
        if any(ids[0] <= window[0][-1] and ids[-1] >= window[0][0] for window in windows):
            continue
        rendered = "\n".join(
            f"[ID {index}] [{float(segments[index].start_s):.3f}s - "
            f"{float(segments[index].end_s):.3f}s] {segments[index].text}"
            for index in ids
        )
        if len(rendered) > MAX_WINDOW_CHARS:
            continue
        windows.append((tuple(ids), rendered, slot))
    return windows[:MAX_PROFILE_WINDOWS]


def _contiguous_runs(decisions, ads_module, segments, remove_self_promotion):
    """Build short-lived nomination runs from one complete generic classification."""
    runs = []
    positive = []
    for segment_id, is_ad, label in decisions:
        if is_ad:
            current_label = label or "ad_break"
            if positive and (
                segment_id != positive[-1][0] + 1 or current_label != positive[-1][1]
            ):
                runs.append(positive)
                positive = []
            positive.append((segment_id, current_label))
        elif positive:
            runs.append(positive)
            positive = []
    if positive:
        runs.append(positive)

    result = []
    for run in runs:
        ids = tuple(item[0] for item in run)
        label = run[0][1]
        if len(ids) > MAX_PROFILE_CANDIDATE_IDS:
            continue
        if label in {"self_promo", "newsletter_pitch"} and not remove_self_promotion:
            continue
        if len(ids) <= 2:
            coarse = ads_module._CoarseAdRun(  # noqa: SLF001
                ids[0], ids[-1], ads_module.COARSE_CONFIDENCE_FLOOR, label
            )
            if label == "self_promo":
                has_evidence = remove_self_promotion and ads_module._has_house_promotion_cue(  # noqa: SLF001
                    coarse, segments
                )
            else:
                has_evidence = ads_module._has_sparse_promo_evidence(coarse, segments)  # noqa: SLF001
            if not has_evidence:
                continue
        # One supplementary classification is a nomination only; confidence is
        # deliberately below the archive's coarse classifier band.
        result.append(ads_module._CoarseAdRun(
            ids[0], ids[-1], ads_module.RECOVERED_CONFIDENCE_FLOOR, label
        ))
    return result


def _render_complete(ads_module, ids, segments) -> str | None:
    """Render full original cue text without the archive's truncation fallback."""
    rendered = "\n".join(
        ads_module._segment_prefix(index, segments[index]) + (segments[index].text or "")  # noqa: SLF001
        for index in ids
    )
    return rendered if len(rendered) <= MAX_WINDOW_CHARS else None


def _split_complete_batches(ads_module, ids, segments):
    """Split current cues while proving no candidate text was truncated."""
    batches = []
    batch_ids = []
    rendered_chars = 0
    for index in ids:
        line = ads_module._segment_prefix(index, segments[index]) + (segments[index].text or "")  # noqa: SLF001
        if len(line) > MAX_WINDOW_CHARS:
            return None
        added = len(line) + bool(batch_ids)
        if batch_ids and (len(batch_ids) >= MAX_WINDOW_IDS or rendered_chars + added > MAX_WINDOW_CHARS):
            text = _render_complete(ads_module, batch_ids, segments)
            if text is None:
                return None
            batches.append((batch_ids, text))
            batch_ids, rendered_chars = [], 0
            added = len(line)
        batch_ids.append(index)
        rendered_chars += added
    if batch_ids:
        text = _render_complete(ads_module, batch_ids, segments)
        if text is None:
            return None
        batches.append((batch_ids, text))
    return batches


def _profile_preroll_boundary(ads_module, backend, segments, program_start_max: int, slot: dict):
    """Use the profile only as a search hint for Q1, then require blind Q2 confirmation."""
    from .commercial_seeds import _constrained_id
    from .constants import PREROLL_COLD_OPEN_MAX_ID, PREROLL_RECOVERY_MINIMUM_SECONDS
    from .prompts import PREROLL_CONFIRM_PROMPT, PREROLL_PROGRAM_START_PROMPT

    if program_start_max <= 0:
        return None
    q1_ids = tuple(range(0, min(len(segments), MAX_WINDOW_IDS, program_start_max + 18)))
    hint = {
        "position": slot["position"],
        "startBasisPoints": slot["startBasisPoints"],
        "endBasisPoints": slot["endBasisPoints"],
        "entryPhrases": slot["entryPhrases"],
        "returnPhrases": slot["returnPhrases"],
    }
    rendered = _render_complete(ads_module, q1_ids, segments)
    if rendered is None:
        return None
    q1_content = (
        "Ad placement profile search hint (unverified; do not treat as evidence): "
        + __import__("json").dumps(hint, ensure_ascii=False, separators=(",", ":"))
        + "\nCurrent episode excerpt:\n"
        + rendered
    )
    if len(q1_content) > MAX_WINDOW_CHARS:
        return None
    response, _tokens = ads_module._generate_constrained_response(  # noqa: SLF001
        backend,
        PREROLL_PROGRAM_START_PROMPT,
        q1_content,
        ads_module._id_response_format("program_start_id", q1_ids),  # noqa: SLF001
    )
    import json
    parsed = json.loads(response)
    if (not isinstance(parsed, dict) or set(parsed) != {"program_start_id"}
            or isinstance(parsed["program_start_id"], bool)
            or not isinstance(parsed["program_start_id"], int)
            or parsed["program_start_id"] not in q1_ids):
        raise ValueError("profile opening review returned an invalid program boundary")
    program_start_id = parsed["program_start_id"]
    if program_start_id <= PREROLL_COLD_OPEN_MAX_ID:
        return None
    end_s = float(segments[program_start_id].start_s)
    if end_s < PREROLL_RECOVERY_MINIMUM_SECONDS:
        return None

    candidate_ids = tuple(range(program_start_id))
    # Q2 sees the entire current candidate and a bounded current return on the
    # right. The profile hint is absent, and only IDs inside the candidate (or
    # -1) are valid answers, so programme cues on the right are comparison only.
    context_end = min(len(segments), MAX_WINDOW_IDS, program_start_id + 9)
    context_ids = tuple(range(context_end))
    q2_rendered = _render_complete(ads_module, context_ids, segments)
    if q2_rendered is None:
        return None
    comparison_ids = tuple(index for index in context_ids if index not in candidate_ids)
    q2_rendered = (
        f"Candidate IDs to assess: {', '.join(map(str, candidate_ids))}\n"
        f"Following IDs are comparison context only: {', '.join(map(str, comparison_ids))}\n"
        "Return -1 or an ID from the candidate list only.\n"
        + q2_rendered
    )
    confirmation, _tokens = ads_module._generate_constrained_response(  # noqa: SLF001
        backend,
        PREROLL_CONFIRM_PROMPT,
        q2_rendered,
        ads_module._id_response_format("program_id", [-1, *candidate_ids]),  # noqa: SLF001
    )
    confirmed = json.loads(confirmation)
    if (not isinstance(confirmed, dict) or set(confirmed) != {"program_id"}
            or isinstance(confirmed["program_id"], bool)
            or not isinstance(confirmed["program_id"], int)
            or confirmed["program_id"] not in {-1, *candidate_ids}):
        raise ValueError("profile opening confirmation returned an invalid ID")
    if confirmed["program_id"] != -1:
        return None
    return candidate_ids


def _profile_preroll_preserved(segments, candidate_ids):
    """Require a bounded, nonempty opening with a confirmed current right flank."""
    from .constants import PREROLL_RECOVERY_MINIMUM_SECONDS
    if (not candidate_ids or candidate_ids[0] != 0
            or candidate_ids[-1] + 1 >= len(segments)
            or len(candidate_ids) > MAX_PROFILE_CANDIDATE_IDS):
        return False
    start_s = float(segments[0].start_s)
    end_s = float(segments[candidate_ids[-1]].end_s)
    right_start = float(segments[candidate_ids[-1] + 1].start_s)
    return (end_s - start_s >= PREROLL_RECOVERY_MINIMUM_SECONDS
            and 0 <= start_s < end_s <= right_start)


def _uncovered_ids(ids, segments, detections, held_spans):
    """Retain only current cues not already cut or held by primary safeguards."""
    selected = []
    for index in ids:
        start, end = float(segments[index].start_s), float(segments[index].end_s)
        covered = any(float(ad.start_s) <= start and float(ad.end_s) >= end for ad in detections)
        held = any(float(span.start_s) < end and float(span.end_s) > start for span in held_spans)
        if not covered and not held:
            selected.append(index)
    return tuple(selected)

class _MeasuredProfileBackend:
    """Measure each additional request before spending the profile call budget."""

    def __init__(self, backend):
        self.backend = backend

    def measure_prompt(self, system_prompt, user_content, *, response_format=None):
        return self.backend.measure_prompt(system_prompt, user_content, response_format=response_format)

    def generate(self, system_prompt, user_content, *, response_format=None, prepared_prompt=None):
        prepared = prepared_prompt
        if prepared is None:
            prepared = self.measure_prompt(system_prompt, user_content, response_format=response_format)
        values = _prompt_budget_values(prepared)
        if values[0] + values[2] > values[1]:
            raise ValueError("profile recovery request exceeds measured model context")
        kwargs = {"response_format": response_format, "prepared_prompt": prepared}
        return self.backend.generate(system_prompt, user_content, **kwargs)


def recover_profile_candidates(
    ads_module,
    backend: AuditingBackend,
    segments,
    total_seconds: float,
    profile: dict,
    *,
    remove_self_promotion: bool = False,
    existing_detections=(),
    held_spans=(),
) -> ProfileRecovery:
    """Nominate profile windows, then require current independent preservation."""
    windows = _slot_windows(profile, segments, total_seconds, existing_detections)
    if not windows:
        return ProfileRecovery((), 0, 0)

    raw_backend = getattr(backend, "_backend", None)
    if raw_backend is None:
        return ProfileRecovery((), 0, 0)
    overrides = None
    if remove_self_promotion:
        from .ad_removal import self_promotion_prompt_overrides
        overrides = self_promotion_prompt_overrides(ads_module)
    profile_audit = AuditingBackend(
        raw_backend, ads_module, len(segments), prompt_overrides=overrides
    )
    call_budget = _CallBudgetBackend(profile_audit, MAX_PROFILE_CALLS)
    bounded = _MeasuredProfileBackend(call_budget)
    recovered = []
    windows_used = 0
    for ids, _rendered, slot in windows:
        eligible_ids = _uncovered_ids(ids, segments, existing_detections, held_spans)
        if not eligible_ids:
            continue
        runs = []
        for index in eligible_ids:
            if runs and runs[-1][-1] + 1 == index:
                runs[-1].append(index)
            else:
                runs.append([index])
        # Each uncovered run is kept separate so an existing cut cannot be
        # bridged by a profile nomination; every cue is rendered in full.
        chunks = []
        for run_ids in runs:
            complete = _split_complete_batches(ads_module, run_ids, segments)
            if complete is None:
                chunks = []
                break
            chunks.extend(complete)
        if not chunks or len(chunks) > 3:
            continue
        window_decisions = []
        for batch_index, (batch_ids, transcript_text) in enumerate(chunks):
            try:
                window_decisions.extend(ads_module._classify_batch(  # noqa: SLF001
                    batch_ids, segments, bounded, -1, f"profile-{batch_index}", transcript_text,
                    remove_self_promotion=remove_self_promotion,
                ))
            except WorkerError:
                window_decisions = []
                break
            if call_budget.calls >= MAX_PROFILE_CALLS and not window_decisions:
                window_decisions = []
                break
        covered = {
            segment_id
            for lineage in profile_audit.lineages
            for segment_id in lineage.classifications
        }
        if not window_decisions or not set(eligible_ids).issubset(covered):
            windows_used += 1
            continue
        windows_used += 1
        runs = _contiguous_runs(window_decisions, ads_module, segments, remove_self_promotion)
        for run in runs:
            if call_budget.calls >= MAX_PROFILE_CALLS:
                continue
            candidate_ids = tuple(range(run.start_id, run.end_id + 1))
            if any(
                float(segments[run.end_id].end_s) > float(held.start_s)
                and float(segments[run.start_id].start_s) < float(held.end_s)
                for held in held_spans
            ):
                continue
            try:
                if run.start_id == 0:
                    if slot["position"] != "pre":
                        continue
                    candidate_ids = _profile_preroll_boundary(
                        ads_module, bounded, segments, run.end_id, slot
                    )
                    if not candidate_ids or not _profile_preroll_preserved(
                        segments, candidate_ids
                    ):
                        continue
                    verified_ids = candidate_ids
                else:
                    verified_ids = _commercial_envelope_preserved(
                        ads_module, bounded, segments, total_seconds, candidate_ids,
                        nominate=False,
                    )
                if not verified_ids:
                    continue
                first, last = verified_ids[0], verified_ids[-1]
                start_s = float(segments[first].start_s)
                end_s = float(segments[last].end_s)
                if not 0 <= start_s < end_s <= total_seconds:
                    continue
                label = run.label
                recovered.append(ads_module.AdSegment(
                    start_s,
                    end_s,
                    ads_module.RECOVERED_CONFIDENCE_FLOOR,
                    label,
                ))
            except Exception:  # noqa: BLE001 - uncertainty leaves this candidate audible
                continue
    return ProfileRecovery(
        tuple(recovered), windows_used, call_budget.calls, profile_audit.failures
    )


def independent_primary_observation(backend, segments, *, feed_id: str, episode_id: str, source_hash: str, total_seconds: float | None = None):
    """Summarize only the original unprofiled classifier's validated positive spans."""
    if not isinstance(source_hash, str):
        return None
    if source_hash.startswith("sha256:"):
        source_hash = source_hash[7:]
    if re.fullmatch(r"[0-9a-f]{64}", source_hash) is None:
        return None
    labels_by_id = {}
    for lineage in getattr(backend, "lineages", ()):
        for segment_id, states in lineage.classifications.items():
            labels_by_id.setdefault(segment_id, []).extend(states)
    positive_ids = []
    for segment_id, states in sorted(labels_by_id.items()):
        positive = [state[3:] for state in states if state.startswith("ad:")]
        negative = sum(state == "content" for state in states)
        # This is placement evidence only: no label or removal-policy decision
        # is stored. Every runtime nomination is classified and policy-checked
        # again against the current episode and the user's current setting.
        eligible = [label for label in positive if label in {"sponsor_read", "ad_break", "self_promo", "newsletter_pitch"}]
        if eligible and len(eligible) > negative:
            positive_ids.append(segment_id)
    runs = []
    for segment_id in positive_ids:
        if not runs or segment_id != runs[-1][-1] + 1:
            runs.append([segment_id])
        else:
            runs[-1].append(segment_id)
    slots = []
    duration = float(total_seconds if total_seconds is not None else (segments[-1].end_s if segments else 0.0))
    if duration <= 0 or not duration < float("inf"):
        return None
    url_re = re.compile(r"(?:https?://|www\.)\S+|\b[\w.-]+\.(?:com|net|org|io|fm|tv|ai)\b", re.I)
    for run in runs:
        first, last = run[0], run[-1]
        start_s, end_s = float(segments[first].start_s), float(segments[last].end_s)
        if not 0 <= start_s < end_s <= duration:
            continue
        start_bp = max(0, min(9_999, round(start_s / duration * 10_000)))
        end_bp = max(start_bp + 1, min(10_000, round(end_s / duration * 10_000)))
        position = "pre" if end_bp <= 1_200 else "post" if start_bp >= 8_800 else "mid"
        def phrase(segment, first_words):
            text = unicodedata.normalize("NFKC", str(segment.text or ""))
            text = url_re.sub(" ", text)
            words = re.findall(r"[^\W_]+(?:['’-][^\W_]+)?", text, re.UNICODE)
            selected = words[:6] if first_words else words[-6:]
            value = " ".join(selected)[:120].strip()
            return value if value and any(char.isalpha() for char in value) else None
        entry = phrase(segments[first], True)
        return_id = next((index for index in range(last + 1, len(segments))
                          if "content" in labels_by_id.get(index, ())), None)
        returning = phrase(segments[return_id], True) if return_id is not None else phrase(segments[last], False)
        if not entry and not returning:
            continue
        slots.append({
            "position": position,
            "startBasisPoints": start_bp,
            "endBasisPoints": end_bp,
            "entryPhrases": [entry] if entry else [],
            "returnPhrases": [returning] if returning else [],
        })
        if len(slots) >= 12:
            break
    observation = {
        "schemaVersion": 1,
        "feedID": feed_id,
        "episodeID": episode_id,
        "sourceHash": source_hash,
        "slots": slots,
    }
    from .feed_profiles import validate_observation
    return validate_observation(observation, feed_id, episode_id, source_hash)
