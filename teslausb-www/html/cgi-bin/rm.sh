#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_mutation
cgi_parse_query 2 -1
cgi_resolve_root "${CGI_ARGS[0]}"

declare -a paths=()
for requested in "${CGI_ARGS[@]:1}"
do
  cgi_resolve_path "$requested"
  cgi_reject_final_symlink "$requested"
  cgi_require_existing any
  paths+=("$CGI_PATH")
done

if rm -r -- "${paths[@]}" &> /dev/null
then
  cgi_ok 'Delete completed.'
else
  cgi_error '409 Conflict' 'Unable to remove one or more requested paths.'
fi
