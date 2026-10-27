#!/bin/zsh
# Builds the grokbot CLI (github.com/BugenZhao/grokbot-cli) at a pinned commit and puts it in the
# app as Contents/Helpers/grokbot. Run by the PRDesk target's last build phase; bump `rev` to update.
set -euo pipefail

rev=cac95adcc9199ac700a582ae48f7641d326bcbdd

# One build per commit, shared by every DerivedData (test copies build into their own).
cache="$HOME/Library/Caches/com.bugenzhao.PRDesk.build/grokbot"
bin="$cache/$rev/bin/grokbot"
if [[ ! -x $bin ]]; then
  # A clean environment: Xcode's build settings (SDKROOT, deployment target, …) break cargo's
  # proc-macro builds.
  env -i HOME="$HOME" PATH="$HOME/.cargo/bin:/usr/bin:/bin" CARGO_TARGET_DIR="$cache/target" cargo install --quiet --locked \
    --git https://github.com/BugenZhao/grokbot-cli --rev "$rev" --root "$cache/$rev" grokbot
fi

dest="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$dest"
cp -f "$bin" "$dest/grokbot"
# The identity and identifier `just install` signs with: the keychain grant for `grokbot login
# --from-app` follows them, so this copy and ~/.cargo/bin/grokbot share it.
codesign --force --sign "Apple Development" --identifier com.bugenzhao.grokbot "$dest/grokbot" 2>/dev/null \
  || codesign --force --sign - --identifier com.bugenzhao.grokbot "$dest/grokbot"
