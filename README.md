# Backup Script

Tägliches Backup des Servers nach `/hdd2/backups/JJJJ-MM-TT/`: Datenbank-Dumps (MariaDB, PostgreSQL, MongoDB,
Postgres in Docker-Containern) und ein rsync-Snapshot der wichtigen Ordner. Jeder Tagesordner sieht aus wie eine
Vollkopie; unveränderte Dateien sind Hardlinks auf den Vortag (`--link-dest`), es werden also nur Änderungen
kopiert. Aufbewahrung 180 Tage.

**Wiederherstellen, Notfälle, was gesichert ist und was nicht: [WIEDERHERSTELLEN.md](WIEDERHERSTELLEN.md).**

## Dateien

| Datei | Zweck |
|---|---|
| `backup.sh` | das Backup (Cron täglich 4:00) |
| `backup-suche` | alle Versionen einer Datei finden, verlinkt nach `/usr/local/bin/backup-suche` |
| `WIEDERHERSTELLEN.md` | Anleitung, wird bei jedem Lauf auch nach `/hdd2/backups/` kopiert |
| `.env` | `HA_WEBHOOK=<id>` für den Push über Home Assistant (nicht im Repo) |

## Einrichtung

```bash
ln -s /root/scripts/backup-suche /usr/local/bin/backup-suche
crontab -e
# 0 4 * * * /root/scripts/backup.sh >> /var/log/backup.log 2>&1
```

MongoDB-Zugang kommt aus `/etc/environment` (`MDB_HOST`, `MDB_USER`, `MDB_PW`, `MDB_DB`).

Push: In Home Assistant eine Automation mit Webhook-Auslöser (`local_only`, POST) anlegen, die
`notify.mobile_app_<handy>` mit `{{ trigger.json.title }}` und `{{ trigger.json.message }}` aufruft. Die
Webhook-ID kommt als `HA_WEBHOOK=...` in `/root/scripts/.env`.

## Flags

| Flag | Wirkung |
|---|---|
| (keins) | alle Dumps und rsync |
| `--databases` | alle Dumps, kein rsync |
| `--only-mariadb`, `--only-psql`, `--only-mongo`, `--only-docker` | nur dieser Dump |
| `--dry-run` | nichts schreiben, nur loggen |
| `--test-alarm` | nur Mail und Push testen |

## Verhalten

- Ein Fehler in einem Schritt bricht die anderen nicht ab. Alle Fehler werden gesammelt und am Ende per Mail und
  Push gemeldet, ebenso ein vorzeitiger Abbruch des Skripts. Ohne Fehler kommt keine Nachricht.
- Nur ein Lauf gleichzeitig (`flock` auf `/run/backup.lock`). Hängt ein Lauf über 20 Stunden, meldet der nächste das.
- Ist `/hdd2` nicht gemountet, wird nichts geschrieben (sonst liefe die Systemplatte voll).
- Ein Tag gilt erst als vollständig (`.vollstaendig`, `latest` wird umgehängt), wenn rsync durchlief und die
  Gegenprobe (ausgewählte Dateien Byte für Byte) stimmt. Nur dann werden alte Tage gelöscht, nach Ordnername,
  und der neueste vollständige Stand bleibt immer.
- Das Skript steht komplett in `{ ... }`: Bash liest es vor dem Start ein, Änderungen stören einen laufenden Lauf nicht.
- Rechte: `/hdd2` gehört root mit 755, `db/` je Tag hat 700 (Dumps enthalten alle Datenbanken im Klartext). Im
  Snapshot behalten Dateien Besitzer, Rechte und Zugriffslisten des Originals (rsync `-aHA`).
- Je Tag entsteht `system/` mit Paketliste, Platten samt UUIDs, Containern und aktivierten Diensten: der Bauplan
  für den Neuaufbau, falls die Systemplatte ausfällt.

#### License

Copyright © Florian DasNerdwork/TheNerdwork Falk. All rights reserved.

This code is proprietary. No part of this repository may be used, copied, modified, or distributed in any form without explicit written permission from the author.
