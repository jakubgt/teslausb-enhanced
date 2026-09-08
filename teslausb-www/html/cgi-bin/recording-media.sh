#!/bin/bash

# Host/origin/method checks also apply when this CGI is called directly.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
export TESLAUSB_API_VERSION=1
export TESLAUSB_API_RESPONSE=json
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"
cgi_reject_cross_site

route="${PATH_INFO:-${REQUEST_URI%%\?*}}"
case "${route%/}" in
  /api/v1/recordings/download)
    cgi_require_method GET
    operation=download
    ;;
  /api/v1/trash/download)
    cgi_require_method GET
    operation=trash-download
    ;;
  /api/v1/recordings/preview)
    case "${REQUEST_METHOD:-GET}" in
      GET) operation=preview-status ;;
      POST)
        cgi_require_mutation
        operation=preview-request
        ;;
      *) cgi_error '405 Method Not Allowed' 'This endpoint requires GET or POST.' ;;
    esac
    ;;
  /api/v1/recordings/preview/media)
    cgi_require_method GET
    operation=preview-media
    ;;
  *) cgi_error '404 Not Found' 'Unknown recording media route.' ;;
esac

[[ -x /usr/bin/python3 ]] || cgi_error '503 Service Unavailable' 'The recording helper is unavailable.'
exec /usr/bin/python3 -I "$script_dir/recording-media.py" "$operation"
