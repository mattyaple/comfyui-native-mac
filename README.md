# ComfyUI Native Mac Setup

Native, git-based ComfyUI install for macOS — **both Apple Silicon and Intel** —
plus a lightweight dockable Mac app to run the UI outside a browser.
No Comfy Desktop required (Desktop is Apple-Silicon-only; this works everywhere).

## What you get

- `~/ComfyUI` — standard git install (update with `git pull`)
- `~/venvs/comfy-current` — Python 3.12 venv with the right torch for your hardware
- `~/ComfyUI/start.sh` — one-command server launch on port 8188
- **ComfyUI Local.app** — native Swift/WKWebView wrapper (~450 lines, no Electron):
  - Launch from the Dock; starts the server automatically if it isn't running
  - ⌘Q asks whether to also stop the server (warns if jobs are queued)
  - Browser-equivalent drag-and-drop (images/audio/video onto nodes, workflow
    PNGs, custom-node drop zones, multi-file drops)
  - ⌘R reload, ⌘B open in browser, downloads go to ~/Downloads
  - Diagnostic log at `~/ComfyUI/user/comfyui-app.log`

## Install

```bash
# Apple Silicon (M1–M4+):
bash install/setup-comfyui-apple-silicon.sh

# Intel (e.g. Mac Pro 2019, with important caveats — see below):
bash install/setup-comfyui-intel-mac.sh

# The dockable app (either arch):
bash app/build.sh
```

Start the server with `~/ComfyUI/start.sh` — or just launch **ComfyUI Local**
from /Applications; it starts the server for you.

## Intel Mac caveats (read me if you're on x86_64)

| Constraint | Reason |
|---|---|
| torch pinned to **2.2.2** | PyTorch's last release with Intel-macOS builds (early 2024). Everything is pinned around it (`numpy<2`, `transformers<5`). |
| **GPU (MPS) is experimental** | torch 2.2's Metal backend supported "Apple silicon **or AMD GPUs**" in that era, and cards like the Radeon Pro W5700X qualify — but it was never polished on Intel. The installer runs a GPU smoke test at the end and prints a verdict. If generation produces black/garbage images or crashes, edit `start.sh` and add `--cpu`. |
| **ComfyUI version may need pinning** | Current master doesn't formally guarantee torch 2.2. If `start.sh` fails at startup naming a missing torch function, walk back: `cd ~/ComfyUI && git checkout <older tag>` and reinstall requirements with the same constraints. Keep the newest tag that boots. |

**Realistic Intel expectations:** API-node workflows (Nano Banana, GPT-Image,
Kling, …) run great — the cloud does the heavy lifting. Local SD1.5/SDXL is
workable but slow. FLUX/video models are not realistic on this hardware.

## The app in daily use

- Quitting the app **leaves the server running** by default (queued jobs finish;
  relaunch is instant). ⌘Q → "Quit & Stop Server" shuts everything down.
- Stop the server from a terminal anytime: `pkill -f ComfyUI/main.py`
- The app and a browser tab can be used interchangeably — same server, same session.

## Updating

```bash
cd ~/ComfyUI && git pull
# then restart the server (⌘Q → Quit & Stop Server, relaunch the app)
```

On Intel, re-run the installer after a pull so the dependency constraints are
re-applied (`bash install/setup-comfyui-intel-mac.sh` — it's idempotent).
