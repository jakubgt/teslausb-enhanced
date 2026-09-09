#!/bin/bash -eu

# setup-teslausb exports SOURCE_DIR and the helper functions used below.
: "${SOURCE_DIR:?SOURCE_DIR must be exported by setup-teslausb}"

if [[ -v WEB_PASSWORD ]]
then
  export -n WEB_PASSWORD
fi

recording_encoder_available() {
  local encoder_list flags encoder

  [ -x /usr/bin/ffmpeg ] || return 1
  if ! encoder_list="$(timeout 10 /usr/bin/ffmpeg -hide_banner -encoders 2>/dev/null)"
  then
    return 1
  fi
  while read -r flags encoder _
  do
    if [[ "$flags" =~ ^V[A-Z.]{5}$ ]] && [ "$encoder" = mjpeg ]
    then
      return 0
    fi
  done <<< "$encoder_list"
  return 1
}

configure_optional_recording_encoder() {
  # Release images already contain the verified distro encoder. Older images
  # may install it here, but unavailable optional packages must not prevent
  # authenticated web access, Trash cleanup, or original-quality playback.
  if recording_encoder_available
  then
    return 0
  fi
  setup_progress "Installing optional recording thumbnail encoder"
  if DEBIAN_FRONTEND=noninteractive apt-get -y install ffmpeg
  then
    if ! recording_encoder_available
    then
      setup_progress "WARNING: recording thumbnail encoder is unavailable after package installation. Original-quality playback and downloads remain available."
    fi
  else
    setup_progress "WARNING: optional ffmpeg installation failed. Recording thumbnails may be unavailable; continuing web and Trash setup. Original-quality playback and downloads remain available."
  fi
  return 0
}

validate_webui_archive() {
  local archive="$1"
  local listing_file="$2"
  local verbose_listing_file="$3"
  local archive_entry
  local archive_line
  local archive_type

  # Use escaped listings and reject every escaped name. This deliberately
  # excludes control characters and backslashes as well as path traversal.
  tar --gzip --list --file "$archive" --quoting-style=escape > "$listing_file"
  [ -s "$listing_file" ] || {
    echo "Web UI archive is empty" >&2
    return 1
  }

  while IFS= read -r archive_entry
  do
    case "$archive_entry" in
      new|new/|new/*)
        ;;
      *)
        echo "Web UI archive contains an unexpected path: $archive_entry" >&2
        return 1
        ;;
    esac

    case "/$archive_entry/" in
      *\\*|*'//'*|*'/../'*|*'/./'*)
        echo "Web UI archive contains an unsafe path: $archive_entry" >&2
        return 1
        ;;
    esac
  done < "$listing_file"

  # The UI is static content and should never need links, devices, sockets, or
  # other special archive members. Rejecting them also prevents link traversal
  # during extraction by older tar versions.
  tar --gzip --verbose --list --file "$archive" \
    --quoting-style=escape > "$verbose_listing_file"
  while IFS= read -r archive_line
  do
    archive_type="${archive_line:0:1}"
    case "$archive_type" in
      -|d)
        ;;
      *)
        echo "Web UI archive contains a non-file member: $archive_line" >&2
        return 1
        ;;
    esac
  done < "$verbose_listing_file"
}

teslausb_webui_stage_dir=

cleanup_webui_stage() {
  case "$teslausb_webui_stage_dir" in
    /var/www/.teslausb-webui-stage.*)
      rm -rf -- "$teslausb_webui_stage_dir"
      ;;
  esac
}

install_webui() {
  local webui_release="${WEBUI_RELEASE:-}"
  local webui_expected_sha256="${WEBUI_SHA256:-}"
  local webui_url
  local webui_archive
  local webui_actual_sha256
  local webui_verification
  local webui_extract_dir
  local webui_store=/var/www/teslausb-webui
  local webui_release_dir
  local webui_next_link
  local webui_metadata

  if [ -z "$webui_release" ] && [ -z "$webui_expected_sha256" ]
  then
    if [ -e /var/www/html/new ] || [ -L /var/www/html/new ]
    then
      setup_progress "No pinned external WebUI configured; using the bundled interface and retaining the validated /new interface"
    else
      setup_progress "No pinned external WebUI configured; using the bundled interface"
    fi
    return 0
  fi
  if [ -z "$webui_release" ] || [ -z "$webui_expected_sha256" ]
  then
    echo "External WebUI installation requires both WEBUI_RELEASE and WEBUI_SHA256; using an unverified download is not supported" >&2
    return 1
  fi

  case "$webui_release" in
    latest|*..*)
      echo "WEBUI_RELEASE must be a pinned release tag, not latest, dot, or dot-dot syntax" >&2
      return 1
      ;;
    *)
      if ! [[ "$webui_release" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]
      then
        echo "WEBUI_RELEASE must start and end with a letter or number and contain only tag-safe characters" >&2
        return 1
      fi
      webui_url="https://github.com/marcone/teslausb-webui/releases/download/$webui_release/teslausb-ui.tgz"
      ;;
  esac

  if ! [[ "$webui_expected_sha256" =~ ^[[:xdigit:]]{64}$ ]]
  then
    echo "WEBUI_SHA256 must be exactly 64 hexadecimal characters" >&2
    return 1
  fi
  webui_expected_sha256="${webui_expected_sha256,,}"

  teslausb_webui_stage_dir="$(mktemp -d /var/www/.teslausb-webui-stage.XXXXXX)"
  trap cleanup_webui_stage EXIT
  webui_archive="$teslausb_webui_stage_dir/teslausb-ui.tgz"
  webui_extract_dir="$teslausb_webui_stage_dir/extracted"
  mkdir "$webui_extract_dir"

  curlwrapper --proto '=https' --proto-redir '=https' --max-filesize 67108864 -L \
    -o "$webui_archive" "$webui_url"
  webui_actual_sha256="$(sha256sum "$webui_archive")"
  webui_actual_sha256="${webui_actual_sha256%% *}"

  if [ "$webui_actual_sha256" != "$webui_expected_sha256" ]
  then
    echo "Web UI checksum mismatch: expected $webui_expected_sha256, got $webui_actual_sha256" >&2
    return 1
  fi
  webui_verification=sha256-pinned

  validate_webui_archive "$webui_archive" \
    "$teslausb_webui_stage_dir/archive.list" \
    "$teslausb_webui_stage_dir/archive.verbose.list"
  tar --gzip --extract --file "$webui_archive" \
    --directory "$webui_extract_dir" --no-same-owner --no-same-permissions

  if ! [ -f "$webui_extract_dir/new/index.html" ] ||
     [ -L "$webui_extract_dir/new/index.html" ]
  then
    echo "Web UI archive does not contain a regular new/index.html" >&2
    return 1
  fi
  if find "$webui_extract_dir/new" -type l -print -quit | grep -q .
  then
    echo "Web UI archive extracted an unexpected symbolic link" >&2
    return 1
  fi
  find "$webui_extract_dir/new" -type d -exec chmod 0755 {} +
  find "$webui_extract_dir/new" -type f -exec chmod 0644 {} +

  install -d -o root -g root -m 0755 "$webui_store" "$webui_store/releases"
  webui_release_dir="$webui_store/releases/$webui_actual_sha256"
  if [ -e "$webui_release_dir" ] || [ -L "$webui_release_dir" ]
  then
    if ! [ -d "$webui_release_dir" ] ||
       [ -L "$webui_release_dir" ] ||
       ! [ -f "$webui_release_dir/index.html" ] ||
       [ -L "$webui_release_dir/index.html" ]
    then
      echo "Existing Web UI release directory is invalid: $webui_release_dir" >&2
      return 1
    fi
  else
    mv -T "$webui_extract_dir/new" "$webui_release_dir"
  fi

  # A symlink switch exposes only the fully validated release. The first
  # migration from the historical real directory happens while nginx is
  # stopped above; subsequent switches are a single atomic rename.
  webui_next_link="$teslausb_webui_stage_dir/next"
  ln -s "$webui_release_dir" "$webui_next_link"
  if [ -d /var/www/html/new ] && ! [ -L /var/www/html/new ]
  then
    find /var/www/html/new -xdev -depth -delete
  fi
  mv -Tf "$webui_next_link" /var/www/html/new

  # Publish the deployment record after the UI switch so it can never claim a
  # release was activated when the final rename failed.
  webui_metadata="$teslausb_webui_stage_dir/installed-webui.txt"
  printf 'release=%s\nurl=%s\nsha256=%s\nverification=%s\n' \
    "$webui_release" "$webui_url" "$webui_actual_sha256" \
    "$webui_verification" > "$webui_metadata"
  chmod 0644 "$webui_metadata"
  mv -Tf "$webui_metadata" "$webui_store/installed-webui.txt"

  cleanup_webui_stage
  teslausb_webui_stage_dir=
  trap - EXIT
}

validate_web_auth_config() {
  local password_bytes
  case "${WEB_AUTH_DISABLED:-false}" in
    true|false)
      ;;
    *)
      setup_progress "STOP: WEB_AUTH_DISABLED must be true or false"
      return 1
      ;;
  esac
  if [ "${WEB_AUTH_DISABLED:-false}" = true ]
  then
    if [ -n "${WEB_USERNAME:-}" ] || [ -n "${WEB_PASSWORD:-}" ]
    then
      setup_progress "STOP: WEB_AUTH_DISABLED cannot be combined with WEB_USERNAME or WEB_PASSWORD"
      return 1
    fi
    return 0
  fi
  if { [ -n "${WEB_USERNAME:-}" ] && [ -z "${WEB_PASSWORD:-}" ]; } ||
     { [ -z "${WEB_USERNAME:-}" ] && [ -n "${WEB_PASSWORD:-}" ]; }
  then
    setup_progress "STOP: WEB_USERNAME and WEB_PASSWORD must both be set, or both be empty"
    return 1
  fi
  if [ -z "${WEB_USERNAME:-}" ]
  then
    setup_progress "STOP: web authentication credentials were not provisioned"
    return 1
  fi

  if [ -n "${WEB_USERNAME:-}" ]
  then
    if [ "${#WEB_USERNAME}" -gt 64 ] ||
       ! [[ "$WEB_USERNAME" =~ ^[A-Za-z0-9_.@-]+$ ]]
    then
      setup_progress "STOP: WEB_USERNAME must be 1-64 letters, numbers, dots, underscores, at signs, or dashes"
      return 1
    fi
    case "$WEB_USERNAME" in
      *:*|*$'\r'*|*$'\n'*)
        setup_progress "STOP: WEB_USERNAME contains a character unsupported by htpasswd"
        return 1
        ;;
    esac
    case "$WEB_PASSWORD" in
      *$'\r'*|*$'\n'*)
        setup_progress "STOP: WEB_PASSWORD must not contain a newline"
        return 1
        ;;
    esac
    password_bytes="$(LC_ALL=C; printf %s "$WEB_PASSWORD" | wc -c)"
    if [ "$password_bytes" -lt 12 ] || [ "$password_bytes" -gt 72 ]
    then
      setup_progress "STOP: WEB_PASSWORD must be between 12 and 72 bytes for bcrypt"
      return 1
    fi
    case "${WEB_PASSWORD,,}" in
      raspberry|password|teslausb|"${WEB_USERNAME,,}")
        setup_progress "STOP: WEB_PASSWORD must not be a default value or the username"
        return 1
        ;;
    esac
  fi
}

WEB_AUTH_AUTOGENERATED=false

prepare_web_auth_config() {
  local credential_file=/root/teslausb-web-credentials
  local credential_tmp
  local metadata
  local stored_username
  local stored_password

  if [ "${WEB_AUTH_DISABLED:-false}" = true ] ||
     [ -n "${WEB_USERNAME:-}" ] || [ -n "${WEB_PASSWORD:-}" ]
  then
    return 0
  fi

  if [ -e "$credential_file" ] || [ -L "$credential_file" ]
  then
    if [ -L "$credential_file" ] || [ ! -f "$credential_file" ]
    then
      setup_progress "STOP: $credential_file must be a regular file, not a symbolic link"
      return 1
    fi
    metadata="$(stat -c '%u:%g:%a' -- "$credential_file")" || return 1
    if [ "$metadata" != '0:0:600' ]
    then
      setup_progress "STOP: $credential_file must be owned by root:root with mode 0600"
      return 1
    fi
    if [ "$(grep -c '^username=' "$credential_file" || true)" -ne 1 ] ||
       [ "$(grep -c '^password=' "$credential_file" || true)" -ne 1 ] ||
       [ "$(wc -l < "$credential_file")" -ne 2 ]
    then
      setup_progress "STOP: $credential_file has an invalid format"
      return 1
    fi
    stored_username="$(sed -n 's/^username=//p' "$credential_file")"
    stored_password="$(sed -n 's/^password=//p' "$credential_file")"
    if [ "$stored_username" != teslausb ] ||
       ! [[ "$stored_password" =~ ^[[:xdigit:]]{48}$ ]]
    then
      setup_progress "STOP: $credential_file has invalid generated credentials"
      return 1
    fi
    WEB_USERNAME="$stored_username"
    WEB_PASSWORD="$stored_password"
    WEB_AUTH_AUTOGENERATED=true
    setup_progress "Reusing generated web credentials from $credential_file"
    return 0
  fi

  WEB_USERNAME=teslausb
  WEB_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')"
  if ! [[ "$WEB_PASSWORD" =~ ^[[:xdigit:]]{48}$ ]]
  then
    setup_progress "STOP: failed to generate a cryptographically random web password"
    return 1
  fi
  credential_tmp="$(mktemp /root/.teslausb-web-credentials.XXXXXX)"
  if ! printf 'username=%s\npassword=%s\n' \
       "$WEB_USERNAME" "$WEB_PASSWORD" > "$credential_tmp"
  then
    rm -f -- "$credential_tmp"
    return 1
  fi
  chown root:root "$credential_tmp"
  chmod 0600 "$credential_tmp"
  mv -fT -- "$credential_tmp" "$credential_file"
  WEB_AUTH_AUTOGENERATED=true
  setup_progress "Generated web credentials are stored root-only at $credential_file; run 'sudo cat $credential_file' to retrieve them"
}

validate_ipv6_literal() {
  local value="${1,,}"
  local prefix
  local suffix
  local component
  local -a components=()
  local count=0

  [[ "$value" =~ ^[0-9a-f:]+$ ]] || return 1
  [[ "$value" == *:* ]] || return 1
  if [[ "$value" == *::* ]]
  then
    prefix="${value%%::*}"
    suffix="${value#*::}"
    [[ "$suffix" != *::* ]] || return 1
    IFS=: read -r -a components <<< "$prefix:$suffix"
    for component in "${components[@]}"
    do
      [ -z "$component" ] && continue
      [[ "$component" =~ ^[0-9a-f]{1,4}$ ]] || return 1
      count=$((count + 1))
    done
    [ "$count" -lt 8 ]
    return
  fi

  IFS=: read -r -a components <<< "$value"
  [ "${#components[@]}" -eq 8 ] || return 1
  for component in "${components[@]}"
  do
    [[ "$component" =~ ^[0-9a-f]{1,4}$ ]] || return 1
  done
}

validate_ipv4_literal() {
  local value="$1"
  local octet
  local -a octets=()

  IFS=. read -r -a octets <<< "$value"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"
  do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    [ "$((10#$octet))" -le 255 ] || return 1
  done
}

validate_dns_hostname() {
  local value="${1,,}"
  local label
  local -a labels=()

  [ -n "$value" ] && [ "${#value}" -le 253 ] || return 1
  IFS=. read -r -a labels <<< "$value"
  for label in "${labels[@]}"
  do
    [ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

normalize_allowed_web_host() {
  local value="${1,,}"

  case "$value" in
    \[*\])
      value="${value#[}"
      value="${value%]}"
      validate_ipv6_literal "$value" || return 1
      ;;
    *:*)
      validate_ipv6_literal "$value" || return 1
      ;;
    *[!0-9.]* )
      validate_dns_hostname "$value" || return 1
      ;;
    *.*)
      validate_ipv4_literal "$value" || return 1
      ;;
    *)
      validate_dns_hostname "$value" || return 1
      ;;
  esac
  printf '%s\n' "$value"
}

declare -a TESLAUSB_ALLOWED_WEB_HOSTS=()
TESLAUSB_FASTCGI_ALLOWED_HOSTS=

prepare_allowed_web_hosts() {
  local configured_allowed_hosts="${WEB_ALLOWED_HOSTS:-}"
  local requested
  local token
  local normalized
  local existing
  local duplicate
  local -a requested_hosts=()

  configured_allowed_hosts="${configured_allowed_hosts//,/ }"
  requested="${TESLAUSB_HOSTNAME:-teslausb} $configured_allowed_hosts"
  read -r -a requested_hosts <<< "$requested"
  for token in "${requested_hosts[@]}"
  do
    normalized="$(normalize_allowed_web_host "$token")" || {
      setup_progress "STOP: invalid hostname in TESLAUSB_HOSTNAME or WEB_ALLOWED_HOSTS: $token"
      return 1
    }
    duplicate=false
    for existing in "${TESLAUSB_ALLOWED_WEB_HOSTS[@]}"
    do
      if [ "$normalized" = "$existing" ]
      then
        duplicate=true
        break
      fi
    done
    if [ "$duplicate" = false ]
    then
      TESLAUSB_ALLOWED_WEB_HOSTS+=("$normalized")
    fi
  done
  TESLAUSB_FASTCGI_ALLOWED_HOSTS="$(IFS=,; printf '%s' "${TESLAUSB_ALLOWED_WEB_HOSTS[*]}")"
}

write_nginx_configuration() {
  local map_entries
  local nginx_candidate
  local host

  map_entries="$(mktemp /etc/nginx/.teslausb-host-map.XXXXXX)"
  nginx_candidate="$(mktemp /etc/nginx/sites-available/.teslausb.nginx.XXXXXX)"
  chmod 0600 "$map_entries" "$nginx_candidate"
  for host in "${TESLAUSB_ALLOWED_WEB_HOSTS[@]}"
  do
    case "$host" in
      localhost|teslausb|raspberrypi)
        continue
        ;;
      *:*)
        printf '    "%s" 1;\n    "[%s]" 1;\n' "$host" "$host" >> "$map_entries"
        ;;
      *)
        printf '    "%s" 1;\n' "$host" >> "$map_entries"
        ;;
    esac
  done

  if ! sed "/# TESLAUSB_CUSTOM_HOSTS/r $map_entries" \
       "$SOURCE_DIR/teslausb-www/teslausb.nginx" > "$nginx_candidate" ||
     ! sed -i "s|__TESLAUSB_ALLOWED_HOSTS__|$TESLAUSB_FASTCGI_ALLOWED_HOSTS|g" \
       "$nginx_candidate"
  then
    rm -f -- "$map_entries" "$nginx_candidate"
    return 1
  fi
  chown root:root "$nginx_candidate"
  chmod 0644 "$nginx_candidate"
  mv -fT -- "$nginx_candidate" /etc/nginx/sites-available/teslausb.nginx
  rm -f -- "$map_entries"
}

valid_existing_webui() {
  local path=/var/www/html/new
  local target
  local metadata
  local owner
  local mode

  if [ -L "$path" ]
  then
    target="$(readlink -f -- "$path" 2> /dev/null || true)"
    if ! [[ "$target" =~ ^/var/www/teslausb-webui/releases/[[:xdigit:]]{64}$ ]]
    then
      return 1
    fi
    path="$target"
  fi
  [ -d "$path" ] && [ ! -L "$path/index.html" ] && [ -f "$path/index.html" ] || return 1
  metadata="$(stat -c '%u:%a' -- "$path")" || return 1
  IFS=: read -r owner mode <<< "$metadata"
  [ "$owner" = 0 ] || return 1
  (( (8#$mode & 0022) == 0 )) || return 1
  if find "$path" -xdev \( -type f -o -type d \) \
       \( ! -user root -o -perm /022 \) -print -quit | grep -q .
  then
    return 1
  fi
}

validate_recording_storage() {
  local legacy_store=/mutable/teslausb-recording-trash
  local legacy_entry

  if [ -L /backingfiles ] || ! mountpoint -q /backingfiles
  then
    echo "Recording storage requires the real mounted /backingfiles filesystem" >&2
    return 1
  fi
  if [ -L "$legacy_store" ] || { [ -e "$legacy_store" ] && ! [ -d "$legacy_store" ]; }
  then
    echo "Legacy recording Trash requires manual migration before web setup" >&2
    return 1
  fi
  if [ -d "$legacy_store" ]
  then
    # Empty scaffolding is harmless; manifests, recovery copies, staging files,
    # and unexpected entries must never be abandoned by a root change.
    legacy_entry=$(find "$legacy_store" -mindepth 1 -maxdepth 1 \
      ! -name lock ! -name objects -print -quit) || return 1
    if [ -n "$legacy_entry" ] || [ -L "$legacy_store/objects" ] ||
       { [ -e "$legacy_store/objects" ] && ! [ -d "$legacy_store/objects" ]; } ||
       [ -L "$legacy_store/lock" ] ||
       { [ -e "$legacy_store/lock" ] && ! [ -f "$legacy_store/lock" ]; }
    then
      echo "Legacy recording Trash requires manual migration before web setup" >&2
      return 1
    fi
    if [ -d "$legacy_store/objects" ]
    then
      legacy_entry=$(find "$legacy_store/objects" -mindepth 1 -maxdepth 1 -print -quit) || return 1
      if [ -n "$legacy_entry" ]
      then
        echo "Legacy recording Trash contains preserved data; migrate it before web setup" >&2
        return 1
      fi
    fi
  fi
}

validate_recording_storage
prepare_web_auth_config
validate_web_auth_config
prepare_allowed_web_hosts
setup_progress "configuring nginx"

# delete existing nginx fstab entries
sed -i "/.*\/nginx tmpfs.*/d" /etc/fstab
# and recreate them
echo "tmpfs /var/log/nginx tmpfs nodev,nosuid 0 0" >> /etc/fstab
echo "tmpfs /var/lib/nginx tmpfs nodev,nosuid 0 0" >> /etc/fstab
# only needed for initial setup, since systemd will create these automatically after that
mkdir -p /var/log/nginx
mkdir -p /var/lib/nginx
mount /var/log/nginx
mount /var/lib/nginx

DEBIAN_FRONTEND=noninteractive apt-get -y install nginx fcgiwrap libnginx-mod-http-fancyindex fuse libfuse-dev g++ net-tools wireless-tools ethtool

# install data files and config files
systemctl stop nginx.service &> /dev/null || true
mkdir -p /var/www/html
umount /var/www/html/TeslaCam &> /dev/null || true
umount /var/www/html/fs/Music &> /dev/null || true
umount /var/www/html/fs/LightShow &> /dev/null || true
umount /var/www/html/fs/Boombox &> /dev/null || true
if valid_existing_webui
then
  preserve_existing_webui=true
else
  preserve_existing_webui=false
  if [ -L /var/www/html/new ] || [ -f /var/www/html/new ]
  then
    rm -f -- /var/www/html/new
  elif [ -d /var/www/html/new ]
  then
    find /var/www/html/new -xdev -depth -delete
  fi
fi
if [ "$preserve_existing_webui" = true ]
then
  find /var/www/html -xdev -path /var/www/html/new -prune -o \
    \( -type f -o -type l \) -exec rm -f -- {} +
else
  find /var/www/html -xdev \( -type f -o -type l \) -exec rm -f -- {} +
fi
cp -r "$SOURCE_DIR/teslausb-www/html/." /var/www/html/
chown -R root:root /var/www/html
find /var/www/html -xdev -type d -exec chmod 0755 {} +
find /var/www/html -xdev -type f -exec chmod 0644 {} +
find /var/www/html/cgi-bin -xdev -type f -name '*.sh' -exec chmod 0755 {} +
ln -sf /teslausb/teslausb-headless-setup.log /var/www/html/
ln -sf /mutable/archiveloop.log /var/www/html/
ln -sf /tmp/diagnostics.txt /var/www/html/
mkdir -p /var/www/html/TeslaCam
write_nginx_configuration
ln -sf /etc/nginx/sites-available/teslausb.nginx /etc/nginx/sites-enabled/default

# Setup /etc/nginx/.htpasswd if user requested web auth, otherwise disable auth_basic.
# Supplying only half of the credential pair is almost certainly a typo and
# must not silently leave an administrative interface unauthenticated.
if [ "${WEB_AUTH_DISABLED:-false}" != true ]
then
  DEBIAN_FRONTEND=noninteractive apt-get -y install apache2-utils
  htpasswd_tmp="$(mktemp /etc/nginx/.htpasswd.XXXXXX)"
  if ! printf '%s\n' "$WEB_PASSWORD" | \
       htpasswd -Bci "$htpasswd_tmp" "$WEB_USERNAME"
  then
    rm -f -- "$htpasswd_tmp"
    exit 1
  fi
  chown root:www-data "$htpasswd_tmp"
  chmod 0640 "$htpasswd_tmp"
  mv -f "$htpasswd_tmp" /etc/nginx/.htpasswd
  sed -i 's/auth_basic off/auth_basic "Restricted Content"/' /etc/nginx/sites-available/teslausb.nginx
  if [ "$WEB_AUTH_AUTOGENERATED" != true ]
  then
    rm -f -- /root/teslausb-web-credentials
  fi
else
  sed -i 's/auth_basic "Restricted Content"/auth_basic off/' /etc/nginx/sites-available/teslausb.nginx
  rm -f -- /etc/nginx/.htpasswd
  rm -f -- /root/teslausb-web-credentials
fi

# install the fuse layer needed to work around an incompatibility
# between Chrome and Tesla's recordings
g++ -o /root/cttseraser -D_FILE_OFFSET_BITS=64 "$SOURCE_DIR/teslausb-www/cttseraser.cpp" -lstdc++ -lfuse

# install new UI (compiled js/css files)
install_webui
if [ -d /var/www/html/new ] &&
   ! [ -e /var/www/html/new/favicon.ico ] &&
   ! [ -L /var/www/html/new/favicon.ico ]
then
  ln -s /var/www/html/favicon.ico /var/www/html/new/favicon.ico
fi


cat > /sbin/mount.ctts << EOF
#!/bin/bash -eu
/root/cttseraser "\$@" -o allow_other
EOF
chmod +x /sbin/mount.ctts

sed -i '/mount.ctts/d' /etc/fstab
echo "mount.ctts#/mutable/TeslaCam /var/www/html/TeslaCam fuse defaults,nofail,x-systemd.requires=/mutable 0 0" >> /etc/fstab
mkdir -p /mutable/TeslaCam

# Recording recovery copies and disposable previews must never be served as
# static files. Validate existing paths before changing their ownership.
for recording_store in /backingfiles/teslausb-recording-trash /backingfiles/teslausb-previews
do
  if [ -L "$recording_store" ] || { [ -e "$recording_store" ] && ! [ -d "$recording_store" ]; }
  then
    echo "Unsafe recording store path: $recording_store" >&2
    exit 1
  fi
  install -d -o www-data -g www-data -m 0700 "$recording_store"
done
# Thumbnails use an optional encoder; full-quality playback and downloads work
# without it. Fresh release images already include the verified distro package.
configure_optional_recording_encoder
install -o root -g root -m 0644 "$SOURCE_DIR/setup/pi/teslausb-trash-cleanup.service" /etc/systemd/system/
install -o root -g root -m 0644 "$SOURCE_DIR/setup/pi/teslausb-trash-cleanup.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now teslausb-trash-cleanup.timer

sed -i 's/#user_allow_other/user_allow_other/' /etc/fuse.conf

# Install the root-owned dispatcher before replacing the sudo policy.  The
# source policy is validated first so an invalid update cannot remove web
# access to the currently configured privileged actions.
install -o root -g root -m 0755 \
  "$SOURCE_DIR/teslausb-www/teslausb-web-sudo" \
  /usr/local/sbin/teslausb-web-sudo
/usr/sbin/visudo -cf "$SOURCE_DIR/teslausb-www/teslausb-web-sudoers"
install -o root -g root -m 0440 \
  "$SOURCE_DIR/teslausb-www/teslausb-web-sudoers" \
  /etc/sudoers.d/010_www-data-nopasswd
/usr/sbin/visudo -cf /etc/sudoers.d/010_www-data-nopasswd

# allow multiple concurrent cgi calls
cat > /etc/default/fcgiwrap << EOF
DAEMON_OPTS="-c 4 -f"
EOF

if [ -e /backingfiles/music_disk.bin ] || [ -e /backingfiles/lightshow_disk.bin ] || [ -e /backingfiles/boombox_disk.bin ]
then
  mkdir -p /var/www/html/fs
  copy_script run/auto.www /root/bin
  echo "/var/www/html/fs  /root/bin/auto.www" > /etc/auto.master.d/www.autofs
  DEBIAN_FRONTEND=noninteractive apt-get -y install zip
fi

nginx -t
systemctl restart nginx.service
setup_progress "done configuring nginx"
