#!/bin/bash -eu

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
envsetup="$repo_root/setup/pi/envsetup.sh"
setup_script="$repo_root/setup/pi/setup-teslausb"
partition_script="$repo_root/setup/pi/create-backingfiles-partition.sh"
rc_local="$repo_root/pi-gen-sources/00-teslausb-tweaks/files/rc.local"
config_library="$repo_root/pi-gen-sources/00-teslausb-tweaks/files/teslausb-config-loader.sh"
configure_web="$repo_root/setup/pi/configure-web.sh"
configure_samba="$repo_root/setup/pi/configure-samba.sh"
configure_ssh="$repo_root/setup/pi/configure-ssh.sh"
pi_gen_run="$repo_root/pi-gen-sources/00-teslausb-tweaks/00-run.sh"
pi_gen_config="$repo_root/pi-gen-sources/pi-gen-config"

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

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
eval "$(sed -n '/^function lock_image_account () {$/,/^}$/p' "$pi_gen_run")"
eval "$(sed -n '/^function verify_source_bundle () {$/,/^}$/p' "$pi_gen_run")"
eval "$(sed -n '/^function verify_tzupdate_checksum () {$/,/^}$/p' "$setup_script")"
eval "$(sed -n '/^function set_timezone () {$/,/^}$/p' "$setup_script")"
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

# The known pi-gen password is locked in the offline root filesystem before
# the image can boot. The rewrite is idempotent and fails closed when the
# configured account is absent.
fake_rootfs="$test_root/fake-rootfs"
mkdir -p "$fake_rootfs/etc"
locked_password="!\$6\$saltsalt\$hashhash"
unlocked_password="${locked_password#!}"
printf '%s\n' \
  'root:*:20000:0:99999:7:::' \
  "pi:${unlocked_password}:20000:0:99999:7:::" \
  'service:!:20000:0:99999:7:::' > "$fake_rootfs/etc/shadow"
chmod 0640 "$fake_rootfs/etc/shadow"
shadow_metadata_before="$(stat -c '%u:%g:%a' "$fake_rootfs/etc/shadow")"
service_shadow_before="$(grep '^service:' "$fake_rootfs/etc/shadow")"
lock_image_account "$fake_rootfs" pi
[ "$(awk -F: '$1 == "pi" { print $2 }' "$fake_rootfs/etc/shadow")" = \
  "$locked_password" ] || fail 'pi-gen image account was not locked'
[ "$(grep '^service:' "$fake_rootfs/etc/shadow")" = "$service_shadow_before" ] ||
  fail 'locking the image account changed another shadow record'
[ "$(stat -c '%u:%g:%a' "$fake_rootfs/etc/shadow")" = "$shadow_metadata_before" ] ||
  fail 'locking the image account changed shadow owner, group, or mode'
lock_image_account "$fake_rootfs" pi
[ "$(awk -F: '$1 == "pi" { print $2 }' "$fake_rootfs/etc/shadow")" = \
  "$locked_password" ] || fail 'image-account lock is not idempotent'

# Image source provenance is checked before and after installation. The
# verifier rejects content changes, forged metadata, unrecorded files, and
# symlinks instead of blindly accepting a copied source tree.
source_bundle="$test_root/source-bundle"
mkdir -p "$source_bundle/nested"
printf 'runtime source\n' > "$source_bundle/runtime"
printf 'nested provenance-named source\n' > "$source_bundle/nested/SOURCE-METADATA"
(
  cd "$source_bundle"
  while IFS= read -r -d '' bundled_file
  do
    sha256sum -- "${bundled_file#./}"
  done < <(find . -type f ! -path './SOURCE-MANIFEST.sha256' \
                    ! -path './SOURCE-METADATA' -print0 | LC_ALL=C sort -z)
) > "$source_bundle/SOURCE-MANIFEST.sha256"
source_manifest_sha256="$(sha256sum -- "$source_bundle/SOURCE-MANIFEST.sha256")"
source_manifest_sha256="${source_manifest_sha256%% *}"
printf '%s\n' \
  'format=1' \
  'source_manifest=SOURCE-MANIFEST.sha256' \
  "source_manifest_sha256=$source_manifest_sha256" \
  > "$source_bundle/SOURCE-METADATA"
verify_source_bundle "$source_bundle" ||
  fail 'source bundle verifier rejected valid content'
grep -Fq 'nested/SOURCE-METADATA' "$source_bundle/SOURCE-MANIFEST.sha256" ||
  fail 'nested provenance-named files were incorrectly omitted from manifest'
printf 'tampered\n' >> "$source_bundle/runtime"
if verify_source_bundle "$source_bundle" 2> /dev/null
then
  fail 'source bundle verifier accepted modified content'
fi
printf 'runtime source\n' > "$source_bundle/runtime"
printf 'not recorded\n' > "$source_bundle/unrecorded"
if verify_source_bundle "$source_bundle" 2> /dev/null
then
  fail 'source bundle verifier accepted an unrecorded file'
fi
rm -- "$source_bundle/unrecorded"
ln -s "$test_root/outside-source" "$source_bundle/source-link"
if verify_source_bundle "$source_bundle" 2> /dev/null
then
  fail 'source bundle verifier accepted a symbolic link'
fi
rm -- "$source_bundle/source-link"
sed -i \
  's/^source_manifest_sha256=.*/source_manifest_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$source_bundle/SOURCE-METADATA"
if verify_source_bundle "$source_bundle" 2> /dev/null
then
  fail 'source bundle verifier accepted forged manifest metadata'
fi

missing_rootfs="$test_root/missing-account-rootfs"
mkdir -p "$missing_rootfs/etc"
printf '%s\n' 'root:*:20000:0:99999:7:::' > "$missing_rootfs/etc/shadow"
if lock_image_account "$missing_rootfs" pi 2> /dev/null
then
  fail 'image-account lock accepted a shadow file without the configured user'
fi

assert_contains "$pi_gen_config" 'FIRST_USER_NAME=pi'
assert_contains "$pi_gen_config" 'FIRST_USER_PASS=raspberry'
assert_contains "$pi_gen_config" 'ENABLE_SSH=1'
assert_absent "$rc_local" 'lock_fresh_image_default_password'
assert_absent "$rc_local" 'passwd --lock'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$rc_local" 'printf '\''%s:%s\n'\'' "$login_user" "$SSH_USER_PASSWORD" | chpasswd'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$rc_local" 'passwd --unlock "$login_user"'

# shellcheck disable=SC2016 # The search string is intentionally literal source.
image_lock_line="$(grep -nF -- 'lock_image_account "${ROOTFS_DIR}" "${FIRST_USER_NAME:-pi}"' "$pi_gen_run" | cut -d: -f1)"
# shellcheck disable=SC2016 # The search string is intentionally literal source.
ssh_enable_line="$(grep -nF -- 'touch "${ROOTFS_DIR}/boot/ssh"' "$pi_gen_run" | cut -d: -f1)"
if [ -z "$image_lock_line" ] || [ -z "$ssh_enable_line" ]
then
  fail 'pi-gen account lock or SSH enable step was not found'
fi
[ "$image_lock_line" -lt "$ssh_enable_line" ] ||
  fail 'pi-gen enables SSH before locking the image account'

mapfile -t source_verify_lines < <(
  grep -n '^verify_source_bundle ' "$pi_gen_run" | cut -d: -f1
)
# shellcheck disable=SC2016 # The search string is intentionally literal.
source_copy_line="$(grep -nF -- \
  'cp -a files/teslausb-source/. "$installed_source_dir/"' \
  "$pi_gen_run" | cut -d: -f1)"
if [ "${#source_verify_lines[@]}" -ne 2 ] || [ -z "$source_copy_line" ]
then
  fail 'source bundle must be verified exactly before and after installation'
fi
if [ "${source_verify_lines[0]}" -ge "$source_copy_line" ] ||
   [ "$source_copy_line" -ge "${source_verify_lines[1]}" ]
then
  fail 'source bundle verification does not bracket its image installation'
fi

# Checksum verification accepts exact content, rejects a mismatch, and rejects
# symlink candidates. The production helper is pinned and is never executed
# before the downloaded private-temp copy passes verification.
checksum_file="$test_root/tzupdate.py"
printf '%s\n' 'print("timezone test")' > "$checksum_file"
checksum="$(sha256sum -- "$checksum_file")"
checksum="${checksum%% *}"
verify_tzupdate_checksum "$checksum_file" "$checksum" ||
  fail 'tzupdate checksum verifier rejected matching content'
if verify_tzupdate_checksum "$checksum_file" \
  0000000000000000000000000000000000000000000000000000000000000000
then
  fail 'tzupdate checksum verifier accepted a mismatch'
fi
if ln -s "$checksum_file" "$test_root/tzupdate-link.py" 2> /dev/null &&
   [ -L "$test_root/tzupdate-link.py" ]
then
  if verify_tzupdate_checksum "$test_root/tzupdate-link.py" "$checksum"
  then
    fail 'tzupdate checksum verifier accepted a symlink'
  fi
fi

timezone_fixture="$test_root/tzupdate-fixture.py"
timezone_execution_marker="$test_root/tzupdate-executed"
TESLAUSB_SCRIPT_TMPDIR="$test_root/timezone-private"
mkdir -p "$TESLAUSB_SCRIPT_TMPDIR"
chmod 0700 "$TESLAUSB_SCRIPT_TMPDIR"
# shellcheck disable=SC2034 # Consumed by the function extracted with eval.
TZUPDATE_MAX_BYTES=131072
# shellcheck disable=SC2034 # Consumed by the function extracted with eval.
TZUPDATE_URL='https://example.invalid/immutable/tzupdate.py'
# shellcheck disable=SC2034 # Consumed by the function extracted with eval.
TIME_ZONE=auto

curlwrapper() {
  local timezone_output=
  while [ "$#" -gt 0 ]
  do
    case "$1" in
      --output)
        [ "$#" -ge 2 ] || return 1
        timezone_output="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  [ -n "$timezone_output" ] || return 1
  cp -- "$timezone_fixture" "$timezone_output"
}

python3() {
  : > "$timezone_execution_marker"
  printf '%s\n' 'timezone test complete'
}

setup_progress() { :; }

printf '%s\n' 'print("verified timezone helper")' > "$timezone_fixture"
TZUPDATE_SHA256="$(sha256sum -- "$timezone_fixture")"
TZUPDATE_SHA256="${TZUPDATE_SHA256%% *}"
set_timezone
[ -e "$timezone_execution_marker" ] ||
  fail 'verified tzupdate helper was not executed'

rm -f -- "$timezone_execution_marker"
printf '%s\n' 'print("tampered timezone helper")' > "$timezone_fixture"
if set_timezone
then
  fail 'set_timezone accepted a checksum mismatch'
fi
[ ! -e "$timezone_execution_marker" ] ||
  fail 'set_timezone executed tzupdate before rejecting its checksum'

assert_absent "$setup_script" 'tzupdate/develop'
assert_absent "$setup_script" '/root/bin/tzupdate.py'
assert_contains "$setup_script" '2d41763825fcfae3f2266bf1628ce245ab285f5a'
assert_contains "$setup_script" '7e6769fcf6c2a19a3492a9d62bd529714081132b12244796a4800269804857cb'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$setup_script" '$TESLAUSB_SCRIPT_TMPDIR/tzupdate.XXXXXXXX.py'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$setup_script" 'mkdir -m 0700 "$TESLAUSB_SCRIPT_TMPDIR"'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$setup_script" '--max-filesize "$TZUPDATE_MAX_BYTES"'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$setup_script" 'if ! verify_tzupdate_checksum "$tzupdate_candidate" "$TZUPDATE_SHA256"'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$setup_script" 'python3 "$tzupdate_candidate"'
# shellcheck disable=SC2016 # The search string is intentionally literal source.
checksum_verify_line="$(grep -nF -- 'verify_tzupdate_checksum "$tzupdate_candidate" "$TZUPDATE_SHA256"' "$setup_script" | cut -d: -f1)"
# shellcheck disable=SC2016 # The search string is intentionally literal source.
tzupdate_execute_line="$(grep -nF -- 'python3 "$tzupdate_candidate"' "$setup_script" | cut -d: -f1)"
if [ -z "$checksum_verify_line" ] || [ -z "$tzupdate_execute_line" ]
then
  fail 'tzupdate checksum or execution step was not found'
fi
[ "$checksum_verify_line" -lt "$tzupdate_execute_line" ] ||
  fail 'tzupdate helper can execute before checksum verification'
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
verify_data_drive_validator="$(
  sed -n '/^function data_drive_path_is_lexically_safe () {$/,/^}$/p' \
    "$repo_root/setup/pi/verify-configuration.sh"
)"
partition_data_drive_validator="$(
  sed -n '/^function data_drive_path_is_lexically_safe () {$/,/^}$/p' \
    "$partition_script"
)"
[ -n "$verify_data_drive_validator" ] || fail 'verify script lacks a DATA_DRIVE lexical validator'
[ "$verify_data_drive_validator" = "$partition_data_drive_validator" ] || \
  fail 'shell DATA_DRIVE lexical validators have diverged'
eval "$partition_data_drive_validator"
for valid_data_drive in \
  /dev/sda \
  /dev/mmcblk0 \
  /dev/nvme0n1 \
  /dev/disk/by-id/usb-SanDisk_Ultra_Fit-0:0
do
  data_drive_path_is_lexically_safe "$valid_data_drive" || \
    fail "DATA_DRIVE lexical validator rejected $valid_data_drive"
done
for invalid_data_drive in \
  /dev/../sda \
  /dev/sda/../sdb \
  /dev/disk/./by-id/device \
  /dev//sda \
  /dev/sda/ \
  /dev/.hidden \
  /tmp/sda
do
  if data_drive_path_is_lexically_safe "$invalid_data_drive"
  then
    fail "DATA_DRIVE lexical validator accepted $invalid_data_drive"
  fi
done
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
for config_loader in "$envsetup" "$setup_script" "$config_library"
do
  assert_contains "$config_loader" 'must have mode 0600'
  assert_contains "$config_loader" 'must be owned by root:root'
  assert_absent "$config_loader" 'config-check.out'
done
# shellcheck disable=SC2016 # Assertion intentionally searches literal source.
assert_contains "$rc_local" 'source "$TESLAUSB_CONFIG_LOADER"'
# shellcheck disable=SC2016 # Assertion intentionally searches literal shell source.
assert_contains "$rc_local" 'teslausb_secure_config "$destination_config"'
assert_absent "$rc_local" 'config-check.out'
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
