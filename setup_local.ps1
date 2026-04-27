<#
.SYNOPSIS
    setup_local.ps1 - Bootstrap Axiom + Crypto-Bot stack di Windows (Docker Desktop).
.DESCRIPTION
    Versi mirror dari setup_local.sh untuk Ubuntu. Generate password, build .env,
    siapin pgbouncer/userlist.txt, init git submodule, lalu docker compose up -d.
.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\setup_local.ps1
#>

[CmdletBinding()]
param(
    [switch]$Force  # paksa regenerate .env walau sudah ada
)

$ErrorActionPreference = 'Stop'

# --- Helpers --------------------------------------------------------------
function Log-Info  { param($m) Write-Host "[setup] $m" -ForegroundColor Cyan }
function Log-Ok    { param($m) Write-Host "[ OK  ] $m" -ForegroundColor Green }
function Log-Warn  { param($m) Write-Host "[warn] $m" -ForegroundColor Yellow }
function Log-Fail  { param($m) Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $RootDir

# --- 1) Prereq check ------------------------------------------------------
Log-Info "Step 1/8: cek prerequisite..."

try { docker --version | Out-Null } catch { Log-Fail "Docker Desktop tidak terinstall / tidak running. Install: https://docs.docker.com/desktop/install/windows-install/" }
try { docker compose version | Out-Null } catch { Log-Fail "Docker Compose plugin tidak ada. Update Docker Desktop." }
try { git --version | Out-Null } catch { Log-Fail "git tidak ada. Install: https://git-scm.com/download/win" }

Log-Ok "Tools tersedia."

# --- 2) Generate passwords ------------------------------------------------
Log-Info "Step 2/8: generate password..."

$EnvFile = Join-Path $RootDir ".env"

if ((Test-Path $EnvFile) -and -not $Force) {
    Log-Warn ".env sudah ada — skip generate. Pakai -Force untuk regenerate."
} else {
    if (-not (Test-Path "$RootDir\.env.example")) { Log-Fail ".env.example tidak ditemukan." }

    Copy-Item "$RootDir\.env.example" $EnvFile -Force

    function New-Password {
        $bytes = New-Object 'System.Byte[]' 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        ([Convert]::ToBase64String($bytes) -replace '[^A-Za-z0-9]', '').Substring(0, 32)
    }

    $passwords = @{
        REPLACE_AXIOM_DB_PW     = New-Password
        REPLACE_CRYPTOBOT_DB_PW = New-Password
        REPLACE_OBSERVER_DB_PW  = New-Password
        REPLACE_PARAMSYNC_DB_PW = New-Password
        REPLACE_N8N_DB_PW       = New-Password
        REPLACE_PGB_ADMIN_PW    = New-Password
        REPLACE_REDIS_PW        = New-Password
        REPLACE_N8N_BASIC_PW    = New-Password
    }

    $envContent = Get-Content $EnvFile -Raw
    foreach ($key in $passwords.Keys) {
        $envContent = $envContent -replace [regex]::Escape($key), $passwords[$key]
    }
    Set-Content $EnvFile -Value $envContent -NoNewline

    # Restrict file permissions ke current user only
    $acl = Get-Acl $EnvFile
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        'FullControl', 'Allow'
    )
    $acl.SetAccessRule($rule)
    Set-Acl $EnvFile $acl

    Log-Ok "8 password generated, .env permissions di-restrict."

    # Save credentials.txt
    $credPath = Join-Path $RootDir "credentials.txt"
    @"
# =============================================================================
# credentials.txt - generated $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
# JANGAN COMMIT FILE INI. Tambahkan ke .gitignore.
# =============================================================================
DB_PASSWORD_AXIOM=$($passwords.REPLACE_AXIOM_DB_PW)
DB_PASSWORD_CRYPTOBOT=$($passwords.REPLACE_CRYPTOBOT_DB_PW)
DB_PASSWORD_OBSERVER=$($passwords.REPLACE_OBSERVER_DB_PW)
DB_PASSWORD_PARAMSYNC=$($passwords.REPLACE_PARAMSYNC_DB_PW)
DB_PASSWORD_N8N=$($passwords.REPLACE_N8N_DB_PW)
PGB_ADMIN_PASSWORD=$($passwords.REPLACE_PGB_ADMIN_PW)
REDIS_PASSWORD=$($passwords.REPLACE_REDIS_PW)
N8N_BASIC_AUTH_PASSWORD=$($passwords.REPLACE_N8N_BASIC_PW)

# WAJIB di-set MANUAL di .env:
#   OPENROUTER_API_KEY=
#   ANTHROPIC_API_KEY=
#   BYBIT_API_KEY=
#   BYBIT_API_SECRET=
#   TELEGRAM_BOT_TOKEN_AXIOM=
#   TELEGRAM_BOT_TOKEN_CRYPTOBOT=
#   TELEGRAM_CHAT_ID=
#   BOT_PIN_HASH=
"@ | Set-Content $credPath
}

# --- 3) PgBouncer userlist ------------------------------------------------
Log-Info "Step 3/8: generate pgbouncer/userlist.txt..."

$PgbDir = Join-Path $RootDir "pgbouncer"
$Userlist = Join-Path $PgbDir "userlist.txt"
if (-not (Test-Path $PgbDir)) { Log-Fail "Folder pgbouncer/ tidak ada." }

if ((Test-Path $Userlist) -and (Get-Item $Userlist).Length -gt 0 -and -not $Force) {
    Log-Warn "userlist.txt sudah ada — skip."
} else {
    # Parse .env into hashtable
    $envVars = @{}
    Get-Content $EnvFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object {
        $kv = $_ -split '=', 2
        $envVars[$kv[0]] = $kv[1]
    }

    function Get-PgbMd5Hash {
        param([string]$User, [string]$Pass)
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Pass + $User)
        $hash = $md5.ComputeHash($bytes)
        $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
        return "md5$hex"
    }

    $userlistContent = @"
"axiom_user"          "$(Get-PgbMd5Hash 'axiom_user' $envVars['DB_PASSWORD_AXIOM'])"
"cryptobot_user"      "$(Get-PgbMd5Hash 'cryptobot_user' $envVars['DB_PASSWORD_CRYPTOBOT'])"
"readonly_observer"   "$(Get-PgbMd5Hash 'readonly_observer' $envVars['DB_PASSWORD_OBSERVER'])"
"parameter_sync_user" "$(Get-PgbMd5Hash 'parameter_sync_user' $envVars['DB_PASSWORD_PARAMSYNC'])"
"n8n_user"            "$(Get-PgbMd5Hash 'n8n_user' $envVars['DB_PASSWORD_N8N'])"
"pgbouncer_admin"     "$(Get-PgbMd5Hash 'pgbouncer_admin' $envVars['PGB_ADMIN_PASSWORD'])"
"@
    Set-Content $Userlist -Value $userlistContent
    Log-Ok "userlist.txt generated."
}

# --- 4) Submodule ---------------------------------------------------------
Log-Info "Step 4/8: init git submodule crypto-bot..."

$SubDir = Join-Path $RootDir "agents\crypto_bot"
$SubGit = Join-Path $SubDir ".git"

if (Test-Path $SubGit) {
    git submodule update --init --recursive
    Log-Ok "Submodule already initialized."
} else {
    if (Test-Path "$RootDir\.gitmodules") {
        $gm = Get-Content "$RootDir\.gitmodules" -Raw
        if ($gm -match 'agents/crypto_bot') {
            git submodule update --init --recursive
        }
    } else {
        if ((Test-Path $SubDir) -and -not (Test-Path $SubGit)) {
            $bak = "$SubDir.bak.$(Get-Date -Format yyyyMMddHHmmss)"
            Log-Warn "agents\crypto_bot ada tapi bukan submodule — backup ke $bak"
            Move-Item $SubDir $bak
        }
        git submodule add https://github.com/junadwi009/crypto-bot.git agents/crypto_bot
        git submodule update --init --recursive
    }
    Log-Ok "Submodule terinisialisasi."
}

# --- 5) Validate ----------------------------------------------------------
Log-Info "Step 5/8: validasi config..."

if (-not (Test-Path "$RootDir\docker-compose.yaml")) { Log-Fail "docker-compose.yaml tidak ada." }
if (-not (Test-Path "$RootDir\init.sql")) { Log-Fail "init.sql tidak ada." }
if (-not (Test-Path "$RootDir\init_cryptobot_db.sql")) { Log-Fail "init_cryptobot_db.sql tidak ada." }

docker compose config --quiet
if ($LASTEXITCODE -ne 0) { Log-Fail "docker-compose.yaml invalid." }
Log-Ok "Config valid."

# --- 6) Up ----------------------------------------------------------------
Log-Info "Step 6/8: docker compose up -d --build..."
docker compose up -d --build
if ($LASTEXITCODE -ne 0) { Log-Fail "docker compose up gagal." }
Log-Ok "Containers spawning..."

# --- 7) Healthcheck -------------------------------------------------------
Log-Info "Step 7/8: tunggu service ready (max 120 detik)..."

$required = @('axiom_db', 'axiom_redis', 'axiom_pgbouncer', 'axiom_brain', 'cryptobot_main')
$elapsed = 0; $allOk = $false
while ($elapsed -lt 120) {
    $allOk = $true
    foreach ($svc in $required) {
        $status = (docker inspect -f '{{.State.Health.Status}}' $svc 2>$null)
        if ($status -and $status -ne 'healthy' -and $status -ne 'no-healthcheck') {
            $allOk = $false; break
        }
    }
    if ($allOk) { break }
    Start-Sleep 5; $elapsed += 5; Write-Host -NoNewline "."
}
Write-Host ""

if ($allOk) { Log-Ok "Service core healthy dalam ${elapsed}s." }
else { Log-Warn "Timeout 120s. Cek: docker compose ps; docker compose logs <service>" }

# --- 8) Summary -----------------------------------------------------------
Log-Info "Step 8/8: summary"

@"

==============================================================================
  AXIOM + CRYPTO-BOT LOCAL STACK READY (Windows)
==============================================================================

  Container status:    docker compose ps
  Logs (semua):        docker compose logs -f
  Stop all:            docker compose down
  Reset (NUKE data):   docker compose down -v

  n8n dashboard:       http://localhost:5678
  Crypto-bot API:      http://localhost:8000
  PgBouncer port:      6432

  Credentials:         .\credentials.txt
  Env file:            .\.env

  WAJIB DIISI MANUAL DI .env:
    - OPENROUTER_API_KEY
    - ANTHROPIC_API_KEY
    - BYBIT_API_KEY / BYBIT_API_SECRET
    - TELEGRAM_BOT_TOKEN_AXIOM
    - TELEGRAM_BOT_TOKEN_CRYPTOBOT
    - TELEGRAM_CHAT_ID
    - BOT_PIN_HASH

  Next: baca CLAUDE_INSTRUCTIONS.md, lalu DEVELOPMENT_ROADMAP.md.
==============================================================================
"@ | Write-Host
