#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_mutation
cgi_parse_query 3 -1
cgi_resolve_root "${CGI_ARGS[0]}"

declare -a paths=()
last_index=$((${#CGI_ARGS[@]} - 1))
for ((i=1; i<last_index; i++))
do
  cgi_resolve_path "${CGI_ARGS[i]}"
  cgi_reject_final_symlink "${CGI_ARGS[i]}"
  cgi_require_existing any
  paths+=("$CGI_PATH")
done
cgi_resolve_path "${CGI_ARGS[last_index]}" yes
cgi_reject_final_symlink "${CGI_ARGS[last_index]}"
paths+=("$CGI_PATH")

if cp -- "${paths[@]}" &> /dev/null
then
  cgi_ok 'Copy completed.'
else
  cgi_error '409 Conflict' 'Unable to copy the requested path.'
fi
