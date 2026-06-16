    #Requires -Version 5.1

# ==============================================================================
#  RGSS Williams Portal -- Windows Installer (Native PowerShell)
#
#  Installs Docker Desktop, Portainer, and sets up the backend + frontend.
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

$BACKEND_REPO         = "https://github.com/RGSS-CS/williams-rgss-website-dev-backend.git"
$FRONTEND_COMPOSE_RAW = "https://raw.githubusercontent.com/RGSS-CS/williams-rgss-website-dev-frontend/main/compose.yml"

function Setup-Backend([string]$projectDir, [string]$credFile) {
    Write-Host ""
    Write-Host "==> Setting up backend..."

    $backendDir = Join-Path $projectDir "backend"
    $exitCode = Invoke-CloneOrPull $BACKEND_REPO $backendDir
    if ($exitCode -ne 0) { Exit-WithError "Git clone/pull failed for backend." }
    Write-Ok "Backend repository ready."

    $envPath = Join-Path $backendDir ".env"
    if (Test-Path $envPath) {
        Write-Info "backend/.env already exists - leaving untouched."
        return
    }

    Write-Host "  Generating secrets..."
    $secretKey         = New-RandomHex 32
    $postgresPassword  = New-RandomHex 24
    $superuserPassword = New-RandomHex 24
    $postgresDb        = "db"
    $postgresUser      = "db"
    $superuserUsername = "admin"
    $superuserEmail    = "admin@localhost"
    $allowedHosts      = "localhost,backend"
    $csrfOrigins       = "http://localhost"

    Write-Host "  [AUTO] SECRET_KEY        -> $($secretKey.Substring(0,12))... (truncated)"
    Write-Host "  [AUTO] POSTGRES_PASSWORD -> $($postgresPassword.Substring(0,8))... (truncated)"

    $envContent = @(
        "# -- Django ---------------------------------------------------------------",
        "# AUTO-GENERATED by install.ps1 -- do NOT commit this file",
        "SECRET_KEY=$secretKey",
        "ALLOWED_HOSTS=$allowedHosts",
        "CSRF_TRUSTED_ORIGINS=$csrfOrigins",
        "DJANGO_SUPERUSER_USERNAME=$superuserUsername",
        "DJANGO_SUPERUSER_EMAIL=$superuserEmail",
        "DJANGO_SUPERUSER_PASSWORD=$superuserPassword",
        "",
        "# -- PostgreSQL ------------------------------------------------------------",
        "POSTGRES_DB=$postgresDb",
        "POSTGRES_USER=$postgresUser",
        "POSTGRES_PASSWORD=$postgresPassword",
        "DB_HOST=db",
        "DB_PORT=5432"
    )
    [System.IO.File]::WriteAllLines($envPath, $envContent, [System.Text.UTF8Encoding]::new($false))
    Write-Ok "backend/.env written."

    if ($credFile) {
        $credContent = @(
            "# -- Backend credentials --------------------------------------------------",
            "SECRET_KEY=$secretKey",
            "DJANGO_SUPERUSER_USERNAME=$superuserUsername",
            "DJANGO_SUPERUSER_EMAIL=$superuserEmail",
            "DJANGO_SUPERUSER_PASSWORD=$superuserPassword",
            "POSTGRES_DB=$postgresDb",
            "POSTGRES_USER=$postgresUser",
            "POSTGRES_PASSWORD=$postgresPassword"
        )
        Add-Content -Path $credFile -Value $credContent -Encoding UTF8
    }
}

function Setup-Frontend([string]$projectDir, [string]$credFile) {
    Write-Host ""
    Write-Host "==> Setting up frontend..."

    $frontendDir = Join-Path $projectDir "frontend"
    New-Item -ItemType Directory -Force -Path $frontendDir | Out-Null

    $composeDest = Join-Path $frontendDir "compose.yml"
    Write-Host "  -> Downloading frontend/compose.yml..."
    Invoke-Download $FRONTEND_COMPOSE_RAW $composeDest
    Write-Host "  [OK] frontend/compose.yml downloaded."

    $envPath = Join-Path $frontendDir ".env"
    if (Test-Path $envPath) {
        Write-Info "frontend/.env already exists - leaving untouched."
        return
    }

    Write-Host "  Generating secrets..."
    $adminKey = New-RandomHex 24
    Write-Host "  [AUTO] ADMIN_KEY -> $($adminKey.Substring(0,8))... (truncated)"

    $envContent = @(
        "# -- Frontend -------------------------------------------------------------",
        "# AUTO-GENERATED by install.ps1 -- do NOT commit this file",
        "",
        "API_URL=http://backend:8000",
        "",
        "# -- Captcha / Admin ------------------------------------------------------",
        "ADMIN_KEY=$adminKey",
        "REDIS_URL=redis://valkey:6379"
    )
    [System.IO.File]::WriteAllLines($envPath, $envContent, [System.Text.UTF8Encoding]::new($false))
    Write-Ok "frontend/.env written."

    if ($credFile) {
        $credContent = @(
            "# -- Frontend credentials -------------------------------------------------",
            "ADMIN_KEY=$adminKey"
        )
        Add-Content -Path $credFile -Value $credContent -Encoding UTF8
    }
}

function New-SharedNetwork {
    Write-Host ""
    Write-Host "==> Ensuring shared Docker network 'internetwork' exists..."
    $networks = cmd /c "docker network ls --format {{.Name}}" "2>&1"
    if ($networks -contains "internetwork") {
        Write-Host "  -> 'internetwork' already exists. Skipping."
    } else {
        Invoke-Docker "network create internetwork" -quiet
        Write-Host "  [OK] 'internetwork' network created."
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

# -- Step 1: Docker ------------------------------------------------------------

if (Test-Docker) {
    Write-Host "==> Docker already running. Skipping install."
} elseif ($stage -eq "docker_installed") {
    Write-Info "Docker was installed before reboot - starting Docker Desktop..."
    Start-DockerDesktop
    if (-not (Wait-ForDocker -timeoutSeconds 300)) {
        Exit-WithError "Docker daemon did not start within 5 minutes. Start Docker Desktop manually and re-run."
    }
    Write-Ok "Docker Desktop is running."
} else {
    Install-DockerWindows
    # Install-DockerWindows reboots -- nothing below runs on first pass.
}

# -- Step 2: Verify ------------------------------------------------------------
Confirm-Docker

# -- Step 3: Portainer ---------------------------------------------------------
Install-Portainer

# -- Step 4: Project -----------------------------------------------------------

$projectDir = Join-Path $PSScriptRoot "project"
New-Item -ItemType Directory -Force -Path $projectDir | Out-Null
Push-Location $projectDir

$credFile = Join-Path $projectDir "credentials.txt"
if (-not (Test-Path $credFile)) {
    $credHeader = @(
        "# AUTO-GENERATED credentials. KEEP SECRET.",
        "# Contains Django, PostgreSQL, and frontend keys."
    )
    [System.IO.File]::WriteAllLines($credFile, $credHeader, [System.Text.UTF8Encoding]::new($false))
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    icacls $credFile /inheritance:r /grant:r "${currentUser}:(R,W)" | Out-Null
}

Setup-Backend  $projectDir $credFile
Setup-Frontend $projectDir $credFile
New-SharedNetwork

Write-Host ""
Write-Host "================================================================"
Write-Host "  Setup complete!"
Write-Host ""
Write-Host "  Files written:"
Write-Host "    $projectDir\backend\.env         <- KEEP SECRET"
Write-Host "    $projectDir\frontend\.env        <- KEEP SECRET"
Write-Host "    $projectDir\credentials.txt      <- KEEP SECRET"
Write-Host "================================================================"
Write-Host ""

# -- Step 5: Start services ----------------------------------------------------

Write-Host "  -> Starting backend (PostgreSQL + Django)..."
Invoke-Docker "compose -f `"$(Join-Path $projectDir 'backend\compose.yml')`" up -d --wait"
if ($LASTEXITCODE -ne 0) { Exit-WithError "Backend failed to start." }

Write-Host ""
Write-Host "  -> Starting frontend (Next.js + Valkey)..."
Invoke-Docker "compose -f `"$(Join-Path $projectDir 'frontend\compose.yml')`" up -d --wait"
if ($LASTEXITCODE -ne 0) { Exit-WithError "Frontend failed to start." }

Pop-Location
Set-Stage "complete"

Write-Host ""
Write-Host "================================================================"
Write-Host "  Services started:"
Write-Host "    Frontend  -> http://localhost:3000"
Write-Host "    Backend   -> http://localhost:8000"
Write-Host "    Portainer -> https://localhost:9443"
Write-Host "================================================================"
Write-Host ""

Stop-Transcript -ErrorAction SilentlyContinue | Out-Null

Write-Host "  Rebooting in 10 seconds..."
shutdown /r /t 10 /c "RGSS-WILLIAMS-PORTAL install complete."