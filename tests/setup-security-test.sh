#!/bin/bash -eu

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
envsetup="$repo_root/setup/pi/envsetup.sh"
setup_script="$repo_root/setup/pi/setup-teslausb"
partition_script="$repo_root/setup/pi/create-backingfiles-partition.sh"
rc_local="$repo_root/pi-gen-sources/00-teslausb-tweaks/files/rc.local"
configure_web="$repo_root/setup/pi/configure-web.sh"
configure_samba="$repo_root/setup/pi/configure-samba.sh"
configure_ssh="$repo_root/setup/pi/configure-ssh.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_absent() {
  if grep -Fq -- "$2" "$1"
  then
    fail "$1 unexpectedly contains: $2"
  fi
}

# Exercise the download-coordinate and hostname validators without sourcing
# envsetup's hardware-specific main body.
eval "$(sed -n '/^function validate_source_coordinates {$/,/^}$/p' "$envsetup")"
eval "$(sed -n '/^function validate_teslausb_hostname {$/,/^}$/p' "$envsetup")"
setup_config_message() { :; }

REPO=marcone
BRANCH=release/v1.2.1
validate_source_coordinates
for bad_repo in '../owner' 'owner/repo' 'owner?query' '-owner'
do
  if (REPO="$bad_repo"; BRANCH=main; validate_source_coordinates) 2>/dev/null
  then
    fail "source validator accepted REPO=$bad_repo"
  fi
done
for bad_branch in '../main' '/main' 'main/' 'main..evil' 'main?query' 'main//evil' '.hidden' 'main.lock'
do
  # shellcheck disable=SC2034 # Variables are consumed by the extracted function.
  if (REPO=marcone; BRANCH="$bad_branch"; validate_source_coordinates) 2>/dev/null
  then
    fail "source validator accepted BRANCH=$bad_branch"
  fi
done

TESLAUSB_HOSTNAME=teslausb-2
validate_teslausb_hostname
for bad_hostname in 'bad/name' 'bad&name' 'two.labels' '-leading' 'trailing-' ''
do
  # shellcheck disable=SC2034 # Variable is consumed by the extracted function.
  if (TESLAUSB_HOSTNAME="$bad_hostname"; validate_teslausb_hostname) 2>/dev/null
  then
    fail "hostname validator accepted $bad_hostname"
  fi
done

# DATA_DRIVE is checked at preflight and twice in the partition script, with
# the final call immediately before wipefs. Device identification is
# fail-closed and destructive conversion holds archiveloop's exact flock.
assert_contains "$envsetup" 'STOP: TESLAUSB_HOSTNAME must be a single 1-63 character DNS label.'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$partition_script" 'DATA_DRIVE ($DATA_DRIVE) is not a block device.'
assert_contains "$partition_script" 'unable to identify the disk containing the root filesystem.'
assert_contains "$partition_script" 'exec {ARCHIVELOOP_LOCK_FD}< /root/bin/archiveloop'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$partition_script" 'flock -n "$ARCHIVELOOP_LOCK_FD"'
assert_absent "$partition_script" 'killall archiveloop'
assert_absent "$setup_script" 'killall archiveloop'

wipe_line="$(grep -n '^[[:space:]]*wipefs -afq' "$partition_script" | cut -d: -f1)"
[ -n "$wipe_line" ] || fail 'wipefs call not found'
previous_noncomment="$(head -n "$((wipe_line - 1))" "$partition_script" | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' | tail -n 1)"
case "$previous_noncomment" in
  *refuse_system_data_drive*) ;;
  *) fail 'the second DATA_DRIVE safety check is not immediately before wipefs' ;;
esac
[ "$(grep -c '^[[:space:]]*refuse_system_data_drive$' "$partition_script")" -ge 2 ] ||
  fail 'partition script lacks two DATA_DRIVE safety calls'

# Root configuration is accepted only as a root-owned regular 0600 file, and
# config validation no longer writes predictable or inherited temp output.
for config_loader in "$envsetup" "$setup_script" "$rc_local"
do
  assert_contains "$config_loader" 'must have mode 0600'
  assert_contains "$config_loader" 'must be owned by root:root'
  assert_absent "$config_loader" 'config-check.out'
done
assert_absent "$rc_local" '/tmp/checksetupconf'

# Downloads are bounded; URL coordinates are checked before interpolation.
assert_contains "$setup_script" '--connect-timeout 15 --max-time 300'
assert_contains "$rc_local" '--connect-timeout 15 --max-time 120'
assert_contains "$setup_script" 'validate_source_coordinates || exit 1'
assert_contains "$rc_local" 'if ! validate_source_coordinates'

# Wi-Fi and hostname values are passed as data, not interpolated into sed
# programs. The plaintext passphrase comment produced by wpa_passphrase is
# removed before either config copy is installed.
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$rc_local" 'wpa_passphrase "$SSID"'
assert_contains "$rc_local" "sed '/^[[:space:]]*#psk=/d'"
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_absent "$rc_local" '"$wpa_config" /teslausb/wpa_supplicant.conf'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$rc_local" 'awk -v old="$old_host_name" -v new="$new_host_name"'
assert_absent "$rc_local" 'TEMPSSID'
assert_absent "$rc_local" 'TEMPPASS'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_absent "$setup_script" 'sed -i -e "s/$old_host_name/$new_host_name/g"'

# No setup path may override apt authentication failures. Samba never creates
# raspberry/raspberry and non-guest mode requires explicit strong credentials.
if grep -R -F --include='*.sh' --include='setup-teslausb' --include='rc.local' \
     -- '--force-yes' "$repo_root/setup" "$repo_root/pi-gen-sources" > /dev/null
then
  fail 'setup still uses apt --force-yes'
fi
assert_absent "$configure_samba" 'raspberry\nraspberry'
assert_contains "$configure_samba" 'SAMBA_PASSWORD is required when SAMBA_GUEST is false.'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$configure_samba" 'smbpasswd -s -a "$SAMBA_USER"'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$configure_ssh" 'ssh-keygen -l -f "$authorized_keys_tmp"'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$configure_ssh" 'mv -fT -- "$authorized_keys_tmp" "$ssh_dir/authorized_keys"'
assert_contains "$rc_local" 'SSH_USER_PASSWORD must be a non-default password of at least 12 bytes.'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$rc_local" 'ssh-keygen -l -f "$authorized_keys_tmp"'

# Checked-in CGI modes are normalized during every deployment, including API
# files newly created on filesystems that do not preserve executable bits.
assert_contains "$configure_web" "find /var/www/html/cgi-bin -xdev -type f -name '*.sh' -exec chmod 0755"

printf 'setup security tests passed\n'
