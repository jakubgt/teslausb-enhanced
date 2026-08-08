#!/bin/bash -eu

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

# g_mass_storage module may be loaded on a system that
# is being transitioned from module to configfs
modprobe -q -r g_mass_storage || true

if ! configfs_root=$(findmnt -o TARGET -n configfs)
then
  echo "error: configfs not found"
  exit 1
fi
readonly gadget_root="$configfs_root/usb_gadget/teslausb"

if [ ! -d "$gadget_root" ]
then
  echo "already released"
  exit 2
fi

echo > "$gadget_root/UDC" || true
rmdir "$gadget_root"/configs/*/strings/* || true
rm -f "$gadget_root"/configs/*/mass_storage.0 || true
rmdir "$gadget_root"/functions/mass_storage.0/lun.1 &> /dev/null || true
rmdir "$gadget_root"/functions/mass_storage.0/lun.2 &> /dev/null || true
rmdir "$gadget_root"/functions/mass_storage.0/lun.3 &> /dev/null || true
rmdir "$gadget_root"/functions/mass_storage.0 || true
rmdir "$gadget_root"/configs/* || true
rmdir "$gadget_root"/strings/* || true
rmdir "$gadget_root"

modprobe -r usb_f_mass_storage g_ether usb_f_ecm usb_f_rndis libcomposite || true
