#!/bin/sh
# Runs all tests against the mock Jellyfin server, as Jellyfin 10.9+ ("modern")
# and as Jellyfin 10.8 ("legacy").
# Needs: luajit, lua-socket, lua-sec, lua-cjson, python3.
set -e
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'kill $pid 2>/dev/null; rm -rf "$work"' EXIT
port=18096
for mode in modern legacy; do
    python3 mock.py $port $mode 2>/dev/null &
    pid=$!
    sleep 1
    echo "== $mode server"
    rm -rf "$work/client" "$work/ui"; mkdir -p "$work/client" "$work/ui"
    luajit test_client.lua $port "$work/client"
    luajit test_all.lua $port "$work/ui" $mode
    kill $pid; wait $pid 2>/dev/null || true
    port=$((port + 1))
done
