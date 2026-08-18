#!/bin/sh
# Ensures the shared PerforatedAI Studio Server container is running on this
# machine. Idempotent, no project concept (ADR 0028) — this never touches
# .mcp.json or any project directory. Per-project registration (bootstrap.sh)
# calls this first, so install order never matters.
#
# By default, an already-running Server is left alone — re-running this (or
# bootstrap.sh) never refreshes it, even if a newer image is available. Pass
# --update to replace it: stop + remove the running container, then fall
# through to the normal pull/start path below. The named volume (and so the
# SQLite state keyed by Project ID) survives a `docker rm`, so this never
# loses registered Projects.
set -e

# GHCR, not Docker Hub: Docker Hub rate-limits anonymous pulls per IP, and the
# first thing this script does is an anonymous pull (ADR 0022).
IMAGE_REPO="ghcr.io/perforatedai/studio"
LABEL_KEY="org.opencontainers.image.version"
CONTAINER_NAME="perforatedai-studio-server"
VOLUME_NAME="perforatedai-studio-data"

VERSION="latest"
PORT=3002
IMAGE=""
UPDATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    # Dev hatch: start from a local image instead of pulling. Undocumented.
    --image)   IMAGE="$2"; shift 2 ;;
    --update)  UPDATE=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- already running? Nothing else to do but report what it's serving from —
# the caller (per-project registration) needs the image reference regardless of
# which path was taken, to docker cp the matching skills/export script.
# Unless --update was passed: then stop + remove it and fall through to the
# normal pull/start path, so it comes back up on whatever image is current.
if [ -n "$(docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" --format '{{.ID}}')" ]; then
  if [ "$UPDATE" -eq 0 ]; then
    docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME"
    exit 0
  fi
  echo "--update: stopping the running Server to restart it on a fresh image..." >&2
  docker stop "$CONTAINER_NAME" >/dev/null
  docker rm "$CONTAINER_NAME" >/dev/null
fi

if [ -n "$IMAGE" ]; then
  LOCAL_IMAGE=1
else
  LOCAL_IMAGE=0
  IMAGE="$IMAGE_REPO:$VERSION"
fi

# --- pull. Surface network/registry failures here, at server-bootstrap time,
# rather than in an invisible subprocess later.
if [ "$LOCAL_IMAGE" -eq 0 ]; then
  if ! docker pull "$IMAGE"; then
    printf 'error: failed to pull %s — check your network and that Docker is running\n' "$IMAGE" >&2
    exit 1
  fi
fi

# --- resolve. `latest` is an INPUT, never an output: what we run and record
# must be the concrete version, or the Server could silently drift on restart.
RESOLVED="$(docker inspect --format "{{index .Config.Labels \"$LABEL_KEY\"}}" "$IMAGE")"
if [ -z "$RESOLVED" ]; then
  printf 'error: %s carries no %s label — cannot determine its version\n' "$IMAGE" "$LABEL_KEY" >&2
  exit 1
fi
if [ "$LOCAL_IMAGE" -eq 1 ]; then
  PINNED="$IMAGE"
else
  PINNED="$IMAGE_REPO:$RESOLVED"
  if [ "$IMAGE" != "$PINNED" ]; then
    docker tag "$IMAGE" "$PINNED"
    docker rmi "$IMAGE" >/dev/null 2>&1 || true
    IMAGE="$PINNED"
  fi
fi

# --- smoke test: verify the image actually runs AND its deps import on this
# machine before starting the long-lived container.
if ! docker run --rm --entrypoint python "$IMAGE" -c "import mcp_server.server" >/dev/null 2>&1; then
  echo "error: $IMAGE failed to start on this machine. Details:" >&2
  docker run --rm --entrypoint python "$IMAGE" -c "import mcp_server.server" 2>&1 | sed 's/^/  /' >&2
  exit 1
fi

# --- start. Detached and --restart=always so it survives machine reboots
# (ADR 0028); bound to loopback only, since nothing authenticates this port yet
# (ADR 0028); the named volume is what makes the SQLite file survive
# `docker rm` + recreate on upgrade (ticket 75). No project mount at all —
# the Server has no filesystem access to any Project (ADR 0029).
docker run -d --restart=always \
  -p "127.0.0.1:$PORT:$PORT" \
  -v "$VOLUME_NAME:/perforated_tools" \
  --name "$CONTAINER_NAME" \
  "$IMAGE" >/dev/null

# --- wait for it to actually be ready. `docker run -d` returns as soon as the
# container starts, not once uvicorn is accepting connections — a real gap
# found by an actual end-to-end run (ticket 85), not a guess. Without this,
# the per-project registration that immediately follows POSTs to a port
# nothing is listening on yet. Overridable for tests only.
READY_RETRIES="${STUDIO_READY_RETRIES:-20}"
READY_INTERVAL="${STUDIO_READY_INTERVAL:-0.5}"
i=0
while ! curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge "$READY_RETRIES" ]; then
    printf 'error: %s started but never became ready on port %s\n' "$CONTAINER_NAME" "$PORT" >&2
    exit 1
  fi
  sleep "$READY_INTERVAL"
done

echo "$IMAGE"
