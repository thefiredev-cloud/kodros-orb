#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

app_dir="$HOME/Applications"
app="$app_dir/Kodros Orb.app"
agent="$HOME/Library/LaunchAgents/ai.meshvault.piorb.plist"
domain="gui/$UID"
mkdir -p "$app_dir" "$(dirname "$agent")"

launchctl bootout "$domain/ai.meshvault.piorb" 2>/dev/null || true
# The app was called Mesh Orb.app before the Kodros rename. Same bundle id, so
# move the old copy aside (never delete it) rather than leave two apps that both
# claim the LaunchAgent. The backup name does not end in .app, so macOS ignores it.
if [ -d "$app_dir/Mesh Orb.app" ]; then
  mv "$app_dir/Mesh Orb.app" "$app_dir/Mesh Orb.app.bak-$(date +%Y%m%d-%H%M%S)"
fi
ditto "Kodros Orb.app" "$app"

cat > "$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.meshvault.piorb</string>
  <key>ProgramArguments</key>
  <array><string>$app/Contents/MacOS/PiOrb</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/PiOrb.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/PiOrb.error.log</string>
</dict>
</plist>
PLIST
chmod 600 "$agent"
plutil -lint "$agent"
codesign --verify --strict "$app"
launchctl bootstrap "$domain" "$agent"
launchctl kickstart -k "$domain/ai.meshvault.piorb"
echo "installed and started $app"
