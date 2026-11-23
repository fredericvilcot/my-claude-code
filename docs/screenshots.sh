#!/bin/zsh
# Rebuilds the README screenshots from made-up data (docs/demo/make-demo.py), never from your own sessions:
# the app runs with a fake home (CFFIXED_USER_HOME) in demo mode (MCC_DEMO: it never runs `claude` itself).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x "build/My Claude Code.app/Contents/MacOS/MyClaudeCode" ]] || ./build.sh
OUT="$PWD/docs/screenshots"
HOME_DEMO=$(mktemp -d /tmp/mcc-demo.XXXXXX)
# A copy of the app under its own bundle id: its preferences never touch those of your installed app.
cp -R "build/My Claude Code.app" "$HOME_DEMO/MCC Demo.app"
plutil -replace CFBundleIdentifier -string app.myclaudecode.demo "$HOME_DEMO/MCC Demo.app/Contents/Info.plist"
codesign --force --sign - "$HOME_DEMO/MCC Demo.app" 2>/dev/null
APP="$HOME_DEMO/MCC Demo.app/Contents/MacOS/MyClaudeCode"
# Three live processes with no terminal stand in for open sessions (the app checks their pid is alive).
PIDS=()
for i in 1 2 3; do
  python3 -c 'import os,time; os.setsid(); time.sleep(900)' </dev/null >/dev/null 2>&1 &
  PIDS+=($!)
done
trap 'kill ${PIDS[@]} 2>/dev/null; rm -rf "$HOME_DEMO"; defaults delete app.myclaudecode.demo 2>/dev/null || true' EXIT
python3 docs/demo/make-demo.py "$HOME_DEMO" ${PIDS[@]}
shot() {   # shot <name> <app arguments…>
  local name=$1; shift
  CFFIXED_USER_HOME="$HOME_DEMO" MCC_DEMO=1 "$APP" --snapshot "$OUT/$name.png" "$@" >/dev/null 2>&1 || true
  echo "  $name.png"
}
mkdir -p "$OUT"
shot overview --demo-attention
shot sessions --tab sessions
shot session --session-detail
shot stats --tab stats
shot notifications --notifications --demo-attention
shot quick --quick --picker
shot settings --tab settings
shot floating --minis
mv "$OUT"/floating-session-*.png "$OUT/floating-session.png" 2>/dev/null || true
rm -f "$OUT/floating.png"
CFFIXED_USER_HOME="$HOME_DEMO" MCC_DEMO=1 "$APP" --render-menubar "$OUT/menubar.png" >/dev/null 2>&1 || true
echo "  menubar.png"
