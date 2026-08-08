#!/bin/bash

set -euo pipefail

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(dirname "$TEST_DIR")
readonly REPO_ROOT
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/teslausb-prepare-test.XXXXXX")
readonly TEST_TMP

cleanup() {
  case "$TEST_TMP" in
    "${TMPDIR:-/tmp}"/teslausb-prepare-test.*)
      rm -rf -- "$TEST_TMP"
      ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'prepare-image-test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -F -- "$expected" "$file" > /dev/null || \
    fail "$file does not contain: $expected"
}

stage_digest() {
  local stage="$1"
  local entry
  local entry_hash
  (
    cd "$stage"
    while IFS= read -r -d '' entry
    do
      entry_hash=-
      if [ -f "$entry" ]
      then
        entry_hash="$(sha256sum -- "$entry" | awk '{print $1}')"
      fi
      printf '%s %s %s\n' "$(stat -c '%F:%a:%Y' -- "$entry")" \
        "$entry_hash" "${entry#./}"
    done < <(find . -mindepth 1 -print0 | LC_ALL=C sort -z)
  ) | sha256sum | awk '{print $1}'
}

run_prepare() {
  local source_repo="$1"
  local pi_gen="$2"
  local pi_gen_commit="$3"
  (
    cd "$pi_gen"
    TESLAUSB_PI_GEN_COMMIT_OVERRIDE="$pi_gen_commit" \
      "$source_repo/pi-gen-sources/prepare.sh"
  )
}

source_repo="$TEST_TMP/teslausb"
pi_gen="$TEST_TMP/pi-gen"
mkdir -p "$source_repo/pi-gen-sources/00-teslausb-tweaks/files" \
  "$source_repo/run" "$source_repo/setup/pi" "$source_repo/teslausb-www"

cp "$REPO_ROOT/pi-gen-sources/prepare.sh" "$source_repo/pi-gen-sources/prepare.sh"
cp "$REPO_ROOT/pi-gen-sources/00-teslausb-tweaks/files/iso3166-country-codes.json" \
  "$source_repo/pi-gen-sources/00-teslausb-tweaks/files/iso3166-country-codes.json"
cp "$REPO_ROOT/LICENSE" "$source_repo/LICENSE"
chmod 0755 "$source_repo/pi-gen-sources/prepare.sh"
printf '9.9.9\n' > "$source_repo/VERSION"
printf '*.conf\n*.key\n' > "$source_repo/.gitignore"
printf '#!/bin/bash\nprintf "runtime\\n"\n' > "$source_repo/run/archiveloop"
printf '#!/bin/bash\nprintf "removed\\n"\n' > "$source_repo/run/removed-after-first"
printf '#!/bin/bash\nprintf "setup\\n"\n' > "$source_repo/setup/pi/setup-teslausb"
printf 'server { listen 80; }\n' > "$source_repo/teslausb-www/teslausb.nginx"
printf 'RELEASE=trixie\n' > "$source_repo/pi-gen-sources/pi-gen-config"
printf '#!/bin/bash\nprintf "image tweak\\n"\n' \
  > "$source_repo/pi-gen-sources/00-teslausb-tweaks/00-run.sh"
printf 'rsync\n' > "$source_repo/pi-gen-sources/00-teslausb-tweaks/00-packages"
printf '#!/bin/bash\nprintf "first boot\\n"\n' \
  > "$source_repo/pi-gen-sources/00-teslausb-tweaks/files/rc.local"
printf '#!/bin/bash\nprintf "loader\\n"\n' \
  > "$source_repo/pi-gen-sources/00-teslausb-tweaks/files/teslausb-config-loader.sh"
printf '#!/usr/bin/env python3\nprint("validator")\n' \
  > "$source_repo/pi-gen-sources/00-teslausb-tweaks/files/teslausb_config.py"
chmod 0755 "$source_repo/run/archiveloop" \
  "$source_repo/run/removed-after-first" \
  "$source_repo/setup/pi/setup-teslausb" \
  "$source_repo/pi-gen-sources/00-teslausb-tweaks/00-run.sh" \
  "$source_repo/pi-gen-sources/00-teslausb-tweaks/files/rc.local" \
  "$source_repo/pi-gen-sources/00-teslausb-tweaks/files/teslausb_config.py"

git -C "$source_repo" init -q -b release
git -C "$source_repo" config user.name 'TeslaUSB test'
git -C "$source_repo" config user.email 'teslausb-test@example.invalid'
git -C "$source_repo" add .
GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' \
GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
  git -C "$source_repo" commit -q -m 'fixture source'
source_commit=$(git -C "$source_repo" rev-parse HEAD)

# Neither ignored nor ordinary untracked files may enter an image bundle.
printf 'wifi_password=must-not-leak\n' > "$source_repo/run/private.conf"
printf 'api_key=must-not-leak\n' \
  > "$source_repo/pi-gen-sources/00-teslausb-tweaks/files/local-secret.key"
printf 'untracked data\n' \
  > "$source_repo/pi-gen-sources/00-teslausb-tweaks/files/untracked.txt"

mkdir -p "$pi_gen/stage2/EXPORT_NOOBS" "$pi_gen/stage2/EXPORT_IMAGE" \
  "$pi_gen/export-image/01-user-rename/00-packages"
printf '#!/bin/bash\nprintf "prerun\\n"\n' > "$pi_gen/stage2/prerun.sh"
printf 'old noobs\n' > "$pi_gen/stage2/EXPORT_NOOBS/old"
printf 'old image\n' > "$pi_gen/stage2/EXPORT_IMAGE/old"
printf 'old package\n' > "$pi_gen/export-image/01-user-rename/00-packages/old"
chmod 0755 "$pi_gen/stage2/prerun.sh"
git -C "$pi_gen" init -q -b arm64
git -C "$pi_gen" config user.name 'pi-gen test'
git -C "$pi_gen" config user.email 'pi-gen-test@example.invalid'
git -C "$pi_gen" add .
GIT_AUTHOR_DATE='2026-01-02T00:00:00Z' \
GIT_COMMITTER_DATE='2026-01-02T00:00:00Z' \
  git -C "$pi_gen" commit -q -m 'fixture pi-gen'
pi_gen_commit=$(git -C "$pi_gen" rev-parse HEAD)

pin_error="$TEST_TMP/pin-error"
if (
  cd "$pi_gen"
  "$source_repo/pi-gen-sources/prepare.sh"
) > "$pin_error" 2>&1
then
  fail 'prepare accepted an unpinned pi-gen commit'
fi
assert_contains "$pin_error" 'pi-gen commit mismatch'
assert_contains "$pin_error" 'TESLAUSB_PI_GEN_COMMIT_OVERRIDE'

override_error="$TEST_TMP/override-error"
if (
  cd "$pi_gen"
  TESLAUSB_PI_GEN_COMMIT_OVERRIDE=arm64 \
    "$source_repo/pi-gen-sources/prepare.sh"
) > "$override_error" 2>&1
then
  fail 'prepare accepted a floating or abbreviated pi-gen override'
fi
assert_contains "$override_error" \
  'must be one exact lowercase 40-character commit SHA'

run_prepare "$source_repo" "$pi_gen" "$pi_gen_commit" > /dev/null
stage="$pi_gen/stage_teslausb"
bundle="$stage/00-teslausb-tweaks/files/teslausb-source"
[ -f "$pi_gen/config" ] || fail 'pi-gen config was not prepared'
[ -f "$stage/EXPORT_IMAGE" ] || fail 'stage export marker is missing'
[ -x "$stage/prerun.sh" ] || fail 'stage prerun is missing or not executable'
[ ! -e "$pi_gen/stage2/EXPORT_NOOBS" ] || fail 'obsolete EXPORT_NOOBS remains'
[ ! -e "$pi_gen/stage2/EXPORT_IMAGE" ] || fail 'obsolete stage2 EXPORT_IMAGE remains'
[ ! -e "$pi_gen/export-image/01-user-rename/00-packages" ] || \
  fail 'obsolete export-image packages remain'
cmp -s "$source_repo/LICENSE" "$bundle/LICENSE" || fail 'MIT LICENSE is absent or changed'
[ -f "$bundle/run/archiveloop" ] || fail 'required runtime source is missing'
[ -f "$bundle/setup/pi/setup-teslausb" ] || fail 'required setup source is missing'
[ -f "$bundle/pi-gen-sources/pi-gen-config" ] || fail 'pi-gen config source is missing'
[ -f "$bundle/pi-gen-sources/00-teslausb-tweaks/files/iso3166-country-codes.json" ] || \
  fail 'canonical ISO country list is missing from bundled source'
[ ! -e "$bundle/run/private.conf" ] || fail 'ignored credential file entered bundle'
[ ! -e "$bundle/pi-gen-sources/00-teslausb-tweaks/files/local-secret.key" ] || \
  fail 'ignored tweak credential entered bundle'
[ ! -e "$bundle/pi-gen-sources/00-teslausb-tweaks/files/untracked.txt" ] || \
  fail 'untracked tweak file entered bundle'
if grep -R -F 'must-not-leak' "$stage" > /dev/null
then
  fail 'secret content entered prepared stage'
fi
assert_contains "$bundle/SOURCE-METADATA" "teslausb_source_commit=$source_commit"
assert_contains "$bundle/SOURCE-METADATA" "pi_gen_commit=$pi_gen_commit"
assert_contains "$bundle/SOURCE-METADATA" \
  'official_pi_gen_commit=ca8aeed0ae300c2a89f55ce9617d5f96a27e99e5'
(
  cd "$bundle"
  sha256sum -c SOURCE-MANIFEST.sha256 > /dev/null
) || fail 'bundled source manifest does not verify'
recorded_manifest_sum=$(awk -F= '$1 == "source_manifest_sha256" {print $2}' \
  "$bundle/SOURCE-METADATA")
actual_manifest_sum=$(sha256sum "$bundle/SOURCE-MANIFEST.sha256" | awk '{print $1}')
[ "$recorded_manifest_sum" = "$actual_manifest_sum" ] || \
  fail 'metadata does not identify the exact source manifest'

first_digest=$(stage_digest "$stage")
printf 'stale output\n' > "$stage/00-teslausb-tweaks/files/stale-from-prior-run"
run_prepare "$source_repo" "$pi_gen" "$pi_gen_commit" > /dev/null
[ ! -e "$stage/00-teslausb-tweaks/files/stale-from-prior-run" ] || \
  fail 'consecutive prepare retained a stale stage file'
second_digest=$(stage_digest "$stage")
[ "$first_digest" = "$second_digest" ] || \
  fail 'consecutive prepare runs from the same commits were not deterministic'

# A file deleted in a later source commit must disappear from the clean bundle.
git -C "$source_repo" rm -q run/removed-after-first
GIT_AUTHOR_DATE='2026-01-03T00:00:00Z' \
GIT_COMMITTER_DATE='2026-01-03T00:00:00Z' \
  git -C "$source_repo" commit -q -m 'remove obsolete runtime'
new_source_commit=$(git -C "$source_repo" rev-parse HEAD)
run_prepare "$source_repo" "$pi_gen" "$pi_gen_commit" > /dev/null
[ ! -e "$bundle/run/removed-after-first" ] || \
  fail 'bundle retained a file deleted from the source commit'
assert_contains "$bundle/SOURCE-METADATA" \
  "teslausb_source_commit=$new_source_commit"

printf 'dirty\n' >> "$source_repo/VERSION"
dirty_error="$TEST_TMP/dirty-error"
if run_prepare "$source_repo" "$pi_gen" "$pi_gen_commit" \
  > "$dirty_error" 2>&1
then
  fail 'prepare accepted modified tracked source'
fi
assert_contains "$dirty_error" 'tracked TeslaUSB inputs are modified'
git -C "$source_repo" checkout -q -- VERSION

source_archive="$TEST_TMP/source-archive"
mkdir -p "$source_archive"
git -C "$source_repo" archive --format=tar HEAD | tar -xf - -C "$source_archive"
archive_error="$TEST_TMP/archive-error"
if run_prepare "$source_archive" "$pi_gen" "$pi_gen_commit" \
  > "$archive_error" 2>&1
then
  fail 'prepare accepted a source archive without Git metadata'
fi
assert_contains "$archive_error" 'GitHub source archives are not sufficient'
assert_contains "$archive_error" 'git clone --branch <release-tag>'

printf 'prepare image reproducibility tests passed\n'
