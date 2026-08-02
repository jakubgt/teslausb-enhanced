#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_html_escape "${1:-}"
cgi_headers '200 OK' 'text/html; charset=utf-8'
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
