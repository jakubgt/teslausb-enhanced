#!/bin/bash -eu

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/teslausb-gadget-status.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

# Exercise the real collector against configfs-shaped fixtures without root,
# a USB host, or changes to the running machine's gadget.
eval "$(sed -n '/^function read_drive_status {$/,/^}$/p' \
  "$repo_root/teslausb-www/html/cgi-bin/status.sh")"
gadget="$test_dir/gadget"
udc_class="$test_dir/udc"
drives_active=
camera_drive_state=
usb_state=

check_status() {
  read_drive_status "$gadget" "$udc_class"
  if [[ "$drives_active" != "$1" || "$camera_drive_state" != "$2" || "$usb_state" != "$3" ]]
  then
    printf 'Expected %s/%s/%s, got %s/%s/%s\n' \
      "$1" "$2" "$3" "$drives_active" "$camera_drive_state" "$usb_state" >&2
    exit 1
  fi
}

check_status no disabled unknown
mkdir -p "$gadget"
check_status yes unknown unknown
touch "$gadget/UDC"
check_status yes prepared 'not attached'

mkdir -p "$gadget/configs/c.1" "$gadget/functions/mass_storage.0/lun.0" \
  "$udc_class/test-controller"
ln -s "$gadget/functions/mass_storage.0" "$gadget/configs/c.1/mass_storage.0"
printf '%s\n' test-controller > "$gadget/UDC"
printf '%s\n' /backingfiles/cam_disk.bin > "$gadget/functions/mass_storage.0/lun.0/file"
printf '%s\n' 'not attached' > "$udc_class/test-controller/state"
check_status yes disconnected 'not attached'

for kernel_state in attached powered default addressed
do
  printf '%s\n' "$kernel_state" > "$udc_class/test-controller/state"
  check_status yes connecting "$kernel_state"
done
printf '%s\n' configured > "$udc_class/test-controller/state"
check_status yes connected configured

# A snapshot detaches only the camera medium; the UDC can remain configured.
# The enabled/disabled API field stays unchanged for the toggle endpoint.
: > "$gadget/functions/mass_storage.0/lun.0/file"
check_status yes paused configured
printf '%s\n' /backingfiles/music_disk.bin > "$gadget/functions/mass_storage.0/lun.0/file"
check_status yes unavailable configured
printf '%s\n' /backingfiles/cam_disk.bin > "$gadget/functions/mass_storage.0/lun.0/file"
printf '%s\n' suspended > "$udc_class/test-controller/state"
check_status yes suspended suspended

rm "$udc_class/test-controller/state"
check_status yes unknown unknown
printf '%s\n' configured > "$udc_class/test-controller/state"
rm "$gadget/functions/mass_storage.0/lun.0/file"
check_status yes unknown configured
rm "$gadget/configs/c.1/mass_storage.0"
check_status yes prepared configured

printf '%s\n' ../test-controller > "$gadget/UDC"
check_status yes unknown unknown
printf 'gadget status tests passed\n'
