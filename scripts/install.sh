#!/bin/zsh
# Builds a Release PR Desk and installs it as /Applications/PR Desk.app, replacing any previous
# install. Local data in ~/Library/Application Support/PR Desk is kept.
set -euo pipefail
cd "$(dirname "$0")/.."

# Signed with this Mac's Apple Development certificate where there is one, so the app is the
# same app to macOS from one install to the next (its Keychain items, what it was allowed). The
# team comes from the certificate and is never written into the project, which signs ad hoc.
team=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
  | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
  | awk -F'= ' '/organizationalUnitName/ {print $2; exit}' || true)
[[ -n "$team" ]] && security find-identity -p codesigning -v | grep -q "Apple Development" || team=""

tuist generate --no-open >/dev/null
build() {
  xcodebuild -workspace PRDesk.xcworkspace -scheme PRDesk -configuration Release \
    -derivedDataPath .build/DerivedData -destination 'platform=macOS' "$@" build -quiet
}
if [[ -z "$team" ]]; then
  build
# With its identifier and team as entitlements, which is where Handoff takes the team it offers
# an activity under: without them the iPad and iPhone are offered the item's page in a browser
# instead of in PR Desk (the other way needs only the certificate). They are restricted, so the
# app carries a provisioning profile, which Xcode makes (or has made) with the account in its
# settings. Without the account or the profile, signed as before, and said so.
elif ! build CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$team" \
    CODE_SIGN_ENTITLEMENTS="$PWD/PRDesk/PRDesk.entitlements" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration 2>/dev/null; then
  echo "No provisioning profile (is an account signed in to Xcode?): installing without Handoff to other devices." >&2
  build CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$team"
fi

app=".build/DerivedData/Build/Products/Release/PRDesk.app"
dest="/Applications/PR Desk.app"

# Quit any running copy (debug or release) so the new one replaces it cleanly.
osascript -e 'quit app id "com.bugenzhao.PRDesk"' 2>/dev/null || true
while pgrep -x PRDesk >/dev/null; do sleep 0.5; done

rm -rf "$dest"
ditto "$app" "$dest"
open "$dest"
echo "Installed $dest"
