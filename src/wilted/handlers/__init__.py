"""Pipeline stage handlers invoked by :class:`~wilted.pipeline_runner.PipelineRunner`."""

from wilted.handlers.classify import handle_classify
from wilted.handlers.prepare import handle_prepare

__all__ = [
    "handle_classify",
    "handle_prepare",
]
