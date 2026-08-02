#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_method GET
if sudo -n /usr/local/sbin/teslausb-web-sudo ble-status &> /dev/null
then
  message=paired
else
  message='not paired'
fi

if [[ "${TESLAUSB_API_RESPONSE:-}" == json ]]
then
  cgi_ok "$message"
else
  exec "$script_dir/reload.sh" "$message"
fi
