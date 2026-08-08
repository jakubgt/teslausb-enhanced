#!/bin/bash -e

function lock_image_account () {
  local rootfs_dir="$1"
  local login_user="$2"
  local shadow_file
  local shadow_tmp

  case "$login_user" in
    ''|*[!A-Za-z0-9._-]*)
      echo "Refusing to lock an invalid image account name: $login_user" >&2
      return 1
      ;;
  esac

  shadow_file="$rootfs_dir/etc/shadow"
  if [ ! -f "$shadow_file" ] || [ -L "$shadow_file" ]
  then
    echo "Image shadow file is missing or unsafe: $shadow_file" >&2
    return 1
  fi

  shadow_tmp="$(mktemp "$rootfs_dir/etc/.shadow.XXXXXXXX")"
  if ! awk -F: -v OFS=: -v login_user="$login_user" '
      $1 == login_user {
        matches++
        if ($2 !~ /^!/) {
          $2 = "!" $2
        }
      }
      { print }
      END { if (matches != 1) exit 1 }
    ' "$shadow_file" > "$shadow_tmp" ||
     ! chown --reference="$shadow_file" "$shadow_tmp" ||
     ! chmod --reference="$shadow_file" "$shadow_tmp"
  then
    rm -f -- "$shadow_tmp"
    echo "Unable to lock image account $login_user" >&2
    return 1
  fi

  if ! mv -fT -- "$shadow_tmp" "$shadow_file"
  then
    rm -f -- "$shadow_tmp"
    return 1
  fi

  if ! awk -F: -v login_user="$login_user" '
      $1 == login_user && $2 ~ /^!/ { locked++ }
      END { exit locked == 1 ? 0 : 1 }
    ' "$shadow_file"
  then
    echo "Image account $login_user was not locked" >&2
    return 1
  fi
}

function verify_source_bundle () {
  local source_dir="$1"
  local metadata_file="$source_dir/SOURCE-METADATA"
  local manifest_file="$source_dir/SOURCE-MANIFEST.sha256"
  local manifest_name
  local expected_manifest_sha256
  local actual_manifest_sha256

  if [ ! -d "$source_dir" ] || [ -L "$source_dir" ] ||
     [ ! -f "$metadata_file" ] || [ -L "$metadata_file" ] ||
     [ ! -f "$manifest_file" ] || [ -L "$manifest_file" ]
  then
    echo "TeslaUSB source bundle or provenance files are missing or unsafe: $source_dir" >&2
    return 1
  fi
  if [ -n "$(find "$source_dir" -type l -print -quit)" ]
  then
    echo "TeslaUSB source bundle contains a symbolic link: $source_dir" >&2
    return 1
  fi

  if ! manifest_name="$(awk -F= '
      $1 == "source_manifest" {
        count++
        value = substr($0, index($0, "=") + 1)
      }
      END {
        if (count != 1) exit 1
        print value
      }
    ' "$metadata_file")" || [ "$manifest_name" != 'SOURCE-MANIFEST.sha256' ]
  then
    echo "TeslaUSB source metadata does not name the expected manifest" >&2
    return 1
  fi
  if ! expected_manifest_sha256="$(awk -F= '
      $1 == "source_manifest_sha256" {
        count++
        value = substr($0, index($0, "=") + 1)
      }
      END {
        if (count != 1) exit 1
        print value
      }
    ' "$metadata_file")"
  then
    echo "TeslaUSB source metadata does not contain one manifest digest" >&2
    return 1
  fi
  if [ "${#expected_manifest_sha256}" -ne 64 ] ||
     [[ "$expected_manifest_sha256" == *[!0-9a-f]* ]]
  then
    echo "TeslaUSB source metadata contains an invalid manifest digest" >&2
    return 1
  fi
  actual_manifest_sha256="$(sha256sum -- "$manifest_file")"
  actual_manifest_sha256="${actual_manifest_sha256%% *}"
  if [ "$actual_manifest_sha256" != "$expected_manifest_sha256" ]
  then
    echo "TeslaUSB source manifest digest does not match SOURCE-METADATA" >&2
    return 1
  fi

  # sha256sum verifies every recorded file. Comparing against a freshly
  # generated canonical manifest also rejects unrecorded files and unsafe
  # manifest path tricks. Only the two root provenance files are excluded.
  if ! (
    cd "$source_dir"
    cmp -s -- "$manifest_name" <(
        while IFS= read -r -d '' bundled_file
        do
          relative_file=${bundled_file#./}
          sha256sum -- "$relative_file"
        done < <(find . -type f ! -path './SOURCE-MANIFEST.sha256' \
                          ! -path './SOURCE-METADATA' -print0 | LC_ALL=C sort -z)
      ) &&
      sha256sum -c -- "$manifest_name" > /dev/null
  )
  then
    echo "TeslaUSB source bundle does not match its complete manifest" >&2
    return 1
  fi
}

# pi-gen requires a configured password when first-boot user renaming is
# disabled. Lock that account in the offline root filesystem before the image
# can boot or its SSH service can accept a password.
# shellcheck disable=SC2153 # ROOTFS_DIR is provided by pi-gen's stage runner.
lock_image_account "${ROOTFS_DIR}" "${FIRST_USER_NAME:-pi}"

touch "${ROOTFS_DIR}/boot/firmware/ssh"
install -m 755 files/rc.local                             "${ROOTFS_DIR}/etc/"
install -m 644 files/teslausb_config_wizard.html          "${ROOTFS_DIR}/boot/firmware/teslausb_config_wizard.html"
install -m 666 files/teslausb_setup.json.sample           "${ROOTFS_DIR}/boot/firmware/teslausb_setup.json.sample"
install -m 666 files/teslausb_setup_variables.conf.sample "${ROOTFS_DIR}/boot/firmware/teslausb_setup_variables.conf.sample"
install -m 666 files/wpa_supplicant.conf.sample           "${ROOTFS_DIR}/boot/firmware"
install -m 666 files/run_once                             "${ROOTFS_DIR}/boot/firmware"
install -d "${ROOTFS_DIR}/root/bin"
install -d -m 755 "${ROOTFS_DIR}/usr/local/lib/teslausb"
install -m 755 files/teslausb_config.py \
  "${ROOTFS_DIR}/usr/local/lib/teslausb/teslausb_config.py"
install -m 644 files/teslausb-config-loader.sh \
  "${ROOTFS_DIR}/usr/local/lib/teslausb/teslausb-config-loader.sh"
verify_source_bundle files/teslausb-source
installed_source_dir="${ROOTFS_DIR}/usr/local/share/teslausb-source"
if [ -L "$installed_source_dir" ] ||
   { [ -e "$installed_source_dir" ] && [ ! -d "$installed_source_dir" ]; }
then
  echo "Refusing to replace unsafe installed source path: $installed_source_dir" >&2
  exit 1
fi
install -d -m 0755 "$installed_source_dir"
find "$installed_source_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -a files/teslausb-source/. "$installed_source_dir/"
chown -R root:root "$installed_source_dir"
chmod -R go-w "$installed_source_dir"
verify_source_bundle "$installed_source_dir"

# ensure dwc2 module is loaded
echo "dtoverlay=dwc2" >> "${ROOTFS_DIR}/boot/firmware/config.txt"

# remove unwanted packages, disable unwanted services, and disable swap
on_chroot << EOF
apt-get remove -y --purge triggerhappy userconf-pi dphys-swapfile rpi-swap systemd-zram-generator firmware-libertas firmware-realtek firmware-atheros mkvtoolnix
apt-get -y autoremove
systemctl disable keyboard-setup
systemctl disable rpi-resize.service
systemctl disable resize2fs_once
systemctl disable dpkg-db-backup.timer
update-rc.d resize2fs_once remove
rm -f -- /etc/init.d/resize2fs_once
rm -f -- /usr/share/initramfs-tools/scripts/local-premount/firstboot
update-initramfs -u
EOF
