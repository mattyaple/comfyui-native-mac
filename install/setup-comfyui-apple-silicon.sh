#!/bin/bash
# ComfyUI native install for APPLE SILICON Macs (M1–M4 and later).
# Layout: ~/ComfyUI (git) + ~/venvs/comfy-current (Python 3.12) + start.sh.
# Safe to re-run; each step skips work already done.
set -euo pipefail

if [ "$(uname -m)" != "arm64" ]; then
    echo "This script targets Apple Silicon (uname -m = arm64). Detected: $(uname -m)"
    echo "On Intel Macs, run setup-comfyui-intel-mac.sh instead."
    exit 1
fi

echo "==> 1/5 Checking for git (Xcode Command Line Tools)..."
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    echo "    Missing. Run:  xcode-select --install   then re-run this script."
    exit 1
fi

echo "==> 2/5 Installing uv (python manager) if missing..."
if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

echo "==> 3/5 Creating venv (Python 3.12) at ~/venvs/comfy-current..."
mkdir -p "$HOME/venvs"
[ -d "$HOME/venvs/comfy-current" ] || uv venv --python 3.12 "$HOME/venvs/comfy-current"
PY="$HOME/venvs/comfy-current/bin/python"

echo "==> 4/5 Cloning ComfyUI and installing dependencies..."
[ -d "$HOME/ComfyUI" ] || git clone https://github.com/comfyanonymous/ComfyUI.git "$HOME/ComfyUI"
uv pip install --python "$PY" torch torchvision torchaudio
uv pip install --python "$PY" -r "$HOME/ComfyUI/requirements.txt"
uv pip install --python "$PY" pip   # so ComfyUI-Manager can install node deps later

echo "==> 5/5 Creating ~/ComfyUI/start.sh..."
cat > "$HOME/ComfyUI/start.sh" <<'EOF'
#!/bin/bash
# Launch ComfyUI natively on Apple Silicon (MPS).
source "$HOME/venvs/comfy-current/bin/activate"
# transformers 5.x threaded weight loading can segfault on MPS; force single-threaded.
export HF_DEACTIVATE_ASYNC_LOAD=1
exec python3 -u "$HOME/ComfyUI/main.py" \
    --listen 127.0.0.1 \
    --port 8188 \
    --max-upload-size 4096 \
    "$@"
EOF
chmod +x "$HOME/ComfyUI/start.sh"

echo ""
echo "Done. Start ComfyUI with:   ~/ComfyUI/start.sh"
echo "Then open:                  http://127.0.0.1:8188"
