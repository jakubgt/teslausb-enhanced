#!/bin/bash

set -u
set -o pipefail

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/teslausb-cgi-test.XXXXXX")"
readonly test_dir
readonly document_root="$test_dir/html"
cgi_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../teslausb-www/html/cgi-bin" && pwd)"
readonly cgi_dir
sudo_helper="$cgi_dir/../../teslausb-web-sudo"
readonly sudo_helper

cleanup() {
  rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$document_root/fs/Music" "$document_root/fs/LightShow" "$document_root/fs/Boombox"
mkdir -p "$document_root/fs/Music/nested"
printf 'outside-secret\n' > "$test_dir/outside-secret"
printf 'inside-file\n' > "$document_root/fs/Music/inside.txt"

tests_run=0
tests_failed=0

pass() {
  tests_run=$((tests_run + 1))
  printf 'ok %d - %s\n' "$tests_run" "$1"
}

fail() {
  tests_run=$((tests_run + 1))
  tests_failed=$((tests_failed + 1))
  printf 'not ok %d - %s\n' "$tests_run" "$1"
}

assert_contains() {
  local description="$1"
  local haystack="$2"
  local needle="$3"

  if [[ "$haystack" == *"$needle"* ]]
  then
    pass "$description"
  else
    fail "$description (missing '$needle')"
  fi
}

assert_file_content() {
  local description="$1"
  local path="$2"
  local expected="$3"
  local actual

  if [[ -f "$path" ]]
  then
    actual="$(<"$path")"
  else
    actual='<<missing>>'
  fi
  if [[ "$actual" == "$expected" ]]
  then
    pass "$description"
  else
    fail "$description (got '$actual')"
  fi
}

run_get() {
  local script="$1"
  local query="$2"

  DOCUMENT_ROOT="$document_root" GATEWAY_INTERFACE=CGI/1.1 \
    HTTP_HOST=teslausb.local HTTP_USER_AGENT='Test Browser' \
    HTTP_SEC_FETCH_SITE=same-origin REQUEST_METHOD=GET QUERY_STRING="$query" \
    bash "$cgi_dir/$script"
}

run_api() {
  local method="$1"
  local route="$2"
  local query="${3:-}"

  DOCUMENT_ROOT="$document_root" GATEWAY_INTERFACE=CGI/1.1 \
    HTTP_HOST=teslausb.local REQUEST_METHOD="$method" PATH_INFO="$route" \
    QUERY_STRING="$query" HTTP_X_TESLAUSB_REQUEST=1 \
    bash "$cgi_dir/api-v1.sh"
}

printf 'TAP version 13\n'

# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$cgi_dir/cgi-common.sh"
cgi_html_escape '<script x="y">&'
if [[ "$CGI_ESCAPED" == '&lt;script x=&quot;y&quot;&gt;&amp;' ]]
then
  pass 'HTML output is escaped before interpolation'
else
  fail 'HTML output is escaped before interpolation'
fi

unsafe_json=$'Cafe "Guest"\\\n'
expected_json='"Cafe \"Guest\"\\\n"'
cgi_json_quote "$unsafe_json"
if [[ "$CGI_JSON" == "$expected_json" ]]
then
  pass 'JSON strings escape quotes, backslashes, and newlines'
else
  fail 'JSON strings escape quotes, backslashes, and newlines'
fi

response="$(run_api GET '/api/v1/capabilities')"
assert_contains 'the v1 capability endpoint is available' "$response" 'Status: 200 OK'
assert_contains 'v1 responses advertise their version' "$response" 'X-TeslaUSB-API-Version: 1'
assert_contains 'the capability document requires POST mutations' "$response" '"mutations": "POST"'

response="$(GATEWAY_INTERFACE=CGI/1.1 HTTP_HOST=teslausb.local \
  REQUEST_METHOD=GET PATH_INFO=/api/v1/speed-test QUERY_STRING=31 \
  bash "$cgi_dir/api-v1.sh")"
assert_contains 'the speed-test stream enforces its 30 second bound' "$response" 'Status: 400 Bad Request'

response="$(run_api GET '/api/v1/not-a-route')"
assert_contains 'unknown v1 routes return a JSON 404' "$response" 'Status: 404 Not Found'
assert_contains 'unknown v1 routes return a structured error' "$response" '"ok":false'

response="$(GATEWAY_INTERFACE=CGI/1.1 HTTP_HOST=dashboard.example \
  REQUEST_METHOD=GET PATH_INFO=/api/v1/capabilities bash "$cgi_dir/api-v1.sh")"
assert_contains 'unconfigured public Host values are rejected' "$response" 'Status: 421 Misdirected Request'
assert_contains 'API boundary failures use JSON' "$response" '"ok":false'

response="$(GATEWAY_INTERFACE=CGI/1.1 HTTP_HOST=10.attacker.example \
  REQUEST_METHOD=GET PATH_INFO=/api/v1/capabilities bash "$cgi_dir/api-v1.sh")"
assert_contains 'private-IP-looking public names are rejected' "$response" 'Status: 421 Misdirected Request'

response="$(GATEWAY_INTERFACE=CGI/1.1 HTTP_HOST=fd-attacker.example \
  REQUEST_METHOD=GET PATH_INFO=/api/v1/capabilities bash "$cgi_dir/api-v1.sh")"
assert_contains 'IPv6-prefix-looking public names are rejected' "$response" 'Status: 421 Misdirected Request'

response="$(GATEWAY_INTERFACE=CGI/1.1 HTTP_HOST='[fd00::1]' \
  REQUEST_METHOD=GET PATH_INFO=/api/v1/capabilities bash "$cgi_dir/api-v1.sh")"
assert_contains 'private IPv6 literal Hosts remain supported' "$response" 'Status: 200 OK'

response="$(GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET \
  PATH_INFO=/api/v1/capabilities bash "$cgi_dir/api-v1.sh")"
assert_contains 'CGI requests require a Host header' "$response" 'Status: 400 Bad Request'

response="$(GATEWAY_INTERFACE=CGI/1.1 HTTP_HOST=dashboard.example \
  WEB_ALLOWED_HOSTS=dashboard.example REQUEST_METHOD=GET \
  PATH_INFO=/api/v1/capabilities bash "$cgi_dir/api-v1.sh")"
assert_contains 'explicit custom Host values remain supported' "$response" 'Status: 200 OK'

response="$(DOCUMENT_ROOT="$document_root" GATEWAY_INTERFACE=CGI/1.1 \
  HTTP_HOST=teslausb.local REQUEST_METHOD=POST \
  PATH_INFO=/api/v1/files/mkdir QUERY_STRING='fs%2FMusic&missing-header' \
  bash "$cgi_dir/api-v1.sh")"
assert_contains 'v1 mutations require the CSRF request header' "$response" 'Status: 403 Forbidden'

response="$(GATEWAY_INTERFACE=CGI/1.1 HTTP_HOST=teslausb.local \
  REQUEST_METHOD=GET HTTP_USER_AGENT='Test Browser' HTTP_SEC_FETCH_SITE=same-origin \
  PATH_INFO=/api/v1/files/mkdir QUERY_STRING='fs%2FMusic&wrong-api-method' \
  bash "$cgi_dir/api-v1.sh")"
assert_contains 'v1 mutations reject compatibility GETs' "$response" 'Status: 405 Method Not Allowed'

response="$(DOCUMENT_ROOT="$document_root" GATEWAY_INTERFACE=CGI/1.1 \
  HTTP_HOST=teslausb.local REQUEST_METHOD=POST HTTP_X_TESLAUSB_REQUEST=1 \
  HTTP_SEC_FETCH_SITE=cross-site PATH_INFO=/api/v1/files/mkdir \
  QUERY_STRING='fs%2FMusic&cross-site' bash "$cgi_dir/api-v1.sh")"
assert_contains 'cross-site mutation requests are rejected' "$response" 'Status: 403 Forbidden'

response="$(run_api POST '/api/v1/files/mkdir' 'fs%2FMusic&created-by-v1')"
assert_contains 'a same-origin v1 mutation succeeds' "$response" 'Status: 200 OK'
assert_contains 'a successful v1 mutation returns JSON' "$response" '"ok":true'
if [[ -d "$document_root/fs/Music/created-by-v1" ]]
then
  pass 'the successful v1 mutation changes only its selected root'
else
  fail 'the successful v1 mutation changes only its selected root'
fi

response="$(DOCUMENT_ROOT="$document_root" GATEWAY_INTERFACE=CGI/1.1 \
  HTTP_HOST=teslausb.local REQUEST_METHOD=GET HTTP_USER_AGENT='Test Browser' \
  HTTP_SEC_FETCH_SITE=cross-site QUERY_STRING='fs%2FMusic&legacy-cross-site' \
  bash "$cgi_dir/mkdir.sh")"
assert_contains 'cross-site legacy mutations are rejected' "$response" 'Status: 403 Forbidden'

response="$(DOCUMENT_ROOT="$document_root" GATEWAY_INTERFACE=CGI/1.1 \
  HTTP_HOST=teslausb.local:80 SERVER_PORT=80 REQUEST_METHOD=GET \
  HTTP_USER_AGENT='Test Browser' HTTP_REFERER='http://teslausb.local:8080/new/' \
  QUERY_STRING='fs%2FMusic&legacy-other-port' bash "$cgi_dir/mkdir.sh")"
assert_contains 'legacy mutations reject a different-origin port' "$response" 'Status: 403 Forbidden'

response="$(DOCUMENT_ROOT="$document_root" GATEWAY_INTERFACE=CGI/1.1 \
  HTTP_HOST=teslausb.local REQUEST_METHOD=GET HTTP_USER_AGENT='Test Browser' \
  HTTP_SEC_FETCH_SITE=same-origin QUERY_STRING='fs%2FMusic&legacy-same-origin' \
  bash "$cgi_dir/mkdir.sh")"
assert_contains 'same-origin legacy mutations remain temporarily compatible' "$response" 'Status: 200 OK'
assert_contains 'legacy mutation responses advertise deprecation' "$response" 'Deprecation: true'

response="$(run_get download.sh 'fs%2FMusic&inside.txt')"
assert_contains 'a valid download succeeds' "$response" 'Status: 200 OK'
assert_contains 'download responses disable MIME sniffing' "$response" 'X-Content-Type-Options: nosniff'
assert_contains 'download responses are attachments' "$response" 'Content-Disposition: attachment'
assert_contains 'a valid download returns the file body' "$response" 'inside-file'

response="$(run_get download.sh 'fs%2FMusic&..%2F..%2F..%2Foutside-secret')"
assert_contains 'download rejects parent traversal' "$response" 'Status: 403 Forbidden'
if [[ "$response" != *'outside-secret'* ]]
then
  pass 'download traversal does not disclose the outside file'
else
  fail 'download traversal does not disclose the outside file'
fi

response="$(run_get download.sh 'fs%2FMusic&%2Fetc%2Fpasswd')"
assert_contains 'download rejects absolute paths' "$response" 'Status: 400 Bad Request'

response="$(run_get ls.sh '..%2F..&.')"
assert_contains 'filesystem roots are allowlisted' "$response" 'Status: 403 Forbidden'

response="$(run_get ls.sh 'fs%2FMusic&bad%GGname')"
assert_contains 'malformed percent escapes are rejected' "$response" 'Status: 400 Bad Request'

ln -s "$test_dir/outside-secret" "$document_root/fs/Music/outside-link"
response="$(run_get download.sh 'fs%2FMusic&outside-link')"
assert_contains 'symlinks cannot escape the selected root' "$response" 'Status: 403 Forbidden'

mkdir -p "$document_root/fs/Music/zip-nested"
ln -s "$test_dir/outside-secret" "$document_root/fs/Music/zip-nested/outside-link"
response="$(run_get downloadzip.sh 'fs%2FMusic&zip-nested')"
assert_contains 'ZIP downloads reject nested symlinks' "$response" 'Status: 403 Forbidden'
if [[ "$response" != *'outside-secret'* ]]
then
  pass 'ZIP downloads do not disclose nested symlink targets'
else
  fail 'ZIP downloads do not disclose nested symlink targets'
fi

declare -a traversal_cases=(
  'rm.sh|fs%2FMusic&..%2F..%2F..%2Foutside-secret'
  'cp.sh|fs%2FMusic&..%2F..%2F..%2Foutside-secret&copy.txt'
  'mv.sh|fs%2FMusic&..%2F..%2F..%2Foutside-secret&moved.txt'
  'mkdir.sh|fs%2FMusic&..%2F..%2F..%2Fescape-directory'
  'ls.sh|fs%2FMusic&..%2F..%2F..'
  'downloadzip.sh|fs%2FMusic&..%2F..%2F..%2Foutside-secret'
)
for test_case in "${traversal_cases[@]}"
do
  script="${test_case%%|*}"
  query="${test_case#*|}"
  response="$(run_get "$script" "$query")"
  assert_contains "$script rejects paths outside its root" "$response" 'Status: 403 Forbidden'
done
assert_file_content 'rejected operations leave the outside file unchanged' "$test_dir/outside-secret" 'outside-secret'

printf 'option-name\n' > "$document_root/fs/Music/-rf"
response="$(run_get rm.sh 'fs%2FMusic&-rf')"
assert_contains 'option-like filenames are accepted as paths' "$response" 'Status: 200 OK'
if [[ ! -e "$document_root/fs/Music/-rf" ]]
then
  pass 'rm treats an option-like filename as data'
else
  fail 'rm treats an option-like filename as data'
fi

payload='complete upload'
response="$(printf '%s' "$payload" | DOCUMENT_ROOT="$document_root" REQUEST_METHOD=POST \
  QUERY_STRING='fs%2FMusic&uploads%2Ftrack.txt' CONTENT_LENGTH="${#payload}" \
  HTTP_X_TESLAUSB_REQUEST=1 \
  bash "$cgi_dir/upload.sh")"
assert_contains 'a complete upload succeeds' "$response" 'Status: 200 OK'
assert_file_content 'a complete upload is installed' "$document_root/fs/Music/uploads/track.txt" "$payload"

payload='nested upload'
response="$(printf '%s' "$payload" | DOCUMENT_ROOT="$document_root" REQUEST_METHOD=POST \
  QUERY_STRING='fs%2FMusic%2Fnested&track.txt' CONTENT_LENGTH="${#payload}" \
  HTTP_X_TESLAUSB_REQUEST=1 \
  bash "$cgi_dir/upload.sh")"
assert_contains 'a nested legacy root remains supported' "$response" 'Status: 200 OK'
assert_file_content 'nested roots remain inside their allowed filesystem' "$document_root/fs/Music/nested/track.txt" "$payload"

response="$(run_get download.sh 'fs%2FMusic%2Fnested&..%2Finside.txt')"
assert_contains 'operands cannot escape a nested legacy root' "$response" 'Status: 403 Forbidden'

printf 'move to root\n' > "$document_root/fs/Music/nested/move-me.txt"
response="$(run_get mv.sh 'fs%2FMusic&nested%2Fmove-me.txt&.')"
assert_contains 'move accepts the selected filesystem root as a destination' "$response" 'Status: 200 OK'
assert_file_content 'moving into the selected root remains compatible' "$document_root/fs/Music/move-me.txt" 'move to root'

printf 'original content\n' > "$document_root/fs/Music/existing.txt"
payload='short'
response="$(printf '%s' "$payload" | DOCUMENT_ROOT="$document_root" REQUEST_METHOD=POST \
  QUERY_STRING='fs%2FMusic&existing.txt' CONTENT_LENGTH=20 \
  HTTP_X_TESLAUSB_REQUEST=1 \
  bash "$cgi_dir/upload.sh")"
assert_contains 'a truncated upload is rejected' "$response" 'Status: 400 Bad Request'
assert_file_content 'a truncated upload preserves the old destination' "$document_root/fs/Music/existing.txt" 'original content'
if ! find "$document_root/fs/Music" -name '.teslausb-upload.*' -print -quit | grep -q .
then
  pass 'failed uploads remove their temporary files'
else
  fail 'failed uploads remove their temporary files'
fi

payload='escape attempt'
response="$(printf '%s' "$payload" | DOCUMENT_ROOT="$document_root" REQUEST_METHOD=POST \
  QUERY_STRING='fs%2FMusic&..%2F..%2F..%2Fuploaded-outside' CONTENT_LENGTH="${#payload}" \
  HTTP_X_TESLAUSB_REQUEST=1 \
  bash "$cgi_dir/upload.sh")"
assert_contains 'upload rejects parent traversal' "$response" 'Status: 403 Forbidden'
if [[ ! -e "$test_dir/uploaded-outside" ]]
then
  pass 'upload traversal creates no outside file'
else
  fail 'upload traversal creates no outside file'
fi

response="$(DOCUMENT_ROOT="$document_root" REQUEST_METHOD=GET \
  QUERY_STRING='fs%2FMusic&wrong-method.txt' CONTENT_LENGTH=0 \
  bash "$cgi_dir/upload.sh")"
assert_contains 'upload rejects non-POST requests' "$response" 'Status: 405 Method Not Allowed'

if bash "$sudo_helper" > /dev/null 2>&1
then
  fail 'the sudo dispatcher rejects a missing action'
else
  pass 'the sudo dispatcher rejects a missing action'
fi

if bash "$sudo_helper" 'diagnose;id' > /dev/null 2>&1
then
  fail 'the sudo dispatcher rejects shell-like action text'
else
  pass 'the sudo dispatcher rejects shell-like action text'
fi

if bash "$sudo_helper" diagnose extra-argument > /dev/null 2>&1
then
  fail 'the sudo dispatcher rejects extra arguments'
else
  pass 'the sudo dispatcher rejects extra arguments'
fi

printf '1..%d\n' "$tests_run"
if (( tests_failed > 0 ))
then
  exit 1
fi
