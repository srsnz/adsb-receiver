#!/usr/bin/env bash
set -u
echo '=== ADS-B receiver diagnostics ==='
date
printf '\nTime synchronisation:\n'; timedatectl status 2>/dev/null || true
printf '\nDNS:\n'; getent ahostsv4 opensky-network.org | head -2 || true
printf '\nSDR USB:\n'; lsusb 2>/dev/null | grep -Ei 'RTL2832|Realtek|RTL-SDR' || echo 'No RTL-SDR USB device found (or lsusb unavailable)'
printf '\nDecoder TCP Beast port 30005:\n'; if command -v nc >/dev/null && nc -z -w 2 127.0.0.1 30005; then echo 'Listening'; else echo 'Not listening'; fi
printf '\nServices (active / enabled):\n'
for s in readsb dump1090-fa dump1090-mutability fr24feed adsbexchange-feed adsbexchange-mlat adsbexchange-stats opensky-feeder; do
  if systemctl list-unit-files "${s}.service" --no-legend 2>/dev/null | grep -q "^${s}.service"; then
    printf '%-25s active=%-12s enabled=%s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || true)" "$(systemctl is-enabled "$s" 2>/dev/null || true)"
  fi
done
printf '\nThis checks local processes and connectivity only; confirm accepted aircraft uploads on provider dashboards.\n'

printf '\nFR24 status:\n'; if command -v fr24feed-status >/dev/null; then fr24feed-status 2>&1 || true; else echo 'Not installed'; fi
printf '\nFR24 Beast configuration (without sharing key):\n'; if [[ -r /etc/fr24feed.ini ]]; then grep -E '^(receiver|host|bs|raw|mlat)=' /etc/fr24feed.ini || true; else echo 'Use sudo to inspect /etc/fr24feed.ini'; fi
printf '\nRecent ADSBx connection events:\n'; journalctl -u adsbexchange-feed --since '30 minutes ago' --no-pager 2>/dev/null | grep -E 'Connection established|Connection refused|Name resolution|disconnected' | tail -8 || true
printf '\nOpenSky recent connectivity:\n'; journalctl -u opensky-feeder --since '30 minutes ago' --no-pager 2>/dev/null | grep -Ei 'connected to|currently online|disconnection' | tail -8 || true
printf '\nLocal tar1090 HTTP (if installed):\n'; curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 3 http://127.0.0.1/tar1090/ 2>/dev/null || echo 'Unavailable'
