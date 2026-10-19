#!/usr/bin/env bash
# screenshot.sh [OUT.png] [HOST] - take a screenshot of the MiSTer's screen
# through its remote API (port 8182: POST /api/screenshots takes one, GET
# lists them) and save the newest one of the running core to OUT.png
# (default sim/out/screen-<time>.png). No OBS needed.
set -euo pipefail
OUT="${1:-sim/out/screen-$(date +%H%M%S).png}"
HOST="${2:-10.0.2.192}"
before=$(curl -s -m 10 "http://$HOST:8182/api/screenshots" | python3 -c 'import json,sys; print(max((x["modified"] for x in json.load(sys.stdin)), default=""))')
curl -s -m 30 -X POST "http://$HOST:8182/api/screenshots" > /dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    path=$(curl -s -m 10 "http://$HOST:8182/api/screenshots" | python3 -c '
import json,sys
l=json.load(sys.stdin); b=sys.argv[1]
n=[x for x in l if x["modified"]>b]
print(max(n,key=lambda x:x["modified"])["path"] if n else "")' "$before")
    if [ -n "$path" ]; then
        mkdir -p "$(dirname "$OUT")"
        curl -s -m 30 -o "$OUT" "http://$HOST:8182/api/screenshots/$path"
        echo "$OUT ($path)"; exit 0
    fi
done
echo "no new screenshot" >&2; exit 1
