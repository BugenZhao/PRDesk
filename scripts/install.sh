#!/bin/zsh
# Builds a Release PR Desk and installs it as /Applications/PR Desk.app, replacing any previous
# install. Local data in ~/Library/Application Support/PR Desk is kept.
set -euo pipefail
cd "$(dirname "$0")/.."

# Signed with this Mac's Apple Development certificate where there is one, so the app is the
# same app to macOS from one install to the next (its Keychain items, what it was allowed). The
# team comes from the certificate and is never written into the project, which signs ad hoc.
signing=()
team=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
  | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
  | awk -F'= ' '/organizationalUnitName/ {print $2; exit}' || true)
if [[ -n "$team" ]] && security find-identity -p codesigning -v | grep -q "Apple Development"; then
  signing=(CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$team")
fi

tuist generate --no-open >/dev/null
xcodebuild -workspace PRDesk.xcworkspace -scheme PRDesk -configuration Release \
  -derivedDataPath .build/DerivedData -destination 'platform=macOS' "${signing[@]}" build -quiet

app=".build/DerivedData/Build/Products/Release/PRDesk.app"
dest="/Applications/PR Desk.app"

# Quit any running copy (debug or release) so the new one replaces it cleanly.
osascript -e 'quit app id "com.bugenzhao.PRDesk"' 2>/dev/null || true
while pgrep -x PRDesk >/dev/null; do sleep 0.5; done

rm -rf "$dest"
ditto "$app" "$dest"
open "$dest"
echo "Installed $dest"
