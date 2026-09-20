    #Requires -Version 5.1

# ==============================================================================
#  RGSS Williams Portal -- Windows Installer (Native PowerShell)
#
#  Installs Docker Desktop, Portainer, and the all-in-one application stack.
#  Automatically resumes after the reboot that WSL2 setup requires.
#
#  Usage:
#    powershell -ExecutionPolicy Bypass -File install.ps1
# ==============================================================================

# NOTE: ErrorActionPreference is intentionally NOT set to Stop globally.
# Docker writes informational messages to stderr (e.g. "Unable to find image
# locally" during a pull) which PowerShell treats as terminating errors when
# ErrorActionPreference = Stop. We handle errors explicitly instead.

# -- State file ----------------------------------------------------------------

$StateFile = Join-Path $PSScriptRoot "install.state"

function Get-Stage {
    if (Test-Path $StateFile) { return (Get-Content $StateFile -Raw).Trim() }
    return ""
}

function Set-Stage([string]$stage) {
    Set-Content -Path $StateFile -Value $stage -Encoding ASCII
}

# -- Colour helpers ------------------------------------------------------------

function Write-Section([string]$msg) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Blue
    Write-Host "  $msg" -ForegroundColor Blue
    Write-Host "================================================================" -ForegroundColor Blue
    Write-Host ""
}

function Write-Info([string]$msg)  { Write-Host "-> $msg" -ForegroundColor Cyan   }
function Write-Ok([string]$msg)    { Write-Host "OK $msg" -ForegroundColor Green  }
function Write-Warn([string]$msg)  { Write-Host "!! $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)   { Write-Host "XX $msg" -ForegroundColor Red    }

function Exit-WithError([string]$msg) {
    Write-Err $msg
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    Read-Host "Press Enter to exit"
    exit 1
}

# -- Self-elevation ------------------------------------------------------------

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($currentIdentity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host "Elevation required - requesting Administrator privileges..."
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        Write-Host "ERROR: Cannot determine script path. Run from an elevated PowerShell prompt."
        Read-Host "Press Enter to exit"
        exit 1
    }
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"") `
        -Verb RunAs
    exit 0
}

Write-Ok "Running as Administrator."

# -- Logging ------------------------------------------------------------------

$LogFile = Join-Path $PSScriptRoot "install.log"
Start-Transcript -Path $LogFile -Append | Out-Null
Write-Info "Logging to: $LogFile"

# -- TLS 1.2 ------------------------------------------------------------------

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ==============================================================================
#  Docker helpers
#
#  All docker calls go through cmd.exe so that docker's stderr output never
#  triggers PowerShell's error handling. Docker routinely prints to stderr
#  during normal operation (image pull progress, "Unable to find image locally",
#  daemon info warnings) -- none of these are failures.
# ==============================================================================

function Invoke-Docker([string]$dockerArgs, [switch]$quiet) {
    if ($quiet) {
        cmd /c "docker $dockerArgs" "2>&1" | Out-Null
    } else {
        cmd /c "docker $dockerArgs" "2>&1"
    }
    return $LASTEXITCODE
}

function Test-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    Invoke-Docker "info" -quiet | Out-Null
    return $LASTEXITCODE -eq 0
}

function Wait-ForDocker([int]$timeoutSeconds = 300) {
    Write-Info "Waiting for Docker daemon (up to ${timeoutSeconds}s)..."
    Write-Host "  (this can take 1-3 minutes while WSL2 initialises)" -ForegroundColor DarkGray
    $waited = 0
    while (-not (Test-Docker)) {
        Write-Host "." -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
        $waited += 5
        if ($waited -ge $timeoutSeconds) { Write-Host ""; return $false }
    }
    Write-Host ""
    return $true
}

# ==============================================================================
#  Utility functions
# ==============================================================================

function New-RandomSecret([int]$bytes = 48) {
    $buffer = [byte[]]::new($bytes)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($buffer)
    } finally {
        $rng.Dispose()
    }
    return [Convert]::ToBase64String($buffer).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Read-Setting([string]$name, [string]$prompt, [string]$defaultValue) {
    $configuredValue = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace($configuredValue)) {
        Write-Info "Using preconfigured $name."
        return $configuredValue
    }

    $enteredValue = Read-Host "$prompt [$defaultValue]"
    if ([string]::IsNullOrWhiteSpace($enteredValue)) {
        return $defaultValue
    }
    return $enteredValue
}

function Invoke-Download([string]$url, [string]$dest) {
    Write-Info "Downloading: $url"
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    if (-not (Test-Path $dest) -or (Get-Item $dest).Length -eq 0) {
        throw "Download failed or empty: $dest"
    }
}

function Get-FileSha256([string]$path) {
    if (-not (Test-Path $path)) {
        throw "File not found: $path"
    }
    return (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Verify-Sha256([string]$path, [string]$expectedHash) {
    $actualHash = Get-FileSha256 -path $path
    if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
        Write-Err "SHA-256 mismatch for $path"
        Write-Err "  Expected: $expectedHash"
        Write-Err "  Got:      $actualHash"
        return $false
    }
    Write-Ok "SHA-256 verified for $path"
    return $true
}

function Invoke-CloneOrPull([string]$repoUrl, [string]$targetDir) {
    if (Test-Path (Join-Path $targetDir ".git")) {
        Write-Info "'$targetDir' already cloned - pulling latest..."
        git -C $targetDir pull
    } else {
        Write-Info "Cloning into '$targetDir'..."
        git clone $repoUrl $targetDir
    }
    return $LASTEXITCODE
}

# ==============================================================================
#  Docker install
# ==============================================================================

function Register-ResumeOnBoot {
    # Task Scheduler is more reliable than the Run registry key for elevated
    # scripts because it preserves the "Run with highest privileges" flag
    # across reboots, avoiding a second UAC prompt on resume.
    # Source: https://learn.microsoft.com/powershell/module/scheduledtasks/register-scheduledtask
    $scriptPath = $PSCommandPath

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

    # At logon of any user -- mirrors what the Run key did but with elevation.
    $trigger = New-ScheduledTaskTrigger -AtLogOn

    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
        -MultipleInstances IgnoreNew

    # RunLevel Highest = elevated token, no UAC prompt.
    # The task runs as the current user so it gets their profile/desktop.
    $principal = New-ScheduledTaskPrincipal `
        -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -RunLevel Highest `
        -LogonType Interactive

    Register-ScheduledTask `
        -TaskName "WILLIAMS-RGSS-PORTAL-INSTALLER" `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Force | Out-Null

    Write-Info "Registered auto-resume task in Task Scheduler."
}

function Remove-ResumeOnBoot {
    if (Get-ScheduledTask -TaskName "WILLIAMS-RGSS-PORTAL-INSTALLER" -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName "WILLIAMS-RGSS-PORTAL-INSTALLER" -Confirm:$false
        Write-Info "Removed auto-resume scheduled task."
    }
}

function Install-DockerWindows {
    Write-Section "Installing Docker Desktop for Windows..."

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Info "Installing Docker Desktop via winget..."
        # winget exit code 3 means "already installed, upgrade attempted but
        # app was running" -- not a real failure, safe to continue.
        winget install --id Docker.DockerDesktop --exact `
            --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3) {
            Exit-WithError "winget failed to install Docker Desktop (exit code $LASTEXITCODE)."
        }

        Write-Info "Installing Git via winget..."
        winget install --id Git.Git --exact `
            --accept-source-agreements --accept-package-agreements
        # exit code 0 = installed, -1978335189 (0x8A150011) = already up to date
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
            Write-Warn "Git winget exit code: $LASTEXITCODE (may already be installed, continuing)"
        }
    } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Info "Using Chocolatey..."
        choco install docker-desktop git -y
        if ($LASTEXITCODE -ne 0) { Exit-WithError "Chocolatey install failed." }
    } else {
        Exit-WithError "Neither winget nor Chocolatey found. Install Docker manually: https://www.docker.com/products/docker-desktop/"
    }

    Write-Ok "Docker Desktop installed."
    Set-Stage "docker_installed"

    Write-Warn "A reboot is required to complete WSL2/Hyper-V setup."
    Write-Warn "The installer will resume automatically after you log back in."
    Register-ResumeOnBoot

    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    shutdown /r /t 10 /c "WILLIAMS-RGSS-PORTAL Installer: rebooting to complete Docker/WSL2 setup."
    exit 0
}

function Start-DockerDesktop {
    $ddExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $ddExe) {
        Write-Info "Launching Docker Desktop..."
        Start-Process -FilePath $ddExe
    } else {
        Write-Warn "Docker Desktop not found at expected path."
        Write-Warn "Please start Docker Desktop manually."
        Read-Host "Press Enter once Docker Desktop is running in the system tray"
    }
}

function Confirm-Docker {
    Write-Section "Verifying Docker..."
    # Run hello-world via cmd.exe so stderr pull progress never trips PS error handling.
    Write-Info "Running hello-world test image..."
    Invoke-Docker "run --rm hello-world"
    if ($LASTEXITCODE -ne 0) {
        Exit-WithError "Docker verification failed (exit $LASTEXITCODE). Check Docker Desktop is running."
    }
    Write-Ok "Docker verified."
}

# ==============================================================================
#  Portainer
# ==============================================================================

function Install-Portainer {
    Write-Section "Installing Portainer CE..."

    # Pre-create admin without a setup token; existing accounts are not reset.
    # https://docs.portainer.io/faqs/installing/setup-token
    $passwordFile = Join-Path $projectDir "portainer-admin-password.txt"
    if (-not (Test-Path $passwordFile)) {
        $password = "Aa1!" + (New-RandomSecret 18)
        [System.IO.File]::WriteAllText($passwordFile, $password, [System.Text.UTF8Encoding]::new($false))
    }
    if ((Get-Item $passwordFile).Length -eq 0) { Exit-WithError "Portainer password file is empty." }
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    icacls $passwordFile /inheritance:r /grant:r "$($currentUser):(R,W)" | Out-Null
    if ($LASTEXITCODE -ne 0) { Exit-WithError "Could not secure Portainer password file." }

    Invoke-Docker "volume inspect portainer_data" -quiet
    if ($LASTEXITCODE -ne 0) {
        Invoke-Docker "volume create portainer_data" -quiet
    }

    $existing = cmd /c "docker ps -a --format {{.Names}}" "2>&1" | Where-Object { $_ -eq "portainer" }
    if ($existing) {
        Write-Info "Removing existing Portainer container..."
        Invoke-Docker "rm -f portainer" -quiet
    }

    # Quote the mount for project paths containing spaces; keep Docker stderr
    # handling consistent with the rest of this Windows PowerShell installer.
    Invoke-Docker "run -d --name portainer --restart unless-stopped -p 9000:9000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data -v `"${passwordFile}:/run/secrets/portainer-admin-password:ro`" portainer/portainer-ce:latest --admin-password-file /run/secrets/portainer-admin-password"
    if ($LASTEXITCODE -ne 0) { Exit-WithError "Failed to start Portainer." }

    Write-Ok "Portainer installed."
    Write-Info "New installation: sign in as admin with the password in $passwordFile."
    Write-Info "Existing Portainer accounts retain their current passwords."
    Write-Ok "Web UI (HTTPS): https://localhost:9443"
    Write-Ok "Web UI (HTTP):  http://localhost:9000"
}

# ==============================================================================
#  Project setup
# ==============================================================================

$InstallAssetRef  = "alpha"
$InstallAssetBase = "https://raw.githubusercontent.com/RGSS-CS/documentation/$InstallAssetRef/static/InstScripts"
$ComposeSha256    = "d3923a4921c2759bf365d17df1cd9744cd4e6fd70242e324fea31e90b815f96f"
$NginxSha256      = "e0324656d6e0e24c87639b7ca70c8128f235f1d3f463355ece472beec6c432eb"

function Install-Asset([string]$name, [string]$expectedHash, [string]$destination) {
    $temporary = "$destination.tmp"
    Invoke-Download "$InstallAssetBase/$name" $temporary
    if (-not (Verify-Sha256 -path $temporary -expectedHash $expectedHash)) {
        Remove-Item -Path $temporary -Force -ErrorAction SilentlyContinue
        Exit-WithError "$name SHA-256 verification failed."
    }
    Move-Item -Path $temporary -Destination $destination -Force
    Write-Ok "$name downloaded and verified."
}

function Write-ProjectEnv([string]$projectDir, [string]$credFile) {
    $envPath = Join-Path $projectDir ".env"
    if (Test-Path $envPath) {
        Write-Info ".env already exists - leaving secrets untouched."
        return
    }

    Write-Section "Application configuration"

    $siteOrigin = (Read-Setting "SITE_URL" "Public site origin (full URL, including http:// or https://)" "http://localhost").TrimEnd('/')
    $siteUri = $null
    $validOrigin = [Uri]::TryCreate($siteOrigin, [UriKind]::Absolute, [ref]$siteUri)
    if (
        -not $validOrigin -or
        $siteUri.Scheme -notin @("http", "https") -or
        $siteUri.AbsolutePath -ne "/" -or
        -not [string]::IsNullOrEmpty($siteUri.Query) -or
        -not [string]::IsNullOrEmpty($siteUri.Fragment)
    ) {
        Exit-WithError "Public site origin must be a full HTTP(S) origin without a path (for example, https://dev.rgsscs.org)."
    }

    $publicMediaBaseUrl = Read-Setting "PUBLIC_MEDIA_BASE_URL" "Public media base URL" "$siteOrigin/media/"
    $publicMediaBaseUrl = $publicMediaBaseUrl.TrimEnd('/') + '/'
    $captchaUrl         = (Read-Setting "CAPTCHA_URL" "Public CAP captcha URL" "http://localhost:3001").TrimEnd('/')
    $superuserUsername  = Read-Setting "DJANGO_SUPERUSER_USERNAME" "Django superuser username" "admin"
    $superuserEmail     = Read-Setting "DJANGO_SUPERUSER_EMAIL" "Django superuser email" "admin@localhost"
    $postgresDb         = Read-Setting "POSTGRES_DB" "PostgreSQL database name" "db"
    $postgresUser       = Read-Setting "POSTGRES_USER" "PostgreSQL username" "db"
    $capSecret          = Read-Setting "CAP_SECRET" "Existing CAP site secret (leave blank to configure after startup)" ""
    $captchaVerifyUrl   = Read-Setting "CAPTCHA_VERIFY_URL" "Existing CAP verification URL (leave blank to configure after startup)" ""

    $allowedHosts       = (@("localhost", "127.0.0.1", "backend", "nginx", $siteUri.Host) | Select-Object -Unique) -join ","
    $csrfTrustedOrigins = (@("http://localhost", "http://127.0.0.1", $siteOrigin) | Select-Object -Unique) -join ","

    $secretKey         = New-RandomSecret 48
    $signingKey        = New-RandomSecret 48
    $revalidateSecret  = New-RandomSecret 32
    $adminKey          = New-RandomSecret 32
    $postgresPassword  = New-RandomSecret 24
    # 12 random bytes produce a 16-character password (96 bits of entropy).
    $superuserPassword = New-RandomSecret 12

    $envContent = @(
        "# AUTO-GENERATED by install.ps1 - do not commit this file.",
        "",
        "# ==============================================================================",
        "# CONFIGURABLE SETTINGS",
        "# Review these values before the first container startup.",
        "# ==============================================================================",
        "",
        "# Public URLs used by the frontend at container startup.",
        "PUBLIC_MEDIA_BASE_URL=$publicMediaBaseUrl",
        "CAPTCHA_URL=$captchaUrl",
        "# Hostname written into nginx.conf by the installer (no scheme, port or path).",
        "NGINX_SERVER_NAME=$($siteUri.Host)",
        "",
        "# ALLOWED_HOSTS uses hostnames only; CSRF_TRUSTED_ORIGINS uses full origins.",
        "# Public hostname: $($siteUri.Host)",
        "ALLOWED_HOSTS=$allowedHosts",
        "CSRF_TRUSTED_ORIGINS=$csrfTrustedOrigins",
        "",
        "# Initial Django administrator account.",
        "DJANGO_SUPERUSER_USERNAME=$superuserUsername",
        "DJANGO_SUPERUSER_EMAIL=$superuserEmail",
        "",
        "# CAP site settings. Blank values can be filled after creating a CAP site.",
        "CAP_SECRET=$capSecret",
        "CAPTCHA_VERIFY_URL=$captchaVerifyUrl",
        "",
        "# PostgreSQL database names.",
        "POSTGRES_DB=$postgresDb",
        "POSTGRES_USER=$postgresUser",
        "",
        "# ==============================================================================",
        "# NON-CONFIGURABLE / AUTO-GENERATED SETTINGS",
        "# The installer generates secrets and keeps internal service addresses here.",
        "# ==============================================================================",
        "",
        "# Frontend/internal application settings.",
        "API_URL=http://backend:8000",
        "# Shared backend/frontend secret authorizing cache refresh requests to /console/revalidate.",
        "REVALIDATE_SECRET=$revalidateSecret",
        "",
        "# CAP dashboard and storage.",
        "# CAP dashboard administrator login key; use it to manage CAPTCHA sites (not a Django password).",
        "ADMIN_KEY=$adminKey",
        "REDIS_URL=redis://valkey:6379",
        "",
        "# Django cryptographic and internal settings.",
        "# Django cryptographic secret for signed data, sessions and password-reset tokens; keep private.",
        "SECRET_KEY=$secretKey",
        "# Authentication token signing key; keep private and stable or existing tokens may stop working.",
        "SIGNING_KEY=$signingKey",
        "DJANGO_SUPERUSER_PASSWORD=$superuserPassword",
        "REVALIDATE_URL=http://frontend:3000/console/revalidate",
        "",
        "# PostgreSQL connection settings.",
        "POSTGRES_PASSWORD=$postgresPassword",
        "DB_HOST=db",
        "DB_PORT=5432"
    )
    [System.IO.File]::WriteAllLines($envPath, $envContent, [System.Text.UTF8Encoding]::new($false))

    $credContent = @(
        "# AUTO-GENERATED credentials. KEEP SECRET.",
        "# Django cryptographic secret for signed data, sessions and password-reset tokens; keep private.",
        "SECRET_KEY=$secretKey",
        "# Authentication token signing key; keep private and stable or existing tokens may stop working.",
        "SIGNING_KEY=$signingKey",
        "# Shared backend/frontend secret authorizing cache refresh requests to /console/revalidate.",
        "REVALIDATE_SECRET=$revalidateSecret",
        "DJANGO_SUPERUSER_USERNAME=$superuserUsername",
        "DJANGO_SUPERUSER_EMAIL=$superuserEmail",
        "DJANGO_SUPERUSER_PASSWORD=$superuserPassword",
        "POSTGRES_DB=$postgresDb",
        "POSTGRES_USER=$postgresUser",
        "POSTGRES_PASSWORD=$postgresPassword",
        "# CAP dashboard administrator login key; use it to manage CAPTCHA sites (not a Django password).",
        "ADMIN_KEY=$adminKey"
    )
    [System.IO.File]::WriteAllLines($credFile, $credContent, [System.Text.UTF8Encoding]::new($false))
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    icacls $envPath $credFile /inheritance:r /grant:r "$($currentUser):(R,W)" | Out-Null
    Write-Ok ".env and credentials.txt written."
}

function New-SharedNetwork {
    foreach ($network in @("internetwork", "external")) {
        Invoke-Docker "network inspect $network" -quiet
        if ($LASTEXITCODE -ne 0) {
            Invoke-Docker "network create $network" -quiet
            if ($LASTEXITCODE -ne 0) { Exit-WithError "Could not create $network." }
        }
        Write-Ok "Shared network '$network' is ready."
    }
}

function Set-NginxServerName([string]$projectDir) {
    $settings = @{}
    foreach ($line in Get-Content (Join-Path $projectDir ".env")) {
        if ($line -match '^(NGINX_SERVER_NAME|ALLOWED_HOSTS)=(.*)$') {
            $settings[$Matches[1]] = $Matches[2].Trim()
        }
    }
    $hostname = $settings["NGINX_SERVER_NAME"]
    if ([string]::IsNullOrEmpty($hostname)) {
        # Older .env files retain their secrets; infer the public hostname.
        $hostname = $settings["ALLOWED_HOSTS"] -split ',' | Where-Object {
            $_ -and $_ -notin @("localhost", "127.0.0.1", "backend", "nginx")
        } | Select-Object -First 1
        if (-not $hostname) { $hostname = "localhost" }
    }
    if ($hostname -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') {
        Exit-WithError "NGINX_SERVER_NAME must be a hostname or IPv4 address without a scheme, port or path."
    }
    $nginxPath = Join-Path $projectDir "nginx.conf"
    $content = [System.IO.File]::ReadAllText($nginxPath)
    $content = $content -replace 'server_name localhost;[^\r\n]*', "server_name $hostname;"
    [System.IO.File]::WriteAllText($nginxPath, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Ok "nginx server_name set to $hostname."
}

# ==============================================================================
#  Main
# ==============================================================================

Write-Section "RGSS Williams Portal Installer"

$stage = Get-Stage
if ($stage -eq "docker_installed") {
    Remove-ResumeOnBoot
    Write-Info "Resuming after reboot..."
}

if (Test-Docker) {
    Write-Info "Docker is already installed and running."
} elseif ($stage -eq "docker_installed") {
    Start-DockerDesktop
    if (-not (Wait-ForDocker -timeoutSeconds 300)) {
        Exit-WithError "Docker daemon did not start within 5 minutes."
    }
} else {
    Install-DockerWindows
}

Confirm-Docker

$projectDir = Join-Path $PSScriptRoot "project"
New-Item -ItemType Directory -Force -Path $projectDir | Out-Null
Push-Location $projectDir

$credFile = Join-Path $projectDir "credentials.txt"
Install-Asset "AIO_compose.yml" $ComposeSha256 (Join-Path $projectDir "compose.yml")
Install-Asset "nginx.conf" $NginxSha256 (Join-Path $projectDir "nginx.conf")
Write-ProjectEnv $projectDir $credFile
Set-NginxServerName $projectDir
New-SharedNetwork

Write-Info "Validating Docker Compose configuration..."
Invoke-Docker "compose --env-file .env -f compose.yml config --quiet"
if ($LASTEXITCODE -ne 0) { Exit-WithError "Docker Compose validation failed." }
Write-Ok "Docker Compose configuration is valid."
Install-Portainer

Write-Info "Pulling current application images..."
Invoke-Docker "compose --env-file .env -f compose.yml pull"
if ($LASTEXITCODE -ne 0) { Exit-WithError "Could not pull application images." }

Write-Info "Starting the all-in-one stack..."
Invoke-Docker "compose --env-file .env -f compose.yml up -d --wait"
if ($LASTEXITCODE -ne 0) {
    Invoke-Docker "compose --env-file .env -f compose.yml ps"
    Exit-WithError "The application stack failed to become healthy."
}

Pop-Location
Set-Stage "complete"

Write-Host ""
Write-Host "================================================================"
Write-Host "  Installation complete"
Write-Host "  Website:       http://localhost"
Write-Host "  API:           http://localhost/api/"
Write-Host "  CAP dashboard: http://localhost:3001"
Write-Host "  Portainer:     https://localhost:9443"
Write-Host ""
Write-Host "  CAP requires one manual setup step:"
Write-Host "    1. Sign in to the CAP dashboard with ADMIN_KEY."
Write-Host "    2. Create a site and copy its site key and secret."
Write-Host "    3. Set CAP_SECRET and CAPTCHA_VERIFY_URL in project\.env,"
Write-Host "       then recreate backend."
Write-Host "    4. CAPTCHA_URL and PUBLIC_MEDIA_BASE_URL are applied when the"
Write-Host "       frontend container starts; recreate it after changing either value."
Write-Host "================================================================"
Write-Host ""

Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
