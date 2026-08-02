#!/bin/bash -eu

set -eu

BASH_BIN="${BASH_BIN:-$BASH}"
readonly BASH_BIN

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(dirname "$TEST_DIR")
readonly REPO_ROOT
TEST_TMP=$(mktemp -d)
readonly TEST_TMP
trap 'rm -rf "$TEST_TMP"' EXIT

function fail {
  echo "FAIL: $*" >&2
  exit 1
}

function assert_equal {
  if [ "$1" != "$2" ]
  then
    printf 'FAIL: expected <%s>, got <%s>\n' "$1" "$2" >&2
    exit 1
  fi
}

fakebin="$TEST_TMP/bin"
backingfiles="$TEST_TMP/backingfiles"
mkdir -p "$fakebin" "$backingfiles"

printf '%s\n' '#!/bin/sh' 'printf "%s\n" 2048' > "$fakebin/sfdisk"
# The expansion is intentionally deferred to the generated helper.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "${FAKE_FSTYPE:-ext4}"' > "$fakebin/blkid"
chmod +x "$fakebin/sfdisk" "$fakebin/blkid"

image="$TEST_TMP/image.bin"
touch "$image"
actual=$(FAKE_FSTYPE=ext4 PATH="$fakebin:$PATH" "$BASH_BIN" -eu "$REPO_ROOT/run/mountoptsforimage" "$image")
assert_equal "ext4 offset=1048576,time_offset=-420" "$actual"

helper="$TEST_TMP/mountoptsforimage"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "vfat utf8,umask=000,offset=1048576,time_offset=-420"' > "$helper"
chmod +x "$helper"

touch "$backingfiles/music_disk.bin"
actual=$(BACKINGFILES_ROOT="$backingfiles" MOUNTOPTSFORIMAGE="$helper" sh "$REPO_ROOT/run/auto.www" Music)
expected="-fstype=vfat,rw,utf8,umask=000,offset=1048576,time_offset=-420 :$backingfiles/music_disk.bin"
assert_equal "$expected" "$actual"
assert_equal "$expected" "$(cat "$backingfiles/music_disk.bin.opts")"

# A cached value must remain usable without invoking the helper again.
printf '%s\n' '#!/bin/sh' 'exit 1' > "$helper"
actual=$(BACKINGFILES_ROOT="$backingfiles" MOUNTOPTSFORIMAGE="$helper" sh "$REPO_ROOT/run/auto.www" Music)
assert_equal "$expected" "$actual"

# A failed helper must not leave behind a permanent or partial cache file.
rm "$backingfiles/music_disk.bin.opts"
if BACKINGFILES_ROOT="$backingfiles" MOUNTOPTSFORIMAGE="$helper" sh "$REPO_ROOT/run/auto.www" Music
then
  fail "auto.www accepted a failed mountoptsforimage invocation"
fi
[ ! -e "$backingfiles/music_disk.bin.opts" ] || fail "auto.www left an invalid cache file"
if compgen -G "$backingfiles/music_disk.bin.opts.tmp.*" > /dev/null
then
  fail "auto.www left a temporary cache file"
fi

printf '%s\n' '#!/bin/sh' 'printf "%s\n" "vfat utf8,umask=000,offset=1048576,time_offset=-420"' > "$helper"
snapdir="$backingfiles/snapshots/snap-000001"
snapshot_mount_root="$TEST_TMP/snapshot-mounts"
mkdir -p "$snapdir/mnt" "$snapshot_mount_root"
touch "$snapdir/snap.bin"
actual=$(BACKINGFILES_ROOT="$backingfiles" SNAPSHOT_MOUNT_ROOT="$snapshot_mount_root" MOUNTOPTSFORIMAGE="$helper" sh "$REPO_ROOT/run/auto.teslausb" snap-000001)
expected="-fstype=vfat,ro,utf8,umask=000,offset=1048576,time_offset=-420 :$snapdir/snap.bin"
assert_equal "$expected" "$actual"
assert_equal "$expected" "$(cat "$snapdir/snap.bin.opts")"
[ -L "$snapdir/mnt" ] || fail "auto.teslausb did not convert the mountpoint to a symlink"
assert_equal "$snapshot_mount_root/snap-000001" "$(readlink "$snapdir/mnt")"

echo "mount helper tests passed"
