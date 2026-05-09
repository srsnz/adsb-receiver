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
for VAR in SITE_NAME LAT LON ALT_M FR24_KEY; do
    if [ -z "${!VAR}" ]; then
        echo "ERROR: $VAR not set in config/site.conf"
        exit 1
    fi
done

# ALT in feet is required by ADSB Exchange
ALT_FT=$(awk "BEGIN {printf \"%d\", ${ALT_M} * 3.28084}")

echo "Site:     $SITE_NAME"
echo "Location: $LAT, $LON  Alt: ${ALT_M}m / ${ALT_FT}ft"

# ── System update ─────────────────────────────────────────────
echo "Updating system..."
sudo apt-get update -y
sudo apt-get upgrade -y

# ── Install base packages ─────────────────────────────────────
echo "Installing base packages..."
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

EEPROM_OUT=$(rtl_eeprom 2>&1 || true)
DETECTED_SERIAL=$(echo "$EEPROM_OUT" | grep -i "Serial number:" | awk -F': ' '{print $2}' | tr -d '[:space:]')

echo "Current dongle serial: '${DETECTED_SERIAL:-none}'"

# Treat blank, 0, all-zeros, or the RTL-SDR Blog V4 default as non-unique
SERIAL_IS_UNIQUE=0
if [ -n "$DETECTED_SERIAL" ] \
    && [ "$DETECTED_SERIAL" != "0" ] \
    && [ "$DETECTED_SERIAL" != "00000000" ] \
    && [ "$DETECTED_SERIAL" != "00000001" ]; then
    SERIAL_IS_UNIQUE=1
fi

if [ "$SERIAL_IS_UNIQUE" = "1" ]; then
    echo "Serial is unique, using: $DETECTED_SERIAL"
    if [ "${RTLSDR_SERIAL:-}" != "$DETECTED_SERIAL" ]; then
        echo "Saving RTLSDR_SERIAL to config/site.conf..."
        if grep -q "^RTLSDR_SERIAL=" config/site.conf; then
            sed -i "s/^RTLSDR_SERIAL=.*/RTLSDR_SERIAL=${DETECTED_SERIAL}/" config/site.conf
        else
            echo "RTLSDR_SERIAL=${DETECTED_SERIAL}" >> config/site.conf
        fi
        RTLSDR_SERIAL="$DETECTED_SERIAL"
    fi
else
    echo "Serial is not unique — writing a new one to EEPROM..."
    NEW_SERIAL="ADSB$(shuf -i 1000-9999 -n 1)"
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

        # Rebind USB device so kernel re-reads the new serial from EEPROM
        echo "Rebinding USB device to apply new serial..."
        USB_SYSFS=$(for d in /sys/bus/usb/devices/*/; do
            vid=$(cat "$d/idVendor" 2>/dev/null)
            pid=$(cat "$d/idProduct" 2>/dev/null)
            case "$vid:$pid" in
                0bda:2832|0bda:2838|0bda:2888|1d50:60a4)
                    echo "$d"; break ;;
            esac
        done)

        if [ -n "$USB_SYSFS" ]; then
            USB_DEV=$(basename "$USB_SYSFS")
            echo "  Unbinding $USB_DEV..."
            echo "$USB_DEV" | sudo tee /sys/bus/usb/drivers/usb/unbind > /dev/null
            sleep 2
            echo "  Rebinding $USB_DEV..."
            echo "$USB_DEV" | sudo tee /sys/bus/usb/drivers/usb/bind > /dev/null
            sleep 3

            # Verify the rebind worked by re-reading the serial
            VERIFY_SERIAL=$(rtl_eeprom 2>&1 | grep -i "Serial number:" | awk -F': ' '{print $2}' | tr -d '[:space:]')
            if [ "$VERIFY_SERIAL" = "$NEW_SERIAL" ]; then
                echo "  Confirmed: dongle now reports serial '$NEW_SERIAL'"
            else
                echo "  WARNING: Dongle still reports '$VERIFY_SERIAL' after rebind."
                echo "  A reboot is needed to apply the new serial."
                NEEDS_REBOOT=1
            fi
        else
            echo "  WARNING: Could not find device in sysfs — reboot required to apply serial."
            NEEDS_REBOOT=1
        fi
    else
        echo "WARNING: Could not write serial to EEPROM. Falling back to --device 0."
        RTLSDR_SERIAL=""
    fi
fi

# If reboot is needed, the serial in EEPROM is correct but the kernel hasn't
# seen it yet. Fall back to --device 0 for this install run — it will still
# work since there's only one dongle. After reboot the serial will be used.
if [ "${NEEDS_REBOOT}" = "1" ]; then
    echo "Note: Using --device 0 for this install. After reboot readsb will use serial ${RTLSDR_SERIAL}."
    DEVICE_ARG="--device 0"
else
    if [ -n "${RTLSDR_SERIAL:-}" ]; then
        DEVICE_ARG="--device ${RTLSDR_SERIAL}"
    else
        DEVICE_ARG="--device 0"
    fi
fi

echo "RTL-SDR device arg: $DEVICE_ARG"

# ── Install readsb ────────────────────────────────────────────
echo "Installing readsb..."
sudo bash -c "$(wget -q -O - https://raw.githubusercontent.com/wiedehopf/adsb-scripts/master/readsb-install.sh)"

# Write our config AFTER the install script finishes (it may write its own defaults)
echo "Configuring readsb..."
sudo tee /etc/default/readsb > /dev/null <<EOF
RECEIVER_OPTIONS="--device-type rtlsdr ${DEVICE_ARG} --gain ${RECEIVER_GAIN:-40}"
DECODER_OPTIONS="--lat ${LAT} --lon ${LON} --max-range 360 --fix"
NET_OPTIONS="--net --net-ro-port 30002 --net-sbs-port 30003 --net-bi-port 30004 --net-bo-port 30005 --net-ri-port 30001"
JSON_OPTIONS="--json-location-accuracy 2"
EOF

sudo systemctl enable readsb
sudo systemctl restart readsb
sleep 5

if ! systemctl is-active --quiet readsb; then
    echo "WARNING: readsb failed to start — check: sudo journalctl -u readsb -n 50"
else
    echo "  ✓ readsb running"
fi

# ── Install FR24 feeder (no wizard) ───────────────────────────
echo "Installing FR24 feeder..."

# Step 1: Add the FR24 apt repo key and source
# Use signed-by method (modern Debian/bookworm approach — avoids apt-key deprecation)
sudo mkdir -p /etc/apt/keyrings
wget -qO - https://repo-feed.flightradar24.com/flightradar24.pub \
    | sudo gpg --dearmor -o /etc/apt/keyrings/flightradar24.gpg 2>/dev/null || \
    wget -qO /etc/apt/keyrings/flightradar24.gpg https://repo-feed.flightradar24.com/flightradar24.pub

echo "deb [signed-by=/etc/apt/keyrings/flightradar24.gpg] http://repo.feed.flightradar24.com flightradar24 raspberrypi-stable" \
    | sudo tee /etc/apt/sources.list.d/fr24feed.list > /dev/null

sudo apt-get update -y

# Step 2: Write the config BEFORE installing the package.
# fr24feed's postinst script checks for an existing ini and skips the wizard if found.
echo "Writing FR24 config before package install to suppress wizard..."
sudo mkdir -p /etc/
sudo tee /etc/fr24feed.ini > /dev/null <<EOF
receiver="beast-tcp"
host="127.0.0.1:30005"
fr24key="${FR24_KEY}"
bs="no"
raw="no"
logmode="1"
windowmode="0"
mpx="no"
mlat="yes"
mlat-without-gps="yes"
EOF

# Step 3: Install the package — postinst will see the ini and skip the wizard
sudo apt-get install -y fr24feed

# Step 4: Ensure config is still correct (package install might have overwritten it)
sudo tee /etc/fr24feed.ini > /dev/null <<EOF
receiver="beast-tcp"
host="127.0.0.1:30005"
fr24key="${FR24_KEY}"
bs="no"
raw="no"
logmode="1"
windowmode="0"
mpx="no"
mlat="yes"
mlat-without-gps="yes"
EOF

sudo systemctl enable fr24feed
sudo systemctl restart fr24feed
sleep 3

if ! systemctl is-active --quiet fr24feed; then
    echo "WARNING: fr24feed failed to start — check: sudo journalctl -u fr24feed -n 50"
else
    echo "  ✓ fr24feed running"
fi

# ── Install ADS-B Exchange feeder (no wizard) ─────────────────
echo "Installing ADS-B Exchange feeder..."

# Generate UUID if not set
if [ -z "${ADSBX_UUID:-}" ]; then
    ADSBX_UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "Generated ADSBX_UUID=$ADSBX_UUID"
    if grep -q "^ADSBX_UUID=" config/site.conf; then
        sed -i "s/^ADSBX_UUID=.*/ADSBX_UUID=${ADSBX_UUID}/" config/site.conf
    else
        echo "ADSBX_UUID=${ADSBX_UUID}" >> config/site.conf
    fi
fi

# Write /etc/default/adsbexchange BEFORE running feed.sh so it skips configure.sh
# Format taken directly from the official ADSBexchange/feedclient configure.sh source
sudo tee /etc/default/adsbexchange > /dev/null <<EOF
INPUT="127.0.0.1:30005"
REDUCE_INTERVAL="0.5"
USER="${SITE_NAME}"
LATITUDE="${LAT}"
LONGITUDE="${LON}"
ALTITUDE="${ALT_FT}ft"
UAT_INPUT="127.0.0.1:30978"
RESULTS="--results beast,connect,127.0.0.1:30104"
RESULTS2="--results basestation,listen,31003"
RESULTS3="--results beast,listen,30157"
RESULTS4="--results beast,connect,127.0.0.1:30154"
PRIVACY=""
INPUT_TYPE="dump1090"
MLATSERVER="feed.adsbexchange.com:31090"
TARGET="--net-connector feed1.adsbexchange.com,30004,beast_reduce_out,feed2.adsbexchange.com,64004"
NET_OPTIONS="--net-heartbeat 60 --net-ro-size 1280 --net-ro-interval 0.2 --net-ro-port 0 --net-sbs-port 0 --net-bi-port 30154 --net-bo-port 0 --net-ri-port 0 --write-json-every 1"
JSON_OPTIONS="--max-range 450 --json-location-accuracy 2 --range-outline-hours 24"
EOF

# feed.sh checks for /etc/default/adsbexchange and skips configure.sh if it exists
curl -L -o /tmp/axfeed.sh https://adsbexchange.com/feed.sh
sudo bash /tmp/axfeed.sh

# Write UUID to where the feedclient stores it
sudo mkdir -p /usr/local/share/adsbexchange
echo "$ADSBX_UUID" | sudo tee /usr/local/share/adsbexchange/uuid > /dev/null

sudo systemctl enable adsbexchange-feed 2>/dev/null || true
sudo systemctl enable adsbexchange-mlat 2>/dev/null || true
sudo systemctl restart adsbexchange-feed 2>/dev/null || true
sudo systemctl restart adsbexchange-mlat 2>/dev/null || true
sleep 3

# ── Service status ────────────────────────────────────────────
echo ""
echo "=== Service Status ==="
systemctl is-active --quiet readsb              && echo "  ✓ readsb"            || echo "  ✗ readsb            — sudo journalctl -u readsb -n 50"
systemctl is-active --quiet fr24feed            && echo "  ✓ fr24feed"          || echo "  ✗ fr24feed          — sudo journalctl -u fr24feed -n 50"
systemctl is-active --quiet adsbexchange-feed   2>/dev/null \
                                                && echo "  ✓ adsbexchange-feed" || echo "  ✗ adsbexchange-feed — sudo journalctl -u adsbexchange-feed -n 50"
systemctl is-active --quiet adsbexchange-mlat   2>/dev/null \
                                                && echo "  ✓ adsbexchange-mlat" || echo "  ✗ adsbexchange-mlat — sudo journalctl -u adsbexchange-mlat -n 50"

echo ""
echo "VRS Beast connection:"
echo "  Host:   $(hostname -I | awk '{print $1}')"
echo "  Port:   30005"
echo "  Format: Beast"
echo ""
echo "Verify feeders:"
echo "  FR24:  http://$(hostname -I | awk '{print $1}'):8754"
echo "  ADSBX: https://www.adsbexchange.com/myip"

# ── Reboot if required ────────────────────────────────────────
if [ "${NEEDS_REBOOT}" = "1" ]; then
    echo ""
    echo "A reboot is required to apply the RTL-SDR serial change."
    echo "After reboot, readsb will use serial '${RTLSDR_SERIAL}' instead of --device 0."
    echo "Rebooting in 10 seconds... (Ctrl+C to cancel)"
    sleep 10
    sudo reboot
else
    echo ""
    echo "=== Install complete — no reboot required ==="
fi
