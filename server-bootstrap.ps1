# Ensures the shared PerforatedAI Studio Server container is running on this
# machine. Idempotent, no project concept (ADR 0028) - this never touches
# .mcp.json or any project directory. Per-project registration calls this first,
# so install order never matters.
#
# Outputs the resolved image reference on success.
#
# Plain ASCII only, deliberately: this file has no UTF-8 BOM (matching every
# other script here), and Windows PowerShell 5.1 - the version that actually
# ships on Windows, distinct from PowerShell 7's pwsh.exe - reads a
# BOM-less script using the system's legacy codepage, not UTF-8. A non-ASCII
# character like an em dash silently turns into mojibake, and depending on
# exactly where it lands, can corrupt string-literal parsing badly enough to
# throw "Missing closing '}'" - a real failure reported from a Windows
# machine, not a hypothetical.
[CmdletBinding()]
param(
    [string]$Version = "latest",
    [int]$Port = 3002,
    [string]$Image = "",
    [switch]$Update
)

$ErrorActionPreference = "Stop"

$ImageRepo = "ghcr.io/perforatedai/studio"
$LabelKey = "org.opencontainers.image.version"
$ContainerName = "perforatedai-studio-server"
$VolumeName = "perforated-studio-data"

# Check if Server is already running. If so and not --update, report its image and exit.
$RunningContainer = docker ps --filter "name=$ContainerName" --filter "status=running" --format "{{.ID}}" 2>&1 | Select-Object -First 1
if ($RunningContainer -and -not $Update) {
    $ImageRunning = docker inspect --format "{{.Config.Image}}" $ContainerName 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Output $ImageRunning
        exit 0
    }
}

# If --update, stop and remove the running container to restart it fresh.
if ($Update -and $RunningContainer) {
    Write-Host "--update: stopping the running Server to restart it on a fresh image..." -ForegroundColor Yellow
    docker stop $ContainerName *> $null
    docker rm $ContainerName *> $null
}

$LocalImage = $Image -ne ""
if (-not $LocalImage) {
    $Image = "${ImageRepo}:${Version}"
}

# Pull the image. Surface network/registry failures here, not in a subprocess later.
if (-not $LocalImage) {
    docker pull $Image 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "error: failed to pull $Image - check your network and that Docker is running" -ForegroundColor Red
        exit 1
    }
}

# Resolve the version from the image label. `latest` is an INPUT, never an output.
$Resolved = docker inspect --format "{{index .Config.Labels `"$LabelKey`"}}" $Image 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Resolved)) {
    Write-Host "error: $Image carries no $LabelKey label - cannot determine its version" -ForegroundColor Red
    exit 1
}

# Pin the resolved version so the Server doesn't drift on restart.
if ($LocalImage) {
    $Pinned = $Image
} else {
    $Pinned = "${ImageRepo}:${Resolved}"
    if ($Image -ne $Pinned) {
        docker tag $Image $Pinned 2>&1 | Out-Null
        docker rmi $Image *> $null
        $Image = $Pinned
    }
}

# Smoke test: verify the image actually runs and its deps import on this machine.
$SmokeOutput = docker run --rm --entrypoint python $Image -c "import mcp_server.server" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "error: $Image failed to start on this machine. Details:" -ForegroundColor Red
    $SmokeOutput | ForEach-Object { Write-Host "  $_" }
    exit 1
}

# Start the Server. Detached, --restart=always, bound to loopback, named volume.
docker run -d --restart=always `
    -p "127.0.0.1:${Port}:${Port}" `
    -v "${VolumeName}:/perforated_tools" `
    --name $ContainerName `
    $Pinned *> $null

if ($LASTEXITCODE -ne 0) {
    Write-Host "error: failed to start Server container" -ForegroundColor Red
    exit 1
}

# Wait for the Server to become ready. Without this, project registration POSTs
# to a port nothing is listening on yet.
$ReadyRetries = if ($env:STUDIO_READY_RETRIES) { [int]$env:STUDIO_READY_RETRIES } else { 20 }
$ReadyInterval = if ($env:STUDIO_READY_INTERVAL) { [double]$env:STUDIO_READY_INTERVAL } else { 0.5 }

$i = 0
while ($true) {
    try {
        $response = Invoke-WebRequest "http://127.0.0.1:${Port}/" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        break
    } catch {
        $i += 1
        if ($i -ge $ReadyRetries) {
            Write-Host "error: $ContainerName started but never became ready on port $Port" -ForegroundColor Red
            exit 1
        }
        Start-Sleep -Milliseconds ($ReadyInterval * 1000)
    }
}

Write-Output $Pinned
