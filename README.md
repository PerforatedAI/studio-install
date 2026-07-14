# PerforatedAI Studio — installer

This repository contains one file: [`bootstrap.sh`](bootstrap.sh), the installer for PerforatedAI Studio.

**Read it before you run it.** It's about 150 lines of plain shell, and that's the point of this repo existing at all — you shouldn't have to pull a multi-gigabyte image to find out what a script is going to do to your machine.

---

## Install

Run this from the root of the project you want to add the Dashboard to:

```sh
curl -fsSL https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.sh -o bootstrap.sh
sh bootstrap.sh
```

Or, if you'd rather not read it first:

```sh
curl -fsSL https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.sh | sh
```

Then **restart Claude Code**, so it picks up the new `.mcp.json`, and type `/dashboard`.

### Requirements

`docker` (running) and `python3` on the host.

### Options

| Flag | Default | |
|---|---|---|
| `--version` | `latest` | Install a specific version, e.g. `--version v0.1.1` |
| `--port` | `3002` | Port the Dashboard listens on |

Through a pipe, flags go to `sh`, not to `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.sh | sh -s -- --port 4000
```

---

## What it does to your project

1. Pulls the Studio image from `ghcr.io/perforatedai/studio` and checks it actually runs on your machine — so a bad image fails now, loudly, instead of silently inside a background process later.
2. Copies the Claude Code skills out of the image into `.claude/skills/`.
3. Writes `.perforated_tools/` — the runtime launcher, the uninstaller, and a record of what was installed.
4. Adds a `dashboard` entry to your `.mcp.json`, leaving any other entries alone.

Nothing is installed system-wide. Everything lives in the project you ran it from.

---

## Upgrading

Run the installer again. That's the whole upgrade path.

It's idempotent, and it reconciles: skills that a new version renamed or dropped are removed rather than left behind to rot in `.claude/skills/`.

**Your own skills are never touched.** The installer keeps a record of the skills *it* installed, and only ever removes those.

There's deliberately no `update.sh` — anything shipped inside the image is, by definition, the *previous* version's logic, and upgrading is exactly when you want the *newest* installer. That's the one at the URL above.

---

## Uninstalling

The installer left the uninstaller in your project:

```sh
.perforated_tools/uninstall.sh
```

It removes the MCP entry, the skills it installed, the launcher, and the Docker image. It needs no network. It leaves your own skills alone, along with anything else under `.perforated_tools/` — your exports and saved training runs are yours.

---

## Why the installer lives here and not in the image

Everything else *is* in the image: the skills, the launcher, the uninstaller. That's what makes it impossible for your skills and the server they talk to be at different versions — they're the same artifact.

The installer is the exception, for two reasons. It's the code most likely to need a fix, because it's the code that touches every user's particular Docker setup; welding it into the image would mean a full rebuild to correct a typo, and anyone pinned to an older version would keep the broken copy forever. And it's the one piece we're asking you to pipe into a shell — so it should be a file you can open in a browser and read, not a blob you have to extract.
