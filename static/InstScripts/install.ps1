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

function New-RandomHex([int]$bytes = 32) {
    $buf = New-Object byte[] $bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($buf)
    return ($buf | ForEach-Object { $_.ToString("x2") }) -join ""
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

    Invoke-Docker "volume inspect portainer_data" -quiet
    if ($LASTEXITCODE -ne 0) {
        Invoke-Docker "volume create portainer_data" -quiet
    }

    $existing = cmd /c "docker ps -a --format {{.Names}}" "2>&1" | Where-Object { $_ -eq "portainer" }
    if ($existing) {
        Write-Info "Removing existing Portainer container..."
        Invoke-Docker "rm -f portainer" -quiet
    }

    Invoke-Docker "run -d --name portainer --restart unless-stopped -p 9000:9000 -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest"
    if ($LASTEXITCODE -ne 0) { Exit-WithError "Failed to start Portainer." }

    Write-Ok "Portainer installed."
    Write-Ok "Web UI (HTTPS): https://localhost:9443"
    Write-Ok "Web UI (HTTP):  http://localhost:9000"
}

# ==============================================================================
#  Project setup
# ==============================================================================

$InstallAssetRef  = "alpha"
$InstallAssetBase = "https://raw.githubusercontent.com/RGSS-CS/documentation/$InstallAssetRef/static/InstScripts"
$ComposeSha256    = "0d0a6041a4c1dc6909a0d17dee8381410912a0b8beed346731ad1be5aaca29a7"
$NginxSha256      = "485a51229cac3c7b039e9b911fdbe846e58cc8ae3bace815662cfcfb08223c48"

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

    $secretKey         = New-RandomHex 32
    $signingKey        = New-RandomHex 32
    $revalidateSecret  = New-RandomHex 32
    $adminKey          = New-RandomHex 32
    $postgresPassword  = New-RandomHex 24
    $superuserPassword = New-RandomHex 24

    $envContent = @(
        "# AUTO-GENERATED by install.ps1 - do not commit this file.",
        "",
        "# Frontend",
        "API_URL=http://backend:8000",
        "FRONTEND_REVALIDATE_URL=http://frontend:3000/api/revalidate",
        "REVALIDATE_SECRET=$revalidateSecret",
        "# Build-time value for the Next.js client bundle; see the completion notes.",
        "NEXT_PUBLIC_CAPTCHA_URL=",
        "",
        "# CAP dashboard and storage",
        "ADMIN_KEY=$adminKey",
        "REDIS_URL=redis://valkey:6379",
        "",
        "# Django",
        "SECRET_KEY=$secretKey",
        "SIGNING_KEY=$signingKey",
        "ALLOWED_HOSTS=localhost,127.0.0.1,backend,nginx",
        "CSRF_TRUSTED_ORIGINS=http://localhost,http://127.0.0.1",
        "DJANGO_SUPERUSER_USERNAME=admin",
        "DJANGO_SUPERUSER_EMAIL=admin@localhost",
        "DJANGO_SUPERUSER_PASSWORD=$superuserPassword",
        "REVALIDATE_URL=http://frontend:3000/api/revalidate",
        "",
        "# Create a site in the CAP dashboard, then fill in these two values.",
        "CAP_SECRET=",
        "CAPTCHA_VERIFY_URL=",
        "",
        "# PostgreSQL",
        "POSTGRES_DB=db",
        "POSTGRES_USER=db",
        "POSTGRES_PASSWORD=$postgresPassword",
        "DB_HOST=db",
        "DB_PORT=5432"
    )
    [System.IO.File]::WriteAllLines($envPath, $envContent, [System.Text.UTF8Encoding]::new($false))

    $credContent = @(
        "# AUTO-GENERATED credentials. KEEP SECRET.",
        "SECRET_KEY=$secretKey",
        "SIGNING_KEY=$signingKey",
        "REVALIDATE_SECRET=$revalidateSecret",
        "DJANGO_SUPERUSER_USERNAME=admin",
        "DJANGO_SUPERUSER_EMAIL=admin@localhost",
        "DJANGO_SUPERUSER_PASSWORD=$superuserPassword",
        "POSTGRES_DB=db",
        "POSTGRES_USER=db",
        "POSTGRES_PASSWORD=$postgresPassword",
        "ADMIN_KEY=$adminKey"
    )
    [System.IO.File]::WriteAllLines($credFile, $credContent, [System.Text.UTF8Encoding]::new($false))
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    icacls $envPath $credFile /inheritance:r /grant:r "$($currentUser):(R,W)" | Out-Null
    Write-Ok ".env and credentials.txt written."
}

function New-SharedNetwork {
    Write-Host ""
    Write-Host "==> Ensuring shared Docker network 'internetwork' exists..."
    Invoke-Docker "network inspect internetwork" -quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Info "'internetwork' already exists."
    } else {
        Invoke-Docker "network create internetwork" -quiet
        if ($LASTEXITCODE -ne 0) { Exit-WithError "Could not create internetwork." }
        Write-Ok "'internetwork' network created."
    }
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
Install-Portainer

$projectDir = Join-Path $PSScriptRoot "project"
New-Item -ItemType Directory -Force -Path $projectDir | Out-Null
Push-Location $projectDir

$credFile = Join-Path $projectDir "credentials.txt"
Install-Asset "AIO_compose.yml" $ComposeSha256 (Join-Path $projectDir "compose.yml")
Install-Asset "nginx.conf" $NginxSha256 (Join-Path $projectDir "nginx.conf")
Write-ProjectEnv $projectDir $credFile
New-SharedNetwork

Write-Info "Validating Docker Compose configuration..."
Invoke-Docker "compose --env-file .env -f compose.yml config --quiet"
if ($LASTEXITCODE -ne 0) { Exit-WithError "Docker Compose validation failed." }
Write-Ok "Docker Compose configuration is valid."

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
Write-Host "    4. NEXT_PUBLIC_CAPTCHA_URL is compiled into the prebuilt frontend"
Write-Host "       image. Rebuild it with your CAP URL, or update the frontend"
Write-Host "       to read the setting at runtime, before enabling captcha."
Write-Host "================================================================"
Write-Host ""

Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
