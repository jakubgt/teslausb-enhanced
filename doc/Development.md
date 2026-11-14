# Development and formatting

The [Validate workflow](../.github/workflows/shellcheck.yml) is the authoritative
list of checks and required Linux dependencies. It includes shell analysis,
Python and JavaScript tests, configuration checks, archive integration tests,
and Chromium tests. `./check.sh` runs shell syntax analysis and ShellCheck; it
does not run the complete suite.

## Modern UI formatting

`.prettierignore` preserves the legacy web tree while allowing files below
`teslausb-www/html/modern/` to be formatted. Keep formatting changes focused on
the files being edited, rather than reformatting unrelated upstream assets.
For example, on a development machine with pnpm:

```sh
pnpm dlx prettier@3.10.1 --check teslausb-www/html/modern/device.js
pnpm dlx prettier@3.10.1 --write teslausb-www/html/modern/device.js
```

Prettier is a development tool. It is not required on the Pi, and formatting is
not a replacement for the functional and browser checks.

## Stable installer entry point

`tools/modern-install.py` is the stable entry point for the reviewed manual
modern UI installer. It delegates to `tools/modern-install-20260908.py`, which
remains available for existing callers. Keep both files together from the same
reviewed source checkout. To inspect the command without installing anything:

```sh
python3 tools/modern-install.py --help
```

Both names retain the same package validation, fixed destination allowlist,
root/Linux requirements, backups, and recovery guards. This is a compatibility
entry point, not a new automatic update mechanism.

Use descriptive, date-independent names for new maintained entry points. Keep
existing CGI paths, service names, and privileged command references compatible;
renaming them requires reviewing their callers and permission rules together.
