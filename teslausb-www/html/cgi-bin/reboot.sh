#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_mutation

# The dispatcher uses systemctl --no-block where available, which reports
# whether the reboot was queued while leaving enough time to return this CGI
# response.  Older images fall back to their existing reboot executable.
if sudo -n /usr/local/sbin/teslausb-web-sudo reboot &> /dev/null
then
  if [[ "${TESLAUSB_API_RESPONSE:-}" == json ]]
  then
    cgi_ok 'Reboot queued.' '202 Accepted'
  else
    exec "$script_dir/reload.sh" "Rebooting"
  fi
else
  cgi_error '500 Internal Server Error' 'Unable to queue the reboot.'
fi
