#!/usr/bin/python3
"""Stable entry point for the reviewed, reversible modern UI installer.

Keep the dated implementation beside this file. Existing callers can continue
using its original name; both entry points run the same validation and guards.
"""

from pathlib import Path
import runpy


if __name__ == "__main__":
    runpy.run_path(
        str(Path(__file__).resolve().with_name("modern-install-20260908.py")),
        run_name="__main__",
    )
