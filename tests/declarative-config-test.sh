#!/bin/bash

# The quoted strings below are fixtures and static source assertions; their
# shell-looking contents must remain literal.
# shellcheck disable=SC2016

set -eu

if [ "$(id -u)" -ne 0 ]
then
  echo "declarative-config-test.sh must run as root" >&2
  exit 1
fi

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(dirname "$TEST_DIR")
readonly REPO_ROOT
HELPER_SOURCE="$REPO_ROOT/pi-gen-sources/00-teslausb-tweaks/files/teslausb_config.py"
LOADER="$REPO_ROOT/pi-gen-sources/00-teslausb-tweaks/files/teslausb-config-loader.sh"
readonly HELPER_SOURCE LOADER
TEST_TMP=$(mktemp -d /tmp/teslausb-declarative-test.XXXXXX)
readonly TEST_TMP
cleanup() {
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

release_state="$TEST_TMP/application-releases"
live_bin="$TEST_TMP/live-bin"
release_dir="$release_state/releases/v1"
install -d -o root -g root -m 0700 \
  "$release_state" "$release_state/releases" "$release_dir" \
  "$release_dir/root-bin" "$live_bin"
install -o root -g root -m 0700 "$HELPER_SOURCE" \
  "$release_dir/root-bin/teslausb_config.py"
ln -s "$release_dir" "$release_state/current"
ln -s "$release_state/current/root-bin/teslausb_config.py" \
  "$live_bin/teslausb_config.py"
export TESLAUSB_CONFIG_RELEASE_STATE_DIR="$release_state"
export TESLAUSB_CONFIG_LIVE_BIN="$live_bin"

cat > "$TEST_TMP/teslausb_setup.json" <<'JSON'
{
  "schema_version": 1,
  "variables": {
    "SSID": "Garage $(touch /tmp/teslausb-config-was-executed)",
    "WIFIPASS": "literal $HOME and `whoami`",
    "WIFI_COUNTRY": "US",
    "ARCHIVE_SYSTEM": "none",
    "CAM_SIZE": "40G",
    "ARCHIVE_RECENTCLIPS": false,
    "RCLONE_FLAGS": ["--transfers", "2"]
  }
}
JSON
chown root:root "$TEST_TMP/teslausb_setup.json"
chmod 0600 "$TEST_TMP/teslausb_setup.json"
rm -f /tmp/teslausb-config-was-executed

# shellcheck source=/dev/null
source "$LOADER"
# setup-teslausb and envsetup.sh can discover the same loader in one shell.
# A repeated source must remain a harmless no-op despite readonly schema data.
# shellcheck source=/dev/null
source "$LOADER"

mode_config="$TEST_TMP/mode-normalization.json"
install -o root -g root -m 0644 "$TEST_TMP/teslausb_setup.json" "$mode_config"
teslausb_secure_config "$mode_config"
[ "$(stat -c '%u:%g:%a' -- "$mode_config")" = 0:0:600 ] || {
  echo 'declarative loader did not normalize a root-owned config to mode 0600' >&2
  exit 1
}

symlink_config="$TEST_TMP/symlink-config.json"
ln -s "$mode_config" "$symlink_config"
if teslausb_secure_config "$symlink_config" > /dev/null 2>&1
then
  echo 'declarative loader accepted a symbolic-link config' >&2
  exit 1
fi

wrong_owner_config="$TEST_TMP/wrong-owner.json"
install -o root -g root -m 0600 "$TEST_TMP/teslausb_setup.json" \
  "$wrong_owner_config"
if chown 65534:65534 "$wrong_owner_config" 2> /dev/null
then
  if teslausb_secure_config "$wrong_owner_config" > /dev/null 2>&1
  then
    echo 'declarative loader accepted a config not owned by root:root' >&2
    exit 1
  fi
else
  echo 'SKIP: local system cannot create a wrong-owner config fixture' >&2
fi

teslausb_load_json_config "$TEST_TMP/teslausb_setup.json"

[ "$TESLAUSB_CONFIG_FORMAT" = json ]
[ "$SSID" = 'Garage $(touch /tmp/teslausb-config-was-executed)' ]
[ "$WIFIPASS" = 'literal $HOME and `whoami`' ]
[ "$WIFI_COUNTRY" = US ]
[ "$ARCHIVE_RECENTCLIPS" = false ]
[ "${#RCLONE_FLAGS[@]}" -eq 2 ]
[ "${RCLONE_FLAGS[0]}" = --transfers ]
[ "${RCLONE_FLAGS[1]}" = 2 ]
[ ! -e /tmp/teslausb-config-was-executed ]

# The normal helper remains usable after transactional activation, where the
# stable live path is an exact symlink through application-releases/current.
[ "$(teslausb_config_helper)" = "$live_bin/teslausb_config.py" ]

cat > "$TEST_TMP/unknown.json" <<'JSON'
{"schema_version":1,"variables":{"ARCHIVE_SYSTEM":"none","CAM_SIZE":"40G","BASH_ENV":"/tmp/pwn"}}
JSON
chown root:root "$TEST_TMP/unknown.json"
chmod 0600 "$TEST_TMP/unknown.json"
if teslausb_load_json_config "$TEST_TMP/unknown.json" > /dev/null 2>&1
then
  echo "declarative loader accepted an unsupported variable" >&2
  exit 1
fi

upgrade_dir="$TEST_TMP/upgrade"
install -d -o root -g root -m 0700 "$upgrade_dir"
cat > "$upgrade_dir/teslausb_config.py" <<'SH'
#!/bin/bash
if [ "$1" = validate ]
then
  exit 0
fi
exit 23
SH
chown root:root "$upgrade_dir/teslausb_config.py"
chmod 0700 "$upgrade_dir/teslausb_config.py"
export TESLAUSB_UPGRADE_DIR="$upgrade_dir"
export TESLAUSB_CONFIG_HELPER="$upgrade_dir/teslausb_config.py"
if teslausb_load_json_config "$TEST_TMP/teslausb_setup.json" > /dev/null 2>&1
then
  echo "declarative loader ignored an emitter failure" >&2
  exit 1
fi

cat > "$upgrade_dir/teslausb_config.py" <<'SH'
#!/bin/bash
if [ "$1" = validate ]
then
  exit 0
fi
if [ "$1" = emit0 ]
then
  printf 'S\0BASH_ENV\0/tmp/teslausb-loader-owned\0'
  exit 0
fi
exit 2
SH
chown root:root "$upgrade_dir/teslausb_config.py"
chmod 0700 "$upgrade_dir/teslausb_config.py"
unset BASH_ENV
if teslausb_load_json_config "$TEST_TMP/teslausb_setup.json" > /dev/null 2>&1
then
  echo "declarative loader trusted a replacement helper's variable name" >&2
  exit 1
fi
[ -z "${BASH_ENV+x}" ]

cat > "$upgrade_dir/teslausb_config.py" <<'SH'
#!/bin/bash
if [ "$1" = validate ]
then
  exit 0
fi
if [ "$1" = emit0 ]
then
  printf 'S\0RCLONE_FLAGS\0--config=/tmp/owned\0'
  exit 0
fi
exit 2
SH
chown root:root "$upgrade_dir/teslausb_config.py"
chmod 0700 "$upgrade_dir/teslausb_config.py"
if teslausb_load_json_config "$TEST_TMP/teslausb_setup.json" > /dev/null 2>&1
then
  echo "declarative loader accepted a scalar record for an array variable" >&2
  exit 1
fi

outside_helper="$TEST_TMP/outside-helper"
install -o root -g root -m 0700 "$HELPER_SOURCE" "$outside_helper"
export TESLAUSB_CONFIG_HELPER="$outside_helper"
if teslausb_load_json_config "$TEST_TMP/teslausb_setup.json" > /dev/null 2>&1
then
  echo "declarative loader accepted a helper outside the private upgrade directory" >&2
  exit 1
fi

# Downstream consumers retain structural defenses even if called with legacy
# variables instead of the strict JSON loader.
if grep -Eq 'eval[[:space:]]+"?\$commandline' \
  "$REPO_ROOT/run/nfs_archive/verify-and-configure-archive.sh"
then
  echo "NFS archive setup still evaluates a constructed command line" >&2
  exit 1
fi
grep -F 'if "${mount_command[@]}"' \
  "$REPO_ROOT/run/nfs_archive/verify-and-configure-archive.sh" > /dev/null
grep -F 'fstab_escape' \
  "$REPO_ROOT/run/nfs_archive/verify-and-configure-archive.sh" > /dev/null
grep -F 'fstab_escape' \
  "$REPO_ROOT/run/cifs_archive/verify-and-configure-archive.sh" > /dev/null
grep -F 'create_archive_trigger_file' "$REPO_ROOT/run/archiveloop" > /dev/null
grep -F 'timezone_real=$(readlink -f -- "$timezone_path")' \
  "$REPO_ROOT/setup/pi/setup-teslausb" > /dev/null

echo "declarative config loader tests passed"
