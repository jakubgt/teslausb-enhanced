#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_method GET

duration="${QUERY_STRING:-15}"
if [[ ! "$duration" =~ ^([1-9]|[12][0-9]|30)$ ]]
then
  cgi_error '400 Bad Request' 'Speed-test duration must be between 1 and 30 seconds.'
fi

cgi_headers '200 OK' 'application/octet-stream'
# Zero bytes measure the network path without consuming CPU in the kernel RNG.
# Both a wall-clock bound and a byte bound ensure abandoned requests release an
# fcgiwrap worker predictably. gzip is disabled for CGI responses in nginx.
timeout --signal=TERM "$duration" \
  head --bytes=1073741824 /dev/zero || status=$?
if [[ "${status:-0}" -ne 0 && "${status:-0}" -ne 124 && "${status:-0}" -ne 141 ]]
then
  exit "$status"
fi
