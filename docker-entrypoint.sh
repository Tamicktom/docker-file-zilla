#!/bin/bash
set -e

APP_USER="${APP_USER:-ftpuser}"

if [ -z "${APP_PASSWORD}" ]; then
  echo "ERROR: APP_PASSWORD environment variable is required." >&2
  exit 1
fi

if ! id "${APP_USER}" &>/dev/null; then
  echo "ERROR: user '${APP_USER}' does not exist. Keep APP_USER=ftpuser or rebuild the image." >&2
  exit 1
fi

#* Use printf to avoid shell expansion of special characters in APP_PASSWORD ($, !, etc.)
printf '%s:%s\n' "${APP_USER}" "${APP_PASSWORD}" | chpasswd

mkdir -p /var/run/sshd

#* Ensure SSH host keys exist (volume mounts may overwrite /etc/ssh)
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
  ssh-keygen -A
fi

if ! sshd -t; then
  echo "ERROR: sshd configuration is invalid (see above)." >&2
  exit 1
fi

if ! chown -R "${APP_USER}:www-data" /var/www/html; then
  echo "WARNING: chown failed on /var/www/html — check volume mount permissions." >&2
fi

if ! chmod -R g+rwX /var/www/html; then
  echo "WARNING: chmod failed on /var/www/html — check volume mount permissions." >&2
fi

find /var/www/html -type d -exec chmod g+s {} + 2>/dev/null || true

echo "SFTP ready: user=${APP_USER}, port=22, document_root=/var/www/html"

if [ -z "$(ls -A /var/www/html 2>/dev/null)" ]; then
  cat > /var/www/html/index.php <<'EOF'
<!DOCTYPE html>
<html>
<body>
<p>Apache + PHP OK</p>
<?php echo '<p>' . PHP_VERSION . '</p>'; ?>
</body>
</html>
EOF
  chown "${APP_USER}:www-data" /var/www/html/index.php
fi

exec "$@"
