#!/bin/bash
# Assemble release notes in two formats from hand-written, version-bound sources:
#
#   release-notes.txt  — plain text. Rendered by the Sparkle update dialog,
#                        embedded in appcast.xml, and shipped in the Tauri
#                        latest.json, so it must stay markdown-free. Ends
#                        with a deterministic "Thanks: @…" line when the
#                        release contains external PRs.
#   release-notes.md   — GitHub-flavored markdown for the GitHub release
#                        page, plus GitHub's own "New Contributors" and
#                        "Full Changelog" tail appended verbatim.
#
# Both bodies come from `release-notes/<tag>.{txt,md}`, written by hand before
# the tag is pushed. There is no generation step and no model: earlier versions
# asked DeepSeek to write these, which produced text that differed between the
# two formats and between a local preview and the CI run.
#
# The sources are bound to the tag by filename, and a missing one is a hard
# error rather than a fallback. That is the point of this design: the previous
# scheme read an unversioned `release-notes.override.{txt,md}`, so completing a
# release correctly left the current version's notes in the repository, armed
# to be published again by the next one. That misfire was caught by manual
# inspection before v1.16.0 and v1.17.0 and never by a mechanism.
#
# Inputs (env): GITHUB_REF_NAME (tag), GITHUB_REPOSITORY (owner/repo),
# VERSION, GH_TOKEN. The GitHub API supplies contributor attribution and the
# changelog tail; without a token those segments are simply absent, which is
# why a local run is still not proof of the CI artifact.
set -euo pipefail

TAG="${GITHUB_REF_NAME:?GITHUB_REF_NAME (tag) required}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY (owner/repo) required}"
VERSION="${VERSION:-${TAG#v}}"
OWNER="${REPO%%/*}"
TXT="release-notes.txt"
MD="release-notes.md"

SRC_TXT="release-notes/${TAG}.txt"
SRC_MD="release-notes/${TAG}.md"

# --- Version-bound sources, required. ----------------------------------------
MISSING=()
[[ -f "$SRC_TXT" ]] || MISSING+=("$SRC_TXT")
[[ -f "$SRC_MD" ]] || MISSING+=("$SRC_MD")
if (( ${#MISSING[@]} > 0 )); then
  {
    printf 'error: no release notes for %s\n' "$TAG"
    printf 'Write these before tagging:\n'
    printf '  %s\n' "${MISSING[@]}"
    printf 'Notes are hand-written and named after the tag; there is no fallback,\n'
    printf 'so a release cannot inherit the previous version'"'"'s text.\n'
  } >&2
  exit 1
fi

# --- GitHub attribution: PR authors and the changelog tail. -------------------
PREV="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)"
AUTO=""
if [[ -n "${GH_TOKEN:-}" ]]; then
  if [[ -n "$PREV" ]]; then
    AUTO="$(gh api "repos/${REPO}/releases/generate-notes" \
      -f tag_name="$TAG" -f previous_tag_name="$PREV" --jq .body 2>/dev/null || true)"
  else
    AUTO="$(gh api "repos/${REPO}/releases/generate-notes" \
      -f tag_name="$TAG" --jq .body 2>/dev/null || true)"
  fi
fi
# External PR authors: everyone credited "by @login" except the owner and bots.
CONTRIB="$(printf '%s\n' "$AUTO" | grep -oE 'by @[A-Za-z0-9_-]+' | sed 's/^by //' \
  | sort -u | grep -vix "@${OWNER}" | grep -vi 'bot$' || true)"
# GitHub's tail sections, kept verbatim.
AUTO_TAIL="$(printf '%s\n' "$AUTO" | awk '/^## New Contributors/{f=1} f' || true)"
[[ -z "$AUTO_TAIL" ]] && AUTO_TAIL="$(printf '%s\n' "$AUTO" | grep '^\*\*Full Changelog' || true)"

# --- Plain text for Sparkle / appcast / latest.json. --------------------------
cp "$SRC_TXT" "$TXT"
if [[ -n "$CONTRIB" ]]; then
  printf '\nThanks: %s\n' "$(printf '%s\n' "$CONTRIB" | paste -sd, - | sed 's/,/, /g')" >> "$TXT"
fi

# --- Markdown for the GitHub release page. ------------------------------------
cp "$SRC_MD" "$MD"
if [[ -n "$AUTO_TAIL" ]]; then
  printf '\n%s\n' "$AUTO_TAIL" >> "$MD"
fi

echo "----- $TXT -----"
cat "$TXT"
echo "----- $MD -----"
cat "$MD"
