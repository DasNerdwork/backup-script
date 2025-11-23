#!/bin/bash
# ----------------------------------------
# Backup-Skript mit optionalen Flags
# ----------------------------------------
# Verfügbare Flags:
#   --only-mysql    -> nur MySQL/MariaDB-Dump
#   --only-psql     -> nur PostgreSQL-Dump
#   --only-mongo    -> nur MongoDB-Dump
#   --databases     -> alle Datenbanken dumpen (MySQL + PostgreSQL + MongoDB)
#   --dry-run       -> Simulation ohne echte Dumps oder Rsync

SECONDS=0
DATE=$(date +"%d.%m.%Y")
TIME=$(date +"%H:%M:%S")
LOGFILE="/var/log/backup.log"

# Default: alles machen
DO_MYSQL=1
DO_PSQL=1
DO_MONGO=1
DO_RSYNC=1
DRY_RUN=0

# -------------------------
# Flags auswerten
# -------------------------
for arg in "$@"; do
    case $arg in
        --only-mysql)
            DO_MYSQL=1
            DO_PSQL=0
            DO_MONGO=0
            ;;
        --only-psql)
            DO_MYSQL=0
            DO_PSQL=1
            DO_MONGO=0
            ;;
        --only-mongo)
            DO_MYSQL=0
            DO_PSQL=0
            DO_MONGO=1
            ;;
        --databases)
            DO_MYSQL=1
            DO_PSQL=1
            DO_MONGO=1
            DO_RSYNC=0
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        *)
            echo "Unbekanntes Argument: $arg"
            ;;
    esac
done

# -------------------------
# Backup-Ziel definieren
# -------------------------
BACKUP_ROOT="/hdd2/backups"
TODAY_DIR="$BACKUP_ROOT/$(date +%Y-%m-%d)"
LATEST="$BACKUP_ROOT/latest"

# Rsync-Verzeichnis anlegen
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$TODAY_DIR"
    mkdir -p "$TODAY_DIR/db/mysql" "$TODAY_DIR/db/postgres" "$TODAY_DIR/db/mongodb"
else
    echo "[DRY-RUN] würde Verzeichnisse unter $TODAY_DIR anlegen..."
fi

echo "[$DATE $TIME] Backup gestartet (DRY_RUN=$DRY_RUN)" >> "$LOGFILE"

# -------------------------
# MySQL/MariaDB-Dump
# -------------------------
if [ "$DO_MYSQL" -eq 1 ]; then
    echo "[$DATE $TIME] MySQL/MariaDB-Dump..." >> "$LOGFILE"
    if [ "$DRY_RUN" -eq 0 ]; then
        sudo mysqldump --all-databases --single-transaction --routines --triggers --events --user=root | \
            gzip > "$TODAY_DIR/db/mysql/all_databases_$(date +%F).sql.gz"
    else
        echo "[DRY-RUN] mysqldump würde ausgeführt werden..."
    fi
fi

# -------------------------
# PostgreSQL-Dump
# -------------------------
if [ "$DO_PSQL" -eq 1 ]; then
    echo "[$DATE $TIME] PostgreSQL-Dump..." >> "$LOGFILE"
    if [ "$DRY_RUN" -eq 0 ]; then
        sudo -u postgres pg_dumpall | gzip > "$TODAY_DIR/db/postgres/all_databases_$(date +%F).sql.gz"
    else
        echo "[DRY-RUN] pg_dumpall würde ausgeführt werden..."
    fi
fi

# -------------------------
# MongoDB-Dump
# -------------------------
if [ "$DO_MONGO" -eq 1 ]; then
    echo "[$DATE $TIME] MongoDB-Dump..." >> "$LOGFILE"
    MDB_HOST="${MDB_HOST}"
    MDB_USER="${MDB_USER}"
    MDB_PW="${MDB_PW}"
    MDB_DB="${MDB_DB}"
    MDB_PATH="${MDB_PATH}"

    if [ "$DRY_RUN" -eq 0 ]; then
        mongodump \
          --host "$MDB_HOST" \
          -u "$MDB_USER" \
          -p "$MDB_PW" \
          --authenticationDatabase "$MDB_DB" \
          --ssl --tlsInsecure \
          --out "$TODAY_DIR/db/mongodb" \
          --gzip
    else
        echo "[DRY-RUN] mongodump würde ausgeführt werden..."
    fi
fi

# -------------------------
# Rsync Backup
# -------------------------
if [ "$DO_RSYNC" -eq 1 ]; then
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
    for e in "${EXCLUDES[@]}"; do
        EXCLUDE_ARGS+=(--exclude="$e")
    done

    if [ "$DRY_RUN" -eq 0 ]; then
        if [ -d "$LATEST" ]; then
            rsync -aH --delete --link-dest="$LATEST" -v --progress "${EXCLUDE_ARGS[@]}" $SRC "$TODAY_DIR"
        else
            rsync -aH -v --progress "${EXCLUDE_ARGS[@]}" $SRC "$TODAY_DIR"
        fi
        ln -sfn "$TODAY_DIR" "$LATEST"
    else
        echo "[DRY-RUN] rsync würde ausgeführt werden..."
    fi
fi

echo "[$DATE $TIME] Backup beendet." >> "$LOGFILE"
