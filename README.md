# Raspberry Pi ADS-B receiver — FR24 + ADS-B Exchange + OpenSky

**Fresh-install kit** for a Raspberry Pi with **Raspberry Pi OS Lite** and one RTL-SDR 1090 MHz receiver. Installs a decoder (`readsb`) and guides you through adding three independent feeder services. Intended for **new / blank systems**, not upgrades of existing ADS-B installations.

> **Testing:** Bash syntax checked; not yet end-to-end tested on a newly flashed Pi. Upstream installers and package URLs can change. Test on a spare Pi before unattended remote deployment. Review downloaded third-party scripts before authorising execution.

## Architecture

```text
RTL-SDR USB + 1090 MHz antenna
           |
         readsb (single decoder)
           |  Beast TCP :30005
           +---- FR24 (network / Beast mode; NOT USB decoder)
           +---- ADS-B Exchange feed + MLAT
           +---- OpenSky feeder
           +---- Optional Virtual Radar Server via LAN/VPN
```

## Requirements

- Raspberry Pi with Raspberry Pi OS Lite (Debian-based, **arm64** preferred; armhf also supported).
- RTL2832-compatible USB SDR, 1090 MHz antenna, power supply, working Internet/DNS/NTP.
- SSH and a normal user with sudo access (configure in Raspberry Pi Imager).
- Accurate **latitude, longitude, antenna altitude above mean sea level in metres**.
- FR24 sharing key (or create a new station); ADS-B Exchange feeder name; optional OpenSky account.

## Installation from a fresh Pi

1. Flash Raspberry Pi OS Lite using Raspberry Pi Imager; configure hostname, user, Wi-Fi if required, SSH, and credentials. Boot with the SDR attached.
2. SSH into the Pi and run:

```bash
sudo apt-get update
sudo apt-get install -y git
# After replacing the repository contents on GitHub:
git clone https://github.com/srsnz/adsb-receiver.git
cd adsb-receiver
chmod +x install.sh diagnose.sh
./install.sh
```

3. Approve the OS dependencies and **readsb** upstream installer after reviewing its downloaded script. The readsb installer may offer a local `tar1090` aircraft map.
4. Enter site latitude, longitude and antenna altitude. The script uses `readsb-set-location` where available and checks Beast TCP port **30005** before proceeding.
5. Choose the feeders to install. Each provider's installer has its own interactive configuration. **FR24 must use an external Beast TCP decoder at `127.0.0.1:30005`**, not direct RTL-SDR access. ADS-B Exchange should use the same Beast feed. For OpenSky choose `default` decoder mode and port `30005` (not `hptoa`).
6. Check actual reporting in each provider dashboard; run `./diagnose.sh`.

**Do not run `sudo ./install.sh`.** The script invokes sudo only for privileged actions.

## Verify

```bash
./diagnose.sh
sudo systemctl status readsb fr24feed adsbexchange-feed adsbexchange-mlat opensky-feeder --no-pager
sudo journalctl -u readsb -n 50 --no-pager
sudo journalctl -u fr24feed -n 50 --no-pager
sudo journalctl -u adsbexchange-feed -n 50 --no-pager
sudo journalctl -u opensky-feeder -n 50 --no-pager
```

Expected: decoder is active; TCP 30005 listens; feeder processes are active; remote server connections establish. **Actual aircraft uploads must be verified in each provider's station dashboard.** `systemctl is-enabled` indicates boot configuration, not service health.

## Networking and resilience

- DHCP is fine; reserve a static lease at the router if desired. Keep DNS and NTP functional. Incorrect time/DNS caused a real outage at the Glenorchy/Precipice Hill installation.
- **Do not forward TCP 30005 to the public Internet.** If you need Virtual Radar Server remotely, use WireGuard/VPN and firewall rules.
- Only **one** decoder should open the SDR. FR24, ADS-B Exchange and OpenSky should read from the decoder's Beast TCP output.
- MLAT accuracy depends on correct station coordinates and altitude and reliable timekeeping.
- All feeder services should be enabled at boot by their installers; confirm using `./diagnose.sh`.

## Existing receiver? Do not use the fresh installer

If you already run `readsb`, `dump1090-fa`, `dump1090-mutability`, FR24 or ADS-B Exchange, this script deliberately stops rather than modifying the working setup. Use the individual upstream feeder instructions to add services to the existing port 30005 decoder.

## Troubleshooting

- `getent hosts opensky-network.org` fails: repair DHCP/DNS/router configuration.
- `timedatectl status` not synchronised: repair NTP before trusting feeder connections.
- `lsusb` doesn't show RTL-SDR: check USB, power and dongle.
- `readsb` fails: `sudo journalctl -u readsb -n 80 --no-pager` (permissions, DVB kernel module, missing dongle).
- No TCP 30005: decoder isn't serving Beast; check `/etc/default/readsb` and readsb logs.
- FR24 starts another decoder: change FR24 receiver type to Beast TCP/network mode; don't let two programs control the SDR.
- ADSBx stats page not reachable: `adsbexchange-stats` is optional; verify main feeder separately.
- OpenSky connects but no station data: check OpenSky account, location, logs and receiver input.

## Upstream projects / installation sources

- readsb: https://github.com/wiedehopf/readsb
- readsb installer: https://github.com/wiedehopf/adsb-scripts/blob/master/readsb-install.sh
- FR24: https://fr24.com/install.sh
- ADS-B Exchange: https://www.adsbexchange.com/community/feeder-hub/connect-equipment/
- OpenSky: https://opensky-network.org/

Third-party scripts execute with root privileges only after an interactive approval prompt. For production deployment, review/pin upstream versions and hashes; this package does not pin them.

## Security

Never commit FR24 sharing keys, account credentials, `/etc/fr24feed.ini`, local `.env` or site-specific secrets. This repository is intentionally location-independent. Avoid publishing internal IP addresses or operational station identifiers if not needed.
