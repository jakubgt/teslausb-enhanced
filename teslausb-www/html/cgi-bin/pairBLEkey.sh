#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_mutation

message=$(sudo -n /usr/local/sbin/teslausb-web-sudo ble-pair 2>&1)
result=$?

status_code="202 Accepted"
output="Pairing initiated."

if [[ $result -ne 0 ]]
then
  status_code="502 Bad Gateway"
  output="Failed to send pairing request. $message"
fi

if [[ "${TESLAUSB_API_RESPONSE:-}" == json ]]
then
  if [[ $result -eq 0 ]]
  then
    cgi_ok "$output" "$status_code"
  else
    cgi_error "$status_code" "$output"
  fi
else
  cgi_html_escape "$output"
  cgi_headers "$status_code" 'text/html; charset=utf-8'
  cat << EOF

<html>
<head>
  <meta http-equiv="refresh" content="3; URL=/" />
</head>
<body>
  <p>$CGI_ESCAPED</p>
</body>
</html>
EOF
fi
