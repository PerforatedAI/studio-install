#!/bin/sh
# PerforatedAI Studio machine-scoped bootstrap.
#
# Run once per machine, from anywhere:
#   curl -fsSL https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.sh | sh
#
# Ensures the shared Server is running on this machine and installs machine-level
# artifacts: Skills to ~/.claude/skills/, register.sh to ~/.perforated_studio/bin/,
# and the machine manifest ~/.perforated_studio/installed.json.
#
# Projects are registered separately via register.sh (run by the Skill).
#
# This script runs on the HOST, not in the container: it calls docker and writes
# to the user's home directory.
set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# Piped straight to `sh` (the one-liner the header above documents), `$0` names
# no real file, so SELF_DIR above resolves to the caller's cwd rather than to
# where this script actually lives — and a sibling server-bootstrap.sh was
# never downloaded there either way, since only THIS file was fetched. Fall
# back to pulling it fresh from the same repo it shipped from. Prefer the local
# sibling when one exists (the repo checkout's own package/bootstrap.sh, used
# for local dev and by the shell tests) so that path never touches the network.
SERVER_BOOTSTRAP="$SELF_DIR/server-bootstrap.sh"
if [ ! -f "$SERVER_BOOTSTRAP" ]; then
  FETCH_DIR="$(mktemp -d)"
  SERVER_BOOTSTRAP="$FETCH_DIR/server-bootstrap.sh"
  if ! curl -fsSL "https://raw.githubusercontent.com/PerforatedAI/studio-install/main/server-bootstrap.sh" -o "$SERVER_BOOTSTRAP"; then
    printf 'error: could not find server-bootstrap.sh locally and failed to fetch it — check your network\n' >&2
    exit 1
  fi
  chmod +x "$SERVER_BOOTSTRAP"
fi

VERSION="latest"
PORT=3002
IMAGE=""
UPDATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --image)   IMAGE="$2"; shift 2 ;;
    --update)  UPDATE=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

SERVER_ARGS=""
if [ "$UPDATE" -eq 1 ]; then
  SERVER_ARGS="--update"
fi

# Ensure the Server is running and capture the resolved image reference.
if [ -n "$IMAGE" ]; then
  RESOLVED_IMAGE="$("$SERVER_BOOTSTRAP" --port "$PORT" --image "$IMAGE" $SERVER_ARGS)"
else
  RESOLVED_IMAGE="$("$SERVER_BOOTSTRAP" --version "$VERSION" --port "$PORT" $SERVER_ARGS)"
fi

# Install to home directory, not to the current working directory.
STUDIO_HOME="${HOME}/.perforated_studio"
mkdir -p "$STUDIO_HOME/bin"

SKILLS_DIR="${HOME}/.claude/skills"
mkdir -p "$SKILLS_DIR"

# Reconcile Skills: remove only those recorded in the previous manifest,
# leaving any hand-written Skills alone. ADR 0021.
PREV_MANIFEST="$STUDIO_HOME/installed.json"
if [ -f "$PREV_MANIFEST" ]; then
  PREVIOUS_SKILLS="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("skills", [])))' "$PREV_MANIFEST")"
  for skill in $PREVIOUS_SKILLS; do
    rm -rf "$SKILLS_DIR/$skill"
  done
fi

# Extract Skills from the resolved image via docker create + docker cp.
STAGE="$(mktemp -d)"
CID="$(docker create "$RESOLVED_IMAGE")"
docker cp "$CID:/app/package/skills/." "$STAGE"
docker cp "$CID:/app/package/register.sh" "$STUDIO_HOME/bin/register.sh"
# register.sh looks for server-bootstrap.sh at $STUDIO_HOME/bin first (its own
# SELF_DIR-based fallback only covers running it from inside a repo checkout) —
# without this copy, register.sh has nothing to find there on a real install.
docker cp "$CID:/app/package/server-bootstrap.sh" "$STUDIO_HOME/bin/server-bootstrap.sh"
# machine-uninstall.sh ships under its own source name (ticket 112) but is
# installed as uninstall.sh — the name the Operator actually runs.
docker cp "$CID:/app/package/machine-uninstall.sh" "$STUDIO_HOME/bin/uninstall.sh"
docker rm "$CID" >/dev/null
chmod +x "$STUDIO_HOME/bin/register.sh" "$STUDIO_HOME/bin/server-bootstrap.sh" "$STUDIO_HOME/bin/uninstall.sh"

# Install extracted Skills to ~/.claude/skills/
OUR_SKILLS=""
for skill_path in "$STAGE"/*/; do
  [ -d "$skill_path" ] || continue
  skill_name="$(basename "$skill_path")"
  rm -rf "$SKILLS_DIR/$skill_name"
  cp -R "$skill_path" "$SKILLS_DIR/$skill_name"
  OUR_SKILLS="$OUR_SKILLS $skill_name"
done
rm -rf "$STAGE"

# Write the machine manifest.
MANIFEST="$STUDIO_HOME/installed.json"
python3 - "$MANIFEST" "$RESOLVED_IMAGE" "$PORT" "$OUR_SKILLS" <<'EOF'
import datetime
import json
import sys

path, server_image, port, skill_names = sys.argv[1:5]
manifest = {
    "skills": skill_names.split(),
    "package_version": server_image.split(":")[-1],
    "server_image": server_image,
    "port": int(port),
    "installed_at": datetime.datetime.now(datetime.timezone.utc)
        .isoformat(timespec="seconds").replace("+00:00", "Z"),
}
with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
EOF
