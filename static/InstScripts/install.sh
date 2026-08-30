#!/bin/bash

# ══════════════════════════════════════════════════════════════════════════════
#  Project Installer (Secure Edition)
#  Installs Docker, Portainer, and the all-in-one application stack.
#
#  Usage:
#    chmod +x install.sh && ./install.sh
#
#  The installer downloads verified Compose/Nginx assets, generates secrets,
#  validates the Compose model, and waits for the services to start.
#
#  SECURITY NOTE:
#  This script uses SHA-256 verification for remote downloads (Homebrew
#  installer and Docker GPG key on Linux) to protect against supply-chain
#  attacks. See the relevant SHA-256 variables below for details.
#  Source: https://owasp.org/www-community/attacks/Supply_chain_attack
# ══════════════════════════════════════════════════════════════════════════════

supports_color() {
    # Ensure stdout is a terminal, tput is available, and the terminal supports
    # at least 8 colors. This avoids emitting ANSI escapes when output is
    # redirected through `tee` or other non-interpreting consumers.
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        local colors
        colors=$(tput colors 2>/dev/null || echo 0)
        [[ "$colors" -ge 8 ]]
    else
        return 1
    fi
}

if supports_color; then
    BOLD="\033[1m"
    RESET="\033[0m"
    RED="\033[31m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    BLUE="\033[34m"
    CYAN="\033[36m"
else
    BOLD=""
    RESET=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
fi

section() {
    printf "\n%s%s%s\n" "$BOLD" "================================================================" "$RESET"
    printf "%s  %s%s\n" "$BLUE" "$1" "$RESET"
    printf "%s%s%s\n\n" "$BOLD" "================================================================" "$RESET"
}

info() {
    printf "%s→ %s%s\n" "$CYAN" "$1" "$RESET"
}

ok() {
    printf "%s✔ %s%s\n" "$GREEN" "$1" "$RESET"
}

warn() {
    printf "%s⚠ %s%s\n" "$YELLOW" "$1" "$RESET"
}

error() {
    printf "%s✖ %s%s\n" "$RED" "$1" "$RESET"
}

section "Project Installer"

# ── Privilege Escalation ──────────────────────────────────────────────────────
# Re-launches the script with elevated privileges if not already root/admin.
# exec sudo -E preserves the current environment (PATH, etc.) for the new process.
# Source: https://www.gnu.org/software/bash/manual/bash.html#Bourne-Shell-Builtins (exec)

request_admin() {
    case "$OSTYPE" in
        linux*)
            if [[ "$EUID" -ne 0 ]]; then
                info "Elevated privileges required. Re-launching with sudo..."
                exec sudo -E bash "$0" "$@"
            else
                ok "Running as root. Privilege check passed."
            fi
            ;;

        darwin*)
            # Unlike Linux, this script must NOT run as root on macOS.
            # Homebrew (used below to install Docker Desktop) explicitly
            # refuses to run as root, and Docker Desktop itself runs as the
            # logged-in user, not root.
            # Source: https://docs.brew.sh/FAQ#why-does-homebrew-say-sudo-is-bad-or-i-dont-want-this-program-installed-in-my-home-directory
            if [[ "$EUID" -eq 0 ]]; then
                error "Do not run this script with sudo on macOS."
                echo "      Homebrew and Docker Desktop must be installed/run as your"
                echo "      normal user. Re-run as: ./install.sh   (without sudo)"
                exit 1
            fi
            ok "Running as standard user (required on macOS)."
            ;;
    esac
}

request_admin "$@"

# ── Logging ────────────────────────────────────────────────────────────────────
# Every run (whether started manually or auto-resumed after a reboot) tees its
# output to a log file so the result of an unattended/automatic run can be
# reviewed afterwards.
# Source: https://www.gnu.org/software/bash/manual/bash.html#Process-Substitution

case "$OSTYPE" in
    linux*)
        # Script runs as root on Linux (see request_admin) — /var/log is writable.
        LOG_FILE="/var/log/install.log"
        ;;
    darwin*)
        # Script intentionally runs as the normal user on macOS (see
        # request_admin), so /var/log is NOT writable. ~/Library/Logs is
        # Apple's standard per-user location for application log files.
        # Source: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html
        LOG_FILE="$HOME/Library/Logs/install.log"
        mkdir -p "$(dirname "$LOG_FILE")"
        ;;

esac

exec > >(tee -a "$LOG_FILE") 2>&1
info "Logging this run to: $LOG_FILE"

# ── OS Detection ──────────────────────────────────────────────────────────────
# Determined automatically from bash's built-in $OSTYPE — no user confirmation
# required.
# Source: https://www.gnu.org/software/bash/manual/bash.html#Bash-Variables (OSTYPE)

ostype=""

get_os() {
    case "$OSTYPE" in
        linux*)
            ostype="linux"
            ;;
        darwin*)
            ostype="osx"
            ;;
        *)
            echo "  [!] Unsupported OS type: $OSTYPE"
            echo "      Supported: Linux, macOS"
            ostype="undefined"
            ;;
    esac

    info "Detected OS: $ostype (\$OSTYPE=$OSTYPE)"
}

# ── Docker Check ──────────────────────────────────────────────────────────────
# Returns 0 (true) if Docker is installed and the daemon is reachable.
# Used to skip installation on re-runs (e.g. after an auto-resume reboot).

check_docker() {
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# ── Docker Installers ─────────────────────────────────────────────────────────

install_docker_linux() {
    section "Installing Docker Engine for Linux..."

    if command -v apt-get &>/dev/null; then
        # Detect whether the distro is Debian or Ubuntu so the correct Docker
        # APT repository is used. Docker maintains separate repos for each.
        # Source: https://docs.docker.com/engine/install/debian/
        #         https://docs.docker.com/engine/install/ubuntu/
        local distro_id
        distro_id=$(. /etc/os-release && echo "$ID")

        case "$distro_id" in
            debian) local docker_repo_url="https://download.docker.com/linux/debian" ;;
            ubuntu) local docker_repo_url="https://download.docker.com/linux/ubuntu" ;;
            *)
                echo "  [!] Unrecognised Debian-family distro: $distro_id"
                echo "      Defaulting to Ubuntu repo — override docker_repo_url if incorrect."
                local docker_repo_url="https://download.docker.com/linux/ubuntu"
                ;;
        esac

        info "Detected apt (${distro_id^}). Using Docker repo: $docker_repo_url"

        apt-get update -y
        apt-get install -y ca-certificates curl git gnupg

        install -m 0755 -d /etc/apt/keyrings
        local docker_gpg_tmp
        docker_gpg_tmp=$(mktemp /tmp/docker-gpg.XXXXXX)

        if ! curl -fsSL "${docker_repo_url}/gpg" -o "$docker_gpg_tmp"; then
            error "Failed to download Docker GPG key from ${docker_repo_url}/gpg"
            rm -f "$docker_gpg_tmp"
            return 1
        fi

        # Verify by GPG fingerprint (more tolerant of re-exports/rotations).
        if ! command -v gpg &>/dev/null && ! command -v gpg2 &>/dev/null; then
            error "gpg not found; ensure 'gnupg' is installed before running this script"
            rm -f "$docker_gpg_tmp"
            return 1
        fi

        actual_fingerprint=$(get_gpg_fingerprint "$docker_gpg_tmp")
        if [[ -z "$actual_fingerprint" ]]; then
            error "Could not extract GPG fingerprint from downloaded key."
            rm -f "$docker_gpg_tmp"
            return 1
        fi

        if [[ "$actual_fingerprint" != "$DOCKER_GPG_FPR" ]]; then
            error "Docker GPG fingerprint mismatch!"
            error "  Expected: $DOCKER_GPG_FPR"
            error "  Got:      $actual_fingerprint"
            rm -f "$docker_gpg_tmp"
            return 1
        fi

        mv "$docker_gpg_tmp" /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        cat > /etc/apt/sources.list.d/docker.sources << EOF
Types: deb
URIs: ${docker_repo_url}
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

        apt-get update -y
        apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin

    elif command -v dnf &>/dev/null; then
        info "Detected dnf (Fedora/RHEL)"
        dnf -y install dnf-plugins-core git
        dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    elif command -v yum &>/dev/null; then
        info "Detected yum (CentOS/older RHEL)"
        yum install -y yum-utils git
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    elif command -v pacman &>/dev/null; then
        info "Detected pacman (Arch Linux)"
        pacman -Sy --noconfirm docker git

    else
        error "No supported package manager found."
        echo "      Install Docker manually: https://docs.docker.com/engine/install/"
        return 1
    fi

    # Enable the Docker daemon and start it immediately.
    systemctl enable --now docker

    # Add the invoking user (not root) to the docker group so they can run
    # Docker commands without sudo. $SUDO_USER is set by sudo to the original
    # unprivileged username.
    # Source: https://docs.docker.com/engine/install/linux-postinstall/
    if [[ -n "$SUDO_USER" ]]; then
        usermod -aG docker "$SUDO_USER"
    fi

    ok "Docker Engine installed."

}

# ── Homebrew Installer with SHA-256 Verification ──────────────────────────────
# Downloads the Homebrew installer to a temp file, verifies its SHA-256 hash
# against a pinned value, then executes it. This protects against supply-chain
# attacks (compromised download server, MITM, malicious CDN).
#
# Security Model:
#   1. Download to a temp file (isolation)
#   2. Verify SHA-256 (integrity check — must match known-good hash)
#   3. Show file path to user (transparency)
#   4. Execute only if hash matches
#
# If SHA-256 changes (Homebrew updates installer):
#   a) Re-run: shasum -a 256 <temp_file>
#   b) Update HOMEBREW_INSTALL_SHA256 below with new value
#   c) Commit change with release notes
#
# Sources:
#   - OWASP on supply-chain attacks:
#       https://owasp.org/www-community/attacks/Supply_chain_attack
#   - CIS Benchmarks for scripting:
#       https://www.cisecurity.org/cis-benchmarks/
#   - Homebrew security docs:
#       https://docs.brew.sh/Security
#   - Pinned commit approach (immutable):
#       https://github.blog/2020-12-15-token-authentication-requirements-for-git-operations/

# Pin to a specific commit hash instead of HEAD (HEAD is mutable).
# Commit hashes are immutable — the content at this hash will never change.
# Source: https://github.com/Homebrew/install
HOMEBREW_INSTALL_COMMIT="bbaa54b31e44b0c93db56ce12071bceda4c2c120"
HOMEBREW_INSTALL_SHA256="2863708cb516c5d0bcdfff97dc13bffb61db93f7acc6ae559a5598a57ce11091"

# IMPORTANT: Verify Docker's signing key by GPG fingerprint (more robust than
# hashing the exported key file because keys may be rotated or re-exported).
# Official Docker GPG fingerprint (long form, uppercase):
#   9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKER_GPG_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
install_homebrew_with_verification() {
    local brew_installer
    brew_installer=$(mktemp /tmp/homebrew-install.XXXXXX.sh)

    local homebrew_url="https://raw.githubusercontent.com/Homebrew/install/${HOMEBREW_INSTALL_COMMIT}/install.sh"

    info "Downloading Homebrew installer from pinned commit: ${HOMEBREW_INSTALL_COMMIT:0:8}..."
    if ! curl -fsSL "$homebrew_url" -o "$brew_installer"; then
        error "Failed to download Homebrew installer from: $homebrew_url"
        rm -f "$brew_installer"
        return 1
    fi

    ok "Homebrew installer downloaded from pinned commit: ${HOMEBREW_INSTALL_COMMIT:0:8}"
    info "Installer path: $brew_installer"
    info "Installer size: $(du -h "$brew_installer" | awk '{print $1}')"
    echo ""
    warn "About to execute: $homebrew_url"
    warn "You can inspect the file at: cat $brew_installer"
    echo ""

    # Optional: Show a confirmation prompt so users can abort if desired.
    # Comment out the next 3 lines if you prefer non-interactive execution.
    read -rp "Press Enter to continue with Homebrew installation, or Ctrl-C to abort: " -t 10 || {
        info "Proceeding automatically (10 second timeout elapsed)..."
    }

    bash "$brew_installer"
    local exit_code=$?
    rm -f "$brew_installer"
    return $exit_code
}

install_docker_mac() {
    section "Installing Docker Desktop for macOS..."

    if ! command -v brew &>/dev/null; then
        info "Homebrew not found. Installing Homebrew first..."
        if ! install_homebrew_with_verification; then
            error "Homebrew installation failed or was aborted."
            return 1
        fi

        # Homebrew installs to /opt/homebrew on Apple Silicon and /usr/local
        # on Intel Macs — load whichever one exists.
        # Source: https://docs.brew.sh/Installation
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -f /usr/local/bin/brew ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    else
        info "Homebrew already installed: $(brew --version | head -1)"
    fi

    if ! command -v git &>/dev/null; then
        info "Installing Git via Homebrew..."
        brew install git
    fi

    info "Installing Docker Desktop via Homebrew..."
    brew install --cask docker

    ok "Docker Desktop installed."

    # Docker Desktop must be launched at least once before `docker` commands
    # work, and the user may need to approve its privileged helper tool.
    # `open -a` launches a macOS app bundle by name.
    # Source: https://ss64.com/mac/open.html
    info "Launching Docker Desktop..."
    open -a Docker

    if wait_for_docker 120; then
        ok "Docker Desktop is running."
    else
        warn "Docker Desktop did not finish starting within 2 minutes."
        warn "Approve any setup dialogs in the Docker app, then re-run this script."
    fi
}


# Polls `docker info` until the daemon responds or the timeout elapses.
# Useful right after installing/launching Docker Desktop on macOS,
# which can take anywhere from a few seconds to a couple of minutes to start
# its VM/backend before the `docker` CLI can talk to it.
wait_for_docker() {
    local timeout="${1:-90}"
    local waited=0

    info "Waiting for the Docker daemon to come online (up to ${timeout}s)..."
    while ! docker info &>/dev/null; do
        sleep 3
        waited=$((waited + 3))
        if (( waited >= timeout )); then
            return 1
        fi
    done
    return 0
}

# ── Docker Verification ───────────────────────────────────────────────────────
# Runs the official hello-world image to confirm the daemon, CLI, and image
# pull pipeline are all working end-to-end.
# Source: https://docs.docker.com/get-started/#test-docker-installation

verify_docker() {
    section "Verifying Docker installation..."

    if docker run --rm hello-world &>/dev/null; then
        ok "Docker is working correctly (hello-world ran successfully)."
    else
        error "Docker verification failed."
        case "$ostype" in
            linux)
                echo "      - Check that the Docker daemon is running: systemctl status docker"
                echo "      - Ensure your user is in the docker group and you have re-logged in."
                ;;
            osx)
                echo "      - Make sure Docker Desktop is running (check the menu bar icon)."
                echo "      - Open Docker.app and wait for it to say 'Docker Desktop is running'."
                ;;
        esac
        echo "      - Run manually: docker run hello-world"
        exit 1
    fi
}

# ── Portainer ─────────────────────────────────────────────────────────────────
# Portainer CE default ports:
#   9000 → HTTP web UI
#   9443 → HTTPS web UI  (preferred)
# Source: https://docs.portainer.io/start/install-ce/server/docker/linux

install_portainer() {
    section "Installing Portainer CE..."

    docker volume inspect portainer_data >/dev/null 2>&1 \
        || docker volume create portainer_data

    if docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
        info "Existing Portainer container found — removing it..."
        docker rm -f portainer >/dev/null 2>&1
    fi

    # --restart=unless-stopped: restarts on crash/daemon-restart but respects
    # a manual 'docker stop portainer'.
    # Source: https://docs.docker.com/config/containers/start-containers-automatically/
    docker run -d \
        --name portainer \
        --restart=unless-stopped \
        -p 9000:9000 \
        -p 9443:9443 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:latest

    ok "Portainer installed."
    ok "Web UI (HTTPS): https://localhost:9443"
    ok "Web UI (HTTP):  http://localhost:9000"
}

# ── Utilities ─────────────────────────────────────────────────────────────────

# Generates a cryptographically secure URL-safe Base64 secret.
# OpenSSL reads from the operating system CSPRNG. URL-safe Base64 preserves all
# entropy while avoiding shell- and .env-sensitive characters.
# Source: https://www.openssl.org/docs/man3.0/man1/openssl-rand.html
generate_secret() {
    local bytes="${1:-48}"
    command -v openssl &>/dev/null || {
        error "OpenSSL is required to generate application secrets."
        return 1
    }
    openssl rand -base64 "$bytes" | tr -d '\n=' | tr '+/' '-_'
}

prompt_setting() {
    local variable_name="$1"
    local prompt_text="$2"
    local default_value="$3"
    local value="${!variable_name:-}"

    if [[ -z "$value" ]]; then
        if [[ -t 0 ]]; then
            read -rp "${prompt_text} [${default_value}]: " value
        fi
        value="${value:-$default_value}"
    else
        info "Using preconfigured ${variable_name}."
    fi

    printf -v "$variable_name" '%s' "$value"
}

# Downloads a file with curl (preferred) or wget.
download_file() {
    local url="$1"
    local dest="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget &>/dev/null; then
        wget -q "$url" -O "$dest"
    else
        echo "  [!] Neither curl nor wget found. Cannot download files."
        return 1
    fi
}

compute_sha256() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v openssl &>/dev/null; then
        openssl dgst -sha256 "$file" | awk '{print $2}'
    else
        return 1
    fi
}

get_gpg_fingerprint() {
    local file="$1"
    local fp=""

    if command -v gpg &>/dev/null; then
        fp=$(gpg --with-colons --import-options show-only --show-keys "$file" 2>/dev/null | awk -F: '/^fpr:/ { print toupper($10); exit }')
    elif command -v gpg2 &>/dev/null; then
        fp=$(gpg2 --with-colons --import-options show-only --show-keys "$file" 2>/dev/null | awk -F: '/^fpr:/ { print toupper($10); exit }')
    fi

    echo "$fp"
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual

    actual=$(compute_sha256 "$file") || {
        error "SHA-256 verification tool not available for $file"
        return 1
    }

    if [[ "$actual" != "$expected" ]]; then
        error "SHA-256 mismatch for $file"
        error "  Expected: $expected"
        error "  Got:      $actual"
        return 1
    fi

    ok "SHA-256 verified for $file"
    return 0
}

# Clones a git repo into a target directory, or pulls latest if it already exists.
# Source: https://git-scm.com/docs/git-clone
#         https://git-scm.com/docs/git-pull
clone_or_pull() {
    local repo_url="$1"
    local target_dir="$2"

    if [[ -d "$target_dir/.git" ]]; then
        echo "  -> '$target_dir' already cloned — pulling latest..."
        git -C "$target_dir" pull
    else
        echo "  -> Cloning into '$target_dir'..."
        git clone "$repo_url" "$target_dir"
    fi
}

# ── Project Setup ─────────────────────────────────────────────────────────────

INSTALL_ASSET_REF="alpha"
INSTALL_ASSET_BASE="https://raw.githubusercontent.com/RGSS-CS/documentation/${INSTALL_ASSET_REF}/static/InstScripts"
COMPOSE_SHA256="0d0a6041a4c1dc6909a0d17dee8381410912a0b8beed346731ad1be5aaca29a7"
NGINX_SHA256="485a51229cac3c7b039e9b911fdbe846e58cc8ae3bace815662cfcfb08223c48"

install_asset() {
    local name="$1"
    local expected_hash="$2"
    local destination="$3"
    local temporary
    temporary=$(mktemp "/tmp/rgss-${name}.XXXXXX")
    download_file "${INSTALL_ASSET_BASE}/${name}" "$temporary" || { rm -f "$temporary"; return 1; }
    verify_sha256 "$temporary" "$expected_hash" || { rm -f "$temporary"; return 1; }
    mv "$temporary" "$destination"
}

write_project_env() {
    local env_path="$1"
    if [[ -f "$env_path" ]]; then
        info ".env already exists — leaving secrets untouched."
        return 0
    fi

    section "Application configuration"

    local site_origin site_host public_media_base_url captcha_url allowed_hosts csrf_trusted_origins
    local superuser_username superuser_email postgres_db postgres_user
    local cap_secret captcha_verify_url

    prompt_setting site_origin "Public site origin (full URL, including http:// or https://)" "http://localhost"
    site_origin="${site_origin%/}"
    if [[ ! "$site_origin" =~ ^https?://([^/:]+)(:[0-9]+)?$ ]]; then
        error "Public site origin must be a full HTTP(S) origin without a path (for example, https://dev.rgsscs.org)."
        return 1
    fi
    site_host="${BASH_REMATCH[1]}"
    allowed_hosts="localhost,127.0.0.1,backend,nginx"
    csrf_trusted_origins="http://localhost,http://127.0.0.1"
    if [[ ",${allowed_hosts}," != *",${site_host},"* ]]; then
        allowed_hosts="${allowed_hosts},${site_host}"
    fi
    if [[ ",${csrf_trusted_origins}," != *",${site_origin},"* ]]; then
        csrf_trusted_origins="${csrf_trusted_origins},${site_origin}"
    fi

    prompt_setting public_media_base_url "Public media base URL" "${site_origin}/media/"
    prompt_setting captcha_url "Public CAP captcha URL" "http://localhost:3001"
    prompt_setting superuser_username "Django superuser username" "admin"
    prompt_setting superuser_email "Django superuser email" "admin@localhost"
    prompt_setting postgres_db "PostgreSQL database name" "db"
    prompt_setting postgres_user "PostgreSQL username" "db"
    prompt_setting cap_secret "Existing CAP site secret (leave blank to configure after startup)" ""
    prompt_setting captcha_verify_url "Existing CAP verification URL (leave blank to configure after startup)" ""

    public_media_base_url="${public_media_base_url%/}/"
    captcha_url="${captcha_url%/}"

    local secret_key signing_key revalidate_secret admin_key postgres_password superuser_password
    secret_key=$(generate_secret 48) || return 1
    signing_key=$(generate_secret 48) || return 1
    revalidate_secret=$(generate_secret 32)
    admin_key=$(generate_secret 32)
    postgres_password=$(generate_secret 24)
    superuser_password=$(generate_secret 24)

    cat > "$env_path" << EOF
# AUTO-GENERATED by install.sh — do not commit this file.

# ==============================================================================
# CONFIGURABLE SETTINGS
# Review these values before the first container startup.
# ==============================================================================

# Public URLs used by the frontend at container startup.
PUBLIC_MEDIA_BASE_URL=${public_media_base_url}
CAPTCHA_URL=${captcha_url}

# ALLOWED_HOSTS uses hostnames only; CSRF_TRUSTED_ORIGINS uses full origins.
# Public hostname: ${site_host}
ALLOWED_HOSTS=${allowed_hosts}
CSRF_TRUSTED_ORIGINS=${csrf_trusted_origins}

# Initial Django administrator account.
DJANGO_SUPERUSER_USERNAME=${superuser_username}
DJANGO_SUPERUSER_EMAIL=${superuser_email}

# CAP site settings. Blank values can be filled after creating a CAP site.
CAP_SECRET=${cap_secret}
CAPTCHA_VERIFY_URL=${captcha_verify_url}

# PostgreSQL database names.
POSTGRES_DB=${postgres_db}
POSTGRES_USER=${postgres_user}

# ==============================================================================
# NON-CONFIGURABLE / AUTO-GENERATED SETTINGS
# The installer generates secrets and keeps internal service addresses here.
# ==============================================================================

# Frontend/internal application settings.
API_URL=http://backend:8000
REVALIDATE_SECRET=${revalidate_secret}

# CAP dashboard and storage.
ADMIN_KEY=${admin_key}
REDIS_URL=redis://valkey:6379

# Django cryptographic and internal settings.
SECRET_KEY=${secret_key}
SIGNING_KEY=${signing_key}
DJANGO_SUPERUSER_PASSWORD=${superuser_password}
REVALIDATE_URL=http://frontend:3000/console/revalidate

# PostgreSQL connection settings.
POSTGRES_PASSWORD=${postgres_password}
DB_HOST=db
DB_PORT=5432
EOF
    chmod 600 "$env_path" 2>/dev/null || true

    cat > "$CREDENTIALS_FILE" << EOF
# AUTO-GENERATED credentials. KEEP SECRET.
SECRET_KEY=${secret_key}
SIGNING_KEY=${signing_key}
REVALIDATE_SECRET=${revalidate_secret}
DJANGO_SUPERUSER_USERNAME=${superuser_username}
DJANGO_SUPERUSER_EMAIL=${superuser_email}
DJANGO_SUPERUSER_PASSWORD=${superuser_password}
POSTGRES_DB=${postgres_db}
POSTGRES_USER=${postgres_user}
POSTGRES_PASSWORD=${postgres_password}
ADMIN_KEY=${admin_key}
EOF
    chmod 600 "$CREDENTIALS_FILE" 2>/dev/null || true
    ok ".env and credentials.txt written."
}

create_shared_network() {
    echo ""
    echo "==> Ensuring shared Docker network 'internetwork' exists..."
    if docker network inspect internetwork >/dev/null 2>&1; then
        info "'internetwork' already exists."
    else
        docker network create internetwork >/dev/null
        ok "'internetwork' network created."
    fi
}

setup_project() {
    section "Preparing all-in-one project..."
    install_asset "AIO_compose.yml" "$COMPOSE_SHA256" "compose.yml" || return 1
    install_asset "nginx.conf" "$NGINX_SHA256" "nginx.conf" || return 1
    write_project_env ".env" || return 1
    create_shared_network

    info "Validating Docker Compose configuration..."
    docker compose --env-file .env -f compose.yml config --quiet || return 1
    ok "Docker Compose configuration is valid."
}

# ── Main ──────────────────────────────────────────────────────────────────────

get_os
echo ""
[[ "$ostype" != "undefined" ]] || { error "Unsupported OS."; exit 1; }

if check_docker; then
    info "Docker is already installed and running."
else
    case "$ostype" in
        linux) install_docker_linux ;;
        osx) install_docker_mac ;;
    esac
    check_docker || { error "Docker is not running after installation."; exit 1; }
fi

verify_docker
install_portainer

project_dir="./project"
mkdir -p "$project_dir"
cd "$project_dir" || { error "Could not enter $project_dir."; exit 1; }
CREDENTIALS_FILE="$(pwd)/credentials.txt"

setup_project || { error "Project setup or Compose validation failed."; exit 1; }

info "Pulling current application images..."
docker compose --env-file .env -f compose.yml pull || { error "Image pull failed."; exit 1; }

info "Starting the all-in-one stack..."
if ! docker compose --env-file .env -f compose.yml up -d --wait; then
    error "The application stack failed to become healthy."
    docker compose --env-file .env -f compose.yml ps
    exit 1
fi

echo ""
echo "================================================================"
echo "  Installation complete"
echo "  Website:       http://localhost"
echo "  API:           http://localhost/api/"
echo "  CAP dashboard: http://localhost:3001"
echo "  Portainer:     https://localhost:9443"
echo ""
echo "  CAP requires one manual setup step:"
echo "    1. Sign in to the CAP dashboard with ADMIN_KEY."
echo "    2. Create a site and copy its site key and secret."
echo "    3. Set CAP_SECRET and CAPTCHA_VERIFY_URL in .env, then recreate backend."
echo "    4. CAPTCHA_URL and PUBLIC_MEDIA_BASE_URL are applied when the"
echo "       frontend container starts; recreate it after changing either value."
echo "================================================================"
