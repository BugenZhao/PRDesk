#!/bin/zsh
# Builds a Release PR Desk and installs it as /Applications/PR Desk.app, replacing any previous
# install. Local data in ~/Library/Application Support/PR Desk is kept.
set -euo pipefail
cd "$(dirname "$0")/.."

# Signed with this Mac's Apple Development certificate where there is one, so the app is the
# same app to macOS from one install to the next (its Keychain items, what it was allowed). The
# team comes from the certificate and is never written into the project, which signs ad hoc. The
# certificate is found by its full name: an expired one may come first by "Apple Development".
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
team=""
[[ -n "$identity" ]] && team=$(security find-certificate -c "$identity" -p 2>/dev/null \
  | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
  | awk -F'= ' '/organizationalUnitName/ {print $2; exit}' || true)

tuist generate --no-open >/dev/null
# What Settings shows as the version: the commit, with a + for changes not committed.
commit="$(git rev-parse --short=7 HEAD)$(git diff --quiet HEAD -- || echo +)"
build() {
  xcodebuild -workspace PRDesk.xcworkspace -scheme PRDesk -configuration Release \
    -derivedDataPath .build/DerivedData -destination 'platform=macOS' PRDESK_COMMIT="$commit" "$@" build -quiet
}
signed() {
  build CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$team" \
    CODE_SIGN_ENTITLEMENTS="$PWD/PRDesk/$1" -allowProvisioningUpdates -allowProvisioningDeviceRegistration 2>/dev/null
}
# With entitlements, which are restricted, so the app carries a provisioning profile, which Xcode
# makes (or has made) with the account in its settings. First iCloud and pushes, for the hints
# between devices (`CloudHints`), which need a profile for this app alone; failing that, its
# identifier and team, which the team's wildcard profile covers: Handoff takes the team it offers
# an activity under from them (without them the iPad and iPhone are offered the item's page in a
# browser instead of in PR Desk; the other way needs only the certificate). What is missing is said.
if [[ -z "$team" ]]; then
  build
elif ! signed PRDesk-iCloud.entitlements; then
  echo "No provisioning profile with iCloud (is an account signed in to Xcode?): installing without hints between devices." >&2
  if ! signed PRDesk.entitlements; then
    echo "No provisioning profile at all: installing without Handoff to other devices either." >&2
    build CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$team"
  fi
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
