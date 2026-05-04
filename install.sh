#!/bin/bash
set -e

echo "ADS-B receiver installer starting..."

if [ ! -f config/site.conf ]; then
  echo "Missing config/site.conf"
  echo "Copy config/site.conf.example to config/site.conf and edit it first."
  exit 1
fi

source config/site.conf

echo "Site name: $SITE_NAME"
echo "Lat/Lon: $LAT, $LON"
echo "Altitude: $ALT_M m"

echo "Installer skeleton complete."
