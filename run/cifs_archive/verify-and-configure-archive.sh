#!/bin/bash -eu

VERS_OPT=
SEC_OPT=
TMP_CREDENTIALS_FILE=

function cleanup_credentials () {
  if [ -n "$TMP_CREDENTIALS_FILE" ]
  then
    rm -f -- "$TMP_CREDENTIALS_FILE"
    TMP_CREDENTIALS_FILE=
  fi
}

trap cleanup_credentials EXIT

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
  local output='' character
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
   ! archive_field_is_single_line "$SHARE_USER" ||
   ! archive_field_is_single_line "$SHARE_PASSWORD" ||
   ! archive_field_is_single_line "${SHARE_DOMAIN:-}" ||
   [[ "$ARCHIVE_SERVER" == -* ]]
then
  log_progress "STOP: unsafe archive server, share, or credentials value"
  exit 1
fi

case "${CIFS_VERSION:-}" in
  ''|default|1.0|2.0|2.1|3.0|3.02|3.1.1) ;;
  *)
    log_progress "STOP: unsupported CIFS_VERSION"
    exit 1
    ;;
esac
case "${CIFS_SEC:-}" in
  ''|none|krb5|krb5i|ntlm|ntlmi|ntlmv2|ntlmv2i|ntlmssp|ntlmsspi) ;;
  *)
    log_progress "STOP: unsupported CIFS_SEC"
    exit 1
    ;;
esac

function check_archive_server_reachable () {
  log_progress "Verifying that the archive server $ARCHIVE_SERVER is reachable..."
  local serverunreachable=false
  local default_interface
  default_interface=$(route | grep "^default" | awk '{print $NF}')
  hping3 -c 1 -S -p 445 "$ARCHIVE_SERVER" 1>/dev/null 2>&1 ||
    hping3 -c 1 -S -p 445 -I "$default_interface" "$ARCHIVE_SERVER" 1>/dev/null 2>&1 ||
    serverunreachable=true

  if [ "$serverunreachable" = true ]
  then
    log_progress "STOP: The archive server $ARCHIVE_SERVER is unreachable. Try specifying its IP address instead."
    exit 1
  fi

  log_progress "The archive server is reachable."
}

function write_archive_configs_to {
  local destination="$1"
  local temporary
  temporary=$(mktemp "${destination}.tmp.XXXXXX")
  chmod 0600 "$temporary"

  if ! (
    printf 'username=%s\n' "$SHARE_USER"
    printf 'password=%s\n' "$SHARE_PASSWORD"
    if [ -n "${SHARE_DOMAIN+x}" ]
    then
      printf 'domain=%s\n' "$SHARE_DOMAIN"
    fi
  ) > "$temporary"
  then
    rm -f -- "$temporary"
    return 1
  fi

  if ! mv -f -- "$temporary" "$destination"
  then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 0600 "$destination"
}

function check_archive_mountable () {
  local test_mount_location="/tmp/archivetestmount"

  log_progress "Verifying that the archive share is mountable..."

  if [ ! -e "$test_mount_location" ]
  then
    mkdir "$test_mount_location"
  fi

  TMP_CREDENTIALS_FILE=$(mktemp /tmp/teslaCamArchiveCredentials.XXXXXX)
  write_archive_configs_to "$TMP_CREDENTIALS_FILE"

  local mounted=false
  local try_versions="${CIFS_VERSION:-default 3.1.1 3.0 2.1 2.0 @@}"
  local try_secs="${CIFS_SEC:-@@ ntlmssp ntlmv2 ntlm}"
  local -a mount_command=()
  local commandline=

  echo "Trying all combinations of vers=($try_versions) and sec=($try_secs)"
  for vers in $try_versions
  do
    for sec in $try_secs
    do
      versopt=""
      secopt=""
      if [ "$vers" != "@@" ]
      then
        versopt="vers=$vers"
      fi
      if [ "$sec" != "@@" ]
      then
        secopt="sec=$sec"
      fi
      local mount_options="$3,credentials=${TMP_CREDENTIALS_FILE},iocharset=utf8,file_mode=0777,dir_mode=0777"
      if [ -n "$versopt" ]
      then
        mount_options+=",$versopt"
      fi
      if [ -n "$secopt" ]
      then
        mount_options+=",$secopt"
      fi
      mount_command=(mount -t cifs "//$1/$2" "$test_mount_location" -o "$mount_options")
      printf -v commandline '%q ' "${mount_command[@]}"
      log_progress "Trying mount command-line:"
      log_progress "$commandline"
      if "${mount_command[@]}"
      then
        mounted=true
        break 2
      fi
    done
  done
  if [ "$mounted" = false ]
  then
    log_progress "STOP: no working combination of vers and sec mount options worked"
    exit 1
  else
    log_progress "The archive share is mountable using: $commandline"
    if [ "$3" = "rw" ]
    then
       if ! touch "$test_mount_location/testfile"
       then
         log_progress "STOP: archive share is not writeable. Check permissions."
         umount "$test_mount_location"
         exit 1
       fi
       rm "$test_mount_location/testfile"
    fi

    # the music archive must be mountable with the same mount options
    # so fix the options now
    export CIFS_VERSION=$vers
    export CIFS_SEC=$sec
    VERS_OPT=$versopt
    SEC_OPT=$secopt
  fi

  umount "$test_mount_location"
  cleanup_credentials
}

function install_required_packages () {
  log_progress "Installing/updating required packages if needed"
  DEBIAN_FRONTEND=noninteractive apt-get -y install hping3 cifs-utils
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
  check_archive_mountable "$ARCHIVE_SERVER" "$SHARE_NAME" rw
fi

if [ -n "${MUSIC_SHARE_NAME:+x}" ]
then
  if [ "$MUSIC_SIZE" = "0" ]
  then
    log_progress "STOP: MUSIC_SHARE_NAME specified but no music drive size specified"
    exit 1
  fi
  check_archive_mountable "$ARCHIVE_SERVER" "$MUSIC_SHARE_NAME" ro
fi

function configure_archive () {
  log_progress "Configuring the archive..."

  local archive_path="/mnt/archive"
  local music_archive_path="/mnt/musicarchive"

  if [ ! -e "$archive_path" ] && [ -e /backingfiles/cam_disk.bin ]
  then
    mkdir "$archive_path"
  fi

  local credentials_file_path="/root/.teslaCamArchiveCredentials"
  write_archive_configs_to "$credentials_file_path"

  sed -i "/^.*\.teslaCamArchiveCredentials.*$/ d" /etc/fstab


  if [ -e /backingfiles/cam_disk.bin ]
  then
    local archive_source
    archive_source=$(fstab_escape "//$ARCHIVE_SERVER/$SHARE_NAME")
    printf '%s %s cifs rw,noauto,credentials=%s,iocharset=utf8,file_mode=0777,dir_mode=0777,%s,%s 0 0\n' \
      "$archive_source" "$archive_path" "$credentials_file_path" \
      "$VERS_OPT" "$SEC_OPT" >> /etc/fstab
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
    music_archive_source=$(fstab_escape "//$ARCHIVE_SERVER/$MUSIC_SHARE_NAME")
    printf '%s %s cifs ro,noauto,credentials=%s,iocharset=utf8,file_mode=0777,dir_mode=0777,%s,%s 0 0\n' \
      "$music_archive_source" "$music_archive_path" "$credentials_file_path" \
      "$VERS_OPT" "$SEC_OPT" >> /etc/fstab
  elif [ -d "$music_archive_path" ]
  then
    rmdir "$music_archive_path" || log_progress "failed to remove $music_archive_path"
  fi
  log_progress "Configured the archive."
}

configure_archive
