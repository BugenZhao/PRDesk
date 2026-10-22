#!/bin/zsh
# Copies the guidance docs Xcode ships for its coding assistant into vendor/xcode-docs.
# Re-run after updating Xcode.
set -euo pipefail

xcode="$(xcode-select -p)/../.."
out="$(cd "$(dirname "$0")/.." && pwd)/vendor/xcode-docs"
sources=(
  "AdditionalDocumentation:PlugIns/IDEIntelligenceChat.framework/Versions/A/Resources/AdditionalDocumentation"
  "TriageDocs:PlugIns/IDEAnalytics.framework/Versions/A/Resources/TriageDocs"
)

rm -rf "$out"
for entry in "${sources[@]}"; do
  name="${entry%%:*}"
  src="$xcode/Contents/${entry#*:}"
  mkdir -p "$out/$name"
  cp "$src"/*.md "$out/$name/"
done

version="$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
cat > "$out/README.md" <<README
# Xcode coding-assistant docs

Copied verbatim from \`$(cd "$xcode" && pwd)\` ($version) by \`scripts/vendor-xcode-docs.sh\`.
Apple ships these for Xcode's built-in coding assistant; they describe APIs newer than most
model training data. Do not edit by hand — re-run the script after updating Xcode.

- \`AdditionalDocumentation/\` — guides to new SDK APIs (from IDEIntelligenceChat.framework)
- \`TriageDocs/\` — crash, hang, launch, energy and disk-write analysis guides (from IDEAnalytics.framework)
README
echo "Vendored $(find "$out" -name '*.md' ! -name README.md | wc -l | tr -d ' ') docs into $out"
