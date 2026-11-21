#!/usr/bin/env bash
set -euo pipefail

# Install the exact reviewed Openusage Dev revision on a macOS user session. The source checkout
# remains in Application Support so the same command can apply later accepted revisions.
#
# Usage:
#   script/openusage-dev-bootstrap.sh <full-commit-sha>

APP_COMMIT="${1:-}"
if [[ ! "$APP_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "Usage: $0 <full-commit-sha>" >&2
  exit 2
fi
APP_COMMIT="$(printf '%s' "$APP_COMMIT" | tr '[:upper:]' '[:lower:]')"

REPOSITORY="${OPENUSAGE_REPOSITORY:-https://github.com/hwong103/openusage.git}"
BRANCH="${OPENUSAGE_BRANCH:-main}"
CHECKOUT="${OPENUSAGE_CHECKOUT:-$HOME/Library/Application Support/Openusage Dev/source}"
CLI_LINK="${OPENUSAGE_CLI_LINK:-}"

if [[ -z "$CLI_LINK" ]]; then
  if [[ -d /opt/homebrew/bin && -w /opt/homebrew/bin ]]; then
    CLI_LINK=/opt/homebrew/bin/openusage
  else
    CLI_LINK="$HOME/.local/bin/openusage"
  fi
fi

mkdir -p "$(dirname "$CHECKOUT")"
if [[ ! -d "$CHECKOUT/.git" ]]; then
  git clone --branch "$BRANCH" "$REPOSITORY" "$CHECKOUT"
fi

cd "$CHECKOUT"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Bootstrap refused: $CHECKOUT has uncommitted tracked changes." >&2
  exit 1
fi

git fetch --prune origin
SCRIPT_COMMIT="$(git rev-parse HEAD)"
printf 'Using accepted updater from %s/script/openusage-dev-update.sh (%s).\n' \
  "$CHECKOUT" "$SCRIPT_COMMIT"
git cat-file -e "$APP_COMMIT^{commit}"
git checkout --detach "$APP_COMMIT"
if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream https://github.com/robinebers/openusage.git
fi

OPENUSAGE_UPDATE_CURRENT_BRANCH=1 \
OPENUSAGE_INSTALL_TARGET="${OPENUSAGE_INSTALL_TARGET:-$HOME/Applications/Openusage Dev.app}" \
OPENUSAGE_CLI_LINK="$CLI_LINK" \
  "$CHECKOUT/script/openusage-dev-update.sh"

printf 'Openusage Dev source: %s\n' "$CHECKOUT"
printf 'Openusage Dev CLI: %s\n' "$CLI_LINK"
printf 'Login item: %s\n' "$HOME/Library/LaunchAgents/com.hwong103.openusage-dev.plist"
