"""WiltedApp re-export shim.

WiltedApp is defined in wilted.tui.__init__ so that test patches like
``@patch("wilted.tui.get_playlist_items")`` intercept calls from WiltedApp
methods (Python resolves free variables in the defining module's __dict__
at call time).
"""

from wilted.tui import WiltedApp

__all__ = ["WiltedApp"]
