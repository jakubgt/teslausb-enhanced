#!/bin/bash -eu

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$(sed -n '/^function ensure_live_drives_unmounted () {$/,/^}$/p' \
  "$repo_root/run/enable_gadget.sh")"

mounts=$'/\n/boot/firmware\n/backingfiles\n/mutable\n/tmp/snapshots/snap-000123'
inspection_status=0
findmnt() {
  [ "$*" = '--kernel --list --raw --noheadings --output TARGET' ] || return 64
  printf '%s\n' "$mounts"
  return "$inspection_status"
}

ensure_live_drives_unmounted
for live_mount in /mnt/cam /mnt/music /mnt/lightshow /mnt/boombox
do
  mounts=$'/\n'"$live_mount"
  status=0
  ensure_live_drives_unmounted 2>/dev/null || status=$?
  [ "$status" -eq 69 ] || {
    echo "USB export was allowed with $live_mount mounted" >&2
    exit 1
  }
done

# Empty or failed mount-table inspection must not imply that export is safe.
mounts=
status=0
ensure_live_drives_unmounted 2>/dev/null || status=$?
[ "$status" -eq 69 ]
mounts=/
inspection_status=1
status=0
ensure_live_drives_unmounted 2>/dev/null || status=$?
[ "$status" -eq 69 ]

echo 'USB export mount safety tests passed'
