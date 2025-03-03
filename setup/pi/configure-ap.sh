#!/bin/bash -eu

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "configure-ap: $1"
  else
    echo "configure-ap: $1"
  fi
}

if [ -z "${AP_SSID+x}" ]
then
  log_progress "AP_SSID not set"
  exit 1
fi

if [ -z "${AP_PASS+x}" ] || [ "$AP_PASS" = "password" ] || (( ${#AP_PASS} < 8))
then
  log_progress "AP_PASS not set, not changed from default, or too short"
  exit 1
fi

function nm_get_wifi_client_device () {
  for i in {1..5}
  do
    # Prioritize external adapter (wlan1) for regular WiFi use
    WLAN_CLIENT="$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep -v ":ap0$" | grep -v "wlan0" | awk -F: '{print $2}' | head -n 1)"

    if [ -n "$WLAN_CLIENT" ]; then
      log_progress "Using external WiFi adapter for internet: $WLAN_CLIENT"
      break
    fi

    # Fallback: Use wlan0 for client if no external adapter is found
    if [ -z "$WLAN_CLIENT" ] && [ -n "$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep 'wlan0' | awk -F: '{print $2}')" ]; then
      WLAN_CLIENT="wlan0"
      log_progress "No external adapter found, using built-in WiFi: wlan0"
      break
    fi

    log_progress "Waiting for WiFi interface to come back up..."
    sleep 5
  done

  if [ -z "$WLAN_CLIENT" ]; then
    log_progress "Couldn't determine WiFi client device."
    nmcli c show
    return 1
  fi
}

function nm_add_ap () {
  nm_get_wifi_client_device || return 1

  # Set wlan0 as the AP device
  WLAN_AP="wlan0"
  log_progress "Using $WLAN_AP for AP mode (ap0)."

  log_progress "Ensuring $WLAN_AP is up before creating AP..."
  ip link set "$WLAN_AP" up
  sleep 2

  if ! iw dev ap0 info &> /dev/null
  then
    log_progress "Creating AP interface on $WLAN_AP..."
    if iw dev "$WLAN_AP" interface add ap0 type __ap; then
      log_progress "AP interface ap0 successfully created on $WLAN_AP."
    else
      log_progress "ERROR: AP creation failed on $WLAN_AP! AP mode will not be available."
      return 1
    fi
  fi

  iw "$WLAN_AP" set power_save off || return 1
  iw ap0 set power_save off || return 1

  nmcli con delete TESLAUSB_AP &> /dev/null || true
  nmcli con add type wifi ifname ap0 mode ap con-name TESLAUSB_AP ssid "$AP_SSID" || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.psk "$AP_PASS" || return 1
  IP=${AP_IP:-"192.168.66.1"}
  nmcli con modify TESLAUSB_AP ipv4.addr "$IP/24" || return 1
  nmcli con modify TESLAUSB_AP ipv4.method shared || return 1
  nmcli con modify TESLAUSB_AP ipv6.method disabled || return 1

  MAC="$(cat /sys/class/net/$WLAN_AP/address)"

  cat > /etc/network/if-up.d/teslausb-ap << EOF
#!/bin/bash

if [ "\$IFACE" = "$WLAN_AP" ]
then
  iw dev $WLAN_AP interface add ap0 type __ap
  iw "$WLAN_AP" set power_save off
  iw ap0 set power_save off
  nmcli con up TESLAUSB_AP
fi

EOF
  chmod a+x /etc/network/if-up.d/teslausb-ap || return 1
}

if systemctl --quiet is-enabled NetworkManager.service
then
  apt-get -y --force-yes install iw || return 1
  if ! nm_add_ap
  then
    log_progress "Retrying after restarting Network Manager"
    systemctl restart NetworkManager.service
    if ! nm_add_ap
    then
      log_progress "STOP: Failed to configure AP"
      exit 1
    fi
  fi
  log_progress "AP configured"
  exit 0
fi
