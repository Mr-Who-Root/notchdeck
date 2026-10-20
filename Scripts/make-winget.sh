#!/bin/bash
# Writes the winget manifests for one NotchDeck release, from the Windows
# installer that release publishes, into the layout microsoft/winget-pkgs
# expects (manifests/m/Mr-Who-Root/NotchDeck/VERSION/). Submitting them is a
# pull request to that repository — `wingetcreate submit` or by hand.
#
#   Scripts/make-winget.sh VERSION SETUP.exe OUTDIR
set -euo pipefail

VERSION=${1:?usage: make-winget.sh VERSION SETUP.exe OUTDIR}
SETUP=${2:?usage: make-winget.sh VERSION SETUP.exe OUTDIR}
OUTDIR=${3:?usage: make-winget.sh VERSION SETUP.exe OUTDIR}
REPO=${NOTCHDECK_REPOSITORY:-Mr-Who-Root/notchdeck}
ID="Mr-Who-Root.NotchDeck"
SHA=$(shasum -a 256 "$SETUP" | awk '{print toupper($1)}')
DIR="$OUTDIR/manifests/m/Mr-Who-Root/NotchDeck/$VERSION"
SCHEMA="1.12.0"

mkdir -p "$DIR"

cat > "$DIR/$ID.yaml" <<YAML
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.version.$SCHEMA.schema.json
PackageIdentifier: $ID
PackageVersion: $VERSION
DefaultLocale: en-US
ManifestType: version
ManifestVersion: $SCHEMA
YAML

cat > "$DIR/$ID.installer.yaml" <<YAML
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.installer.$SCHEMA.schema.json
PackageIdentifier: $ID
PackageVersion: $VERSION
InstallerType: nullsoft
Scope: user
InstallModes:
  - interactive
  - silent
UpgradeBehavior: install
ReleaseDate: $(date -u +%Y-%m-%d)
Installers:
  - Architecture: x64
    InstallerUrl: https://github.com/$REPO/releases/download/v$VERSION/NotchDeck-Setup.exe
    InstallerSha256: $SHA
ManifestType: installer
ManifestVersion: $SCHEMA
YAML

cat > "$DIR/$ID.locale.en-US.yaml" <<YAML
# yaml-language-server: \$schema=https://aka.ms/winget-manifest.defaultLocale.$SCHEMA.schema.json
PackageIdentifier: $ID
PackageVersion: $VERSION
PackageLocale: en-US
Publisher: NotchDeck contributors
PublisherUrl: https://github.com/Mr-Who-Root
PublisherSupportUrl: https://github.com/$REPO/issues
PackageName: NotchDeck
PackageUrl: https://mr-who-root.github.io/notchdeck/
License: MIT
LicenseUrl: https://github.com/$REPO/blob/main/LICENSE
ShortDescription: AI usage rings, now playing, clipboard history, a file vault and a focus timer in a notch at the top of your screen.
Description: |-
  NotchDeck puts a small notch at the edge of your screen with live usage rings for AI coding tools
  (Claude Code, Codex, Cursor and more), what's playing with volume and output controls, clipboard
  history with search and snippets, a vault to drag files in and back out, your next meeting, and a
  focus timer with breaks.
Tags:
  - clipboard
  - productivity
  - notch
  - ai
  - focus-timer
ReleaseNotesUrl: https://github.com/$REPO/releases/tag/v$VERSION
ManifestType: defaultLocale
ManifestVersion: $SCHEMA
YAML

echo "wrote $DIR ($SHA)"
