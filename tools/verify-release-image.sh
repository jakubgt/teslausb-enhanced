#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: verify-release-image.sh IMAGE VERSION SOURCE_COMMIT PI_GEN_COMMIT PACKAGES_OUTPUT METADATA_OUTPUT' \
    '' \
    'Verifies an uncompressed TeslaUSB release image without modifying it. The' \
    'package manifest and metadata JSON outputs must not already exist.' >&2
  exit 2
}

fail() {
  printf 'verify-release-image: %s\n' "$*" >&2
  exit 1
}

metadata_value() {
  local metadata_file="$1"
  local metadata_key="$2"

  awk -F= -v key="$metadata_key" '
    $1 == key {
      count++
      value = substr($0, index($0, "=") + 1)
    }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$metadata_file"
}

prepare_output_path() {
  local requested_path="$1"
  local output_parent
  local output_name

  if [ -e "$requested_path" ] || [ -L "$requested_path" ]
  then
    fail "output already exists or is a symbolic link: $requested_path"
  fi
  output_parent=$(dirname -- "$requested_path")
  output_name=$(basename -- "$requested_path")
  if [ -z "$output_name" ] || [ "$output_name" = . ] || [ "$output_name" = .. ]
  then
    fail "invalid output path: $requested_path"
  fi
  if [ ! -d "$output_parent" ] || [ -L "$output_parent" ]
  then
    fail "output directory is missing or symbolic: $output_parent"
  fi
  output_parent=$(readlink -f -- "$output_parent")
  printf '%s/%s\n' "$output_parent" "$output_name"
}

find_enabled_systemd_unit() {
  local systemd_directory="$1"
  local unit_name="$2"

  find "$systemd_directory" -xdev \
    \( -type f -o -type l \) \
    \( -path "*/*.wants/$unit_name" \
       -o -path "*/*.requires/$unit_name" \
       -o -path "*/*.upholds/$unit_name" \) \
    -print -quit
}

[ "$#" -eq 6 ] || usage

readonly IMAGE_INPUT=$1
readonly EXPECTED_VERSION=$2
readonly EXPECTED_SOURCE_COMMIT=$3
readonly EXPECTED_PI_GEN_COMMIT=$4
readonly PACKAGES_INPUT=$5
readonly METADATA_INPUT=$6

[[ "$EXPECTED_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$ ]] ||
  fail "expected version is not a supported semantic version or release candidate"
[[ "$EXPECTED_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
  fail "expected TeslaUSB commit must be one lowercase 40-character SHA"
[[ "$EXPECTED_PI_GEN_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
  fail "expected pi-gen commit must be one lowercase 40-character SHA"
if [ ! -f "$IMAGE_INPUT" ] || [ -L "$IMAGE_INPUT" ]
then
  fail "image must be a regular file, not a symbolic link: $IMAGE_INPUT"
fi
case "$IMAGE_INPUT" in
  *.img) ;;
  *) fail "uncompressed image name must end in .img" ;;
esac

IMAGE_PATH=$(readlink -f -- "$IMAGE_INPUT")
readonly IMAGE_PATH
PACKAGES_OUTPUT=$(prepare_output_path "$PACKAGES_INPUT")
readonly PACKAGES_OUTPUT
METADATA_OUTPUT=$(prepare_output_path "$METADATA_INPUT")
readonly METADATA_OUTPUT
[ "$PACKAGES_OUTPUT" != "$METADATA_OUTPUT" ] || fail "output paths must be different"

for required_command in awk basename blkid chmod cmp dirname dpkg-query e2fsck \
  file find fsck.vfat grep jq losetup lsblk mkdir mktemp mount mountpoint mv \
  readlink rm rmdir sfdisk sha256sum sleep sort stat sudo tr udevadm umount
do
  command -v "$required_command" > /dev/null ||
    fail "required verification command is unavailable: $required_command"
done
sudo -n true > /dev/null 2>&1 ||
  fail "passwordless sudo is required for read-only loop and mount verification"

VERIFY_TMP=
BOOT_MOUNT=
ROOT_MOUNT=
LOOP_DEVICE=
PACKAGES_TMP=
METADATA_TMP=

cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT
  set +e
  if [ -n "$BOOT_MOUNT" ] && mountpoint -q -- "$BOOT_MOUNT"
  then
    sudo -n umount -- "$BOOT_MOUNT" || cleanup_status=1
  fi
  if [ -n "$ROOT_MOUNT" ] && mountpoint -q -- "$ROOT_MOUNT"
  then
    sudo -n umount -- "$ROOT_MOUNT" || cleanup_status=1
  fi
  if [ -n "$LOOP_DEVICE" ] && [[ "$LOOP_DEVICE" =~ ^/dev/loop[0-9]+$ ]]
  then
    sudo -n losetup --detach "$LOOP_DEVICE" || cleanup_status=1
  fi
  [ -z "$PACKAGES_TMP" ] || rm -f -- "$PACKAGES_TMP"
  [ -z "$METADATA_TMP" ] || rm -f -- "$METADATA_TMP"
  if [ -n "$VERIFY_TMP" ] && [[ "$VERIFY_TMP" == /tmp/teslausb-image-verify.* ]]
  then
    [ -z "$BOOT_MOUNT" ] || rmdir -- "$BOOT_MOUNT" 2> /dev/null || true
    [ -z "$ROOT_MOUNT" ] || rmdir -- "$ROOT_MOUNT" 2> /dev/null || true
    rmdir -- "$VERIFY_TMP" 2> /dev/null || true
  fi
  if [ "$status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]
  then
    printf '%s\n' 'verify-release-image: unable to cleanly unmount the verified image' >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

VERIFY_TMP=$(mktemp -d /tmp/teslausb-image-verify.XXXXXXXX)
BOOT_MOUNT="$VERIFY_TMP/boot"
ROOT_MOUNT="$VERIFY_TMP/root"
mkdir -m 0700 -- "$BOOT_MOUNT" "$ROOT_MOUNT"
PACKAGES_TMP=$(mktemp "$(dirname -- "$PACKAGES_OUTPUT")/.teslausb-packages.XXXXXXXX")
METADATA_TMP=$(mktemp "$(dirname -- "$METADATA_OUTPUT")/.teslausb-metadata.XXXXXXXX")

LOOP_DEVICE=$(sudo -n losetup --find --show --partscan --read-only "$IMAGE_PATH")
[[ "$LOOP_DEVICE" =~ ^/dev/loop[0-9]+$ ]] || fail "losetup returned an unsafe device name"
sudo -n udevadm settle

partitions=()
for _ in {1..20}
do
  mapfile -t partitions < <(lsblk -nrpo NAME,TYPE -- "$LOOP_DEVICE" |
    awk '$2 == "part" { print $1 }')
  [ "${#partitions[@]}" -eq 2 ] && break
  sleep 0.25
done
[ "${#partitions[@]}" -eq 2 ] ||
  fail "image must expose exactly two partitions"

partition_json=$(sudo -n sfdisk --json -- "$LOOP_DEVICE")
jq -e '
  .partitiontable.label == "dos" and
  (.partitiontable.partitions | length == 2)
' > /dev/null <<< "$partition_json" ||
  fail "image must have an MBR/DOS partition table with exactly two partitions"
sudo -n sfdisk --verify -- "$LOOP_DEVICE" > /dev/null

readonly BOOT_PARTITION=${partitions[0]}
readonly ROOT_PARTITION=${partitions[1]}
[ "$(lsblk -ndo PKNAME -- "$BOOT_PARTITION")" = "$(basename -- "$LOOP_DEVICE")" ] ||
  fail "boot partition does not belong to the verified loop device"
[ "$(lsblk -ndo PKNAME -- "$ROOT_PARTITION")" = "$(basename -- "$LOOP_DEVICE")" ] ||
  fail "root partition does not belong to the verified loop device"

boot_filesystem=$(sudo -n blkid -p -s TYPE -o value -- "$BOOT_PARTITION")
root_filesystem=$(sudo -n blkid -p -s TYPE -o value -- "$ROOT_PARTITION")
[ "$boot_filesystem" = vfat ] || fail "boot partition must use FAT/vfat"
[ "$root_filesystem" = ext4 ] || fail "root partition must use ext4"
sudo -n fsck.vfat -n -- "$BOOT_PARTITION" > /dev/null
sudo -n e2fsck -fn -- "$ROOT_PARTITION" > /dev/null

sudo -n mount -o ro -- "$BOOT_PARTITION" "$BOOT_MOUNT"
sudo -n mount -o ro,noload -- "$ROOT_PARTITION" "$ROOT_MOUNT"

[ -f "$BOOT_MOUNT/kernel8.img" ] || fail "64-bit kernel8.img is missing"
[ -f "$BOOT_MOUNT/bcm2710-rpi-zero-2-w.dtb" ] ||
  fail "Raspberry Pi Zero 2 W device tree is missing"
[ -f "$BOOT_MOUNT/config.txt" ] || fail "boot config.txt is missing"
grep -Eq '^[[:space:]]*dtoverlay=dwc2([[:space:]]|$)' "$BOOT_MOUNT/config.txt" ||
  fail "dwc2 USB OTG overlay is missing from boot config"
if [ ! -f "$BOOT_MOUNT/ssh" ] || [ -L "$BOOT_MOUNT/ssh" ]
then
  fail "first-boot SSH marker is missing or symbolic on the boot partition"
fi
if [ -e "$ROOT_MOUNT/boot/ssh" ] || [ -L "$ROOT_MOUNT/boot/ssh" ]
then
  fail "release image contains a legacy root-filesystem SSH marker"
fi
systemd_config="$ROOT_MOUNT/etc/systemd/system"
if [ ! -d "$systemd_config" ] || [ -L "$systemd_config" ]
then
  fail "systemd configuration directory is missing or symbolic"
fi
enabled_rpi_resize=$(find_enabled_systemd_unit \
  "$systemd_config" rpi-resize.service)
[ -z "$enabled_rpi_resize" ] ||
  fail "automatic root partition resizing remains enabled: $enabled_rpi_resize"
enabled_dpkg_backup=$(find_enabled_systemd_unit \
  "$systemd_config" dpkg-db-backup.timer)
[ -z "$enabled_dpkg_backup" ] ||
  fail "dpkg database backup timer remains enabled: $enabled_dpkg_backup"
[ -f "$BOOT_MOUNT/run_once" ] || fail "TeslaUSB first-boot marker is missing"
[ -f "$BOOT_MOUNT/teslausb_setup.json.sample" ] ||
  fail "JSON setup sample is missing from the boot partition"
[ -f "$BOOT_MOUNT/teslausb_setup_variables.conf.sample" ] ||
  fail "legacy setup sample is missing from the boot partition"
[ -f "$BOOT_MOUNT/teslausb_config_wizard.html" ] ||
  fail "offline configuration wizard is missing from the boot partition"

for active_config in \
  "$BOOT_MOUNT/teslausb_setup.json" \
  "$BOOT_MOUNT/teslausb_setup_variables.conf" \
  "$BOOT_MOUNT/wpa_supplicant.conf" \
  "$ROOT_MOUNT/root/teslausb_setup.json" \
  "$ROOT_MOUNT/root/teslausb_setup_variables.conf"
do
  if [ -e "$active_config" ] || [ -L "$active_config" ]
  then
    fail "release image contains an active user configuration: $active_config"
  fi
done

file -L -- "$ROOT_MOUNT/usr/bin/bash" |
  grep -Eq 'ELF 64-bit LSB.*ARM aarch64' ||
  fail "root filesystem is not an arm64 userspace"
codename=$(awk -F= '
  $1 == "VERSION_CODENAME" {
    count++
    value = $2
    gsub(/^"|"$/, "", value)
  }
  END {
    if (count != 1) exit 1
    print value
  }
' "$ROOT_MOUNT/etc/os-release") || fail "unable to read one OS codename"
[ "$codename" = trixie ] || fail "root filesystem is not Debian Trixie"
[ "$(tr -d '\r\n' < "$ROOT_MOUNT/etc/hostname")" = teslausb ] ||
  fail "image hostname is not teslausb"

sudo -n awk -F: '
  $1 == "pi" {
    count++
    locked = ($2 ~ /^!/) || ($2 == "*")
  }
  END { exit !(count == 1 && locked) }
' "$ROOT_MOUNT/etc/shadow" || fail "first user pi is missing or not locked"
awk -F: '$1 == "pi" { count++; uid = $3 } END { exit !(count == 1 && uid == 1000) }' \
  "$ROOT_MOUNT/etc/passwd" || fail "first user pi is not the unique UID 1000 account"

for prohibited_swap_package in dphys-swapfile rpi-swap systemd-zram-generator
do
  package_state=
  if package_state=$(dpkg-query --admindir="$ROOT_MOUNT/var/lib/dpkg" \
       --show --showformat='${db:Status-Status}' \
       "$prohibited_swap_package" 2> /dev/null) &&
     [ "$package_state" = installed ]
  then
    fail "release image contains active swap package: $prohibited_swap_package"
  fi
done

machine_id_file="$ROOT_MOUNT/etc/machine-id"
if [ ! -f "$machine_id_file" ] || [ -L "$machine_id_file" ]
then
  fail "etc/machine-id must be a regular file"
fi
machine_id=$(tr -d '[:space:]' < "$machine_id_file")
[ -z "$machine_id" ] || [ "$machine_id" = uninitialized ] ||
  fail "release image contains an initialized machine ID"
dbus_machine_id="$ROOT_MOUNT/var/lib/dbus/machine-id"
if [ -L "$dbus_machine_id" ]
then
  [ "$(readlink -- "$dbus_machine_id")" = /etc/machine-id ] ||
    fail "D-Bus machine ID does not point to /etc/machine-id"
elif [ -e "$dbus_machine_id" ]
then
  dbus_id=$(tr -d '[:space:]' < "$dbus_machine_id")
  [ -z "$dbus_id" ] || [ "$dbus_id" = uninitialized ] ||
    fail "release image contains an initialized D-Bus machine ID"
fi

ssh_host_key=$(find "$ROOT_MOUNT/etc/ssh" -maxdepth 1 \
  \( -type f -o -type l \) -name 'ssh_host_*' -print -quit)
[ -z "$ssh_host_key" ] || fail "release image contains a shared SSH host key: $ssh_host_key"
for random_seed in \
  "$ROOT_MOUNT/var/lib/systemd/random-seed" \
  "$ROOT_MOUNT/var/lib/urandom/random-seed"
do
  if [ -e "$random_seed" ] || [ -L "$random_seed" ]
  then
    fail "release image contains a shared random seed: $random_seed"
  fi
done

nonempty_build_log=$(sudo -n find "$ROOT_MOUNT/var/log" -xdev \
  -type f -size +0c -print -quit)
[ -z "$nonempty_build_log" ] ||
  fail "release image contains a nonempty build-time log: $nonempty_build_log"
for build_log in \
  "$ROOT_MOUNT/build.log" \
  "$ROOT_MOUNT/pi-gen.log" \
  "$ROOT_MOUNT/root/build.log"
do
  if [ -e "$build_log" ] || [ -L "$build_log" ]
  then
    fail "release image contains a builder log: $build_log"
  fi
done
cached_deb=
if [ -d "$ROOT_MOUNT/var/cache/apt/archives" ]
then
  cached_deb=$(find "$ROOT_MOUNT/var/cache/apt/archives" -maxdepth 1 -type f \
    -name '*.deb' -print -quit)
fi
[ -z "$cached_deb" ] || fail "release image contains a cached build package: $cached_deb"

for apt_auth_path in \
  "$ROOT_MOUNT/etc/apt/auth.conf" \
  "$ROOT_MOUNT/etc/apt/auth.conf.d"
do
  [ ! -L "$apt_auth_path" ] ||
    fail "release image contains symbolic APT authentication configuration: $apt_auth_path"
  if [ -d "$apt_auth_path" ]
  then
    [ -z "$(find "$apt_auth_path" -mindepth 1 -print -quit)" ] ||
      fail "release image contains APT authentication configuration: $apt_auth_path"
  else
    if [ -e "$apt_auth_path" ] || [ -L "$apt_auth_path" ]
    then
      fail "release image contains APT authentication configuration: $apt_auth_path"
    fi
  fi
done
proxy_match=$(grep -RIsEil \
  '(^|[[:space:]])(http|https|ftp|all)_proxy=|Acquire::(http|https|ftp)::Proxy' \
  "$ROOT_MOUNT/etc/apt" "$ROOT_MOUNT/etc/environment" \
  "$ROOT_MOUNT/etc/profile" "$ROOT_MOUNT/etc/profile.d" 2> /dev/null || true)
[ -z "$proxy_match" ] || fail "release image contains a builder proxy setting: $proxy_match"

for credential_path in \
  "$ROOT_MOUNT/root/.git-credentials" \
  "$ROOT_MOUNT/root/.netrc" \
  "$ROOT_MOUNT/root/.config/gh/hosts.yml" \
  "$ROOT_MOUNT/root/.bash_history" \
  "$ROOT_MOUNT/root/.ssh/authorized_keys" \
  "$ROOT_MOUNT/home/pi/.git-credentials" \
  "$ROOT_MOUNT/home/pi/.netrc" \
  "$ROOT_MOUNT/home/pi/.ssh/authorized_keys"
do
  if [ -e "$credential_path" ] || [ -L "$credential_path" ]
  then
    fail "release image contains a credential or history file: $credential_path"
  fi
done
network_profile=
network_profile_directory="$ROOT_MOUNT/etc/NetworkManager/system-connections"
if [ -d "$network_profile_directory" ]
then
  network_profile=$(find "$network_profile_directory" \
    -mindepth 1 \( -type f -o -type l \) -print -quit)
elif [ -e "$network_profile_directory" ] || [ -L "$network_profile_directory" ]
then
  fail "NetworkManager system-connections path is not a directory"
fi
[ -z "$network_profile" ] ||
  fail "release image contains an active NetworkManager profile: $network_profile"
wpa_config="$ROOT_MOUNT/etc/wpa_supplicant/wpa_supplicant.conf"
if [ -f "$wpa_config" ] && grep -Eq '^[[:space:]]*(network=|psk=)' "$wpa_config"
then
  fail "release image contains an active wpa_supplicant network"
fi
for residue_path in \
  "$ROOT_MOUNT/pi-gen" \
  "$ROOT_MOUNT/work" \
  "$ROOT_MOUNT/actions-runner"
do
  if [ -e "$residue_path" ] || [ -L "$residue_path" ]
  then
    fail "release image contains build residue: $residue_path"
  fi
done

readonly SOURCE_DIR="$ROOT_MOUNT/usr/local/share/teslausb-source"
readonly SOURCE_METADATA="$SOURCE_DIR/SOURCE-METADATA"
readonly SOURCE_MANIFEST="$SOURCE_DIR/SOURCE-MANIFEST.sha256"
if [ ! -d "$SOURCE_DIR" ] || [ -L "$SOURCE_DIR" ]
then
  fail "embedded TeslaUSB source bundle is missing or symbolic"
fi
if [ ! -f "$SOURCE_METADATA" ] || [ -L "$SOURCE_METADATA" ]
then
  fail "embedded source metadata is missing or symbolic"
fi
if [ ! -f "$SOURCE_MANIFEST" ] || [ -L "$SOURCE_MANIFEST" ]
then
  fail "embedded source manifest is missing or symbolic"
fi
[ -z "$(find "$SOURCE_DIR" -name .git -print -quit)" ] ||
  fail "embedded source contains Git build metadata"

actual_version=$(metadata_value "$SOURCE_METADATA" teslausb_version) ||
  fail "embedded source metadata has an invalid version entry"
actual_source_commit=$(metadata_value "$SOURCE_METADATA" teslausb_source_commit) ||
  fail "embedded source metadata has an invalid source commit entry"
actual_pi_gen_commit=$(metadata_value "$SOURCE_METADATA" pi_gen_commit) ||
  fail "embedded source metadata has an invalid pi-gen commit entry"
manifest_name=$(metadata_value "$SOURCE_METADATA" source_manifest) ||
  fail "embedded source metadata has an invalid manifest entry"
expected_manifest_sha=$(metadata_value "$SOURCE_METADATA" source_manifest_sha256) ||
  fail "embedded source metadata has an invalid manifest digest entry"
[ "$actual_version" = "$EXPECTED_VERSION" ] || fail "embedded TeslaUSB version does not match"
[ "$actual_source_commit" = "$EXPECTED_SOURCE_COMMIT" ] ||
  fail "embedded TeslaUSB commit does not match"
[ "$actual_pi_gen_commit" = "$EXPECTED_PI_GEN_COMMIT" ] ||
  fail "embedded pi-gen commit does not match"
[ "$manifest_name" = SOURCE-MANIFEST.sha256 ] ||
  fail "embedded metadata names an unexpected source manifest"
[[ "$expected_manifest_sha" =~ ^[0-9a-f]{64}$ ]] ||
  fail "embedded source manifest digest is malformed"
actual_manifest_sha=$(sha256sum -- "$SOURCE_MANIFEST")
actual_manifest_sha=${actual_manifest_sha%% *}
[ "$actual_manifest_sha" = "$expected_manifest_sha" ] ||
  fail "embedded source manifest digest does not match metadata"
(
  cd "$SOURCE_DIR"
  sha256sum -c -- SOURCE-MANIFEST.sha256 > /dev/null
) || fail "embedded source files do not match their manifest"
for boot_source_file in \
  teslausb_config_wizard.html \
  teslausb_setup.json.sample \
  teslausb_setup_variables.conf.sample
do
  cmp -s -- "$BOOT_MOUNT/$boot_source_file" \
    "$SOURCE_DIR/pi-gen-sources/00-teslausb-tweaks/files/$boot_source_file" ||
    fail "boot configuration asset does not match embedded source: $boot_source_file"
done

LC_ALL=C dpkg-query --admindir="$ROOT_MOUNT/var/lib/dpkg" --show \
  --showformat='${binary:Package}\t${Version}\t${Architecture}\n' |
  LC_ALL=C sort > "$PACKAGES_TMP"
[ -s "$PACKAGES_TMP" ] || fail "installed package manifest is empty"
chmod 0644 "$PACKAGES_TMP"

image_bytes=$(stat -c %s -- "$IMAGE_PATH")
jq -S -n \
  --arg schema_version '1' \
  --arg teslausb_version "$EXPECTED_VERSION" \
  --arg teslausb_source_commit "$EXPECTED_SOURCE_COMMIT" \
  --arg pi_gen_commit "$EXPECTED_PI_GEN_COMMIT" \
  --arg architecture arm64 \
  --arg debian_codename trixie \
  --arg partition_table dos \
  --arg boot_filesystem "$boot_filesystem" \
  --arg root_filesystem "$root_filesystem" \
  --arg first_user pi \
  --argjson image_bytes "$image_bytes" \
  '{
    schema_version: ($schema_version | tonumber),
    source: {
      teslausb_version: $teslausb_version,
      teslausb_source_commit: $teslausb_source_commit,
      pi_gen_commit: $pi_gen_commit
    },
    image: {
      architecture: $architecture,
      debian_codename: $debian_codename,
      partition_table: $partition_table,
      boot_filesystem: $boot_filesystem,
      root_filesystem: $root_filesystem,
      uncompressed_bytes: $image_bytes,
      raspberry_pi_zero_2_w_device_tree: true,
      kernel8_present: true,
      dwc2_overlay_present: true,
      first_user: $first_user,
      first_user_locked: true,
      active_setup_config_present: false,
      offline_config_wizard_present: true,
      machine_id_initialized: false,
      ssh_host_keys_present: false,
      random_seed_present: false,
      build_logs_present: false,
      builder_proxy_present: false,
      embedded_source_manifest_verified: true
    }
  }' > "$METADATA_TMP"
chmod 0644 "$METADATA_TMP"

mv -fT -- "$PACKAGES_TMP" "$PACKAGES_OUTPUT"
PACKAGES_TMP=
mv -fT -- "$METADATA_TMP" "$METADATA_OUTPUT"
METADATA_TMP=

printf 'Verified TeslaUSB %s arm64 Trixie image for Raspberry Pi Zero 2 W: %s\n' \
  "$EXPECTED_VERSION" "$IMAGE_PATH"
