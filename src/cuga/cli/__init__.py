"""CLI package entry point.

Logging is configured *first*, before any ``cuga.*`` import, because a good deal
of this project's log output is emitted at module scope (``cuga.config``,
``base_agent``) — by the time Typer parses argv those records have already been
written. Mirrors the "configure diagnostics before heavy imports" ordering in
``cuga.backend.server.acp.stdio``.
"""

import logging
import os
import sys

from loguru import logger


def _resolve_log_level() -> str:
    """Stderr log level for the CLI.

    Quiet by default so ``cuga`` opens with CUGA's own output rather than a
    screenful of INFO. ``-v``/``--verbose`` is read straight from ``sys.argv``:
    Typer parses too late to gate import-time records.
    """
    if "-v" in sys.argv or "--verbose" in sys.argv:
        return "DEBUG"
    return os.environ.get("CUGA_LOG_LEVEL", "WARNING").upper()


_LOG_LEVEL = _resolve_log_level()

logger.remove()
logger.add(sys.stderr, level=_LOG_LEVEL)

# This project logs through both loguru and stdlib logging (e.g.
# logging.getLogger("cuga.demo") in backend.server.demo_manage_setup), so one
# level control has to drive both or the output stays half-quiet.
logging.getLogger().setLevel(_LOG_LEVEL)

# The registry / demo / CRM children are separate processes that never run this
# module, so they can't inherit the sink above. They do inherit the environment,
# and loguru's *default* handler reads LOGURU_LEVEL at import — so exporting it
# here quiets them with no code change on their side.
os.environ["LOGURU_LEVEL"] = _LOG_LEVEL

from cuga.cli.app_manager import AppManager  # noqa: E402
from cuga.cli.main import app, start_extension_browser_if_configured  # noqa: E402

__all__ = ["AppManager", "app", "start_extension_browser_if_configured"]
