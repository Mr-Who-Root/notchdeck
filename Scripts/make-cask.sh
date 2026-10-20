#!/bin/bash
# Writes the Homebrew cask for one NotchDeck release, from the disk image that
# release publishes. Used by `make bump-cask`, which pushes it to the tap
# (github.com/Mr-Who-Root/homebrew-notchdeck) so `brew upgrade` finds it.
#
#   Scripts/make-cask.sh VERSION DMG OUT
set -euo pipefail

VERSION=${1:?usage: make-cask.sh VERSION DMG OUT}
DMG=${2:?usage: make-cask.sh VERSION DMG OUT}
OUT=${3:?usage: make-cask.sh VERSION DMG OUT}
REPO=${NOTCHDECK_REPOSITORY:-Mr-Who-Root/notchdeck}
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<CASK
cask "notchdeck" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/NotchDeck-#{version}.dmg"
  name "NotchDeck"
  desc "AI usage rings, media controls, clipboard history and more in the notch"
  homepage "https://mr-who-root.github.io/notchdeck/"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Sparkle updates it in place; Homebrew only has to know that.
  auto_updates true
  depends_on macos: :sequoia

  app "NotchDeck.app"

  uninstall quit: "com.notchdeck.app"

  zap trash: [
    "~/Library/Application Support/NotchDeck",
    "~/Library/Caches/com.notchdeck.app",
    "~/Library/HTTPStorages/com.notchdeck.app",
    "~/Library/Preferences/com.notchdeck.app.plist",
  ]

  caveats <<~EOS
    NotchDeck is not notarized by Apple yet. If macOS says it cannot verify
    the app on first launch, open System Settings > Privacy & Security and
    click "Open Anyway" next to NotchDeck.
  EOS
end
CASK
echo "wrote $OUT ($VERSION, $SHA)"
