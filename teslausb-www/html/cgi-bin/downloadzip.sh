#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_method GET
cgi_parse_query 2 -1
cgi_resolve_root "${CGI_ARGS[0]}"

declare -a paths=()
for requested in "${CGI_ARGS[@]:1}"
do
  cgi_resolve_path "$requested" yes
  cgi_reject_final_symlink "$requested"
  cgi_require_existing any
  paths+=("./$CGI_RELATIVE_PATH")
done

if ! command -v zip > /dev/null
then
  cgi_error '503 Service Unavailable' 'ZIP support is not installed.'
fi
if ! cd -- "$CGI_ROOT"
then
  cgi_error '500 Internal Server Error' 'The requested filesystem root is unavailable.'
fi

# Refuse trees containing links so an archive cannot disclose a target outside
# the selected media root.  The zip -y option below is a second, race-safe
# boundary: if a link appears after this scan, it is stored as a link and is
# never dereferenced by Info-ZIP.
if ! symlink_scan="$(find "${paths[@]}" -type l -print -quit 2>/dev/null)"
then
  cgi_error '500 Internal Server Error' 'The requested files could not be inspected safely.'
fi
if [[ -n "$symlink_scan" ]]
then
  cgi_error '403 Forbidden' 'Symbolic links cannot be included in ZIP downloads.'
fi

cgi_header_start '200 OK' 'application/zip'
printf 'Content-Disposition: attachment\r\n'
printf '\r\n'
exec zip -q -r -0 -y - -- "${paths[@]}"
