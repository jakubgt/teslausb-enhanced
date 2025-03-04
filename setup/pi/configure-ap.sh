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
    WLAN="$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep -v ":ap0$" | grep "wlan1" | cut -c 17-)"
    if [ -z "$WLAN" ]; then
      WLAN="$(nmcli -t -f TYPE,DEVICE c show --active | grep 802-11-wireless | grep -v ":ap0$" | grep "wlan0" | cut -c 17-)"
    fi
    if [ -n "$WLAN" ]
    then
      break;
    fi
    log_progress "Waiting for wifi interface to come back up"
    sleep 5
  done

  [ -n "$WLAN" ] && return 0

  log_progress "Couldn't determine wifi client device"
  nmcli c show
  return 1
}

function nm_add_ap () {
  nm_get_wifi_client_device || return 1

  if ! iw dev ap0 info &> /dev/null
  then
    # Create additional virtual interface for the wifi device
    iw dev "$WLAN" interface add ap0 type __ap || return 1
  fi

  # Disable power saving for AP
  iw "$WLAN" set power_save off || return 1
  iw ap0 set power_save off || return 1

  nmcli con delete TESLAUSB_AP &> /dev/null || true
  nmcli con add type wifi ifname ap0 mode ap con-name TESLAUSB_AP ssid "$AP_SSID" || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.key-mgmt wpa-psk || return 1
  nmcli con modify TESLAUSB_AP 802-11-wireless-security.psk "$AP_PASS" || return 1
  IP=${AP_IP:-"192.168.66.1"}
  nmcli con modify TESLAUSB_AP ipv4.addr "$IP/24" || return 1
  nmcli con modify TESLAUSB_AP ipv4.method shared || return 1
  nmcli con modify TESLAUSB_AP ipv6.method disabled || return 1

  cat > /etc/network/if-up.d/teslausb-ap << EOF
#!/bin/bash

if [ "\$IFACE" = "$WLAN" ]
then
  iw dev $WLAN interface add ap0 type __ap
  iw "$WLAN" set power_save off
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

if [ ! -e /etc/wpa_supplicant/wpa_supplicant.conf ]
then
  log_progress "No wpa_supplicant, skipping AP setup."
  exit 0
fi

if ! grep -q id_str /etc/wpa_supplicant/wpa_supplicant.conf
then
  IP=${AP_IP:-"192.168.66.1"}
  NET=$(echo -n "$IP" | sed -e 's/\.[0-9]\{1,3\}$//')

  log_progress "installing dnsmasq and hostapd"
  apt-get -y --force-yes install dnsmasq hostapd

  log_progress "configuring AP '$AP_SSID' with IP $IP"
  MAC="$(cat /sys/class/net/wlan1/address 2>/dev/null || cat /sys/class/net/wlan0/address)"
  cat <<- EOF > /etc/udev/rules.d/70-persistent-net.rules
	SUBSYSTEM=="ieee80211", ACTION=="add|change", ATTR{macaddress}=="$MAC", KERNEL=="phy0", \
	RUN+="/sbin/iw phy phy0 interface add ap0 type __ap", \
	RUN+="/bin/ip link set ap0 address $MAC"
	EOF

  cat <<- EOF > /etc/dnsmasq.conf
	interface=lo,ap0
	no-dhcp-interface=lo,wlan1,wlan0
	bind-interfaces
	bogus-priv
	dhcp-range=${NET}.10,${NET}.254,12h
	dhcp-option=3
	EOF

  cat <<- EOF > /etc/hostapd/hostapd.conf
	ctrl_interface=/var/run/hostapd
	ctrl_interface_group=0
	interface=ap0
	driver=nl80211
	ssid=${AP_SSID}
	hw_mode=g
	channel=11
	wmm_enabled=0
	macaddr_acl=0
	auth_algs=1
	wpa=2
	wpa_passphrase=${AP_PASS}
	wpa_key_mgmt=WPA-PSK
	wpa_pairwise=TKIP CCMP
	rsn_pairwise=CCMP
	EOF
  cat <<- EOF > /etc/default/hostapd
	DAEMON_CONF="/etc/hostapd/hostapd.conf"
	EOF

  cat <<- EOF > /etc/network/interfaces
	source-directory /etc/network/interfaces.d

	auto lo
	auto ap0
	auto wlan1
	auto wlan0
	iface lo inet loopback

	allow-hotplug ap0
	iface ap0 inet static
	    address ${IP}
	    netmask 255.255.255.0
	    hostapd /etc/hostapd/hostapd.conf

	allow-hotplug wlan1
	iface wlan1 inet manual
	    wpa-roam /etc/wpa_supplicant/wpa_supplicant.conf
	iface AP1 inet dhcp

	allow-hotplug wlan0
	iface wlan0 inet manual
	    wpa-roam /etc/wpa_supplicant/wpa_supplicant.conf
	iface AP2 inet dhcp
	EOF

  cat <<- EOF >> /etc/dhcpcd.conf
	interface ap0
	nohook wpa_supplicant
	EOF
else
  log_progress "AP mode already configured"
fi
