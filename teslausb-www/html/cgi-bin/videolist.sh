#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_method GET

if [[ "${TESLAUSB_API_RESPONSE:-}" == json ]]
then
  cgi_headers '200 OK' 'application/json; charset=utf-8'
  printf '{"videos":['
  first=yes
  while IFS= read -r -d '' path
  do
    cgi_json_quote "$path"
    if [[ "$first" == yes ]]
    then
      first=no
    else
      printf ','
    fi
    printf '%s' "$CGI_JSON"
  done < <(find /mutable/TeslaCam -type l -printf '%P\0' 2>/dev/null | LC_ALL=C sort -z)
  printf ']}\n'
else
  cgi_headers '200 OK' 'text/plain; charset=utf-8'
  find /mutable/TeslaCam -type l -printf '%P\n' 2>/dev/null | LC_ALL=C sort
fi
