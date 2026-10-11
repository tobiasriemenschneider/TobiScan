#!/bin/sh
# Baut TobiScan und installiert es nach /Applications.
set -e
cd "$(dirname "$0")"

if pgrep -xq TobiScan; then
    echo "TobiScan läuft noch. Bitte erst beenden und dann erneut ausführen." >&2
    exit 1
fi
./build.sh
rm -rf /Applications/TobiScan.app
cp -R TobiScan.app /Applications/TobiScan.app
echo "Installiert: /Applications/TobiScan.app"
