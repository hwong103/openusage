#!/usr/bin/env bash
set -euo pipefail

# Build and atomically install the development build from this checkout. Optional upstream syncing
# is intentionally conservative: it never resolves conflicts or publishes a partial build.

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
  [[ "$SCRIPT_PATH" = /* ]] || SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
INSTALL_TARGET="${OPENUSAGE_INSTALL_TARGET:-$HOME/Applications/Openusage Dev.app}"
STAGED_APP="${OPENUSAGE_STAGED_APP:-$ROOT_DIR/dist/Openusage Dev.app}"
LAUNCH_LABEL="com.hwong103.openusage-dev"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"
CLI_LINK="${OPENUSAGE_CLI_LINK:-/opt/homebrew/bin/openusage}"
SYNC_UPSTREAM="${OPENUSAGE_SYNC_UPSTREAM:-0}"
UPSTREAM_REF="${OPENUSAGE_UPSTREAM_REF:-upstream/main}"
BASE_BRANCH="${OPENUSAGE_BASE_BRANCH:-main}"
BUILD_REVISION=""
SOURCE_RELEASE=""
STAGED_VERSION=""
LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/openusage-dev-update.log"
LOCK_DIR="$HOME/Library/Caches/openusage-dev-update.lock"

verify_commandcode_fresh() {
  local cli="$1"
  local label="$2"
  local output=""
  local now=""
  local item=""
  local configured=""
  local elapsed=0
  local timeout_seconds="${OPENUSAGE_VERIFY_TIMEOUT_SECONDS:-180}"

  configured="$(/usr/bin/python3 -c '
import json
import plistlib
import subprocess
import sys

try:
    data = subprocess.check_output(
        ["/usr/bin/defaults", "export", "com.robinebers.openusage.dev", "-"],
        stderr=subprocess.DEVNULL,
    )
    values = plistlib.loads(data)
    accounts = json.loads(values["accounts.v1"])
except Exception:
    accounts = []
print("yes" if any(account.get("kind") == "commandcode" for account in accounts) else "no")
' 2>/dev/null || printf 'no')"
  if [[ "$configured" != "yes" ]]; then
    echo "No Command Code account is configured for $label; data-freshness check skipped."
    return 0
  fi

  while (( elapsed < timeout_seconds )); do
    output="$("$cli" commandcode 2>/dev/null || true)"
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    item="$(printf '%s' "$output" | /usr/bin/python3 -c '
import json
import sys

payload = json.load(sys.stdin)
providers = payload.get("providers", {})
for key, value in providers.items():
    if key.startswith("commandcode@"):
        print("|".join([
            str(value.get("fetchedAt", "")),
            str(value.get("expiresAt", "")),
            str(value.get("stale", "")).lower(),
            ",".join(sorted((value.get("resources") or {}).keys())),
        ]))
        break
' 2>/dev/null || true)"
    if [[ -z "$item" ]]; then
      sleep 1
      elapsed=$((elapsed + 1))
      continue
    fi
    if /usr/bin/python3 -c '
import datetime
import sys

fetched_at, expires_at, stale, resources = sys.argv[1].split("|", 3)
now_text = sys.argv[2]
if stale != "false":
    raise SystemExit(1)
fetched = datetime.datetime.fromisoformat(fetched_at.replace("Z", "+00:00"))
now = datetime.datetime.fromisoformat(now_text.replace("Z", "+00:00"))
if now - fetched > datetime.timedelta(minutes=5):
    raise SystemExit(1)
required = {"balance", "monthly", "requests", "session", "weekly"}
if set(resources.split(",")) & required != required:
    raise SystemExit(1)
' "$item" "$now"; then
      echo "Fresh Command Code data verified for $label: $item at $now."
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

install_launch_agent() {
  if [[ ! -f "$LAUNCH_PLIST" ]]; then
    mkdir -p "$(dirname "$LAUNCH_PLIST")"
    cat > "$LAUNCH_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LAUNCH_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-gj</string>
    <string>$INSTALL_TARGET</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/openusage-dev.launch.out</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/openusage-dev.launch.err</string>
</dict>
</plist>
PLIST
    plutil -lint "$LAUNCH_PLIST" >/dev/null
  fi
  launchctl bootout "gui/$(id -u)/$LAUNCH_LABEL" >/dev/null 2>&1 || true
  if [[ -f "$LAUNCH_PLIST" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$LAUNCH_PLIST" 2>/dev/null \
      || launchctl kickstart "gui/$(id -u)/$LAUNCH_LABEL"
  else
    open -gj "$INSTALL_TARGET"
  fi
}

restore_previous() {
  local reason="$1"
  echo "Update failed after install: $reason Restoring previous app." >&2
  pkill -f "^$INSTALL_TARGET/Contents/MacOS/OpenUsage$" >/dev/null 2>&1 || true
  rm -rf "$INSTALL_TARGET"
  if [[ -d "$LIVE_PREVIOUS" ]]; then
    mv "$LIVE_PREVIOUS" "$INSTALL_TARGET"
    ln -sfn "$INSTALL_TARGET/Contents/Helpers/openusage" "$CLI_LINK"
    install_launch_agent
    verify_commandcode_fresh "$CLI_LINK" "the restored app" \
      || echo "Restored app is installed, but its Command Code data could not be revalidated." >&2
  fi
  exit 1
}

mkdir -p "$LOG_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another Openusage Dev update is running." >&2
  exit 1
fi
cleanup() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT

cd "$ROOT_DIR"
{
  echo "=== $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
  echo "root=$ROOT_DIR"
  echo "sync_upstream=$SYNC_UPSTREAM ref=$UPSTREAM_REF"

  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "Update refused: working tree has uncommitted changes." >&2
    exit 1
  fi

  tracked_after_check="$(git status --porcelain --untracked-files=no)"
  if [[ -n "$tracked_after_check" ]]; then
    echo "Update refused: working tree changed while preparing." >&2
    exit 1
  fi

  git fetch --prune --tags origin
  if git remote get-url upstream >/dev/null 2>&1; then
    git fetch --prune --tags upstream
  elif [[ "$SYNC_UPSTREAM" == "1" ]]; then
    echo "Update refused: upstream syncing was requested, but this checkout has no upstream remote." >&2
    exit 1
  else
    echo "No upstream remote is configured; skipping upstream fetch."
  fi

  if [[ "${OPENUSAGE_UPDATE_CURRENT_BRANCH:-0}" != "1" ]]; then
    current_branch="$(git rev-parse --abbrev-ref HEAD)"
    if [[ "$current_branch" == "$BASE_BRANCH" ]]; then
      git pull --ff-only origin "$BASE_BRANCH"
    elif [[ "$current_branch" != "main" && "$current_branch" != "master" ]]; then
      echo "Update refused: use an accepted main branch or explicitly allow this integration branch." >&2
      exit 1
    fi
  fi

  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "Update refused: tracked files are not clean after fetching." >&2
    exit 1
  fi

  if [[ "$SYNC_UPSTREAM" == "1" ]]; then
    if ! git merge-base --is-ancestor "$UPSTREAM_REF" HEAD; then
      echo "Merging $UPSTREAM_REF (existing build remains untouched until the build passes)."
      if ! git merge --no-edit "$UPSTREAM_REF"; then
        git merge --abort 2>/dev/null || true
        echo "Update refused: upstream merge needs manual conflict resolution." >&2
        exit 2
      fi
    fi
  fi

  BUILD_REVISION="$(git rev-parse HEAD)"
  SOURCE_RELEASE="$(git describe --tags --match 'v[0-9]*' "$BUILD_REVISION" 2>/dev/null || printf '%s' 'unreleased fork commit')"

  echo "Building and testing $BUILD_REVISION."
  ./script/test_quiet.sh

  echo "Building staged app."
  OPENUSAGE_KEEP_RUNNING=1 ./script/build_and_run.sh build

  if [[ ! -d "$STAGED_APP" ]]; then
    echo "Update failed: staged app is missing." >&2
    exit 1
  fi
  codesign --verify --deep --strict "$STAGED_APP"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist" | grep -Fx 'com.robinebers.openusage.dev' >/dev/null
  /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$STAGED_APP/Contents/Info.plist" | grep -Fx 'Openusage Dev' >/dev/null
  STAGED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED_APP/Contents/Info.plist")"
  [[ "$STAGED_VERSION" == "dev (${BUILD_REVISION:0:7})" ]]
  "$STAGED_APP/Contents/Helpers/openusage" --version >/dev/null

  BACKUP="$HOME/Library/Application Support/Openusage Dev/backup"
  mkdir -p "$BACKUP"
  PREVIOUS="$BACKUP/Openusage Dev.app.previous"
  LIVE_PREVIOUS="$HOME/Applications/.Openusage Dev.app.previous"
  if [[ -d "$INSTALL_TARGET" ]]; then
    rm -rf "$PREVIOUS"
    ditto "$INSTALL_TARGET" "$PREVIOUS"
  fi

  TMP_TARGET="$HOME/Applications/.Openusage Dev.app.installing"
  rm -rf "$TMP_TARGET"
  ditto "$STAGED_APP" "$TMP_TARGET"
  codesign --verify --deep --strict "$TMP_TARGET"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$TMP_TARGET/Contents/Info.plist" | grep -Fx 'Openusage Dev' >/dev/null
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TMP_TARGET/Contents/Info.plist" | grep -Fx 'com.robinebers.openusage.dev' >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TMP_TARGET/Contents/Info.plist")" == "$STAGED_VERSION" ]]
  "$TMP_TARGET/Contents/Helpers/openusage" --version >/dev/null
  PLIST_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$LAUNCH_PLIST" 2>/dev/null || true)"
  if [[ -f "$LAUNCH_PLIST" && "$PLIST_LABEL" != "$LAUNCH_LABEL" ]]; then
    echo "Update failed: launch item $LAUNCH_PLIST has the wrong Label." >&2
    exit 1
  fi

  echo "Quitting current Openusage Dev instance."
  osascript -e 'tell application id "com.robinebers.openusage.dev" to quit' >/dev/null 2>&1 || true
  for _ in {1..30}; do
    pgrep -f "^$INSTALL_TARGET/Contents/MacOS/OpenUsage$" >/dev/null || break
    sleep 0.2
  done
  if pgrep -f "^$INSTALL_TARGET/Contents/MacOS/OpenUsage$" >/dev/null; then
    echo "Update failed: current app did not quit; installed app was not changed." >&2
    exit 1
  fi

  rm -rf "$LIVE_PREVIOUS"
  if [[ -d "$INSTALL_TARGET" ]]; then
    mv "$INSTALL_TARGET" "$LIVE_PREVIOUS"
  fi
  mv "$TMP_TARGET" "$INSTALL_TARGET"

  mkdir -p "$(dirname "$CLI_LINK")"
  if [[ -L "$CLI_LINK" ]] || [[ -e "$CLI_LINK" ]]; then
    if [[ -L "$CLI_LINK" ]]; then
      existing_link="$(readlink "$CLI_LINK")"
      case "$existing_link" in
        "$INSTALL_TARGET/Contents/Helpers/openusage"|"$LIVE_PREVIOUS/Contents/Helpers/openusage"|"$PREVIOUS/Contents/Helpers/openusage") ;;
        *) echo "Update refused: $CLI_LINK points to an unrelated file." >&2; exit 1 ;;
      esac
    else
      echo "Update refused: $CLI_LINK is an unrelated file." >&2
      exit 1
    fi
    rm -f "$CLI_LINK"
  fi
  ln -s "$INSTALL_TARGET/Contents/Helpers/openusage" "$CLI_LINK"
  install_launch_agent

  for _ in {1..30}; do
    pgrep -f "^$INSTALL_TARGET/Contents/MacOS/OpenUsage$" >/dev/null && break
    sleep 0.2
  done
  if ! pgrep -f "^$INSTALL_TARGET/Contents/MacOS/OpenUsage$" >/dev/null; then
    restore_previous "the app did not relaunch."
  fi

  if [[ "$(git rev-parse HEAD)" != "$BUILD_REVISION" ]]; then
    restore_previous "the checkout changed while building."
  fi
  if [[ "$(pgrep -f "^$INSTALL_TARGET/Contents/MacOS/OpenUsage$" | wc -l | tr -d ' ')" != "1" ]]; then
    restore_previous "expected exactly one Openusage Dev instance."
  fi
  codesign --verify --deep --strict "$INSTALL_TARGET"
  [[ "$(readlink "$CLI_LINK")" == "$INSTALL_TARGET/Contents/Helpers/openusage" ]]
  "$CLI_LINK" --version >/dev/null
  if ! verify_commandcode_fresh "$CLI_LINK" "the installed app"; then
    restore_previous "Command Code did not refresh to fresh, complete data."
  fi

  echo "Installed $("$CLI_LINK" --version 2>&1 | head -n 1) from commit $BUILD_REVISION, source release $SOURCE_RELEASE."
} 2>&1 | tee -a "$LOG_FILE"
