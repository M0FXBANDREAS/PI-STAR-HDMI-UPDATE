#!/bin/bash
# Pi-Star HDMI dashboard installer, v1.0.1
# Supports Pi-Star on Raspberry Pi, Debian/Raspbian Bookworm only.
set -Eeuo pipefail
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID} == 0 ]] || fail 'Run with sudo bash pistar-hdmi-install.sh'
[[ ${1:-} != --help ]] || { echo 'Usage: sudo bash pistar-hdmi-install.sh'; exit 0; }
[[ -f /etc/pistar-release ]] || fail 'Pi-Star installation not found.'
[[ -f /etc/os-release ]] || fail 'Cannot identify the operating system.'
. /etc/os-release
[[ ${VERSION_CODENAME:-} == bookworm ]] || fail 'This release supports Bookworm only. No changes made.'
[[ -r /proc/device-tree/model ]] || fail 'Raspberry Pi hardware not detected.'
grep -aq 'Raspberry Pi' /proc/device-tree/model || fail 'Raspberry Pi hardware required.'
id pi-star >/dev/null 2>&1 || fail 'The pi-star account is missing.'
# Pi-Star 4.3.7 provides rpi-rw/rpi-ro as interactive aliases.
# Use mount directly instead of depending on shell startup files.
for tool in systemctl findmnt mount; do
  command -v "$tool" >/dev/null || fail "Required command missing: $tool"
done
restore_ro=0
restore_boot_ro=0
boot_mount=0
root_options=$(findmnt -n -o OPTIONS --mountpoint /) || fail 'Cannot inspect root mount.'
case ",$root_options," in *,ro,*) restore_ro=1;; esac
if boot_options=$(findmnt -n -o OPTIONS --mountpoint /boot/firmware); then
  boot_mount=1
  case ",$boot_options," in *,ro,*) restore_boot_ro=1;; esac
fi
cleanup() {
  result=$?
  trap - EXIT
  # Restore the boot mount before the root mount.
  if (( restore_boot_ro )); then
    if ! mount -o remount,ro /boot/firmware; then
      echo 'Could not restore /boot/firmware to read-only mode.' >&2
      result=1
    fi
  fi
  if (( restore_ro )); then
    if ! mount -o remount,ro /; then
      echo 'Could not restore / to read-only mode. Run rpi-ro manually.' >&2
      result=1
    fi
  fi
  if (( result != 0 )); then echo 'Installation failed. See the error above; no hotspot configuration was edited.' >&2; fi
  exit "$result"
}
trap cleanup EXIT
mount -o remount,rw / || fail 'Cannot make root filesystem writable.'
if (( boot_mount )); then
  mount -o remount,rw /boot/firmware || fail 'Cannot make boot filesystem writable.'
fi
echo 'Installing HDMI browser and display packages (this can take several minutes)...'
apt-get update
apt-get install -y --no-install-recommends xserver-xorg xserver-xorg-legacy xinit xauth openbox chromium x11-xserver-utils dbus-x11 fonts-dejavu-core
for executable in /usr/bin/startx /usr/lib/xorg/Xorg /usr/bin/chromium /usr/bin/dbus-run-session; do
  [[ -x $executable ]] || fail "Required executable missing: $executable"
done
backup=$(mktemp -d /var/backups/pistar-hdmi.XXXXXXXX)
chmod 700 "$backup"
for target in /usr/local/bin/pistar-hdmi-session /etc/systemd/system/pistar-hdmi.service; do
  if [[ -e $target ]]; then cp -a --parents "$target" "$backup/"; fi
done
systemctl is-enabled pistar-hdmi.service >"$backup/previous-enabled.txt" 2>&1 || true
systemctl stop pistar-hdmi.service 2>/dev/null || true
cat >/usr/local/bin/pistar-hdmi-session <<'SESSION'
#!/bin/sh
set -e
xset s off
xset s noblank
xset -dpms || true
xhost +SI:localuser:pi-star
install -d -o pi-star -g pi-star -m 700 /run/pistar-hdmi-browser
openbox &
exec runuser -u pi-star -- env HOME=/home/pi-star DISPLAY="$DISPLAY" XAUTHORITY=/dev/null dbus-run-session -- chromium --user-data-dir=/run/pistar-hdmi-browser --kiosk --no-first-run --no-default-browser-check --disable-session-crashed-bubble http://127.0.0.1/
SESSION
chmod 755 /usr/local/bin/pistar-hdmi-session
cat >/etc/systemd/system/pistar-hdmi.service <<'SERVICE'
[Unit]
Description=Pi-Star HDMI dashboard
After=network.target
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Type=simple
RuntimeDirectory=pistar-hdmi-x
RuntimeDirectoryMode=0700
Environment=HOME=/run/pistar-hdmi-x
WorkingDirectory=/run/pistar-hdmi-x
ExecStart=/usr/bin/startx /usr/local/bin/pistar-hdmi-session -- /usr/lib/xorg/Xorg :0 vt7 -nolisten tcp -logfile /run/pistar-hdmi-x/Xorg.log
Restart=on-failure
RestartSec=10
KillMode=control-group

[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
systemctl reset-failed pistar-hdmi.service || true
systemctl enable --now pistar-hdmi.service
echo "HDMI service started and enabled at boot. Previous files backed up in: $backup"
echo 'Check the HDMI monitor. Service startup does not confirm that a picture is visible.'
echo 'Diagnostics: sudo journalctl -u pistar-hdmi.service -n 50 --no-pager'
echo 'Disable HDMI: sudo systemctl disable --now pistar-hdmi.service'
echo 'No MMDVM, GPIO, radio, network, or dashboard configuration was changed.'
