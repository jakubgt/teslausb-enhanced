#!/bin/bash -eu

# Based on: https://blog.thewalr.us/2017/09/26/raspberry-pi-zero-w-simultaneous-ap-and-managed-mode-wifi/

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
    WLAN="$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep -v ":ap0$" | cut -c 17-)"
    if [ -n "$WLAN" ]
    then
      break;
    fi
    log_progress "Waiting for WiFi interface to come back up"
    sleep 5
  done

  [ -n "$WLAN" ] && return 0

  log_progress "Couldn't determine WiFi client device"
  nmcli c show
  return 1
}

function nm_add_ap () {
  nm_get_wifi_client_device || return 1

  if [ "$WLAN" = "wlan1" ]; then
    log_progress "Checking if wlan1 can switch to AP mode"

    if iw list | grep -q '* AP'; then
      log_progress "wlan1 supports AP mode, attempting switch"
      nmcli dev set wlan1 managed no

      # Ensure we don't disconnect SSH if wlan1 is the only active interface
      if nmcli device status | grep -q "wlan0.*connected"; then
        ip link set wlan1 down
        iw dev wlan1 set type __ap
        ip link set wlan1 up
      else
        log_progress "wlan1 is the only active connection, skipping AP mode switch to prevent SSH disconnection"
        WLAN="wlan0"  # Fall back to wlan0
      fi
    else
      log_progress "wlan1 does NOT support AP mode. Falling back to wlan0."
      WLAN="wlan0"
    fi
  fi

  if ! iw dev ap0 info &> /dev/null
  then
    iw dev "$WLAN" interface add ap0 type __ap || return 1
  fi

  # Disable power saving mode
  iw "$WLAN" set power_save off || return 1
  iw ap0 set power_save off || return 1

  # Get wlan1’s current channel
  WLAN1_CHANNEL=$(iw dev wlan1 info | grep channel | awk '{print $2}')

  if [ -z "$WLAN1_CHANNEL" ]; then
    WLAN1_CHANNEL=6  # Default to 6 if detection fails
  fi

  # Determine frequency band (2.4GHz or 5GHz)
  if [ "$WLAN1_CHANNEL" -gt 14 ]; then
    HW_MODE="a"  # Use "a" for 5GHz
  else
    HW_MODE="g"  # Use "g" for 2.4GHz
  fi

  # Set up the AP
  cat <<- EOF > /etc/hostapd/hostapd.conf
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
interface=ap0
driver=nl80211
ssid=${AP_SSID}
hw_mode=${HW_MODE}
channel=${WLAN1_CHANNEL}
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=${AP_PASS}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
EOF

  log_progress "AP setup completed on $WLAN."
}

if systemctl --quiet is-enabled NetworkManager.service
then
  apt-get -y install iw || return 1
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

log_progress "Configuring AP on $WLAN with dynamically detected channel"

# Apply udev rules to allow wlan1 AP mode like wlan0
if [ "$WLAN" = "wlan1" ]; then
  log_progress "Using wlan1 for AP"
  MAC="$(cat /sys/class/net/wlan1/address)"
else
  log_progress "Using wlan0 for AP"
  MAC="$(cat /sys/class/net/wlan0/address)"
fi

cat <<- EOF > /etc/udev/rules.d/70-persistent-net.rules
SUBSYSTEM=="ieee80211", ACTION=="add|change", ATTR{macaddress}=="$MAC", KERNEL=="phy1", \
RUN+="/sbin/iw phy phy1 interface add ap0 type __ap", \
RUN+="/bin/ip link set ap0 address $MAC"
EOF

udevadm control --reload-rules && udevadm trigger

log_progress "AP mode setup complete"
