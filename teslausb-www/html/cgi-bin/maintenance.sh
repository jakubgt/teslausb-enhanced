#!/bin/bash

# Read-only maintenance API. Never source device configuration or request data.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
export TESLAUSB_API_VERSION=1
export TESLAUSB_API_RESPONSE=json
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_method GET
cgi_reject_cross_site
if [[ -n "${QUERY_STRING:-}" ]]
then
  cgi_error '400 Bad Request' 'This endpoint does not accept query parameters.'
fi

route="${PATH_INFO:-${REQUEST_URI%%\?*}}"
case "${route%/}" in
  /api/v1/maintenance|/cgi-bin/maintenance.sh|'') operation=status ;;
  /api/v1/maintenance/logs/diagnostics) operation=diagnostics ;;
  /api/v1/maintenance/logs/archiveloop) operation=archiveloop ;;
  /api/v1/maintenance/logs/setup) operation=setup ;;
  /api/v1/maintenance/logs/maintenance) operation=maintenance ;;
  *) cgi_error '404 Not Found' 'Unknown maintenance route.' ;;
esac

if [[ ! -x /usr/bin/python3 ]]
then
  cgi_error '503 Service Unavailable' 'The maintenance helper is unavailable.'
fi
# Isolated mode ignores PYTHONPATH and user site packages. The operation is
# selected above; neither paths nor commands come from the request.
exec /usr/bin/python3 -I "$script_dir/maintenance.py" "$operation"
