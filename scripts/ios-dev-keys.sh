#!/bin/sh
# Copies ANTHROPIC_API_KEY, MESHY_API_KEY (and ELEVENLABS_API_KEY if set) from the repo's .env into
# ios/DrawCompanion3D/DevKeys.plist (git-ignored). On launch the app moves them
# into the iPhone's Keychain, so you don't have to type keys on the phone.
# Only for your own builds: anyone with the app file can read bundled keys.
set -e
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env in $(pwd). Create it first (cp .env.example .env)."; exit 1; }
out=ios/DrawCompanion3D/DevKeys.plist
plutil -create xml1 "$out"
for name in ANTHROPIC_API_KEY MESHY_API_KEY; do
  value=$(grep -E "^$name=" .env | tail -1 | cut -d= -f2- | tr -d '\r"' | sed "s/^'//;s/'$//")
  [ -n "$value" ] || { echo "$name is missing from .env"; rm -f "$out"; exit 1; }
  plutil -insert "$name" -string "$value" "$out"
done
# Optional: human-sounding character voices.
value=$(grep -E "^ELEVENLABS_API_KEY=" .env | tail -1 | cut -d= -f2- | tr -d '\r"' | sed "s/^'//;s/'$//")
[ -n "$value" ] && plutil -insert ELEVENLABS_API_KEY -string "$value" "$out"
echo "Wrote $out (git-ignored). Rebuild the app in Xcode to bundle it."
