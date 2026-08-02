#!/bin/bash -eu

setup_progress "configuring ssh"

for ssh_secret_name in SSH_USER_PASSWORD SSH_ROOT_PUBLIC_KEY
do
  if [[ -v $ssh_secret_name ]]
  then
    export -n "$ssh_secret_name"
  fi
done
unset ssh_secret_name

# If requested, add the desired SSH public key into /root/.ssh/authorized_keys
if [ -n "${SSH_ROOT_PUBLIC_KEY:-}" ]
then
  ssh_dir='/root/.ssh'
  case "$SSH_ROOT_PUBLIC_KEY" in
    *$'\r'*|*$'\n'*)
      setup_progress "STOP: SSH_ROOT_PUBLIC_KEY must contain exactly one public-key line"
      exit 1
      ;;
  esac
  install -d -o root -g root -m 0700 "$ssh_dir"
  authorized_keys_tmp="$(mktemp "$ssh_dir/.authorized_keys.XXXXXX")"
  printf '%s\n' "$SSH_ROOT_PUBLIC_KEY" > "$authorized_keys_tmp"
  if ! ssh-keygen -l -f "$authorized_keys_tmp" > /dev/null
  then
    rm -f -- "$authorized_keys_tmp"
    setup_progress "STOP: SSH_ROOT_PUBLIC_KEY is not a valid OpenSSH public key"
    exit 1
  fi
  chown root:root "$authorized_keys_tmp"
  chmod 0600 "$authorized_keys_tmp"
  mv -fT -- "$authorized_keys_tmp" "$ssh_dir/authorized_keys"
fi

# If requested, disable SSH Password Authentication
if [ "${SSH_DISABLE_PASSWORD_AUTHENTICATION:-false}" = "true" ]
then
  install -d -o root -g root -m 0755 /etc/ssh/sshd_config.d
  ssh_config_tmp="$(mktemp /etc/ssh/sshd_config.d/.teslausb-security.conf.XXXXXX)"
  printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' > "$ssh_config_tmp"
  chown root:root "$ssh_config_tmp"
  chmod 0644 "$ssh_config_tmp"
  mv -fT -- "$ssh_config_tmp" /etc/ssh/sshd_config.d/10-teslausb-security.conf
  sshd -t
  systemctl reload ssh.service
fi

setup_progress "done configuring ssh"
