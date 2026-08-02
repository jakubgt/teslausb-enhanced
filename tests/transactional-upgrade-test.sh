#!/bin/bash

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
manager_script="$repo_root/setup/pi/transactional-upgrade.sh"
setup_script="$repo_root/setup/pi/setup-teslausb"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

state_dir="$test_root/state"
live_bin="$test_root/live-bin"
source_dir="$test_root/source"
os_release="$test_root/os-release"
model_file="$test_root/model"
finished_marker="$test_root/TESLAUSB_SETUP_FINISHED"
fake_systemctl="$test_root/systemctl"
fake_sleep="$test_root/sleep"
health_failure="$test_root/health-failure"
delayed_restart="$test_root/delayed-restart"
restart_count="$test_root/restart-count"

function fail {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

function assert_file_contains {
  grep -F -- "$2" "$1" > /dev/null || fail "$1 does not contain: $2"
}

function assert_file_not_contains {
  if grep -F -- "$2" "$1" > /dev/null
  then
    fail "$1 unexpectedly contains: $2"
  fi
}

assert_file_contains "$setup_script" "\"\$TESLAUSB_TRANSACTION_MANAGER\" prepare \"\$SOURCE_DIR\""
assert_file_contains "$setup_script" "\"\$TESLAUSB_TRANSACTION_MANAGER\" finalize \"\$TESLAUSB_UPGRADE_STAGING_DIR\""
assert_file_contains "$setup_script" "\"\$TESLAUSB_TRANSACTION_MANAGER\" abort \"\$TESLAUSB_UPGRADE_STAGING_DIR\""
assert_file_contains "$setup_script" "teslausb_secure_config \"\$TESLAUSB_CONFIG_PATH\""
assert_file_contains "$setup_script" 'copy_script setup/pi/transactional-upgrade.sh /root/bin teslausb-upgrade'
assert_file_contains "$setup_script" 'TESLAUSB_TRANSACTIONAL_UPGRADE=1 NO_REBOOT_PROMPT=1'
assert_file_contains "$setup_script" "stop_if_transaction_requires_reboot 'the dwc2 boot overlay change'"
assert_file_contains "$setup_script" 'stop_required_service_for_upgrade teslausb.service'
assert_file_contains "$setup_script" 'stop_optional_service_for_upgrade smbd.service'
assert_file_contains "$setup_script" 'disable_gadget_for_upgrade'
assert_file_contains "$setup_script" "unmount_if_mounted_for_upgrade \"\$mount_path\""
assert_file_not_contains "$setup_script" 'systemctl stop teslausb.service || true'
assert_file_not_contains "$setup_script" '/root/bin/disable_gadget.sh || true'
assert_file_contains "$setup_script" 'ExecStart=/usr/local/libexec/teslausb-upgrade-recovery recover'
assert_file_contains "$setup_script" 'Requires=teslausb-upgrade-recovery.service'
assert_file_contains "$setup_script" "bash -n \"\$source_helper\""
assert_file_contains "$setup_script" "source_sum=\$(sha256sum \"\$source_helper\""
assert_file_contains "$setup_script" "mv -Tf -- \"\$temporary_helper\" \"\$recovery_helper\""
assert_file_contains "$manager_script" 'recover_pending_activation true'
assert_file_contains "$manager_script" "SERVICE_STABILITY_SECONDS=\${TESLAUSB_SERVICE_STABILITY_SECONDS:-7}"
assert_file_contains "$repo_root/pi-gen-sources/pi-gen-config" 'RELEASE=trixie'
assert_file_contains "$repo_root/pi-gen-sources/pi-gen-config" 'PASSWORDLESS_SUDO=0'
assert_file_contains "$repo_root/pi-gen-sources/pi-gen-config" 'ENABLE_CLOUD_INIT=0'
assert_file_contains "$repo_root/pi-gen-sources/Readme.md" 'git clone --branch arm64'
assert_file_contains "$repo_root/pi-gen-sources/00-teslausb-tweaks/00-packages" 'ntpsec-ntpdig'
assert_file_contains "$repo_root/setup/pi/make-root-fs-readonly.sh" 'ntpsec ntpsec-ntpdig busybox-syslogd'

function write_os_release {
  cat > "$os_release" <<EOF
ID=raspbian
VERSION_ID="$1"
PRETTY_NAME="Raspberry Pi OS"
EOF
}

function release_manager {
  env \
    TESLAUSB_UPGRADE_ALLOW_NON_ROOT=true \
    TESLAUSB_RELEASE_STATE_DIR="$state_dir" \
    TESLAUSB_RELEASE_LIVE_BIN="$live_bin" \
    TESLAUSB_OS_RELEASE_FILE="$os_release" \
    TESLAUSB_MODEL_FILE="$model_file" \
    TESLAUSB_SETUP_FINISHED_MARKER="$finished_marker" \
    TESLAUSB_SYSTEMCTL="$fake_systemctl" \
    TESLAUSB_UPGRADE_MIN_FREE_KIB=1 \
    TESLAUSB_HEALTH_RETRIES=1 \
    TESLAUSB_SERVICE_STABILITY_SECONDS=2 \
    TESLAUSB_HEALTH_SLEEP="$fake_sleep" \
    TESLAUSB_UPGRADE_ARCHITECTURE="${TEST_ARCHITECTURE:-aarch64}" \
    TESLAUSB_UPGRADE_TEST_ABANDON_AFTER_SWITCH="${TEST_ABANDON_AFTER_SWITCH:-false}" \
    FAKE_SYSTEMCTL_HEALTH_FAILURE="$health_failure" \
    FAKE_SYSTEMCTL_DELAYED_RESTART="$delayed_restart" \
    FAKE_SYSTEMCTL_RESTART_COUNT="$restart_count" \
    "$manager_script" "$@"
}

mkdir -p "$live_bin" "$source_dir/setup/pi" "$source_dir/run"
touch "$finished_marker"
printf 'Raspberry Pi Zero 2 W Rev 1.0\000' > "$model_file"
write_os_release 13

cat > "$fake_systemctl" <<'EOF'
#!/bin/bash
set -eu
case "$1" in
  is-enabled) exit 0 ;;
  restart) exit 0 ;;
  is-active)
    [ ! -e "$FAKE_SYSTEMCTL_HEALTH_FAILURE" ]
    ;;
  show)
    cat "$FAKE_SYSTEMCTL_RESTART_COUNT"
    ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$fake_systemctl"

cat > "$fake_sleep" <<'EOF'
#!/bin/bash
set -eu
if [ -e "$FAKE_SYSTEMCTL_DELAYED_RESTART" ]
then
  current=$(cat "$FAKE_SYSTEMCTL_RESTART_COUNT")
  printf '%s\n' "$((current + 1))" > "$FAKE_SYSTEMCTL_RESTART_COUNT"
  rm -f "$FAKE_SYSTEMCTL_DELAYED_RESTART"
fi
EOF
chmod 0755 "$fake_sleep"
printf '0\n' > "$restart_count"

cat > "$live_bin/setup-teslausb" <<'EOF'
#!/bin/bash
echo old-setup
EOF
cat > "$live_bin/archiveloop" <<'EOF'
#!/bin/bash
echo old-archive
EOF
cat > "$live_bin/obsolete-tool" <<'EOF'
#!/bin/bash
echo old-obsolete
EOF
chmod 0755 "$live_bin/setup-teslausb" "$live_bin/archiveloop" \
  "$live_bin/obsolete-tool"

printf '1.1.0\n' > "$source_dir/VERSION"
cat > "$source_dir/setup/pi/setup-teslausb" <<'EOF'
#!/bin/bash
echo new-setup
EOF
cat > "$source_dir/run/archiveloop" <<'EOF'
#!/bin/bash
echo new-archive
EOF
cat > "$source_dir/run/obsolete-tool" <<'EOF'
#!/bin/bash
echo new-obsolete
EOF
cp "$manager_script" "$source_dir/setup/pi/transactional-upgrade.sh"
chmod 0755 "$source_dir/setup/pi/setup-teslausb" \
  "$source_dir/run/archiveloop" \
  "$source_dir/run/obsolete-tool" \
  "$source_dir/setup/pi/transactional-upgrade.sh"

candidate=$(release_manager prepare "$source_dir")
[ -d "$candidate" ] || fail 'prepare did not create a private candidate'
release_manager stage-file "$candidate" \
  "$source_dir/setup/pi/setup-teslausb" setup-teslausb
release_manager stage-file "$candidate" \
  "$source_dir/run/archiveloop" archiveloop
release_manager stage-file "$candidate" \
  "$source_dir/run/obsolete-tool" obsolete-tool
release_manager stage-file "$candidate" \
  "$source_dir/setup/pi/transactional-upgrade.sh" teslausb-upgrade

if release_manager stage-file "$candidate" \
     "$source_dir/run/archiveloop" '../escape' > /dev/null 2>&1
then
  fail 'stage-file accepted a traversal destination'
fi
if ln -s "$source_dir/run/archiveloop" "$test_root/symlink-input" 2> /dev/null
then
  if release_manager stage-file "$candidate" \
       "$test_root/symlink-input" symlink-input > /dev/null 2>&1
  then
    fail 'stage-file accepted a symbolic-link input'
  fi
else
  printf 'SKIP: local filesystem cannot create symbolic links\n' >&2
fi

new_release=$(release_manager finalize "$candidate")
[ -d "$new_release" ] || fail 'finalize did not create an immutable release'
[ "$(readlink -f "$state_dir/current")" = "$new_release" ] || \
  fail 'current was not switched to the new release'
[ "$(readlink -f "$state_dir/last-known-good")" = "$new_release" ] || \
  fail 'last-known-good was not advanced after health checks'
[ -L "$live_bin/setup-teslausb" ] || fail 'setup-teslausb is not a stable release link'
[ "$(readlink "$live_bin/setup-teslausb")" = \
  "$state_dir/current/root-bin/setup-teslausb" ] || \
  fail 'setup-teslausb link bypasses the atomic current pointer'
assert_file_contains "$live_bin/setup-teslausb" new-setup
assert_file_contains "$live_bin/archiveloop" new-archive
assert_file_contains "$live_bin/obsolete-tool" new-obsolete
release_manager verify "$new_release"
assert_file_contains "$new_release/release.properties" 'format=1'
assert_file_contains "$new_release/release.properties" 'version=1.1.0'
assert_file_contains "$new_release/release.properties" 'os_major=13'
assert_file_contains "$new_release/release.properties" 'architecture=aarch64'
assert_file_contains "$new_release/manifest.sha256" 'root-bin/setup-teslausb'

bootstrap_release=$(readlink -f "$state_dir/previous")
[ "$bootstrap_release" != "$new_release" ] || fail 'bootstrap rollback release was not retained'
assert_file_contains "$bootstrap_release/root-bin/setup-teslausb" old-setup

rolled_back=$(release_manager rollback)
[ "$rolled_back" = "$bootstrap_release" ] || fail 'manual rollback selected the wrong release'
assert_file_contains "$live_bin/setup-teslausb" old-setup
assert_file_contains "$live_bin/archiveloop" old-archive
assert_file_contains "$live_bin/obsolete-tool" old-obsolete
[ -x "$live_bin/teslausb-upgrade" ] || fail 'rollback control plane disappeared with the old release'

# A later candidate that cannot make its required service healthy must restore
# the active release without leaving a mixed set of runtime files.
cat > "$source_dir/setup/pi/setup-teslausb" <<'EOF'
#!/bin/bash
echo unhealthy-new-setup
EOF
candidate=$(release_manager prepare "$source_dir")
release_manager stage-file "$candidate" \
  "$source_dir/setup/pi/setup-teslausb" setup-teslausb
release_manager stage-file "$candidate" \
  "$source_dir/run/archiveloop" archiveloop
touch "$health_failure"
if release_manager finalize "$candidate" > "$test_root/unhealthy.out" 2> "$test_root/unhealthy.err"
then
  fail 'an unhealthy release was activated'
fi
rm -f "$health_failure"
assert_file_contains "$test_root/unhealthy.err" 'atomically restored'
[ "$(readlink -f "$state_dir/current")" = "$bootstrap_release" ] || \
  fail 'failed activation did not restore the prior release'
assert_file_contains "$live_bin/setup-teslausb" old-setup
assert_file_contains "$live_bin/archiveloop" old-archive
assert_file_contains "$live_bin/obsolete-tool" old-obsolete

# A required service that initially reports active but increments systemd's
# automatic restart counter during the stability window is a crash loop, not a
# healthy activation.
cat > "$source_dir/setup/pi/setup-teslausb" <<'EOF'
#!/bin/bash
echo crash-loop-setup
EOF
candidate=$(release_manager prepare "$source_dir")
release_manager stage-file "$candidate" \
  "$source_dir/setup/pi/setup-teslausb" setup-teslausb
release_manager stage-file "$candidate" \
  "$source_dir/run/archiveloop" archiveloop
printf '0\n' > "$restart_count"
touch "$delayed_restart"
if release_manager finalize "$candidate" > "$test_root/crash-loop.out" \
     2> "$test_root/crash-loop.err"
then
  fail 'a delayed required-service crash loop was activated'
fi
assert_file_contains "$test_root/crash-loop.err" 'restart loop'
[ "$(readlink -f "$state_dir/current")" = "$bootstrap_release" ] || \
  fail 'crash-loop activation did not restore the prior release'
[ ! -e "$state_dir/pending-activation" ] || \
  fail 'normal health rollback retained its activation journal'
printf '0\n' > "$restart_count"

# Simulated uncatchable process loss must leave a persistent journal, and the
# same command used by the boot oneshot must restore known-good before the
# service is allowed to start.
cat > "$source_dir/setup/pi/setup-teslausb" <<'EOF'
#!/bin/bash
echo interrupted-setup
EOF
candidate=$(release_manager prepare "$source_dir")
release_manager stage-file "$candidate" \
  "$source_dir/setup/pi/setup-teslausb" setup-teslausb
release_manager stage-file "$candidate" \
  "$source_dir/run/archiveloop" archiveloop
TEST_ABANDON_AFTER_SWITCH=true
export TEST_ABANDON_AFTER_SWITCH
if release_manager finalize "$candidate" > "$test_root/interrupted.out" \
     2> "$test_root/interrupted.err"
then
  fail 'process-loss injection unexpectedly completed activation'
fi
unset TEST_ABANDON_AFTER_SWITCH
[ -f "$state_dir/pending-activation" ] || \
  fail 'uncatchable interruption did not retain a recovery journal'
interrupted_release=$(readlink -f "$state_dir/current")
[ "$interrupted_release" != "$bootstrap_release" ] || \
  fail 'interruption injection occurred before the current pointer switched'
release_manager recover
[ "$(readlink -f "$state_dir/current")" = "$bootstrap_release" ] || \
  fail 'boot recovery did not restore the journaled known-good release'
[ "$(readlink -f "$state_dir/last-known-good")" = "$bootstrap_release" ] || \
  fail 'boot recovery left a stale last-known-good pointer'
[ ! -e "$state_dir/pending-activation" ] || \
  fail 'successful boot recovery did not clear its journal'
assert_file_contains "$live_bin/setup-teslausb" old-setup
assert_file_contains "$live_bin/obsolete-tool" old-obsolete

# The ordinary preflight path is a second recovery entrypoint for an operator
# retrying an upgrade before rebooting.
cat > "$state_dir/pending-activation" <<EOF
format=1
old_release=$(basename "$bootstrap_release")
new_release=$(basename "$interrupted_release")
EOF
ln -sfn -- "$interrupted_release" "$state_dir/current"
release_manager preflight
[ "$(readlink -f "$state_dir/current")" = "$bootstrap_release" ] || \
  fail 'preflight did not recover a pending activation'
[ ! -e "$state_dir/pending-activation" ] || \
  fail 'preflight recovery did not clear its journal'

# Any post-activation corruption must be detected by the stored checksums.
chmod u+w "$new_release/root-bin/archiveloop"
printf '# tampered\n' >> "$new_release/root-bin/archiveloop"
if release_manager verify "$new_release" > /dev/null 2>&1
then
  fail 'checksum verification accepted a modified release file'
fi

# The application updater must never present a distribution upgrade as safe.
write_os_release 12
if release_manager preflight > "$test_root/bookworm.out" 2> "$test_root/bookworm.err"
then
  fail 'Bookworm passed the Trixie release preflight'
fi
assert_file_contains "$test_root/bookworm.err" 'cannot be converted to Trixie in place'
assert_file_contains "$test_root/bookworm.err" 'Flash a clean current Trixie image'

write_os_release 13
TEST_ARCHITECTURE=armv7l
export TEST_ARCHITECTURE
if release_manager preflight > "$test_root/armv7.out" 2> "$test_root/armv7.err"
then
  fail '32-bit architecture passed the arm64 release preflight'
fi
assert_file_contains "$test_root/armv7.err" 'architecture armv7l is unsupported'
unset TEST_ARCHITECTURE

candidate=$(release_manager prepare "$source_dir")
release_manager abort "$candidate"
[ ! -e "$candidate" ] || fail 'abort did not remove the private incomplete candidate'

# A future manifest may intentionally remove an entrypoint. Reconcile only
# stale links proven to resolve into the managed release tree; preserve an
# operator-owned link elsewhere. Rolling back must recreate the removed link.
printf 'operator target\n' > "$test_root/operator-target"
ln -s "$test_root/operator-target" "$live_bin/operator-link"
candidate=$(release_manager prepare "$source_dir")
release_manager stage-file "$candidate" \
  "$source_dir/setup/pi/setup-teslausb" setup-teslausb
release_manager stage-file "$candidate" \
  "$source_dir/run/archiveloop" archiveloop
release_manager stage-file "$candidate" \
  "$source_dir/setup/pi/transactional-upgrade.sh" teslausb-upgrade
reduced_release=$(release_manager finalize "$candidate")
[ "$(readlink -f "$state_dir/current")" = "$reduced_release" ] || \
  fail 'reduced manifest was not activated'
if [ -e "$live_bin/obsolete-tool" ] || [ -L "$live_bin/obsolete-tool" ]
then
  fail 'entrypoint removed from the manifest retained a stale managed link'
fi
[ -L "$live_bin/operator-link" ] || \
  fail 'reconciliation removed an operator-owned link outside the release tree'
[ "$(readlink -f "$live_bin/operator-link")" = "$test_root/operator-target" ] || \
  fail 'reconciliation changed an operator-owned link'

rolled_back=$(release_manager rollback)
[ "$rolled_back" = "$bootstrap_release" ] || \
  fail 'rollback after a reduced manifest selected the wrong release'
assert_file_contains "$live_bin/obsolete-tool" old-obsolete
[ -L "$live_bin/operator-link" ] || \
  fail 'rollback reconciliation removed an operator-owned link'

printf 'transactional upgrade tests passed\n'
