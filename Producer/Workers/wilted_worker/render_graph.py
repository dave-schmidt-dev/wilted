"""The ffmpeg filter graph that renders a keep map in one pass over the source."""
from __future__ import annotations

from .reporting import WorkerError

# The graph writes split points at microsecond precision, so two points closer
# than this cannot be told apart and are treated as one.
_POINT_DECIMALS = 6


def keep_segment_graph(keeps) -> str:
    """Build the ``-filter_complex`` graph that keeps exactly ``keeps``.

    The source is split once with ``asegment`` at every keep boundary; kept
    pieces are concatenated in order and removed pieces drain into
    ``anullsink``. Each decoded frame therefore reaches one branch.

    The graph this replaces gave every keep its own ``atrim`` branch of
    ``[0:a]``, so ffmpeg delivered every frame to every branch and the cost
    grew with keeps times episode length: on a 30-minute MP3, 450 keeps took
    552 s against 10.6 s for two. The split graph rendered the same 450 keeps
    in 7.5 s, and on WAV, MP3 and M4A sources its decoded PCM was
    byte-identical to the ``atrim`` graph's, including keeps that start at
    zero or run past the end of the stream (measured 2026-10-20, ffmpeg 9.0).

    Args:
        keeps: Time-ordered, non-overlapping ``KeepInterval`` values on the
            source clock.

    Returns:
        The filter graph; its output label is ``[outa]``.

    Raises:
        WorkerError: ``cut-unsafe`` when an interval is empty, negative, out
            of order, or when nothing is left to keep.
    """
    points: list[float] = []
    kept: list[int] = []
    cursor = 0.0
    for keep in keeps:
        if not (keep.start_s >= 0 and keep.end_s > keep.start_s):
            raise WorkerError("cut-unsafe", "render map contains an empty or invalid keep interval")
        start, end = round(keep.start_s, _POINT_DECIMALS), round(keep.end_s, _POINT_DECIMALS)
        if start < cursor:
            raise WorkerError("cut-unsafe", "render map keep intervals overlap or are out of order")
        if end <= start:
            # Shorter than the graph can express, and far shorter than
            # anything audible.
            continue
        if start > cursor:
            points.append(start)
        # Output n of asegment runs from split point n-1 to split point n.
        kept.append(len(points))
        points.append(end)
        cursor = end
    if not kept:
        raise WorkerError("cut-unsafe", "no meaningful programme audio remains after ad detection")
    outputs = len(points) + 1
    kept_outputs = set(kept)
    filters = [
        "[0:a]asegment=timestamps=" + "|".join(f"{point:.{_POINT_DECIMALS}f}" for point in points)
        + "".join(f"[s{index}]" for index in range(outputs))
    ]
    for index in range(outputs):
        if index in kept_outputs:
            filters.append(f"[s{index}]asetpts=PTS-STARTPTS[k{index}]")
        else:
            filters.append(f"[s{index}]anullsink")
    filters.append("".join(f"[k{index}]" for index in kept) + f"concat=n={len(kept)}:v=0:a=1[outc]")
    # libmp3lame's FLTP path rejects any frame with
    # linesize < 4 * FFALIGN(nb_samples, 8); concat's output frames routinely
    # fail that check at non-frame-aligned split points, so resample once more
    # to force fully-padded frames before the encoder ever sees them.
    filters.append("[outc]aresample[outa]")
    return ";".join(filters)
