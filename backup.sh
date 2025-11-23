#!/bin/bash
SECONDS=0
DATE=$(date +"%d.%m.%Y")
TIME=$(date +"%H:%M:%S")
FILENAME=/hdd2/backup-$(date +%d-%m-%Y).tar.gz
FILESIZE=$(stat -c%s "$FILENAME")
LOGFILE=/root/logs/backup.log
LOGLINES=$(wc -l /root/logs/backup.log | awk '{print $1;}')
cd /
mkdir /hdd2/backup-$(date +%d-%m-%Y)
tar -cvpzf /hdd2/backup-$(date +%d-%m-%Y)/home.tar.gz --exclude=/backup.tar.gz --one-file-system home
tar -cvpzf /hdd2/backup-$(date +%d-%m-%Y)/etc.tar.gz --exclude=/backup.tar.gz --one-file-system etc
tar -cvpzf /hdd2/backup-$(date +%d-%m-%Y)/opt.tar.gz --exclude=/backup.tar.gz --one-file-system opt
tar -cvpzf /hdd2/backup-$(date +%d-%m-%Y)/www.tar.gz --exclude=/backup.tar.gz --one-file-system var/www
tar -cvpzf /hdd2/backup-$(date +%d-%m-%Y)/hdd1.tar.gz --exclude=/backup.tar.gz --one-file-system hdd1
tar -cvpzf /hdd2/backup-$(date +%d-%m-%Y)/root.tar.gz --exclude=/backup.tar.gz --one-file-system root
cd /hdd2
if [ "$LOGLINES" -gt 11 ];
then
sed -i -e "1d" "$LOGFILE"
fi
SIZE=$(du -h /hdd2/backup-$(date +%d-%m-%Y) | awk '{print $1;}')
if [ "$SECONDS" -lt 2 ];
then
echo -e "Das Backup in \033[0;31m/hdd2/backup\033[0m vom \033[0;36m$DATE\033[0m um \033[0;35m$TIME\033[0m dauerte \033[0;32meine\033[0m Sekunde mit einer Größe von \033[0;33m${SIZE}B\033[0m." >> /root/logs/backup.log
elif [ "$SECONDS" -lt 60 ]
then
echo -e "Das Backup in \033[0;31m/hdd2/backup\033[0m vom \033[0;36m$DATE\033[0m um \033[0;35m$TIME\033[0m dauerte \033[0;32m$SECONDS\033[0m Sekunden mit einer Größe von \033[0;33m${SIZE}B\033[0m." >> /root/logs/backup.log
elif [ "$SECONDS" -eq 60 ]
then
echo -e "Das Backup in \033[0;31m/hdd2/backup\033[0m vom \033[0;36m$DATE\033[0m um \033[0;35m$TIME\033[0m dauerte \033[0;32meine\033[0m Minute mit einer Größe von \033[0;33m${SIZE}B\033[0m." >> /root/logs/backup.log
else
echo -e "Das Backup in \033[0;31m/hdd2/backup\033[0m vom \033[0;36m$DATE\033[0m um \033[0;35m$TIME\033[0m dauerte \033[0;32m$(($SECONDS / 60))\033[0m Minuten mit einer Größe von \033[0;33m${SIZE}B\033[0m." >> /root/logs/backup.log
fi
