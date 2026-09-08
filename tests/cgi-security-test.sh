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
assert_contains 'the capability document advertises manual gadget repair' "$response" '"drives/repair"'
assert_contains 'the capability document advertises recording Trash' "$response" '"trash": "/api/v1/trash"'
assert_contains 'the capability document advertises preview requests' "$response" '"recording_previews": "/api/v1/recordings/preview"'
assert_contains 'the capability document advertises safe shutdown' "$response" '"shutdown"'

# Power-action tests always substitute inert sudo before invoking a CGI. Even
# a method/CSRF regression cannot reach the host's actual shutdown command.
shutdown_fixture="$test_dir/shutdown"
mkdir -p "$shutdown_fixture/bin"
cat > "$shutdown_fixture/bin/sudo" <<'SHUTDOWN_SUDO'
#!/bin/sh
[ "$*" = '-n /usr/local/sbin/teslausb-web-sudo shutdown' ] || exit 99
printf '%s\n' "$*" > "$SHUTDOWN_FIXTURE_LOG"
exit "${SHUTDOWN_FIXTURE_RESULT:-0}"
SHUTDOWN_SUDO
chmod +x "$shutdown_fixture/bin/sudo"

run_shutdown_fixture() {
  local script="$1"
  local method="$2"
  local query="${3:-}"

  PATH="$shutdown_fixture/bin:$PATH" SHUTDOWN_FIXTURE_LOG="$shutdown_fixture/sudo-called" \
    DOCUMENT_ROOT="$document_root" GATEWAY_INTERFACE=CGI/1.1 HTTP_HOST=teslausb.local \
    REQUEST_METHOD="$method" PATH_INFO=/api/v1/actions/shutdown QUERY_STRING="$query" \
    bash "$cgi_dir/$script"
}

for entrypoint in api-v1.sh shutdown.sh
do
  response="$(HTTP_SEC_FETCH_SITE=same-origin HTTP_X_TESLAUSB_REQUEST=1 \
    run_shutdown_fixture "$entrypoint" GET)"
  assert_contains "$entrypoint rejects GET shutdown" "$response" 'Status: 405 Method Not Allowed'
  response="$(HTTP_SEC_FETCH_SITE=same-origin HTTP_X_TESLAUSB_REQUEST= \
    run_shutdown_fixture "$entrypoint" POST)"
  assert_contains "$entrypoint requires CSRF before shutdown" "$response" 'Status: 403 Forbidden'
  response="$(HTTP_SEC_FETCH_SITE=cross-site HTTP_X_TESLAUSB_REQUEST=1 \
    run_shutdown_fixture "$entrypoint" POST)"
  assert_contains "$entrypoint rejects cross-site shutdown" "$response" 'Status: 403 Forbidden'
  response="$(HTTP_SEC_FETCH_SITE=same-origin HTTP_ORIGIN=http://other.local HTTP_X_TESLAUSB_REQUEST=1 \
    run_shutdown_fixture "$entrypoint" POST)"
  assert_contains "$entrypoint rejects a mismatched shutdown Origin" "$response" 'Status: 403 Forbidden'
  response="$(HTTP_SEC_FETCH_SITE=same-origin HTTP_X_TESLAUSB_REQUEST=1 \
    run_shutdown_fixture "$entrypoint" POST 'command=anything')"
  assert_contains "$entrypoint rejects shutdown query arguments" "$response" 'Status: 400 Bad Request'
done
if [[ ! -e "$shutdown_fixture/sudo-called" ]]
then
  pass 'rejected shutdown requests never invoke sudo'
else
  fail 'a rejected shutdown request invoked sudo'
fi
response="$(HTTP_SEC_FETCH_SITE=same-origin HTTP_X_TESLAUSB_REQUEST=1 SHUTDOWN_FIXTURE_RESULT=0 \
  run_shutdown_fixture api-v1.sh POST)"
assert_contains 'protected shutdown queues the fixed mocked action' "$response" 'Status: 202 Accepted'
assert_contains 'accepted shutdown returns structured success' "$response" '"ok":true'
assert_contains 'accepted shutdown explains how to start the Pi again' "$response" 'Disconnect and reconnect power'
assert_file_content 'shutdown forwards exactly the fixed sudo action' "$shutdown_fixture/sudo-called" '-n /usr/local/sbin/teslausb-web-sudo shutdown'
response="$(HTTP_SEC_FETCH_SITE=same-origin HTTP_X_TESLAUSB_REQUEST=1 SHUTDOWN_FIXTURE_RESULT=23 \
  run_shutdown_fixture api-v1.sh POST)"
assert_contains 'shutdown fails closed when the privileged action fails' "$response" 'Status: 500 Internal Server Error'
assert_contains 'failed shutdown never reports queued success' "$response" '"ok":false'

# Validate the production privilege boundary, then exercise only a copied
# run_shutdown function whose two absolute executable paths point into this
# private fixture. The copied program contains no real host power command.
if python3 - "$sudo_helper" "$cgi_dir/../../teslausb-web-sudoers" "$shutdown_fixture" <<'SHUTDOWN_PYTHON'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
policy = pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')
fixture = pathlib.Path(sys.argv[3])
match = re.search(r'(?m)^run_shutdown\(\) \{\n(.*?)^\}\n', source, re.S)
assert match, 'Missing fixed shutdown function'
function = match.group(0)
assert 'for candidate in /usr/bin/systemctl /bin/systemctl' in function
assert 'exec "$candidate" --no-block poweroff' in function
assert 'exit 127' in function
assert all(token not in function for token in ('$@', 'eval ', 'source ', '${', '/sbin/poweroff', '/sbin/shutdown'))
assert '(( $# == 1 )) || usage_error' in source
assert 'readonly PATH' in source
assert '  shutdown)\n    run_shutdown\n    ;;' in source
assert policy.count('/usr/local/sbin/teslausb-web-sudo shutdown,') == 1
assert 'NOSETENV: TESLAUSB_WEB' in policy
assert '/usr/bin/systemctl' not in policy and '/bin/systemctl' not in policy
assert '/sbin/poweroff' not in policy and '/sbin/shutdown' not in policy
assert not re.search(r'teslausb-web-sudo\s+shutdown\s*\*', policy)
for name in ('/usr/bin/systemctl', '/bin/systemctl'):
    target = str(fixture / ('first-systemctl' if name.startswith('/usr/') else 'second-systemctl'))
    function = function.replace(name, "'" + target.replace("'", "'\\''") + "'")
assert '/usr/bin/systemctl' not in function and '/bin/systemctl' not in function
(fixture / 'dispatcher-copy.sh').write_text('#!/bin/bash\n' + function + '\nrun_shutdown\n', encoding='utf-8')
SHUTDOWN_PYTHON
then
  pass 'shutdown uses fixed root candidates and one exact sudoers action'
else
  fail 'shutdown uses fixed root candidates and one exact sudoers action'
fi
if bash "$shutdown_fixture/dispatcher-copy.sh" > "$shutdown_fixture/output" 2>&1
then
  fail 'shutdown refuses to proceed without systemctl'
else
  shutdown_status=$?
  if [[ "$shutdown_status" == 127 ]]
  then
    pass 'shutdown refuses to proceed without systemctl'
  else
    fail 'shutdown missing-executable result is explicit'
  fi
fi
cat > "$shutdown_fixture/first-systemctl" <<'SHUTDOWN_SYSTEMCTL'
#!/bin/sh
printf '%s\n' "$0" "$@" > "$SHUTDOWN_FIXTURE_LOG"
exit "${SHUTDOWN_FIXTURE_RESULT:-0}"
SHUTDOWN_SYSTEMCTL
chmod +x "$shutdown_fixture/first-systemctl"
if SHUTDOWN_FIXTURE_LOG="$shutdown_fixture/dispatch-called" SHUTDOWN_FIXTURE_RESULT=0 \
  bash "$shutdown_fixture/dispatcher-copy.sh"
then
  pass 'fixed shutdown function propagates mocked queue success'
else
  fail 'fixed shutdown function propagates mocked queue success'
fi
assert_file_content 'shutdown uses only no-block poweroff arguments' "$shutdown_fixture/dispatch-called" \
  "$shutdown_fixture/first-systemctl"$'\n--no-block\npoweroff'
if SHUTDOWN_FIXTURE_LOG="$shutdown_fixture/dispatch-called" SHUTDOWN_FIXTURE_RESULT=23 \
  bash "$shutdown_fixture/dispatcher-copy.sh"
then
  fail 'fixed shutdown function must not hide systemctl failure'
else
  shutdown_status=$?
  if [[ "$shutdown_status" == 23 ]]
  then
    pass 'fixed shutdown function propagates systemctl failure'
  else
    fail 'fixed shutdown function preserves the actual failure code'
  fi
fi
mv "$shutdown_fixture/first-systemctl" "$shutdown_fixture/second-systemctl"
if SHUTDOWN_FIXTURE_LOG="$shutdown_fixture/dispatch-called" SHUTDOWN_FIXTURE_RESULT=0 \
  bash "$shutdown_fixture/dispatcher-copy.sh"
then
  pass 'shutdown supports the second fixed systemctl location'
else
  fail 'shutdown supports the second fixed systemctl location'
fi
assert_file_content 'second candidate still receives only no-block poweroff' "$shutdown_fixture/dispatch-called" \
  "$shutdown_fixture/second-systemctl"$'\n--no-block\npoweroff'
if bash "$sudo_helper" shutdown extra-argument > /dev/null 2>&1
then
  fail 'shutdown privilege dispatcher rejects extra arguments'
else
  pass 'shutdown privilege dispatcher rejects extra arguments'
fi

# Exercise the actual dispatcher and recording wrappers with inert Python
# implementations. An accepted request can only create a marker in this fixture;
# these tests never open /mutable, recordings, a preview encoder, or a Pi service.
recording_fixture="$test_dir/recording-cgi"
mkdir -p "$recording_fixture"
cp "$cgi_dir/api-v1.sh" "$cgi_dir/cgi-common.sh" \
  "$cgi_dir/recording-trash.sh" "$cgi_dir/recording-media.sh" "$recording_fixture/"
chmod +x "$recording_fixture/"*.sh
cat > "$recording_fixture/recording-trash.py" <<'PYTHON'
import pathlib
import sys

operation = sys.argv[1]
pathlib.Path(__file__).with_suffix('.called').write_text(operation, encoding='ascii')
print('Status: 200 OK\r\nContent-Type: text/plain\r\n\r\nfixture-operation: ' + operation)
PYTHON
cp "$recording_fixture/recording-trash.py" "$recording_fixture/recording-media.py"

run_recording_fixture() {
  local script="$1"
  local method="$2"
  local route="$3"
  local query="${4:-}"

  DOCUMENT_ROOT="$document_root" GATEWAY_INTERFACE=CGI/1.1 \
    HTTP_HOST=teslausb.local REQUEST_METHOD="$method" PATH_INFO="$route" \
    QUERY_STRING="$query" bash "$recording_fixture/$script"
}

for trash_action in move restore delete
do
  recording_route="/api/v1/trash/$trash_action"
  for entrypoint in api-v1.sh recording-trash.sh
  do
    response="$(HTTP_SEC_FETCH_SITE=same-origin HTTP_X_TESLAUSB_REQUEST=1 \
      run_recording_fixture "$entrypoint" GET "$recording_route")"
    assert_contains "$entrypoint rejects GET Trash $trash_action" "$response" 'Status: 405 Method Not Allowed'
    response="$(HTTP_X_TESLAUSB_REQUEST='' HTTP_SEC_FETCH_SITE=same-origin \
      run_recording_fixture "$entrypoint" POST "$recording_route")"
    assert_contains "$entrypoint requires CSRF header for Trash $trash_action" "$response" 'Status: 403 Forbidden'
    response="$(HTTP_X_TESLAUSB_REQUEST=1 HTTP_SEC_FETCH_SITE=cross-site \
      run_recording_fixture "$entrypoint" POST "$recording_route")"
    assert_contains "$entrypoint rejects cross-site Trash $trash_action" "$response" 'Status: 403 Forbidden'
    response="$(HTTP_X_TESLAUSB_REQUEST=1 HTTP_SEC_FETCH_SITE=same-site HTTP_ORIGIN=http://other.local \
      run_recording_fixture "$entrypoint" POST "$recording_route")"
    assert_contains "$entrypoint rejects another origin for Trash $trash_action" "$response" 'Status: 403 Forbidden'
    response="$(HTTP_X_TESLAUSB_REQUEST=1 HTTP_SEC_FETCH_SITE=same-origin \
      run_recording_fixture "$entrypoint" POST "$recording_route" 'event=ignored-query')"
    assert_contains "$entrypoint rejects query parameters for Trash $trash_action" "$response" 'Status: 400 Bad Request'
  done
done

for entrypoint in api-v1.sh recording-media.sh
do
  response="$(HTTP_X_TESLAUSB_REQUEST='' HTTP_SEC_FETCH_SITE=same-origin \
    run_recording_fixture "$entrypoint" POST /api/v1/recordings/preview)"
  assert_contains "$entrypoint requires CSRF header before preview generation" "$response" 'Status: 403 Forbidden'
  response="$(HTTP_X_TESLAUSB_REQUEST=1 HTTP_SEC_FETCH_SITE=cross-site \
    run_recording_fixture "$entrypoint" POST /api/v1/recordings/preview)"
  assert_contains "$entrypoint rejects cross-site preview generation" "$response" 'Status: 403 Forbidden'
  response="$(HTTP_X_TESLAUSB_REQUEST=1 HTTP_SEC_FETCH_SITE=same-origin HTTP_ORIGIN=http://teslausb.local:8080 \
    run_recording_fixture "$entrypoint" POST /api/v1/recordings/preview)"
  assert_contains "$entrypoint rejects a different origin port for previews" "$response" 'Status: 403 Forbidden'
  response="$(HTTP_X_TESLAUSB_REQUEST=1 HTTP_SEC_FETCH_SITE=same-origin \
    run_recording_fixture "$entrypoint" DELETE /api/v1/recordings/preview)"
  assert_contains "$entrypoint rejects unsupported preview mutation methods" "$response" 'Status: 405 Method Not Allowed'
done

for recording_route in /api/v1/trash /api/v1/trash/media \
  /api/v1/trash/download /api/v1/recordings/download /api/v1/recordings/preview/media
do
  response="$(HTTP_X_TESLAUSB_REQUEST=1 HTTP_SEC_FETCH_SITE=same-origin \
    run_recording_fixture api-v1.sh POST "$recording_route")"
  assert_contains "$recording_route rejects POST on its read-only route" "$response" 'Status: 405 Method Not Allowed'
  response="$(HTTP_SEC_FETCH_SITE=cross-site \
    run_recording_fixture api-v1.sh GET "$recording_route")"
  assert_contains "$recording_route rejects cross-site reads" "$response" 'Status: 403 Forbidden'
done

for recording_route in /api/v1/trash/cleanup /api/v1/trash/purge /api/v1/trash/media/extra \
  /api/v1/recordings/preview/worker /api/v1/recordings/preview/request
do
  response="$(HTTP_X_TESLAUSB_REQUEST=1 HTTP_SEC_FETCH_SITE=same-origin \
    run_recording_fixture api-v1.sh POST "$recording_route")"
  assert_contains "$recording_route is not an exposed API action" "$response" 'Status: 404 Not Found'
done

response="$(HTTP_X_TESLAUSB_REQUEST=1 HTTP_SEC_FETCH_SITE=same-origin \
  run_recording_fixture recording-trash.sh POST /cgi-bin/recording-trash.sh)"
assert_contains 'direct Trash wrapper URL cannot choose a mutation' "$response" 'Status: 404 Not Found'
response="$(HTTP_X_TESLAUSB_REQUEST=1 HTTP_SEC_FETCH_SITE=same-origin \
  run_recording_fixture recording-media.sh POST /cgi-bin/recording-media.sh)"
assert_contains 'direct recording wrapper URL cannot choose a worker operation' "$response" 'Status: 404 Not Found'

if [[ ! -e "$recording_fixture/recording-trash.called" && ! -e "$recording_fixture/recording-media.called" ]]
then
  pass 'all rejected recording requests stop before the Python helper boundary'
else
  fail 'a rejected recording request reached the Python helper boundary'
fi

for trash_action in move restore delete
do
  response="$(HTTP_X_TESLAUSB_REQUEST=1 HTTP_SEC_FETCH_SITE=same-origin HTTP_ORIGIN=http://teslausb.local \
    run_recording_fixture api-v1.sh POST "/api/v1/trash/$trash_action")"
  assert_contains "protected Trash POST dispatches only $trash_action" "$response" "fixture-operation: $trash_action"
done
response="$(HTTP_X_TESLAUSB_REQUEST=1 HTTP_SEC_FETCH_SITE=same-origin \
  run_recording_fixture api-v1.sh POST /api/v1/recordings/preview 'path=fixture')"
assert_contains 'protected preview POST dispatches its generation operation' "$response" 'fixture-operation: preview-request'
response="$(HTTP_X_TESLAUSB_REQUEST='' HTTP_SEC_FETCH_SITE=same-origin \
  run_recording_fixture api-v1.sh GET /api/v1/recordings/preview 'path=fixture')"
assert_contains 'preview GET dispatches status without starting generation' "$response" 'fixture-operation: preview-status'
response="$(HTTP_SEC_FETCH_SITE=same-origin \
  run_recording_fixture api-v1.sh GET /api/v1/trash/download 'id=fixture&camera=all')"
assert_contains 'Trash downloads reach the original media helper' "$response" 'fixture-operation: trash-download'
response="$(HTTP_SEC_FETCH_SITE=same-origin \
  run_recording_fixture api-v1.sh GET /api/v1/trash/media 'id=fixture&file=fixture')"
assert_contains 'Trash playback reaches the private playback helper' "$response" 'fixture-operation: media'

# Direct Python helpers have no HTTP method/origin boundary of their own. Nginx
# must deny both the exact helper URL and every path-info suffix before fcgiwrap.
if python3 - "$cgi_dir/../../teslausb.nginx" <<'PYTHON'
import pathlib
import re
import sys

config = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
marker = 'location ~ ^/cgi-bin/.*\\.py(?:/|$) {'
assert marker in config, 'Python helper deny rule must cover path-info suffixes'
block = config.split(marker, 1)[1].split('}', 1)[0]
assert 'deny all;' in block
assert 'location ^~ /cgi-bin/' not in config, 'A priority prefix must not bypass regex denial'
pattern = re.compile(r'^/cgi-bin/.*\.py(?:/|$)')
for name in ('recording-trash.py', 'recording-media.py', 'maintenance.py'):
    for suffix in ('', '/cleanup', '/preview-worker'):
        assert pattern.search('/cgi-bin/' + name + suffix)
assert 'fastcgi_param SCRIPT_FILENAME /var/www/html/cgi-bin/api-v1.sh;' in config
assert 'fastcgi_param PATH_INFO $uri;' in config
PYTHON
then
  pass 'nginx blocks direct Python helpers and pins the versioned dispatcher'
else
  fail 'nginx blocks direct Python helpers and pins the versioned dispatcher'
fi

response="$(run_api GET '/api/v1/actions/drives/repair')"
assert_contains 'manual gadget repair rejects GET requests' "$response" 'Status: 405 Method Not Allowed'

mkdir -p "$test_dir/fake-sudo"
# shellcheck disable=SC2016 # These lines form an isolated fixture executable.
printf '%s\n' \
  '#!/bin/sh' \
  '[ "$*" = "-n /usr/local/sbin/teslausb-web-sudo gadget-repair" ] || exit 99' \
  'printf "fixture repair completed\n"' > "$test_dir/fake-sudo/sudo"
chmod +x "$test_dir/fake-sudo/sudo"
response="$(PATH="$test_dir/fake-sudo:$PATH" run_api POST '/api/v1/actions/drives/repair')"
assert_contains 'manual gadget repair accepts a protected POST request' "$response" 'Status: 200 OK'
assert_contains 'manual gadget repair returns a structured success' "$response" '"ok":true'

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
