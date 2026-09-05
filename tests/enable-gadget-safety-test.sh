#!/bin/bash -eu

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$(sed -n '/^function ensure_live_drives_unmounted () {$/,/^}$/p' \
  "$repo_root/run/enable_gadget.sh")"

# Exercise the real findmnt parser, not just an argv-accepting shell mock. The
# synthetic mountinfo is supplied through a pipe: no mounts, image files, gadget
# operations, or production mount-table entries are changed by these tests.
command -v findmnt >/dev/null || {
  echo 'These tests require the real util-linux findmnt command' >&2
  exit 1
}
base_mountinfo=$'20 1 8:1 / / rw,relatime - ext4 /dev/fixture-root rw\n21 20 8:2 / /boot/firmware ro,relatime - vfat /dev/fixture-boot ro\n22 20 8:3 / /backingfiles rw,relatime - xfs /dev/fixture-backing rw\n23 20 8:4 / /mutable rw,relatime - ext4 /dev/fixture-mutable rw\n24 20 0:50 / /tmp/snapshots/snap-000123 ro,relatime - tmpfs tmpfs ro'
mountinfo="$base_mountinfo"
findmnt() {
  command findmnt "$@" --tab-file <(printf '%s\n' "$mountinfo")
}

ensure_live_drives_unmounted
for live_mount in /mnt/cam /mnt/music /mnt/lightshow /mnt/boombox
do
  for mount_mode in ro rw
  do
    mountinfo="$base_mountinfo"$'\n'"25 20 7:1 / $live_mount $mount_mode,relatime - vfat /dev/fixture-loop $mount_mode"
    status=0
    ensure_live_drives_unmounted 2>/dev/null || status=$?
    [ "$status" -eq 69 ] || {
      echo "Real mount-table inspection allowed $live_mount mounted $mount_mode" >&2
      exit 1
    }
  done
done

# Keep deterministic fault-injection cases in addition to real CLI coverage.
mounts=$'/\n/boot/firmware\n/backingfiles\n/mutable\n/tmp/snapshots/snap-000123'
inspection_status=0
findmnt() {
  [ "$*" = '--kernel --raw --noheadings --output TARGET' ] || return 64
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
