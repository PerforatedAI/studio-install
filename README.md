# PerforatedAI Studio — installer

This repository contains the installer for PerforatedAI Studio: a machine-level bootstrap script that
sets up a shared Server, plus a README that describes what it does.

**Read it before you run it.** It's about 150 lines of plain shell, and that's the point of this repo
existing at all — you shouldn't have to pull a multi-gigabyte image to find out what a script is
going to do to your machine.

---

## Install

**Run this from anywhere on your machine.** It's a one-time, machine-level install:

```sh
curl -fsSL https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.sh -o bootstrap.sh
sh bootstrap.sh
```

Or, if you'd rather not read it first:

```sh
curl -fsSL https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.sh | sh
```

After this completes, **register each project** by running `/register-project-studio` in Claude Code.
Then restart Claude Code so it picks up the new `.mcp.json`, and type `/dashboard-studio`.

**Native Windows (PowerShell, no WSL/Git Bash needed):**

```powershell
iwr -useb https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.ps1 -OutFile bootstrap.ps1
.\bootstrap.ps1
```

> **Windows support:** `bootstrap.ps1` now mirrors the Unix flow. This implementation is based on the Unix design but **has not been tested on a real Windows machine**. If you encounter issues, please report them.

### Requirements

`docker` (running) on the host.

### Options

| Flag | Default | |
|---|---|---|
| `--version` | `latest` | Install a specific version, e.g. `--version v0.1.1` |
| `--port` | `3002` | Port the shared Server listens on (only meaningful for the first project to run this) |
| `--update` | — | Stop and replace the running Server with a fresh one |

Through a pipe, flags go to `sh`, not to `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.sh | sh -s -- --port 4000
```

---

## What it does to your machine

1. Pulls the Studio image from `ghcr.io/perforatedai/studio` and checks it actually runs on your machine — so a bad image fails now, loudly, instead of silently inside a background process later.
2. Starts a shared Docker container (`perforatedai-studio-server`) that runs on this machine, independent of any Claude Code session. If one is already running, this is a no-op.
3. Stores Server state in a named Docker volume (`perforatedai-studio-data`) so that data survives an image upgrade.
4. Records the installation in `~/.perforated_studio/` for tracking and upgrades.

**It does not touch any project directories.** Each project registers itself separately via the `/register-project-studio` Skill in Claude Code, which adds entries to that project's `.mcp.json` and `.perforated_tools/` — but leaves nothing on disk until the Skill is run.

---

## Upgrading

To upgrade the shared Server to a new version, run the installer again with `--update`:

```sh
curl -fsSL https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.sh | sh -s -- --update
```

It's idempotent. Without `--update`, re-running the installer ensures the machine-level Server is
running (starting it if it isn't) and records the new version — but does not stop a running Server
that's already up.

There's deliberately no `update.sh` — anything shipped inside the image is, by definition, the
*previous* version's logic, and upgrading is exactly when you want the *newest* installer. That's
the one at the URL above.

Individual projects refresh their skills and scripts by re-running `/register-project-studio` in
Claude Code.

---

## Uninstalling

To remove the shared Server:

```sh
~/.perforated_studio/uninstall-server.sh
```

It removes the Server container and the Docker image. It needs no network. Projects remain on disk
but will not reach the Server until it is reinstalled. Your project files and exports are never
touched.

---

## Why the installer lives here and not in the image

Everything else *is* in the image: the skills, the launcher, the uninstaller. That's what makes it impossible for your skills and the server they talk to be at different versions — they're the same artifact.

The installer is the exception, for two reasons. It's the code most likely to need a fix, because it's the code that touches every user's particular Docker setup; welding it into the image would mean a full rebuild to correct a typo, and anyone pinned to an older version would keep the broken copy forever. And it's the one piece we're asking you to pipe into a shell — so it should be a file you can open in a browser and read, not a blob you have to extract.
