# PerforatedAI Studio machine-scoped bootstrap for native Windows PowerShell.
#
# Run once per machine, from anywhere:
#   iwr -useb https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.ps1 -OutFile bootstrap.ps1
#   .\bootstrap.ps1
#
# Ensures the shared Server is running on this machine and installs machine-level
# artifacts: Skills to $env:USERPROFILE\.claude\skills\, register.ps1 to
# $env:USERPROFILE\.perforated_studio\bin\, and the machine manifest.
#
# Projects are registered separately via register.ps1 (run by the Skill).
#
# Re-run it to upgrade. It is idempotent.
#
# This script runs on the HOST, not in the container: it calls docker and writes
# to the user's home directory, never the working directory.
[CmdletBinding()]
param(
    [string]$Version = "latest",
    [int]$Port = 3002,
    # Dev hatch: install from a local image instead of pulling. Undocumented.
    [string]$Image = "",
    # Upgrade: stop and replace the running Server. Undocumented.
    [switch]$Update,
    # Dev hatch: skip the signup gate prompts. Undocumented - for the local
    # dev loop, never the public install one-liner.
    [switch]$SkipSignup
)

$ErrorActionPreference = "Stop"

# Piped straight to `iex` (the README's documented upgrade one-liner), there is
# no script file at all - $MyInvocation.MyCommand.Path is $null - and even the
# two-step `-OutFile bootstrap.ps1; .\bootstrap.ps1` form only ever downloads
# THIS file, never a server-bootstrap.ps1 sibling alongside it. Either way,
# fall back to fetching it fresh from the same repo this script shipped from.
# Prefer a local sibling when one exists (a repo checkout's own
# package\windows\bootstrap.ps1, used for local dev) so that path never
# touches the network.
$ScriptDir = $null
if ($MyInvocation.MyCommand.Path) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$ServerBootstrapScript = $null
if ($ScriptDir) {
    $Candidate = Join-Path $ScriptDir "server-bootstrap.ps1"
    if (Test-Path $Candidate) { $ServerBootstrapScript = $Candidate }
}

if (-not $ServerBootstrapScript) {
    $FetchDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $FetchDir | Out-Null
    $ServerBootstrapScript = Join-Path $FetchDir "server-bootstrap.ps1"
    try {
        Invoke-WebRequest `
            -Uri "https://raw.githubusercontent.com/PerforatedAI/studio-install/main/server-bootstrap.ps1" `
            -OutFile $ServerBootstrapScript `
            -UseBasicParsing `
            -ErrorAction Stop
    } catch {
        Write-Error "error: could not find server-bootstrap.ps1 locally and failed to fetch it - check your network: $_"
        exit 1
    }
}

# Install to home directory, not to the current working directory.
$StudioHome = Join-Path $env:USERPROFILE ".perforated_studio"
$BinDir = Join-Path $StudioHome "bin"
$SkillsDir = Join-Path $env:USERPROFILE ".claude\skills"
$PrevManifest = Join-Path $StudioHome "installed.json"

$SignupEndpoint = if ($env:SIGNUP_ENDPOINT) { $env:SIGNUP_ENDPOINT } else { "https://api.perforatedai.com/signup" }
$SlackInviteUrl = if ($env:SLACK_INVITE_URL) { $env:SLACK_INVITE_URL } else { "https://join.slack.com/t/perforatedcommunity/shared_invite/zt-409j8mfv9-fMOyIHI7LIKHa1Gs6Tit_A" }
$BootstrapScriptVersion = "v0.2.6"

# The Signup Gate (ADR 0044): required before any Docker activity, fails
# closed on submission failure. Completion is recorded in the machine
# manifest so a later run never re-prompts.
function Invoke-SignupGate {
    $Email = ""
    while (-not $Email) {
        $EmailInput = Read-Host "Work email"
        if ($EmailInput -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            $Email = $EmailInput
        } else {
            Write-Host "That does not look like a valid email address - please try again."
        }
    }

    $Role = ""
    $RoleOther = ""
    Write-Host "Role:"
    Write-Host "  1) Software engineer"
    Write-Host "  2) ML engineer"
    Write-Host "  3) Data scientist"
    Write-Host "  4) Student"
    Write-Host "  5) Other"
    while (-not $Role) {
        $Choice = Read-Host "Choice [1-5]"
        switch ($Choice) {
            "1" { $Role = "software_engineer" }
            "2" { $Role = "ml_engineer" }
            "3" { $Role = "data_scientist" }
            "4" { $Role = "student" }
            "5" {
                $Role = "other"
                $RoleOther = Read-Host "Please describe your role"
            }
            default { Write-Host "Please enter a number from 1-5." }
        }
    }

    $Modality = ""
    $ModalityOther = ""
    Write-Host "Data modality:"
    Write-Host "  1) Computer vision"
    Write-Host "  2) Language"
    Write-Host "  3) Tabular"
    Write-Host "  4) Other"
    while (-not $Modality) {
        $Choice = Read-Host "Choice [1-4]"
        switch ($Choice) {
            "1" { $Modality = "computer_vision" }
            "2" { $Modality = "language" }
            "3" { $Modality = "tabular" }
            "4" {
                $Modality = "other"
                $ModalityOther = Read-Host "Please describe your data modality"
            }
            default { Write-Host "Please enter a number from 1-4." }
        }
    }

    $Payload = [PSCustomObject]@{
        email          = $Email
        role           = $Role
        role_other     = $RoleOther
        modality       = $Modality
        modality_other = $ModalityOther
        source         = "cli-bootstrap"
        script_version = $BootstrapScriptVersion
        os             = "Windows"
        timestamp      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Uri $SignupEndpoint -Method Post -ContentType "application/json" -Body $Payload -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "error: signup failed - could not reach ${SignupEndpoint}. Check your network and try again: $_"
        exit 1
    }

    New-Item -ItemType Directory -Force -Path $StudioHome | Out-Null
    $Manifest = @{}
    if (Test-Path $PrevManifest) {
        try {
            $Existing = Get-Content $PrevManifest -Raw | ConvertFrom-Json
            $Existing.PSObject.Properties | ForEach-Object { $Manifest[$_.Name] = $_.Value }
        } catch {
            Write-Host "warning: failed to parse previous manifest, starting fresh: $_" -ForegroundColor Yellow
        }
    }
    $Manifest["signup_completed"] = $true
    $Manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $PrevManifest

    Write-Host ""
    Write-Host "You are in! Join us on Slack: $SlackInviteUrl"
    Write-Host ""
}

$SignupCompleted = $false
if (Test-Path $PrevManifest) {
    try {
        $ExistingManifest = Get-Content $PrevManifest -Raw | ConvertFrom-Json
        if ($ExistingManifest.signup_completed) { $SignupCompleted = $true }
    } catch {
        Write-Host "warning: failed to parse previous manifest, treating signup as incomplete: $_" -ForegroundColor Yellow
    }
}
if (-not $SignupCompleted -and -not $SkipSignup) { Invoke-SignupGate }

$ServerBootstrapArgs = @("-Version", $Version, "-Port", $Port)
if ($Image) { $ServerBootstrapArgs += @("-Image", $Image) }
if ($Update) { $ServerBootstrapArgs += "-Update" }

try {
    $ResolvedImage = & $ServerBootstrapScript @ServerBootstrapArgs
    if ($LASTEXITCODE -ne 0) { exit 1 }
} catch {
    Write-Error "error: server-bootstrap.ps1 failed: $_"
    exit 1
}

# Install to home directory, not to the current working directory.
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null

# Reconcile Skills: remove only those recorded in the previous manifest,
# leaving any hand-written Skills alone (ADR 0021).
if (Test-Path $PrevManifest) {
    try {
        $PreviousManifestObj = Get-Content $PrevManifest -Raw | ConvertFrom-Json
        foreach ($skill in @($PreviousManifestObj.skills)) {
            $skillPath = Join-Path $SkillsDir $skill
            if (Test-Path $skillPath) { Remove-Item -Recurse -Force $skillPath }
        }
    } catch {
        Write-Host "warning: failed to parse previous manifest, skipping reconciliation: $_" -ForegroundColor Yellow
    }
}

# Extract Skills and register.ps1 from the resolved image via docker create + docker cp.
$Stage = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

try {
    $Cid = docker create $ResolvedImage 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Cid)) {
        Write-Error "error: failed to create a container from $ResolvedImage"
        exit 1
    }

    docker cp "${Cid}:/app/package/skills/." $Stage 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        docker rm $Cid *> $null
        Write-Error "error: failed to extract skills from $ResolvedImage"
        exit 1
    }

    # Windows scripts ship under package\windows\ in the image, not package\ -
    # a source path that never matched what's actually there for register.ps1
    # meant this docker cp always failed.
    docker cp "${Cid}:/app/package/windows/register.ps1" (Join-Path $BinDir "register.ps1") 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        docker rm $Cid *> $null
        Write-Error "error: failed to extract register.ps1 from $ResolvedImage"
        exit 1
    }

    # server-bootstrap.ps1 lands here too: register.ps1 looks for it at
    # $StudioHome\bin\server-bootstrap.ps1 first, and nothing had ever put it
    # there on a real install.
    docker cp "${Cid}:/app/package/windows/server-bootstrap.ps1" (Join-Path $BinDir "server-bootstrap.ps1") 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        docker rm $Cid *> $null
        Write-Error "error: failed to extract server-bootstrap.ps1 from $ResolvedImage"
        exit 1
    }

    # Machine teardown script - the Operator runs it as
    # $StudioHome\bin\uninstall-server.ps1, per its own header comment, but
    # nothing had ever placed it there either.
    docker cp "${Cid}:/app/package/windows/uninstall-server.ps1" (Join-Path $BinDir "uninstall-server.ps1") 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        docker rm $Cid *> $null
        Write-Error "error: failed to extract uninstall-server.ps1 from $ResolvedImage"
        exit 1
    }

    docker rm $Cid *> $null
} finally {
    if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
}

# Install extracted Skills to $env:USERPROFILE\.claude\skills\
$OurSkills = @()
Get-ChildItem -Directory -Path $Stage -ErrorAction SilentlyContinue | ForEach-Object {
    $skillName = $_.Name
    $dest = Join-Path $SkillsDir $skillName
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Copy-Item -Recurse -Force -Path $_.FullName -Destination $dest
    $OurSkills += $skillName
}

# Record what we installed. This manifest is the record of what this installer
# OWNS: uninstall reads it to know what to tear down, and the next run reads it
# to know what to clean up before laying down a new version. signup_completed
# was already recorded by Invoke-SignupGate, before any Docker activity ran -
# carry it forward rather than clobbering it.
$SignupCompletedFlag = $false
if (Test-Path $PrevManifest) {
    try {
        $SignupCompletedFlag = [bool](Get-Content $PrevManifest -Raw | ConvertFrom-Json).signup_completed
    } catch { }
}
$ManifestObj = [PSCustomObject]@{
    image            = $ResolvedImage
    version          = ($ResolvedImage -split ':')[-1]
    port             = $Port
    skills           = [array]$OurSkills
    installed_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    signup_completed = $SignupCompletedFlag
}
$ManifestObj | ConvertTo-Json -Depth 10 | Set-Content -Path $PrevManifest

Write-Host "Installed PerforatedAI Studio at machine level"
Write-Host "  Server:   running (port $Port)"
Write-Host "  skills:   $SkillsDir"
Write-Host "  register: $BinDir\register.ps1"
Write-Host ""
Write-Host "Next: register your project with /register-project-studio in Claude Code"
Write-Host "To upgrade, re-run: iwr -useb https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.ps1 | iex"
