#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

# This recovery action has no legacy GET compatibility. Rebuilding the gadget
# briefly disconnects every exported drive, so it always requires an explicit
# same-origin POST from the dashboard or a trusted API client.
cgi_require_method POST
cgi_require_mutation

output=
status=0
output=$(sudo -n /usr/local/sbin/teslausb-web-sudo gadget-repair 2>&1) || status=$?
output=${output//$'\r'/ }
output=${output//$'\n'/ }
output=${output:0:512}

case "$status" in
  0)
    cgi_ok 'USB gadget rebuilt and verified.'
    ;;
  69)
    cgi_error '503 Service Unavailable' "USB gadget repair is unavailable. $output"
    ;;
  75)
    cgi_error '429 Too Many Requests' "$output"
    ;;
  *)
    cgi_error '500 Internal Server Error' "USB gadget repair failed. $output"
    ;;
esac
