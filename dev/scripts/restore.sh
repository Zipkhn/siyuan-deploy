#!/usr/bin/env bash
# Restore a snapshot produced by backup.sh.
# Usage: scripts/restore.sh <timestamp>
#   ex:  scripts/restore.sh 20260512T143000Z
#
# Effect:
#   1. `docker compose down` (containers gone, volumes preserved temporarily).
#   2. Remove existing named volumes (siyuan-stack snapshots + reader-db).
#   3. Replace workspace/ directory on host with backup content.
#   4. Recreate volumes and untar backup content into them.
#   5. `docker compose up -d`.
#
# DESTRUCTIVE: existing workspace/, snapshots volume, reader-db volume will be
# overwritten. The script asks for confirmation before doing anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

cd "$COMPOSE_DIR"

if [[ $# -lt 1 ]]; then
    echo "Usage: $(basename "$0") <timestamp>"
    if [[ -d "$COMPOSE_DIR/backups" ]]; then
        echo
        echo "Available backups:"
        ls -1 "$COMPOSE_DIR/backups" 2>/dev/null | sed 's/^/  /'
    fi
    exit 1
fi

TS="$1"
BACKUP_ROOT="${BACKUP_ROOT:-$COMPOSE_DIR/backups}"
BACKUP="$BACKUP_ROOT/$TS"

if [[ ! -d "$BACKUP" ]]; then
    echo "ERROR: backup directory not found: $BACKUP" >&2
    exit 1
fi

log() { printf '[restore] %s\n' "$*"; }

# Verify archive integrity before doing anything destructive. If SHA256SUMS
# is missing (old backups written before V1.1), the restore continues but
# logs a clear warning so the operator can decide to abort manually.
verify_integrity() {
    if [[ ! -f "$BACKUP/SHA256SUMS" ]]; then
        log "WARN: no SHA256SUMS file in this backup — skipping integrity check."
        log "WARN: this backup likely predates V1.1; verify archives by hand."
        return 0
    fi
    local sha_cmd
    if command -v sha256sum >/dev/null 2>&1; then
        sha_cmd="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        sha_cmd="shasum -a 256"
    else
        log "ERROR: neither sha256sum nor shasum installed; cannot verify integrity." >&2
        exit 1
    fi
    log "Verifying SHA256 sums..."
    if ! (cd "$BACKUP" && $sha_cmd -c SHA256SUMS); then
        log "ERROR: integrity check failed. Refusing to restore corrupted backup." >&2
        exit 1
    fi
    log "Integrity OK."
}

# After extraction, sanity-check that the named volumes received content.
# Catches the silent case where a corrupted tarball "extracts" into an empty
# tree without erroring out.
verify_volume_not_empty() {
    local short_name="$1"
    local full_name
    full_name="$(resolve_volume "$short_name")"
    local count
    count="$(docker run --rm -v "$full_name:/v:ro" alpine:3.20 \
        sh -c "find /v -mindepth 1 -maxdepth 4 -print 2>/dev/null | head -n1 | wc -l")"
    if [[ "$count" -eq 0 ]]; then
        log "ERROR: volume $short_name is empty after restore. Aborting before bringing the stack back up." >&2
        exit 1
    fi
    log "Volume $short_name: non-empty after restore."
}

resolve_volume() {
    local short_name="$1"
    local full
    full="$(docker volume ls \
        --filter "label=com.docker.compose.project=$(basename "$COMPOSE_DIR")" \
        --filter "label=com.docker.compose.volume=$short_name" \
        --format '{{.Name}}' | head -n1)"
    if [[ -z "$full" ]]; then
        full="$(basename "$COMPOSE_DIR")_$short_name"
    fi
    printf '%s' "$full"
}

verify_integrity

echo "================================================================"
echo " WARNING: This restore will OVERWRITE current data with backup:"
echo "   $BACKUP"
echo "   ($(ls -la "$BACKUP" | awk 'NR>1 {print "    " $9}'))"
echo "================================================================"
read -r -p "Type 'yes' to continue, anything else to abort: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

log "Stopping & removing containers (volumes kept for now)..."
docker compose -f "$COMPOSE_FILE" down

restore_volume() {
    local short_name="$1"
    local archive="$2"
    local archive_path="$BACKUP/$archive"
    if [[ ! -f "$archive_path" ]]; then
        log "WARN: $archive not in backup — skipping volume $short_name."
        return
    fi
    local full_name
    full_name="$(resolve_volume "$short_name")"
    log "Recreating volume $short_name ($full_name)..."
    docker volume rm "$full_name" >/dev/null 2>&1 || true
    docker volume create --label com.docker.compose.project="$(basename "$COMPOSE_DIR")" \
        --label com.docker.compose.volume="$short_name" \
        "$full_name" >/dev/null
    docker run --rm \
        -v "$full_name:/target" \
        -v "$BACKUP:/backup:ro" \
        alpine:3.20 \
        sh -c "tar -xzf /backup/$archive -C /target"
    log "Volume $short_name restored."
}

log "Restoring workspace/ from backup..."
if [[ -f "$BACKUP/workspace.tar.gz" ]]; then
    rm -rf "$COMPOSE_DIR/workspace"
    tar -xzf "$BACKUP/workspace.tar.gz" -C "$COMPOSE_DIR"
    if [[ ! -d "$COMPOSE_DIR/workspace/data" ]]; then
        log "ERROR: workspace/data missing after extract. Aborting." >&2
        exit 1
    fi
    log "workspace/: non-empty after restore."
fi

restore_volume snapshots snapshots.tar.gz
restore_volume reader-db reader-db.tar.gz

# Post-extraction sanity: catch corrupted tarballs that decompress into empty
# trees without erroring. Only check volumes that were actually restored.
if [[ -f "$BACKUP/snapshots.tar.gz" ]]; then
    verify_volume_not_empty snapshots
fi
if [[ -f "$BACKUP/reader-db.tar.gz" ]]; then
    verify_volume_not_empty reader-db
fi

log "Bringing stack back up..."
docker compose -f "$COMPOSE_FILE" up -d

log "Done. Verify with: docker compose logs --tail 30"
