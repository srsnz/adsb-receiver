# adsb-receiver
Custom ADSB receiver script to load FR24Feeder, ADSB Exhange and VRS

Raspberry Pi Zero 2 W ADS-B receiver setup for:

- readsb decoder
- FR24 feeder
- ADS-B Exchange feeder
- Virtual Radar Server Beast output

Only readsb talks to the SDR. All feeders connect to readsb on port 30005.
