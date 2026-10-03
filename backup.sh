#!/bin/bash
# ----------------------------------------
# Tägliches Backup nach /hdd2/backups/JJJJ-MM-TT (Datenbank-Dumps + rsync-Snapshot)
# ----------------------------------------
# Jeder Tagesordner sieht aus wie eine Vollkopie, unveränderte Dateien sind aber Hardlinks auf den
# Vortag (rsync --link-dest), kosten also keinen Platz. Pfad im Backup = Originalpfad, z. B.
#   /etc/nginx/sites-available/035-meet -> /hdd2/backups/2026-10-03/etc/nginx/sites-available/035-meet
# Wiederherstellen: WIEDERHERSTELLEN.md und `backup-suche <pfad>`.
#
# Fehler in einem Schritt brechen nicht alles ab: der Schritt wird als Warnung gesammelt, am Ende
# kommt eine Mail + Push (Home Assistant). Läuft alles glatt, kommt nichts.
#
# Flags:
#   --only-mariadb | --only-psql | --only-mongo | --only-docker  -> nur dieser Dump, kein rsync
#   --databases     -> alle Dumps, kein rsync
#   --dry-run       -> nichts schreiben, nur loggen, was passieren würde
#   --test-alarm    -> nur Mail + Push testen

# Alles in { ... }: Bash liest den Block vor dem Start komplett ein, Änderungen am Skript
# stören einen laufenden Lauf dann nicht.
{
SKRIPT_DIR="$(dirname "$(readlink -f "$0")")"   # vor cd /, sonst falsch bei ./backup.sh
cd / || exit 1
set -o pipefail
SECONDS=0

LOGFILE="/var/log/backup.log"
BACKUP_ROOT="/hdd2/backups"
RETENTION_DAYS=180
MAX_LOG_SIZE=$((10 * 1024 * 1024))
MAIL_TO="dasnerdwork@gmail.com"
LOCK="/run/backup.lock"

# Quellen, im Backup unter demselben Pfad (rsync -R)
SRC=(/home /etc /opt /var/www /root /hdd1 /usr/local/bin /var/spool/cron /var/vmail)
# Laufende Postgres-Container: werden gedumpt (Rohdateien einer laufenden DB sind nicht verlässlich)
DOCKER_PG=(okapeo-prototyp-postgres-1 strapi-db)
# Docker-Volumes, die 1:1 kopiert werden (keine laufende DB darin)
DOCKER_VOLUMES=(okapeo-prototyp_s3-data okapeo-prototyp_postgres-data okapeo-prototyp_minio-data
                n8n_data matter-data backend_postgres_data)

# Git-Repos unter /hdd1/okapeo samt .git sichern (nicht gepushte Commits), sonst bleibt .git draußen.
# Includes müssen vor den Excludes stehen.
INCLUDES=("/hdd1/okapeo/**/*.git/")   # auch Bare-Repos wie testinstanzen/repo.git
EXCLUDES=(
    "/hdd1/clashapp/data/patch/"
    "/hdd1/nextcloud/data/appdata_*/preview/"
    "/hdd1/food-tinder/.dartServer/"
    "/hdd1/food-tinder/android-sdk/"
    "/hdd1/food-tinder/bin/"
    "/home/*/steam_cache/"
    "/home/*/garrysmod/cache/"
    "/home/*/satisfactory/Engine/Binaries/Linux/*.debug"
    "/root/.bun/"
    "/root/.rustup/"
    "/root/.nvm/"
    "/opt/netdata/var/cache/"
    "/opt/sinusbot/**/*.log"
    "/**/*.gma"
    "/**/*.vpk"
    "/**/*.uacs"
    "/**/*.swp"
    "/**/*.swo"
    "/**/*.tmp"
    "/**/*node_modules/"
    "/**/.pnpm-store/"
    "/**/.npm/"
    "/**/.next/"
    "/**/.turbo/"
    "/**/__pycache__/"
    "/**/*.git/"
    "/**/vendor/"
    "/**/*.vscode/"
    "/**/*.cache/"
    "/**/*.vscode-server/"
    "/**/*.pub-cache/"
)

DO_MYSQL=1; DO_PSQL=1; DO_MONGO=1; DO_DOCKER=1; DO_RSYNC=1; DRY_RUN=0; TEST_ALARM=0
FEHLER=()
FERTIG=0

# ----------------------------------------
# Log + Alarm
# ----------------------------------------
log()      { echo "[$(date +"%d.%m.%Y %H:%M:%S")] [backup.sh - INFO]: $1" >> "$LOGFILE"; }
log_warn() { echo "[$(date +"%d.%m.%Y %H:%M:%S")] [backup.sh - WARNING]: $1" >> "$LOGFILE"; FEHLER+=("$1"); }

# Mail + Push. Push über einen Webhook in Home Assistant (Automation „Backup-Alarm“ ruft
# notify.mobile_app_flos_handy). Die Webhook-ID steht in $SKRIPT_DIR/.env (HA_WEBHOOK=...).
melden() {
    local titel="$1" text="$2"
    printf '%s\n\nLog: %s\nAnleitung: %s/WIEDERHERSTELLEN.md\n' "$text" "$LOGFILE" "$BACKUP_ROOT" \
        | mail -s "$titel" "$MAIL_TO" \
        || echo "[$(date +"%d.%m.%Y %H:%M:%S")] [backup.sh - WARNING]: Mail fehlgeschlagen" >> "$LOGFILE"
    local HA_WEBHOOK=""
    [ -f "$SKRIPT_DIR/.env" ] && HA_WEBHOOK=$(sed -n 's/^HA_WEBHOOK=//p' "$SKRIPT_DIR/.env")
    if [ -n "$HA_WEBHOOK" ]; then
        jq -n --arg t "💾 $titel" --arg m "$text" '{title: $t, message: $m}' \
            | curl -fsS -m 20 -X POST -H 'Content-Type: application/json' --data @- \
                "http://127.0.0.1:8123/api/webhook/$HA_WEBHOOK" >/dev/null \
            || echo "[$(date +"%d.%m.%Y %H:%M:%S")] [backup.sh - WARNING]: Push an Home Assistant fehlgeschlagen" >> "$LOGFILE"
    else
        echo "[$(date +"%d.%m.%Y %H:%M:%S")] [backup.sh - WARNING]: HA_WEBHOOK fehlt in $SKRIPT_DIR/.env, kein Push" >> "$LOGFILE"
    fi
}

# Läuft bei jedem Ende, auch bei Abbruch (kill, Absturz): Fehler melden
am_ende() {
    [ "$DRY_RUN" -eq 1 ] && return
    [ "$FERTIG" -eq 0 ] && FEHLER+=("Skript vorzeitig abgebrochen (nach ${SECONDS}s)")
    if [ "${#FEHLER[@]}" -gt 0 ]; then
        melden "Backup $(date +%F): ${#FEHLER[@]} Problem(e)" "$(printf -- '- %s\n' "${FEHLER[@]}")"
    fi
}

# ----------------------------------------
# Flags
# ----------------------------------------
for arg in "$@"; do
    case $arg in
        --only-mariadb) DO_MYSQL=1; DO_PSQL=0; DO_MONGO=0; DO_DOCKER=0; DO_RSYNC=0;;
        --only-psql)    DO_MYSQL=0; DO_PSQL=1; DO_MONGO=0; DO_DOCKER=0; DO_RSYNC=0;;
        --only-mongo)   DO_MYSQL=0; DO_PSQL=0; DO_MONGO=1; DO_DOCKER=0; DO_RSYNC=0;;
        --only-docker)  DO_MYSQL=0; DO_PSQL=0; DO_MONGO=0; DO_DOCKER=1; DO_RSYNC=0;;
        --databases)    DO_RSYNC=0;;
        --dry-run)      DRY_RUN=1;;
        --test-alarm)   TEST_ALARM=1;;
        *) echo "Unbekanntes Argument: $arg" >&2; exit 2;;
    esac
done

if [ "$TEST_ALARM" -eq 1 ]; then
    melden "Backup: Testalarm" "Nur ein Test von backup.sh --test-alarm. Alles in Ordnung."
    exit 0
fi

# ----------------------------------------
# Nur ein Lauf gleichzeitig
# ----------------------------------------
exec 9>>"$LOCK"
if ! flock -n 9; then
    # Läuft der andere Lauf schon über 20 Stunden, hängt vermutlich etwas
    if [ -n "$(find "$LOCK" -mmin +1200 2>/dev/null)" ]; then
        melden "Backup $(date +%F): läuft seit über 20 Stunden" "Ein Backup-Lauf hält noch die Sperre $LOCK. Bitte prüfen: ps aux | grep backup.sh"
    fi
    log "Anderer Backup-Lauf aktiv, dieser Lauf übersprungen"
    exit 0
fi
touch "$LOCK"
trap am_ende EXIT
[ -f /etc/environment ] && { set -a; . /etc/environment; set +a; }   # MDB_* für MongoDB

# ----------------------------------------
# Logrotation
# ----------------------------------------
if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE")" -gt "$MAX_LOG_SIZE" ]; then
    mv "$LOGFILE" "$LOGFILE.$(date +%Y%m%d%H%M%S)"
    log "Log rotiert"
fi
find /var/log -maxdepth 1 -name "backup.log.*" -mtime +$RETENTION_DAYS -delete

log "------------------------------------------------------------"
log "Backup gestartet $*"

# ----------------------------------------
# Ziel prüfen: ohne gemountete hdd2 würde alles auf die Systemplatte geschrieben
# ----------------------------------------
if ! mountpoint -q /hdd2; then
    log_warn "/hdd2 ist nicht gemountet, Backup abgebrochen"
    FERTIG=1; exit 1
fi

TODAY_DIR="$BACKUP_ROOT/$(date +%F)"
DB_DIR="$TODAY_DIR/db"
# Letzter vollständiger Snapshot vor heute: Basis für die Hardlinks
PREV=$(find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -name .vollstaendig -printf '%h\n' 2>/dev/null \
       | grep -v "^$TODAY_DIR$" | sort | tail -1)

if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$DB_DIR/mariadb" "$DB_DIR/postgres" "$DB_DIR/mongodb" "$DB_DIR/docker" "$TODAY_DIR/system" \
        || { log_warn "Kann $TODAY_DIR nicht anlegen"; FERTIG=1; exit 1; }
    chmod 700 "$DB_DIR"   # Dumps enthalten alle Datenbanken im Klartext, nur root darf lesen

    # Bauplan des Systems für den Neuaufbau nach einem Ausfall der Systemplatte
    apt-mark showmanual > "$TODAY_DIR/system/pakete.txt" 2>>"$LOGFILE"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID,MODEL > "$TODAY_DIR/system/platten.txt" 2>>"$LOGFILE"
    { docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Label "com.docker.compose.project.working_dir"}}'
      echo; docker volume ls; } > "$TODAY_DIR/system/docker.txt" 2>>"$LOGFILE"
    systemctl list-unit-files --state=enabled --no-legend > "$TODAY_DIR/system/dienste.txt" 2>>"$LOGFILE"
fi

# Dump-Helfer: prüft Exitcode der ganzen Pipe, gzip-Integrität und Mindestgröße
dump() {
    local name="$1" datei="$2"; shift 2
    if [ "$DRY_RUN" -eq 1 ]; then log "$name: [DRY-RUN] würde $datei schreiben"; return; fi
    if "$@" 2>>"$LOGFILE" | gzip > "$datei" && gzip -t "$datei" && [ "$(stat -c%s "$datei")" -gt 1024 ]; then
        log "$name: Dump ok ($(du -h "$datei" | cut -f1))"
    else
        log_warn "$name: Dump fehlgeschlagen ($datei)"
    fi
}

# ----------------------------------------
# Datenbanken
# ----------------------------------------
[ "$DO_MYSQL" -eq 1 ] && dump "MariaDB" "$DB_DIR/mariadb/all_databases_$(date +%F).sql.gz" \
    mariadb-dump --all-databases --single-transaction --routines --triggers --events --user=root

[ "$DO_PSQL" -eq 1 ] && dump "PostgreSQL (Host)" "$DB_DIR/postgres/all_databases_$(date +%F).sql.gz" \
    sudo -u postgres pg_dumpall

# TLS ist in mongod aus (net.tls auskommentiert), daher kein --ssl
[ "$DO_MONGO" -eq 1 ] && dump "MongoDB" "$DB_DIR/mongodb/all_databases_$(date +%F).archive.gz" \
    mongodump --host "$MDB_HOST" -u "$MDB_USER" -p "$MDB_PW" --authenticationDatabase "$MDB_DB" --archive --quiet

if [ "$DO_DOCKER" -eq 1 ]; then
    for c in "${DOCKER_PG[@]}"; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != "true" ]; then
            log_warn "Docker $c: Container läuft nicht, kein Dump"
            continue
        fi
        dump "Docker $c" "$DB_DIR/docker/${c}_$(date +%F).sql.gz" \
            docker exec "$c" sh -c 'pg_dumpall -U "$POSTGRES_USER"'
    done
fi

# ----------------------------------------
# rsync-Snapshot
# ----------------------------------------
if [ "$DO_RSYNC" -eq 1 ]; then
    QUELLEN=("${SRC[@]}")
    for v in "${DOCKER_VOLUMES[@]}"; do
        if [ -d "/var/lib/docker/volumes/$v" ]; then QUELLEN+=("/var/lib/docker/volumes/$v")
        else log_warn "Docker-Volume $v fehlt"; fi
    done
    FILTER=()
    for i in "${INCLUDES[@]}"; do FILTER+=(--include="$i"); done
    for e in "${EXCLUDES[@]}"; do FILTER+=(--exclude="$e"); done
    LINK=()
    [ -n "$PREV" ] && LINK=(--link-dest="$PREV")

    if [ "$DRY_RUN" -eq 1 ]; then
        log "[DRY-RUN] rsync ${QUELLEN[*]} -> $TODAY_DIR (Basis: ${PREV:-keine, Vollkopie})"
    else
        log "rsync startet (Basis: ${PREV:-keine, Vollkopie})"
        RSYNC_START=$(date +%s)
        # -A: Zugriffslisten (ACLs) mitsichern, /hdd1/okapeo und /home hängen daran
        rsync -aHAR --delete --delete-excluded --numeric-ids --stats "${LINK[@]}" "${FILTER[@]}" "${QUELLEN[@]}" "$TODAY_DIR/" \
            > "$TODAY_DIR/.rsync-stats" 2> "$TODAY_DIR/.rsync-fehler"
        RC=$?
        grep -E "^(Number of (files|regular files transferred)|Total (file size|transferred file size)):" \
            "$TODAY_DIR/.rsync-stats" | while read -r z; do log "rsync: $z"; done
        case $RC in
            0)  log "rsync ok";;
            24) log "rsync ok (einige Dateien verschwanden während des Kopierens, normal)";;
            23) log_warn "rsync: einzelne Dateien nicht kopierbar ($(wc -l < "$TODAY_DIR/.rsync-fehler") Meldungen, siehe $TODAY_DIR/.rsync-fehler)";;
            *)  log_warn "rsync fehlgeschlagen (Exitcode $RC, siehe $TODAY_DIR/.rsync-fehler)";;
        esac

        # Gegenprobe: ausgewählte Dateien müssen im Snapshot liegen und identisch sein
        PROBE_OK=1
        for f in /etc/fstab /etc/nginx/nginx.conf /etc/nginx/sites-available/035-meet /opt/meet/compose.yml \
                 /hdd1/okapeo/okapeo-app/.git/HEAD /hdd1/okapeo/okapeo-genesis/.git/HEAD "$SKRIPT_DIR/backup.sh"; do
            [ -e "$f" ] || continue
            # während des Laufs geändert (z. B. Branchwechsel): Abweichung ist dann kein Fehler
            if [ "$(stat -c %Y "$f")" -ge "$RSYNC_START" ]; then log "Gegenprobe: $f während des Laufs geändert, übersprungen"; continue; fi
            cmp -s "$f" "$TODAY_DIR$f" || { log_warn "Gegenprobe: $f fehlt oder weicht ab"; PROBE_OK=0; }
        done
        if [ -n "$(find "$TODAY_DIR/hdd1/okapeo" -maxdepth 3 -name node_modules -print -quit 2>/dev/null)" ]; then
            log_warn "Gegenprobe: node_modules im Snapshot gelandet (Ausschlüsse greifen nicht)"; PROBE_OK=0
        fi

        if { [ "$RC" -eq 0 ] || [ "$RC" -eq 24 ] || [ "$RC" -eq 23 ]; } && [ "$PROBE_OK" -eq 1 ]; then
            touch "$TODAY_DIR/.vollstaendig"
            ln -sfn "$TODAY_DIR" "$BACKUP_ROOT/latest"
            PREV="$TODAY_DIR"
            log "Snapshot vollständig, latest -> $TODAY_DIR"
        fi
    fi
fi

# ----------------------------------------
# Aufbewahrung: Tagesordner älter als RETENTION_DAYS löschen (nach Name, nicht mtime).
# Nur nach einem vollständigen Snapshot heute; der neueste vollständige bleibt immer.
# ----------------------------------------
if [ "$DRY_RUN" -eq 0 ] && [ -f "$TODAY_DIR/.vollstaendig" ]; then
    GRENZE=$(date -d "-$RETENTION_DAYS days" +%F)
    for d in "$BACKUP_ROOT"/20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
        n=$(basename "$d")
        if [[ "$n" < "$GRENZE" ]] && [ "$d" != "$PREV" ]; then
            rm -rf "$d" && log "Alter Snapshot gelöscht: $n (älter als $RETENTION_DAYS Tage)"
        fi
    done
fi

FREI=$(df --output=pcent /hdd2 | tail -1 | tr -dc 0-9)
[ "$FREI" -gt 90 ] && log_warn "/hdd2 ist zu ${FREI}% voll"

# Anleitung und Suche auch auf hdd2 ablegen (falls /root mal weg ist)
if [ "$DRY_RUN" -eq 0 ]; then
    cp -f "$SKRIPT_DIR/WIEDERHERSTELLEN.md" "$SKRIPT_DIR/backup-suche" "$BACKUP_ROOT/" \
        || log_warn "Anleitung/backup-suche nicht nach $BACKUP_ROOT kopiert"
fi

FERTIG=1
log "Backup beendet nach ${SECONDS}s, ${#FEHLER[@]} Problem(e)"
[ "${#FEHLER[@]}" -eq 0 ]; exit
}
