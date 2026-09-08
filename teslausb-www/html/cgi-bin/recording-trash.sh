#!/bin/bash

# Exact Trash routes. Python receives fixed operation names, never shell text.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
export TESLAUSB_API_VERSION=1
export TESLAUSB_API_RESPONSE=json
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

route="${PATH_INFO:-${REQUEST_URI%%\?*}}"
case "${route%/}" in
  /api/v1/trash) operation=status ;;
  /api/v1/trash/media) operation=media ;;
  /api/v1/trash/move) operation=move ;;
  /api/v1/trash/restore) operation=restore ;;
  /api/v1/trash/delete) operation=delete ;;
  *) cgi_error '404 Not Found' 'Unknown Trash route.' ;;
esac

case "$operation" in
  status|media)
    cgi_require_method GET
    cgi_reject_cross_site
    ;;
  move|restore|delete)
    cgi_require_method POST
    cgi_require_mutation
    ;;
esac
if [[ "$operation" != media && -n "${QUERY_STRING:-}" ]]
then
  cgi_error '400 Bad Request' 'This Trash operation does not accept query parameters.'
fi
exec /usr/bin/python3 -I "$script_dir/recording-trash.py" "$operation"
