# Backup: Wiederherstellen und Notfälle

Liegt doppelt: `/root/scripts/WIEDERHERSTELLEN.md` und `/hdd2/backups/WIEDERHERSTELLEN.md` (falls `/root` weg ist).
Ausführliche Fassung mit Szenarien und Abwägungen: Genesis, `wissen/infrastruktur/backup.md`.

## Auf einen Blick

| | |
|---|---|
| Wann | täglich 4:00 (root-Crontab), Skript `/root/scripts/backup.sh` |
| Wohin | `/hdd2/backups/JJJJ-MM-TT/` (eigene Platte im selben Rechner), `latest` zeigt auf den neuesten vollständigen Stand |
| Wie lange | 180 Tage, jeder Tag einzeln abrufbar |
| Log | `/var/log/backup.log`, je Tag zusätzlich `.rsync-stats` und `.rsync-fehler` im Tagesordner |
| Alarm | bei Fehlern Mail an dasnerdwork@gmail.com (landet ggf. im Spam) und Push aufs Handy (Home Assistant, Automation „Backup-Alarm“). Läuft alles glatt, kommt nichts. Test: `/root/scripts/backup.sh --test-alarm` |

**Gesichert:** `/hdd1` (komplett, inkl. `.git` unter `/hdd1/okapeo`), `/etc`, `/opt`, `/home`, `/root`, `/var/www`,
`/usr/local/bin`, `/var/spool/cron` (Crontabs), `/var/vmail`, Docker-Volumes `okapeo-prototyp_s3-data`,
`okapeo-prototyp_postgres-data`, `okapeo-prototyp_minio-data`, `n8n_data`, `matter-data`, `backend_postgres_data`.
Datenbank-Dumps unter `db/`: MariaDB, Postgres (Host), MongoDB, Docker-Postgres `okapeo-prototyp-postgres-1`
(app.okapeo.com) und `strapi-db`.

**Nicht gesichert:** Caches und Build-Ergebnisse (`node_modules`, `.pnpm-store`, `.next`, `.turbo`, `.npm`,
`.cache`, `__pycache__`, `vendor`), `.git` außerhalb von `/hdd1/okapeo`, `/root/.bun`, `.rustup`, `.nvm`,
Spiele-Caches, `/var/log`, Docker-Images und alle übrigen Docker-Volumes (Testinstanzen, supabase), alles Weitere
auf der Systemplatte (`/usr`, `/var/lib/...`). Liste: `EXCLUDES` in `backup.sh`.

**Wie es funktioniert:** Jeder Tagesordner sieht aus wie eine Vollkopie. Der Pfad im Backup ist der Originalpfad
mit dem Datumsordner davor. Unveränderte Dateien sind Hardlinks auf den Vortag und kosten keinen Platz, nur
Änderungen werden kopiert. Einen Tagesordner zu löschen schadet den anderen nicht.

```
/etc/nginx/sites-available/035-meet
/hdd2/backups/2026-10-03/etc/nginx/sites-available/035-meet
```

## Eine Datei zurückholen (z. B. gelöschte nginx-Config)

```bash
backup-suche /etc/nginx/sites-available/035-meet
```

Zeigt nur die Tage, an denen sich die Datei geändert hat, und „ab hier nicht mehr vorhanden“, falls sie gelöscht
wurde. Dann:

```bash
diff /hdd2/backups/2026-10-01/etc/nginx/sites-available/035-meet /etc/nginx/sites-available/035-meet   # ansehen
cp -a /hdd2/backups/2026-10-01/etc/nginx/sites-available/035-meet /etc/nginx/sites-available/035-meet
nginx -t && systemctl reload nginx
```

Symlinks (z. B. `sites-enabled/*`) sind als Link gesichert, ihr Ziel unter dessen eigenem Pfad. `cp -a` stellt
den Link wieder her.

Pfad unbekannt? `backup-suche -n '035-meet*'` sucht nach dem Namen im neuesten Stand.

## Einen Ordner zurückholen

```bash
backup-suche /hdd1/okapeo/okapeo-genesis        # an welchen Tagen hat sich darin etwas geändert
rsync -a --dry-run -v /hdd2/backups/2026-10-01/hdd1/okapeo/okapeo-genesis/ /hdd1/okapeo/okapeo-genesis/   # erst schauen
rsync -a /hdd2/backups/2026-10-01/hdd1/okapeo/okapeo-genesis/ /hdd1/okapeo/okapeo-genesis/               # dann echt
```

Mit `--delete` wird der Ordner exakt auf den alten Stand gebracht (neuere Dateien werden gelöscht), also vorsichtig.
`node_modules` usw. sind nicht im Backup: danach `pnpm install` bzw. `npm ci`.

## Datenbanken

Dumps liegen unter `/hdd2/backups/<datum>/db/`. Vorher immer die App stoppen, die in die Datenbank schreibt.

**okapeo (app.okapeo.com, Docker `okapeo-prototyp-postgres-1`, Datenbank `okapeo_tenant`)**. Am 03.10.2026 getestet,
Einspielen dauert etwa 5 Sekunden:

```bash
D=/hdd2/backups/<datum>/db/docker/okapeo-prototyp-postgres-1_<datum>.sql.gz
okapeo-stack stop api worker web
docker exec okapeo-prototyp-postgres-1 psql -U okapeo -d postgres -c 'DROP DATABASE okapeo_tenant WITH (FORCE)'
zcat "$D" | docker exec -i okapeo-prototyp-postgres-1 psql -U okapeo -d postgres -q
okapeo-stack start api worker web
```

Meldungen „role … already exists“ sind normal. Ohne Risiko vorher ausprobieren: Dump in einen Wegwerf-Container
spielen (`docker run -d --rm --name restore-test -e POSTGRES_USER=okapeo -e POSTGRES_PASSWORD=test postgres:18-alpine`,
dann `zcat "$D" | docker exec -i restore-test psql -U okapeo -d postgres -q`, am Ende `docker stop restore-test`).

**strapi (Docker `strapi-db`)**: wie okapeo, Benutzer per `docker exec strapi-db env | grep POSTGRES_USER`.

**Postgres auf dem Host** (alle Datenbanken):

```bash
zcat /hdd2/backups/<datum>/db/postgres/all_databases_<datum>.sql.gz | sudo -u postgres psql -d postgres
```

Nur eine Datenbank: in einen Wegwerf-Container spielen (wie oben) und daraus `pg_dump name` ziehen, oder vorher
`DROP DATABASE name` und den kompletten Dump einspielen (Fehler zu bestehenden Datenbanken ignorieren).

**MariaDB** (alle Datenbanken):

```bash
zcat /hdd2/backups/<datum>/db/mariadb/all_databases_<datum>.sql.gz | mariadb
```

Nur eine Datenbank:
``zcat ... | sed -n '/^-- Current Database: `NAME`/,/^-- Current Database: `/p' | mariadb``

**MongoDB** (clashappdb):

```bash
. /etc/environment
mongorestore --host "$MDB_HOST" -u "$MDB_USER" -p "$MDB_PW" --authenticationDatabase "$MDB_DB" \
  --archive=/hdd2/backups/<datum>/db/mongodb/all_databases_<datum>.archive.gz --gzip --drop --nsInclude 'clashappdb.*'
```

## Docker-Volumes (z. B. okapeo-Uploads)

```bash
okapeo-stack stop
rsync -a --delete /hdd2/backups/<datum>/var/lib/docker/volumes/okapeo-prototyp_s3-data/ /var/lib/docker/volumes/okapeo-prototyp_s3-data/
okapeo-stack start
```

## Wenn etwas kaputt geht

| Was | Folge | Was tun |
|---|---|---|
| Datei oder Ordner versehentlich gelöscht oder kaputt | höchstens die Änderungen seit 4:00 sind weg | `backup-suche`, dann `cp -a` bzw. `rsync -a` (siehe oben) |
| okapeo-Datenbank kaputt | Stand von 4:00, Änderungen seit 4:00 sind weg | Dump einspielen (siehe oben) |
| hdd1 defekt | Daten bis 4:00 auf hdd2, Code zusätzlich auf GitHub | neue Platte, Eintrag in `/etc/fstab` anpassen (UUID), `rsync -aH /hdd2/backups/latest/hdd1/ /hdd1/`, in den Projekten `pnpm install`, Container neu starten |
| Systemplatte (NVMe) defekt | Configs, Crontab, `/opt`, `/root`, okapeo-DB (Dump) und Uploads liegen auf hdd2 | Debian neu installieren, `/etc` gezielt zurückkopieren (nicht blind komplett: fstab, UUIDs, Netzwerk prüfen), Pakete und Docker neu, `okapeo-stack up -d --build`, DB-Dump einspielen, Volumes zurück |
| hdd2 defekt | keine Backups mehr, Live-Daten auf hdd1 unberührt, Code auf GitHub | neue Platte nach `/hdd2` mounten, `mkdir /hdd2/backups`, `backup.sh` einmal von Hand (Vollkopie, dauert Stunden) |
| Rechner weg (Brand, Diebstahl, Überspannung, Ransomware) | **alles außer GitHub verloren**: okapeo-Datenbank, Uploads, Configs | heute keine Vorsorge. Offen: Kopie außer Haus (z. B. restic, verschlüsselt, Hetzner Storage Box) |
| Backup schlägt fehl | Mail und Push | `tail -50 /var/log/backup.log`, je Tag `.rsync-fehler`. Ein Fehler in einem Schritt bricht die anderen nicht ab |

## Läuft das Backup?

```bash
tail -20 /var/log/backup.log                       # letzter Lauf, „0 Problem(e)“?
ls -l /hdd2/backups/latest                         # zeigt auf heute (bzw. gestern vor 4:00)?
ls /hdd2/backups/latest/.vollstaendig              # nur vorhanden, wenn rsync und Gegenprobe ok waren
/root/scripts/backup.sh --test-alarm               # Mail und Push testen
```

Von Hand starten (eine Sperre verhindert Doppelläufe):
`setsid nohup /root/scripts/backup.sh >> /var/log/backup.log 2>&1 &`. Nur Datenbanken: `--databases`.
Probelauf ohne Schreiben: `--dry-run`.

Jeder Lauf prüft sich selbst: Dumps (Exitcode, gzip-Test, Mindestgröße), rsync-Exitcode, und eine Gegenprobe
vergleicht ausgewählte Dateien (fstab, nginx, meet, `.git/HEAD` von okapeo-app und okapeo-genesis) Byte für Byte mit
dem Snapshot. Erst dann wird der Tag als vollständig markiert und `latest` umgehängt.

## Bekannte Grenzen

- hdd2 steckt im selben Rechner (siehe Tabelle). Eine Kopie außer Haus ist bewusst vertagt.
- Backups sind nicht verschlüsselt. Wer an hdd2 kommt, sieht alles, auch `.env`-Dateien mit Geheimnissen.
- Was zwischen 4:00 und einem Ausfall passiert, ist nicht gesichert (Code: git push, Daten: weg).
- Die Alarm-Mail landet im Spam, weil der SPF-Eintrag von dasnerdwork.net smtp2go nicht erlaubt.
- Fallen Server oder cron ganz aus, kommt kein Alarm, weil das Skript dann gar nicht läuft.
