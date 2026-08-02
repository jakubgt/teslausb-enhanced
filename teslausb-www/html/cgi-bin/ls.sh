#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_method GET
cgi_parse_query 1 2
cgi_resolve_root "${CGI_ARGS[0]}"

lspath="${CGI_ARGS[1]:-.}"
cgi_resolve_path "$lspath" yes
cgi_reject_final_symlink "$lspath"
cgi_require_existing directory
lspath="./$CGI_RELATIVE_PATH"

if ! cd -- "$CGI_ROOT"
then
  cgi_error '500 Internal Server Error' 'The requested filesystem root is unavailable.'
fi

cgi_headers '200 OK' 'text/plain; charset=utf-8'
{
  find "$lspath" -mindepth 1 -maxdepth 1 \( -type d -printf 'd:%p\n' \) -o -printf "f:%p:%s\n"
  find "$lspath" -mindepth 2 -maxdepth 2 \( -type d -printf 'D:%p\n' -prune \)
  read -r free_blocks total_blocks block_size < <(stat --file-system --format='%f %b %S' -- "$lspath/.")
  printf 's:%s:%s\n' "$((free_blocks * block_size))" "$((total_blocks * block_size))"
} | sed 's/:\.\//:/' | LC_ALL=C sort -f
