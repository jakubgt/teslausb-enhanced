#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_mutation
if ! touch /tmp/archive_is_unreachable
then
  cgi_error '500 Internal Server Error' 'Unable to trigger archive sync.'
fi

if [[ "${TESLAUSB_API_RESPONSE:-}" == json ]]
then
  cgi_ok 'Archive sync triggered.' '202 Accepted'
else
  exec "$script_dir/reload.sh" 'Sync triggered'
fi
