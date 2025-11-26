#!/bin/bash
cd / || exit 1 # Change to working directory
# ----------------------------------------
# Backup script with database dumps and rsync
# ----------------------------------------
# Available flags:
#   --only-mariadb    -> run only MariaDB dump
#   --only-psql     -> run only PostgreSQL dump
#   --only-mongo    -> run only MongoDB dump
#   --databases     -> dump all databases (MariaDB + PostgreSQL + MongoDB) without rsync
#   --dry-run       -> simulate only; no dump or rsync executed

SECONDS=0
LOGFILE="/var/log/backup.log"
DO_MYSQL=1
DO_PSQL=1
DO_MONGO=1
DO_RSYNC=1
DRY_RUN=0
MAX_LOG_SIZE=$((10 * 1024 * 1024)) # 10 MiB
RETENTION_DAYS=180 # Keep rotations 6 months

# ----------------------------------------
# Logging helper functions
# ----------------------------------------
log() {
    local DATE=$(date +"%d.%m.%Y")
    local TIME=$(date +"%H:%M:%S")
    echo "[$DATE $TIME] [backup.sh - INFO]: $1" >> "$LOGFILE"
}

log_warn() {
    local DATE=$(date +"%d.%m.%Y")
    local TIME=$(date +"%H:%M:%S")
    echo "[$DATE $TIME] [backup.sh - WARNING]: $1" >> "$LOGFILE"
}

# ----------------------------------------
# Log rotation and cleanup
# ----------------------------------------

# Rotate log if needed
if [ -f "$LOGFILE" ]; then
    ACTUAL_SIZE=$(stat -c%s "$LOGFILE")
    if [ "$ACTUAL_SIZE" -gt "$MAX_LOG_SIZE" ]; then
        ROTATED="$LOGFILE.$(date +%Y%m%d%H%M%S)"
        mv "$LOGFILE" "$ROTATED"
        touch "$LOGFILE"
        log "Filesize exceeded, log rotated (moved to $ROTATED)"
    fi
fi

# Delete old log rotations
OLD_LOGS=$(find /var/log -maxdepth 1 -name "backup.log.*" -mtime +$RETENTION_DAYS)

# Only run deletion if at least one file exists
if [ -n "$OLD_LOGS" ]; then
    for f in $OLD_LOGS; do
        rm -f "$f"
        log "Deleted old rotated log $f (retention > $RETENTION_DAYS days)"
    done
fi

# -------------------------
# Parse flags
# -------------------------
for arg in "$@"; do
    case $arg in
        --only-mariadb)
            DO_MYSQL=1; DO_PSQL=0; DO_MONGO=0;;
        --only-psql)
            DO_MYSQL=0; DO_PSQL=1; DO_MONGO=0;;
        --only-mongo)
            DO_MYSQL=0; DO_PSQL=0; DO_MONGO=1;;
        --databases)
            DO_MYSQL=1; DO_PSQL=1; DO_MONGO=1; DO_RSYNC=0;;
        --dry-run)
            DRY_RUN=1;;
        *)
            log_warn "Unknown argument: $arg";;
    esac
done

# -------------------------
# Define backup targets
# -------------------------
BACKUP_ROOT="/hdd2/backups"
TODAY_DIR="$BACKUP_ROOT/$(date +%Y-%m-%d)"
YESTERDAY_DIR="$BACKUP_ROOT/$(date -d "yesterday" +%Y-%m-%d 2>/dev/null)"
LATEST="$BACKUP_ROOT/latest"

# Create rsync base directories
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$TODAY_DIR"
    mkdir -p "$TODAY_DIR/db/mariadb" "$TODAY_DIR/db/postgres" "$TODAY_DIR/db/mongodb"
else
    log "Would create directories under $TODAY_DIR..."
fi

# ----------------------------------------
# Backup retention: delete backups older than RETENTION_DAYS first
# ----------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
    OLD_BACKUPS=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*" -mtime +$RETENTION_DAYS)
    if [ -n "$OLD_BACKUPS" ]; then
        for f in $OLD_BACKUPS; do
            rm -rf "$f"
            log "Deleted old backup $f (retention > $RETENTION_DAYS days)"
        done
    fi
else
    log "[DRY-RUN] Would delete backups older than $RETENTION_DAYS days..."
fi

# -------------------------
# MariaDB Dump
# -------------------------
if [ "$DO_MYSQL" -eq 1 ]; then
    log "Starting MariaDB dump..."
    if [ "$DRY_RUN" -eq 0 ]; then
        DUMP_FILE="$TODAY_DIR/db/mariadb/all_databases_$(date +%F).sql.gz"
        if sudo mariadb-dump --all-databases --single-transaction --routines --triggers --events --user=root \
            | gzip > "$DUMP_FILE"; then
            SIZE=$(du -h "$DUMP_FILE" | awk '{print $1}')
            log "MariaDB dump successful (size: $SIZE)"
        else
            log_warn "MySQL dump failed"
        fi
    else
        log "Would run mariadb-dump..."
    fi
fi

# -------------------------
# PostgreSQL Dump
# -------------------------
if [ "$DO_PSQL" -eq 1 ]; then
    log "Starting PostgreSQL dump..."
    if [ "$DRY_RUN" -eq 0 ]; then
        DUMP_FILE="$TODAY_DIR/db/postgres/all_databases_$(date +%F).sql.gz"
        if sudo -u postgres pg_dumpall | gzip > "$DUMP_FILE"; then
            SIZE=$(du -h "$DUMP_FILE" | awk '{print $1}')
            log "PostgreSQL dump successful (size: $SIZE)"
        else
            log_warn "PostgreSQL dump failed"
        fi
    else
        log "Would run pg_dumpall..."
    fi
fi

# -------------------------
# MongoDB Dump
# -------------------------
if [ "$DO_MONGO" -eq 1 ]; then
    log "Starting MongoDB dump..."
    MDB_HOST="${MDB_HOST}"
    MDB_USER="${MDB_USER}"
    MDB_PW="${MDB_PW}"
    MDB_DB="${MDB_DB}"
    MDB_PATH="${MDB_PATH}"

    if [ "$DRY_RUN" -eq 0 ]; then
        OUT_DIR="$TODAY_DIR/db/mongodb"
        if mongodump \
            --host "$MDB_HOST" \
            -u "$MDB_USER" \
            -p "$MDB_PW" \
            --authenticationDatabase "$MDB_DB" \
            --ssl --tlsInsecure \
            --out "$OUT_DIR" \
            --gzip ; then
            
            SIZE=$(du -sh "$OUT_DIR" | awk '{print $1}')
            log "MongoDB dump successful (size: $SIZE)"
        else
            log_warn "MongoDB dump failed"
        fi
    else
        log "Would run mongodump..."
    fi
fi

# -------------------------
# Rsync Backup
# -------------------------
if [ "$DO_RSYNC" -eq 1 ]; then
    log "Starting incremental rsync backup..."

    SRC="/home /etc /opt /var/www /root /hdd1"

    EXCLUDES=(
        "/hdd1/clashapp/data/patch/"
        "/hdd1/food-tinder/.dartServer/"
        "/hdd1/food-tinder/android-sdk/"
        "/hdd1/food-tinder/bin/"
        "/var/log/"
        "/home/*/steam_cache/"
        "/home/*/garrysmod/cache/"
        "/home/*/satisfactory/Engine/Binaries/Linux/*.debug"
        "/root/.npm/"
        "/opt/netdata/var/cache/"
        "/opt/sinusbot/**/*.log"
        "/**/*.gma"
        "/**/*.vpk"
        "/**/*.uacs"
        "/**/*.swp"
        "/**/*.swo"
        "/**/*.tmp"
        "/**/*node_modules/"
        "/**/*.git/"
        "/**/*vendor/"
        "/**/*.vscode/"
        "/**/*.cache/"
        "/**/*.vscode-server/"
        "/**/*.pub-cache/"
    )
    EXCLUDE_ARGS=()
    for e in "${EXCLUDES[@]}"; do EXCLUDE_ARGS+=(--exclude="$e"); done

    if [ "$DRY_RUN" -eq 0 ]; then
        if [ -d "$LATEST" ]; then
            if rsync -aH --delete --link-dest="$LATEST" -v --progress "${EXCLUDE_ARGS[@]}" $SRC "$TODAY_DIR"; then
                log "Rsync backup successful (using link-dest)"
            else
                log_warn "Rsync backup failed (using link-dest)"
            fi
        else
            if rsync -aH -v --progress "${EXCLUDE_ARGS[@]}" $SRC "$TODAY_DIR"; then
                log "Rsync backup successful (initial full copy)"
            else
                log_warn "Rsync backup failed (initial full copy)"
            fi
        fi
        ln -sfn "$TODAY_DIR" "$LATEST"
    else
        log "Would run rsync backup..."
    fi
fi

# ----------------------------------------
# Compute backup sizes
# ----------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
    TODAY_SIZE=$(du -sh "$TODAY_DIR" | awk '{print $1}')
    if [ -d "$YESTERDAY_DIR" ]; then
        YESTERDAY_SIZE_RAW=$(du -sb "$YESTERDAY_DIR" | awk '{print $1}')
        TODAY_SIZE_RAW=$(du -sb "$TODAY_DIR" | awk '{print $1}')
        SIZE_DIFF=$((TODAY_SIZE_RAW - YESTERDAY_SIZE_RAW))

        if [ "$SIZE_DIFF" -gt 0 ]; then
            SIZE_DIFF_FMT="+$(numfmt --to=iec -- $SIZE_DIFF)"
        else
            SIZE_DIFF_FMT="$(numfmt --to=iec -- $SIZE_DIFF)"
        fi
        log "Backup size: $TODAY_SIZE ($SIZE_DIFF_FMT compared to yesterday)"
    else
        log "Backup size: $TODAY_SIZE (no previous backup for comparison)"
    fi
else
    log "Would calculate backup sizes..."
fi

# ----------------------------------------
# Finish
# ----------------------------------------
RUNTIME="$SECONDS"
if [ "$DRY_RUN" -eq 1 ]; then
    log "Dry-Run Test of Backup completed, runtime was ${RUNTIME}s"
else
    log "Backup completed, runtime was ${RUNTIME}s"
fi
log "------------------------------------------------------------"
