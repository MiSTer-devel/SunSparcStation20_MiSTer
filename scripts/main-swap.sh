#!/usr/bin/env bash
# main-swap.sh FILE|stock - put a Main binary on the MiSTer and reboot it.
# The stock binary (md5 d6d63ec4) is kept as /media/fat/MiSTer.stock. A Main
# is changed by renaming files, sync and reboot (a hand relaunch once left
# HDMI black: the Mac project's notes). Waits until the MiSTer answers again.
set -u
. "$(dirname "$0")/common.sh"
R="ssh ${SSH_OPTS[*]} $DEV"
$R "test -f /media/fat/MiSTer.stock || cp -p /media/fat/MiSTer /media/fat/MiSTer.stock" || exit 1
if [ "$1" = stock ]; then
    $R "cp -p /media/fat/MiSTer.stock /media/fat/MiSTer.new && mv /media/fat/MiSTer.new /media/fat/MiSTer"
else
    scp -q "${SSH_OPTS[@]}" "$1" "$DEV:/media/fat/MiSTer.new" || exit 1
    $R "chmod +x /media/fat/MiSTer.new && mv /media/fat/MiSTer.new /media/fat/MiSTer"
fi
echo "Main on the MiSTer: $($R md5sum /media/fat/MiSTer | cut -c1-8)"
$R "sync; reboot" > /dev/null 2>&1
sleep 20
for i in $(seq 1 60); do $R true 2> /dev/null && break; sleep 3; done
sleep 15   # Main up, the menu core loaded
$R "ls /dev/MiSTer_cmd" > /dev/null && echo "MiSTer back up"
