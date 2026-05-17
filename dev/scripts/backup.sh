#!/usr/bin/env bash
# Backup the Siyuan stack in 3 tarballs : workspace, snapshots, reader-db.
# Outputs to ../backups/<timestamp>/ next to the compose file.
#
# Strategy:
#  1. `docker compose stop` for siyuan + extractor + reader (NOT `down`,
#     volumes stay intact). Avoids partial writes to SQLite WAL during backup.
#  2. tar.gz the workspace bind mount directly from the host.
#  3. tar.gz each named Docker volume via a throwaway alpine container.
#  4. `docker compose start` to resume services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

cd "$COMPOSE_DIR"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_ROOT="${BACKUP_ROOT:-$COMPOSE_DIR/backups}"
OUT="$BACKUP_ROOT/$TS"
mkdir -p "$OUT"

log() { printf '[backup] %s\n' "$*"; }

resolve_volume() {
    local short_name="$1"
    local full
    full="$(docker volume ls \
        --filter "label=com.docker.compose.project=$(basename "$COMPOSE_DIR")" \
        --filter "label=com.docker.compose.volume=$short_name" \
        --format '{{.Name}}' | head -n1)"
    if [[ -z "$full" ]]; then
        # Fallback: <dir>_<short>
        full="$(basename "$COMPOSE_DIR")_$short_name"
    fi
    printf '%s' "$full"
}

backup_volume() {
    local short_name="$1"
    local archive="$2"
    local full_name
    full_name="$(resolve_volume "$short_name")"
    log "Volume $short_name → $full_name"
    docker run --rm \
        -v "$full_name:/source:ro" \
        -v "$OUT:/backup" \
        alpine:3.20 \
        sh -c "tar -czf /backup/$archive -C /source . && chown $(id -u):$(id -g) /backup/$archive"
}

log "Output: $OUT"

log "Stopping services (siyuan, extractor, reader) — volumes preserved..."
docker compose -f "$COMPOSE_FILE" stop siyuan extractor reader

log "Archiving workspace/ (bind mount)..."
if [[ -d "$COMPOSE_DIR/workspace" ]]; then
    tar -czf "$OUT/workspace.tar.gz" -C "$COMPOSE_DIR" workspace
else
    log "WARN: workspace/ missing — skipping."
fi

log "Archiving Docker named volumes..."
backup_volume snapshots snapshots.tar.gz
backup_volume reader-db reader-db.tar.gz

log "Computing SHA256 sums..."
# `sha256sum` is GNU, `shasum -a 256` is BSD/macOS. Pick whichever is present.
if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD="shasum -a 256"
else
    log "ERROR: neither sha256sum nor shasum found; aborting." >&2
    docker compose -f "$COMPOSE_FILE" start siyuan extractor reader
    exit 1
fi
(cd "$OUT" && $SHA_CMD *.tar.gz > SHA256SUMS)

log "Writing manifest..."
{
    echo "timestamp: $TS"
    echo "compose_dir: $COMPOSE_DIR"
    echo "host: $(uname -a)"
    echo "files:"
    (cd "$OUT" && ls -lh *.tar.gz | awk '{print "  - " $9 "  " $5}')
    echo "sha256:"
    sed 's/^/  /' "$OUT/SHA256SUMS"
} > "$OUT/MANIFEST.txt"

log "Restarting services..."
docker compose -f "$COMPOSE_FILE" start siyuan extractor reader

log "Done."
log "Backup created at: $OUT"
log "Verify anytime with: (cd $OUT && $SHA_CMD -c SHA256SUMS)"
log "Restore with: scripts/restore.sh $TS"
