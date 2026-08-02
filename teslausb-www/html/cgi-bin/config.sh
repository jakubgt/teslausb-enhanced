#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_method GET

function exists(){
  if [ -e "$1" ]
  then
    echo -n yes
  else
    echo -n no
  fi
}

function ble_configured(){
  if sudo -n /usr/local/sbin/teslausb-web-sudo ble-configured &> /dev/null
  then
    echo -n yes
  else
    echo -n no
  fi
}

cgi_headers '200 OK' 'application/json; charset=utf-8'
cat << EOF
{
   "has_cam" : "$(exists /backingfiles/cam_disk.bin)",
   "has_music" : "$(exists /backingfiles/music_disk.bin)",
   "has_lightshow" : "$(exists /backingfiles/lightshow_disk.bin)",
   "has_boombox" : "$(exists /backingfiles/boombox_disk.bin)",
   "uses_ble" : "$(ble_configured)"
}
EOF
