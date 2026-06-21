# docker-file-zilla

Single-container PHP hosting environment for [Coolify](https://coolify.io): upload files via **SFTP** (FileZilla) and serve them with **Apache + PHP**.

## What is inside

| Service | Port | Purpose |
|---------|------|---------|
| Apache + PHP | 80 | Serve PHP projects from `/var/www/html` |
| OpenSSH (SFTP only) | 22 | Manual file upload via FileZilla |

PHP extensions included: `mysql`, `pgsql` (PostgreSQL), `mbstring`, `xml`, `curl`, `zip`, `gd`.

## Deploy on Coolify

### 1. Create the resource

1. In Coolify, create a new resource using **Dockerfile** as the build type.
2. Point it to this repository.

### 2. Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `APP_PASSWORD` | **Yes** | — | SFTP login password (store as a Coolify secret) |
| `APP_USER` | No | `ftpuser` | SFTP username |

The container will **not start** without `APP_PASSWORD`.

### 3. Persistent storage

Mount a volume to:

```
/var/www/html
```

Without this volume, uploaded PHP files are lost when the container is recreated.

### 4. Ports

| Container port | Usage |
|----------------|-------|
| `80` | HTTP — assign a Coolify domain (TLS handled by Coolify proxy) |
| `22` | SFTP — publish this port for FileZilla access |

If Coolify maps port 22 to a different host port, use that external port in FileZilla.

### 5. FileZilla connection

| Setting | Value |
|---------|-------|
| Protocol | `SFTP - SSH File Transfer Protocol` |
| Host | Coolify server IP or hostname |
| Port | `22` (or the mapped external port) |
| User | Value of `APP_USER` (default: `ftpuser`) |
| Password | Value of `APP_PASSWORD` |

After connecting, you land in `/var/www/html`. Upload your PHP project files there.

### 7. PostgreSQL

The image includes the PHP `pgsql` and `pdo_pgsql` extensions. To connect to a Postgres database (e.g. a Coolify Postgres resource on the same network):

| Variable | Example | Description |
|----------|---------|-------------|
| `DB_HOST` | `postgres` or internal hostname | Postgres host (Coolify service name) |
| `DB_PORT` | `5432` | Postgres port |
| `DB_DATABASE` | `myapp` | Database name |
| `DB_USERNAME` | `postgres` | Database user |
| `DB_PASSWORD` | — | Database password (Coolify secret) |

In PHP (PDO):

```php
$dsn = sprintf(
    'pgsql:host=%s;port=%s;dbname=%s',
    getenv('DB_HOST'),
    getenv('DB_PORT') ?: '5432',
    getenv('DB_DATABASE')
);
$pdo = new PDO($dsn, getenv('DB_USERNAME'), getenv('DB_PASSWORD'));
```

Link the Postgres resource to this app in Coolify so both containers share the same Docker network. Use the internal hostname Coolify provides — not the public IP.

### 8. Verify

1. Open `http://your-coolify-domain/` in a browser.
2. Upload or replace `index.php` via FileZilla.
3. Refresh the browser to confirm the new file is served.

## Local test

```bash
docker build -t php-sftp .
docker run -d --name php-sftp-test \
  -e APP_PASSWORD='strong-password-here' \
  -p 8080:80 \
  -p 2222:22 \
  -v php-data:/var/www/html \
  php-sftp
```

- HTTP: `curl http://localhost:8080/`
- SFTP: connect FileZilla to `localhost`, port `2222`, user `ftpuser`

Stop and remove:

```bash
docker rm -f php-sftp-test
docker volume rm php-data
```

## Limitations

- **Manual deploy only** — there is no CI/CD; you upload files yourself via FileZilla.
- **Password authentication** — keep `APP_PASSWORD` as a Coolify secret and rotate it periodically.
- **SFTP only** — interactive SSH shell access is disabled; only file transfer is allowed.
- **No volume, no files** — always configure persistent storage on `/var/www/html` in production.

## Troubleshooting

### Container exits immediately

Check Coolify logs for:

```
ERROR: APP_PASSWORD environment variable is required.
```

Set `APP_PASSWORD` in the Coolify environment variables.

### FileZilla cannot connect

- Confirm port `22` is published in Coolify via **Ports Mappings** (e.g. `4550:22`), not only **Ports Exposes**.
- Connect to the server **IP and mapped port**, not the HTTP domain.
- Use **SFTP**, not FTP or FTPS.
- In Site Manager, set **Host** to the IP only (`65.x.x.x`), **User** in the username field (`ftpuser`), not `user@host` in the host field.
- Verify `APP_USER` and `APP_PASSWORD` match the Coolify environment variables.

### Nothing connects after redeploy (terminal and FileZilla)

Check the Coolify container logs first. Common causes:

1. **Missing `APP_PASSWORD`** — container exits immediately with:
   ```
   ERROR: APP_PASSWORD environment variable is required.
   ```
2. **Port mapping lost** — confirm **Ports Mappings** still has `4550:22` (or your mapping) after redeploy.
3. **Wrong `APP_USER`** — only `ftpuser` exists unless you rebuild the image with another username.
4. **Firewall** — the host port (e.g. `4550`) must be open on the server/cloud firewall.
5. **Wrong IP** — connect to the server IP, not the HTTP domain.

Quick test from your machine:

```bash
nc -zv YOUR_SERVER_IP 4550
sftp -P 4550 ftpuser@YOUR_SERVER_IP
```

- `nc` fails → port mapping or firewall problem (not FileZilla).
- `nc` succeeds but `sftp` fails → credentials or container SSH issue; read Coolify logs for `SFTP ready:` or `ERROR:` lines.

### FileZilla times out but terminal `sftp` works

OpenSSH 9.x enables post-quantum key exchange algorithms that older FileZilla versions do not support. The handshake stalls and FileZilla reports:

```
Connection timed out after 20 seconds of inactivity
```

This image configures compatible `KexAlgorithms` for FileZilla. If you still see this on an older build:

1. Redeploy with the latest image.
2. Update FileZilla to the latest version.
3. Test from the same machine: `sftp -P 4550 ftpuser@YOUR_SERVER_IP`

### Uploaded files not visible on the website

- Confirm files were uploaded to `/` (which maps to `/var/www/html`).
- Ensure a volume is mounted at `/var/www/html`.
- Check that `index.php` or `index.html` exists in the document root.

### Permission errors on upload

The entrypoint sets ownership to `ftpuser:www-data` on every start. If issues persist, restart the container so the entrypoint re-applies permissions.
