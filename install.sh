#!/usr/bin/env bash
# Install the loop-engineering pipeline into ~/.claude
# Copies commands / agents / templates / scripts and the .env.example profiles.
# Existing real *.env provider profiles are never overwritten.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${CLAUDE_HOME:-$HOME/.claude}"

echo "Installing loop-engineering → $DEST"
mkdir -p "$DEST/commands" "$DEST/agents" "$DEST/templates/development" "$DEST/scripts" "$DEST/providers"

cp -v "$SRC"/commands/*.md            "$DEST/commands/"
cp -v "$SRC"/agents/*.md              "$DEST/agents/"
cp -v "$SRC"/templates/development/*.md "$DEST/templates/development/"
cp -v "$SRC"/scripts/*.sh             "$DEST/scripts/"
chmod +x "$DEST"/scripts/*.sh

# Only the .env.example — never clobber a real profile the user already configured
for ex in "$SRC"/providers/*.env.example; do
  [ -e "$ex" ] || continue
  cp -vn "$ex" "$DEST/providers/"
done

echo
echo "Done."
echo "  • Slash commands: /clarify /architect /third_party_review /ship /retro (and dev/review/qa run inside /ship)"
echo "  • To enable /third_party_review: copy providers/provider.env.example"
echo "    to <provider>.env (e.g. deepseek.env) and fill in BASE_URL / TOKEN / MODEL."
