#!/bin/bash
# Maintain a multi-item appcast.xml for a release archive.
#
#   scripts/make_appcast.sh <archive.tar.gz> <version> <tag> <ed-key-file> [notes.txt]
#
# Delegates to Sparkle's own generate_appcast (shipped in the SPM artifact, the
# same place as sign_update) so the feed is a proper MULTI-item appcast instead
# of a single item overwritten on every release. generate_appcast reads the
# existing appcast.xml back in, preserves prior items verbatim (their URLs,
# EdDSA signatures and release notes survive without the old archives being
# present), appends the new item, signs it, and prunes to --maximum-versions
# per branch. Keeping the latest stable item always present is what stops a
# future prerelease (a channel-tagged item) from hiding stable from everyone.
#
# generate_appcast authors item fields from the bundle's Info.plist, so the one
# thing it does not produce is our release notes; we render them to an
# HTML sidecar named after the archive (TokenBar.app.html) and pass
# --embed-release-notes so they land in the item's <description> CDATA.
set -euo pipefail

ARCHIVE="$1"        # freshly built TokenBar.app.tar.gz
VERSION="$2"
TAG="$3"            # git tag, e.g. v1.1.2 — used for the per-release download URL
KEY_FILE="$4"
NOTES_FILE="${5:-}"

GENERATE_APPCAST=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
REPO_APPCAST="appcast.xml"
ARCHIVE_BASENAME=$(basename "$ARCHIVE")                  # TokenBar.app.tar.gz
NOTES_BASENAME="${ARCHIVE_BASENAME%.tar.gz}.html"        # TokenBar.app.html

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Seed generate_appcast with the currently published feed so it preserves the
# prior items (read back from this file — the old archives are not needed).
[ -f "$REPO_APPCAST" ] && cp "$REPO_APPCAST" "$WORK/appcast.xml"

cp "$ARCHIVE" "$WORK/$ARCHIVE_BASENAME"

# Render the plain-text notes (restricted format: "New:"/"Fixes:" headings,
# "- " bullets) into simple HTML beside the archive; generate_appcast embeds a
# same-base-name HTML sidecar as this item's <description>.
if [[ -n "$NOTES_FILE" && -s "$NOTES_FILE" ]]; then
  awk '
    function esc(t) { gsub(/&/, "\\&amp;", t); gsub(/</, "\\&lt;", t); return t }
    /^- / {
      if (!inlist) { print "<ul>"; inlist = 1 }
      print "<li>" esc(substr($0, 3)) "</li>"
      next
    }
    {
      if (inlist) { print "</ul>"; inlist = 0 }
      if ($0 ~ /^[[:space:]]*$/) next
      t = esc($0)
      if (t ~ /:[[:space:]]*$/) print "<b>" t "</b>"
      else print "<p>" t "</p>"
    }
    END { if (inlist) print "</ul>" }
  ' "$NOTES_FILE" > "$WORK/$NOTES_BASENAME"
fi

# Stable releases stay channel-less (served to everyone, so the latest stable is
# always visible). Prereleases (1.2.0-beta.1) go on the "beta" channel, so only
# hosts that opted in (allowedChannels -> ["beta"]) see them and stable users are
# never offered a beta. Because stable items remain channel-less in the same
# multi-item feed, a beta opt-in still sees stable and graduates to it
# automatically once a higher stable build ships. (Empty for stable; left
# unquoted on purpose so no flag is passed — safe, the value never has spaces.)
CHANNEL_ARG=""
case "$VERSION" in
  *-*) CHANNEL_ARG="--channel beta" ;;
esac

"$GENERATE_APPCAST" \
  --ed-key-file "$KEY_FILE" \
  --download-url-prefix "https://github.com/Nanako0129/TokenBar/releases/download/$TAG/" \
  --link "https://github.com/Nanako0129/TokenBar/releases/tag/$TAG" \
  --embed-release-notes \
  --maximum-versions 5 \
  $CHANNEL_ARG \
  "$WORK"

cp "$WORK/appcast.xml" "$REPO_APPCAST"
echo "appcast.xml updated ($VERSION) -> $(grep -c '<item>' "$REPO_APPCAST") item(s)"
