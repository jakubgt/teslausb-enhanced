#!/bin/bash
# Generate diagnostics. flock guard so a concurrent trigger does not run a second
# diagnose or clobber the in-progress result file. setup-teslausb's own output
# ends with "====== end of diagnostics ======", which the web UI uses to detect
# completion, so no extra marker is written into the file.
LOCK=/tmp/diagnose.lock
exec 9>"$LOCK"
if flock -n 9; then
  (sudo /root/bin/setup-teslausb diagnose) &> /tmp/diagnostics.txt
  flock -u 9
fi

"$(dirname "$0")/reload.sh" "Sync triggered"
