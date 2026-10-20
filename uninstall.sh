#!/bin/bash
# School Printer - uninstaller for macOS and Linux.
#   curl -fsSL https://print.mahanmirzaee.com/uninstall.sh | sudo bash
[ "$(id -u)" -eq 0 ] || { echo "Run it with sudo:  curl -fsSL https://print.mahanmirzaee.com/uninstall.sh | sudo bash"; exit 1; }
if [ "$(uname -s)" = Darwin ]; then
    DIR="/Library/Application Support/SchoolPrinter"; plist=/Library/LaunchDaemons/com.mahanmirzaee.schoolprinter.plist
    launchctl bootout system "$plist" 2>/dev/null || true; rm -f "$plist"
    u="$(stat -f %Su /dev/console 2>/dev/null || true)"; rm -f "$(eval echo "~$u")/Desktop/School Printer (Admin).webloc"
else
    DIR=/opt/schoolprinter
    systemctl disable --now schoolprinter 2>/dev/null || true; rm -f /etc/systemd/system/schoolprinter.service; systemctl daemon-reload
    command -v ufw >/dev/null && ufw status numbered 2>/dev/null | grep -q 'School Printer' && \
        ufw status numbered | awk -F'[][]' '/School Printer/ {print $2}' | sort -rn | while read -r n; do yes | ufw delete "$n" >/dev/null; done
    u="${SUDO_USER:-$(logname 2>/dev/null || true)}"; rm -f "$(eval echo "~$u")/Desktop/school-printer-admin.desktop"
fi
echo "School Printer stopped and removed from startup."
read -r -p "Also delete $DIR (program, settings, print log)? [y/N] " a </dev/tty || a=""
if [[ "$a" =~ ^[yY] ]]; then rm -rf "$DIR"; echo "Deleted."; fi
[ "$(uname -s)" = Darwin ] && echo "If you let the installer keep this Mac awake, undo it with:  sudo pmset -c sleep 1"
exit 0
