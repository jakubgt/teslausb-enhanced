#! /bin/bash

set -eu

shopt -s globstar nullglob extglob

# print shellcheck version so we know what Github uses
shellcheck -V

# Every version-controlled shell entrypoint gets syntax validation and
# ShellCheck's error-severity diagnostics. The stricter curated pass below is
# expanded incrementally as legacy warnings are addressed.
shell_files=()
while IFS= read -r -d '' file
do
  first_line=
  IFS= read -r first_line < "$file" || true
  case "$first_line" in
    '#!'*sh*)
      shell_files+=("$file")
      ;;
  esac
done < <(git ls-files -z)

if [ "${#shell_files[@]}" -eq 0 ]
then
  echo "No shell scripts found" >&2
  exit 1
fi

for file in "${shell_files[@]}"
do
  IFS= read -r first_line < "$file" || true
  case "$first_line" in
    '#!'*/dash*) dash -n "$file" ;;
    *) bash -n "$file" ;;
  esac
done
shellcheck --severity=error --exclude=SC1091 "${shell_files[@]}"

# SC1091 - Don't complain about not being able to find files that don't exist.
shellcheck --exclude=SC1091 \
           ./check.sh \
           ./setup/pi/setup-teslausb \
           ./setup/pi/configure-web.sh \
           ./setup/pi/install-tesla-ble-artifact.sh \
           ./pi-gen-sources/00-teslausb-tweaks/files/rc.local \
           ./run/archiveloop \
           ./run/auto.teslausb \
           ./run/auto.www \
           ./run/awake_start \
           ./run/awake_stop \
           ./run/archive-common.sh \
           ./run/archive-rsync-local.sh \
           ./run/keep-awake-pid.sh \
           ./run/cifs_archive/verify-and-configure-archive.sh \
           ./run/cifs_archive/archive-clips.sh \
           ./run/copy-music.sh \
           ./run/force_sync.sh \
           ./run/make_snapshot.sh \
           ./run/mountimage \
           ./run/mountoptsforimage \
           ./run/remountfs_rw \
           ./run/send-push-message \
           ./run/nfs_archive/archive-clips.sh \
           ./run/rclone_archive/archive-clips.sh \
           ./run/rsync_archive/archive-clips.sh \
           ./run/temperature_monitor \
           ./run/waitforidle \
           ./teslausb-www/teslausb-web-sudo \
           ./teslausb-www/html/cgi-bin/api-v1.sh \
           ./teslausb-www/html/cgi-bin/cgi-common.sh \
           ./teslausb-www/html/cgi-bin/checkBLEstatus.sh \
           ./teslausb-www/html/cgi-bin/config.sh \
           ./teslausb-www/html/cgi-bin/cp.sh \
           ./teslausb-www/html/cgi-bin/diagnose.sh \
           ./teslausb-www/html/cgi-bin/download.sh \
           ./teslausb-www/html/cgi-bin/downloadzip.sh \
           ./teslausb-www/html/cgi-bin/ls.sh \
           ./teslausb-www/html/cgi-bin/mkdir.sh \
           ./teslausb-www/html/cgi-bin/mv.sh \
           ./teslausb-www/html/cgi-bin/pairBLEkey.sh \
           ./teslausb-www/html/cgi-bin/randomdata.sh \
           ./teslausb-www/html/cgi-bin/reboot.sh \
           ./teslausb-www/html/cgi-bin/reload.sh \
           ./teslausb-www/html/cgi-bin/rm.sh \
           ./teslausb-www/html/cgi-bin/status.sh \
           ./teslausb-www/html/cgi-bin/toggledrives.sh \
           ./teslausb-www/html/cgi-bin/trigger_sync.sh \
           ./teslausb-www/html/cgi-bin/upload.sh \
           ./teslausb-www/html/cgi-bin/videolist.sh \
           ./tests/cgi-security-test.sh \
           ./tests/archive-common-test.sh \
           ./tests/ble-artifact-test.sh \
           ./tests/copy-music-test.sh \
           ./tests/dependency-strategy-test.sh \
           ./tests/make-snapshot-failure-test.sh \
           ./tests/mount-helpers-test.sh \
           ./tests/runtime-qol-test.sh \
           ./tests/setup-security-test.sh \
           ./tests/web-config-security-test.sh
