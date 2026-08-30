# Quickstart

Zero to a live dendrite training run. About 10 minutes, most of it Docker pulling an image.

For what each piece *is*, see [README.md](README.md). This is just the happy path.

---

## Before you start

- **Docker**, running. The shared Server ships as a container; the installer fails fast if Docker isn't up.
- **Python**, in the project's own environment, with `torch` installed. The export script and the
  PerforatedAI training loop run locally in that environment, not inside the Server container.
- **Claude Code**, in the project you want to add dendrites to.
- **A PyTorch project** with a model class and a dataloader you can import.

You do **not** need to install PerforatedAI or the Dashboard by hand. The skills walk you through it.

---

## 1. Machine install (once per machine)

**Run this from anywhere** — it's a machine-level installer, not per-project:

```sh
curl -fsSL https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.sh | sh
```

Add `-s -- --port 4000` if something already owns port 3002. (The `-s --` is how you pass flags
through a pipe — they go to `sh`, not to `curl`.)

**Native Windows (PowerShell, no WSL/Git Bash needed):**

```powershell
iwr -useb https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.ps1 -OutFile bootstrap.ps1
.\bootstrap.ps1
```

Add `-Port 4000` if something already owns port 3002.

This starts the shared Server (a single long-lived container, independent of any Claude Code session).
Every project on this machine reuses the same Server — no second container, no port conflict, no
need to re-run this step.

**Then restart Claude Code.** It reads `.mcp.json` at startup, so a running session won't see the
Dashboard until you do.

---

## 2. Register this project (once per project)

In the Claude Code session in your project, ask Claude to register it:

```
/register-project-studio
```

The Skill walks you through it. Your project gets its own Project ID and only ever sees its own data.

**Then restart Claude Code.** It reads `.mcp.json` at startup, so a running session won't see the
Dashboard until you do. This is the single most common reason step 3 fails.

---

## 3. Check it's alive

```
/dashboard-studio
```

Claude pings the Server and opens the Dashboard in your browser. If it says the server isn't
connected, see [Troubleshooting](#troubleshooting).

## 4. Look at your model

```
/visualize-model-studio
```

Claude asks for your model file, class name, and dataloader, runs the export script locally, and
opens the result as an interactive graph. Click any node for its type, shape, and constructor args.

This step is optional, but it is the fastest way to confirm the export can actually import your
model — which is the same thing dendrite setup needs. Better to find out here.

## 5. Add dendrites

```
/perforate-my-model-studio
```

The Skill walks you through wrapping your model with PerforatedAI: which layers get dendrites, what
the switching policy is, and how the training loop changes. It writes a Perforation Config next to
your model.

Multi-GPU? It pulls in the `perforatedai-distributed` skill on its own; you don't have to ask.

## 6. Train, and watch it grow

```
/train-my-model-studio
```

Claude collects your save name and training script, wires the training run to the Dashboard, opens
the **Training View**, and hands you the command to run. Start training, and the page fills in live:

- **Dendrites** — the diagram on the left. Each time a dendrite set is *successfully integrated*, a
  new dendrite sprouts, tapping the same inputs as the neuron and feeding back into it. The count
  below it is exact even when the drawing caps out.
- **Score per epoch** — validation and train score, with each switch marked. Reload bursts (PerforatedAI
  re-trying a candidate dendrite set) branch the line instead of drawing backward over itself.
- **Learning Rate**, **Epoch Times**, **Param Counts**, **PB Scores** — the diagnostics, in the grid.

All the charts start visible. Ask Claude to hide the noisy ones (`hide the epoch times chart`) and
it will; the choice resets on the next run.

> **Watch the gap.** More switches than dendrites is normal and interesting: it means PerforatedAI
> tried a dendrite set and rejected it because it didn't earn its place. Three switches with two
> dendrites is the model telling you it's saturating.

## 7. Read the results

```
/perforatedai-analyze-studio
```

The Skill reads the run output and tells you what the dendrites bought you — accuracy per parameter
added, where returns started diminishing, what to try next.

---

## Upgrading

The machine install and project registration are now separate, so upgrades happen at two levels.

### Machine-level upgrade (shared Server)

To upgrade the shared Server to a new version:

```sh
curl -fsSL https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.sh | sh -s -- --update
```

This stops and replaces the shared Server with a fresh container, then ensures the current machine's
registration is up to date. Every other project registered against the Server keeps its Project ID
and data — that state lives in a named Docker volume, not in the container itself.

### Project-level upgrade (project's scripts and skills)

To refresh a project's scripts and skills against the running Server:

```
/register-project-studio
```

Re-running registration against the same machine re-syncs the project's scripts and keeps its
existing Project ID. This is the only step needed when the Server is already running — you never
need to run `bootstrap.sh` again for subsequent projects.

---

## Uninstall

There are two levels of uninstall with different meanings.

### Remove a single project's registration

In the Claude Code session in that project:

```
/unregister-project-studio
```

This removes the project's `.mcp.json` entry, the skills it installed, and its registration files
(`project.json`, `installed.json`, the export script). Your own skills, and anything else you put in
`.perforated_tools/` (exports, training runs), are left alone. **Does not touch the shared Server** —
other projects on this machine keep running untouched.

### Remove the shared Server (machine-level)

```sh
.perforated_tools/uninstall-server.sh
```

On Windows: `.perforated_tools\uninstall-server.ps1`

This stops and removes the shared Server container and its Docker image. Projects remain registered
but will not be able to reach the Server until it is reinstalled. Existing project files and skills
are left untouched.

---

## Troubleshooting

**`/dashboard-studio` says the MCP Server isn't connected.**
Almost always a stale Claude Code session. Restart it. If that doesn't do it, check
`docker ps --filter name=perforatedai-studio-server` and `docker logs perforatedai-studio-server`
for the Server's own output.

**Port already in use.**
This only matters for the very first project on a machine — that's the one that picks the Server's
port. Re-run the machine install with `--port`: 
`curl -fsSL https://raw.githubusercontent.com/PerforatedAI/studio-install/main/bootstrap.sh | sh -s -- --port 4000`.
Every project after that reuses whatever port the running Server is already on.

**The Training View says "waiting for training run".**
The page is open and connected; it just hasn't received a `run_start` yet. That's expected until
your training script actually starts.

**The dendrite diagram never grows.**
Dendrites only appear on *successful integration*, which is not the same as a switch. If the Score
chart shows switches but the diagram stays at zero, PerforatedAI is trying dendrite sets and
rejecting all of them — that's a real result, not a bug. Check the PB Scores chart: flat or absent
candidate scores mean the dendrites aren't learning anything worth keeping.

---

## Testing this branch locally

To try the new two-step flow before it ships publicly:

```sh
./dev-build.sh
sh package/bootstrap.sh --image perforated_studio_mcp:dev
```

That installs the machine-level Server. Then register a project using the Skill:

```
/register-project-studio
```

Register a **second** project from a different directory to see the "one shared Server, many projects"
part actually work: the second registration reuses the already-running Server (no second `docker run`)
and gets its own distinct Project ID. This is the most interesting part of the new flow — the second
project needs no shell command at all, only the Skill.

`--image` is a dev-only flag; skip it once this ships and the public `curl` command works instead.

Rebuilt the image and want the already-running Server to pick it up? Re-run with `--update`:

```sh
sh package/bootstrap.sh --image perforated_studio_mcp:dev --update
```

Iterating quickly and don't want to answer the signup questions on every re-run? Add
`--skip-signup` (also dev-only, never the public one-liner):

```sh
sh package/bootstrap.sh --image perforated_studio_mcp:dev --update --skip-signup
```

**Windows support:** `bootstrap.ps1` now mirrors the Unix flow: machine-scoped install followed by
per-project registration via `/register-project-studio`. This has been implemented based on the Unix
design but has not been tested on a real Windows machine. If you encounter issues, please report them.
