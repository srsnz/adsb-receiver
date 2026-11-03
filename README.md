# ADS-B Receiver for Raspberry Pi

A simple way to turn a Raspberry Pi and an RTL-SDR dongle into a **1090 MHz aircraft receiver**. The installer sets up one `readsb` decoder and lets you share its aircraft data with **Flightradar24**, **ADS-B Exchange**, and **OpenSky Network**.

It also provides a local aircraft map and data feeds for **Virtual Radar Server (VRS)**, your own tracking application, or a monitoring system. Suitable for home installations and remote receiver sites with an internet connection.

## How it works

```text
1090 MHz antenna → RTL-SDR → Raspberry Pi / readsb
                                    │
                                    ├── Beast TCP :30005 ── FR24
                                    │                 ├── ADS-B Exchange + MLAT
                                    │                 ├── OpenSky
                                    │                 └── Your own app / VRS
                                    ├── Basestation TCP :30003 (if enabled)
                                    └── tar1090 local aircraft map
```

Only `readsb` controls the USB receiver. The other applications connect to its decoded data; no extra dongles are needed.

## What you need

- Raspberry Pi with **Raspberry Pi OS Lite**, preferably 64-bit, and a suitable power supply and microSD card.
- RTL-SDR compatible USB receiver and **1090 MHz antenna**.
- Internet access with working DNS and time synchronisation (NTP).
- SSH access and a user with `sudo` privileges.
- Receiver **latitude**, **longitude** (decimal degrees), and **antenna elevation above sea level** (metres).
- An email address / account for FR24, an ADS-B Exchange account for station linking, and an OpenSky account if feeding OpenSky.

## Install

Flash Raspberry Pi OS Lite using [Raspberry Pi Imager](https://www.raspberrypi.com/software/). Set up the username, network and SSH during imaging. Connect the RTL-SDR, boot the Pi and SSH in.

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/srsnz/adsb-receiver.git
cd adsb-receiver
chmod +x install.sh diagnose.sh
./install.sh
```

Follow the prompts. The script installs system prerequisites and `readsb`, checks the local Beast output, and offers each feeder installer. Upstream installer scripts are downloaded for review before you approve them.

**Run this on a fresh Raspberry Pi OS Lite installation.** It will not replace an existing ADS-B decoder or feeder configuration.

## Feeder setup reference

All three feeders should use the **existing decoder on the Pi**, not open the RTL-SDR directly.

### Flightradar24 (FR24)

In the FR24 setup wizard:

| Prompt | Enter / select |
|---|---|
| Email | Your FR24 email address |
| Sharing key | Existing key, or leave blank for a new station |
| MLAT participation | As preferred; requires accurate receiver location |
| Latitude / longitude | Your antenna's coordinates |
| Antenna altitude | **Feet above sea level** (metres × 3.28084) |
| Receiver type | **4 — ModeS Beast** |
| Connection type | **1 — Network connection** |
| Receiver IP / hostname | **`127.0.0.1`** |
| Receiver data port | **`30005`** |
| RAW output port 30334 | **No**, unless you specifically need it |
| Basestation output port 30003 | **No**, unless you specifically need it |

**Important:** The wizard asks for the IP and port separately. Enter `127.0.0.1` in the hostname field, **not** `127.0.0.1:30005`.

The resulting `/etc/fr24feed.ini` should include:

```ini
receiver="beast-tcp"
host="127.0.0.1:30005"
```

Do not publish the FR24 sharing key from that file. Check FR24 using `fr24feed-status` or the local interface at `http://PI-IP:8754`.

### ADS-B Exchange

Choose to install the **feed and MLAT** components. Use the existing local Beast decoder at **`127.0.0.1:30005`** when requested. Install **ADS-B Exchange stats** when prompted; it helps with account linking and station information.

**Linking your station:** Open [ADS-B Exchange My IP](https://www.adsbexchange.com/myip/) in a browser using the **same public internet connection** as the Pi, then follow the account-linking instructions. Being connected and sending data is separate from appearing in your ADS-B Exchange account. Keep the feeder's assigned UUID when relocating the same installation.

Optional local ADS-B Exchange interface:

```bash
sudo bash /usr/local/share/adsbexchange/git/install-or-update-interface.sh
```

### OpenSky Network

The OpenSky configuration dialog should use:

| Prompt | Enter / select |
|---|---|
| Dump1090 branch | **`default`** (not `hptoa`) |
| Dump1090 / Beast port | **`30005`** |
| Receiver location | Your antenna's latitude and longitude |
| Antenna elevation | **Metres above sea level** |
| Username | Your OpenSky account username |

The feeder connects to the existing `readsb` Beast output. Check `sudo journalctl -u opensky-feeder -n 30 --no-pager` for a connection to `collector.opensky-network.org`.

## Use the data in your own software

You can consume the same local aircraft stream as the feeder clients. **Do not connect your own software directly to the USB SDR** while `readsb` is running.

| Interface | Address / port | Typical use |
|---|---|---|
| **Beast TCP** | `PI-IP:30005` | Virtual Radar Server, custom decoders, remote aggregation |
| **Basestation / SBS TCP** | `PI-IP:30003` if enabled in `readsb` | VRS and applications expecting SBS messages |
| **tar1090 map** | `http://PI-IP/tar1090/` | Browser-based aircraft map |
| **readsb JSON** | Usually `/run/readsb/aircraft.json` on the Pi | Local scripts, APIs, dashboards |

For **Virtual Radar Server**, add a receiver with the Pi's LAN/VPN address, port **30005**, and a Beast-compatible data format; alternatively use port **30003** with a Basestation/SBS receiver format if that output is enabled.

For **your own app**, either consume the Beast stream on TCP `30005` or read the local JSON produced by `readsb`. Beast is a binary protocol; JSON is simpler for scripts and dashboards. Check the actual JSON path and readsb configuration on your installation. A web JSON endpoint is not guaranteed just because tar1090 is installed.

**Remote sites:** use a private network or VPN (for example, WireGuard) to reach the Pi. Do **not** forward the decoder ports directly to the public internet. Reserve the Pi's DHCP address or use a stable hostname if other software depends on it.

## Check status

Run the included diagnostic script:

```bash
cd ~/adsb-receiver
./diagnose.sh
```

Useful manual checks:

```bash
fr24feed-status
sudo systemctl status readsb fr24feed adsbexchange-feed adsbexchange-mlat adsbexchange-stats opensky-feeder --no-pager
sudo ss -ltnp | grep -E ':30005|:30003'
sudo journalctl -u adsbexchange-feed -n 30 --no-pager
sudo journalctl -u opensky-feeder -n 30 --no-pager
```

Services should be active, `readsb` should listen on port `30005`, and the feeder logs should show remote connections. Confirm aircraft data in each provider's dashboard.

## Troubleshooting

| Problem | Check |
|---|---|
| Feeder disconnected but aircraft appear locally | DNS (`getent hosts pool.ntp.org`) and time (`timedatectl status`) |
| No aircraft or decoder fails | RTL-SDR USB connection, antenna, `sudo journalctl -u readsb -n 50` |
| Nothing listening on port 30005 | `readsb` service and `/etc/default/readsb` network settings |
| FR24 cannot connect | Beast/network mode; `127.0.0.1` and `30005` entered separately in the wizard |
| ADS-B Exchange not in account | Link from a browser on the same public IP; verify stats service and feeder UUID |
| OpenSky offline | `sudo journalctl -u opensky-feeder -n 50 --no-pager` |
| Remote VRS/app cannot connect | Pi IP, VPN routing, firewall, and whether `readsb` binds the required interface |

## Projects and credits

This installer uses third-party software and official/provider installation processes:

- [readsb](https://github.com/wiedehopf/readsb) and [tar1090](https://github.com/wiedehopf/tar1090)
- [Flightradar24](https://www.flightradar24.com/)
- [ADS-B Exchange](https://www.adsbexchange.com/)
- [OpenSky Network](https://opensky-network.org/)

Keep station keys, account credentials and local configuration files out of GitHub. This repository contains no station-specific secrets.
