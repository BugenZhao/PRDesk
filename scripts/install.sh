#!/bin/zsh
# Builds a Release PR Desk and installs it as /Applications/PR Desk.app, replacing any previous
# install. Local data in ~/Library/Application Support/PR Desk is kept.
set -euo pipefail
cd "$(dirname "$0")/.."

tuist generate --no-open >/dev/null
xcodebuild -workspace PRDesk.xcworkspace -scheme PRDesk -configuration Release \
  -derivedDataPath .build/DerivedData -destination 'platform=macOS' build -quiet

app=".build/DerivedData/Build/Products/Release/PRDesk.app"
dest="/Applications/PR Desk.app"

# Quit any running copy (debug or release) so the new one replaces it cleanly.
osascript -e 'quit app id "com.bugenzhao.PRDesk"' 2>/dev/null || true
while pgrep -x PRDesk >/dev/null; do sleep 0.5; done

rm -rf "$dest"
ditto "$app" "$dest"
open "$dest"
echo "Installed $dest"
