#!/bin/zsh
# Builds PR Desk (Release) for the iPad and iPhone once and installs it on every device of mine
# this Mac can reach just now: by cable, or over the network where the devices can see each other
# (at home; an office's Wi-Fi usually keeps them apart). The ones it can't reach are named and
# left as they are. Their secrets and data stay: a device is first set up with setup-device.sh,
# which also registers it for the provisioning profile.
#
#   scripts/install-devices.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE=com.bugenzhao.PRDesk.mobile
# The team of this Mac's development certificate; never written into the project.
TEAM=$(security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline | awk -F'= ' '/organizationalUnitName/ {print $2; exit}')
[[ -n "$TEAM" ]] || { echo "No Apple Development certificate in the keychain." >&2; exit 1; }

# Which devices, before the build: with none in reach there is nothing to build for.
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
xcrun devicectl list devices -j "$LIST" >/dev/null 2>&1
# One line a device: its id, whether it is in reach, its name.
DEVICES=$(python3 - "$LIST" <<'PY'
import json, sys
for device in json.load(open(sys.argv[1]))["result"]["devices"]:
    hardware, connection = device.get("hardwareProperties", {}), device.get("connectionProperties", {})
    if hardware.get("reality") != "physical" or hardware.get("platform") != "iOS" or connection.get("pairingState") != "paired":
        continue
    reach = "no" if connection.get("tunnelState") in (None, "unavailable") else "yes"
    print("\t".join([hardware.get("udid", device["identifier"]), reach, device.get("deviceProperties", {}).get("name", "?")]))
PY
)
[[ -n "$DEVICES" ]] || { echo "No paired iPad or iPhone." >&2; exit 1; }
if ! print -r -- "$DEVICES" | awk -F'\t' '$2 == "yes"' | grep -q .; then
  print -r -- "$DEVICES" | awk -F'\t' '{print "Not in reach: " $3}'
  exit 1
fi

DD=.build/DerivedDataDevice
COMMIT="$(git rev-parse --short=7 HEAD)$(git diff --quiet HEAD -- || echo +)"
tuist generate --no-open >/dev/null
# For any device: the profile Xcode keeps for the team has every device registered with it.
xcodebuild -workspace PRDesk.xcworkspace -scheme PRDeskMobile -configuration Release \
  -derivedDataPath "$DD" -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" PRDESK_COMMIT="$COMMIT" build \
  | grep -E 'warning:|error:|BUILD (SUCCEEDED|FAILED)' | grep -v appintents | sort -u
APP="$DD/Build/Products/Release-iphoneos/PRDeskMobile.app"

failed=0
print -r -- "$DEVICES" | while IFS=$'\t' read -r id reach name; do
  if [[ "$reach" != "yes" ]]; then
    echo "Not in reach, left as it is: $name"
  elif ! xcrun devicectl device install app --device "$id" "$APP" >/dev/null 2>&1; then
    echo "Couldn't install on $name"
    failed=1
  # A locked device takes the install and not the launch: the new copy is there when it is opened.
  elif xcrun devicectl device process launch --device "$id" --terminate-existing "$BUNDLE" >/dev/null 2>&1; then
    echo "Installed $COMMIT and relaunched: $name"
  else
    echo "Installed $COMMIT (locked, not relaunched): $name"
  fi
done
exit $failed
