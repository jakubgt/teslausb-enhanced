#!/bin/bash -eu

set -o pipefail

install_path="${1:?usage: install-tesla-ble-artifact.sh INSTALL_PATH}"
artifact_version="${TESLA_BLE_ARTIFACT_VERSION:-v0.4.1}"
artifact_sha256="${TESLA_BLE_ARTIFACT_SHA256:-6e1411a22a948760796c5b19c97337ea2431314d37486e060402e260b6fd21a4}"
artifact_max_bytes="${TESLA_BLE_ARTIFACT_MAX_BYTES:-67108864}"
artifact_name=vehicle-command-binaries-linux-armv6.tar.gz
artifact_url=""
work_dir=""
release_stage=""
link_stage=""

fail() {
  printf 'STOP: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  [ -z "$link_stage" ] || rm -rf -- "$link_stage"
  [ -z "$release_stage" ] || rm -rf -- "$release_stage"
  [ -z "$work_dir" ] || rm -rf -- "$work_dir"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [[ ! "$artifact_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]]
then
  fail "invalid Tesla BLE artifact version: $artifact_version"
fi
if [[ ! "$artifact_sha256" =~ ^[0-9A-Fa-f]{64}$ ]]
then
  fail 'Tesla BLE artifact SHA-256 must contain exactly 64 hexadecimal characters'
fi
artifact_sha256=${artifact_sha256,,}
if [[ ! "$artifact_max_bytes" =~ ^[1-9][0-9]*$ ]] ||
   [ "$artifact_max_bytes" -gt 536870912 ]
then
  fail 'Tesla BLE artifact size limit must be between 1 byte and 512 MiB'
fi
artifact_url="https://github.com/MikeBishop/tesla-vehicle-command-arm-binaries/releases/download/${artifact_version}/${artifact_name}"

if [ ! -d "$install_path" ] || [ -L "$install_path" ]
then
  fail "$install_path must be a real directory"
fi

work_dir=$(mktemp -d /tmp/teslausb-ble.XXXXXX)
archive="$work_dir/$artifact_name"
if [ -n "${TESLA_BLE_ARTIFACT_FILE:-}" ]
then
  if [ ! -f "$TESLA_BLE_ARTIFACT_FILE" ] || [ -L "$TESLA_BLE_ARTIFACT_FILE" ]
  then
    fail 'local Tesla BLE artifact must be a regular file'
  fi
  cp -- "$TESLA_BLE_ARTIFACT_FILE" "$archive"
elif declare -F curlwrapper > /dev/null
then
  curlwrapper --connect-timeout 10 --max-time 180 \
    --max-filesize "$artifact_max_bytes" -L -o "$archive" "$artifact_url"
else
  curl --fail --silent --show-error --connect-timeout 10 --max-time 180 \
    --max-filesize "$artifact_max_bytes" --location --output "$archive" "$artifact_url"
fi

artifact_size=$(stat --format='%s' -- "$archive") \
  || fail 'Tesla BLE artifact size could not be read'
[ "$artifact_size" -le "$artifact_max_bytes" ] \
  || fail "Tesla BLE artifact exceeds the $artifact_max_bytes byte limit"

printf '%s  %s\n' "$artifact_sha256" "$archive" | sha256sum --check --status \
  || fail 'Tesla BLE artifact checksum verification failed'

member_names="$work_dir/members.txt"
member_details="$work_dir/member-details.txt"
canonical_members="$work_dir/canonical-members.txt"
LC_ALL=C tar --quoting-style=escape -tzf "$archive" > "$member_names" \
  || fail 'Tesla BLE artifact member listing failed'
LC_ALL=C tar --quoting-style=escape -tvzf "$archive" > "$member_details" \
  || fail 'Tesla BLE artifact detailed member listing failed'

while IFS= read -r detail || [ -n "$detail" ]
do
  [ "${detail:0:1}" = '-' ] \
    || fail 'Tesla BLE artifact contains an unsupported archive member type'
done < "$member_details"

: > "$canonical_members"
while IFS= read -r member || [ -n "$member" ]
do
  case "$member" in
    *\\* | *[!A-Za-z0-9._/-]*)
      fail 'Tesla BLE artifact contains an escaped, control, or unsupported name'
      ;;
    ./tesla-auth-token | ./tesla-control | ./tesla-http-proxy | ./tesla-jws | ./tesla-keygen | \
    tesla-auth-token | tesla-control | tesla-http-proxy | tesla-jws | tesla-keygen)
      printf '%s\n' "${member#./}" >> "$canonical_members"
      ;;
    *)
      fail "Tesla BLE artifact contains an unexpected member: $member"
      ;;
  esac
done < "$member_names"

for member in \
  tesla-auth-token \
  tesla-control \
  tesla-http-proxy \
  tesla-jws \
  tesla-keygen
do
  count=$(grep -Fxc -- "$member" "$canonical_members" || true)
  [ "$count" -eq 1 ] || fail "Tesla BLE artifact must contain exactly one $member"
done

payload_dir="$work_dir/payload"
mkdir -p -- "$payload_dir"
tar -xzf "$archive" -C "$payload_dir" --no-same-owner --no-same-permissions \
  || fail 'Tesla BLE artifact extraction failed'

# Validate the complete pair before creating or replacing any live path.
for binary in tesla-control tesla-keygen
do
  if [ ! -f "$payload_dir/$binary" ] || [ -L "$payload_dir/$binary" ]
  then
    fail "Tesla BLE artifact is missing regular file $binary"
  fi
done

release_root="$install_path/tesla-vehicle-command-releases"
if [ -L "$release_root" ] || { [ -e "$release_root" ] && [ ! -d "$release_root" ]; }
then
  fail "$release_root must be a real directory"
fi
mkdir -p -- "$release_root"
release_id="${artifact_version}-${artifact_sha256}"
release_dir="$release_root/$release_id"

release_stage=$(mktemp -d "$release_root/.release.XXXXXX")
for binary in tesla-control tesla-keygen
do
  install -m 0755 "$payload_dir/$binary" "$release_stage/$binary"
done
{
  printf 'version=%s\n' "$artifact_version"
  printf 'sha256=%s\n' "$artifact_sha256"
  printf 'url=%s\n' "$artifact_url"
  for binary in tesla-control tesla-keygen
  do
    printf '%s  %s\n' "$(sha256sum "$release_stage/$binary" | cut -d ' ' -f 1)" "$binary"
  done
} > "$release_stage/manifest"
chmod 0644 "$release_stage/manifest"
chmod 0755 "$release_stage"

if [ -L "$release_dir" ] || { [ -e "$release_dir" ] && [ ! -d "$release_dir" ]; }
then
  fail "$release_dir must be a real directory"
fi
if [ -d "$release_dir" ]
then
  for binary in tesla-control tesla-keygen
  do
    if [ ! -f "$release_dir/$binary" ] || [ -L "$release_dir/$binary" ]
    then
      fail "existing Tesla BLE release is missing regular file $binary"
    fi
    cmp --silent "$release_stage/$binary" "$release_dir/$binary" \
      || fail "existing Tesla BLE release content does not match $artifact_sha256"
  done
  if [ ! -f "$release_dir/manifest" ] || [ -L "$release_dir/manifest" ]
  then
    fail 'existing Tesla BLE release is missing its regular manifest'
  fi
  cmp --silent "$release_stage/manifest" "$release_dir/manifest" \
    || fail 'existing Tesla BLE release manifest does not match'
  rm -rf -- "$release_stage"
  release_stage=""
else
  mv -T -- "$release_stage" "$release_dir"
  release_stage=""
fi

current_link="$install_path/tesla-vehicle-command-current"
if [ -e "$current_link" ] && [ ! -L "$current_link" ]
then
  fail "$current_link must be a symbolic link"
fi
if [ -L "$current_link" ]
then
  current_target=$(readlink -- "$current_link") || fail 'could not read current Tesla BLE release link'
  if [[ ! "$current_target" =~ ^tesla-vehicle-command-releases/v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*-[0-9a-f]{64}$ ]]
  then
    fail 'current Tesla BLE release link points outside the managed release directory'
  fi
fi
for live_name in tesla-control tesla-keygen tesla-vehicle-command.manifest
do
  if { [ -e "$install_path/$live_name" ] || [ -L "$install_path/$live_name" ]; } &&
     [ ! -f "$install_path/$live_name" ] && [ ! -L "$install_path/$live_name" ]
  then
    fail "$install_path/$live_name must be a regular file or symbolic link"
  fi
done

# The public links remain stable across later upgrades. The one atomic switch
# of `current` activates both validated binaries as a pair.
link_stage=$(mktemp -d "$install_path/.tesla-ble-links.XXXXXX")
ln -s tesla-vehicle-command-current/tesla-control "$link_stage/tesla-control"
ln -s tesla-vehicle-command-current/tesla-keygen "$link_stage/tesla-keygen"
ln -s tesla-vehicle-command-current/manifest "$link_stage/tesla-vehicle-command.manifest"
ln -s "tesla-vehicle-command-releases/$release_id" "$link_stage/tesla-vehicle-command-current"
# On a first install, make the validated release available before exposing
# any stable public link. On upgrades the stable links already dereference
# through current, so replacing current remains the single activation point.
if [ ! -L "$current_link" ]
then
  mv -Tf -- "$link_stage/tesla-vehicle-command-current" "$current_link"
fi
for live_name in tesla-control tesla-keygen tesla-vehicle-command.manifest
do
  mv -Tf -- "$link_stage/$live_name" "$install_path/$live_name"
done
if [ -e "$link_stage/tesla-vehicle-command-current" ] ||
   [ -L "$link_stage/tesla-vehicle-command-current" ]
then
  mv -Tf -- "$link_stage/tesla-vehicle-command-current" "$current_link"
fi
rm -rf -- "$link_stage"
link_stage=""

printf 'Installed verified Tesla BLE release %s.\n' "$release_id"
