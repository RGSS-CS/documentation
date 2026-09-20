#!/usr/bin/env bash
# Exercise installer functions without installing Docker or starting the stack.
set -euo pipefail
scripts=$(cd "$(dirname "$0")" && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
# Load only project functions; skip privilege escalation, logging and main.
# A regular file also works with Apple's system Bash 3.2.
sed -n '/^install_portainer()/,/^# ── Main/p' "$scripts/install.sh" > "$test_dir/functions.sh"
source "$test_dir/functions.sh"
section() { :; }
info() { :; }
ok() { :; }
error() { printf '%s\n' "$*" >&2; }
cd "$test_dir"
CREDENTIALS_FILE="$test_dir/credentials.txt"

# Simulate non-interactive setup with a public origin containing a port.
prompt_setting() {
    local value="$3"
    [[ "$1" != site_origin ]] || value=https://dev.rgsscs.org:8443
    printf -v "$1" '%s' "$value"
}
write_project_env .env
password=$(sed -n 's/^DJANGO_SUPERUSER_PASSWORD=//p' .env)
[[ ${#password} -eq 16 && "$password" =~ ^[a-zA-Z0-9_-]+$ ]]
for key in SECRET_KEY SIGNING_KEY REVALIDATE_SECRET ADMIN_KEY; do
    [[ -n "$(sed -n "s/^${key}=//p" .env)" ]]
done
original_env=$(cat .env)
write_project_env .env
[[ "$(cat .env)" == "$original_env" ]]
cp "$scripts/nginx.conf" nginx.conf
configure_nginx
grep -Fq 'server_name dev.rgsscs.org;' nginx.conf

# Older files should also yield the public hostname without changing secrets.
sed '/^NGINX_SERVER_NAME=/d' .env > old.env
mv old.env .env
cp "$scripts/nginx.conf" nginx.conf
configure_nginx
grep -Fq 'server_name dev.rgsscs.org;' nginx.conf
printf '\nNGINX_SERVER_NAME=bad;injected\n' >> .env
if configure_nginx; then
    echo 'Unsafe nginx hostname was accepted' >&2
    exit 1
fi

# Capture Docker arguments, including read-only mounting of the password file.
docker() {
    printf '%s\n' "$*" >> docker.log
    case "$*" in
        'network inspect '*) return 1 ;;
        'ps -a '*) return 0 ;;
    esac
}
create_shared_network
grep -Fxq 'network create internetwork' docker.log
grep -Fxq 'network create external' docker.log
install_portainer
portainer_password=$(cat portainer-admin-password.txt)
[[ ${#portainer_password} -ge 12 ]]
grep -Fq -- '--admin-password-file /run/secrets/portainer-admin-password' docker.log
grep -Fq '/run/secrets/portainer-admin-password:ro' docker.log
! grep -Fq "$portainer_password" docker.log
install_portainer
[[ "$(cat portainer-admin-password.txt)" == "$portainer_password" ]]
echo 'Installer configuration checks passed.'
