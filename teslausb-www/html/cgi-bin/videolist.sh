#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_method GET

list_visible_video_links() {
  local path
  local resolved_path

  while IFS= read -r -d '' path
  do
    case "$path" in
      EncryptedClips | EncryptedClips/* | */EncryptedClips | */EncryptedClips/*)
        continue
        ;;
    esac
    resolved_path=$(realpath -e -- "/mutable/TeslaCam/$path" 2> /dev/null || true)
    case "$resolved_path" in
      '' | */EncryptedClips | */EncryptedClips/*)
        # Fail closed for broken/unresolvable links as well as aliases into an
        # encrypted snapshot. Only path metadata is resolved here.
        continue
        ;;
    esac
    printf '%s\0' "$path"
  done < <(find /mutable/TeslaCam -name EncryptedClips -prune -o \
    -type l -printf '%P\0' 2> /dev/null)
}

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
  done < <(list_visible_video_links | LC_ALL=C sort -z)
  printf ']}\n'
else
  cgi_headers '200 OK' 'text/plain; charset=utf-8'
  list_visible_video_links | tr '\0' '\n' | LC_ALL=C sort
fi
