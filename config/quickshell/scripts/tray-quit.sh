#!/usr/bin/env bash
# tray-quit.sh <tray-id> <tray-title> [term|force]
# Fully closes the app that owns a system-tray icon (used by the bar's flyout).
# It asks the StatusNotifierWatcher (Quickshell) which D-Bus connection registered
# the tray item with this Id, gets that connection's PID and signals it:
#   term  -> SIGTERM (polite quit), then SIGKILL if it is still running after 5 s
#   force -> SIGKILL right away
id=$1 title=$2 mode=${3:-term}
pid=""

items=$(busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher \
            org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems 2>/dev/null \
        | grep -o '"[^"]*"' | tr -d '"')
for entry in $items; do
    svc=${entry%%/*}                                   # ":1.89" or "org.kde.StatusNotifierItem-1234-1"
    if [[ $entry == */* ]]; then path=/${entry#*/}; else path=/StatusNotifierItem; fi
    iid=$(busctl --user get-property "$svc" "$path" org.kde.StatusNotifierItem Id 2>/dev/null \
          | sed -n 's/^s "\(.*\)"$/\1/p')
    if [[ -n $iid && $iid == "$id" ]]; then
        pid=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus \
                  GetConnectionUnixProcessID s "$svc" 2>/dev/null | awk '{print $2}')
        break
    fi
done
# fallback: a process with the same name as the tray id
[[ -z $pid && -n $id ]] && pid=$(pgrep -xi -- "$id" | head -1)

name=${title:-$id}
if [[ -z $pid ]]; then
    notify-send -a "Tray" "Couldn't find the process for $name" 2>/dev/null
    exit 1
fi
# never touch the shell itself
[[ $pid == "$PPID" || $(ps -o comm= -p "$pid") == quickshell ]] && exit 1

if [[ $mode == force ]]; then
    kill -KILL "$pid"
else
    kill -TERM "$pid"
    for _ in $(seq 10); do sleep 0.5; kill -0 "$pid" 2>/dev/null || exit 0; done
    kill -KILL "$pid"
fi
