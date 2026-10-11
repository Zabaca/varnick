#!/bin/sh
# Prints the launchd plist for Varnick: scripts/varnick.plist.in with its three places filled in. `make install` writes it as the
# LaunchAgent, and scripts/restart.sh as a transient job's when no LaunchAgent runs this checkout, so both run Varnick the same way.
# Usage: varnick-plist.sh <label> <checkout> <log file>
sed -e "s|@LABEL@|$1|g" -e "s|@ROOT@|$2|g" -e "s|@LOG@|$3|g" "$(dirname "$0")/varnick.plist.in"
