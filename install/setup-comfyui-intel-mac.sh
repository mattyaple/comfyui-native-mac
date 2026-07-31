#!/bin/bash
# ComfyUI native install for INTEL Macs (tested target: Mac Pro 2019).
# Mirrors Matt's Apple-Silicon setup (~/ComfyUI + ~/venvs/comfy-current + start.sh)
# with the pins Intel requires. Safe to re-run; each step skips work already done.
#
# Key constraint: PyTorch shipped its LAST Intel-macOS build as 2.2.2 (torchvision
# 0.17.2 / torchaudio 2.2.2), so everything is pinned around that:
#   - numpy<2          (torch 2.2 was compiled against numpy 1.x)
#   - transformers<5   (transformers 5.x requires newer torch)
set -euo pipefail

if [ "$(uname -m)" != "x86_64" ]; then
    echo "This script targets Intel Macs (uname -m = x86_64). Detected: $(uname -m)"
    echo "On Apple Silicon, use the standard setup instead (no pins needed)."
    exit 1
fi

echo "==> 1/6 Checking for git (Xcode Command Line Tools)..."
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    echo "    Xcode Command Line Tools missing. Run:  xcode-select --install"
    echo "    then re-run this script."
    exit 1
fi

echo "==> 2/6 Installing uv (python manager) if missing..."
if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

echo "==> 3/6 Creating venv (Python 3.12) at ~/venvs/comfy-current..."
mkdir -p "$HOME/venvs"
[ -d "$HOME/venvs/comfy-current" ] || uv venv --python 3.12 "$HOME/venvs/comfy-current"
PY="$HOME/venvs/comfy-current/bin/python"

echo "==> 4/6 Cloning ComfyUI to ~/ComfyUI..."
[ -d "$HOME/ComfyUI" ] || git clone https://github.com/comfyanonymous/ComfyUI.git "$HOME/ComfyUI"

echo "==> 5/6 Installing pinned dependencies (this takes a few minutes)..."
# Torch stack first — last Intel-macOS builds.
uv pip install --python "$PY" \
    "torch==2.2.2" "torchvision==0.17.2" "torchaudio==2.2.2" "numpy<2"

# Constraints keep the rest of the requirements from upgrading past Intel-compatible versions.
CONS="$(mktemp)"
cat > "$CONS" <<EOF
torch==2.2.2
torchvision==0.17.2
torchaudio==2.2.2
numpy<2
transformers<5
EOF

if ! uv pip install --python "$PY" -r "$HOME/ComfyUI/requirements.txt" -c "$CONS"; then
    echo "    Full requirements failed — likely comfy-kitchen/comfy-aimdo lack Intel wheels."
    echo "    Retrying without those optional accelerator packages..."
    grep -vE "^comfy-kitchen|^comfy-aimdo" "$HOME/ComfyUI/requirements.txt" > "$CONS.reqs"
    uv pip install --python "$PY" -r "$CONS.reqs" -c "$CONS"
fi
uv pip install --python "$PY" pip   # so ComfyUI-Manager can install node deps later

echo "==> 6/6 Creating ~/ComfyUI/start.sh..."
cat > "$HOME/ComfyUI/start.sh" <<'EOF'
#!/bin/bash
# Launch ComfyUI on Intel Mac.
# MPS on Intel/AMD GPUs is experimental in torch 2.2 — the fallback env lets
# unsupported ops run on CPU. If generation misbehaves (black images, crashes),
# force pure CPU by adding --cpu to the line below.
source "$HOME/venvs/comfy-current/bin/activate"
export PYTORCH_ENABLE_MPS_FALLBACK=1
exec python3 -u "$HOME/ComfyUI/main.py" \
    --listen 127.0.0.1 \
    --port 8188 \
    --max-upload-size 4096 \
    "$@"
EOF
chmod +x "$HOME/ComfyUI/start.sh"

echo ""
echo "==> GPU check: can torch 2.2 drive the AMD GPU via Metal (MPS)?"
"$PY" - <<'PYEOF'
import torch
built = torch.backends.mps.is_built()
avail = torch.backends.mps.is_available()
print(f"    MPS built into this torch: {built}")
print(f"    MPS available on this Mac: {avail}")
if avail:
    try:
        x = (torch.ones(64, 64, device="mps") @ torch.ones(64, 64, device="mps")).sum().item()
        print(f"    MPS smoke test (matmul on GPU): OK (result {x:.0f})")
        print("    -> ComfyUI will use the Radeon via Metal. If generation ever produces")
        print("       black/garbage images, fall back to CPU: add --cpu in start.sh.")
    except Exception as e:
        print(f"    MPS smoke test FAILED: {e}")
        print("    -> Use CPU mode: add --cpu to the python line in start.sh.")
else:
    print("    -> No GPU acceleration available; ComfyUI runs CPU-only (fine for API")
    print("       workflows, slow for local generation).")
PYEOF

echo ""
echo "Done. Start ComfyUI with:   ~/ComfyUI/start.sh"
echo "Then open:                  http://127.0.0.1:8188"
echo ""
echo "If startup errors mention a missing torch attribute/function, current ComfyUI"
echo "has moved past torch 2.2 — check out an older release tag (see README)."
