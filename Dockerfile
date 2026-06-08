#* Debian image with SSH, vsftpd (FTP/FileZilla), Apache and PHP via Supervisor
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
      apache2 \
      libapache2-mod-php \
      php \
      php-cli \
      openssl \
      openssh-server \
      supervisor \
      vsftpd \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

#* SSH daemon runtime directory and host keys (entrypoint refreshes keys if missing)
RUN mkdir -p /var/run/sshd \
  && ssh-keygen -A

#* Dedicated user for FTP/SFTP-over-SSH uploads (same credential for FTP and SSH; change at build/run)
ARG APP_USER=ftpuser
ARG APP_PASSWORD=changeme
RUN useradd --create-home --shell /bin/bash --groups www-data "${APP_USER}" \
  && echo "${APP_USER}:${APP_PASSWORD}" | chpasswd \
  && chown "${APP_USER}":www-data /var/www/html \
  && chmod g+rwx /var/www/html \
  && sed -i \
      -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
      -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
      /etc/ssh/sshd_config \
  && echo "AllowUsers ${APP_USER}" >> /etc/ssh/sshd_config

COPY vsftpd.conf /etc/vsftpd.conf
COPY vsftpd.userlist /etc/vsftpd.userlist

#* Normalize FTP userlist to build-time username
RUN sed -i "s/^ftpuser$/${APP_USER}/" /etc/vsftpd.userlist

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /docker-entrypoint.sh \
  && echo "<?php phpinfo(); ?>" > /var/www/html/info.php \
  && chown "${APP_USER}":www-data /var/www/html/info.php \
  && echo "<!DOCTYPE html><html><body><p>Apache + PHP OK</p><?php echo '<p>' . PHP_VERSION . '</p>'; ?></body></html>" > /var/www/html/index.php \
  && chown "${APP_USER}":www-data /var/www/html/index.php

EXPOSE 20 21 22 80 443 21100-21110

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
