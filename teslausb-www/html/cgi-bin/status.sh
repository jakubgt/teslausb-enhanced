#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_method GET

function read_drive_status {
  local gadget_root="${1:-/sys/kernel/config/usb_gadget/teslausb}"
  local udc_class="${2:-/sys/class/udc}"
  local udc camera_image

  # Keep the legacy enable/disable field aligned with the toggle endpoint.
  # A prepared gadget alone does not mean the host can see its camera drive.
  drives_active=no
  camera_drive_state=disabled
  usb_state=unknown
  [[ -d "$gadget_root" ]] || return 0
  drives_active=yes
  camera_drive_state=unknown
  udc=$(cat "$gadget_root/UDC" 2>/dev/null) || return 0
  if [[ -z "$udc" ]]
  then
    camera_drive_state=prepared
    usb_state='not attached'
    return 0
  fi
  [[ "$udc" != */* && "$udc" != . && "$udc" != .. ]] || return 0
  usb_state=$(cat "$udc_class/$udc/state" 2>/dev/null) || usb_state=unknown

  if [[ ! -L "$gadget_root/configs/c.1/mass_storage.0" ]]
  then
    camera_drive_state=prepared
    return 0
  fi
  camera_image=$(cat "$gadget_root/configs/c.1/mass_storage.0/lun.0/file" 2>/dev/null) || return 0
  if [[ -z "$camera_image" ]]
  then
    camera_drive_state=paused
    return 0
  fi
  if [[ "$camera_image" != /backingfiles/cam_disk.bin ]]
  then
    camera_drive_state=unavailable
    return 0
  fi
  case "$usb_state" in
    configured) camera_drive_state=connected ;;
    suspended) camera_drive_state=suspended ;;
    'not attached') camera_drive_state=disconnected ;;
    attached | powered | default | addressed) camera_drive_state=connecting ;;
    *) camera_drive_state=unknown ;;
  esac
}

read_drive_status /sys/kernel/config/usb_gadget/teslausb /sys/class/udc

readarray -t snapshots < <(find /backingfiles/snapshots/ -name snap.bin 2> /dev/null | sort)
readonly numsnapshots=${#snapshots[@]}
oldestsnapshot=
newestsnapshot=
if [[ "$numsnapshots" != "0" ]]
then
  oldestsnapshot=$(stat --format="%Y" "${snapshots[0]}")
  newestsnapshot=$(stat --format="%Y" "${snapshots[-1]}")
fi

wifidev=$(find /sys/class/net/ -type l -name 'wl*' -printf '%P' -quit)

if [ -n "$wifidev" ]
then
  wifi_ssid=$(iwgetid -r "$wifidev" || true)
  wifi_freq=$(iwgetid -r -f "$wifidev" || true)
  wifi_strength=$(iwconfig "$wifidev" | grep "Link Quality" | sed 's/ *Link Quality=\([0-9]*\)\/\([0-9]*\)\(.*\)/\1\/\2/')
  read -r _ wifi_ip _ < <(ifconfig "$wifidev" | grep "inet ")
else
  wifi_ssid=
  wifi_freq=
  wifi_strength=
  wifi_ip=
fi

ethdev=$(find /sys/class/net/ -type l \( -name 'eth*' -o -name 'en*' \) -printf '%P' -quit)

if [ -n "$ethdev" ]
then
  read -r _ ether_ip _ < <(ifconfig "$ethdev" | grep "inet ")
  IFS=" :" read -r _ ether_speed < <(ethtool "$ethdev" 2>&1 | grep Speed)
else
  ether_ip=
  ether_speed=
fi

read -r -d ' ' ut < /proc/uptime

fan_speed=$(cat /sys/devices/platform/cooling_fan/hwmon/*/fan1_input 2>/dev/null || echo "N/A")

if external_5v=$(sudo -n /usr/local/sbin/teslausb-web-sudo pmic-ext5v 2>/dev/null)
then
  external_5v=${external_5v##*=}
  external_5v=${external_5v%V}
else
  external_5v="N/A"
fi
if rtc_batt_v=$(sudo -n /usr/local/sbin/teslausb-web-sudo pmic-batt 2>/dev/null)
then
  rtc_batt_v=${rtc_batt_v##*=}
  rtc_batt_v=${rtc_batt_v%V}
else
  rtc_batt_v="N/A"
fi
if throttled=$(sudo -n /usr/local/sbin/teslausb-web-sudo get-throttled 2>/dev/null)
then
  throttled=${throttled#throttled=}
else
  throttled="N/A"
fi
cpu_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || true)

total_space=
free_space=
if read -r total_blocks free_blocks block_size < <(stat --file-system --format='%b %f %S' -- /backingfiles/. 2>/dev/null)
then
  total_space=$((total_blocks * block_size))
  free_space=$((free_blocks * block_size))
fi

archive_status_file="${ARCHIVE_STATUS_FILE:-/mutable/teslausb/archive-status.json}"
archive_status_json='{"schema_version":1,"last_result":"unavailable","last_started":"","last_finished":"","pending_files":0,"pending_bytes":0,"transferred_files":0,"transferred_bytes":0,"message":"Archive status is not available yet.","available":false}'
if [[ -f "$archive_status_file" && ! -L "$archive_status_file" ]]
then
  archive_uid="$(stat --format='%u' -- "$archive_status_file" 2>/dev/null || true)"
  archive_mode="$(stat --format='%a' -- "$archive_status_file" 2>/dev/null || true)"
  archive_size="$(stat --format='%s' -- "$archive_status_file" 2>/dev/null || true)"
  if [[ "$archive_uid" == 0 && "$archive_mode" =~ ^[0-7]{3,4}$ &&
        "$archive_size" =~ ^[0-9]+$ ]] &&
     (( (8#$archive_mode & 022) == 0 && archive_size <= 16384 ))
  then
    candidate="$(<"$archive_status_file")"
    if [[ "$candidate" == \{*\} &&
          "$candidate" == *'"schema_version": 1'* &&
          "$candidate" == *'"last_result":'* &&
          "$candidate" == *'"pending_files":'* &&
          "$candidate" == *'"pending_bytes":'* &&
          "$candidate" == *'"transferred_files":'* &&
          "$candidate" == *'"transferred_bytes":'* &&
          "$candidate" == *'"message":'* ]]
    then
      archive_status_json="${candidate%\}}"
      archive_status_json+=', "available": true}'
    fi
  fi
fi

encrypted_status_file="${ENCRYPTED_CLIPS_STATUS_FILE:-/mutable/teslausb/encrypted-clips-status.json}"
encrypted_status_json='{"schema_version":1,"detected":false,"locations":0,"checked_at":"","message":"Encrypted-clip detection has not run yet.","available":false}'
if [[ -f "$encrypted_status_file" && ! -L "$encrypted_status_file" ]]
then
  encrypted_uid="$(stat --format='%u' -- "$encrypted_status_file" 2>/dev/null || true)"
  encrypted_mode="$(stat --format='%a' -- "$encrypted_status_file" 2>/dev/null || true)"
  encrypted_size="$(stat --format='%s' -- "$encrypted_status_file" 2>/dev/null || true)"
  if [[ "$encrypted_uid" == 0 && "$encrypted_mode" =~ ^[0-7]{3,4}$ &&
        "$encrypted_size" =~ ^[0-9]+$ ]] &&
     (( (8#$encrypted_mode & 022) == 0 && encrypted_size <= 8192 ))
  then
    encrypted_candidate="$(<"$encrypted_status_file")"
    if [[ "$encrypted_candidate" == \{*\} &&
          "$encrypted_candidate" == *'"schema_version":1'* &&
          "$encrypted_candidate" == *'"detected":'* &&
          "$encrypted_candidate" == *'"locations":'* &&
          "$encrypted_candidate" == *'"checked_at":'* &&
          "$encrypted_candidate" == *'"message":'* ]]
    then
      encrypted_status_json="${encrypted_candidate%\}}"
      encrypted_status_json+=',"available":true}'
    fi
  fi
fi

cgi_json_quote "$cpu_temp"; cpu_temp_json="$CGI_JSON"
cgi_json_quote "$fan_speed"; fan_speed_json="$CGI_JSON"
cgi_json_quote "$external_5v"; external_5v_json="$CGI_JSON"
cgi_json_quote "$throttled"; throttled_json="$CGI_JSON"
cgi_json_quote "$rtc_batt_v"; rtc_batt_v_json="$CGI_JSON"
cgi_json_quote "$numsnapshots"; numsnapshots_json="$CGI_JSON"
cgi_json_quote "$oldestsnapshot"; oldestsnapshot_json="$CGI_JSON"
cgi_json_quote "$newestsnapshot"; newestsnapshot_json="$CGI_JSON"
cgi_json_quote "$total_space"; total_space_json="$CGI_JSON"
cgi_json_quote "$free_space"; free_space_json="$CGI_JSON"
cgi_json_quote "$ut"; uptime_json="$CGI_JSON"
cgi_json_quote "$drives_active"; drives_active_json="$CGI_JSON"
cgi_json_quote "$camera_drive_state"; camera_drive_state_json="$CGI_JSON"
cgi_json_quote "$usb_state"; usb_state_json="$CGI_JSON"
cgi_json_quote "$wifi_ssid"; wifi_ssid_json="$CGI_JSON"
cgi_json_quote "$wifi_freq"; wifi_freq_json="$CGI_JSON"
cgi_json_quote "$wifi_strength"; wifi_strength_json="$CGI_JSON"
cgi_json_quote "$wifi_ip"; wifi_ip_json="$CGI_JSON"
cgi_json_quote "$ether_ip"; ether_ip_json="$CGI_JSON"
cgi_json_quote "$ether_speed"; ether_speed_json="$CGI_JSON"

cgi_headers '200 OK' 'application/json; charset=utf-8'
cat << EOF
{
   "cpu_temp": $cpu_temp_json,
   "fan_speed": $fan_speed_json,
   "external_5v": $external_5v_json,
   "throttled": $throttled_json,
   "rtc_batt_v": $rtc_batt_v_json,
   "num_snapshots": $numsnapshots_json,
   "snapshot_oldest": $oldestsnapshot_json,
   "snapshot_newest": $newestsnapshot_json,
   "total_space": $total_space_json,
   "free_space": $free_space_json,
   "uptime": $uptime_json,
   "drives_active": $drives_active_json,
   "camera_drive_state": $camera_drive_state_json,
   "usb_state": $usb_state_json,
   "wifi_ssid": $wifi_ssid_json,
   "wifi_freq": $wifi_freq_json,
   "wifi_strength": $wifi_strength_json,
   "wifi_ip": $wifi_ip_json,
   "ether_ip": $ether_ip_json,
   "ether_speed": $ether_speed_json,
   "archive_status": $archive_status_json,
   "encrypted_clips": $encrypted_status_json
}
EOF
