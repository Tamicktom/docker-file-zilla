#* Debian image with SFTP (FileZilla), Apache and PHP via Supervisor
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV APP_USER=ftpuser

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
      apache2 \
      curl \
      libapache2-mod-php \
      php \
      php-cli \
      php-curl \
      php-gd \
      php-mbstring \
      php-mysql \
      php-pgsql \
      php-xml \
      php-zip \
      openssl \
      openssh-server \
      supervisor \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* \
  && a2enmod rewrite \
  && ln -sf /dev/stdout /var/log/apache2/access.log \
  && ln -sf /dev/stderr /var/log/apache2/error.log

#* SSH daemon runtime directory and host keys (entrypoint refreshes keys if missing)
RUN mkdir -p /var/run/sshd \
  && ssh-keygen -A

#* Dedicated user for SFTP uploads; home is the Apache document root
RUN rm -f /var/www/html/index.html \
  && useradd --no-create-home --home-dir /var/www/html --shell /usr/sbin/nologin --groups www-data "${APP_USER}" \
  && chown "${APP_USER}":www-data /var/www/html \
  && chmod g+rwx /var/www/html \
  && sed -i \
      -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
      -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
      /etc/ssh/sshd_config \
  && echo "AllowUsers ${APP_USER}" >> /etc/ssh/sshd_config \
  && printf '%s\n' \
      'ListenAddress 0.0.0.0' \
      'KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512' \
      > /etc/ssh/sshd_config.d/listen-compat.conf \
  && printf '%s\n' \
      "Match User ${APP_USER}" \
      '    PasswordAuthentication yes' \
      '    ForceCommand internal-sftp' \
      '    AllowTcpForwarding no' \
      '    X11Forwarding no' \
      > /etc/ssh/sshd_config.d/sftp-only.conf

COPY apache-vhost.conf /etc/apache2/sites-available/000-default.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /docker-entrypoint.sh

VOLUME ["/var/www/html"]

EXPOSE 22 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:80/ || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
