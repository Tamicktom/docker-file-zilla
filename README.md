# docker-file-zilla

Single-container PHP hosting environment for [Coolify](https://coolify.io): upload files via **SFTP** (FileZilla) and serve them with **Apache + PHP**.

## What is inside

| Service | Port | Purpose |
|---------|------|---------|
| Apache + PHP | 80 | Serve PHP projects from `/var/www/html` |
| OpenSSH (SFTP only) | 22 | Manual file upload via FileZilla |

PHP extensions included: `mysql`, `mbstring`, `xml`, `curl`, `zip`, `gd`.

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

### 6. Verify

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

- Confirm port `22` is published in Coolify.
- Use **SFTP**, not FTP or FTPS.
- Verify `APP_USER` and `APP_PASSWORD` match the Coolify environment variables.

### Uploaded files not visible on the website

- Confirm files were uploaded to `/` (which maps to `/var/www/html`).
- Ensure a volume is mounted at `/var/www/html`.
- Check that `index.php` or `index.html` exists in the document root.

### Permission errors on upload

The entrypoint sets ownership to `ftpuser:www-data` on every start. If issues persist, restart the container so the entrypoint re-applies permissions.
