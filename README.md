# TobiScan

Schlankes Scanprogramm für den Fujitsu/Ricoh ScanSnap iX500 unter macOS, als Ersatz für ScanSnap Home.

- Scannt über **WLAN** (eigene Umsetzung des ScanSnap-Protokolls, keine Herstellersoftware nötig) oder über **USB** (per SANE).
- Stapelscan, ein- oder beidseitig, 150 bis 600 dpi, Farbe, Graustufen oder Schwarzweiß.
- Leere Seiten entfernen, Schräglage korrigieren, Hintergrund aufhellen.
- Speichert durchsuchbare PDFs und schlägt den Dateinamen aus dem Inhalt vor (`JJJJ-MM-TT_Absender-Inhalt`), mit dem Sprachmodell von macOS direkt auf dem Rechner.
- Die Scan-Taste am Gerät startet den Scan, solange TobiScan läuft.

## Installieren

```sh
./install.sh
```

Das baut die App und kopiert sie nach `/Applications`. Voraussetzung sind die Xcode Command Line Tools (`xcode-select --install`). Nach Änderungen am Quelltext einfach erneut ausführen.

Nur für USB zusätzlich: `brew install sane-backends`.

## Hinweise

- Beim ersten Start fragt macOS nach dem Zugriff auf das lokale Netzwerk; ohne ihn findet TobiScan den Scanner im WLAN nicht.
- Solange TobiScan mit eingeschalteter Option „Scan-Taste am Gerät“ läuft, ist der Scanner für ScanSnap Home und die Handy-App belegt.
- Als WLAN-Passwort des Scanners werden die letzten vier Zeichen der Seriennummer verwendet (Werkseinstellung).
- WLAN-Scans werden in `~/Library/Logs/TobiScan.log` protokolliert.
- `TobiScan.app/Contents/MacOS/TobiScan --selfcheck` prüft Import und PDF-Export ohne Scanner (braucht SANE), `--wifi-probe` sucht den Scanner im WLAN und fragt seinen Status ab.
- Gebaut wird direkt mit `swiftc` (`build.sh`); das App-Icon erzeugt `swift Tools/make-icon.swift`.

Getestet mit einem iX500 unter macOS 27 auf Apple Silicon. 600 dpi und das Papierformat „Automatisch“ sind über WLAN noch ungetestet.
