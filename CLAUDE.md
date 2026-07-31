# Instructions for the Claude session performing this install

You are setting up a native ComfyUI install plus a dockable Mac app on this
machine. Everything you need is in this repo. Work through the phases in order,
verify each one before moving on, and prefer the repo's scripts over improvising.

## Phase 1 — Detect and install

1. `uname -m` → `arm64` = Apple Silicon, `x86_64` = Intel.
2. Run the matching installer:
   - arm64: `bash install/setup-comfyui-apple-silicon.sh`
   - x86_64: `bash install/setup-comfyui-intel-mac.sh`
3. Both are idempotent — safe to re-run after fixing any failure.
4. **Intel only:** read the GPU smoke-test verdict the installer prints at the
   end. If the smoke test failed or MPS is unavailable, edit `~/ComfyUI/start.sh`
   and add `--cpu` to the python line now, so the first boot is clean.

## Phase 2 — Verify the server boots

```bash
~/ComfyUI/start.sh > /tmp/comfy-boot.log 2>&1 &
# poll until it serves; first boot takes 30–60s
until curl -s -o /dev/null http://127.0.0.1:8188/; do sleep 2; done
grep -E "Device|pytorch version|IMPORT FAILED" /tmp/comfy-boot.log
```

- Confirm `Device: mps` (Apple Silicon), or `Device: mps`/`cpu` per the Intel verdict.
- **Intel only:** if startup crashes with an AttributeError/TypeError naming a
  torch symbol, current ComfyUI has outgrown torch 2.2.2 (the last Intel build).
  Fix: `cd ~/ComfyUI && git checkout <tag>` — bisect release tags (try recent
  ones first, walk back) until it boots; keep the newest that works. Reinstall
  requirements after each checkout using the same constraints the installer used.

## Phase 3 — Build the Mac app

```bash
bash app/build.sh
open "/Applications/ComfyUI Local.app"
```

- Requires Xcode Command Line Tools (`swiftc`). If missing: `xcode-select --install`.
- Verify: the app window shows the ComfyUI interface. Check
  `~/ComfyUI/user/comfyui-app.log` — a healthy launch logs `page loaded:`,
  `probe 2MB arg: bigArg:2097152`, `probe globals: persist:yes`, and
  `probe replay dispatch: replayed:1->...`.
- Tell the user to drag the app from /Applications to their Dock.

## Phase 4 — Functional checks (do these, don't skip)

1. Queue any tiny workflow (even an empty graph run) via the app — confirms
   end-to-end execution.
2. Drag an image file onto a Load Image node — it should highlight on hover and
   load on drop (the app replays real DOM drag events; the log shows
   `drop replay: replayed:1->CANVAS@x,y`).
3. ⌘Q — confirm the dialog offers Quit / Quit & Stop Server / Cancel.

## Known failure modes and fixes

| Symptom | Cause | Fix |
|---|---|---|
| Server dies silently mid "Loading weights" (Apple Silicon) | transformers 5.x threaded weight loading segfaults on MPS | Ensure `HF_DEACTIVATE_ASYNC_LOAD=1` is exported in start.sh (the AS installer does this) |
| Black/garbage images or crashes during generation (Intel) | torch 2.2 MPS-on-AMD op bugs | Add `--cpu` to start.sh |
| `comfy-kitchen`/`comfy-aimdo` pip failures (Intel) | No x86_64 wheels | Installer already skips them automatically on retry |
| Custom node IMPORT FAILED naming a transformers symbol | Node written for a different transformers major | Report to the user; per-node patches are usually small — check the import error's symbol against the installed transformers version |
| Drop on node does nothing in the app, works in browser | App replay issue | Read `~/ComfyUI/user/comfyui-app.log` — the `drop replay:` line names the element that received the drop |

## Ground rules

- Don't install Comfy Desktop; this replaces it (and Desktop won't run on Intel).
- Don't upgrade torch past 2.2.2 on Intel — newer versions don't exist for x86_64 macOS.
- Models live in `~/ComfyUI/models/...`; the user will handle model downloads
  separately unless they ask.
- The app's source is `app/main.swift` — a known gotcha if you ever edit it:
  it's a script-mode Swift file, so **top-level `let` declarations must stay
  above `app.run()`** (anything after it never initializes and silently reads
  as an empty string).
