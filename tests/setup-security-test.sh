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
release_image_verifier="$repo_root/tools/verify-release-image.sh"
image_workflow="$repo_root/.github/workflows/build-image.yml"
wpa_sample="$repo_root/pi-gen-sources/00-teslausb-tweaks/files/wpa_supplicant.conf.sample"

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
eval "$(sed -n '/^function normalize_cam_size {$/,/^}$/p' "$envsetup")"
eval "$(sed -n '/^function validate_optional_storage_size {$/,/^}$/p' "$envsetup")"
eval "$(sed -n '/^function lock_image_account () {$/,/^}$/p' "$pi_gen_run")"
eval "$(sed -n '/^function normalize_boot_cmdline () {$/,/^}$/p' "$pi_gen_run")"
eval "$(sed -n '/^function verify_source_bundle () {$/,/^}$/p' "$pi_gen_run")"
eval "$(sed -n '/^function verify_tzupdate_checksum () {$/,/^}$/p' "$setup_script")"
eval "$(sed -n '/^function set_timezone () {$/,/^}$/p' "$setup_script")"
eval "$(sed -n '/^function fix_cmdline_txt_modules_load () {$/,/^}$/p' "$setup_script")"
eval "$(sed -n '/^find_enabled_systemd_unit() {$/,/^}$/p' "$release_image_verifier")"
eval "$(sed -n '/^verify_boot_cmdline() {$/,/^}$/p' "$release_image_verifier")"
setup_config_message() { :; }

for valid_cam_size in 20G 40G 40GiB 1780G
do
  CAM_SIZE="$valid_cam_size"
  normalize_cam_size || fail "CAM_SIZE validator rejected $valid_cam_size"
  [[ "$CAM_SIZE" =~ ^[0-9]+G$ ]] ||
    fail "CAM_SIZE validator did not canonicalize $valid_cam_size"
done
for invalid_cam_size in 0 19G 1781G 40 40960M 1T 1P 40GB 40g 40GIB 9007199254740993G
do
  CAM_SIZE="$invalid_cam_size"
  if normalize_cam_size
  then
    fail "CAM_SIZE validator accepted $invalid_cam_size"
  fi
done
unset CAM_SIZE
if normalize_cam_size
then
  fail "CAM_SIZE validator accepted an unset value"
fi

for optional_size in 0 1K 512M 4G 1780G 1822720M 1866465280K
do
  MUSIC_SIZE="$optional_size"
  validate_optional_storage_size MUSIC_SIZE ||
    fail "optional-size validator rejected $optional_size"
done
for invalid_optional_size in 1 1T 1P 4GB 4GiB 4g 512m 1781G 1822721M 1866465281K 999999999999G
do
  MUSIC_SIZE="$invalid_optional_size"
  if validate_optional_storage_size MUSIC_SIZE
  then
    fail "optional-size validator accepted $invalid_optional_size"
  fi
done

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

# The image build removes Raspberry Pi OS's consume-the-card resize request
# and canonicalizes rootwait to one standalone token. Similar-looking values
# remain data instead of being changed by substring matching.
cmdline_rootfs="$test_root/cmdline-rootfs"
mkdir -p "$cmdline_rootfs/boot/firmware"
cmdline_file="$cmdline_rootfs/boot/firmware/cmdline.txt"
printf '%s\n' \
  'console=tty1 root=/dev/mmcblk0p2 resize rootwait foo=resize modules.load=legacy,g_ether modules-load=foo,dwc2,foo rootwait quiet' \
  > "$cmdline_file"
chmod 0640 "$cmdline_file"
normalize_boot_cmdline "$cmdline_rootfs"
[ "$(cat "$cmdline_file")" = \
  'console=tty1 root=/dev/mmcblk0p2 foo=resize quiet rootwait modules-load=dwc2,g_ether,legacy,foo' ] ||
  fail 'image boot command line was not normalized safely'
[ "$(stat -c '%a' "$cmdline_file")" = 640 ] ||
  fail 'image boot command line normalization changed its mode'
normalized_cmdline_sum="$(sha256sum "$cmdline_file")"
normalize_boot_cmdline "$cmdline_rootfs"
[ "$(sha256sum "$cmdline_file")" = "$normalized_cmdline_sum" ] ||
  fail 'image boot command line normalization is not idempotent'

printf 'root=/dev/mmcblk0p2\nsecond=line\n' > "$cmdline_file"
if normalize_boot_cmdline "$cmdline_rootfs" 2> /dev/null
then
  fail 'image boot command line normalizer accepted multiple lines'
fi
printf '\n' > "$cmdline_file"
if normalize_boot_cmdline "$cmdline_rootfs" 2> /dev/null
then
  fail 'image boot command line normalizer accepted an empty line'
fi
printf '%s\n' 'root=/dev/mmcblk0p2 rootwait' > "$cmdline_file"
normalize_boot_cmdline "$cmdline_rootfs"
[ "$(cat "$cmdline_file")" = \
  'root=/dev/mmcblk0p2 rootwait modules-load=dwc2,g_ether' ] ||
  fail 'image boot command line normalizer did not add a missing modules-load token'

# The release verifier enforces the same invariant on the artifact, catching
# future pi-gen changes before an unsafe image can be published.
printf '%s\n' \
  'root=/dev/mmcblk0p2 foo=resize rootwait modules-load=dwc2,g_ether,legacy,foo' \
  > "$cmdline_file"
verify_boot_cmdline "$cmdline_file" 'root=/dev/mmcblk0p2'
for invalid_cmdline in \
  'quiet rootwait modules-load=dwc2,g_ether' \
  'root=/dev/mmcblk0p2 root=/dev/other rootwait modules-load=dwc2,g_ether' \
  'root=/dev/other rootwait modules-load=dwc2,g_ether' \
  'root=/dev/mmcblk0p2 modules-load=dwc2,g_ether' \
  'root=/dev/mmcblk0p2 rootwait rootwait modules-load=dwc2,g_ether' \
  'root=/dev/mmcblk0p2 resize rootwait modules-load=dwc2,g_ether' \
  'root=/dev/mmcblk0p2 rootwait=5 modules-load=dwc2,g_ether' \
  'root=/dev/mmcblk0p2 rootwait' \
  'root=/dev/mmcblk0p2 rootwait modules-load=dwc2' \
  'root=/dev/mmcblk0p2 rootwait modules-load=g_ether,dwc2' \
  'root=/dev/mmcblk0p2 rootwait modules.load=dwc2,g_ether' \
  'root=/dev/mmcblk0p2 rootwait modules-load=dwc2,g_ether modules-load=dwc2,g_ether' \
  'root=/dev/mmcblk0p2 rootwait modules-load=dwc2,g_ether,foo,foo'
do
  printf '%s\n' "$invalid_cmdline" > "$cmdline_file"
  if (verify_boot_cmdline "$cmdline_file" 'root=/dev/mmcblk0p2') 2> /dev/null
  then
    fail "release verifier accepted unsafe cmdline.txt: $invalid_cmdline"
  fi
done
printf 'root=/dev/mmcblk0p2 rootwait modules-load=dwc2,g_ether\r\n' > "$cmdline_file"
if (verify_boot_cmdline "$cmdline_file" 'root=/dev/mmcblk0p2') 2> /dev/null
then
  fail 'release verifier accepted a CRLF cmdline.txt'
fi

# Runtime setup rewrites all legacy or duplicate module parameters as one
# canonical token, retains unrelated modules, and puts dwc2 before g_ether.
runtime_cmdline="$test_root/runtime-cmdline.txt"
printf '%s\n' \
  'console=tty1 modules.load=legacy,g_ether modules-load=foo,dwc2,foo quiet rootwait' \
  > "$runtime_cmdline"
CMDLINE_PATH="$runtime_cmdline"
setup_progress() { :; }
fix_cmdline_txt_modules_load
[ "$(cat "$runtime_cmdline")" = \
  'console=tty1 quiet rootwait modules-load=dwc2,g_ether,legacy,foo' ] ||
  fail 'runtime cmdline module parameters were not canonicalized safely'
runtime_cmdline_sum="$(sha256sum "$runtime_cmdline")"
fix_cmdline_txt_modules_load
[ "$(sha256sum "$runtime_cmdline")" = "$runtime_cmdline_sum" ] ||
  fail 'runtime cmdline module normalization is not idempotent'
printf '%s\n' 'console=tty1 rootwait' > "$runtime_cmdline"
fix_cmdline_txt_modules_load
[ "$(cat "$runtime_cmdline")" = \
  'console=tty1 rootwait modules-load=dwc2,g_ether' ] ||
  fail 'runtime cmdline module parameter was not added when absent'
printf 'console=tty1\nrootwait\n' > "$runtime_cmdline"
if fix_cmdline_txt_modules_load 2> /dev/null
then
  fail 'runtime cmdline module normalizer accepted multiple lines'
fi

# Progress remains visible on stdout when /teslausb is read-only. Redirecting
# stderr before opening the log prevents the shell's failed-redirection error
# from aborting rc.local or obscuring the useful message.
rc_setup_progress_function="$(
  sed -n '/^function setup_progress () {$/,/^}$/p' "$rc_local"
)"
progress_log="$test_root/setup-progress.log"
progress_stderr="$test_root/setup-progress.err"
progress_stdout="$(
  (
    eval "$rc_setup_progress_function"
    SETUP_LOGFILE="$progress_log"
    setup_progress 'writable progress'
  ) 2> "$progress_stderr"
)"
[ "$progress_stdout" = 'writable progress' ] ||
  fail 'rc.local progress did not remain visible on stdout'
grep -Fq ' : writable progress' "$progress_log" ||
  fail 'rc.local progress did not append to a writable log'
[ ! -s "$progress_stderr" ] ||
  fail 'rc.local progress emitted an unexpected writable-log error'
progress_stdout="$(
  (
    eval "$rc_setup_progress_function"
    SETUP_LOGFILE="$test_root/missing-parent/setup-progress.log"
    setup_progress 'read-only progress'
  ) 2> "$progress_stderr"
)"
[ "$progress_stdout" = 'read-only progress' ] ||
  fail 'rc.local lost progress when its log was unavailable'
[ ! -s "$progress_stderr" ] ||
  fail 'rc.local exposed a failed log redirection on stderr'

assert_contains "$pi_gen_config" 'FIRST_USER_NAME=pi'
assert_contains "$pi_gen_config" 'FIRST_USER_PASS=raspberry'
assert_contains "$pi_gen_config" 'ENABLE_SSH=1'
assert_absent "$rc_local" 'lock_fresh_image_default_password'
assert_absent "$rc_local" 'passwd --lock'
# A failed one-time repair remains on the boot partition so the next boot can
# retry it; only a successful exit is allowed to consume the marker.
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$rc_local" 'if "$RC_LOCAL_TMPDIR/run_once"'
assert_contains "$rc_local" 'run_once succeeded and consumed its own trigger'
assert_contains "$rc_local" 'run_once failed; leaving it in place for retry'
assert_contains "$rc_local" 'WARNING: run_once succeeded but could not be renamed; it will be retried'
assert_absent "$rc_local" '"$RC_LOCAL_TMPDIR/run_once" || echo "run_once failed"'
run_once_call_line="$(grep -nF -- \
  'if "$RC_LOCAL_TMPDIR/run_once"' "$rc_local" | cut -d: -f1)"
run_once_rename_line="$(grep -nF -- \
  'if ! mv /teslausb/run_once /teslausb/ran_once' "$rc_local" | cut -d: -f1)"
if [ -z "$run_once_call_line" ] || [ -z "$run_once_rename_line" ] ||
   [ "$run_once_call_line" -ge "$run_once_rename_line" ]
then
  fail 'rc.local does not gate run_once consumption on a successful exit'
fi
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$rc_local" 'printf '\''%s:%s\n'\'' "$login_user" "$SSH_USER_PASSWORD" | chpasswd'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$rc_local" 'passwd --unlock "$login_user"'

# shellcheck disable=SC2016 # The search string is intentionally literal source.
image_lock_line="$(grep -nF -- 'lock_image_account "${ROOTFS_DIR}" "${FIRST_USER_NAME:-pi}"' "$pi_gen_run" | cut -d: -f1)"
# shellcheck disable=SC2016 # The search string is intentionally literal source.
cmdline_normalize_line="$(grep -nF -- 'normalize_boot_cmdline "${ROOTFS_DIR}"' "$pi_gen_run" | cut -d: -f1)"
# shellcheck disable=SC2016 # The search string is intentionally literal source.
ssh_enable_line="$(grep -nF -- 'touch "${ROOTFS_DIR}/boot/firmware/ssh"' "$pi_gen_run" | cut -d: -f1)"
if [ -z "$image_lock_line" ] || [ -z "$cmdline_normalize_line" ] ||
   [ -z "$ssh_enable_line" ]
then
  fail 'pi-gen account lock, command-line normalization, or SSH enable step was not found'
fi
[ "$image_lock_line" -lt "$ssh_enable_line" ] ||
  fail 'pi-gen enables SSH before locking the image account'
[ "$cmdline_normalize_line" -lt "$ssh_enable_line" ] ||
  fail 'pi-gen enables SSH before normalizing the boot command line'
# shellcheck disable=SC2016 # The search string is intentionally literal source.
assert_absent "$pi_gen_run" 'touch "${ROOTFS_DIR}/boot/ssh"'
assert_contains "$pi_gen_run" 'systemctl disable rpi-resize.service'
assert_contains "$pi_gen_run" 'rpi-swap systemd-zram-generator'
assert_contains "$pi_gen_run" 'systemctl disable dpkg-db-backup.timer'
if grep -Fxq -- 'systemctl disable dpkg-db-backup' "$pi_gen_run"
then
  fail 'pi-gen disables the static dpkg backup service instead of its timer'
fi
assert_contains "$pi_gen_run" 'rm -f -- /etc/init.d/resize2fs_once'
assert_contains "$pi_gen_run" \
  'rm -f -- /usr/share/initramfs-tools/scripts/local-premount/firstboot'
assert_contains "$release_image_verifier" \
  'release image contains a legacy root-filesystem SSH marker'
assert_contains "$release_image_verifier" \
  'automatic root partition resizing remains enabled'
assert_contains "$release_image_verifier" \
  'automatic root resize token remains in boot cmdline.txt'
assert_contains "$release_image_verifier" \
  'boot cmdline.txt must contain exactly one rootwait token'
assert_contains "$release_image_verifier" \
  'boot cmdline.txt must contain exactly one root token'
assert_contains "$release_image_verifier" \
  'boot cmdline.txt root token does not match the verified root partition'
assert_contains "$release_image_verifier" \
  'blkid -p -s PART_ENTRY_UUID -o value -- "$ROOT_PARTITION"'
assert_contains "$release_image_verifier" \
  'boot cmdline.txt must contain exactly one modules-load token'
assert_contains "$release_image_verifier" \
  'boot modules-load token must start with dwc2,g_ether'
assert_contains "$release_image_verifier" \
  'dpkg database backup timer remains enabled'
assert_contains "$release_image_verifier" \
  'release image contains active swap package'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$release_image_verifier" \
  'nonempty_build_log=$(sudo -n find "$ROOT_MOUNT/var/log" -xdev'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$release_image_verifier" \
  'sudo -n losetup --detach "$LOOP_DEVICE"'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$release_image_verifier" \
  'sudo -n losetup --find --show --partscan --read-only "$IMAGE_PATH"'
assert_absent "$release_image_verifier" 'losetup --detach --'
assert_absent "$release_image_verifier" \
  'losetup --find --show --partscan --read-only --'
assert_absent "$release_image_verifier" \
  'system-connections" \
  -mindepth 1 \( -type f -o -type l \) -print -quit 2> /dev/null || true'

backing_files_line="$(grep -n '^create_usb_drive_backing_files$' "$setup_script" | cut -d: -f1)"
recovery_install_line="$(grep -n '^install_transaction_recovery_service$' "$setup_script" | cut -d: -f1)"
recovery_precondition_line="$(grep -nF -- \
  '--mountpoint "$MUTABLE_MOUNTPOINT"' "$setup_script" | cut -d: -f1)"
recovery_start_line="$(grep -nF -- \
  'systemctl start teslausb-upgrade-recovery.service' "$setup_script" | cut -d: -f1)"
if [ -z "$backing_files_line" ] || [ -z "$recovery_install_line" ] ||
   [ -z "$recovery_precondition_line" ] || [ -z "$recovery_start_line" ]
then
  fail 'transaction-recovery setup ordering or mutable-mount precondition is missing'
fi
[ "$backing_files_line" -lt "$recovery_install_line" ] ||
  fail 'transaction recovery is installed before the mutable filesystem exists'
[ "$recovery_precondition_line" -lt "$recovery_start_line" ] ||
  fail 'transaction recovery can start before checking the mutable filesystem'
assert_contains "$setup_script" \
  '[[ ",$mutable_mount_options," != *,rw,* ]]'
assert_contains "$setup_script" \
  'the mutable filesystem must be mounted read-write before installing transaction recovery'
encrypted_helper_install_line="$(grep -nF -- \
  'copy_script run/encrypted_clips_path_status.sh /root/bin' "$setup_script" | cut -d: -f1)"
encrypted_guard_install_line="$(grep -nF -- \
  'copy_script run/guarded_snapshot.sh /root/bin' "$setup_script" | cut -d: -f1)"
if [ -z "$encrypted_helper_install_line" ] || [ -z "$encrypted_guard_install_line" ] ||
   [ "$encrypted_helper_install_line" -ge "$encrypted_guard_install_line" ]
then
  fail 'fresh setup does not install the encrypted-path helper before its guarded caller'
fi
# shellcheck disable=SC2016 # Assertions intentionally search literal workflow source.
assert_contains "$image_workflow" \
  'sudo -n bash -- "${GITHUB_WORKSPACE}/tools/verify-release-image.sh"'
# shellcheck disable=SC2016 # Assertions intentionally search literal workflow source.
assert_contains "$image_workflow" \
  'sudo -n chown -- "${runner_uid}:${runner_gid}" "${packages}" "${metadata}"'

# shellcheck disable=SC2016 # The search string is intentionally literal workflow source.
verifier_call_line="$(grep -nF -- \
  'sudo -n bash -- "${GITHUB_WORKSPACE}/tools/verify-release-image.sh"' \
  "$image_workflow" | cut -d: -f1)"
# shellcheck disable=SC2016 # The search string is intentionally literal workflow source.
verifier_output_check_line="$(grep -nF -- \
  'for verifier_output in "${packages}" "${metadata}"' \
  "$image_workflow" | cut -d: -f1)"
# shellcheck disable=SC2016 # The search string is intentionally literal workflow source.
verifier_chown_line="$(grep -nF -- \
  'sudo -n chown -- "${runner_uid}:${runner_gid}" "${packages}" "${metadata}"' \
  "$image_workflow" | cut -d: -f1)"
if [ -z "$verifier_call_line" ] || [ -z "$verifier_output_check_line" ] ||
   [ -z "$verifier_chown_line" ]
then
  fail 'release workflow verifier privilege or output safeguards are incomplete'
fi
if [ "$verifier_call_line" -ge "$verifier_output_check_line" ] ||
   [ "$verifier_output_check_line" -ge "$verifier_chown_line" ]
then
  fail 'release workflow returns verifier outputs to runner ownership unsafely'
fi

# shellcheck disable=SC2016 # The search string is intentionally literal shell source.
image_path_line="$(grep -nF -- \
  'IMAGE_PATH=$(readlink -f -- "$IMAGE_INPUT")' \
  "$release_image_verifier" | cut -d: -f1)"
# shellcheck disable=SC2016 # The search string is intentionally literal shell source.
loop_attach_line="$(grep -nF -- \
  'LOOP_DEVICE=$(sudo -n losetup --find --show --partscan --read-only "$IMAGE_PATH")' \
  "$release_image_verifier" | cut -d: -f1)"
# shellcheck disable=SC2016 # The search string is intentionally literal shell source.
loop_cleanup_guard_line="$(grep -nF -- \
  'if [ -n "$LOOP_DEVICE" ] && [[ "$LOOP_DEVICE" =~ ^/dev/loop[0-9]+$ ]]' \
  "$release_image_verifier" | cut -d: -f1)"
# shellcheck disable=SC2016 # The search string is intentionally literal shell source.
loop_detach_line="$(grep -nF -- \
  'sudo -n losetup --detach "$LOOP_DEVICE"' \
  "$release_image_verifier" | cut -d: -f1)"
if [ -z "$image_path_line" ] || [ -z "$loop_attach_line" ] ||
   [ -z "$loop_cleanup_guard_line" ] || [ -z "$loop_detach_line" ]
then
  fail 'release image verifier loop-device safeguards are incomplete'
fi
[ "$image_path_line" -lt "$loop_attach_line" ] ||
  fail 'release image path is not resolved before loop attachment'
[ "$loop_cleanup_guard_line" -lt "$loop_detach_line" ] ||
  fail 'loop device is not validated before cleanup can detach it'

fake_systemd="$test_root/fake-systemd"
enabled_resize_path="$fake_systemd/sysinit.target.wants/rpi-resize.service"
mkdir -p "$(dirname -- "$enabled_resize_path")"
printf 'enabled test unit\n' > "$enabled_resize_path"
[ "$(find_enabled_systemd_unit "$fake_systemd" rpi-resize.service)" = \
  "$enabled_resize_path" ] ||
  fail 'image verifier did not detect an enabled systemd unit'
rm -- "$enabled_resize_path"
[ -z "$(find_enabled_systemd_unit "$fake_systemd" rpi-resize.service)" ] ||
  fail 'image verifier reported a removed systemd unit as enabled'

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
assert_contains "$rc_local" "raspi-config nonint do_wifi_country \"\$WIFI_COUNTRY\""
assert_contains "$rc_local" "printf 'country=%s\\n' \"\$WIFI_COUNTRY\""
assert_contains "$rc_local" "sed '/^[[:space:]]*#psk=/d'"
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_absent "$rc_local" '"$wpa_config" /teslausb/wpa_supplicant.conf'
# shellcheck disable=SC2016 # Assertions intentionally search literal shell source.
assert_contains "$rc_local" 'awk -v old="$old_host_name" -v new="$new_host_name"'
assert_absent "$rc_local" 'TEMPSSID'
assert_absent "$rc_local" 'TEMPPASS'
assert_absent "$rc_local" 'country=US'
assert_absent "$setup_script" 'country=US'
assert_absent "$pi_gen_config" 'WPA_COUNTRY=US'
assert_absent "$wpa_sample" 'country=US'
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
