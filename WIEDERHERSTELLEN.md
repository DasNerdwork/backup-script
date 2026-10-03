# Backup: Wiederherstellen und Notfälle

Liegt doppelt: `/root/scripts/WIEDERHERSTELLEN.md` und `/hdd2/backups/WIEDERHERSTELLEN.md` (falls `/root` weg ist).
Die Fassung für Menschen mit Hintergrund und Abwägungen: Genesis, `wissen/infrastruktur/backup.md`.

Diese Datei ist so geschrieben, dass ein Claude-Agent sie Schritt für Schritt abarbeiten kann.

## Welcher Fall liegt vor?

| Der Mensch sagt | Abschnitt |
|---|---|
| „Ich hab versehentlich was gelöscht oder überschrieben, hol das zurück“ | [1. Datei oder Ordner zurückholen](#1-datei-oder-ordner-zurückholen) |
| „In der Datenbank fehlt was“ oder „die Datenbank ist kaputt“ | [2. Datenbank zurückholen](#2-datenbank-zurückholen) |
| „Die Festplatte ist abgeraucht“ | [3. Festplatte ausgefallen](#3-festplatte-ausgefallen) |
| „Irgendwas ist korrupt“, „das lief gestern noch“ | [4. Etwas ist kaputt und muss repariert werden](#4-etwas-ist-kaputt-und-muss-repariert-werden) |
| „Wir wurden gehackt“, „da ist was Komisches auf dem Server“ | [5. Angriff von außen](#5-angriff-von-außen) |
| „Läuft das Backup überhaupt?“, Alarm-Mail bekommen | [6. Backup prüfen](#6-backup-prüfen) |

## Regeln für den Agenten

1. **Das Backup wird nur gelesen.** Nie etwas unter `/hdd2/backups/` ändern, verschieben oder löschen. Kopiert wird
   immer vom Backup zum Original, nie umgekehrt.
2. **Erst schauen, dann schreiben.** Vor jedem Zurückspielen zeigen, was sich ändern würde (`diff`,
   `rsync --dry-run`), und dem Menschen das Ergebnis nennen.
3. **Den jetzigen Stand nicht wegwerfen.** Wird etwas Vorhandenes überschrieben, vorher eine Kopie daneben legen
   (`cp -a datei datei.vor-restore`). Bei Datenbanken vorher einen frischen Dump ziehen.
4. **Vor allem, was löscht oder überschreibt, nachfragen:** `rsync --delete`, `DROP DATABASE`, `mkfs`, Partitionieren.
   Gerätenamen (`/dev/sdX`) immer mit `lsblk` gegenprüfen, nie raten.
5. **Den richtigen Tag wählen.** Der neueste Stand ist nicht automatisch der richtige. Wurde etwas vor drei Tagen
   gelöscht oder beschädigt, ist es in den letzten drei Snapshots ebenfalls weg oder kaputt.
6. **Am Ende prüfen und berichten:** Ist die Datei da, startet der Dienst, was wurde zurückgespielt, aus welchem Tag.

## Auf einen Blick

| | |
|---|---|
| Wann | täglich 4:00 (root-Crontab), Skript `/root/scripts/backup.sh` |
| Wohin | `/hdd2/backups/JJJJ-MM-TT/` (eigene Platte im selben Rechner), `latest` zeigt auf den neuesten vollständigen Stand |
| Wie lange | 180 Tage, jeder Tag einzeln abrufbar. Dateien gibt es ab dem 03.10.2026, davor nur Datenbank-Dumps |
| Log | `/var/log/backup.log`, je Tag zusätzlich `.rsync-stats` und `.rsync-fehler` im Tagesordner |
| Alarm | bei Fehlern Mail an dasnerdwork@gmail.com und Push aufs Handy (Home Assistant, Automation „Backup-Alarm“). Läuft alles glatt, kommt nichts |

**So sieht ein Tagesordner aus:** Der Pfad im Backup ist der Originalpfad mit dem Datumsordner davor.

```
/etc/nginx/sites-available/035-meet                              Original
/hdd2/backups/2026-10-03/etc/nginx/sites-available/035-meet      Stand vom 03.10.
/hdd2/backups/2026-10-03/db/                                     Datenbank-Dumps (nur root)
/hdd2/backups/2026-10-03/system/                                 Bauplan: Pakete, Platten, Container, Dienste
```

Jeder Tagesordner sieht aus wie eine Vollkopie. Unveränderte Dateien sind Hardlinks auf den Vortag und kosten
keinen Platz. Einen Tagesordner zu löschen schadet den anderen nicht.

**Gesichert:** `/hdd1` (komplett, inkl. `.git` unter `/hdd1/okapeo`), `/etc`, `/opt`, `/home`, `/root`, `/var/www`,
`/usr/local/bin`, `/var/spool/cron` (Crontabs), `/var/vmail`, Docker-Volumes `okapeo-prototyp_s3-data`,
`okapeo-prototyp_postgres-data`, `okapeo-prototyp_minio-data`, `n8n_data`, `matter-data`, `backend_postgres_data`.
Datenbank-Dumps unter `db/`: MariaDB, Postgres (Host), MongoDB, Docker-Postgres `okapeo-prototyp-postgres-1`
(app.okapeo.com) und `strapi-db`. Besitzer, Rechte und Zugriffslisten (ACLs, ab dem Lauf vom 04.10.2026) bleiben erhalten.

**Nicht gesichert:** Caches und Build-Ergebnisse (`node_modules`, `.pnpm-store`, `.next`, `.turbo`, `.npm`,
`.cache`, `__pycache__`, PHP-`vendor`), `.git` außerhalb von `/hdd1/okapeo`, `.vscode-server`, `/root/.bun`,
`.rustup`, `.nvm`, Nextcloud-Vorschaubilder, Spiele-Caches (`steam_cache`, `garrysmod/cache`, `*.gma`, `*.vpk`),
`/var/log`, Docker-Images und alle übrigen Docker-Volumes (Testinstanzen, supabase), alles Weitere auf der
Systemplatte (`/usr`, `/var/lib/...`). Liste: `EXCLUDES` in `backup.sh`.

## 1. Datei oder Ordner zurückholen

Typischer Auftrag: „Ich hab vor ein paar Tagen versehentlich X gelöscht, lass uns das aus dem Backup holen.“

**Schritt 1: Finden, an welchen Tagen es die Datei gab.**

```bash
backup-suche /etc/nginx/sites-available/035-meet
```

Die Ausgabe zeigt nur die Tage, an denen sich die Datei geändert hat, und „ab hier nicht mehr vorhanden“ ab dem
Tag, an dem sie fehlte. Der richtige Stand ist der letzte Tag vor dieser Zeile, bei einer kaputten Datei der
letzte Tag vor der Beschädigung.

Pfad nicht genau bekannt:

```bash
backup-suche -n '035-meet*'                              # sucht im neuesten Stand
find /hdd2/backups/2026-10-01 -name '035-meet*'           # sucht in einem älteren Tag (wenn im neuesten schon weg)
ls -d /hdd2/backups/*/hdd1/okapeo/qa/tour.mjs             # alle Tage, an denen der Pfad existierte
```

Findet sich nichts: Steht der Pfad unter „Nicht gesichert“? Wurde die Datei am selben Tag angelegt und gelöscht
(dann gab es um 4:00 noch nichts)? Bei Code zusätzlich `git log --all -- <pfad>` und GitHub prüfen.

**Schritt 2: Ansehen und vergleichen.**

```bash
B=/hdd2/backups/2026-10-01
less $B/etc/nginx/sites-available/035-meet
diff $B/etc/nginx/sites-available/035-meet /etc/nginx/sites-available/035-meet    # falls das Original noch existiert
```

**Schritt 3: Zurückkopieren.** `cp -a` erhält Besitzer, Rechte und Zeitstempel und stellt auch Symlinks wieder her.

```bash
[ -e /etc/nginx/sites-available/035-meet ] && cp -a /etc/nginx/sites-available/035-meet{,.vor-restore}
cp -a $B/etc/nginx/sites-available/035-meet /etc/nginx/sites-available/035-meet
```

**Ganzer Ordner:**

```bash
backup-suche /hdd1/okapeo/okapeo-genesis                                              # an welchen Tagen änderte sich etwas
rsync -aHA --dry-run -v $B/hdd1/okapeo/okapeo-genesis/ /hdd1/okapeo/okapeo-genesis/   # erst schauen
rsync -aHA $B/hdd1/okapeo/okapeo-genesis/ /hdd1/okapeo/okapeo-genesis/                # dann echt
```

Ohne `--delete` werden nur fehlende und abweichende Dateien zurückgeholt, Neueres bleibt liegen. Das ist der
Normalfall. Mit `--delete` wird der Ordner exakt auf den alten Stand gebracht und alles Neuere gelöscht, also
nur nach Rückfrage.

**Schritt 4: Nacharbeit.**

- Code-Projekt: `node_modules` usw. sind nicht im Backup, danach `pnpm install` bzw. `npm ci`.
- Konfiguration eines Dienstes: prüfen und neu laden, z. B. `nginx -t && systemctl reload nginx`.
- Kontrolle: `ls -la <pfad>`, Besitzer und Gruppe mit einer Nachbardatei vergleichen.

## 2. Datenbank zurückholen

Dumps liegen unter `/hdd2/backups/<datum>/db/` (nur root). Ein Dump ist der Stand von 4:00 an diesem Tag.

**Immer zuerst:** den jetzigen Zustand sichern und die App stoppen, die in die Datenbank schreibt.

**Nur einzelne Zeilen oder Tabellen fehlen** („ich hab vor drei Tagen einen Kunden gelöscht“): nicht die ganze
Datenbank zurückdrehen, sonst sind alle Änderungen seither weg. Stattdessen den alten Dump in einen
Wegwerf-Container spielen und die Daten gezielt herausholen:

```bash
D=/hdd2/backups/<datum>/db/docker/okapeo-prototyp-postgres-1_<datum>.sql.gz
docker run -d --rm --name restore-test -e POSTGRES_USER=okapeo -e POSTGRES_PASSWORD=test postgres:18-alpine
sleep 5; zcat "$D" | docker exec -i restore-test psql -U okapeo -d postgres -q
docker exec -it restore-test psql -U okapeo -d okapeo_tenant        # nachsehen, Zeilen heraussuchen
docker exec restore-test pg_dump -U okapeo -d okapeo_tenant --data-only -t <tabelle> > /root/tabelle.sql
docker stop restore-test
```

Wie die Zeilen zurück in die echte Datenbank kommen, hängt von den Abhängigkeiten zwischen den Tabellen ab. Das
mit dem Menschen abstimmen, nicht blind einspielen.

**Ganze okapeo-Datenbank zurückdrehen** (app.okapeo.com, Docker `okapeo-prototyp-postgres-1`, Datenbank
`okapeo_tenant`). Am 03.10.2026 getestet, Einspielen dauert etwa 5 Sekunden:

```bash
D=/hdd2/backups/<datum>/db/docker/okapeo-prototyp-postgres-1_<datum>.sql.gz
okapeo-stack stop api worker web
docker exec okapeo-prototyp-postgres-1 sh -c 'pg_dumpall -U "$POSTGRES_USER"' | gzip > /root/okapeo-vor-restore.sql.gz
docker exec okapeo-prototyp-postgres-1 psql -U okapeo -d postgres -c 'DROP DATABASE okapeo_tenant WITH (FORCE)'
zcat "$D" | docker exec -i okapeo-prototyp-postgres-1 psql -U okapeo -d postgres -q
okapeo-stack start api worker web
```

Meldungen „role … already exists“ sind normal.

**strapi (Docker `strapi-db`)**: wie okapeo, Benutzer per `docker exec strapi-db env | grep POSTGRES_USER`.

**Postgres auf dem Host** (`n8n_db`, `petroldb`, `voidwatch`, `zitadel`):

```bash
zcat /hdd2/backups/<datum>/db/postgres/all_databases_<datum>.sql.gz | sudo -u postgres psql -d postgres
```

Nur eine Datenbank: in einen Wegwerf-Container spielen (wie oben) und daraus `pg_dump name` ziehen, oder vorher
`DROP DATABASE name` und den kompletten Dump einspielen (Fehler zu bestehenden Datenbanken ignorieren).

**MariaDB** (`nextcloud`, `clashdb`, `ftdb`, `wpdb`, `ilealoriwp`, `reisesockedb`):

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

**Docker-Volumes** (z. B. okapeo-Uploads):

```bash
okapeo-stack stop
rsync -a --delete /hdd2/backups/<datum>/var/lib/docker/volumes/okapeo-prototyp_s3-data/ /var/lib/docker/volumes/okapeo-prototyp_s3-data/
okapeo-stack start
```

## 3. Festplatte ausgefallen

Im Rechner stecken drei Platten. Zuerst klären, welche betroffen ist:

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID,MODEL
smartctl -H /dev/sda; smartctl -H /dev/sdb; smartctl -H /dev/nvme0n1
dmesg -T | grep -iE 'I/O error|ata[0-9]|nvme' | tail -30
```

| Platte | Gerät (Stand 03.10.2026) | Enthält |
|---|---|---|
| Systemplatte | `nvme0n1` (ADATA, 238 GB), `/` ext4, `/boot/efi` | Debian 13, `/etc`, `/opt`, `/root`, `/home`, Datenbanken, Docker |
| hdd1 | `sda1` (WD 2 TB), `/hdd1` | Okapeo, Nextcloud, Projekte, Modelle |
| hdd2 | `sdb1` (WD 2 TB), `/hdd2` | nur die Backups |

Der Stand zum Zeitpunkt des letzten Backups steht in `/hdd2/backups/latest/system/platten.txt`.

Stirbt eine Platte gerade erst (SMART-Warnung, einzelne Lesefehler): sofort alles Wichtige sichern, was seit 4:00
neu ist (`git push`, frischer Datenbank-Dump), und die Platte so wenig wie möglich benutzen.

### 3a. hdd1 ist defekt

Verloren: Änderungen seit 4:00. Gepushter Code liegt zusätzlich auf GitHub. Dauer: einige Stunden.

1. Alles stoppen, was auf `/hdd1` zugreift: `okapeo-stack down`, `docker compose` der Projekte unter `/hdd1/strapi`
   und `/hdd1/okapeo/testinstanzen`, Nextcloud (nginx/php-fpm), Runner. In `/etc/fstab` die Zeile für `/hdd1`
   auskommentieren, damit der Rechner auch ohne die Platte startet.
2. Neue Platte einbauen, mit `lsblk` den Gerätenamen bestimmen (hier als `/dev/sdX`), **nachfragen**, dann:

   ```bash
   parted -s /dev/sdX mklabel gpt mkpart primary ext4 0% 100%
   mkfs.ext4 -L hdd1 /dev/sdX1
   blkid /dev/sdX1                      # neue UUID in /etc/fstab bei /hdd1 eintragen, Typ ext4
   mount /hdd1 && df -h /hdd1
   ```

3. Zurückkopieren (läuft Stunden, deshalb abgekoppelt starten):

   ```bash
   setsid nohup rsync -aHA --numeric-ids --info=progress2 /hdd2/backups/latest/hdd1/ /hdd1/ > /root/restore-hdd1.log 2>&1 &
   tail -f /root/restore-hdd1.log
   ```

4. Zugriffsrechte der gemeinsamen Ordner prüfen. Snapshots vor dem 04.10.2026 enthalten keine ACLs, dann:
   `setfacl -R -m g:okapeo:rwX,d:g:okapeo:rwX /hdd1/okapeo`.
5. Was nicht im Backup ist, neu erzeugen: in jedem Projekt `pnpm install` bzw. `npm ci`. Repos außerhalb von
   `/hdd1/okapeo` haben kein `.git`, die werden frisch von GitHub geklont und der gesicherte Arbeitsstand
   darübergelegt. Nextcloud-Vorschaubilder baut Nextcloud selbst neu.
6. Dienste starten: `okapeo-stack up -d --build`, strapi, Testinstanzen, Nextcloud. Die Liste aller Container mit
   ihrem Compose-Ordner steht in `/hdd2/backups/latest/system/docker.txt`.
7. Prüfen: app.okapeo.com, genesis.okapeo.com, cloud.dasnerdwork.net erreichbar, `git status` in den Repos sauber.

### 3b. Die Systemplatte (NVMe) ist defekt

Verloren: Änderungen seit 4:00 an Datenbanken und Konfiguration. Das ist kein Knopfdruck, sondern ein Neuaufbau
mit Hilfe des Backups. Dauer: etwa ein Tag.

1. Neue NVMe einbauen, Debian 13 frisch installieren (UEFI). **hdd1 und hdd2 bei der Installation nicht anfassen**,
   am sichersten vorher abstecken.
2. hdd1 und hdd2 einhängen. Die UUIDs stehen in `/hdd2/backups/latest/etc/fstab`, nur diese beiden Zeilen in die
   neue `/etc/fstab` übernehmen (die Zeilen für `/`, `/boot/efi` und swap gehören zur alten Platte).
3. Pakete installieren: `xargs -a /hdd2/backups/latest/system/pakete.txt apt install -y`. Einzelne Pakete aus
   Fremdquellen (Docker, MongoDB, Node) brauchen erst ihre Paketquelle aus
   `/hdd2/backups/latest/etc/apt/sources.list.d/`.
4. Benutzer und Gruppen: `/etc/passwd`, `/etc/group`, `/etc/shadow` aus dem Backup mit den neuen vergleichen und
   die eigenen Konten (ab UID 1000 und die Dienstkonten) übernehmen. Die Nummern müssen gleich bleiben, weil die
   Dateien auf hdd1 und im Backup an den Nummern hängen.
5. Daten zurück:

   ```bash
   B=/hdd2/backups/latest
   rsync -aHA --numeric-ids $B/home/ /home/
   rsync -aHA --numeric-ids $B/root/ /root/
   rsync -aHA --numeric-ids $B/opt/ /opt/
   rsync -aHA --numeric-ids $B/var/www/ /var/www/
   rsync -aHA --numeric-ids $B/var/vmail/ /var/vmail/
   rsync -aHA --numeric-ids $B/usr/local/bin/ /usr/local/bin/
   rsync -aHA --numeric-ids $B/var/spool/cron/ /var/spool/cron/
   ```

6. `/etc` gezielt zurückholen, nicht blind komplett: `nginx`, `letsencrypt`, `postfix`, `samba`, `systemd/system`
   (eigene Dienste, Liste in `system/dienste.txt`), `environment`, `ssh`, `cron.*`, `fail2ban`, `openvpn`,
   `pihole`. Nicht übernehmen: `fstab` (bis auf hdd1/hdd2), Netzwerk-Konfiguration, `machine-id`.
7. Datenbanken: MariaDB, Postgres und MongoDB sind über die Pakete installiert, dann die Dumps aus
   `$B/db/` einspielen (Abschnitt 2).
8. Docker: Volumes zurückkopieren (`$B/var/lib/docker/volumes/*` nach `/var/lib/docker/volumes/`), dann je
   Compose-Ordner aus `system/docker.txt` `docker compose up -d --build`. Für okapeo danach den Dump einspielen.
   Images werden neu gebaut oder gezogen, sie sind nicht im Backup.
9. Neu installieren, weil nicht gesichert: `.nvm`, `.bun`, `.rustup`, Python-Pakete unter `/usr/local/lib`,
   `node_modules`, `.vscode-server`. Supabase (`notarpartner-app`) und die Testinstanzen starten leer.
10. Cron prüfen (`crontab -l`), Backup einmal von Hand laufen lassen (Abschnitt 6), Dienste und Webseiten durchgehen.

### 3c. hdd2 (die Backup-Platte) ist defekt

Verloren: keine Live-Daten, aber alle Backups und der Verlauf. Bis zum ersten neuen Lauf ist nichts gesichert.

```bash
parted -s /dev/sdX mklabel gpt mkpart primary ext4 0% 100%     # Gerät vorher mit lsblk prüfen, nachfragen
mkfs.ext4 -L hdd2 /dev/sdX1
blkid /dev/sdX1                        # UUID in /etc/fstab bei /hdd2 eintragen, Typ ext4
mount /hdd2 && chmod 755 /hdd2 && mkdir /hdd2/backups
setsid nohup /root/scripts/backup.sh >> /var/log/backup.log 2>&1 &      # Vollkopie, am 03.10.2026: 217 GB in etwa 3 Stunden
```

### 3d. Rechner komplett weg (Brand, Diebstahl, Überspannung)

Dann sind hdd1 und hdd2 beide weg. Es bleibt nur, was auf GitHub liegt (Code, Genesis). Datenbanken, Uploads und
Konfiguration sind verloren. Eine Kopie außer Haus gibt es noch nicht (siehe „Bekannte Grenzen“).

## 4. Etwas ist kaputt und muss repariert werden

Gemeint: Eine Datei, ein Repo, eine Datenbank oder ein Dienst ist beschädigt, die Platte lebt aber noch.

**Zuerst die Ursache eingrenzen, nicht sofort zurückspielen.** Wenn die Platte stirbt, wird das Zurückgespielte
gleich wieder kaputt.

```bash
smartctl -H /dev/sda; smartctl -A /dev/sda | grep -Ei 'Reallocated|Pending|Uncorrectable'
dmesg -T | grep -iE 'I/O error|EXT[34]-fs error' | tail -20
df -h; df -i                           # volle Platte sieht oft aus wie Korruption
```

- Lesefehler oder SMART-Befund: weiter bei Abschnitt 3.
- Dateisystemfehler ohne Hardwarebefund: Dienste stoppen, `umount /hdd1`, `fsck -f /dev/sda1`, wieder einhängen.
  Die Systemplatte lässt sich nur aus einem Rettungssystem prüfen.

**Seit wann ist es kaputt?** `backup-suche <pfad>` zeigt, an welchen Tagen sich etwas geändert hat. Den letzten
Tag vor der Beschädigung nehmen. Im Zweifel zwei Tage vergleichen:

```bash
diff -r /hdd2/backups/2026-10-01/opt/meet /hdd2/backups/2026-10-03/opt/meet
```

| Was ist kaputt | Vorgehen |
|---|---|
| Einzelne Datei oder Konfiguration | Abschnitt 1. Die kaputte Fassung als `.vor-restore` aufheben |
| Dienst startet nach einer Änderung nicht mehr | `journalctl -u <dienst> -n 50`, Konfiguration mit dem Stand von gestern vergleichen (`diff`), nur die Abweichung zurücknehmen |
| Git-Repo (`fatal: bad object`, kaputter Index) | erst `git fsck`. Ist nur der Arbeitsstand betroffen: von GitHub neu klonen und nicht gepushte Commits aus `/hdd2/backups/<datum>/hdd1/okapeo/<repo>/.git` holen (`git fetch /hdd2/backups/.../<repo> <branch>`) |
| Datenbank liefert Fehler oder falsche Daten | Abschnitt 2. Erst den kaputten Zustand dumpen, dann den letzten guten Dump einspielen |
| Fehlgeschlagene Migration bei okapeo | wie Datenbank: Dump von vor der Migration, dazu den Code-Stand von davor |
| Ganzer Projektordner durcheinander | `rsync -aHA --dry-run` gegen den letzten guten Tag, Liste mit dem Menschen durchgehen, dann ohne oder mit `--delete` |
| Docker-Volume beschädigt | Stack stoppen, Volume aus dem Backup (Abschnitt 2 unten), Stack starten |

Nach der Reparatur: Dienst prüfen und notieren, was die Ursache war. Kommt derselbe Fehler wieder, liegt es nicht
an den Daten.

## 5. Angriff von außen

Zeichen: unbekannte Benutzer, Prozesse oder Cronjobs, geänderte Dateien, die niemand angefasst hat, verschlüsselte
Dateien, Logins von fremden Adressen, ungewöhnlicher Netzwerkverkehr, eine Lösegeldforderung.

**Der Agent handelt hier nicht allein.** Bei Verdacht sofort den Menschen einbeziehen und vor jedem Eingriff
abstimmen. Reihenfolge:

1. **Eindämmen, nichts löschen.** In der Fritzbox die Portfreigaben zum Server abschalten oder das Netzwerkkabel
   ziehen. Den Rechner nicht neu aufsetzen und nichts „aufräumen“, bevor klar ist, was passiert ist. Sonst sind die
   Spuren weg.
2. **Die Backups schützen.** Den Cronjob für `backup.sh` auskommentieren, damit der nächste Lauf keinen
   manipulierten Stand als neuesten Tag ablegt und keine alten Tage mehr löscht. Wenn möglich hdd2 aushängen
   (`umount /hdd2`).
3. **Zeitpunkt des Einbruchs bestimmen.**

   ```bash
   last -aiF | head -30; lastb -aiF | head                      # Logins, fehlgeschlagene Logins
   journalctl -u ssh --since '14 days ago' | grep -E 'Accepted|Failed' | tail -50
   awk -F: '$3>=1000 || $3==0' /etc/passwd                      # Konten, zweites Konto mit UID 0?
   for h in /root /home/* /hdd1/strapi; do ls -la $h/.ssh/authorized_keys 2>/dev/null; done
   ls -lat /etc/cron* /var/spool/cron/crontabs /etc/systemd/system | head -40
   ss -tlnp; ps auxf | less                                      # was lauscht, was läuft
   ```

4. **Mit dem Backup vergleichen.** Das Backup ist die Vergleichsbasis: was hat sich seit einem sicheren Tag an
   Stellen geändert, an denen sich nichts ändern sollte?

   ```bash
   B=/hdd2/backups/<letzter sicherer Tag>
   for p in /etc /usr/local/bin /var/spool/cron /root/.ssh /root/scripts /opt/meet; do
     rsync -aHAn --delete --itemize-changes $B$p/ $p/ | head -50
   done
   ```

5. **Den Backups nur bis zum Einbruch trauen.** Alle Snapshots ab dem Tag des Einbruchs gelten als verdächtig.
   Wer root auf dem Server hatte, konnte außerdem hdd2 lesen und verändern, weil sie im selben Rechner steckt.
   Deshalb prüfen, ob die älteren Tagesordner noch plausibel aussehen (Größe, `.vollstaendig`, Stichproben).
6. **Alle Geheimnisse tauschen.** Die Backups sind unverschlüsselt und enthalten jede `.env`. Als bekannt gelten
   deshalb: SSH-Schlüssel und Passwörter aller Konten, GitHub-Tokens und Deploy-Keys, Datenbank-Passwörter,
   OAuth-Geheimnisse (test-oauth2, meet-oauth2), Zugänge zu smtp2go, Cloudflare und netcup, LiveKit-Schlüssel,
   das Genesis-MCP-Geheimnis, der Home-Assistant-Webhook, Basic-Auth-Passwörter.
7. **Wiederherstellen.** Hatte der Angreifer root, wird das System neu aufgesetzt (Abschnitt 3b) und nur mit Daten
   aus einem Snapshot **vor** dem Einbruch befüllt. Programme, Skripte und Cronjobs nicht ungeprüft aus dem Backup
   übernehmen, Code frisch von GitHub klonen. War nur eine einzelne Anwendung betroffen, reicht es, diese samt
   Datenbank auf den Stand davor zu bringen und die Lücke zu schließen.
8. **Melden.** Sind Kundendaten von Okapeo betroffen, gilt die Meldefrist von 72 Stunden (OKA-92,
   Datenpannen-Prozess).

Gegen Ransomware, die mit root-Rechten auch hdd2 verschlüsselt, hilft dieses Backup nicht. Dafür braucht es die
Kopie außer Haus.

## 6. Backup prüfen

```bash
tail -20 /var/log/backup.log                       # letzter Lauf, „0 Problem(e)“?
ls -l /hdd2/backups/latest                         # zeigt auf heute (bzw. gestern vor 4:00)?
ls /hdd2/backups/latest/.vollstaendig              # nur vorhanden, wenn rsync und Gegenprobe ok waren
/root/scripts/backup.sh --test-alarm               # Mail und Push testen (löst wirklich einen Push aus)
```

Von Hand starten (eine Sperre verhindert Doppelläufe):
`setsid nohup /root/scripts/backup.sh >> /var/log/backup.log 2>&1 &`. Nur Datenbanken: `--databases`.
Probelauf ohne Schreiben: `--dry-run`.

Jeder Lauf prüft sich selbst: Dumps (Exitcode, gzip-Test, Mindestgröße), rsync-Exitcode, und eine Gegenprobe
vergleicht ausgewählte Dateien (fstab, nginx, meet, `.git/HEAD` von okapeo-app und okapeo-genesis) Byte für Byte mit
dem Snapshot. Dateien, die während des Laufs geändert wurden, überspringt sie. Erst dann wird der Tag als
vollständig markiert und `latest` umgehängt.

**Alarm bekommen:** Die Mail nennt das Problem. Dann `tail -50 /var/log/backup.log` und im Tagesordner
`.rsync-fehler` lesen. Ein Fehler in einem Schritt bricht die anderen nicht ab. Ist die Ursache behoben, das
Backup von Hand neu starten, es ergänzt den Tagesordner.

**Gründlich prüfen** (am 03.10.2026 so gemacht: 0 Fehler, 400 von 400 Stichproben identisch):

```bash
S=$(readlink -f /hdd2/backups/latest)
for f in $(find $S/db -name '*.gz'); do gzip -t $f && echo "ok $f"; done
find $S/etc $S/opt $S/hdd1/okapeo -type f -size -50M -print0 | shuf -z -n 400 | while IFS= read -r -d '' f; do
  cmp -s "$f" "${f#$S}" || echo "weicht ab: ${f#$S}"; done    # nur seit 4:00 Geändertes darf auftauchen
git -c safe.directory='*' -C $S/hdd1/okapeo/okapeo-app fsck --connectivity-only
```

## Zugriffsrechte

- `/hdd2` gehört root, Rechte 755. Andere Konten können lesen, aber nichts anlegen, umbenennen oder löschen.
  Über die Samba-Freigabe `HDD2` lässt sich deshalb ebenfalls nur lesen.
- Im Snapshot behalten Dateien die Rechte des Originals. `/root` oder `/etc/shadow` kann also auch im Backup nur
  root lesen.
- `db/` hat die Rechte 700. Die Dumps enthalten alle Datenbanken im Klartext.

## Bekannte Grenzen

- hdd2 steckt im selben Rechner. Gegen Brand, Diebstahl, Überspannung und einen Angreifer mit root hilft das
  Backup nicht. Eine Kopie außer Haus ist bewusst vertagt.
- Backups sind nicht verschlüsselt. Wer als root an hdd2 kommt oder die Platte ausbaut, sieht alles, auch
  `.env`-Dateien mit Geheimnissen.
- Was zwischen 4:00 und einem Ausfall passiert, ist nicht gesichert (Code: git push, Daten: weg).
- Dateien gibt es erst ab dem 03.10.2026. Die Tagesordner davor enthalten nur Datenbank-Dumps.
- hdd2 ist knapp sechs Jahre alt (50.000 Betriebsstunden, SMART am 03.10.2026 ohne Befund).
- Die laufende Supabase-Datenbank von `notarpartner-app` und die Testinstanzen werden nicht gesichert.
- Der SPF-Eintrag von dasnerdwork.net erlaubt smtp2go nicht, die Alarm-Mail kann deshalb im Spam landen.
- Fallen Server oder cron ganz aus, kommt kein Alarm, weil das Skript dann gar nicht läuft.
