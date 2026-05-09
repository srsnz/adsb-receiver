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

# ── Install rtl-sdr tools early for detection ─────────────────
echo "Installing rtl-sdr tools..."
sudo apt-get install -y rtl-sdr git curl wget

# ── Blacklist DVB driver ──────────────────────────────────────
echo "Blacklisting RTL-SDR DVB driver..."
echo "blacklist dvb_usb_rtl28xxu" | sudo tee /etc/modprobe.d/rtl-sdr-blacklist.conf > /dev/null
sudo modprobe -r dvb_usb_rtl28xxu 2>/dev/null || true
sudo modprobe -r rtl2832 2>/dev/null || true
sleep 1

# ── Detect RTL-SDR ────────────────────────────────────────────
echo "Detecting RTL-SDR dongle..."

RTLSDR_LSUSB=$(lsusb | grep -iE "0bda:2832|0bda:2838|0bda:2888|1d50:60a4")

if [ -z "$RTLSDR_LSUSB" ]; then
    echo ""
    echo "ERROR: No RTL-SDR dongle detected on USB."
    echo "  - Check the dongle is plugged into one of the HAT's USB ports"
    echo "  - Run 'lsusb' to see what is connected"
    echo "  - If 'dvb_usb_rtl28xxu' appears in 'lsmod', try rebooting and re-running"
    exit 1
fi

echo "Found: $RTLSDR_LSUSB"

# ── Read or set RTL-SDR serial ────────────────────────────────
NEEDS_REBOOT=0

# Dump full rtl_eeprom output (read-only, no prompts on plain call)
EEPROM_OUT=$(rtl_eeprom 2>&1 || true)

# Parse serial using awk — no PCRE needed
DETECTED_SERIAL=$(echo "$EEPROM_OUT" | grep -i "Serial number:" | awk -F': ' '{print $2}' | tr -d '[:space:]')

# Treat blank, 0, all-zeros, or the common RTL-SDR Blog default as non-unique
SERIAL_IS_UNIQUE=0
if [ -n "$DETECTED_SERIAL" ] \
    && [ "$DETECTED_SERIAL" != "0" ] \
    && [ "$DETECTED_SERIAL" != "00000000" ] \
    && [ "$DETECTED_SERIAL" != "00000001" ]; then
    SERIAL_IS_UNIQUE=1
fi

if [ "$SERIAL_IS_UNIQUE" = "1" ]; then
    echo "Detected serial: $DETECTED_SERIAL"

    if [ "${RTLSDR_SERIAL:-}" != "$DETECTED_SERIAL" ]; then
        echo "Updating RTLSDR_SERIAL in config/site.conf..."
        if grep -q "^RTLSDR_SERIAL=" config/site.conf; then
            sed -i "s/^RTLSDR_SERIAL=.*/RTLSDR_SERIAL=${DETECTED_SERIAL}/" config/site.conf
        else
            echo "RTLSDR_SERIAL=${DETECTED_SERIAL}" >> config/site.conf
        fi
        RTLSDR_SERIAL="$DETECTED_SERIAL"
    fi

else
    echo "No unique serial found on dongle (got: '${DETECTED_SERIAL:-none}')"
    echo "Writing a unique serial to dongle EEPROM..."

    NEW_SERIAL="ADSB$(shuf -i 1000-9999 -n 1)"

    # printf '\n' sends a bare newline to answer the "Press Enter to write" prompt
    WRITE_OUT=$(printf '\n' | rtl_eeprom -s "$NEW_SERIAL" 2>&1 || true)
    echo "$WRITE_OUT"

    if echo "$WRITE_OUT" | grep -qi "write\|written\|ok\|done"; then
        echo "Serial '$NEW_SERIAL' written to EEPROM."

        if grep -q "^RTLSDR_SERIAL=" config/site.conf; then
            sed -i "s/^RTLSDR_SERIAL=.*/RTLSDR_SERIAL=${NEW_SERIAL}/" config/site.conf
        else
            echo "RTLSDR_SERIAL=${NEW_SERIAL}" >> config/site.conf
        fi
        RTLSDR_SERIAL="$NEW_SERIAL"

        # Rebind USB device to apply new serial without physical replug
        echo "Rebinding USB device to apply new serial..."

        USB_SYSFS=$(for d in /sys/bus/usb/devices/*/; do
            vid=$(cat "$d/idVendor" 2>/dev/null)
            pid=$(cat "$d/idProduct" 2>/dev/null)
            case "$vid:$pid" in
                0bda:2832|0bda:2838|0bda:2888|1d50:60a4)
                    echo "$d"
                    break
                    ;;
            esac
        done)

        if [ -n "$USB_SYSFS" ]; then
            USB_DEV=$(basename "$USB_SYSFS")
            echo "  Found at sysfs: $USB_DEV"
            echo "$USB_DEV" | sudo tee /sys/bus/usb/drivers/usb/unbind > /dev/null
            sleep 1
            echo "$USB_DEV" | sudo tee /sys/bus/usb/drivers/usb/bind > /dev/null
            sleep 2
            echo "  USB device rebound successfully."
        else
            echo "  WARNING: Could not find device in sysfs — will reboot to apply serial."
            NEEDS_REBOOT=1
        fi

    else
        echo "WARNING: Could not write serial to EEPROM. Falling back to --device 0."
        echo "  rtl_eeprom output was: $WRITE_OUT"
        RTLSDR_SERIAL=""
    fi
fi

echo "RTL-SDR ready. Using: ${RTLSDR_SERIAL:-'(index 0 fallback)'}"

# ── Build readsb device arg ───────────────────────────────────
if [ -n "${RTLSDR_SERIAL:-}" ]; then
    DEVICE_ARG="--device ${RTLSDR_SERIAL}"
else
    DEVICE_ARG="--device 0"
fi

# ── Install readsb ────────────────────────────────────────────
echo "Installing readsb..."
sudo bash -c "$(wget -q -O - https://raw.githubusercontent.com/wiedehopf/adsb-scripts/master/readsb-install.sh)"

echo "Configuring readsb..."
sudo mkdir -p /etc/default
sudo tee /etc/default/readsb > /dev/null <<EOF
RECEIVER_OPTIONS="--device-type rtlsdr ${DEVICE_ARG} --gain ${RECEIVER_GAIN:-40}"
DECODER_OPTIONS="--lat ${LAT} --lon ${LON} --max-range 360 --fix"
NET_OPTIONS="--net --net-ro-port 30002 --net-sbs-port 30003 --net-bi-port 30004 --net-bo-port 30005 --net-ri-port 30001"
JSON_OPTIONS="--json-location-accuracy 2"
EOF

sudo systemctl enable readsb
sudo systemctl restart readsb
sleep 3

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

if [ -z "${ADSBX_UUID:-}" ]; then
    ADSBX_UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "Generated ADSBX_UUID=$ADSBX_UUID"
    echo "Saving to config/site.conf..."
    if grep -q "^ADSBX_UUID=" config/site.conf; then
        sed -i "s/^ADSBX_UUID=.*/ADSBX_UUID=${ADSBX_UUID}/" config/site.conf
    else
        echo "ADSBX_UUID=${ADSBX_UUID}" >> config/site.conf
    fi
fi

export FEEDER_LAT="$LAT"
export FEEDER_LON="$LON"
export FEEDER_ALT_M="$ALT_M"
export FEEDER_NAME="$SITE_NAME"
export UUID="$ADSBX_UUID"

curl -L -o /tmp/axfeed.sh https://www.adsbexchange.com/feed.sh
sudo -E bash /tmp/axfeed.sh

sudo systemctl enable adsbexchange-feed 2>/dev/null || true
sudo systemctl restart adsbexchange-feed 2>/dev/null || true

# ── Service status ────────────────────────────────────────────
echo ""
echo "=== Service Status ==="
systemctl is-active --quiet readsb          && echo "  ✓ readsb"       || echo "  ✗ readsb       — sudo journalctl -u readsb -n 50"
systemctl is-active --quiet fr24feed        && echo "  ✓ fr24feed"     || echo "  ✗ fr24feed     — sudo journalctl -u fr24feed -n 50"
systemctl is-active --quiet adsbexchange-feed 2>/dev/null \
                                            && echo "  ✓ adsbexchange" || echo "  ? adsbexchange — sudo journalctl -u adsbexchange-feed -n 50"
echo ""
echo "VRS Beast connection:"
echo "  Host:   $(hostname -I | awk '{print $1}')"
echo "  Port:   30005"
echo "  Format: Beast"

# ── Reboot if required ────────────────────────────────────────
if [ "${NEEDS_REBOOT}" = "1" ]; then
    echo ""
    echo "A reboot is required to apply USB serial changes."
    echo "Rebooting in 10 seconds... (Ctrl+C to cancel)"
    sleep 10
    sudo reboot
else
    echo ""
    echo "=== Install complete — no reboot required ==="
fi
