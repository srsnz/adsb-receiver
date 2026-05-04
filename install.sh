#!/bin/bash
set -e

echo "=== SRS ADS-B Receiver Installer ==="

if [ ! -f config/site.conf ]; then
  echo "Missing config/site.conf"
  echo "Run:"
  echo "cp config/site.conf.example config/site.conf"
  echo "nano config/site.conf"
  exit 1
fi

source config/site.conf

echo "Site: $SITE_NAME"
echo "Location: $LAT, $LON"
echo "Altitude: $ALT_M m"

echo "Updating system..."
sudo apt update
sudo apt upgrade -y

echo "Installing base packages..."
sudo apt install -y git curl wget rtl-sdr lighttpd net-tools

echo "Blacklisting default RTL-SDR DVB driver..."
echo "blacklist dvb_usb_rtl28xxu" | sudo tee /etc/modprobe.d/rtl-sdr-blacklist.conf >/dev/null

echo "Installing readsb..."
sudo bash -c "$(wget -q -O - https://raw.githubusercontent.com/wiedehopf/adsb-scripts/master/readsb-install.sh)"

echo "Configuring readsb..."
sudo mkdir -p /etc/default

sudo tee /etc/default/readsb > /dev/null <<EOF
RECEIVER_OPTIONS="--device-type rtlsdr --gain ${RECEIVER_GAIN}"
DECODER_OPTIONS="--lat ${LAT} --lon ${LON} --max-range 360"
NET_OPTIONS="--net --net-only --net-ro-port 30002 --net-sbs-port 30003 --net-bi-port 30004 --net-bo-port 30005 --net-ri-port 30001"
JSON_OPTIONS="--json-location-accuracy 2"
EOF

sudo systemctl restart readsb

echo "Installing FR24 feeder..."
sudo bash -c "$(wget -O - https://repo-feed.flightradar24.com/install_fr24_rpi.sh)"

echo "Configuring FR24 to use readsb Beast output..."
sudo tee /etc/fr24feed.ini > /dev/null <<EOF
receiver="beast-tcp"
host="127.0.0.1:30005"
bs="no"
raw="no"
mlat="yes"
mlat-without-gps="yes"
EOF

if [ -n "$FR24_KEY" ]; then
  echo 'fr24key="'$FR24_KEY'"' | sudo tee -a /etc/fr24feed.ini >/dev/null
fi

sudo systemctl restart fr24feed

echo "Installing ADS-B Exchange feeder..."
curl -L -o /tmp/axfeed.sh https://adsbexchange.com/feed.sh
sudo bash /tmp/axfeed.sh

echo "Restarting services..."
sudo systemctl restart readsb || true
sudo systemctl restart fr24feed || true
sudo systemctl restart adsbexchange-feed || true

echo ""
echo "=== Install complete ==="
echo "readsb Beast output for VRS:"
echo "  Host: $(hostname -I | awk '{print $1}')"
echo "  Port: 30005"
echo "  Format: Beast"
echo ""
echo "Check services:"
echo "  systemctl status readsb"
echo "  systemctl status fr24feed"
echo "  systemctl status adsbexchange-feed"
