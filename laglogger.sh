#!/bin/bash

OUT="$HOME/logs/memlog.csv"

echo "$(date +%s),\
$(free -h),\
$(awk '/MemAvailable/{print $2}' /proc/meminfo),\
$(awk '/MemFree/{print $2}' /proc/meminfo),\
$(cat /proc/pressure/memory | tr '\n' ' '),\
$(cat /proc/pressure/io | tr '\n' ' '),\
$(cat /proc/meminfo | grep -E 'MemAvailable|Cached|SReclaimable'),\
$(ps -eo pid,comm,rss,%mem --sort=-rss | head -30)" \
>> "$OUT"
