#!/bin/zsh
# Installs PR Desk (Release) on a connected iPad or iPhone and hands it this Mac's secrets and
# settings: the GitHub token, the bots' webhooks and ids, the badges repository. They travel in
# one file over the cable into the app's own container, which the app imports at its next launch
# and deletes (SetupImport). Nothing is printed.
#
#   scripts/setup-device.sh <device name or udid> [--secrets-only | --app-only]
#
# --app-only installs a new build and leaves the device's secrets as they are (an update).
#
# Reading the webhooks may ask for the login keychain's password.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:?device name or udid (xcrun devicectl list devices)}"
BUNDLE=com.bugenzhao.PRDesk.mobile
MAC=com.bugenzhao.PRDesk

if [[ "${2:-}" != "--secrets-only" ]]; then
  # The team of this Mac's development certificate; never written into the project. Found by its
  # full name: an expired one may come first by "Apple Development".
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
  TEAM=$([[ -n "$IDENTITY" ]] && security find-certificate -c "$IDENTITY" -p | openssl x509 -noout -subject -nameopt multiline | awk -F'= ' '/organizationalUnitName/ {print $2; exit}' || true)
  [[ -n "$TEAM" ]] || { echo "No Apple Development certificate in the keychain." >&2; exit 1; }
  DD=.build/DerivedDataDevice
  tuist generate --no-open >/dev/null
  # For this device, so that Xcode puts it into the provisioning profile it makes.
  if [[ "$DEVICE" =~ '^[0-9A-Fa-f-]{24,}$' ]]; then DESTINATION="platform=iOS,id=$DEVICE"; else DESTINATION="platform=iOS,name=$DEVICE"; fi
  build() {
    xcodebuild -workspace PRDesk.xcworkspace -scheme PRDeskMobile -configuration Release \
      -derivedDataPath "$DD" -destination "$DESTINATION" \
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
      CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
      PRDESK_COMMIT="$(git rev-parse --short=7 HEAD)$(git diff --quiet HEAD -- || echo +)" "$@" build 2>&1 \
      | grep -E 'warning:|error:|BUILD (SUCCEEDED|FAILED)' | grep -v appintents | sort -u
  }
  # iCloud and pushes, for the hints between devices, need a profile for this app alone, which
  # Xcode makes with the account in its settings; without one, built without them, and said so.
  if ! build >/dev/null; then
    echo "No provisioning profile with iCloud (is an account signed in to Xcode?): installing without hints between devices." >&2
    # An empty file: an empty setting leaves the target's own in place.
    PLAIN=$(mktemp -d)/plain.entitlements
    plutil -create xml1 "$PLAIN"
    build CODE_SIGN_ENTITLEMENTS="$PLAIN"
    rm -rf "$(dirname "$PLAIN")"
  fi
  xcrun devicectl device install app --device "$DEVICE" "$DD/Build/Products/Release-iphoneos/PRDeskMobile.app" | tail -2
fi

if [[ "${2:-}" == "--app-only" ]]; then
  xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE" >/dev/null
  echo "Installed and relaunched."
  exit 0
fi

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
chmod 700 "$DIR"
# Each value goes to python on stdin or in the environment of this one process, never an argument.
TOKEN=$(security find-generic-password -s "$MAC" -a github-token -w 2>/dev/null || gh auth token) \
HOOK_ASSISTANT=$(security find-generic-password -s "$MAC" -a grokbot-hook-assistant -w 2>/dev/null || true) \
HOOK_MERGER=$(security find-generic-password -s "$MAC" -a grokbot-hook-merger -w 2>/dev/null || true) \
BOT_ASSISTANT=$(defaults read "$MAC" grokBotAssistant 2>/dev/null || true) \
BOT_MERGER=$(defaults read "$MAC" grokBotMerger 2>/dev/null || true) \
BADGES=$(defaults read "$MAC" badgesRepository 2>/dev/null || true) \
python3 - "$DIR/setup.json" <<'PY'
import json, os, sys
env = os.environ
setup = {"token": env["TOKEN"], "hooks": {}, "settings": {}}
for role, name in (("assistant", "HOOK_ASSISTANT"), ("merger", "HOOK_MERGER")):
    if env.get(name):
        setup["hooks"][role] = json.loads(env[name])
for key, name in (("grokBotAssistant", "BOT_ASSISTANT"), ("grokBotMerger", "BOT_MERGER"), ("badgesRepository", "BADGES")):
    if env.get(name):
        setup["settings"][key] = env[name]
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(setup, f)
print("Sending: token, %d webhook(s), %s" % (len(setup["hooks"]), ", ".join(sorted(setup["settings"])) or "no settings"))
PY
xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source "$DIR/setup.json" --destination Documents/setup.json >/dev/null
# The app takes the file in at launch.
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE" >/dev/null
echo "Sent. PR Desk on the device has imported it and deleted the file."
