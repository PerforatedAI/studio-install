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

STUDIO_HOME="${HOME}/.perforated_studio"
MANIFEST="$STUDIO_HOME/installed.json"

SIGNUP_ENDPOINT="${SIGNUP_ENDPOINT:-https://api.perforatedai.com/signup}"
SLACK_INVITE_URL="${SLACK_INVITE_URL:-https://join.slack.com/t/perforatedcommunity/shared_invite/zt-409j8mfv9-fMOyIHI7LIKHa1Gs6Tit_A}"
BOOTSTRAP_SCRIPT_VERSION="v0.2.5"

# The Signup Gate (ADR 0044): required before any Docker activity, fails
# closed on submission failure. Completion is recorded in the machine
# manifest so a later run never re-prompts.
run_signup_gate() {
  EMAIL=""
  while [ -z "$EMAIL" ]; do
    printf 'Work email: '
    read -r INPUT
    if printf '%s' "$INPUT" | python3 -c 'import re, sys
sys.exit(0 if re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", sys.stdin.read().strip()) else 1)'; then
      EMAIL="$INPUT"
    else
      printf 'That does not look like a valid email address - please try again.\n'
    fi
  done

  # Arrow-key row-highlighting was prototyped here (package/prototype-menu-select.sh,
  # since deleted) as an alternative to numeric choice. Confirmed feasible in strict
  # POSIX /bin/sh via `stty -icanon -echo` + `dd bs=1` (no `read -n`/`-s`, those are
  # bash-only). Not swapped in: it needs a real TTY, which breaks the stdin-piped
  # prompt answers test-signup-gate.sh relies on, and would need a Windows port
  # (bootstrap.ps1) kept in lockstep. Worth a follow-up ticket if this is prioritized.
  ROLE=""
  ROLE_OTHER=""
  printf 'Role:\n  1) Software engineer\n  2) ML engineer\n  3) Data scientist\n  4) Student\n  5) Other\n'
  while [ -z "$ROLE" ]; do
    printf 'Choice [1-5]: '
    read -r CHOICE
    case "$CHOICE" in
      1) ROLE="software_engineer" ;;
      2) ROLE="ml_engineer" ;;
      3) ROLE="data_scientist" ;;
      4) ROLE="student" ;;
      5)
        ROLE="other"
        printf 'Please describe your role: '
        read -r ROLE_OTHER
        ;;
      *) printf 'Please enter a number from 1-5.\n' ;;
    esac
  done

  MODALITY=""
  MODALITY_OTHER=""
  printf 'Data modality:\n  1) Computer vision\n  2) Language\n  3) Tabular\n  4) Other\n'
  while [ -z "$MODALITY" ]; do
    printf 'Choice [1-4]: '
    read -r CHOICE
    case "$CHOICE" in
      1) MODALITY="computer_vision" ;;
      2) MODALITY="language" ;;
      3) MODALITY="tabular" ;;
      4)
        MODALITY="other"
        printf 'Please describe your data modality: '
        read -r MODALITY_OTHER
        ;;
      *) printf 'Please enter a number from 1-4.\n' ;;
    esac
  done

  PAYLOAD="$(python3 -c '
import json, sys
email, role, role_other, modality, modality_other, source, script_version, os_name, timestamp = sys.argv[1:10]
print(json.dumps({
    "email": email,
    "role": role,
    "role_other": role_other,
    "modality": modality,
    "modality_other": modality_other,
    "source": source,
    "script_version": script_version,
    "os": os_name,
    "timestamp": timestamp,
}))
' "$EMAIL" "$ROLE" "$ROLE_OTHER" "$MODALITY" "$MODALITY_OTHER" "cli-bootstrap" "$BOOTSTRAP_SCRIPT_VERSION" "$(uname -s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"

  if ! curl -fsS -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" "$SIGNUP_ENDPOINT" >/dev/null; then
    printf 'error: signup failed - could not reach %s. Check your network and try again.\n' "$SIGNUP_ENDPOINT" >&2
    exit 1
  fi

  mkdir -p "$STUDIO_HOME"
  python3 - "$MANIFEST" <<'EOF'
import json
import os
import sys

path = sys.argv[1]
manifest = {}
if os.path.isfile(path):
    with open(path) as f:
        manifest = json.load(f)
manifest["signup_completed"] = True
with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
EOF

  printf '\nYou are in! Join us on Slack: %s\n\n' "$SLACK_INVITE_URL"
}

VERSION="latest"
PORT=3002
IMAGE=""
UPDATE=0
SKIP_SIGNUP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version)      VERSION="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --image)        IMAGE="$2"; shift 2 ;;
    --update)       UPDATE=1; shift ;;
    # Dev hatch: skip the signup gate prompts. Undocumented - for the local
    # dev loop (repeated `dev-build.sh` + bootstrap cycles), never the public
    # curl one-liner.
    --skip-signup)  SKIP_SIGNUP=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

SIGNUP_COMPLETED=0
if [ -f "$MANIFEST" ]; then
  SIGNUP_COMPLETED="$(python3 -c 'import json, sys
try:
    m = json.load(open(sys.argv[1]))
    print(1 if m.get("signup_completed") else 0)
except Exception:
    print(0)' "$MANIFEST")"
fi

if [ "$SIGNUP_COMPLETED" != "1" ] && [ "$SKIP_SIGNUP" -ne 1 ]; then
  run_signup_gate
fi

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
mkdir -p "$STUDIO_HOME/bin"

SKILLS_DIR="${HOME}/.claude/skills"
mkdir -p "$SKILLS_DIR"

# Reconcile Skills: remove only those recorded in the previous manifest,
# leaving any hand-written Skills alone. ADR 0021.
PREV_MANIFEST="$MANIFEST"
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

# Write the machine manifest, preserving signup_completed (recorded earlier
# by run_signup_gate, before any Docker activity ran).
python3 - "$MANIFEST" "$RESOLVED_IMAGE" "$PORT" "$OUR_SKILLS" <<'EOF'
import datetime
import json
import os
import sys

path, server_image, port, skill_names = sys.argv[1:5]
signup_completed = False
if os.path.isfile(path):
    with open(path) as f:
        signup_completed = bool(json.load(f).get("signup_completed"))
manifest = {
    "skills": skill_names.split(),
    "package_version": server_image.split(":")[-1],
    "server_image": server_image,
    "port": int(port),
    "installed_at": datetime.datetime.now(datetime.timezone.utc)
        .isoformat(timespec="seconds").replace("+00:00", "Z"),
    "signup_completed": signup_completed,
}
with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
EOF
