#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
# ================================================================
# GLPI UPDATE SCRIPT (generic / GitHub-friendly)
# - Keeps instance-specific data in a .env file (not committed)
# - Backs up DB + key directories
# - Replaces GLPI code with a downloaded release tarball
# - Restores config/files/plugins/marketplace
# - Runs GLPI DB migration via console
#
# Tested approach: Debian-like layout, Apache user www-data by default
# ================================================================

log()  { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +'%F %T')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date +'%F %T')" "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Command '$1' not found. Please install it."
}

# --- Load .env if present (recommended) ---
ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "$ENV_FILE"
  set +a
else
  warn "No $ENV_FILE found. You can copy .env.example to .env and edit it."
fi

# --- Required configuration (from env) ---
: "${NEW_VERSION_URL:?Missing NEW_VERSION_URL}"
: "${GLPI_DIR:?Missing GLPI_DIR}"
: "${BACKUP_DIR:?Missing BACKUP_DIR}"
: "${TMP_DIR:?Missing TMP_DIR}"
: "${DB_NAME:?Missing DB_NAME}"
: "${DB_USER:?Missing DB_USER}"
# DB_PASS is optional if you use ~/.my.cnf or MYSQL_PWD env, see below.

APACHE_USER="${APACHE_USER:-www-data}"
GLPI_CONSOLE_USER="${GLPI_CONSOLE_USER:-$APACHE_USER}"   # user running php console
LOCK_FILE="${LOCK_FILE:-/tmp/glpi_update.lock}"
KEEP_TMP="${KEEP_TMP:-0}"

# --- Optional maintenance handling ---
ENABLE_MAINTENANCE="${ENABLE_MAINTENANCE:-0}"  # 1 to try toggling maintenance
MAINTENANCE_FILE="${MAINTENANCE_FILE:-$GLPI_DIR/files/_maintenance}"

# --- Safety checks ---
require_cmd sudo
require_cmd tar
require_cmd php
require_cmd wget

# mariadb-dump / mysqldump naming differs depending on distro/package
DUMP_BIN="${DUMP_BIN:-mariadb-dump}"
if ! command -v "$DUMP_BIN" >/dev/null 2>&1; then
  if command -v mysqldump >/dev/null 2>&1; then
    DUMP_BIN="mysqldump"
  else
    die "Neither 'mariadb-dump' nor 'mysqldump' found. Please install mariadb-client (or mysql-client)."
  fi
fi

# Prevent concurrent runs
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another update is already running (lock: $LOCK_FILE)."

# Resolve absolute paths (nice for tar restore)
GLPI_DIR="$(readlink -f "$GLPI_DIR")"
BACKUP_DIR="$(readlink -f "$BACKUP_DIR")"
TMP_DIR="$(readlink -f "$TMP_DIR")"

[[ -d "$GLPI_DIR" ]] || die "GLPI_DIR does not exist: $GLPI_DIR"

log "Starting GLPI update"
log "GLPI_DIR=$GLPI_DIR"
log "BACKUP_DIR=$BACKUP_DIR"
log "TMP_DIR=$TMP_DIR"
log "APACHE_USER=$APACHE_USER"
log "Release URL: $NEW_VERSION_URL"

# --- Prepare folders ---
sudo mkdir -p "$BACKUP_DIR" "$TMP_DIR"

DATE="$(date +"%Y%m%d_%H%M%S")"
DB_BACKUP_FILE="$BACKUP_DIR/glpi_db_${DATE}.sql"
FILE_BACKUP_FILE="$BACKUP_DIR/glpi_files_${DATE}.tar.gz"
CODE_BACKUP_DIR="$BACKUP_DIR/glpi_code_${DATE}"   # optional rollback

cleanup() {
  if [[ "$KEEP_TMP" != "1" ]]; then
    sudo rm -rf "$TMP_DIR" || true
  else
    warn "KEEP_TMP=1 -> temp directory kept at $TMP_DIR"
  fi
}
trap cleanup EXIT

# --- Optionally enable maintenance (very simple approach) ---
if [[ "$ENABLE_MAINTENANCE" == "1" ]]; then
  log "Enabling maintenance (creating $MAINTENANCE_FILE if possible)..."
  sudo -u "$APACHE_USER" bash -c "mkdir -p \"$(dirname "$MAINTENANCE_FILE")\" && touch \"$MAINTENANCE_FILE\"" || \
    warn "Could not enable maintenance automatically. Proceeding anyway."
fi

# ================================================================
# 1) Backup DB
# ================================================================
log "STEP 1/5: Database backup -> $DB_BACKUP_FILE"

# Prefer credentials via ~/.my.cnf (recommended) or env var DB_PASS
# If DB_PASS is set, use it; otherwise rely on default client auth (e.g. ~/.my.cnf)
if [[ -n "${DB_PASS:-}" ]]; then
  sudo "$DUMP_BIN" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$DB_BACKUP_FILE"
else
  warn "DB_PASS not set. Assuming client auth is configured (e.g. ~/.my.cnf for the executing user)."
  sudo "$DUMP_BIN" -u"$DB_USER" "$DB_NAME" > "$DB_BACKUP_FILE"
fi

[[ -s "$DB_BACKUP_FILE" ]] || die "DB backup file is empty: $DB_BACKUP_FILE"

# ================================================================
# 2) Backup important dirs
# ================================================================
log "STEP 2/5: Files backup -> $FILE_BACKUP_FILE"
# Only archive what we need to restore
# NOTE: These paths may vary with GLPI / plugins layout; adjust in .env if needed.
BACKUP_PATHS=(
  "$GLPI_DIR/config"
  "$GLPI_DIR/files"
  "$GLPI_DIR/marketplace"
  "$GLPI_DIR/plugins"
)

for p in "${BACKUP_PATHS[@]}"; do
  [[ -e "$p" ]] || warn "Path not found (will be skipped in restore): $p"
done

sudo tar -czf "$FILE_BACKUP_FILE" --warning=no-file-changed --ignore-failed-read "${BACKUP_PATHS[@]}"

# Optional: keep a copy of current code for rollback
log "Saving current GLPI code snapshot -> $CODE_BACKUP_DIR (optional rollback)"
sudo mkdir -p "$CODE_BACKUP_DIR"
sudo rsync -a --delete "$GLPI_DIR/" "$CODE_BACKUP_DIR/" >/dev/null

# ================================================================
# 3) Download + replace code
# ================================================================
log "STEP 3/5: Download and replace GLPI code"
TGZ="$TMP_DIR/glpi_new.tgz"

wget -O "$TGZ" "$NEW_VERSION_URL"
[[ -s "$TGZ" ]] || die "Downloaded archive is empty: $TGZ"

# Extract to staging dir first (safer than extracting directly over GLPI_DIR)
STAGING="$TMP_DIR/staging"
sudo rm -rf "$STAGING"
sudo mkdir -p "$STAGING"
sudo tar -xzf "$TGZ" -C "$STAGING"

# Heuristic: archive usually contains a top-level "glpi" directory
if [[ -d "$STAGING/glpi" ]]; then
  SRC_DIR="$STAGING/glpi"
else
  # Otherwise pick first directory
  SRC_DIR="$(find "$STAGING" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
fi
[[ -n "${SRC_DIR:-}" && -d "$SRC_DIR" ]] || die "Could not locate extracted GLPI directory inside $STAGING"

log "Replacing code in $GLPI_DIR (keeping restored dirs from backup afterward)"
# Remove everything except the directories we will restore (avoid losing them if restore fails)
# Still, we restore anyway from FILE_BACKUP_FILE, so it's ok to remove all.
sudo rm -rf "$GLPI_DIR"/*
sudo rsync -a "$SRC_DIR"/ "$GLPI_DIR"/

# ================================================================
# 4) Restore instance data + permissions
# ================================================================
log "STEP 4/5: Restore config/files/plugins/marketplace"
# Restore from tar (paths are absolute due to GLPI_DIR absolute; tar stored absolute)
# If you prefer relative, rework backup to be relative. This approach is simple but assumes same target path.
sudo tar -xzf "$FILE_BACKUP_FILE" -C /

log "Fix ownership"
sudo chown -R "$APACHE_USER:$APACHE_USER" "$GLPI_DIR"

# ================================================================
# 5) Run DB migration
# ================================================================
log "STEP 5/5: Run GLPI database migration"
sudo -u "$GLPI_CONSOLE_USER" php "$GLPI_DIR/bin/console" glpi:database:update

if [[ "$ENABLE_MAINTENANCE" == "1" ]]; then
  log "Disabling maintenance (removing $MAINTENANCE_FILE if present)..."
  sudo rm -f "$MAINTENANCE_FILE" || true
fi

log "GLPI update completed successfully."
log "Backups:"
log " - DB:    $DB_BACKUP_FILE"
log " - Files: $FILE_BACKUP_FILE"
log " - Code:  $CODE_BACKUP_DIR"
