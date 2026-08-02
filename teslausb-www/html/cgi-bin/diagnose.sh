#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_mutation

umask 077
if ! tempfile="$(mktemp '/tmp/teslausb-diagnostics.XXXXXX')"
then
  cgi_error '507 Insufficient Storage' 'Unable to create a diagnostics file.'
fi
cleanup_diagnostics() {
  if [[ -n "${tempfile:-}" ]]
  then
    rm -f -- "$tempfile"
  fi
}
trap cleanup_diagnostics EXIT
trap 'exit 1' HUP INT TERM

# The unprivileged CGI process intentionally owns this private capture file;
# sudo is needed only for the fixed diagnostics command.
# shellcheck disable=SC2024
if ! sudo -n /usr/local/sbin/teslausb-web-sudo diagnose > "$tempfile" 2>&1
then
  cgi_error '500 Internal Server Error' 'Diagnostics generation failed.'
fi
if ! mv -fT -- "$tempfile" /tmp/diagnostics.txt
then
  cgi_error '507 Insufficient Storage' 'Unable to install the diagnostics file.'
fi
tempfile=
trap - EXIT HUP INT TERM

if [[ "${TESLAUSB_API_RESPONSE:-}" == json ]]
then
  cgi_ok 'Diagnostics generated.'
else
  exec "$script_dir/reload.sh" "Diagnostics generated"
fi
