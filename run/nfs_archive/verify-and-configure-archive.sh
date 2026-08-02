#!/bin/bash -eu

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "verify-and-configure-archive: $*"
    return
  fi
  echo "verify-and-configure-archive: $1"
}

function archive_field_is_single_line () {
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
}

function fstab_escape () {
  local input="$1"
  local output= character
  while [ -n "$input" ]
  do
    character=${input:0:1}
    input=${input:1}
    case "$character" in
      ' ') output+='\040' ;;
      $'\t') output+='\011' ;;
      "\\") output+='\134' ;;
      *) output+="$character" ;;
    esac
  done
  printf '%s' "$output"
}

if ! archive_field_is_single_line "$ARCHIVE_SERVER" ||
   ! archive_field_is_single_line "${SHARE_NAME:-}" ||
   ! archive_field_is_single_line "${MUSIC_SHARE_NAME:-}" ||
   [[ "$ARCHIVE_SERVER" == -* ]]
then
  log_progress "STOP: unsafe archive server or NFS share value"
  exit 1
fi

function check_archive_server_reachable () {
  log_progress "Verifying that the archive server $ARCHIVE_SERVER is reachable..."
  local serverunreachable=false
  local default_interface
  default_interface=$(route | grep "^default" | awk '{print $NF}')
  
  # Check NFS Port 2049
  hping3 -c 1 -S -p 2049 "$ARCHIVE_SERVER" 1>/dev/null 2>&1 ||
    hping3 -c 1 -S -p 2049 -I "$default_interface" "$ARCHIVE_SERVER" 1>/dev/null 2>&1 ||
    serverunreachable=true

  if [ "$serverunreachable" = true ]
  then
    log_progress "STOP: The archive server $ARCHIVE_SERVER is unreachable on port 2049. Try specifying its IP address instead."
    exit 1
  fi

  log_progress "The archive server is reachable."
}

function check_archive_mountable () {
  local test_mount_location="/tmp/archivetestmount"
  local share_path="$1"
  local mode="$2"

  log_progress "Verifying that the archive share is mountable..."

  if [ ! -e "$test_mount_location" ]
  then
    mkdir "$test_mount_location"
  fi

  local mounted=false
  
  # Forced vers=3 for wider NAS compatibility (Unifi, Synology, etc).
  # Keep every user value in its own array element; this must never use eval.
  local -a mount_command=(
    mount -t nfs "$ARCHIVE_SERVER:$share_path" "$test_mount_location"
    -o 'rw,noauto,nolock,proto=tcp,vers=3'
  )
  local commandline
  printf -v commandline '%q ' "${mount_command[@]}"
  
  log_progress "Trying NFS mount command-line:"
  log_progress "$commandline"
  
  if "${mount_command[@]}"
  then
    mounted=true
  fi

  if [ "$mounted" = false ]
  then
    log_progress "STOP: unable to mount archive share via NFS"
    exit 1
  else
    log_progress "The archive share is mountable."
    if [ "$mode" = "rw" ]
    then
       if ! touch "$test_mount_location/testfile"
       then
         log_progress "STOP: archive share is not writeable. Check permissions on NAS."
         umount "$test_mount_location"
         exit 1
       fi
       rm "$test_mount_location/testfile"
    fi
  fi

  umount "$test_mount_location"
}

function install_required_packages () {
  log_progress "Installing/updating required packages if needed"
  DEBIAN_FRONTEND=noninteractive apt-get -y install hping3 nfs-common
  if ! command -v nc > /dev/null
  then
    DEBIAN_FRONTEND=noninteractive apt-get -y install netcat || \
      DEBIAN_FRONTEND=noninteractive apt-get -y install netcat-openbsd
  fi
  log_progress "Done"
}

install_required_packages

check_archive_server_reachable

if [ -e /backingfiles/cam_disk.bin ]
then
  check_archive_mountable "$SHARE_NAME" rw
fi

if [ -n "${MUSIC_SHARE_NAME:+x}" ]
then
  if [ "$MUSIC_SIZE" = "0" ]
  then
    log_progress "STOP: MUSIC_SHARE_NAME specified but no music drive size specified"
    exit 1
  fi
  check_archive_mountable "$MUSIC_SHARE_NAME" ro
fi

function configure_archive () {
  log_progress "Configuring the archive..."

  local archive_path="/mnt/archive"
  local music_archive_path="/mnt/musicarchive"

  if [ ! -e "$archive_path" ] && [ -e /backingfiles/cam_disk.bin ]
  then
    mkdir "$archive_path"
  fi

  # Remove existing NFS entries to prevent duplicates
  sed -i "/^.* nfs .*$/ d" /etc/fstab

  if [ -e /backingfiles/cam_disk.bin ]
  then
    local archive_source
    archive_source=$(fstab_escape "$ARCHIVE_SERVER:$SHARE_NAME")
    printf '%s %s nfs rw,noauto,nolock,proto=tcp,vers=3 0 0\n' \
      "$archive_source" "$archive_path" >> /etc/fstab
  elif [ -d "$archive_path" ]
  then
    rmdir "$archive_path" || log_progress "failed to remove $archive_path"
  fi

  if [ -n "${MUSIC_SHARE_NAME:+x}" ]
  then
    if [ ! -e "$music_archive_path" ]
    then
      mkdir "$music_archive_path"
    fi
    local music_archive_source
    music_archive_source=$(fstab_escape "$ARCHIVE_SERVER:$MUSIC_SHARE_NAME")
    printf '%s %s nfs ro,noauto,nolock,proto=tcp,vers=3 0 0\n' \
      "$music_archive_source" "$music_archive_path" >> /etc/fstab
  elif [ -d "$music_archive_path" ]
  then
    rmdir "$music_archive_path" || log_progress "failed to remove $music_archive_path"
  fi
  log_progress "Configured the archive."
}

configure_archive
