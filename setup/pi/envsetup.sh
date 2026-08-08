#!/bin/bash -eu

if [ "${BASH_SOURCE[0]}" = "$0" ]
then
  echo "$0 must be sourced, not executed"
  exit 1
fi

if [ ! -L /teslausb ]
then
  mount / -o remount,rw
  if [ -e /teslausb ] && ! rmdir /teslausb
  then
    echo "STOP: /teslausb exists and is not an empty directory or symbolic link" >&2
    exit 1
  fi
  if [ -d /boot/firmware ] && findmnt --fstab /boot/firmware &> /dev/null
  then
    ln -s /boot/firmware /teslausb
  else
    ln -s /boot /teslausb
  fi
fi

function setup_config_message {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "$*"
  else
    printf '%s\n' "$*" >&2
  fi
}

function secure_setup_config_file {
  local setup_config="$1"
  local metadata
  local owner_id
  local group_id
  local mode

  if [ -L "$setup_config" ] || [ ! -f "$setup_config" ]
  then
    setup_config_message "STOP: $setup_config must be a regular file, not a symbolic link."
    return 1
  fi
  metadata="$(stat -c '%u:%g:%a' -- "$setup_config")" || {
    setup_config_message "STOP: unable to inspect $setup_config."
    return 1
  }
  IFS=: read -r owner_id group_id mode <<< "$metadata"
  if [ "$owner_id" != "0" ] || [ "$group_id" != "0" ]
  then
    setup_config_message "STOP: $setup_config must be owned by root:root."
    return 1
  fi
  if [ "$mode" != "600" ] && ! chmod 0600 -- "$setup_config"
  then
    setup_config_message "STOP: unable to set root-only (0600) permissions on $setup_config. Remount the root filesystem writable and retry."
    return 1
  fi
  mode="$(stat -c '%a' -- "$setup_config")" || return 1
  if [ "$mode" != "600" ]
  then
    setup_config_message "STOP: $setup_config must have mode 0600."
    return 1
  fi
}

function safesource {
  local setup_config="$1"
  local failure_output

  secure_setup_config_file "$setup_config" || exit 1
  # Validate in a subshell and keep diagnostics in memory. This avoids trusting
  # TMPDIR-like environment state before the root-owned config is loaded and
  # leaves no secret-bearing validation file behind after an interrupt.
  if failure_output="$( ( set -eu; source "$setup_config" ) 2>&1 )"
  then
    :
  else
    setup_config_message "Error in $setup_config:"
    setup_config_message "$failure_output"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$setup_config"
}

TESLAUSB_CONFIG_LOADER_LOADED=false
for teslausb_loader_candidate in \
  "$(dirname "${BASH_SOURCE[0]}")/teslausb-config-loader.sh" \
  /root/bin/teslausb-config-loader.sh \
  /usr/local/lib/teslausb/teslausb-config-loader.sh
do
  if [ -r "$teslausb_loader_candidate" ]
  then
    # shellcheck source=/dev/null
    source "$teslausb_loader_candidate"
    TESLAUSB_CONFIG_LOADER_LOADED=true
    break
  fi
done
unset teslausb_loader_candidate

function validate_source_coordinates {
  local ref_component
  local -a ref_components=()

  if ! [[ "$REPO" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]
  then
    setup_config_message "STOP: REPO must be a GitHub owner name (letters, numbers, and non-edge dashes only)."
    return 1
  fi
  if [ -z "$BRANCH" ] || [ "${#BRANCH}" -gt 255 ] ||
     ! [[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] ||
     [[ "$BRANCH" == /* || "$BRANCH" == */ || "$BRANCH" == *..* ||
        "$BRANCH" == *//* || "$BRANCH" == *'@{'* || "$BRANCH" == @ ]]
  then
    setup_config_message "STOP: BRANCH is not a safe Git reference."
    return 1
  fi
  IFS=/ read -r -a ref_components <<< "$BRANCH"
  for ref_component in "${ref_components[@]}"
  do
    case "$ref_component" in
      ''|.*|*.|*.lock)
        setup_config_message "STOP: BRANCH is not a safe Git reference."
        return 1
        ;;
    esac
  done
}

function validate_teslausb_hostname {
  if [ -z "$TESLAUSB_HOSTNAME" ] || [ "${#TESLAUSB_HOSTNAME}" -gt 63 ] ||
     ! [[ "$TESLAUSB_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
  then
    setup_config_message "STOP: TESLAUSB_HOSTNAME must be a single 1-63 character DNS label."
    return 1
  fi
}

function read_setup_variables {
  local selected_setup_file
  if [ -n "${setup_file+x}" ]
  then
    selected_setup_file="$setup_file"
  elif [ -e /root/teslausb_setup.json ]
  then
    selected_setup_file=/root/teslausb_setup.json
  else
    selected_setup_file=/root/teslausb_setup_variables.conf
  fi
  if [ -e "$selected_setup_file" ]
  then
    if [ "$TESLAUSB_CONFIG_LOADER_LOADED" = true ]
    then
      teslausb_load_config "$selected_setup_file"
    elif [[ "$selected_setup_file" = *.conf ]]
    then
      setup_config_message "WARNING: declarative config loader unavailable; using deprecated legacy shell configuration."
      safesource "$selected_setup_file"
    else
      setup_config_message "STOP: declarative config loader unavailable for $selected_setup_file."
      return 1
    fi
  else
    echo "couldn't find $selected_setup_file"
    return 1
  fi

  # TODO: change this "declare" to "local" when github updates
  # to a newer shellcheck.
  declare -A newnamefor

  newnamefor[archiveserver]=ARCHIVE_SERVER
  newnamefor[camsize]=CAM_SIZE
  newnamefor[musicsize]=MUSIC_SIZE
  newnamefor[sharename]=SHARE_NAME
  newnamefor[musicsharename]=MUSIC_SHARE_NAME
  newnamefor[shareuser]=SHARE_USER
  newnamefor[sharepassword]=SHARE_PASSWORD
  newnamefor[tesla_email]=TESLA_EMAIL
  newnamefor[tesla_password]=TESLA_PASSWORD
  newnamefor[tesla_vin]=TESLA_VIN
  newnamefor[timezone]=TIME_ZONE
  newnamefor[usb_drive]=DATA_DRIVE
  newnamefor[USB_DRIVE]=DATA_DRIVE
  newnamefor[archivedelay]=ARCHIVE_DELAY
  newnamefor[trigger_file_saved]=TRIGGER_FILE_SAVED
  newnamefor[trigger_file_sentry]=TRIGGER_FILE_SENTRY
  newnamefor[trigger_file_any]=TRIGGER_FILE_ANY
  newnamefor[pushover_enabled]=PUSHOVER_ENABLED
  newnamefor[pushover_user_key]=PUSHOVER_USER_KEY
  newnamefor[pushover_app_key]=PUSHOVER_APP_KEY
  newnamefor[gotify_enabled]=GOTIFY_ENABLED
  newnamefor[gotify_domain]=GOTIFY_DOMAIN
  newnamefor[gotify_app_token]=GOTIFY_APP_TOKEN
  newnamefor[gotify_priority]=GOTIFY_PRIORITY
  newnamefor[ifttt_enabled]=IFTTT_ENABLED
  newnamefor[ifttt_event_name]=IFTTT_EVENT_NAME
  newnamefor[ifttt_key]=IFTTT_KEY
  newnamefor[sns_enabled]=SNS_ENABLED
  newnamefor[aws_region]=AWS_REGION
  newnamefor[aws_access_key_id]=AWS_ACCESS_KEY_ID
  newnamefor[aws_secret_key]=AWS_SECRET_ACCESS_KEY
  newnamefor[aws_sns_topic_arn]=AWS_SNS_TOPIC_ARN

  local oldname
  for oldname in "${!newnamefor[@]}"
  do
    local newname=${newnamefor[$oldname]}
    if [[ -z ${!newname+x} ]] && [[ -n ${!oldname+x} ]]
    then
      local value=${!oldname}
      export $newname="$value"
      unset $oldname
    fi
  done

  # set defaults for things not set in the config
  REPO=${REPO:-marcone}
  SNAPSHOTS_ENABLED=${SNAPSHOTS_ENABLED:-true}
  if [ "$SNAPSHOTS_ENABLED" != "true" ]
  then
    BRANCH="no-snapshots"
    if declare -F setup_progress > /dev/null
    then
      setup_progress "WARNING: using '$BRANCH' branch because SNAPSHOTS_ENABLED is not true"
    else
      echo "WARNING: using '$BRANCH' branch because SNAPSHOTS_ENABLED is not true"
    fi
  else
    BRANCH=${BRANCH:-main-dev}
  fi
  validate_source_coordinates || return 1
  CONFIGURE_ARCHIVING=${CONFIGURE_ARCHIVING:-true}
  UPGRADE_PACKAGES=${UPGRADE_PACKAGES:-false}
  export TESLAUSB_HOSTNAME=${TESLAUSB_HOSTNAME:-teslausb}
  validate_teslausb_hostname || return 1
  export NOTIFICATION_TITLE=${NOTIFICATION_TITLE:-${TESLAUSB_HOSTNAME}}
  SAMBA_ENABLED=${SAMBA_ENABLED:-false}
  SAMBA_GUEST=${SAMBA_GUEST:-false}
  SAMBA_USER=${SAMBA_USER:-pi}
  SSH_ALLOW_DEFAULT_PASSWORD=${SSH_ALLOW_DEFAULT_PASSWORD:-false}
  INCREASE_ROOT_SIZE=${INCREASE_ROOT_SIZE:-0}
  export CAM_SIZE=${CAM_SIZE:-0}
  export MUSIC_SIZE=${MUSIC_SIZE:-0}
  export BOOMBOX_SIZE=${BOOMBOX_SIZE:-0}
  export LIGHTSHOW_SIZE=${LIGHTSHOW_SIZE:-0}
  export WIFI_COUNTRY=${WIFI_COUNTRY:-''}
  export DATA_DRIVE=${DATA_DRIVE:-''}
  export USE_EXFAT=${USE_EXFAT:-false}
}

read_setup_variables

# Keep credentials as shell variables for the narrow setup steps that need
# them, but do not leak them into every subsequently spawned process.
for teslausb_secret_name in WEB_PASSWORD SAMBA_PASSWORD SSH_USER_PASSWORD \
  SSH_ROOT_PUBLIC_KEY WIFIPASS
do
  if [[ -v $teslausb_secret_name ]]
  then
    export -n "$teslausb_secret_name"
  fi
done
unset teslausb_secret_name

if [ -t 0 ]
then
  if ! declare -F log > /dev/null 
  then
    function log { echo "$@"; }
    export -f log
  fi
  complete -W "diagnose upgrade install" setup-teslausb
fi

function isRaspberryPi {
  grep -q "Raspberry Pi" /sys/firmware/devicetree/base/model
}

function isPi5 {
  grep -q "Raspberry Pi 5" /sys/firmware/devicetree/base/model
}
export -f isPi5

function isPi4 {
  grep -q "Raspberry Pi 4" /sys/firmware/devicetree/base/model
}
export -f isPi4

function isPi2 {
  grep -q "Raspberry Pi Zero 2" /sys/firmware/devicetree/base/model
}
export -f isPi2

function isRockPi4 {
  grep -q "ROCK Pi 4" /sys/firmware/devicetree/base/model
}
export -f isRockPi4

function isRadxaZero {
  grep -q "Radxa Zero" /sys/firmware/devicetree/base/model
}
export -f isRadxaZero

STATUSLED=/tmp/fakeled

while read -r led
do
  case "$led" in
    *status | */led0 | */ACT | */user-led2 | */radxa-zero:green)
      STATUSLED="$led"
      break;
      ;;
    *)
      ;;
    esac
done < <(find /sys/class/leds -type l)

if [ ! -d "$STATUSLED" ]
then
  mkdir -p "$STATUSLED"
fi

if [ -f /teslausb/cmdline.txt ]
then
  export CMDLINE_PATH=/teslausb/cmdline.txt
else
  export CMDLINE_PATH=/dev/null
fi

if [ -f /teslausb/config.txt ]
then
  export PICONFIG_PATH=/teslausb/config.txt
else
  export PICONFIG_PATH=/dev/null
fi

# losetup sometimes fails because of a mismatch between kernel and user land
# (https://lore.kernel.org/lkml/8bed44f2-273c-856e-0018-69f127ea4258@linux.ibm.com/)
# but even when it fails like that, testing shows the loop device gets created anyway
function losetup_find_show {
  local lastarg="${@:$#}"
  local loop=$(losetup -n -O NAME -j "$lastarg")
  if losetup -f --show "$@"
  then
    return
  fi
  if [ -n "$loop" ]
  then
    # losetup failed, and there was already a previous loop device for the
    # given file.
    # Rather than trying to determine if a new loop device was created, just return
    # an error.
    return 1
  fi
  local newloop=$(losetup -n -O NAME -j "$lastarg")
  if [ -z "$newloop" ]
  then
    # losetup truly failed and didn't even create a loop device
    return 1
  fi
  echo "$newloop"
}

export -f losetup_find_show
