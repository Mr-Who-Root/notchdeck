#!/bin/bash
# Writes the Sparkle appcast for one release to stdout: the disk image it
# points at, signed with the EdDSA key in the login keychain (account
# `notchdeck`, made by Sparkle's `generate_keys --account notchdeck`).
#
#   SIGN_UPDATE=/path/to/sign_update \
#     Scripts/make-appcast.sh <dmg> <version> <build> <owner/repo> <summary> > appcast.xml
#
# Each GitHub release carries its own appcast.xml, so the feed URL every copy
# polls — releases/latest/download/appcast.xml — always describes the newest.
set -euo pipefail

DMG=$1 VERSION=$2 BUILD=$3 REPO=$4 SUMMARY=$5
: "${SIGN_UPDATE:?set SIGN_UPDATE to Sparkle's sign_update}"

# Prints: sparkle:edSignature="…" length="…"
SIGNATURE=$("$SIGN_UPDATE" --account notchdeck "$DMG")
URL="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")"
DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
# The summary is one line under the offer in the notch; XML-escaped, no markup.
SUMMARY=$(printf '%s' "$SUMMARY" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NotchDeck</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>NotchDeck $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description>$SUMMARY</description>
      <enclosure url="$URL" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
