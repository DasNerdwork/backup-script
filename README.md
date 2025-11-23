# Backup-Skript

Dieses Bash-Skript erstellt Backups von Datenbanken (MySQL/MariaDB, PostgreSQL, MongoDB) und beliebigen Verzeichnissen auf dem System. Es unterstützt optionale Flags, um gezielt nur bestimmte Komponenten zu sichern oder einen Dry-Run durchzuführen.

## Funktionen

- Vollständige oder selektive Backups von MySQL/MariaDB, PostgreSQL und MongoDB.
- Rsync-Backup von beliebigen Verzeichnissen mit Ausschlussoptionen für Cache-, temporäre oder große Dateien.
- Tägliche Backups werden unter `/hdd2/backups/YYYY-MM-DD/` abgelegt.
- Das Verzeichnis `latest` verweist auf das zuletzt erstellte Backup für inkrementelle Sicherungen.


## Installation

1. Skript auf den Server kopieren, z.B. nach `/usr/local/bin/backup.sh`.
2. Ausführbar machen:

```bash
chmod +x /usr/local/bin/backup.sh
```
3. Optional: Ein Cronjob für automatische regelmäßige Backups anlegen:
```bash
1 4 15 * * /usr/local/bin/backup.sh
```
## Nutzung
```bash
./backup.sh [FLAGS]
```

### Verfügbare Flags
|Flag|Beschreibung|
|-|-|
|`--only-mysql`|Nur MySQL/MariaDB-Dump durchführen|
|`--only-psql`|Nur PostgreSQL-Dump durchführen|
|`--only-mongo`|Nur MongoDB-Dump durchführen|
|`--databases`|Alle Datenbanken dumpen, kein Rsync|
|`--dry-run`|Simulation, es werden keine Backups erstellt, nur Log-Ausgaben|

> Wenn keine Flags angegeben werden, werden standardmäßig alle Datenbanken und Rsync-Backups ausgeführt.

## Backup-Ziel

- Standardmäßig: `/hdd2/backups/`
- Tägliche Backups werden unter /hdd2/backups/YYYY-MM-DD/ gespeichert.
- Das Verzeichnis latest verweist auf das zuletzt erstellte Backup, damit Rsync inkrementelle Backups effizient durchführen kann.

## Ausschlüsse

Beim Rsync-Backup werden bestimmte Dateien und Verzeichnisse automatisch ausgeschlossen, z.B.:
- Cache-Ordner (.cache, .pub-cache, .dartServer)
- Temporäre Dateien (*.swp, *.tmp)
- Node-Module (node_modules)
- Git-Ordner (.git)
- Spielespezifische Caches (steam_cache, garrysmod/cache, satisfactory/Engine/Binaries/Linux/*.debug)
- Große Binärdateien und Archive (*.gma, *.vpk, *.uacs)
- Diese Ausschlüsse können bei Bedarf in der EXCLUDES-Liste im Skript angepasst werden.

## Logging

- Alle Aktionen werden in /var/log/backup.log protokolliert.
- Dry-Runs werden ebenfalls im Log vermerkt, ohne dass echte Backups erstellt werden.

### Hinweise

- MongoDB-Dumps verwenden standardmäßig die Umgebungsvariablen:
`
MDB_HOST, MDB_USER, MDB_PW, MDB_DB, MDB_PATH
`

### Beispiel

Backup aller Datenbanken ohne Rsync:

`./backup.sh --databases`


Nur MySQL-Backup:

`./backup.sh --only-mysql`


Testlauf ohne Änderungen:

`./backup.sh --dry-run`

#### Autor

Florian Falk
