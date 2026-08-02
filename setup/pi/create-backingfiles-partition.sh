#!/bin/bash -eu

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "create-backingfiles-partition: $1"
    return
  fi
  echo "create-backingfiles-partition: $1"
}

# install XFS tools if needed
if ! hash mkfs.xfs
then
  DEBIAN_FRONTEND=noninteractive apt-get -y install xfsprogs
fi

function partition_prefix_for {
  case $1 in
    /dev/mmcblk* | /dev/nvme* | /dev/loop*)
      echo p
      ;;
    /dev/sd*)
      echo
      ;;
    *)
      log_progress "STOP: can't determine partition naming scheme for '$1'"
      exit 1
      ;;
  esac
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
    log_progress "STOP: DATA_DRIVE ($DATA_DRIVE) could not be resolved."
    exit 1
  }
  if [ ! -b "$resolved_data_drive" ]
  then
    log_progress "STOP: DATA_DRIVE ($DATA_DRIVE) is not a block device."
    exit 1
  fi
  data_disk="$(parent_disk_for_device "$resolved_data_drive")" || {
    log_progress "STOP: DATA_DRIVE ($DATA_DRIVE) is not backed by a disk device."
    exit 1
  }
  data_type="$(lsblk -dnro TYPE -- "$data_disk" 2> /dev/null | head -n 1)"
  if [ "$data_type" != "disk" ]
  then
    log_progress "STOP: DATA_DRIVE ($DATA_DRIVE) does not resolve to a whole disk."
    exit 1
  fi

  for candidate in "${BOOT_DISK:-}" "${BOOT_PARTITION_DEVICE:-}" "${ROOT_PARTITION_DEVICE:-}"
  do
    if [ -n "$candidate" ]
    then
      protected_devices+=("$candidate")
    fi
  done
  mount_source="$(findmnt -nro SOURCE --target / 2> /dev/null || true)"
  if [ -z "$mount_source" ]
  then
    log_progress "STOP: unable to identify the disk containing the root filesystem."
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
        log_progress "STOP: unable to identify the disk containing $mountpoint."
        exit 1
      fi
      protected_devices+=("$mount_source")
    fi
  done

  for candidate in "${protected_devices[@]}"
  do
    protected_disk="$(parent_disk_for_device "$candidate")" || {
      log_progress "STOP: unable to resolve protected system device $candidate to a disk."
      exit 1
    }
    if [ "$data_disk" = "$protected_disk" ]
    then
      log_progress "STOP: DATA_DRIVE ($DATA_DRIVE) resolves to system disk $data_disk, which contains the root or boot filesystem."
      exit 1
    fi
  done

  DATA_DRIVE="$resolved_data_drive"
}

BACKINGFILES_MOUNTPOINT="${1:-none}"
MUTABLE_MOUNTPOINT="${2:-none}"
function update_fstab {
  if grep -q "LABEL=backingfiles" /etc/fstab
  then
    log_progress "backingfiles already defined in /etc/fstab. Not modifying /etc/fstab."
  elif [ "$BACKINGFILES_MOUNTPOINT" != "none" ]
  then
    echo "LABEL=backingfiles $BACKINGFILES_MOUNTPOINT xfs auto,rw,noatime 0 2" >> /etc/fstab
  fi
  if grep -q 'LABEL=mutable' /etc/fstab
  then
    log_progress "mutable already defined in /etc/fstab. Not modifying /etc/fstab."
  elif [ "$MUTABLE_MOUNTPOINT" != "none" ]
  then
    echo "LABEL=mutable $MUTABLE_MOUNTPOINT ext4 auto,rw 0 2" >> /etc/fstab
  fi
}

# Will check for USB Drive before running sd card
if [ -n "$DATA_DRIVE" ]
then
  log_progress "DATA_DRIVE is set to $DATA_DRIVE"
  refuse_system_data_drive
  PARTITION_PREFIX=$(partition_prefix_for "$DATA_DRIVE")
  P1="${DATA_DRIVE}${PARTITION_PREFIX}1"
  P2="${DATA_DRIVE}${PARTITION_PREFIX}2"
  # Check if backingfiles and mutable partitions exist
  if [ /dev/disk/by-label/backingfiles -ef "$P2" ] && [ /dev/disk/by-label/mutable -ef "$P1" ]
  then
    log_progress "Looks like backingfiles and mutable partitions already exist. Skipping partition creation."
  else
    log_progress "WARNING !!! This will delete EVERYTHING in $DATA_DRIVE."
    # Re-evaluate the resolved device and every protected root/boot disk at the
    # last possible moment. This second fail-closed check protects against a
    # changed device map between preflight and the destructive operation.
    refuse_system_data_drive
    wipefs -afq "$DATA_DRIVE"
    parted "$DATA_DRIVE" --script mktable gpt
    log_progress "$DATA_DRIVE fully erased. Creating partitions..."
    parted -a optimal -m "$DATA_DRIVE" mkpart primary ext4 '0%' 2GB
    parted -a optimal -m "$DATA_DRIVE" mkpart primary ext4 2GB '100%'
    log_progress "Backing files and mutable partitions created."

    log_progress "Formatting new partitions..."
    # Force creation of filesystems even if previous filesystem appears to exist
    mkfs.ext4 -F -L mutable "$P1"
    mkfs.xfs -f -m reflink=1 -L backingfiles "$P2"
  fi

  update_fstab
  log_progress "Done."
  exit 0
else
  echo "DATA_DRIVE not set. Proceeding to SD card setup"
fi

readonly LAST_PARTITION_DEVICE=$(sfdisk -q -l "$BOOT_DISK" | tail -1 | awk '{print $1}')
readonly LAST_PART_NUM=${LAST_PARTITION_DEVICE:0-1}
readonly SECOND_TO_LAST_PART_NUM=$((LAST_PART_NUM - 1))
readonly SECOND_TO_LAST_PARTITION_DEVICE=${LAST_PARTITION_DEVICE:0:-1}${SECOND_TO_LAST_PART_NUM}
if [ /dev/disk/by-label/mutable -ef "$LAST_PARTITION_DEVICE" ]
then
  readonly MUTABLE_DEVICE="$LAST_PARTITION_DEVICE"
else
  readonly MUTABLE_DEVICE="${BOOT_DEVICE_PARTITION_PREFIX}$((LAST_PART_NUM + 2))"
fi
if [ /dev/disk/by-label/backingfiles -ef "$SECOND_TO_LAST_PARTITION_DEVICE" ]
then
  readonly BACKINGFILES_DEVICE="$SECOND_TO_LAST_PARTITION_DEVICE"
else
  readonly BACKINGFILES_DEVICE="${BOOT_DEVICE_PARTITION_PREFIX}$((LAST_PART_NUM + 1))"
fi

# If the backingfiles partition follows the root partition, is type xfs,
# and is in turn followed by the mutable partition, type ext4, then return early.
if [ /dev/disk/by-label/backingfiles -ef "${BACKINGFILES_DEVICE}" ] && \
    [ /dev/disk/by-label/mutable -ef "${MUTABLE_DEVICE}" ] && \
    blkid "${MUTABLE_DEVICE}" | grep -q 'TYPE="ext4"'
then
  if blkid "${BACKINGFILES_DEVICE}" | grep -q 'TYPE="xfs"'
  then
    # assume these were either created previously by the setup scripts,
    # or manually by the user, and that they're big enough
    log_progress "using existing backingfiles and mutable partitions"
    update_fstab
    return &> /dev/null || exit 0
  elif blkid "${BACKINGFILES_DEVICE}" | grep -q 'TYPE="ext4"'
  then
    # special case: convert existing backingfiles from ext4 to xfs
    log_progress "reformatting existing backingfiles as xfs"
    systemctl stop teslausb.service || true
    if [ -e /root/bin/archiveloop ]
    then
      exec {ARCHIVELOOP_LOCK_FD}< /root/bin/archiveloop
      if ! flock -n "$ARCHIVELOOP_LOCK_FD"
      then
        log_progress "STOP: archiveloop is still running; refusing destructive filesystem conversion."
        exit 1
      fi
    fi
    /root/bin/disable_gadget.sh || true
    if mount | grep -qw "/mnt/cam"
    then
      if ! umount /mnt/cam
      then
        log_progress "STOP: couldn't unmount /mnt/cam"
        exit 1
      fi
    fi
    if mount | grep -qw "/backingfiles"
    then
      if ! umount /backingfiles
      then
        log_progress "STOP: couldn't unmount /backingfiles"
        exit 1
      fi
    fi
    mkfs.xfs -f -m reflink=1 -L backingfiles "${BACKINGFILES_DEVICE}"

    # update /etc/fstab
    sed -i 's/LABEL=backingfiles .*/LABEL=backingfiles \/backingfiles xfs auto,rw,noatime 0 2/' /etc/fstab
    mount /backingfiles
    log_progress "backingfiles converted to xfs and mounted"
    return &> /dev/null || exit 0
  fi
fi

# backingfiles and mutable partitions either don't exist, or are the wrong type
if [ -e "${BACKINGFILES_DEVICE}" ] || [ -e "${MUTABLE_DEVICE}" ]
then
  log_progress "STOP: partitions already exist, but are not as expected"
  log_progress "please delete them and re-run setup"
  exit 1
fi

log_progress "Checking existing partitions..."

DISK_SECTORS=$(blockdev --getsz "${BOOT_DISK}")
LAST_DISK_SECTOR=$((DISK_SECTORS - 1))
# mutable partition is 300MB at the end of the disk, calculate its start sector
FIRST_MUTABLE_SECTOR=$((LAST_DISK_SECTOR-614400+1))
# backingfiles partition sits between the last and mutable partition, calculate its start sector and size
LAST_PART_SECTOR=$(sfdisk -o End -q -l "${BOOT_DISK}" | tail +2 | sort -n | tail -1)
FIRST_BACKINGFILES_SECTOR=$((LAST_PART_SECTOR + 1))
# round up to 1MB boundary because the TeslaUSB Buster prebuilt as well as older Armbian
# images might have an odd root partition size
FIRST_BACKINGFILES_SECTOR=$(((FIRST_BACKINGFILES_SECTOR + 2047) / 2048 * 2048))
BACKINGFILES_NUM_SECTORS=$((FIRST_MUTABLE_SECTOR - FIRST_BACKINGFILES_SECTOR))

# As a rule of thumb, one gigabyte of /backingfiles space can hold about 36
# recording files. We need enough inodes in /mutable to create symlinks to
# the recordings. Leaving enough headroom to account for short recordings,
# directories, duplication of sentry files in recentclips, etc, this works
# out to about 1 inode for every 20000 sectors in /backingfiles.
NUM_MUTABLE_INODES=$((BACKINGFILES_NUM_SECTORS / 20000))

ORIGINAL_DISK_IDENTIFIER=$( fdisk -l "${BOOT_DISK}" | grep -e "^Disk identifier" | sed "s/Disk identifier: 0x//" )

log_progress "Modifying partition table for backing files partition..."
echo "$FIRST_BACKINGFILES_SECTOR,$BACKINGFILES_NUM_SECTORS" | sfdisk --force "${BOOT_DISK}" -N $((LAST_PART_NUM + 1))

log_progress "Modifying partition table for mutable (writable) partition for script usage..."
echo "$FIRST_MUTABLE_SECTOR," | sfdisk --force "${BOOT_DISK}" -N $((LAST_PART_NUM + 2))

# manually adding the partitions to the kernel's view of things is sometimes needed
if [ ! -e "${BACKINGFILES_DEVICE}" ] || [ ! -e "${MUTABLE_DEVICE}" ]
then
  partx --add --nr $((LAST_PART_NUM + 1)):$((LAST_PART_NUM + 2)) "${BOOT_DISK}"
fi
if [ ! -e "${BACKINGFILES_DEVICE}" ] || [ ! -e "${MUTABLE_DEVICE}" ]
then
  log_progress "failed to add partitions"
  exit 1
fi

NEW_DISK_IDENTIFIER=$( fdisk -l "${BOOT_DISK}" | grep -e "^Disk identifier" | sed "s/Disk identifier: 0x//" )

log_progress "Writing updated partitions to fstab and cmdline.txt"
sed -i "s/${ORIGINAL_DISK_IDENTIFIER}/${NEW_DISK_IDENTIFIER}/g" /etc/fstab
if [ -f "$CMDLINE_PATH" ]
then
  sed -i "s/${ORIGINAL_DISK_IDENTIFIER}/${NEW_DISK_IDENTIFIER}/" "$CMDLINE_PATH"
fi

log_progress "Formatting new partitions..."
# Force creation of filesystems even if previous filesystem appears to exist
mkfs.xfs -f -m reflink=1 -L backingfiles "${BACKINGFILES_DEVICE}"
mkfs.ext4 -F -N "$NUM_MUTABLE_INODES" -L mutable "${MUTABLE_DEVICE}"

update_fstab
