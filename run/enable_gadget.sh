#!/bin/bash -eu

source /root/bin/envsetup.sh

function ensure_live_drives_unmounted () {
  local mounted_targets target
  # Read the kernel mount table once so a failed inspection cannot look like
  # four successfully unmounted drives. These are the live image mountpoints
  # installed by setup; immutable snapshot mounts are intentionally allowed.
  if ! mounted_targets=$(findmnt --kernel --list --raw --noheadings --output TARGET) ||
     [ -z "$mounted_targets" ]
  then
    echo "error: unable to verify that live USB images are unmounted" >&2
    return 69
  fi
  while IFS= read -r target
  do
    case "$target" in
      /mnt/cam | /mnt/music | /mnt/lightshow | /mnt/boombox)
        echo "error: refusing USB export while $target is mounted" >&2
        return 69
        ;;
    esac
  done <<< "$mounted_targets"
}

if [[ "${TESLAUSB_GADGET_LOCK_HELD:-}" != 1 ]]
then
  readonly gadget_lock_dir=/run/teslausb
  readonly gadget_lock_file="$gadget_lock_dir/gadget-operation.lock"
  [[ ! -L "$gadget_lock_dir" ]] || {
    echo "error: gadget lock directory is a symbolic link" >&2
    exit 69
  }
  mkdir -p -- "$gadget_lock_dir"
  chmod 0700 -- "$gadget_lock_dir"
  [[ ! -L "$gadget_lock_file" &&
     ( ! -e "$gadget_lock_file" || -f "$gadget_lock_file" ) ]] || {
    echo "error: gadget lock is not a regular file" >&2
    exit 69
  }
  exec 9> "$gadget_lock_file"
  chmod 0600 -- "$gadget_lock_file"
  flock -w 30 9 || {
    echo "error: another USB gadget operation is running" >&2
    exit 75
  }
  export TESLAUSB_GADGET_LOCK_HELD=1
fi

# Every caller, including startup and post-archive recovery, must preserve the
# guarded snapshot's refusal to expose an image that is still mounted locally.
ensure_live_drives_unmounted

if ! configfs_root=$(findmnt -o TARGET -n configfs)
then
  echo "error: configfs not found"
  exit 1
fi
readonly gadget_root="$configfs_root/usb_gadget/teslausb"

# USB supports many languages. 0x409 is US English
readonly lang=0x409

# configuration name can be anything, the convention
# appears to be to use "c"
readonly cfg=c

if [ -d "$gadget_root" ]
then
  echo "already prepared"
  exit 0
fi

modprobe libcomposite

mkdir -p "$gadget_root/configs/$cfg.1"

# common setup
echo 0x1d6b > "$gadget_root/idVendor"  # Linux Foundation
echo 0x0104 > "$gadget_root/idProduct" # Composite Gadget
echo 0x0100 > "$gadget_root/bcdDevice" # v1.0.0
echo 0x0200 > "$gadget_root/bcdUSB"    # USB 2.0
mkdir -p "$gadget_root/strings/$lang"
mkdir -p "$gadget_root/configs/$cfg.1/strings/$lang"
echo "TeslaUSB-$(sha256sum < /etc/machine-id | awk '{print $1}')" > "$gadget_root/strings/$lang/serialnumber"
echo TeslaUSB > "$gadget_root/strings/$lang/manufacturer"
echo "TeslaUSB Composite Gadget" > "$gadget_root/strings/$lang/product"
echo "TeslaUSB Config" > "$gadget_root/configs/$cfg.1/strings/$lang/configuration"

# A bare Raspberry Pi 4 or 5 can peak at at over 1 A during boot, but idles around 500 mA.
# A Raspberry Pi Zero 2 W can peak at over 300 mA during boot, but idles around 100 mA.
# A Raspberry Pi Zero W can peak up to 220 mA during boot, but idles around 80 mA.
if isPi5
then
  echo 600 > "$gadget_root/configs/$cfg.1/MaxPower"
elif isPi4
then
  echo 500 > "$gadget_root/configs/$cfg.1/MaxPower"
elif isPi2
then
  echo 200 > "$gadget_root/configs/$cfg.1/MaxPower"
else
  echo 100 > "$gadget_root/configs/$cfg.1/MaxPower"
fi

# mass storage setup
mkdir -p "$gadget_root/functions/mass_storage.0"

lun=0

if [ -e "/backingfiles/cam_disk.bin" ]
then
  echo "/backingfiles/cam_disk.bin" > "$gadget_root/functions/mass_storage.0/lun.${lun}/file"
  echo "TeslaUSB CAM $(du -h /backingfiles/cam_disk.bin | awk '{print $1}')" > "$gadget_root/functions/mass_storage.0/lun.${lun}/inquiry_string"
  ((++lun))
fi

if [ -e "/backingfiles/music_disk.bin" ]
then
  mkdir -p "$gadget_root/functions/mass_storage.0/lun.${lun}"
  echo "/backingfiles/music_disk.bin" > "$gadget_root/functions/mass_storage.0/lun.${lun}/file"
  echo "TeslaUSB MUSIC $(du -h /backingfiles/music_disk.bin | awk '{print $1}')" > "$gadget_root/functions/mass_storage.0/lun.${lun}/inquiry_string"
  ((++lun))
fi

if [ -e "/backingfiles/lightshow_disk.bin" ]
then
  mkdir -p "$gadget_root/functions/mass_storage.0/lun.${lun}"
  echo "/backingfiles/lightshow_disk.bin" > "$gadget_root/functions/mass_storage.0/lun.${lun}/file"
  echo "TeslaUSB LIGHTSHOW $(du -h /backingfiles/lightshow_disk.bin | awk '{print $1}')" > "$gadget_root/functions/mass_storage.0/lun.${lun}/inquiry_string"
  ((++lun))
fi

if [ -e "/backingfiles/boombox_disk.bin" ]
then
  mkdir -p "$gadget_root/functions/mass_storage.0/lun.${lun}"
  echo "/backingfiles/boombox_disk.bin" > "$gadget_root/functions/mass_storage.0/lun.${lun}/file"
  echo "TeslaUSB BOOMBOX $(du -h /backingfiles/boombox_disk.bin | awk '{print $1}')" > "$gadget_root/functions/mass_storage.0/lun.${lun}/inquiry_string"
  ((++lun))
fi

ln -sf "$gadget_root/functions/mass_storage.0" "$gadget_root/configs/$cfg.1"

# activate
find /sys/class/udc -type l -printf '%P\n' | head -1 > "$gadget_root/UDC"
