#* Debian image with SSH, SFTP (FileZilla), cron, Apache and PHP via Supervisor
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV APP_USER=ftpuser

#* PHP minor version (packages from packages.sury.org). Every build installs the
#* newest 8.5.x patch release available; rebuild without cache to pick up updates.
ARG PHP_VERSION=8.5

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb \
  && dpkg -i /tmp/debsuryorg-archive-keyring.deb \
  && rm -f /tmp/debsuryorg-archive-keyring.deb \
  && . /etc/os-release \
  && echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/php.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
      apache2 \
      cron \
      libapache2-mod-php${PHP_VERSION} \
      php${PHP_VERSION} \
      php${PHP_VERSION}-cli \
      php${PHP_VERSION}-curl \
      php${PHP_VERSION}-gd \
      php${PHP_VERSION}-mbstring \
      php${PHP_VERSION}-mysql \
      php${PHP_VERSION}-pgsql \
      php${PHP_VERSION}-xml \
      php${PHP_VERSION}-zip \
      openssl \
      openssh-server \
      supervisor \
  && apt-get upgrade -y \
  && php -r 'exit(str_starts_with(PHP_VERSION, getenv("PHP_VERSION") . ".") ? 0 : 1);' \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* \
  && a2enmod rewrite \
  && ln -sf /dev/stdout /var/log/apache2/access.log \
  && ln -sf /dev/stderr /var/log/apache2/error.log

#* SSH daemon runtime directory and host keys (entrypoint refreshes keys if missing)
RUN mkdir -p /var/run/sshd \
  && ssh-keygen -A

#* Shared SSH/SFTP user; home is the Apache document root
RUN rm -f /var/www/html/index.html \
  && useradd --no-create-home --home-dir /var/www/html --shell /bin/bash --groups www-data "${APP_USER}" \
  && chown "${APP_USER}":www-data /var/www/html \
  && chmod g+rwx /var/www/html \
  && sed -i \
      -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
      -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
      -e 's/^Subsystem[[:space:]]\+sftp.*/Subsystem sftp internal-sftp/' \
      /etc/ssh/sshd_config \
  && echo "AllowUsers ${APP_USER}" >> /etc/ssh/sshd_config \
  && printf '%s\n' \
      'ListenAddress 0.0.0.0' \
      'KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512' \
      > /etc/ssh/sshd_config.d/listen-compat.conf \
  && printf '%s\n' \
      "Match User ${APP_USER}" \
      '    PasswordAuthentication yes' \
      '    AllowTcpForwarding no' \
      '    X11Forwarding no' \
      > /etc/ssh/sshd_config.d/app-user.conf

COPY apache-vhost.conf /etc/apache2/sites-available/000-default.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /docker-entrypoint.sh

VOLUME ["/var/www/html", "/var/spool/cron/crontabs"]

EXPOSE 22 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:80/ || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
