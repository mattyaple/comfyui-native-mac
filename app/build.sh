#!/bin/bash
# Build and install "ComfyUI Local.app" — a native WKWebView wrapper for a local
# ComfyUI server. Starts ~/ComfyUI/start.sh if port 8188 is down, shows the UI in
# its own dockable window, ⌘Q offers to also stop the server (with queue warning),
# and native drag-drop replay makes file drops behave exactly like a browser.
# Works on Apple Silicon and Intel (swiftc compiles for the host arch).
set -e
cd "$(dirname "$0")"
APP="ComfyUI Local.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/ComfyUILocal" main.swift -framework Cocoa -framework WebKit
cp Info.plist "$APP/Contents/"
cp icon.icns "$APP/Contents/Resources/icon.icns"
codesign --force -s - "$APP"
rm -rf "/Applications/$APP"
cp -R "$APP" /Applications/
rm -rf "$APP"
echo "Installed /Applications/$APP — launch it, then drag it to the Dock to keep it there."
