#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
export TESLAUSB_API_VERSION=1
export TESLAUSB_API_RESPONSE=json
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

# New power actions do not inherit legacy GET mutation compatibility.
cgi_require_method POST
cgi_require_mutation
if [[ -n "${QUERY_STRING:-}" ]]
then
  cgi_error '400 Bad Request' 'Shutdown does not accept query parameters.'
fi

# The fixed root action queues poweroff without waiting for the system to stop,
# leaving time to return an accepted response. No request data is forwarded.
if sudo -n /usr/local/sbin/teslausb-web-sudo shutdown &> /dev/null
then
  cgi_ok 'Shutdown queued. Disconnect and reconnect power to start the Pi again.' '202 Accepted'
else
  cgi_error '500 Internal Server Error' 'Unable to queue shutdown. The Pi may still be running.'
fi
