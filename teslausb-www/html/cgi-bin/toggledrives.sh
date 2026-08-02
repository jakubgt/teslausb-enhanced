#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

cgi_require_mutation

if [ -e "/sys/kernel/config/usb_gadget/teslausb/" ]
then
  action=gadget-disable
else
  action=gadget-enable
fi

if ! sudo -n /usr/local/sbin/teslausb-web-sudo "$action" &> /dev/null
then
  cgi_error '500 Internal Server Error' 'Unable to change the USB gadget state.'
fi

cgi_ok 'USB gadget state changed.'
