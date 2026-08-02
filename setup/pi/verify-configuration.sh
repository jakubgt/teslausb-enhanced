#!/bin/bash -eu

function check_variable () {
  local var_name="$1"
  if [ -z "${!var_name+x}" ]
  then
    setup_progress "STOP: Define the variable $var_name like this: export $var_name=value"
    exit 1
  fi
}

function parent_disk_for_device () {
  local device="$1"
  local resolved
  local device_type
  local parent_disk

  resolved="$(readlink -f -- "$device")" || return 1
  device_type="$(lsblk -dnro TYPE -- "$resolved" 2> /dev/null | head -n 1)"
  if [ "$device_type" = "disk" ]
  then
    printf '%s\n' "$resolved"
    return 0
  fi

  parent_disk="$(lsblk -srpno NAME,TYPE -- "$resolved" 2> /dev/null | awk '$2 == "disk" { print $1; exit }')"
  if [ -z "$parent_disk" ]
  then
    return 1
  fi
  readlink -f -- "$parent_disk"
}

function refuse_system_data_drive () {
  local resolved_data_drive
  local data_disk
  local data_type
  local candidate
  local protected_disk
  local mountpoint
  local mount_source
  local -a protected_devices=()

  resolved_data_drive="$(readlink -f -- "$DATA_DRIVE")" || {
    setup_progress "STOP: DATA_DRIVE ($DATA_DRIVE) could not be resolved."
    exit 1
  }
  if [ ! -b "$resolved_data_drive" ]
  then
    setup_progress "STOP: DATA_DRIVE ($DATA_DRIVE) is not a block device."
    exit 1
  fi
  data_disk="$(parent_disk_for_device "$resolved_data_drive")" || {
    setup_progress "STOP: DATA_DRIVE ($DATA_DRIVE) is not backed by a disk device."
    exit 1
  }
  data_type="$(lsblk -dnro TYPE -- "$data_disk" 2> /dev/null | head -n 1)"
  if [ "$data_type" != "disk" ]
  then
    setup_progress "STOP: DATA_DRIVE ($DATA_DRIVE) does not resolve to a whole disk."
    exit 1
  fi

  for candidate in "${BOOT_DISK:-}" "${BOOT_PARTITION_DEVICE:-}" "${ROOT_PARTITION_DEVICE:-}"
  do
    if [ -n "$candidate" ]
    then
      protected_devices+=("$candidate")
    fi
  done

  # Root is mandatory. If its device cannot be identified, abort rather than
  # guessing that a destructive target is safe.
  mount_source="$(findmnt -nro SOURCE --target / 2> /dev/null || true)"
  if [ -z "$mount_source" ]
  then
    setup_progress "STOP: unable to identify the disk containing the root filesystem."
    exit 1
  fi
  protected_devices+=("$mount_source")

  for mountpoint in /teslausb /boot /boot/firmware
  do
    if [ -e "$mountpoint" ] || [ -L "$mountpoint" ]
    then
      mount_source="$(findmnt -nro SOURCE --target "$mountpoint" 2> /dev/null || true)"
      if [ -z "$mount_source" ]
      then
        setup_progress "STOP: unable to identify the disk containing $mountpoint."
        exit 1
      fi
      protected_devices+=("$mount_source")
    fi
  done

  for candidate in "${protected_devices[@]}"
  do
    protected_disk="$(parent_disk_for_device "$candidate")" || {
      setup_progress "STOP: unable to resolve protected system device $candidate to a disk."
      exit 1
    }
    if [ "$data_disk" = "$protected_disk" ]
    then
      setup_progress "STOP: DATA_DRIVE ($DATA_DRIVE) resolves to system disk $data_disk, which contains the root or boot filesystem."
      exit 1
    fi
  done

  DATA_DRIVE="$resolved_data_drive"
  export DATA_DRIVE
}

function check_supported_hardware () {
  if ! grep -q  'Raspberry Pi' /sys/firmware/devicetree/base/model
  then
    return
  fi
  if grep -q 'Raspberry Pi Zero W' /sys/firmware/devicetree/base/model
  then
    return
  fi
  if grep -q 'Raspberry Pi Zero 2' /sys/firmware/devicetree/base/model
  then
    return
  fi
  if grep -q 'Raspberry Pi 4' /sys/firmware/devicetree/base/model
  then
    return
  fi
  if grep -q 'Raspberry Pi 5' /sys/firmware/devicetree/base/model
  then
    return
  fi
  setup_progress "STOP: unsupported hardware: '$(cat /sys/firmware/devicetree/base/model)'"
  setup_progress "(only Pi Zero W, Pi 4, and Pi 5 have the necessary hardware to run teslausb)"
  exit 1
}

function check_udc () {
  local udc
  udc=$(find /sys/class/udc -type l -prune | wc -l)
  if [ "$udc" = "0" ]
  then
    setup_progress "STOP: this device ($(cat /sys/firmware/devicetree/base/model)) does not have a UDC driver"
    exit 1
  fi
}

function check_xfs () {
  local xfs_test_dir
  local xfs_image
  local xfs_mount

  setup_progress "Checking XFS support"
  # install XFS tools if needed
  if ! hash mkfs.xfs
  then
    DEBIAN_FRONTEND=noninteractive apt-get -y install xfsprogs
  fi
  xfs_test_dir="$(mktemp -d /tmp/teslausb-xfs-check.XXXXXX)"
  chmod 0700 "$xfs_test_dir"
  xfs_image="$xfs_test_dir/xfs.img"
  xfs_mount="$xfs_test_dir/mnt"
  truncate -s 1GB "$xfs_image"
  mkfs.xfs -m reflink=1 -f "$xfs_image" > /dev/null
  mkdir -p "$xfs_mount"
  if ! mount "$xfs_image" "$xfs_mount"
  then
    rm -rf -- "$xfs_test_dir"
    setup_progress "STOP: xfs does not support required features"
    exit 1
  fi

  umount "$xfs_mount"
  rm -rf -- "$xfs_test_dir"
  setup_progress "XFS supported"
}

function check_available_space () {
    if [ -z "$DATA_DRIVE" ]
    then
      setup_progress "DATA_DRIVE is not set. SD card will be used."
      check_available_space_sd
    else
      if [ -e "$DATA_DRIVE" ]
      then
        setup_progress "DATA_DRIVE is set to $DATA_DRIVE. This will be used for /mutable and /backingfiles."
        check_available_space_usb
      else
        setup_progress "STOP: DATA_DRIVE is set to $DATA_DRIVE, which does not exist."
        exit 1
      fi
    fi
}

function check_available_space_sd () {
  setup_progress "Verifying that there is sufficient space available on the MicroSD card..."

  # check if backingfiles and mutable already exist
  if [ -e /dev/disk/by-label/backingfiles ] && [ -e /dev/disk/by-label/mutable ]
  then
    backingfiles_size=$(blockdev --getsize64 /dev/disk/by-label/backingfiles)
    if [ "$backingfiles_size" -lt  $(( (1<<30) * 32)) ]
    then
      setup_progress "STOP: Existing backingfiles partition is too small"
      exit 1
    fi
  else
    # The following assumes that all the partitions are at the start
    # of the disk, and that all the free space is at the end.
 
    local available_space
 
    # query unpartitioned space
    available_space=$(sfdisk -F "$BOOT_DISK" | grep -o '[0-9]* bytes' | head -1 | awk '{print $1}')
 
    # Require at least 40 GB of available space.
    if [ "$available_space" -lt  $(( (1<<30) * 32)) ]
    then
      setup_progress "STOP: The MicroSD card is too small: $available_space bytes available."
      setup_progress "$(parted "${BOOT_DISK}" print)"
      exit 1
    fi
  fi

  setup_progress "There is sufficient space available."
}

function check_available_space_usb () {
  setup_progress "Verifying that there is sufficient space available on the USB drive ..."

  refuse_system_data_drive

  # Verify that the disk has been provided and not a partition
  local drive_type
  drive_type=$(lsblk -pno TYPE "$DATA_DRIVE" | head -n 1)

  if [ "$drive_type" != "disk" ]
  then
    setup_progress "STOP: The specified drive ($DATA_DRIVE) is not a disk (TYPE=$drive_type). Please specify path to the disk."
    exit 1
  fi

  # This verifies only the total size of the USB Drive.
  # All existing partitions on the drive will be erased if backingfiles are to be created or changed.
  # EXISTING DATA ON THE DATA_DRIVE WILL BE REMOVED.

  local drive_size
  drive_size=$(blockdev --getsize64 "$DATA_DRIVE")

  # Require at least 64GB drive size, or 59 GiB.
  if [ "$drive_size" -lt  $(( (1<<30) * 59)) ]
  then
    setup_progress "STOP: The USB drive is too small: $(( drive_size / 1024 / 1024 / 1024 ))GB available. Expected at least 64GB"
    setup_progress "$(parted "$DATA_DRIVE" print)"
    exit 1
  fi

  setup_progress "There is sufficient space available."
}

function check_setup_teslausb () {
  if [ ! -e /root/bin/setup-teslausb ]
  then
    setup_progress "STOP: setup-teslausb is not in /root/bin"
    exit 1
  fi

  local parent
  parent="$(ps -o comm= $PPID)"
  if [ "$parent" != "setup-teslausb" ]
  then
    setup_progress "STOP: $0 must be called from setup-teslausb: $parent"
    exit 1
  fi
}

check_supported_hardware

check_udc

check_xfs

check_setup_teslausb

check_variable "CAM_SIZE"

check_available_space
