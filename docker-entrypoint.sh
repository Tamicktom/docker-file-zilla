#!/bin/bash
set -e

APP_USER="${APP_USER:-ftpuser}"

if [ -z "${APP_PASSWORD}" ]; then
  echo "ERROR: APP_PASSWORD environment variable is required." >&2
  exit 1
fi

echo "${APP_USER}:${APP_PASSWORD}" | chpasswd

#* Ensure SSH host keys exist (volume mounts may overwrite /etc/ssh)
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
  ssh-keygen -A
fi

chown -R "${APP_USER}:www-data" /var/www/html
chmod -R g+rwX /var/www/html
find /var/www/html -type d -exec chmod g+s {} +

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
