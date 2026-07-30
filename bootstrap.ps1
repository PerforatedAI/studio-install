# PerforatedAI Studio installer for native Windows PowerShell (no WSL/Git Bash
# required). Counterpart of bootstrap.sh — see that file for the annotated
# rationale behind each step; this mirrors its behavior exactly.
#
# Run from inside the project you want to install into:
#   iwr -useb https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.ps1 -OutFile bootstrap.ps1
#   .\bootstrap.ps1
#
# Re-run it to upgrade. It is idempotent.
#
# This script runs on the HOST, not in the container: it calls docker and writes
# .mcp.json, neither of which a container can do for us.
[CmdletBinding()]
param(
    [string]$Version = "latest",
    [int]$Port = 3002,
    # Dev hatch: install from a local image instead of pulling. Undocumented.
    [string]$Image = ""
)

$ErrorActionPreference = "Stop"

# GHCR, not Docker Hub: Docker Hub rate-limits anonymous pulls per IP, and the
# first thing this script does is an anonymous pull. A team behind one corporate
# NAT would hit `toomanyrequests` on a machine where nothing is wrong (ADR 0022).
$ImageRepo = "ghcr.io/perforatedai/studio"
$LabelKey = "org.opencontainers.image.version"

# --image names an image that already exists locally (a dev build): use it as-is
# and skip the pull. Otherwise we install a published version from the registry.
$LocalImage = $Image -ne ""
if (-not $LocalImage) {
    $Image = "${ImageRepo}:${Version}"
}

# --- pull. Surface network/registry failures here, at install time, rather than
# in the invisible MCP subprocess later.
if (-not $LocalImage) {
    docker pull $Image
    if ($LASTEXITCODE -ne 0) {
        Write-Error "error: failed to pull $Image — check your network and that Docker is running"
        exit 1
    }
}

# --- resolve. `latest` is an INPUT to this installer, never an output: the image
# reference we write into .mcp.json is re-resolved by Claude Code on every session
# start, so a floating tag there would let the MCP Server drift to a new version
# while the skills we copy to disk below stay frozen at this one (ADR 0023).
#
# The version rides inside the image as a label, so reading it back needs no
# registry API and no second network call.
$Resolved = docker inspect --format "{{index .Config.Labels `"$LabelKey`"}}" $Image
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Resolved)) {
    Write-Error "error: $Image carries no $LabelKey label — cannot determine its version"
    exit 1
}

# What goes into .mcp.json. For a local dev build that's the image itself — wiring
# up a published tag the local build isn't would point every session at the wrong
# image (or none at all).
if ($LocalImage) {
    $Pinned = $Image
} else {
    $Pinned = "${ImageRepo}:${Resolved}"
    # Give the daemon the image under the name everything else refers to. Pulling
    # `:latest` stores it under THAT tag, but .mcp.json and the manifest name the
    # resolved tag — so without this the daemon holds no image called
    # `…:v0.1.0`, uninstall's `docker rmi` finds nothing and the image leaks, and
    # the user's first session re-pulls what is already on disk.
    #
    # Then drop the tag we pulled under, so the resolved ref is the ONLY local
    # reference. `docker rmi <tag>` deletes the tag, not the image, while any other
    # tag still points at it — leave `:latest` behind and uninstall's rmi succeeds
    # while the image quietly stays on disk.
    if ($Image -ne $Pinned) {
        docker tag $Image $Pinned
        if ($LASTEXITCODE -ne 0) {
            Write-Error "error: failed to tag $Image as $Pinned"
            exit 1
        }
        docker rmi $Image *> $null
        # Everything below must now refer to the pinned ref. `docker run` and
        # `docker create` silently PULL an image that isn't present locally, so a
        # later command still naming `:latest` would fetch it again and recreate the
        # very tag we just dropped.
        $Image = $Pinned
    }
}

# --- smoke test: verify the image actually runs AND its deps import on this
# machine before we wire up the MCP config. Importing the module exercises the
# heavy imports (torch, the ml plugin) without starting the blocking server.
# A failure here is loud; the same failure inside the MCP subprocess later is not.
$SmokeOutput = docker run --rm --entrypoint python $Image -c "import mcp_server.server" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "error: $Image failed to start on this machine. Details:" -ForegroundColor Red
    $SmokeOutput | ForEach-Object { Write-Host "  $_" }
    exit 1
}

$PwdAbs = (Get-Location).Path
$McpFile = Join-Path $PwdAbs ".mcp.json"
$ToolsDir = Join-Path $PwdAbs ".perforated_tools"
$SkillsDir = Join-Path $PwdAbs ".claude\skills"

$Manifest = Join-Path $ToolsDir "installed.json"

# --- reconcile. Re-running this script is the upgrade path, so a version that
# renames or drops a skill must take the old one away with it — otherwise it sits
# orphaned in .claude\skills\, still loaded by Claude, calling tools that may no
# longer exist.
#
# We remove ONLY the skills our own manifest says we installed. Never the whole of
# .claude\skills\ — the user keeps their own skills in there, and eating a
# customer's hand-written work on upgrade is unforgivable. The manifest is the
# only thing that lets us tell our skills from theirs.
if (Test-Path $Manifest) {
    $PreviousManifest = Get-Content $Manifest -Raw | ConvertFrom-Json
    foreach ($skill in @($PreviousManifest.skills)) {
        $skillPath = Join-Path $SkillsDir $skill
        if (Test-Path $skillPath) { Remove-Item -Recurse -Force $skillPath }
    }
}

# --- extract the Package the image carries: the skills, the runtime launcher and
# the uninstaller (ADR 0021). /app/package/ is a frozen contract — this script is
# always published from main but may be run against an image cut long ago.
#
# `docker cp` rather than a bind mount, and a staging dir first, so we learn
# exactly which skills came out of the image. Listing .claude\skills\ afterwards
# would sweep the user's own skills into our manifest — and a later uninstall
# would then delete them.
New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null

$Stage = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

$Cid = docker create $Image
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Cid)) {
    Write-Error "error: failed to create a container from $Image"
    exit 1
}
docker cp "${Cid}:/app/package/skills/." $Stage
if ($LASTEXITCODE -ne 0) { Write-Error "error: failed to extract skills from $Image"; exit 1 }
docker cp "${Cid}:/app/package/windows/dashboard-run.ps1" (Join-Path $ToolsDir "dashboard-run.ps1")
if ($LASTEXITCODE -ne 0) { Write-Error "error: failed to extract dashboard-run.ps1 from $Image"; exit 1 }
docker cp "${Cid}:/app/package/windows/uninstall.ps1" (Join-Path $ToolsDir "uninstall.ps1")
if ($LASTEXITCODE -ne 0) { Write-Error "error: failed to extract uninstall.ps1 from $Image"; exit 1 }
docker rm $Cid *> $null

$OurSkills = @()
Get-ChildItem -Directory -Path $Stage | ForEach-Object {
    $skillName = $_.Name
    $dest = Join-Path $SkillsDir $skillName
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Copy-Item -Recurse -Force -Path $_.FullName -Destination $dest
    $OurSkills += $skillName
}
Remove-Item -Recurse -Force $Stage

if (-not (Test-Path $McpFile)) {
    "{}" | Set-Content -Path $McpFile
}

# Write or overwrite the dashboard mcpServers entry, preserving other keys.
$Config = Get-Content $McpFile -Raw | ConvertFrom-Json
if (-not $Config.mcpServers) {
    $Config | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([PSCustomObject]@{}) -Force
}

# Forward slashes: Docker Desktop's bind-mount parsing on Windows is happiest with
# them, and it avoids the drive-letter colon colliding with the `-v` flag's own
# `:` separators.
$CwdForward = $PwdAbs -replace '\\', '/'
$DashboardRunPath = Join-Path $ToolsDir "dashboard-run.ps1"
$DashboardEntry = [PSCustomObject]@{
    command = "powershell.exe"
    args = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $DashboardRunPath,
        "run", "--rm", "-i",
        "-p", "${Port}:${Port}",
        "-v", "${CwdForward}:/workspace:ro",
        "-v", "${CwdForward}/.perforated_tools:/perforated_tools:rw",
        $Pinned
    )
}
$Config.mcpServers | Add-Member -NotePropertyName dashboard -NotePropertyValue $DashboardEntry -Force
$Config | ConvertTo-Json -Depth 10 | Set-Content -Path $McpFile

# --- record what we installed. This manifest is the record of what this installer
# OWNS: uninstall reads it to know what to tear down, and the next run reads it to
# know what to clean up before laying down a new version. Without it we would have
# to guess, and guessing means either leaving orphans behind or deleting skills the
# user wrote themselves.
$ManifestObj = [PSCustomObject]@{
    image        = $Pinned
    version      = $Resolved
    port         = $Port
    skills       = [array]$OurSkills
    installed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}
$ManifestObj | ConvertTo-Json -Depth 10 | Set-Content -Path $Manifest

$BootstrapUrl = "https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.ps1"

Write-Host "Installed PerforatedAI Studio $Resolved on port $Port"
Write-Host "  skills:    $SkillsDir"
Write-Host "  uninstall: $(Join-Path $ToolsDir 'uninstall.ps1')"
Write-Host ""
# Re-running this script IS the upgrade path — there is no update.ps1, because
# anything shipped in the image is by definition the previous version's logic.
# Nothing else tells the user this, so say it here.
Write-Host "To upgrade, re-run the installer:"
Write-Host "  iwr -useb $BootstrapUrl -OutFile bootstrap.ps1; .\bootstrap.ps1"
