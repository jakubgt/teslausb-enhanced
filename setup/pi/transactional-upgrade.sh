#!/bin/bash

# Transactional application release manager for TeslaUSB.
#
# This deliberately manages application files copied into /root/bin only. OS
# packages, boot firmware, disk images and administrator configuration are not
# transactionally modified here. A major Raspberry Pi OS migration must be
# performed by flashing a new image, never by this script.

set -euo pipefail

STATE_DIR=${TESLAUSB_RELEASE_STATE_DIR:-/mutable/teslausb/application-releases}
LIVE_BIN=${TESLAUSB_RELEASE_LIVE_BIN:-/root/bin}
OS_RELEASE_FILE=${TESLAUSB_OS_RELEASE_FILE:-/etc/os-release}
MODEL_FILE=${TESLAUSB_MODEL_FILE:-/sys/firmware/devicetree/base/model}
SETUP_FINISHED_MARKER=${TESLAUSB_SETUP_FINISHED_MARKER:-/teslausb/TESLAUSB_SETUP_FINISHED}
SYSTEMCTL=${TESLAUSB_SYSTEMCTL:-systemctl}
MIN_FREE_KIB=${TESLAUSB_UPGRADE_MIN_FREE_KIB:-65536}
ALLOWED_OS_MAJORS=${TESLAUSB_ALLOWED_OS_MAJORS:-13}
ALLOWED_ARCHITECTURES=${TESLAUSB_ALLOWED_ARCHITECTURES:-aarch64 arm64}
REQUIRED_SERVICES=${TESLAUSB_REQUIRED_SERVICES:-teslausb.service}
OPTIONAL_SERVICES=${TESLAUSB_OPTIONAL_SERVICES:-nginx.service autofs.service smbd.service}
HEALTH_RETRIES=${TESLAUSB_HEALTH_RETRIES:-10}
SERVICE_STABILITY_SECONDS=${TESLAUSB_SERVICE_STABILITY_SECONDS:-7}
HEALTH_SLEEP=${TESLAUSB_HEALTH_SLEEP:-sleep}

RELEASES_DIR="$STATE_DIR/releases"
STAGING_DIR="$STATE_DIR/staging"
CURRENT_LINK="$STATE_DIR/current"
PREVIOUS_LINK="$STATE_DIR/previous"
LAST_GOOD_LINK="$STATE_DIR/last-known-good"
PENDING_ACTIVATION="$STATE_DIR/pending-activation"

ACTIVATION_TRAP_ARMED=false

function log {
  printf '%s\n' "$*" >&2
}

function stop {
  log "STOP: $*"
  return 1
}

function require_root {
  if [ "$EUID" -ne 0 ] && [ "${TESLAUSB_UPGRADE_ALLOW_NON_ROOT:-false}" != true ]
  then
    stop 'run sudo -i before managing a TeslaUSB release'
  fi
}

function require_command {
  command -v "$1" > /dev/null 2>&1 || stop "required command is unavailable: $1"
}

function value_in_list {
  local needle="$1"
  local values="$2"
  case " $values " in
    *" $needle "*) return 0 ;;
    *) return 1 ;;
  esac
}

function os_release_value {
  local key="$1"
  awk -F= -v wanted="$key" '
    $1 == wanted {
      value = substr($0, index($0, "=") + 1)
      gsub(/^\047|\047$/, "", value)
      gsub(/^\042|\042$/, "", value)
      print value
      exit
    }
  ' "$OS_RELEASE_FILE"
}

function current_architecture {
  if [ -n "${TESLAUSB_UPGRADE_ARCHITECTURE:-}" ]
  then
    printf '%s\n' "$TESLAUSB_UPGRADE_ARCHITECTURE"
  else
    uname -m
  fi
}

function current_model {
  if [ -f "$MODEL_FILE" ]
  then
    tr -d '\000' < "$MODEL_FILE"
  else
    printf '%s\n' unknown
  fi
}

function validate_positive_integer {
  case "$2" in
    ''|*[!0-9]*) stop "$1 must be a non-negative integer" ;;
  esac
}

function initialize_state {
  if [ -L "$STATE_DIR" ]
  then
    stop "$STATE_DIR must not be a symbolic link"
  fi
  install -d -m 0700 -- "$STATE_DIR" "$RELEASES_DIR" "$STAGING_DIR"
}

function acquire_lock {
  exec 9> "$STATE_DIR/upgrade.lock"
  flock -x 9
}

function preflight {
  local architecture
  local available_kib
  local command_name
  local model
  local os_id
  local os_major

  require_root
  for command_name in awk df flock install ln mv readlink sha256sum sort sync
  do
    require_command "$command_name"
  done
  require_command "$HEALTH_SLEEP"
  [ -f "$OS_RELEASE_FILE" ] || stop "$OS_RELEASE_FILE is unavailable"
  [ -e "$SETUP_FINISHED_MARKER" ] || \
    stop 'the previous TeslaUSB setup has not completed'
  validate_positive_integer TESLAUSB_UPGRADE_MIN_FREE_KIB "$MIN_FREE_KIB"
  validate_positive_integer TESLAUSB_HEALTH_RETRIES "$HEALTH_RETRIES"
  validate_positive_integer TESLAUSB_SERVICE_STABILITY_SECONDS \
    "$SERVICE_STABILITY_SECONDS"

  # A killed activation deliberately leaves a durable journal behind. Recover
  # it before doing any more compatibility checks or staging another release.
  initialize_state
  acquire_lock
  recover_pending_activation true

  os_major=$(os_release_value VERSION_ID)
  os_id=$(os_release_value ID)
  case "$os_major" in
    12)
      stop 'Raspberry Pi OS Bookworm cannot be converted to Trixie in place. Flash a clean current Trixie image, restore the TeslaUSB configuration, and reconnect the existing archive instead.'
      ;;
  esac
  value_in_list "$os_major" "$ALLOWED_OS_MAJORS" || \
    stop "Raspberry Pi OS major $os_major is unsupported by this release (expected: $ALLOWED_OS_MAJORS)"
  case "$os_id" in
    raspbian|debian) ;;
    *) stop "unsupported operating system ID: ${os_id:-unknown}" ;;
  esac

  architecture=$(current_architecture)
  value_in_list "$architecture" "$ALLOWED_ARCHITECTURES" || \
    stop "architecture $architecture is unsupported (expected: $ALLOWED_ARCHITECTURES)"

  model=$(current_model)
  if [ "$model" != unknown ] && [[ "$model" != *'Raspberry Pi'* ]]
  then
    stop "unsupported hardware: $model"
  fi
  if [ "${TESLAUSB_REQUIRE_PI_ZERO_2_W:-false}" = true ] && \
     [[ "$model" != *'Raspberry Pi Zero 2 W'* ]]
  then
    stop "this image is restricted to Raspberry Pi Zero 2 W hardware (detected: $model)"
  fi

  available_kib=$(df -Pk "$STATE_DIR" | awk 'NR == 2 { print $4 }')
  case "$available_kib" in
    ''|*[!0-9]*) stop "could not determine free space below $STATE_DIR" ;;
  esac
  if [ "$available_kib" -lt "$MIN_FREE_KIB" ]
  then
    stop "at least $MIN_FREE_KIB KiB of free space is required below $STATE_DIR ($available_kib KiB available)"
  fi

  log "Preflight passed: Raspberry Pi OS $os_major, $architecture, $model"
}

function validate_version {
  if ! [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]]
  then
    stop "unsafe or unsupported release version: $1"
  fi
}

function source_tree_digest {
  local source_root="$1"
  local source_file
  local relative_path
  local temporary_manifest="$2"

  : > "$temporary_manifest"
  while IFS= read -r -d '' source_file
  do
    relative_path=${source_file#"$source_root"/}
    printf '%s  %s\n' "$(sha256sum "$source_file" | awk '{print $1}')" "$relative_path" \
      >> "$temporary_manifest"
  done < <(find "$source_root" -path "$source_root/.git" -prune -o \
                    -type f -print0 | LC_ALL=C sort -z)
  sha256sum "$temporary_manifest" | awk '{print $1}'
}

function read_source_version {
  local source_root="$1"
  local version
  if [ -n "${TESLAUSB_RELEASE_VERSION:-}" ]
  then
    version="$TESLAUSB_RELEASE_VERSION"
  elif [ -f "$source_root/VERSION" ]
  then
    IFS= read -r version < "$source_root/VERSION"
  else
    version=development
  fi
  validate_version "$version"
  printf '%s\n' "$version"
}

function validate_candidate {
  local candidate
  local staging_root
  [ -n "${1:-}" ] || stop 'a staging directory is required'
  if [ ! -d "$1" ] || [ -L "$1" ]
  then
    stop 'the staging directory must be a real directory'
    return 1
  fi
  candidate=$(readlink -f -- "$1")
  staging_root=$(readlink -f -- "$STAGING_DIR")
  case "$candidate" in
    "$staging_root"/upgrade.*|"$staging_root"/bootstrap.*) ;;
    *) stop "staging path is outside the private release area: $candidate" ;;
  esac
  printf '%s\n' "$candidate"
}

function property_value {
  local property_file="$1"
  local key="$2"
  awk -F= -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' \
    "$property_file"
}

function write_properties {
  local destination="$1"
  local version="$2"
  local os_major="$3"
  local architecture="$4"
  local source_digest="$5"
  {
    printf 'format=1\n'
    printf 'version=%s\n' "$version"
    printf 'os_major=%s\n' "$os_major"
    printf 'architecture=%s\n' "$architecture"
    printf 'source_sha256=%s\n' "$source_digest"
  } > "$destination/release.properties"
  chmod 0600 "$destination/release.properties"
}

function prepare_release {
  local architecture
  local candidate
  local digest_file
  local os_major
  local source_digest
  local source_root
  local version

  [ -n "${1:-}" ] || stop 'a source tree is required'
  if [ ! -d "$1" ] || [ -L "$1" ]
  then
    stop 'the source tree must be a real directory'
    return 1
  fi
  source_root=$(readlink -f -- "$1")
  preflight
  acquire_lock
  candidate=$(mktemp -d "$STAGING_DIR/upgrade.XXXXXXXX")
  install -d -m 0700 "$candidate/root-bin"
  digest_file="$candidate/source.manifest.sha256"
  source_digest=$(source_tree_digest "$source_root" "$digest_file")
  version=$(read_source_version "$source_root")
  os_major=$(os_release_value VERSION_ID)
  architecture=$(current_architecture)
  write_properties "$candidate" "$version" "$os_major" "$architecture" "$source_digest"
  chmod 0600 "$digest_file"
  printf '%s\n' "$candidate"
}

function validate_destination_name {
  if ! [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]]
  then
    stop "unsafe runtime file name: $1"
  fi
}

function stage_file {
  local candidate
  local destination_name="$3"
  local destination_path
  local destination_sum
  local mode=${4:-0755}
  local source_path="$2"
  local source_sum
  local temporary_path

  initialize_state
  acquire_lock
  candidate=$(validate_candidate "$1")
  validate_destination_name "$destination_name"
  if [ ! -f "$source_path" ] || [ -L "$source_path" ]
  then
    stop "release input must be a regular file, not a symbolic link: $source_path"
    return 1
  fi
  case "$mode" in
    0[0-7][0-7][0-7]) ;;
    *) stop "invalid install mode: $mode" ;;
  esac

  destination_path="$candidate/root-bin/$destination_name"
  temporary_path=$(mktemp "$candidate/root-bin/.${destination_name}.XXXXXXXX")
  install -m "$mode" -- "$source_path" "$temporary_path"
  source_sum=$(sha256sum "$source_path" | awk '{print $1}')
  destination_sum=$(sha256sum "$temporary_path" | awk '{print $1}')
  if [ "$source_sum" != "$destination_sum" ]
  then
    unlink "$temporary_path"
    stop "checksum mismatch while staging $destination_name"
  fi
  mv -Tf -- "$temporary_path" "$destination_path"
  log "Staged $destination_name ($destination_sum)"
}

function generate_file_manifest {
  local release_dir="$1"
  local file_name
  local temporary_manifest="$release_dir/manifest.sha256.new"
  : > "$temporary_manifest"
  while IFS= read -r file_name
  do
    [ -n "$file_name" ] || continue
    if [ ! -f "$release_dir/root-bin/$file_name" ] || \
       [ -L "$release_dir/root-bin/$file_name" ]
    then
      stop "invalid release payload: root-bin/$file_name"
    fi
    printf '%s  root-bin/%s\n' \
      "$(sha256sum "$release_dir/root-bin/$file_name" | awk '{print $1}')" \
      "$file_name" >> "$temporary_manifest"
  done < <(find "$release_dir/root-bin" -mindepth 1 -maxdepth 1 -type f \
                 ! -name '.*' -printf '%f\n' | LC_ALL=C sort)
  mv -Tf -- "$temporary_manifest" "$release_dir/manifest.sha256"
  chmod 0600 "$release_dir/manifest.sha256"
}

function validate_release_metadata {
  local actual_source_digest
  local architecture
  local format
  local os_major
  local properties="$1/release.properties"
  local source_digest
  local version

  if [ ! -f "$properties" ] || [ -L "$properties" ]
  then
    stop "release metadata is missing below $1"
    return 1
  fi
  format=$(property_value "$properties" format)
  version=$(property_value "$properties" version)
  os_major=$(property_value "$properties" os_major)
  architecture=$(property_value "$properties" architecture)
  source_digest=$(property_value "$properties" source_sha256)
  if [ "$format" != 1 ]
  then
    stop "unsupported release manifest format: ${format:-missing}"
    return 1
  fi
  validate_version "$version" || return 1
  case "$os_major" in
    ''|*[!0-9]*) stop 'release OS major is invalid'; return 1 ;;
  esac
  if ! value_in_list "$architecture" "$ALLOWED_ARCHITECTURES"
  then
    stop "release architecture is unsupported: $architecture"
    return 1
  fi
  if ! [[ "$source_digest" =~ ^[0-9a-f]{64}$ ]]
  then
    stop 'release source checksum is invalid'
    return 1
  fi
  if [ ! -f "$1/source.manifest.sha256" ] || [ -L "$1/source.manifest.sha256" ]
  then
    stop 'release source manifest is missing or unsafe'
    return 1
  fi
  actual_source_digest=$(sha256sum "$1/source.manifest.sha256" | awk '{print $1}')
  if [ "$actual_source_digest" != "$source_digest" ]
  then
    stop 'release source manifest checksum verification failed'
    return 1
  fi
}

function verify_release {
  local release_dir="$1"
  local manifest="$release_dir/manifest.sha256"
  if [ ! -d "$release_dir" ] || [ -L "$release_dir" ]
  then
    stop "release directory is unavailable: $release_dir"
    return 1
  fi
  validate_release_metadata "$release_dir" || return 1
  if [ ! -f "$manifest" ] || [ -L "$manifest" ]
  then
    stop "release checksum manifest is unavailable below $release_dir"
    return 1
  fi
  if [ -s "$manifest" ] && ! (cd "$release_dir" && sha256sum -c manifest.sha256 > /dev/null)
  then
    stop "release checksum verification failed: $release_dir"
    return 1
  fi
}

function normalized_architecture {
  case "$1" in
    arm64|aarch64) printf '%s\n' arm64 ;;
    *) printf '%s\n' "$1" ;;
  esac
}

function verify_release_compatibility {
  local release_architecture
  local release_os_major
  release_os_major=$(property_value "$1/release.properties" os_major)
  release_architecture=$(property_value "$1/release.properties" architecture)
  if [ "$release_os_major" != "$(os_release_value VERSION_ID)" ]
  then
    stop "release $1 targets Raspberry Pi OS $release_os_major, not the installed OS"
    return 1
  fi
  if [ "$(normalized_architecture "$release_architecture")" != \
       "$(normalized_architecture "$(current_architecture)")" ]
  then
    stop "release $1 targets architecture $release_architecture, not the running kernel"
    return 1
  fi
}

function release_digest {
  local release_dir="$1"
  { cat "$release_dir/release.properties"; cat "$release_dir/manifest.sha256"; } | \
    sha256sum | awk '{print $1}'
}

function discard_staging_directory {
  local candidate
  candidate=$(validate_candidate "$1")
  find "$candidate" -depth -mindepth 1 -delete
  rmdir -- "$candidate"
}

function commit_release_directory {
  local candidate="$1"
  local digest
  local release_dir
  generate_file_manifest "$candidate"
  verify_release "$candidate"
  digest=$(release_digest "$candidate")
  release_dir="$RELEASES_DIR/$digest"
  if [ -e "$release_dir" ]
  then
    verify_release "$release_dir"
    if ! cmp -s "$candidate/release.properties" "$release_dir/release.properties" || \
       ! cmp -s "$candidate/manifest.sha256" "$release_dir/manifest.sha256"
    then
      stop "content address collision at $release_dir"
    fi
    discard_staging_directory "$candidate"
  else
    mv -- "$candidate" "$release_dir"
    chmod -R go-w -- "$release_dir"
    if [ "$EUID" -eq 0 ]
    then
      chown -R root:root -- "$release_dir"
    fi
    durable_sync "$release_dir"
    durable_sync "$RELEASES_DIR"
  fi
  printf '%s\n' "$release_dir"
}

function durable_sync {
  # coreutils sync -f issues syncfs(2) for the filesystem containing PATH. The
  # plain sync fallback keeps recovery correct on older installations whose
  # sync implementation does not yet expose -f.
  if ! sync -f -- "$1" 2> /dev/null
  then
    sync
  fi
}

function atomic_link {
  local link_path="$2"
  local target="$1"
  local temporary_link="${link_path}.new.$$"
  if [ -e "$temporary_link" ] || [ -L "$temporary_link" ]
  then
    unlink "$temporary_link"
  fi
  ln -s -- "$target" "$temporary_link"
  mv -Tf -- "$temporary_link" "$link_path"
  durable_sync "$(dirname -- "$link_path")"
}

function resolved_link {
  if [ -L "$1" ]
  then
    readlink -f -- "$1"
  fi
}

function release_identifier {
  local release_dir
  local release_id
  local releases_root

  release_dir=$(readlink -f -- "$1") || {
    stop "release path cannot be resolved: $1"
    return 1
  }
  releases_root=$(readlink -f -- "$RELEASES_DIR")
  release_id=$(basename -- "$release_dir")
  if [ "$(dirname -- "$release_dir")" != "$releases_root" ] || \
     ! [[ "$release_id" =~ ^[0-9a-f]{64}$ ]]
  then
    stop "release path is outside the content-addressed release area: $release_dir"
    return 1
  fi
  printf '%s\n' "$release_id"
}

function release_path_from_identifier {
  local release_id="$1"
  local release_path
  if ! [[ "$release_id" =~ ^[0-9a-f]{64}$ ]]
  then
    stop "pending activation contains an invalid release identifier"
    return 1
  fi
  release_path="$RELEASES_DIR/$release_id"
  if [ ! -d "$release_path" ] || [ -L "$release_path" ]
  then
    stop "pending activation release is unavailable: $release_path"
    return 1
  fi
  printf '%s\n' "$release_path"
}

function write_pending_activation {
  local new_id
  local old_id
  local temporary_journal

  old_id=$(release_identifier "$1") || return 1
  new_id=$(release_identifier "$2") || return 1
  temporary_journal=$(mktemp "$STATE_DIR/.pending-activation.XXXXXXXX")
  {
    printf 'format=1\n'
    printf 'old_release=%s\n' "$old_id"
    printf 'new_release=%s\n' "$new_id"
  } > "$temporary_journal"
  chmod 0600 "$temporary_journal"
  if [ "$EUID" -eq 0 ]
  then
    chown root:root -- "$temporary_journal"
  fi
  durable_sync "$temporary_journal"
  mv -Tf -- "$temporary_journal" "$PENDING_ACTIVATION"
  durable_sync "$STATE_DIR"
}

function clear_pending_activation {
  if [ -e "$PENDING_ACTIVATION" ] || [ -L "$PENDING_ACTIVATION" ]
  then
    unlink -- "$PENDING_ACTIVATION"
    durable_sync "$STATE_DIR"
  fi
}

function read_pending_activation {
  local format
  local new_id
  local old_id

  if [ ! -e "$PENDING_ACTIVATION" ] && [ ! -L "$PENDING_ACTIVATION" ]
  then
    return 1
  fi
  if [ ! -f "$PENDING_ACTIVATION" ] || [ -L "$PENDING_ACTIVATION" ]
  then
    stop "pending activation journal is not a safe regular file: $PENDING_ACTIVATION"
    return 2
  fi
  format=$(property_value "$PENDING_ACTIVATION" format)
  old_id=$(property_value "$PENDING_ACTIVATION" old_release)
  new_id=$(property_value "$PENDING_ACTIVATION" new_release)
  if [ "$format" != 1 ]
  then
    stop "pending activation journal has unsupported format: ${format:-missing}"
    return 2
  fi
  release_path_from_identifier "$old_id" || return 2
  release_path_from_identifier "$new_id" || return 2
}

function recover_pending_activation {
  local current_release
  local new_release
  local old_release
  local -a pending_releases=()
  local restart_services="${1:-false}"

  if [ ! -e "$PENDING_ACTIVATION" ] && [ ! -L "$PENDING_ACTIVATION" ]
  then
    return 0
  fi
  mapfile -t pending_releases < <(read_pending_activation)
  old_release=${pending_releases[0]:-}
  new_release=${pending_releases[1]:-}
  if [ -z "$old_release" ] || [ -z "$new_release" ]
  then
    stop 'pending activation journal is incomplete'
    return 1
  fi
  verify_release "$old_release" || return 1
  current_release=$(resolved_link "$CURRENT_LINK")
  case "$current_release" in
    ''|"$old_release"|"$new_release") ;;
    *)
      stop "pending activation conflicts with active release: $current_release"
      return 1
      ;;
  esac

  atomic_link "$old_release" "$CURRENT_LINK"
  reconcile_live_links "$old_release"
  atomic_link "$old_release" "$PREVIOUS_LINK"
  atomic_link "$old_release" "$LAST_GOOD_LINK"
  clear_pending_activation
  if [ "$restart_services" = true ]
  then
    restart_old_services_best_effort
  fi
  log "Recovered interrupted activation; restored $old_release"
}

function activation_exit_handler {
  local exit_status="$1"
  trap - EXIT HUP INT TERM
  if [ "$ACTIVATION_TRAP_ARMED" = true ]
  then
    log 'Activation was interrupted; restoring the journaled known-good release.'
    if ! recover_pending_activation true
    then
      log "STOP: automatic recovery failed; $PENDING_ACTIVATION was retained for boot recovery"
    fi
  fi
  exit "$exit_status"
}

function arm_activation_trap {
  ACTIVATION_TRAP_ARMED=true
  trap 'activation_exit_handler $?' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

function disarm_activation_trap {
  ACTIVATION_TRAP_ARMED=false
  trap - EXIT HUP INT TERM
}

function bootstrap_live_release {
  local bootstrap
  local file_name
  local live_path
  local source_digest
  local version

  bootstrap=$(mktemp -d "$STAGING_DIR/bootstrap.XXXXXXXX")
  install -d -m 0700 "$bootstrap/root-bin"
  while IFS= read -r file_name
  do
    [ -n "$file_name" ] || continue
    live_path="$LIVE_BIN/$file_name"
    if [ -f "$live_path" ]
    then
      install -m 0755 -- "$live_path" "$bootstrap/root-bin/$file_name"
    elif [ "$file_name" = teslausb-upgrade ]
    then
      # Keep the rollback/status control plane available even when migrating
      # an installation that predates transactional releases.
      install -m 0755 -- "$1/root-bin/$file_name" \
        "$bootstrap/root-bin/$file_name"
    fi
  done < <(awk '$2 ~ /^root-bin\// { sub(/^root-bin\//, "", $2); print $2 }' \
               "$1/manifest.sha256")
  version="bootstrap-$(date -u +%Y%m%d%H%M%S)"
  printf 'bootstrap of pre-transaction runtime files: %s\n' "$version" \
    > "$bootstrap/source.manifest.sha256"
  chmod 0600 "$bootstrap/source.manifest.sha256"
  source_digest=$(sha256sum "$bootstrap/source.manifest.sha256" | awk '{print $1}')
  write_properties "$bootstrap" "$version" "$(os_release_value VERSION_ID)" \
    "$(current_architecture)" "$source_digest"
  commit_release_directory "$bootstrap"
}

function ensure_live_links {
  local file_name
  local live_path
  local temporary_link
  install -d -m 0755 -- "$LIVE_BIN"
  while IFS= read -r file_name
  do
    [ -n "$file_name" ] || continue
    validate_destination_name "$file_name"
    live_path="$LIVE_BIN/$file_name"
    if [ -d "$live_path" ] && [ ! -L "$live_path" ]
    then
      stop "cannot replace runtime directory with a managed file: $live_path"
    fi
    if [ -L "$live_path" ] && \
       [ "$(readlink -- "$live_path")" = "$CURRENT_LINK/root-bin/$file_name" ]
    then
      continue
    fi
    temporary_link="$LIVE_BIN/.${file_name}.new.$$"
    if [ -e "$temporary_link" ] || [ -L "$temporary_link" ]
    then
      unlink "$temporary_link"
    fi
    ln -s -- "$CURRENT_LINK/root-bin/$file_name" "$temporary_link"
    mv -Tf -- "$temporary_link" "$live_path"
  done < <(awk '$2 ~ /^root-bin\// { sub(/^root-bin\//, "", $2); print $2 }' \
               "$1/manifest.sha256")
}

function live_link_targets_managed_release {
  local file_name="$2"
  local live_path="$1"
  local release_dir
  local release_id
  local releases_root
  local resolved_target

  [ -L "$live_path" ] || return 1
  resolved_target=$(readlink -f -- "$live_path") || return 1
  [ "$(basename -- "$resolved_target")" = "$file_name" ] || return 1
  [ "$(basename -- "$(dirname -- "$resolved_target")")" = root-bin ] || return 1
  release_dir=$(dirname -- "$(dirname -- "$resolved_target")")
  releases_root=$(readlink -f -- "$RELEASES_DIR") || return 1
  [ "$(dirname -- "$release_dir")" = "$releases_root" ] || return 1
  release_id=$(basename -- "$release_dir")
  [[ "$release_id" =~ ^[0-9a-f]{64}$ ]]
}

function remove_stale_managed_links {
  local file_name
  local live_path
  local removed=false
  local -A desired_entrypoints=()

  while IFS= read -r file_name
  do
    [ -n "$file_name" ] || continue
    validate_destination_name "$file_name"
    desired_entrypoints["$file_name"]=true
  done < <(awk '$2 ~ /^root-bin\// { sub(/^root-bin\//, "", $2); print $2 }' \
               "$1/manifest.sha256")

  while IFS= read -r -d '' live_path
  do
    file_name=${live_path##*/}
    # Managed destination names have a deliberately narrow grammar. Preserve
    # any operator-created link with a name outside it without inspecting its
    # array subscript or target.
    [[ "$file_name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] || continue
    [ -z "${desired_entrypoints[$file_name]+present}" ] || continue
    if live_link_targets_managed_release "$live_path" "$file_name"
    then
      unlink -- "$live_path"
      removed=true
      log "Removed stale managed runtime link $live_path"
    fi
  done < <(find "$LIVE_BIN" -mindepth 1 -maxdepth 1 -type l -print0)

  if [ "$removed" = true ]
  then
    durable_sync "$LIVE_BIN"
  fi
}

function reconcile_live_links {
  ensure_live_links "$1"
  remove_stale_managed_links "$1"
}

function check_shell_entrypoints {
  local first_line
  local runtime_file
  while IFS= read -r -d '' runtime_file
  do
    IFS= read -r first_line < "$runtime_file" || true
    case "$first_line" in
      '#!'*'/bash'*|'#!'*'/sh'*) bash -n "$runtime_file" || return 1 ;;
    esac
  done < <(find "$1/root-bin" -mindepth 1 -maxdepth 1 -type f -print0)
}

function check_live_entrypoints {
  local file_name
  local live_path
  while IFS= read -r file_name
  do
    [ -n "$file_name" ] || continue
    live_path="$LIVE_BIN/$file_name"
    if [ ! -L "$live_path" ] || \
       [ "$(readlink -- "$live_path")" != "$CURRENT_LINK/root-bin/$file_name" ] || \
       [ ! -x "$live_path" ] || \
       ! cmp -s "$live_path" "$1/root-bin/$file_name"
    then
      stop "active runtime entrypoint is missing or inconsistent: $live_path"
      return 1
    fi
  done < <(awk '$2 ~ /^root-bin\// { sub(/^root-bin\//, "", $2); print $2 }' \
               "$1/manifest.sha256")
}

function service_is_enabled {
  "$SYSTEMCTL" is-enabled --quiet "$1" > /dev/null 2>&1
}

function wait_for_service {
  local attempt=0
  local service="$1"
  while [ "$attempt" -lt "$HEALTH_RETRIES" ]
  do
    if "$SYSTEMCTL" is-active --quiet "$service" > /dev/null 2>&1
    then
      return 0
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -ge "$HEALTH_RETRIES" ] || "$HEALTH_SLEEP" 1
  done
  stop "service did not become healthy: $service"
}

function service_restart_count {
  local restart_count
  restart_count=$(
    "$SYSTEMCTL" show "$1" --property=NRestarts --value 2> /dev/null
  ) || {
    stop "could not read the restart count for required service: $1"
    return 1
  }
  case "$restart_count" in
    ''|*[!0-9]*)
      stop "required service returned an invalid restart count: $1"
      return 1
      ;;
  esac
  printf '%s\n' "$restart_count"
}

function require_stable_service {
  local elapsed=0
  local initial_restart_count
  local restart_count
  local service="$1"

  initial_restart_count=$(service_restart_count "$service") || return 1
  while [ "$elapsed" -lt "$SERVICE_STABILITY_SECONDS" ]
  do
    "$HEALTH_SLEEP" 1
    if ! "$SYSTEMCTL" is-active --quiet "$service" > /dev/null 2>&1
    then
      stop "required service stopped during its stability window: $service"
      return 1
    fi
    restart_count=$(service_restart_count "$service") || return 1
    if [ "$restart_count" != "$initial_restart_count" ]
    then
      stop "required service entered a restart loop during health checks: $service"
      return 1
    fi
    elapsed=$((elapsed + 1))
  done
}

function restart_enabled_service {
  local required="$1"
  local service="$2"
  if ! service_is_enabled "$service"
  then
    [ "$required" = false ] || stop "required service is not enabled: $service"
    return 0
  fi
  "$SYSTEMCTL" restart "$service" || return 1
  wait_for_service "$service" || return 1
  if [ "$required" = true ]
  then
    require_stable_service "$service" || return 1
  fi
}

function release_health_check {
  local release_dir="$1"
  local service
  local -a optional_services=()
  local -a required_services=()
  verify_release "$release_dir" || return 1
  verify_release_compatibility "$release_dir" || return 1
  check_shell_entrypoints "$release_dir" || return 1
  check_live_entrypoints "$release_dir" || return 1
  if [ "${TESLAUSB_SKIP_SERVICE_HEALTH:-false}" = true ]
  then
    return 0
  fi
  require_command "$SYSTEMCTL"
  read -r -a required_services <<< "$REQUIRED_SERVICES" || true
  read -r -a optional_services <<< "$OPTIONAL_SERVICES" || true
  for service in "${required_services[@]}"
  do
    restart_enabled_service true "$service" || return 1
  done
  for service in "${optional_services[@]}"
  do
    restart_enabled_service false "$service" || return 1
  done
}

function restart_old_services_best_effort {
  local service
  local -a services=()
  if [ "${TESLAUSB_SKIP_SERVICE_HEALTH:-false}" = true ]
  then
    return 0
  fi
  read -r -a services <<< "$REQUIRED_SERVICES $OPTIONAL_SERVICES" || true
  for service in "${services[@]}"
  do
    if service_is_enabled "$service"
    then
      "$SYSTEMCTL" restart "$service" > /dev/null 2>&1 || true
    fi
  done
}

function finalize_release {
  local bootstrap_release
  local candidate
  local new_release
  local old_release

  preflight
  acquire_lock
  candidate=$(validate_candidate "$1")
  generate_file_manifest "$candidate"
  verify_release "$candidate"
  verify_release_compatibility "$candidate"
  if [ ! -s "$candidate/manifest.sha256" ]
  then
    stop 'the candidate release contains no runtime files'
  fi
  new_release=$(commit_release_directory "$candidate")

  old_release=$(resolved_link "$CURRENT_LINK")
  if [ -z "$old_release" ]
  then
    bootstrap_release=$(bootstrap_live_release "$new_release")
    atomic_link "$bootstrap_release" "$CURRENT_LINK"
    atomic_link "$bootstrap_release" "$LAST_GOOD_LINK"
    old_release="$bootstrap_release"
  fi
  verify_release "$old_release"
  ensure_live_links "$new_release"
  atomic_link "$old_release" "$PREVIOUS_LINK"
  atomic_link "$old_release" "$LAST_GOOD_LINK"
  write_pending_activation "$old_release" "$new_release"
  arm_activation_trap
  atomic_link "$new_release" "$CURRENT_LINK"
  reconcile_live_links "$new_release"
  if [ "${TESLAUSB_UPGRADE_TEST_ABANDON_AFTER_SWITCH:-false}" = true ]
  then
    # Test-only failpoint used to model process loss without allowing the EXIT
    # trap to repair state. The durable journal must make the next boot safe.
    disarm_activation_trap
    exit 99
  fi

  if ! release_health_check "$new_release"
  then
    recover_pending_activation true
    disarm_activation_trap
    stop "new release failed health checks; atomically restored $old_release"
  fi
  atomic_link "$new_release" "$LAST_GOOD_LINK"
  clear_pending_activation
  disarm_activation_trap
  log "Activated and verified release $new_release"
  printf '%s\n' "$new_release"
}

function abort_release {
  local candidate
  initialize_state
  acquire_lock
  candidate=$(validate_candidate "$1")
  discard_staging_directory "$candidate"
  restart_old_services_best_effort
  log 'Discarded the incomplete candidate; the active application release was unchanged.'
}

function rollback_release {
  local current_release
  local rollback_release
  preflight
  acquire_lock
  current_release=$(resolved_link "$CURRENT_LINK")
  rollback_release=$(resolved_link "$PREVIOUS_LINK")
  if [ -z "$rollback_release" ] || [ "$rollback_release" = "$current_release" ]
  then
    rollback_release=$(resolved_link "$LAST_GOOD_LINK")
  fi
  [ -n "$current_release" ] || stop 'there is no active transactional release'
  [ -n "$rollback_release" ] || stop 'there is no last-known-good release to restore'
  [ "$rollback_release" != "$current_release" ] || stop 'the active release is already the only known-good release'
  verify_release "$rollback_release"
  write_pending_activation "$current_release" "$rollback_release"
  arm_activation_trap
  ensure_live_links "$rollback_release"
  atomic_link "$rollback_release" "$CURRENT_LINK"
  reconcile_live_links "$rollback_release"
  if ! release_health_check "$rollback_release"
  then
    recover_pending_activation true
    disarm_activation_trap
    stop 'rollback target failed health checks; restored the original active release'
  fi
  atomic_link "$current_release" "$PREVIOUS_LINK"
  atomic_link "$rollback_release" "$LAST_GOOD_LINK"
  clear_pending_activation
  disarm_activation_trap
  log "Rolled back to $rollback_release"
  printf '%s\n' "$rollback_release"
}

function show_status {
  local active
  local last_good
  local previous
  initialize_state
  acquire_lock
  active=$(resolved_link "$CURRENT_LINK")
  previous=$(resolved_link "$PREVIOUS_LINK")
  last_good=$(resolved_link "$LAST_GOOD_LINK")
  printf 'active=%s\n' "${active:-none}"
  printf 'previous=%s\n' "${previous:-none}"
  printf 'last_known_good=%s\n' "${last_good:-none}"
  if [ -e "$PENDING_ACTIVATION" ] || [ -L "$PENDING_ACTIVATION" ]
  then
    printf 'pending_activation=yes\n'
  else
    printf 'pending_activation=no\n'
  fi
  if [ -n "$active" ]
  then
    printf 'version=%s\n' "$(property_value "$active/release.properties" version)"
    verify_release "$active"
    printf 'checksum_status=verified\n'
  fi
}

function usage {
  cat <<'EOF'
Usage: transactional-upgrade.sh COMMAND [ARGUMENTS]

Commands:
  preflight                         Validate OS, hardware and free space
  recover                           Restore a journaled interrupted activation
  prepare SOURCE_TREE               Create a private candidate; print its path
  stage-file CANDIDATE FILE NAME    Checksum and stage one /root/bin entrypoint
  finalize CANDIDATE                Atomically activate, health-check or roll back
  abort CANDIDATE                   Discard an unactivated candidate
  rollback                          Activate and verify the previous good release
  verify RELEASE_DIR                Verify metadata and every payload checksum
  status                            Show active, previous and last-known-good state
EOF
}

require_root
command_name=${1:-}
case "$command_name" in
  preflight) preflight ;;
  recover) initialize_state; acquire_lock; recover_pending_activation false ;;
  prepare) shift; prepare_release "$@" ;;
  stage-file) shift; stage_file "$@" ;;
  finalize) shift; finalize_release "$@" ;;
  abort) shift; abort_release "$@" ;;
  rollback) rollback_release ;;
  verify) shift; verify_release "$@" ;;
  status) show_status ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
