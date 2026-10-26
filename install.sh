#!/usr/bin/env bash
# Fresh Raspberry Pi OS Lite -> readsb -> FR24 / ADSBx / OpenSky.
set -Eeuo pipefail
trap 'echo "Installation failed at line $LINENO. Fix the error and rerun; existing services will not be removed." >&2' ERR
say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
ask(){ local reply; read -r -p "$1 [y/N] " reply; [[ "${reply,,}" == y || "${reply,,}" == yes ]]; }
fetch_script(){ local url="$1" dest="$2"; curl -fL --retry 3 "$url" -o "$dest"; chmod 600 "$dest"; echo "Downloaded $url -> $dest"; }
run_reviewed(){ local url="$1" dest="$2"; fetch_script "$url" "$dest"; echo "Review with: less $dest"; if ask 'Run downloaded upstream script with sudo?'; then sudo bash "$dest"; else echo 'Skipped.'; fi; }
[[ $EUID != 0 ]] || fail 'Run as a normal sudo-capable user, not root.'
[[ -f /etc/os-release ]] || fail 'Cannot identify operating system.'
. /etc/os-release
[[ ${ID:-} == raspbian || ${ID:-} == debian || ${ID_LIKE:-} == *debian* ]] || fail 'Debian/Raspberry Pi OS required.'
command -v sudo >/dev/null || fail 'sudo is required.'
[[ $(uname -m) == aarch64 || $(uname -m) == armv7l || $(uname -m) == armv6l ]] || fail 'This fresh-install path is for Raspberry Pi ARM hardware.'
ARCH=$(dpkg --print-architecture)
[[ $ARCH == arm64 || $ARCH == armhf ]] || fail "Unsupported package architecture: $ARCH"
[[ ! -e /boot/piaware-config.txt ]] || fail 'PiAware image detected. Use the existing-decoder procedure instead.'
if systemctl list-unit-files --no-legend 2>/dev/null | grep -Eq '^(readsb|dump1090-fa|dump1090-mutability|fr24feed|adsbexchange-feed|opensky-feeder)\.service'; then
  fail 'Existing ADS-B services detected. This is a FRESH-install script and will not overwrite them.'
fi
say 'Fresh ADS-B receiver installation'
echo "OS: ${PRETTY_NAME:-unknown} / $ARCH"
echo 'Requires: working Internet, RTL-SDR 1090 MHz dongle, antenna, and accurate site coordinates/elevation.'
echo 'Upstream third-party scripts and packages are downloaded during installation. Review before approving.'
echo 'No network/DNS settings, SDR EEPROM or system passwords will be changed.'
ask 'Continue?' || exit 0
say 'OS prerequisites'
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl wget git gnupg netcat-openbsd usbutils rtl-sdr
sudo timedatectl set-ntp true || true
getent ahostsv4 github.com >/dev/null || fail 'DNS is broken; check router DHCP/DNS.'
if ! timedatectl show -p NTPSynchronized --value | grep -qx yes; then
  echo 'WARNING: Clock is not yet NTP synchronized. Confirm correct date/time before continuing.'
  date
  ask 'Clock is correct / proceed anyway?' || exit 1
fi
lsusb | grep -Ei 'RTL2832|Realtek|RTL-SDR' || echo 'WARNING: RTL-SDR not detected in lsusb. Plug in the dongle before starting readsb.'
say 'Install readsb decoder'
echo 'Using the readsb project maintainer installation script (installs/builds readsb and optionally tar1090).'
run_reviewed 'https://raw.githubusercontent.com/wiedehopf/adsb-scripts/master/readsb-install.sh' '/tmp/srs-readsb-install.sh'
command -v readsb >/dev/null || fail 'readsb was not installed; cannot proceed.'
read -r -p 'Antenna latitude (decimal degrees, e.g. -44.8115): ' LAT
read -r -p 'Antenna longitude (decimal degrees, e.g. 168.445): ' LON
read -r -p 'Antenna altitude ABOVE SEA LEVEL in metres (e.g. 1481): ' ALT
[[ $LAT =~ ^-?[0-9]+(\.[0-9]+)?$ && $LON =~ ^-?[0-9]+(\.[0-9]+)?$ && $ALT =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || fail 'Coordinates/elevation must be numbers.'
awk -v a="$LAT" -v b="$LON" 'BEGIN {exit !(a>=-90 && a<=90 && b>=-180 && b<=180)}' || fail 'Latitude or longitude out of range.'
if command -v readsb-set-location >/dev/null; then
  sudo readsb-set-location "$LAT" "$LON"
else
  echo 'WARNING: readsb-set-location missing. Configure --lat and --lon in /etc/default/readsb manually.'
fi
sudo systemctl enable --now readsb
sleep 3
if ! nc -z -w 3 127.0.0.1 30005; then
  sudo systemctl status readsb --no-pager || true
  fail 'No Beast TCP output on 127.0.0.1:30005. Fix readsb/SDR before installing feeders.'
fi
say 'Install feeder clients (one decoder; all use Beast TCP 127.0.0.1:30005)'
echo 'FR24: select an external Beast TCP receiver (127.0.0.1:30005). DO NOT select a local USB decoder.'
if ask 'Install FR24?'; then
  run_reviewed 'https://fr24.com/install.sh' '/tmp/srs-fr24-install.sh'
fi
if ask 'Install ADS-B Exchange feed + MLAT?'; then
  run_reviewed 'https://www.adsbexchange.com/feed.sh' '/tmp/srs-adsbx-feed.sh'
fi
if ask 'Install ADS-B Exchange stats (recommended for account linking)?'; then
  run_reviewed 'https://www.adsbexchange.com/stats.sh' '/tmp/srs-adsbx-stats.sh'
fi
if ask 'Install OpenSky feeder?'; then
  DEB="/tmp/opensky-feeder_latest_${ARCH}.deb"
  curl -fL --retry 3 "https://opensky-network.org/files/firmware/opensky-feeder_latest_${ARCH}.deb" -o "$DEB"
  echo 'OpenSky prompts: decoder=default, input port=30005, enter location/altitude and account.'
  if ask "Install OpenSky package $DEB?"; then sudo apt-get install -y "$DEB"; fi
fi
say 'Final checks'
for s in readsb fr24feed adsbexchange-feed adsbexchange-mlat adsbexchange-stats opensky-feeder; do
  printf '%-24s ' "$s"
  systemctl is-active "$s" 2>/dev/null || true
done
if [[ -x ./diagnose.sh ]]; then ./diagnose.sh; fi
echo 'Done. Check each provider dashboard for actual data reception. A connected TCP socket alone is not proof of accepted data.'
echo 'No reboot was forced. If readsb has SDR permission errors, check its logs and reboot when convenient.'
