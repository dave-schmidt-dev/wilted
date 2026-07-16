"""Pipeline stage handlers invoked by :class:`~wilted.pipeline_runner.PipelineRunner`."""

from wilted.handlers.briefing import handle_briefing
from wilted.handlers.classify import handle_classify
from wilted.handlers.discover import handle_discover
from wilted.handlers.prepare import handle_prepare
from wilted.handlers.report import handle_report

__all__ = [
    "handle_briefing",
    "handle_classify",
    "handle_discover",
    "handle_prepare",
    "handle_report",
]
