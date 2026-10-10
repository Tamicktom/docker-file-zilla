#!/usr/bin/env bash
# Remote shell/PHP expressions must expand on the server, not locally.
# shellcheck disable=SC2016
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
for tool in docker ssh sftp sshpass curl; do
  command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done
docker info >/dev/null

image="${TEST_IMAGE:-php-ssh-sftp:integration}"
prefix="php-ssh-test-$$"
container="$prefix-app"
volume="$prefix-data"
cron_volume="$prefix-crontabs"
network="$prefix-network"
workdir="$(mktemp -d)"
export SSHPASS='Integration-$! password:with spaces'
original_password="$SSHPASS"
passed=0

cleanup() {
  local status=$?
  if (( status != 0 )); then
    docker logs "$container" >&2 2>/dev/null || true
    docker exec "$container" cat /var/log/supervisor/sshd.err.log >&2 2>/dev/null || true
  fi
  docker rm -fv "$container" "$prefix-missing" "$prefix-empty" "$prefix-user" >/dev/null 2>&1 || true
  docker volume rm "$volume" "$cron_volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$workdir"
}
trap cleanup EXIT
pass() { passed=$((passed + 1)); printf 'PASS %02d: %s\n' "$passed" "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Host networking can be selected for the build only; runtime stays isolated.
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  build_args=()
  if [[ -n "${DOCKER_BUILD_NETWORK:-}" ]]; then
    build_args+=(--network "$DOCKER_BUILD_NETWORK")
  fi
  docker build "${build_args[@]}" -t "$image" .
fi
pass 'Docker image builds successfully'

expect_startup_error() {
  local suffix="$1" message="$2"
  shift 2
  if docker run --rm --name "$prefix-$suffix" --network none "$@" "$image" true >"$workdir/$suffix.log" 2>&1; then
    fail "Startup unexpectedly accepted $suffix"
  fi
  grep -Fq "$message" "$workdir/$suffix.log" || fail "Wrong startup error for $suffix"
}
expect_startup_error missing 'APP_PASSWORD environment variable is required.'
expect_startup_error empty 'APP_PASSWORD environment variable is required.' -e APP_PASSWORD=
expect_startup_error user "user 'unknownapp' does not exist" -e APP_PASSWORD=test -e APP_USER=unknownapp
pass 'Missing/empty password and nonexistent APP_USER fail clearly'

# Isolated bridge: no outside network access is needed by the running app.
docker network create --internal "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker volume create "$cron_volume" >/dev/null
run_app() {
  local publish_args=()
  if [[ "${DOCKER_TEST_NETWORK:-published}" != direct ]]; then
    publish_args=(-p 127.0.0.1::22 -p 127.0.0.1::80)
  fi
  docker run -d --name "$container" --network "$network" \
    "${publish_args[@]}" -e APP_PASSWORD="$SSHPASS" \
    -v "$volume:/var/www/html" -v "$cron_volume:/var/spool/cron/crontabs" "$image" >/dev/null
  if [[ "${DOCKER_TEST_NETWORK:-published}" == direct ]]; then
    host="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container")"
    ssh_port=22
    http_port=80
  else
    host=127.0.0.1
    ssh_port="$(docker port "$container" 22/tcp | sed 's/.*://')"
    http_port="$(docker port "$container" 80/tcp | sed 's/.*://')"
  fi
  ssh_options=(-p "$ssh_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o ConnectTimeout=3 -o ConnectionAttempts=1
    -o PreferredAuthentications=password -o PubkeyAuthentication=no
    -o NumberOfPasswordPrompts=1)
  sftp_options=(-P "$ssh_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o ConnectTimeout=3 -o BatchMode=no
    -o PreferredAuthentications=password -o PubkeyAuthentication=no
    -o NumberOfPasswordPrompts=1)
}
ssh_app() { sshpass -e ssh "${ssh_options[@]}" "ftpuser@$host" "$@"; }
wait_ready() {
  local ready=0
  for ((i=0; i<60; i++)); do
    if curl -fsS --max-time 2 "http://$host:$http_port/" >"$workdir/http.html" 2>/dev/null && \
       ssh_app true 2>/dev/null; then
      ready=1
      break
    fi
    sleep 1
  done
  [[ "$ready" == 1 ]] || fail 'SSH/HTTP did not become ready'
}
run_app
wait_ready
pass 'SSH and HTTP start and accept connections'
grep -Fq 'Apache + PHP OK' "$workdir/http.html" || fail 'Default PHP page missing'
pass 'Apache executes the default PHP page'

[[ "$(ssh_app 'whoami')" == ftpuser ]] || fail 'SSH username mismatch'
[[ "$(ssh_app 'pwd')" == /var/www/html ]] || fail 'SSH starts outside document root'
[[ "$(ssh_app 'printf "%s" "$SHELL"')" == /bin/bash ]] || fail 'Bash is not the login shell'
ssh_app 'test "$(id -u)" != 0 && test ! -w /etc/passwd'
pass 'SSH uses the SFTP credentials, Bash, document root and a non-root user'

if ssh_app 'exit 7'; then
  fail 'Remote nonzero exit status was lost'
else
  [[ "$?" == 7 ]] || fail 'Remote exit status is not 7'
fi
pass 'SSH remote commands preserve exit status'

printf 'test -t 0 && test -t 1 && echo "PTY""_OK"\npwd\nexit\n' | \
  sshpass -e ssh "${ssh_options[@]}" -tt "ftpuser@$host" >"$workdir/pty.log" 2>&1
# The command echo deliberately splits the marker, so only executed output matches.
grep -Fq PTY_OK "$workdir/pty.log" || { cat "$workdir/pty.log" >&2; fail 'Interactive PTY shell failed'; }
pass 'Interactive SSH shell supports a PTY'

config="$(docker exec "$container" /usr/sbin/sshd -T -C user=ftpuser,host=localhost,addr=127.0.0.1)"
for expected in 'forcecommand none' 'passwordauthentication yes' 'permitrootlogin no' \
    'allowtcpforwarding no' 'x11forwarding no' 'allowusers ftpuser' 'subsystem sftp internal-sftp'; do
  grep -Fqx "$expected" <<<"$config" || fail "Unexpected sshd setting: $expected"
done
pass 'Effective sshd settings allow SSH/SFTP and retain security restrictions'

if SSHPASS=incorrect ssh_app true >"$workdir/wrong.log" 2>&1; then
  fail 'Wrong SSH password accepted'
fi
grep -Fq 'Permission denied' "$workdir/wrong.log" || fail 'Wrong password failed for an unexpected reason'
if printf 'pwd\nquit\n' | SSHPASS=incorrect sshpass -e sftp "${sftp_options[@]}" "ftpuser@$host" >"$workdir/wrong-sftp.log" 2>&1; then
  fail 'Wrong SFTP password accepted'
fi
grep -Fq 'Permission denied' "$workdir/wrong-sftp.log" || fail 'Wrong SFTP password failed for an unexpected reason'
pass 'Both SSH and SFTP reject an incorrect password'

for user in root nobody; do
  if sshpass -e ssh "${ssh_options[@]}" "$user@$host" true >"$workdir/denied-$user.log" 2>&1; then
    fail "Unauthorized user $user logged in"
  fi
  grep -Fq 'Permission denied' "$workdir/denied-$user.log" || fail "Unexpected failure for $user"
done
pass 'Root and other users cannot log in'

if sshpass -e ssh "${ssh_options[@]/LogLevel=ERROR/LogLevel=VERBOSE}" -W 127.0.0.1:80 "ftpuser@$host" >"$workdir/forward.log" 2>&1; then
  fail 'TCP forwarding unexpectedly succeeded'
fi
grep -Fq 'administratively prohibited' "$workdir/forward.log" || { cat "$workdir/forward.log" >&2; fail 'Forwarding failed for an unexpected reason'; }
pass 'TCP forwarding is denied over a real SSH connection'

printf '<?php echo "SFTP_PHP_OK"; ?>\n' >"$workdir/upload.php"
printf 'pwd\nput %s uploaded.php\nget uploaded.php %s\nquit\n' \
  "$workdir/upload.php" "$workdir/download.php" | \
  sshpass -e sftp "${sftp_options[@]}" "ftpuser@$host" >"$workdir/sftp.log" 2>&1
grep -Fq 'Remote working directory: /var/www/html' "$workdir/sftp.log" || fail 'Wrong initial SFTP directory'
cmp "$workdir/upload.php" "$workdir/download.php" || fail 'SFTP content changed'
pass 'SFTP starts in document root and uploads/downloads identical files'
[[ "$(curl -fsS --max-time 5 "http://$host:$http_port/uploaded.php")" == SFTP_PHP_OK ]] || fail 'Uploaded PHP not served'
pass 'Files uploaded through SFTP execute through Apache/PHP'

ssh_app 'printf "created over SSH\n" > ssh-file.txt; php -r '\''echo "PHP_CLI_OK";'\''' >"$workdir/php-cli.log"
grep -Fqx PHP_CLI_OK "$workdir/php-cli.log" || fail 'PHP CLI failed'
[[ "$(curl -fsS --max-time 5 "http://$host:$http_port/ssh-file.txt")" == 'created over SSH' ]] || fail 'SSH-created file not served'
[[ "$(docker exec "$container" stat -c '%U:%G' /var/www/html/ssh-file.txt)" == ftpuser:www-data ]] || fail 'Shared group permissions changed'
pass 'SSH can write served files with the shared www-data group and run PHP CLI'
ssh_app 'php -r '\''foreach (["mysqli", "pdo_mysql", "pgsql", "pdo_pgsql", "mbstring", "xml", "curl", "zip", "gd"] as $ext) { if (!extension_loaded($ext)) { fwrite(STDERR, "Missing: $ext\n"); exit(1); } }'\'''
pass 'Existing PHP extensions remain installed'

# Exercise crontab through PHP itself, including Apache's www-data identity.
# These endpoints are test-only fixtures and are removed before cleanup.
cat >"$workdir/cron-test-setup.php" <<'PHP'
<?php
$role = PHP_SAPI === 'cli' ? 'cli' : 'web';
$action = PHP_SAPI === 'cli' ? ($argv[1] ?? 'install') : ($_GET['action'] ?? 'install');
$command = match ($action) {
    'install' => ['/usr/bin/crontab', '-'],
    'list' => ['/usr/bin/crontab', '-l'],
    'remove' => ['/usr/bin/crontab', '-r'],
    default => throw new RuntimeException('Invalid test action'),
};
$process = proc_open($command, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
if (!is_resource($process)) {
    throw new RuntimeException('Cannot execute crontab');
}
if ($action === 'install') {
    fwrite($pipes[0], "SHELL=/bin/sh\nPATH=/usr/bin:/bin\n* * * * * cd /var/www/html && /usr/bin/php cron-test-job.php $role > /var/www/html/$role-cron.log 2>&1\n");
}
fclose($pipes[0]);
$output = stream_get_contents($pipes[1]);
$error = stream_get_contents($pipes[2]);
fclose($pipes[1]);
fclose($pipes[2]);
$status = proc_close($process);
if ($status !== 0) {
    http_response_code(500);
    fwrite(fopen('php://stderr', 'w'), $error);
    exit(1);
}
echo $action === 'list' ? $output : "CRONTAB_OK:$role:$action";
PHP
cat >"$workdir/cron-test-job.php" <<'PHP'
<?php
exec('/usr/bin/id -un', $lines, $status);
if ($status !== 0) {
    exit(1);
}
$result = ['user' => trim(implode('', $lines)), 'sapi' => PHP_SAPI,
    'cwd' => getcwd(), 'pgsql' => extension_loaded('pdo_pgsql')];
file_put_contents(__DIR__ . '/' . $argv[1] . '-cron-result.json', json_encode($result));
PHP
printf 'put %s cron-test-setup.php\nput %s cron-test-job.php\nquit\n' \
  "$workdir/cron-test-setup.php" "$workdir/cron-test-job.php" | \
  sshpass -e sftp "${sftp_options[@]}" "ftpuser@$host" >"$workdir/cron-upload.log" 2>&1
# The project does not expose supervisorctl RPC; inspect the actual daemon instead.
docker exec "$container" /bin/sh -c 'test -s /var/run/crond.pid && kill -0 "$(cat /var/run/crond.pid)"'
[[ "$(docker exec "$container" stat -c '%U:%G:%a' /var/spool/cron/crontabs)" == root:crontab:1730 ]] || fail 'Incorrect crontab spool permissions'
pass 'Cron daemon runs under Supervisor with correct persistent spool permissions'

[[ "$(ssh_app 'php /var/www/html/cron-test-setup.php')" == CRONTAB_OK:cli:install ]] || fail 'PHP CLI cannot install crontab'
ssh_app 'php /var/www/html/cron-test-setup.php list' | grep -Fq 'cron-test-job.php cli' || fail 'PHP CLI cannot list crontab'
[[ "$(curl -fsS --max-time 5 "http://$host:$http_port/cron-test-setup.php")" == CRONTAB_OK:web:install ]] || fail 'Apache PHP cannot install crontab'
curl -fsS --max-time 5 "http://$host:$http_port/cron-test-setup.php?action=list" | grep -Fq 'cron-test-job.php web' || fail 'Apache PHP cannot list crontab'
pass 'PHP CLI and Apache PHP install/list their own crontabs without root'

wait_cron_jobs() {
  local stage="$1" ready=0
  echo "Waiting for a real cron minute tick ($stage; timeout 90s)..."
  for ((i=0; i<90; i++)); do
    if docker exec "$container" test -s /var/www/html/cli-cron-result.json && \
       docker exec "$container" test -s /var/www/html/web-cron-result.json; then
      ready=1
      break
    fi
    if (( i % 15 == 0 )); then echo "Cron wait: $stage, ${i}s elapsed"; fi
    sleep 1
  done
  [[ "$ready" == 1 ]] || {
    docker exec "$container" /bin/sh -c 'cat /var/www/html/*-cron.log /var/log/supervisor/cron.err.log' >&2 || true
    fail "Cron jobs did not execute: $stage"
  }
  docker exec "$container" php -r 'foreach (["cli" => "ftpuser", "web" => "www-data"] as $role => $user) { $data = json_decode(file_get_contents("/var/www/html/$role-cron-result.json"), true); if ($data["user"] !== $user || $data["sapi"] !== "cli" || $data["cwd"] !== "/var/www/html" || !$data["pgsql"]) { fwrite(STDERR, json_encode($data)); exit(1); } }'
}
wait_cron_jobs initial
pass 'Cron actually executes PHP jobs as ftpuser and www-data with PHP extensions'


# Check that SSH/SFTP and scheduled PHP jobs recover after a restart.
docker exec "$container" rm /var/www/html/cli-cron-result.json /var/www/html/web-cron-result.json
docker restart "$container" >/dev/null
wait_ready
printf 'get uploaded.php %s\nquit\n' "$workdir/after-restart.php" | \
  sshpass -e sftp "${sftp_options[@]}" "ftpuser@$host" >"$workdir/restart-sftp.log" 2>&1
cmp "$workdir/upload.php" "$workdir/after-restart.php"
pass 'SSH/SFTP survive a restart and uploaded files persist'
wait_cron_jobs restart
pass 'Scheduled PHP jobs execute again after restart'

# Recreate with the same volume and a new password: both protocols share rotation.
docker exec "$container" rm /var/www/html/cli-cron-result.json /var/www/html/web-cron-result.json
docker rm -fv "$container" >/dev/null
export SSHPASS='Rotated-$! password:also special'
run_app
wait_ready
if SSHPASS="$original_password" ssh_app true >"$workdir/old-password.log" 2>&1; then
  fail 'Old password accepted after recreation'
fi
grep -Fq 'Permission denied' "$workdir/old-password.log" || fail 'Old password failed for an unexpected reason'
printf 'get uploaded.php %s\nquit\n' "$workdir/after-recreate.php" | \
  sshpass -e sftp "${sftp_options[@]}" "ftpuser@$host" >"$workdir/recreate-sftp.log" 2>&1
cmp "$workdir/upload.php" "$workdir/after-recreate.php"
[[ "$(curl -fsS --max-time 5 "http://$host:$http_port/uploaded.php")" == SFTP_PHP_OK ]]
pass 'Recreation preserves files and rotates the shared SSH/SFTP password'
wait_cron_jobs recreation
pass 'Persistent crontabs execute PHP again after container recreation'
[[ "$(ssh_app 'php /var/www/html/cron-test-setup.php remove')" == CRONTAB_OK:cli:remove ]] || fail 'PHP CLI cannot remove crontab'
[[ "$(curl -fsS --max-time 5 "http://$host:$http_port/cron-test-setup.php?action=remove")" == CRONTAB_OK:web:remove ]] || fail 'Apache PHP cannot remove crontab'
for user in ftpuser www-data; do
  if docker exec --user "$user" "$container" crontab -l >"$workdir/removed-$user.log" 2>&1; then
    fail "Crontab for $user still exists"
  fi
  grep -Fq 'no crontab for' "$workdir/removed-$user.log" || fail 'Unexpected removal failure'
done
ssh_app 'rm cron-test-setup.php cron-test-job.php'
pass 'PHP CLI and Apache PHP remove their own crontabs; test endpoints are deleted'

healthy=0
for ((i=0; i<60; i++)); do
  if [[ "$(docker inspect --format '{{.State.Health.Status}}' "$container")" == healthy ]]; then
    healthy=1
    break
  fi
  sleep 1
done
[[ "$healthy" == 1 ]] || fail 'Docker healthcheck did not become healthy'
pass 'Docker HTTP healthcheck reports healthy'
printf '\nAll %s integration checks passed.\n' "$passed"
