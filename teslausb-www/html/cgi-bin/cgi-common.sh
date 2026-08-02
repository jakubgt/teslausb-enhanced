#!/bin/bash

# Shared helpers for the legacy TeslaUSB CGI endpoints.  Keep all request
# parsing and path validation here so every filesystem operation applies the
# same boundary checks.

declare -ag CGI_ARGS=()
CGI_DOCUMENT_ROOT=
CGI_ALLOWED_BASE=
CGI_ROOT=
CGI_PATH=
CGI_RELATIVE_PATH=
CGI_DECODED=
CGI_REQUEST_HOST=
CGI_REQUEST_PORT=
# These are explicit return values for scripts that source this helper.
# shellcheck disable=SC2034
CGI_ESCAPED=
# shellcheck disable=SC2034
CGI_JSON=

cgi_header_start() {
  local status="$1"
  local content_type="$2"

  printf 'Status: %s\r\n' "$status"
  printf 'Content-Type: %s\r\n' "$content_type"
  printf 'Cache-Control: no-store\r\n'
  printf 'X-Content-Type-Options: nosniff\r\n'
  printf 'Referrer-Policy: same-origin\r\n'
  if [[ -n "${TESLAUSB_API_VERSION:-}" ]]
  then
    printf 'X-TeslaUSB-API-Version: %s\r\n' "$TESLAUSB_API_VERSION"
  fi
}

cgi_headers() {
  cgi_header_start "$1" "$2"
  printf '\r\n'
}

cgi_error() {
  local status="$1"
  local message="$2"

  if [[ "${TESLAUSB_API_RESPONSE:-}" == json ]]
  then
    cgi_json_quote "$message"
    cgi_headers "$status" 'application/json; charset=utf-8'
    printf '{"ok":false,"error":%s}\n' "$CGI_JSON"
  else
    cgi_headers "$status" 'text/plain; charset=utf-8'
    printf '%s\n' "$message"
  fi
  exit 0
}

cgi_ok() {
  local message="${1:-OK}"
  local status="${2:-200 OK}"

  if [[ "${TESLAUSB_API_RESPONSE:-}" == json ]]
  then
    cgi_json_quote "$message"
    cgi_headers "$status" 'application/json; charset=utf-8'
    printf '{"ok":true,"message":%s}\n' "$CGI_JSON"
  else
    cgi_headers "$status" 'text/plain; charset=utf-8'
    printf 'OK\n'
  fi
}

cgi_require_method() {
  local expected="$1"

  if [[ "${REQUEST_METHOD:-GET}" != "$expected" ]]
  then
    cgi_error '405 Method Not Allowed' "This endpoint requires $expected."
  fi
}

cgi_host_without_port() {
  local authority="$1"
  local port

  CGI_REQUEST_PORT=

  # Reject syntax which can make one authority look like another to a proxy,
  # log parser, or URL parser. IPv6 literals must use their bracketed form.
  if [[ -z "$authority" || "$authority" =~ [[:space:]/\\,@] ]]
  then
    return 1
  fi
  if [[ "$authority" =~ ^\[([^][]+)\](:([0-9]{1,5}))?$ ]]
  then
    CGI_REQUEST_HOST="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]}"
    if [[ -n "$port" ]]
    then
      (( 10#$port <= 65535 )) || return 1
      CGI_REQUEST_PORT="$((10#$port))"
    fi
  else
    if [[ "$authority" == *:* ]]
    then
      [[ "$authority" != *:*:* ]] || return 1
      CGI_REQUEST_HOST="${authority%:*}"
      port="${authority##*:}"
      [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
      (( 10#$port <= 65535 )) || return 1
      CGI_REQUEST_PORT="$((10#$port))"
    else
      CGI_REQUEST_HOST="$authority"
    fi
  fi
  CGI_REQUEST_HOST="${CGI_REQUEST_HOST,,}"
  CGI_REQUEST_HOST="${CGI_REQUEST_HOST%.}"
  if [[ "$CGI_REQUEST_HOST" == *:* ]]
  then
    [[ "$CGI_REQUEST_HOST" =~ ^[0-9a-f:]+$ ]] || return 1
  else
    [[ "$CGI_REQUEST_HOST" =~ ^[a-z0-9.-]+$ ]] || return 1
  fi
}

cgi_ipv4_is_private() {
  local host="$1"
  local first
  local second
  local third
  local fourth

  [[ "$host" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  first=$((10#${BASH_REMATCH[1]}))
  second=$((10#${BASH_REMATCH[2]}))
  third=$((10#${BASH_REMATCH[3]}))
  fourth=$((10#${BASH_REMATCH[4]}))
  (( first <= 255 && second <= 255 && third <= 255 && fourth <= 255 )) || return 1
  (( first == 10 ||
     first == 127 ||
     (first == 169 && second == 254) ||
     (first == 172 && second >= 16 && second <= 31) ||
     (first == 192 && second == 168) ))
}

cgi_host_is_allowed() {
  local host="${1,,}"
  local allowed
  local allowed_hosts="${WEB_ALLOWED_HOSTS:-}"
  local normalized_allowed
  local original_request_host="$CGI_REQUEST_HOST"
  local original_request_port="$CGI_REQUEST_PORT"
  local effective_request_port="$CGI_REQUEST_PORT"
  local normalized_allowed_port
  local -a allowed_entries=()

  case "$host" in
    localhost|teslausb|raspberrypi|*.local|::1)
      return 0
      ;;
  esac
  # ULA and link-local IPv6 literals are local, but the prefix must not make
  # similarly named DNS hosts (for example, fd-attacker.example) trusted.
  if [[ "$host" == *:* ]]
  then
    case "$host" in
      fc*|fd*|fe8*|fe9*|fea*|feb*) return 0 ;;
    esac
  fi
  if cgi_ipv4_is_private "$host"
  then
    return 0
  fi
  # Single-label names are used by mDNS/NetBIOS-style local discovery. A
  # dotted custom or Tailscale name must be opted in explicitly.
  if [[ "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
  then
    return 0
  fi
  allowed_hosts="${allowed_hosts//,/ }"
  if [[ -z "$effective_request_port" &&
        "${SERVER_PORT:-}" =~ ^[0-9]{1,5}$ ]] &&
     (( 10#${SERVER_PORT} <= 65535 ))
  then
    effective_request_port="$((10#${SERVER_PORT}))"
  fi
  read -r -a allowed_entries <<< "$allowed_hosts"
  for allowed in "${allowed_entries[@]}"
  do
    if cgi_host_without_port "$allowed"
    then
      normalized_allowed="$CGI_REQUEST_HOST"
      normalized_allowed_port="$CGI_REQUEST_PORT"
    else
      CGI_REQUEST_HOST="$original_request_host"
      CGI_REQUEST_PORT="$original_request_port"
      continue
    fi
    CGI_REQUEST_HOST="$original_request_host"
    CGI_REQUEST_PORT="$original_request_port"
    if [[ "$normalized_allowed" == "$host" &&
          ( -z "$normalized_allowed_port" ||
            "$normalized_allowed_port" == "$effective_request_port" ) ]]
    then
      return 0
    fi
  done
  CGI_REQUEST_HOST="$original_request_host"
  CGI_REQUEST_PORT="$original_request_port"
  return 1
}

cgi_validate_host() {
  local authority="${HTTP_HOST:-}"

  # Direct execution by tests and maintenance scripts has no CGI host. Nginx
  # supplies HTTP_HOST for browser/API requests, which is the boundary this
  # check protects.
  if [[ -z "$authority" ]]
  then
    [[ -z "${GATEWAY_INTERFACE:-}" ]] && return 0
    cgi_error '400 Bad Request' 'A Host header is required.'
  fi
  if ! cgi_host_without_port "$authority" ||
     ! cgi_host_is_allowed "$CGI_REQUEST_HOST"
  then
    cgi_error '421 Misdirected Request' 'The requested host is not allowed.'
  fi
}

cgi_url_matches_request_host() {
  local url="$1"
  local authority
  local host
  local port
  local request_host
  local request_port
  local request_scheme
  local url_scheme

  [[ "$url" =~ ^(https?)://([^/]+)(/|$) ]] || return 1
  url_scheme="${BASH_REMATCH[1]}"
  authority="${BASH_REMATCH[2]}"
  cgi_host_without_port "$authority" || return 1
  host="$CGI_REQUEST_HOST"
  port="$CGI_REQUEST_PORT"
  cgi_host_without_port "${HTTP_HOST:-}" || return 1
  request_host="$CGI_REQUEST_HOST"
  request_port="$CGI_REQUEST_PORT"

  if [[ -n "${REQUEST_SCHEME:-}" ]]
  then
    request_scheme="${REQUEST_SCHEME,,}"
  elif [[ "${HTTPS:-off}" == on || "${SERVER_PORT:-}" == 443 ]]
  then
    request_scheme=https
  else
    request_scheme=http
  fi
  if [[ -z "$port" ]]
  then
    [[ "$url_scheme" == https ]] && port=443 || port=80
  fi
  if [[ -z "$request_port" ]]
  then
    if [[ "${SERVER_PORT:-}" =~ ^[0-9]+$ ]]
    then
      request_port="$SERVER_PORT"
    elif [[ "$request_scheme" == https ]]
    then
      request_port=443
    else
      request_port=80
    fi
  fi
  [[ "$url_scheme" == "$request_scheme" &&
     "$host" == "$request_host" && "$port" == "$request_port" ]]
}

cgi_reject_cross_site() {
  local site="${HTTP_SEC_FETCH_SITE:-}"

  case "$site" in
    ''|same-origin|same-site|none) ;;
    *) cgi_error '403 Forbidden' 'Cross-site requests are not allowed.' ;;
  esac
  if [[ -n "${HTTP_ORIGIN:-}" ]] &&
     ! cgi_url_matches_request_host "$HTTP_ORIGIN"
  then
    cgi_error '403 Forbidden' 'The request origin is not allowed.'
  fi
}

cgi_require_mutation() {
  local method="${REQUEST_METHOD:-GET}"
  local has_same_origin_evidence=no

  cgi_reject_cross_site
  case "$method" in
    POST)
      if [[ "${HTTP_X_TESLAUSB_REQUEST:-}" != 1 ]]
      then
        cgi_error '403 Forbidden' 'The X-TeslaUSB-Request header is required.'
      fi
      ;;
    GET)
      # Temporary compatibility for the separately distributed WebUI, which
      # historically issued GETs for actions. Browsers must prove that the
      # request came from this device. CLI clients should migrate to the v1
      # POST route rather than relying on an unverifiable GET.
      if [[ "${HTTP_SEC_FETCH_SITE:-}" == same-origin ]]
      then
        has_same_origin_evidence=yes
      elif [[ -n "${HTTP_ORIGIN:-}" ]] &&
           cgi_url_matches_request_host "$HTTP_ORIGIN"
      then
        has_same_origin_evidence=yes
      elif [[ -n "${HTTP_REFERER:-}" ]] &&
           cgi_url_matches_request_host "$HTTP_REFERER"
      then
        has_same_origin_evidence=yes
      fi
      if [[ "$has_same_origin_evidence" != yes ]]
      then
        cgi_error '403 Forbidden' 'Legacy GET actions require a same-origin browser request.'
      fi
      printf 'Warning: 299 TeslaUSB "GET mutations are deprecated; use POST /api/v1"\r\n'
      printf 'Deprecation: true\r\n'
      ;;
    *)
      cgi_error '405 Method Not Allowed' 'This endpoint requires POST.'
      ;;
  esac
}

cgi_percent_decode() {
  local rest="$1"
  local output=
  local prefix
  local hex
  local decoded

  rest="${rest//+/ }"
  while [[ "$rest" == *%* ]]
  do
    prefix="${rest%%\%*}"
    rest="${rest#*%}"
    if [[ ! "$rest" =~ ^([[:xdigit:]]{2})(.*)$ ]]
    then
      return 1
    fi
    hex="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
    # Bash variables cannot represent NUL bytes. Reject them explicitly
    # instead of silently truncating a path.
    if [[ "$hex" == '00' ]]
    then
      return 1
    fi
    printf -v decoded '%b' "\\x$hex"
    output+="$prefix$decoded"
  done
  output+="$rest"

  # Control characters make the line-oriented zip/list protocols ambiguous
  # and can also corrupt CGI headers and logs.
  if [[ "$output" =~ [[:cntrl:]] ]]
  then
    return 1
  fi

  CGI_DECODED="$output"
}

cgi_parse_query() {
  local minimum="$1"
  local maximum="$2"
  local remainder="${QUERY_STRING:-}"
  local item
  local more=yes

  CGI_ARGS=()
  while [[ "$more" == yes ]]
  do
    if [[ "$remainder" == *'&'* ]]
    then
      item="${remainder%%&*}"
      remainder="${remainder#*&}"
    else
      item="$remainder"
      more=no
    fi

    if ! cgi_percent_decode "$item"
    then
      cgi_error '400 Bad Request' 'The query string contains invalid percent encoding.'
    fi
    CGI_ARGS+=("$CGI_DECODED")
  done

  if (( ${#CGI_ARGS[@]} < minimum )) ||
     (( maximum >= 0 && ${#CGI_ARGS[@]} > maximum ))
  then
    cgi_error '400 Bad Request' 'The query string has the wrong number of arguments.'
  fi
}

cgi_resolve_root() {
  local requested="$1"
  local base_relative
  local base_resolved
  local resolved

  case "$requested" in
    fs/Music|fs/Music/*)
      base_relative='fs/Music'
      ;;
    fs/LightShow|fs/LightShow/*)
      base_relative='fs/LightShow'
      ;;
    fs/Boombox|fs/Boombox/*)
      base_relative='fs/Boombox'
      ;;
    *)
      cgi_error '403 Forbidden' 'The requested filesystem root is not allowed.'
      ;;
  esac

  if [[ -z "${DOCUMENT_ROOT:-}" ]]
  then
    cgi_error '500 Internal Server Error' 'DOCUMENT_ROOT is not configured.'
  fi
  if ! CGI_DOCUMENT_ROOT="$(realpath -e -- "$DOCUMENT_ROOT" 2>/dev/null)"
  then
    cgi_error '500 Internal Server Error' 'The document root is unavailable.'
  fi
  if ! base_resolved="$(realpath -e -- "$CGI_DOCUMENT_ROOT/$base_relative" 2>/dev/null)" ||
     [[ ! -d "$base_resolved" ]]
  then
    cgi_error '404 Not Found' 'The requested filesystem root is unavailable.'
  fi
  case "$base_resolved" in
    "$CGI_DOCUMENT_ROOT"/*)
      CGI_ALLOWED_BASE="$base_resolved"
      ;;
    *)
      cgi_error '403 Forbidden' 'The allowed filesystem root escapes the document root.'
      ;;
  esac

  if ! resolved="$(realpath -e -- "$CGI_DOCUMENT_ROOT/$requested" 2>/dev/null)" ||
     [[ ! -d "$resolved" ]]
  then
    cgi_error '404 Not Found' 'The requested filesystem root is unavailable.'
  fi

  if [[ "$resolved" == "$CGI_ALLOWED_BASE" || "$resolved" == "$CGI_ALLOWED_BASE/"* ]]
  then
      CGI_ROOT="$resolved"
  else
    cgi_error '403 Forbidden' 'The requested filesystem root escapes its allowed filesystem.'
  fi
}

cgi_resolve_path() {
  local relative="$1"
  local allow_root="${2:-no}"
  local resolved

  if [[ -z "$relative" || "$relative" == /* ]]
  then
    cgi_error '400 Bad Request' 'Paths must be non-empty and relative.'
  fi
  if ! resolved="$(realpath -m -- "$CGI_ROOT/$relative" 2>/dev/null)"
  then
    cgi_error '400 Bad Request' 'The requested path is invalid.'
  fi

  if [[ "$resolved" == "$CGI_ROOT" ]]
  then
    if [[ "$allow_root" != yes ]]
    then
      cgi_error '403 Forbidden' 'The filesystem root itself cannot be modified.'
    fi
  elif [[ "$resolved" != "$CGI_ROOT/"* ]]
  then
    cgi_error '403 Forbidden' 'The requested path escapes the allowed filesystem root.'
  fi

  CGI_PATH="$resolved"
  if [[ "$resolved" == "$CGI_ROOT" ]]
  then
    CGI_RELATIVE_PATH='.'
  else
    CGI_RELATIVE_PATH="${resolved#"$CGI_ROOT"/}"
  fi
}

cgi_reject_final_symlink() {
  local relative="$1"

  if [[ -L "$CGI_ROOT/$relative" ]]
  then
    cgi_error '403 Forbidden' 'Symbolic links are not accepted by this endpoint.'
  fi
}

cgi_require_existing() {
  local kind="${1:-any}"

  case "$kind" in
    file)
      [[ -f "$CGI_PATH" ]] || cgi_error '404 Not Found' 'The requested file was not found.'
      ;;
    directory)
      [[ -d "$CGI_PATH" ]] || cgi_error '404 Not Found' 'The requested directory was not found.'
      ;;
    any)
      [[ -e "$CGI_PATH" ]] || cgi_error '404 Not Found' 'The requested path was not found.'
      ;;
    *)
      cgi_error '500 Internal Server Error' 'Invalid path-type check.'
      ;;
  esac
}

cgi_html_escape() {
  local input="$1"
  local output=
  local character
  local i

  for ((i=0; i<${#input}; i++))
  do
    character="${input:i:1}"
    case "$character" in
      '&') output+='&amp;' ;;
      '<') output+='&lt;' ;;
      '>') output+='&gt;' ;;
      '"') output+='&quot;' ;;
      "'") output+='&#39;' ;;
      *) output+="$character" ;;
    esac
  done
  CGI_ESCAPED="$output"
}

cgi_json_quote() {
  local LC_ALL=C
  local input="$1"
  local output='"'
  local character
  local escaped
  local code
  local i

  for ((i=0; i<${#input}; i++))
  do
    character="${input:i:1}"
    case "$character" in
      '"') output+='\"' ;;
      '\') output+='\\' ;;
      $'\b') output+='\b' ;;
      $'\f') output+='\f' ;;
      $'\n') output+='\n' ;;
      $'\r') output+='\r' ;;
      $'\t') output+='\t' ;;
      *)
        printf -v code '%d' "'$character"
        if (( code < 32 || code == 127 ))
        then
          printf -v escaped '\\u%04x' "$code"
          output+="$escaped"
        else
          output+="$character"
        fi
        ;;
    esac
  done
  output+='"'
  CGI_JSON="$output"
}

if [[ -n "${GATEWAY_INTERFACE:-}${HTTP_HOST:-}" ]]
then
  cgi_validate_host
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]
then
  cgi_error '404 Not Found' 'Not found.'
fi
