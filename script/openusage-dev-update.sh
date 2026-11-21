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
STAGING_ROOT=""
STAGED_APP=""
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
  if [[ -d "$INSTALL_TARGET" ]]; then
    if ! rm -rf "$INSTALL_TARGET"; then
      echo "Recovery failed: the replacement app could not be removed before restoring $LIVE_PREVIOUS." >&2
      exit 1
    fi
  fi
  if [[ -d "$LIVE_PREVIOUS" ]]; then
    if ! ditto "$LIVE_PREVIOUS/Contents" "$INSTALL_TARGET/Contents"; then
      echo "Recovery failed: the previous app could not be restored from $LIVE_PREVIOUS." >&2
      return 1
    fi
    rm -rf "$LIVE_PREVIOUS"
    if ! ln -sfn "$INSTALL_TARGET/Contents/Helpers/openusage" "$CLI_LINK"; then
      echo "Recovery failed: the restored app's CLI link could not be recreated." >&2
      return 1
    fi
    if ! install_launch_agent; then
      echo "Restored app is installed, but its login launch item could not be reloaded." >&2
    fi
    verify_commandcode_fresh "$CLI_LINK" "the restored app" \
      || echo "Restored app is installed, but its Command Code data could not be revalidated." >&2
  else
    echo "Recovery failed: no previous app copy exists at $LIVE_PREVIOUS." >&2
    return 1
  fi
  exit 1
}

validate_cli_target() {
  if [[ ! -L "$CLI_LINK" && ! -e "$CLI_LINK" ]]; then
    return 0
  fi
  if [[ ! -L "$CLI_LINK" ]]; then
    echo "Update refused: $CLI_LINK is an unrelated file." >&2
    return 1
  fi
  local existing_link
  existing_link="$(readlink "$CLI_LINK")"
  case "$existing_link" in
    "$INSTALL_TARGET/Contents/Helpers/openusage"|\
    "$HOME/Applications/.Openusage Dev.previous/Contents/Helpers/openusage"|\
    "$HOME/Library/Application Support/Openusage Dev/backup/Openusage Dev.previous/Contents/Helpers/openusage"|\
    "$HOME/Applications/.Openusage Dev.app.previous/Contents/Helpers/openusage"|\
    "$HOME/Library/Application Support/Openusage Dev/backup/Openusage Dev.app.previous/Contents/Helpers/openusage")
      return 0
      ;;
    *)
      echo "Update refused: $CLI_LINK points to an unrelated file." >&2
      return 1
      ;;
  esac
}

stop_current_app() {
  local pids
  pids="$(pgrep -f "^$INSTALL_TARGET/Contents/MacOS/OpenUsage$" || true)"
  if [[ -z "$pids" ]]; then
    return 0
  fi
  # Terminate only the exact installed binary. Bundle-ID AppleScript can select a duplicate app
  # copy during diagnosis or staging and prompt for Automation access.
  kill -TERM $pids 2>/dev/null || true
  for _ in {1..30}; do
    pgrep -f "^$INSTALL_TARGET/Contents/MacOS/OpenUsage$" >/dev/null || return 0
    sleep 0.2
  done
  return 1
}

mkdir -p "$LOG_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another Openusage Dev update is running." >&2
  exit 1
fi
STAGING_ROOT=""
cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
    rm -rf "$STAGING_ROOT"
  fi
}
trap cleanup EXIT
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openusage-dev-build.XXXXXX")"
STAGED_APP="$STAGING_ROOT/dist/Openusage Dev.app"

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
  OPENUSAGE_KEEP_RUNNING=1 \
  OPENUSAGE_DIST_DIR="$STAGING_ROOT/dist" \
    ./script/build_and_run.sh build

  if [[ ! -d "$STAGED_APP" ]]; then
    echo "Update failed: staged app is missing." >&2
    exit 1
  fi
  codesign --verify --deep --strict "$STAGED_APP"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist" | grep -Fx 'com.robinebers.openusage.dev' >/dev/null
  /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$STAGED_APP/Contents/Info.plist" | grep -Fx 'Openusage Dev' >/dev/null
  STAGED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED_APP/Contents/Info.plist")"
  STAGED_REVISION="$(git rev-parse --short "$BUILD_REVISION")"
  if [[ "$STAGED_VERSION" != "dev ($STAGED_REVISION)" ]]; then
    echo "Update failed: staged version '$STAGED_VERSION' does not match commit $BUILD_REVISION." >&2
    exit 1
  fi
  "$STAGED_APP/Contents/Helpers/openusage" --version >/dev/null

  BACKUP="$HOME/Library/Application Support/Openusage Dev/backup"
  mkdir -p "$BACKUP"
  PREVIOUS="$BACKUP/Openusage Dev.previous"
  LIVE_PREVIOUS="$HOME/Applications/.Openusage Dev.previous"
  if [[ -d "$INSTALL_TARGET" ]]; then
    rm -rf "$PREVIOUS"
    ditto "$INSTALL_TARGET/Contents" "$PREVIOUS/Contents"
  fi

  TMP_TARGET="$HOME/Applications/.Openusage Dev.app.installing"
  rm -rf "$TMP_TARGET"
  ditto "$STAGED_APP" "$TMP_TARGET"
  codesign --verify --deep --strict "$TMP_TARGET"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$TMP_TARGET/Contents/Info.plist" | grep -Fx 'Openusage Dev' >/dev/null
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TMP_TARGET/Contents/Info.plist" | grep -Fx 'com.robinebers.openusage.dev' >/dev/null
  TMP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TMP_TARGET/Contents/Info.plist")"
  if [[ "$TMP_VERSION" != "$STAGED_VERSION" ]]; then
    echo "Update failed: staged copy version '$TMP_VERSION' does not match '$STAGED_VERSION'." >&2
    exit 1
  fi
  "$TMP_TARGET/Contents/Helpers/openusage" --version >/dev/null
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  "$LSREGISTER" -u "$STAGED_APP" >/dev/null 2>&1 || true
  PLIST_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$LAUNCH_PLIST" 2>/dev/null || true)"
  if [[ -f "$LAUNCH_PLIST" && "$PLIST_LABEL" != "$LAUNCH_LABEL" ]]; then
    echo "Update failed: launch item $LAUNCH_PLIST has the wrong Label." >&2
    exit 1
  fi

  # Check this before quitting or moving the live app. The link will still point at the current
  # installation until the replacement has passed every staging check below.
  validate_cli_target

  echo "Quitting current Openusage Dev instance."
  if ! stop_current_app; then
    echo "Update failed: current app did not quit; installed app was not changed." >&2
    exit 1
  fi
  if [[ ! -d "$INSTALL_TARGET" ]]; then
    echo "Update failed: current app disappeared after it quit; installed app was not changed." >&2
    exit 1
  fi

  rm -rf "$LIVE_PREVIOUS"
  if ! ditto "$INSTALL_TARGET/Contents" "$LIVE_PREVIOUS/Contents"; then
    echo "Update failed: the current app could not be copied to the rollback directory." >&2
    ln -sfn "$INSTALL_TARGET/Contents/Helpers/openusage" "$CLI_LINK" || true
    install_launch_agent || true
    exit 1
  fi
  if ! rm -rf "$INSTALL_TARGET"; then
    echo "Update failed: the current app could not be removed." >&2
    ln -sfn "$INSTALL_TARGET/Contents/Helpers/openusage" "$CLI_LINK" || true
    install_launch_agent || true
    exit 1
  fi
  if ! mv "$TMP_TARGET" "$INSTALL_TARGET"; then
    restore_previous "the staged app could not be moved into place."
  fi

  mkdir -p "$(dirname "$CLI_LINK")"
  if ! rm -f "$CLI_LINK" \
    || ! ln -s "$INSTALL_TARGET/Contents/Helpers/openusage" "$CLI_LINK"; then
    restore_previous "the CLI link could not be created."
  fi
  if ! install_launch_agent; then
    restore_previous "the launch item could not be installed."
  fi

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
  if ! codesign --verify --deep --strict "$INSTALL_TARGET"; then
    restore_previous "the installed app failed signature verification."
  fi
  if [[ "$(readlink "$CLI_LINK")" != "$INSTALL_TARGET/Contents/Helpers/openusage" ]]; then
    restore_previous "the CLI link does not point at the installed app."
  fi
  if ! "$CLI_LINK" --version >/dev/null; then
    restore_previous "the installed CLI did not run."
  fi
  if ! verify_commandcode_fresh "$CLI_LINK" "the installed app"; then
    restore_previous "Command Code did not refresh to fresh, complete data."
  fi

  echo "Installed $("$CLI_LINK" --version 2>&1 | head -n 1) from commit $BUILD_REVISION, source release $SOURCE_RELEASE."
} 2>&1 | tee -a "$LOG_FILE"
