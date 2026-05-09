#!/bin/bash
set -e

echo "=== SRS ADS-B Receiver Installer ==="

# ── Config check ──────────────────────────────────────────────
if [ ! -f config/site.conf ]; then
    echo "ERROR: Missing config/site.conf"
    echo "  cp config/site.conf.example config/site.conf"
    echo "  nano config/site.conf"
    exit 1
fi

source config/site.conf

# Validate required vars
for VAR in SITE_NAME LAT LON ALT_M; do
    if [ -z "${!VAR}" ]; then
        echo "ERROR: $VAR not set in config/site.conf"
        exit 1
    fi
done

echo "Site:     $SITE_NAME"
echo "Location: $LAT, $LON  Alt: ${ALT_M}m"

# ── System update ─────────────────────────────────────────────
echo "Updating system..."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y git curl wget rtl-sdr

# ── Blacklist DVB driver ──────────────────────────────────────
echo "Blacklisting RTL-SDR DVB driver..."
echo "blacklist dvb_usb_rtl28xxu" | sudo tee /etc/modprobe.d/rtl-sdr-blacklist.conf > /dev/null

# ── Install readsb (wiedehopf) ────────────────────────────────
echo "Installing readsb..."
sudo bash -c "$(wget -q -O - https://raw.githubusercontent.com/wiedehopf/adsb-scripts/master/readsb-install.sh)"

# Configure readsb — NOTE: no --net-only, we need it to talk to the SDR
sudo tee /etc/default/readsb > /dev/null <<EOF
RECEIVER_OPTIONS="--device-type rtlsdr --device 0 --gain ${RECEIVER_GAIN:-40}"
DECODER_OPTIONS="--lat ${LAT} --lon ${LON} --max-range 360 --fix"
NET_OPTIONS="--net --net-ro-port 30002 --net-sbs-port 30003 --net-bi-port 30004 --net-bo-port 30005 --net-ri-port 30001"
JSON_OPTIONS="--json-location-accuracy 2"
READSB_RTLSDR_DEVICE="${RTLSDR_SERIAL:-}"
EOF

sudo systemctl enable readsb
sudo systemctl restart readsb
sleep 3

# Quick sanity check
if ! systemctl is-active --quiet readsb; then
    echo "WARNING: readsb failed to start — check: sudo journalctl -u readsb -n 50"
fi

# ── Install FR24 feeder ───────────────────────────────────────
echo "Installing FR24 feeder..."
sudo bash -c "$(wget -O - https://repo-feed.flightradar24.com/install_fr24_rpi.sh)"

echo "Configuring FR24..."
sudo tee /etc/fr24feed.ini > /dev/null <<EOF
receiver="beast-tcp"
host="127.0.0.1:30005"
fr24key="${FR24_KEY:-}"
bs="no"
raw="no"
mlat="yes"
mlat-without-gps="yes"
lat=${LAT}
lon=${LON}
alt=${ALT_M}
EOF

sudo systemctl enable fr24feed
sudo systemctl restart fr24feed

# ── Install ADS-B Exchange feeder ────────────────────────────
echo "Installing ADS-B Exchange feeder..."

# Generate a UUID if not in config
if [ -z "$ADSBX_UUID" ]; then
    ADSBX_UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "Generated ADSBX_UUID=$ADSBX_UUID — save this to config/site.conf!"
fi

# Pass required vars so the install is non-interactive
export FEEDER_LAT="$LAT"
export FEEDER_LON="$LON"
export FEEDER_ALT_M="$ALT_M"
export FEEDER_NAME="$SITE_NAME"
export UUID="$ADSBX_UUID"

curl -L -o /tmp/axfeed.sh https://www.adsbexchange.com/feed.sh
sudo -E bash /tmp/axfeed.sh

sudo systemctl enable adsbexchange-feed 2>/dev/null || true
sudo systemctl restart adsbexchange-feed 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────
echo ""
echo "=== Install complete ==="
echo ""
echo "VRS Beast connection:"
echo "  Host:   $(hostname -I | awk '{print $1}')"
echo "  Port:   30005"
echo "  Format: Beast"
echo ""
echo "Service status:"
systemctl is-active readsb    && echo "  ✓ readsb" || echo "  ✗ readsb — check logs"
systemctl is-active fr24feed  && echo "  ✓ fr24feed" || echo "  ✗ fr24feed — check logs"
systemctl is-active adsbexchange-feed 2>/dev/null && echo "  ✓ adsbexchange" || echo "  ? adsbexchange"
echo ""
echo "Logs: sudo journalctl -u readsb -f"
