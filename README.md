# Backup Script

This Bash script creates incremental backups of selected directories and databases (MariaDB, PostgreSQL, MongoDB) on the system. It also supports optional flags to selectively back up specific components or perform a dry-run.

## Features

- Full or selective backups of MariaDB, PostgreSQL, and MongoDB.
- Rsync backups of selected directories with exclusions for cache, temporary, or large files.
- Daily backups are stored under `/hdd2/backups/YYYY-MM-DD/`
- The directory `latest` points to the most recent backup to enable efficient incremental backups with Rsync.
- Automatic backup retention: backups older than `RETENTION_DAYS` (default 180 days) are automatically deleted.
- Automatic log rotation: `/var/log/backup.log` is rotated when it exceeds `MAX_LOG_SIZE` (default 10 MiB).

## Installation

1. Copy the script to the server, e.g., to `/usr/local/bin/backup.sh`
2. Make it executable:

```bash
chmod +x /usr/local/bin/backup.sh
```

3. Optional: create a cronjob for automatic scheduled backups, e.g.:

```bash
0 4 * * * /usr/local/bin/backup.sh >/dev/null
```
> We use `>/dev/null` to mute the output because we already have logging, but not `2>&1` to keep errors in the cronlog

## Usage

```bash
bash path/to/file/backup.sh [FLAGS]
```

### Available Flags

| Flag | Description |
|------|-------------|
| `--only-mariadb | Only perform MariaDB dump |
| `--only-psql | Only perform PostgreSQL dump |
| `--only-mongo | Only perform MongoDB dump |
| `--databases | Dump all databases, no Rsync |
| `--dry-run | Simulate only, no actual backups created; logs actions |

> If no flags are specified, all databases and Rsync backups are executed by default.

## Backup Targets

- Default location: `/hdd2/backups/`
- Daily backups are stored under `/hdd2/backups/YYYY-MM-DD/`
- `latest` always points to the most recent backup, so Rsync can perform incremental backups efficiently.

## Exclusions

During Rsync, certain files and directories are automatically excluded, e.g.:

- Cache directories (.cache, .pub-cache, .dartServer)
- Temporary files (*.swp, *.tmp)
- Node modules (node_modules)
- Git repositories (.git)
- Game-specific caches (steam_cache, garrysmod/cache, satisfactory/Engine/Binaries/Linux/*.debug)
- Large binaries and archives (*.gma, *.vpk, *.uacs)

> These exclusions can be modified in the EXCLUDES array inside the script.

## Logging

- All actions are logged to `/var/log/backup.log`
- Dry-runs are also logged, without creating actual backups
- Logs exceeding `MAX_LOG_SIZE` (default 10 MiB) are automatically rotated
- Old rotated logs older than `RETENTION_DAYS` (default 180 days) are automatically deleted

## Notes

- MongoDB dumps use the following environment variables by default:
`MDB_HOST`, `MDB_USER`, `MDB_PW`, `MDB_DB`, `MDB_PATH`

- Backup retention is based on directory modification time (mtime). Only directories older than `RETENTION_DAYS` are deleted.

## Examples

Backup all databases without Rsync:

```bash
./backup.sh --databases
```

Only MariaDB backup:

```bash
./backup.sh --only-mariadb
```

Dry-run test without creating backups:

```bash
./backup.sh --dry-run
```

#### License

Copyright © Florian DasNerdwork/TheNerdwork Falk. All rights reserved.

This code is proprietary. No part of this repository may be used, copied, modified, or distributed in any form without explicit written permission from the author.