#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_method GET
cgi_parse_query 2 2
cgi_resolve_root "${CGI_ARGS[0]}"
cgi_resolve_path "${CGI_ARGS[1]}"
cgi_reject_final_symlink "${CGI_ARGS[1]}"
cgi_require_existing file

mime="$(file --brief --mime-type -- "$CGI_PATH" 2>/dev/null)"
if [[ ! "$mime" =~ ^[[:alnum:]][[:alnum:].+-]*/[[:alnum:]][[:alnum:].+-]*$ ]]
then
  mime='application/octet-stream'
fi

cgi_header_start '200 OK' "$mime"
printf 'Content-Disposition: attachment\r\n'
printf 'Content-Length: %s\r\n' "$(stat --format='%s' -- "$CGI_PATH")"
printf '\r\n'
cat -- "$CGI_PATH"
