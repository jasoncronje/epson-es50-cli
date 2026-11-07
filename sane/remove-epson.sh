#!/bin/sh
# Removes Epson's scanner software (Epson Scan 2, its Image Capture driver, ScanSmart,
# Event Manager, Scanner Monitor, Software Updater, OCR, TWAIN). `scan` no longer needs
# any of it once sane/build.sh has installed the patched SANE driver.
#
#   sudo sh sane/remove-epson.sh         list what would be removed
#   sudo sh sane/remove-epson.sh --yes   remove it
set -eu

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
USER_ID="$(id -u "$USER_NAME")"

[ -x "$USER_HOME/.local/share/scan/sane/bin/scanimage" ] || {
    echo "the patched SANE driver isn't installed; run sane/build.sh first, or scan won't work"
    exit 1
}

PATHS="
/Applications/Epson Software
/Library/Application Support/EPSON
/Library/Image Capture/Devices/EPSON ES017E.app
/Library/Image Capture/Support/EPSON
/Library/Image Capture/TWAIN Data Sources/Epson Scan 2 ES017E.ds
/Library/ColorSync/Profiles/EW-GRAY18
/Library/ColorSync/Profiles/EW-GRAY22
/Library/ColorSync/Profiles/EW-RGB18
/Library/ColorSync/Profiles/EW-sRGB
/Library/LaunchAgents/com.epson.esua.launcher.plist
/Library/LaunchAgents/com.epson.eventmanager.agent.plist
/Library/LaunchAgents/com.epson.scannermonitor.plist
$USER_HOME/Library/Preferences/EPSON
$USER_HOME/Library/Preferences/com.epson.scan.Epson-ScanSmart.plist
$USER_HOME/Library/Preferences/com.epson.InstallNavi.plist
$USER_HOME/Library/Preferences/com.epson.EpsonScan2.devices.plist
$USER_HOME/Library/Preferences/com.epson.ica.es017e.plist
$USER_HOME/Library/Preferences/com.epson.EPSON_Software_Updater_Agent.plist
$USER_HOME/Library/Preferences/com.epson.EventManager.plist
"
PKGS="$(pkgutil --pkgs | grep -i '^com\.epson\.' || true)"

echo "files and folders:"
echo "$PATHS" | while IFS= read -r p; do [ -n "$p" ] && [ -e "$p" ] && echo "  $p"; done
echo "installer receipts:"
for p in $PKGS; do echo "  $p"; done

if [ "${1:-}" != "--yes" ]; then
    echo
    echo "nothing removed. Run again with --yes to remove the above."
    exit 0
fi

# Stop the background agents and any running Epson processes.
for plist in /Library/LaunchAgents/com.epson.*.plist; do
    [ -e "$plist" ] && launchctl bootout "gui/$USER_ID" "$plist" 2>/dev/null || true
done
pkill -f "EPSON Scanner 2" 2>/dev/null || true
pkill -f "/Applications/Epson Software/" 2>/dev/null || true

echo "$PATHS" | while IFS= read -r p; do
    [ -n "$p" ] && [ -e "$p" ] && rm -rf "$p" && echo "removed $p"
done
for p in $PKGS; do pkgutil --forget "$p" >/dev/null && echo "forgot $p"; done
# Image Capture caches its device list; restart it so the old driver is gone.
killall icdd 2>/dev/null || true
echo "done. scan now uses the SANE driver only."
