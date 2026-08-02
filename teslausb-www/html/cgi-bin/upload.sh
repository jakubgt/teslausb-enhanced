#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_method POST
cgi_require_mutation
cgi_parse_query 2 2
cgi_resolve_root "${CGI_ARGS[0]}"

if [[ ! "${CONTENT_LENGTH:-}" =~ ^[0-9]+$ ]]
then
  cgi_error '411 Length Required' 'A valid Content-Length header is required.'
fi

requested="${CGI_ARGS[1]}"
if [[ "$requested" == */ ]]
then
  cgi_error '400 Bad Request' 'The upload destination must be a file path.'
fi
cgi_resolve_path "$requested"
cgi_reject_final_symlink "$requested"
destpath="$CGI_PATH"
destdir="${destpath%/*}"

if ! mkdir -p -- "$destdir"
then
  cgi_error '409 Conflict' 'Unable to create the upload destination directory.'
fi
# Re-resolve after creating parent directories so a pre-existing symlink in
# the path cannot redirect the final write outside the selected filesystem.
cgi_resolve_path "$requested"
destpath="$CGI_PATH"
destdir="${destpath%/*}"
if [[ -d "$destpath" ]]
then
  cgi_error '409 Conflict' 'The upload destination is a directory.'
fi

umask 077
if ! tempfile="$(mktemp --tmpdir="$destdir" '.teslausb-upload.XXXXXX')"
then
  cgi_error '507 Insufficient Storage' 'Unable to create a temporary upload file.'
fi
cleanup_upload() {
  if [[ -n "${tempfile:-}" ]]
  then
    rm -f -- "$tempfile"
  fi
}
trap cleanup_upload EXIT
trap 'exit 1' HUP INT TERM

if ! cat > "$tempfile"
then
  cgi_error '507 Insufficient Storage' 'The upload could not be written.'
fi

expected="$CONTENT_LENGTH"
while [[ ${#expected} -gt 1 && "$expected" == 0* ]]
do
  expected="${expected#0}"
done
actual="$(stat --format='%s' -- "$tempfile")"
if [[ "$actual" != "$expected" ]]
then
  cgi_error '400 Bad Request' 'The request body length did not match Content-Length.'
fi

chmod 0644 "$tempfile" 2>/dev/null || true
if ! mv -f -- "$tempfile" "$destpath"
then
  cgi_error '507 Insufficient Storage' 'The completed upload could not be installed.'
fi
tempfile=
trap - EXIT HUP INT TERM

cgi_ok 'Upload completed.'
