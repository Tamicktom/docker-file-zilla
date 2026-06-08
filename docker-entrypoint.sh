#!/bin/bash
set -e

#* Optional: set PASV_ADDRESS to your host IP/hostname for FileZilla passive mode (e.g. 127.0.0.1 or your LAN IP)
if [ -n "${PASV_ADDRESS}" ]; then
  if grep -q '^pasv_address=' /etc/vsftpd.conf; then
    sed -i "s/^pasv_address=.*/pasv_address=${PASV_ADDRESS}/" /etc/vsftpd.conf
  else
    echo "pasv_address=${PASV_ADDRESS}" >> /etc/vsftpd.conf
  fi
fi

#* Ensure SSH host keys exist (volume mounts may overwrite /etc/ssh)
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
  ssh-keygen -A
fi

exec "$@"
