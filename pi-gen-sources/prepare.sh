#!/bin/bash

set -euo pipefail

readonly OFFICIAL_PI_GEN_COMMIT=ca8aeed0ae300c2a89f55ce9617d5f96a27e99e5

SRC=$(dirname "$(readlink -f "$0")")
DEST=$(readlink -f .)
REPO_ROOT=$(dirname "$SRC")
WORK_DIR=

stop() {
  printf 'STOP: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$WORK_DIR" ]
  then
    case "$WORK_DIR" in
      "$DEST"/.teslausb-prepare.*)
        [ -L "$WORK_DIR" ] || rm -rf -- "$WORK_DIR"
        ;;
      *)
        printf 'WARNING: refusing to remove unexpected prepare path: %s\n' \
          "$WORK_DIR" >&2
        ;;
    esac
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for required_command in awk chmod cp find git install mktemp mv readlink rm \
  sha256sum sort tar touch tr
do
  command -v "$required_command" > /dev/null || \
    stop "required build command is unavailable: $required_command"
done

if [[ "$DEST" != */pi-gen ]]
then
  stop "$0 must be called from the RPi-Distro pi-gen folder"
fi

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1
then
  stop "TeslaUSB image preparation requires a clean Git clone so tracked source and its exact commit can be proven. GitHub source archives are not sufficient. Clone the release with: git clone --branch <release-tag> --single-branch <repository-url> teslausb"
fi
SOURCE_TOP=$(git -C "$REPO_ROOT" rev-parse --show-toplevel)
[ "$(readlink -f "$SOURCE_TOP")" = "$REPO_ROOT" ] || \
  stop "prepare.sh must live in the root of the TeslaUSB Git checkout"

SOURCE_DIRTY=$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=no)
if [ -n "$SOURCE_DIRTY" ]
then
  printf '%s\n' "$SOURCE_DIRTY" >&2
  stop "tracked TeslaUSB inputs are modified, staged, or deleted; commit them and build the release commit, or restore them before preparing an image"
fi
SOURCE_COMMIT=$(git -C "$REPO_ROOT" rev-parse --verify 'HEAD^{commit}')
SOURCE_EPOCH=$(git -C "$REPO_ROOT" show -s --format=%ct "$SOURCE_COMMIT")
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || stop "unable to resolve the TeslaUSB source commit"
[[ "$SOURCE_EPOCH" =~ ^[0-9]+$ ]] || stop "unable to resolve the TeslaUSB source timestamp"

if ! git -C "$DEST" rev-parse --is-inside-work-tree > /dev/null 2>&1
then
  stop "the destination must be a Git clone of RPi-Distro/pi-gen"
fi
PI_GEN_TOP=$(git -C "$DEST" rev-parse --show-toplevel)
[ "$(readlink -f "$PI_GEN_TOP")" = "$DEST" ] || \
  stop "the current directory must be the root of the pi-gen Git checkout"
PI_GEN_COMMIT=$(git -C "$DEST" rev-parse --verify 'HEAD^{commit}')
EXPECTED_PI_GEN_COMMIT=${TESLAUSB_PI_GEN_COMMIT_OVERRIDE:-$OFFICIAL_PI_GEN_COMMIT}
if ! [[ "$EXPECTED_PI_GEN_COMMIT" =~ ^[0-9a-f]{40}$ ]]
then
  stop "TESLAUSB_PI_GEN_COMMIT_OVERRIDE must be one exact lowercase 40-character commit SHA"
fi
if [ "$PI_GEN_COMMIT" != "$EXPECTED_PI_GEN_COMMIT" ]
then
  stop "pi-gen commit mismatch: expected $EXPECTED_PI_GEN_COMMIT but found $PI_GEN_COMMIT. Check out the documented commit, or deliberately pin another exact commit with TESLAUSB_PI_GEN_COMMIT_OVERRIDE=<40-character-sha>."
fi
git -C "$DEST" cat-file -e "$PI_GEN_COMMIT:stage2/prerun.sh" 2> /dev/null || \
  stop "the pinned pi-gen commit does not contain stage2/prerun.sh"
for pi_gen_directory in \
  "$DEST/stage2" \
  "$DEST/export-image" \
  "$DEST/export-image/01-user-rename"
do
  if [ -L "$pi_gen_directory" ] || [ ! -d "$pi_gen_directory" ] ||
     [[ "$(readlink -f "$pi_gen_directory")" != "$DEST"/* ]]
  then
    stop "required pi-gen build path is missing, symbolic, or outside the checkout: $pi_gen_directory"
  fi
done

readonly -a SOURCE_ALLOWLIST=(
  LICENSE
  VERSION
  run
  setup
  teslausb-www
  pi-gen-sources/pi-gen-config
  pi-gen-sources/00-teslausb-tweaks
)
readonly -a REQUIRED_SOURCE_FILES=(
  LICENSE
  VERSION
  run/archiveloop
  setup/pi/setup-teslausb
  teslausb-www/teslausb.nginx
  pi-gen-sources/pi-gen-config
  pi-gen-sources/00-teslausb-tweaks/00-run.sh
  pi-gen-sources/00-teslausb-tweaks/00-packages
  pi-gen-sources/00-teslausb-tweaks/files/rc.local
  pi-gen-sources/00-teslausb-tweaks/files/teslausb-config-loader.sh
  pi-gen-sources/00-teslausb-tweaks/files/teslausb_config.py
)

for required_source in "${REQUIRED_SOURCE_FILES[@]}"
do
  git -C "$REPO_ROOT" cat-file -e "$SOURCE_COMMIT:$required_source" 2> /dev/null || \
    stop "required tracked source is missing from $SOURCE_COMMIT: $required_source"
done

tracked_count=0
while IFS= read -r -d '' tree_entry
do
  tree_metadata=${tree_entry%%$'\t'*}
  tracked_path=${tree_entry#*$'\t'}
  tracked_mode=${tree_metadata%% *}
  case "$tracked_mode" in
    100644|100755) ;;
    *) stop "allowlisted source contains an unsupported symlink, submodule, or special entry: $tracked_path ($tracked_mode)" ;;
  esac
  case "$tracked_path" in
    LICENSE|VERSION|run/*|setup/*|teslausb-www/*|pi-gen-sources/pi-gen-config|pi-gen-sources/00-teslausb-tweaks/*) ;;
    *) stop "Git returned a path outside the source allowlist: $tracked_path" ;;
  esac
  case "$tracked_path" in
    *$'\n'*|*$'\r'*|*$'\t'*|*\\*)
      stop "allowlisted source contains an unsafe path name"
      ;;
    pi-gen-sources/00-teslausb-tweaks/files/teslausb-source|pi-gen-sources/00-teslausb-tweaks/files/teslausb-source/*)
      stop "the generated teslausb-source bundle path must not be committed"
      ;;
  esac
  tracked_count=$((tracked_count + 1))
done < <(git -C "$REPO_ROOT" ls-tree -r -z --full-tree "$SOURCE_COMMIT" -- \
  "${SOURCE_ALLOWLIST[@]}")
[ "$tracked_count" -gt 0 ] || stop "the tracked source allowlist is empty"

WORK_DIR=$(mktemp -d "$DEST/.teslausb-prepare.XXXXXXXX")
SOURCE_EXPORT="$WORK_DIR/source"
STAGE_NEXT="$WORK_DIR/stage_teslausb"
install -d -m 0755 "$SOURCE_EXPORT" "$STAGE_NEXT"

# Export directly from the clean commit. The working tree is never copied, so
# ignored credentials and other untracked files cannot enter the image.
git -C "$REPO_ROOT" archive --format=tar "$SOURCE_COMMIT" -- \
  "${SOURCE_ALLOWLIST[@]}" | tar -xf - -C "$SOURCE_EXPORT"

mapfile -t source_version_lines < "$SOURCE_EXPORT/VERSION"
[ "${#source_version_lines[@]}" -eq 1 ] || stop "VERSION must contain exactly one line"
SOURCE_VERSION=${source_version_lines[0]%$'\r'}
[[ "$SOURCE_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]] || \
  stop "VERSION must contain one safe release identifier"

install -m 0644 /dev/null "$STAGE_NEXT/EXPORT_IMAGE"
git -C "$DEST" show "$PI_GEN_COMMIT:stage2/prerun.sh" > "$STAGE_NEXT/prerun.sh"
chmod 0755 "$STAGE_NEXT/prerun.sh"
cp -a "$SOURCE_EXPORT/pi-gen-sources/00-teslausb-tweaks" "$STAGE_NEXT/"

BUNDLED_SOURCE="$STAGE_NEXT/00-teslausb-tweaks/files/teslausb-source"
if [ -e "$BUNDLED_SOURCE" ] || [ -L "$BUNDLED_SOURCE" ]
then
  stop "reserved generated bundle path already exists in tracked source"
fi
install -d -m 0755 "$BUNDLED_SOURCE/pi-gen-sources"
cp -a "$SOURCE_EXPORT/LICENSE" "$SOURCE_EXPORT/VERSION" \
  "$SOURCE_EXPORT/run" "$SOURCE_EXPORT/setup" "$SOURCE_EXPORT/teslausb-www" \
  "$BUNDLED_SOURCE/"
cp -a "$SOURCE_EXPORT/pi-gen-sources/pi-gen-config" \
  "$SOURCE_EXPORT/pi-gen-sources/00-teslausb-tweaks" \
  "$BUNDLED_SOURCE/pi-gen-sources/"

SOURCE_MANIFEST="$BUNDLED_SOURCE/SOURCE-MANIFEST.sha256"
(
  cd "$BUNDLED_SOURCE"
  while IFS= read -r -d '' bundled_file
  do
    relative_file=${bundled_file#./}
    sha256sum -- "$relative_file"
  done < <(find . -type f ! -path './SOURCE-MANIFEST.sha256' \
                    ! -path './SOURCE-METADATA' -print0 | LC_ALL=C sort -z)
) > "$SOURCE_MANIFEST"
chmod 0644 "$SOURCE_MANIFEST"
SOURCE_MANIFEST_SHA256=$(sha256sum "$SOURCE_MANIFEST" | awk '{print $1}')

{
  printf 'format=1\n'
  printf 'teslausb_version=%s\n' "$SOURCE_VERSION"
  printf 'teslausb_source_commit=%s\n' "$SOURCE_COMMIT"
  printf 'teslausb_source_epoch=%s\n' "$SOURCE_EPOCH"
  printf 'pi_gen_commit=%s\n' "$PI_GEN_COMMIT"
  printf 'official_pi_gen_commit=%s\n' "$OFFICIAL_PI_GEN_COMMIT"
  printf 'source_manifest=SOURCE-MANIFEST.sha256\n'
  printf 'source_manifest_sha256=%s\n' "$SOURCE_MANIFEST_SHA256"
} > "$BUNDLED_SOURCE/SOURCE-METADATA"
chmod 0644 "$BUNDLED_SOURCE/SOURCE-METADATA"

# Normalize generated mtimes so two preparations of the same commits produce
# the same staged tree independent of wall-clock time.
find "$STAGE_NEXT" -exec touch -d "@$SOURCE_EPOCH" -- {} +

if [ -L "$DEST/config" ]
then
  stop "refusing to replace symbolic-link pi-gen config"
fi
install -m 0644 "$SOURCE_EXPORT/pi-gen-sources/pi-gen-config" "$WORK_DIR/config"

for obsolete_path in \
  "$DEST/stage2/EXPORT_NOOBS" \
  "$DEST/stage2/EXPORT_IMAGE" \
  "$DEST/export-image/01-user-rename/00-packages"
do
  if [ -e "$obsolete_path" ] || [ -L "$obsolete_path" ]
  then
    rm -rf -- "$obsolete_path"
  fi
done

if [ -L "$DEST/stage_teslausb" ] || \
   { [ -e "$DEST/stage_teslausb" ] && [ ! -d "$DEST/stage_teslausb" ]; }
then
  stop "refusing to replace a non-directory or symbolic-link stage_teslausb"
fi
if [ -d "$DEST/stage_teslausb" ]
then
  rm -rf -- "$DEST/stage_teslausb"
fi
mv -- "$STAGE_NEXT" "$DEST/stage_teslausb"
mv -Tf -- "$WORK_DIR/config" "$DEST/config"

printf 'Build config prepared from TeslaUSB %s (%s) and pi-gen %s.\n' \
  "$SOURCE_VERSION" "$SOURCE_COMMIT" "$PI_GEN_COMMIT"
printf '%s\n' 'Now use "./build.sh" or "./build-docker.sh" to build the TeslaUSB image.'
