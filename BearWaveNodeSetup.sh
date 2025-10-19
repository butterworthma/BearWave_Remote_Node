#!/bin/bash
# ===========================================================
# Headless JS8Call Pi Zero Installer (Full Version + JS8-CLI)
# by Mark Butterworth – 2025
# ===========================================================

set -e
LOGFILE="/var/log/js8call-setup.log"
exec > >(tee -a $LOGFILE) 2>&1

echo "🛰️ Starting setup for headless JS8Call Pi Node..."
sleep 2

# --- Update & upgrade system
sudo apt update && sudo apt full-upgrade -y

# --- Core packages
sudo apt install -y xvfb openbox x11vnc novnc websockify \
  lxterminal pcmanfm hostapd dnsmasq lightdm-gtk-greeter \
  wget curl jq git nodejs npm -y

# --- Disable default RealVNC
sudo systemctl disable --now vncserver-x11-serviced 2>/dev/null || true

# ===========================================================
# STEP 1: Create Virtual Desktop
# ===========================================================

sudo tee /usr/local/bin/start-virtual-desktop.sh >/dev/null <<'EOF'
#!/bin/bash
export DISPLAY=:0
pkill -f "Xvfb :0" 2>/dev/null || true
Xvfb :0 -screen 0 1280x800x24 -nolisten tcp &
sleep 1
exec /usr/bin/openbox-session
EOF
sudo chmod +x /usr/local/bin/start-virtual-desktop.sh

sudo tee /etc/systemd/system/virtual-desktop.service >/dev/null <<'EOF'
[Unit]
Description=Virtual X desktop on :0 (Xvfb + Openbox)
After=network.target

[Service]
User=pi
Environment=DISPLAY=:0
ExecStart=/usr/local/bin/start-virtual-desktop.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now virtual-desktop

# ===========================================================
# STEP 2: x11vnc Service
# ===========================================================

sudo tee /etc/systemd/system/x11vnc.service >/dev/null <<'EOF'
[Unit]
Description=x11vnc on virtual desktop :0
After=virtual-desktop.service
Requires=virtual-desktop.service

[Service]
User=pi
Environment=DISPLAY=:0
ExecStart=/usr/bin/x11vnc -display :0 -forever -shared -rfbport 5900 -nopw -noxdamage
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now x11vnc

# ===========================================================
# STEP 3: noVNC Service
# ===========================================================

sudo tee /etc/systemd/system/novnc.service >/dev/null <<'EOF'
[Unit]
Description=noVNC web access for the virtual desktop
After=network.target
Wants=x11vnc.service

[Service]
Type=simple
ExecStart=/usr/share/novnc/utils/novnc_proxy --vnc localhost:5900 --listen 0.0.0.0:6080
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now novnc

# --- Optional redirect (port 80 → 6080)
sudo tee /etc/systemd/system/novnc-redirect.service >/dev/null <<'EOF'
[Unit]
Description=Redirect HTTP :80 to noVNC :6080
After=novnc.service
Wants=novnc.service

[Service]
Type=simple
ExecStart=/bin/sh -c 'while true; do { read r; while [ "$r" != $'\r' ]; do read r; done; \
  echo -ne "HTTP/1.1 302 Found\r\nLocation: http://$HOSTNAME:6080/\r\n\r\n"; } | nc -l -p 80 -q 0; done'
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now novnc-redirect

# ===========================================================
# STEP 4: Wi-Fi Autoswitch (Client <-> AP)
# ===========================================================

sudo tee /usr/local/bin/wifi-autoswitch.sh >/dev/null <<'EOF'
#!/bin/bash
WLAN=wlan0
AP_IP=192.168.4.1
check_connection() {
    ip route | grep -q default && ping -c1 -W1 8.8.8.8 >/dev/null 2>&1
}
start_ap() {
    echo "[wifi-autoswitch] Starting AP mode..."
    sudo systemctl stop wpa_supplicant dhcpcd 2>/dev/null
    sudo ip link set $WLAN down
    sudo ip addr flush dev $WLAN
    sudo ip addr add $AP_IP/24 dev $WLAN
    sudo ip link set $WLAN up
    sudo systemctl start dnsmasq
    sudo systemctl start hostapd
}
stop_ap() {
    echo "[wifi-autoswitch] Stopping AP mode (client connected)..."
    sudo systemctl stop hostapd dnsmasq
    sudo systemctl restart dhcpcd wpa_supplicant
}
while true; do
    if check_connection; then
        stop_ap
    else
        start_ap
    fi
    sleep 15
done
EOF
sudo chmod +x /usr/local/bin/wifi-autoswitch.sh

sudo tee /etc/systemd/system/wifi-autoswitch.service >/dev/null <<'EOF'
[Unit]
Description=Auto-switch between Wi-Fi client and AP mode
After=network.target
[Service]
ExecStart=/usr/local/bin/wifi-autoswitch.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now wifi-autoswitch

# --- Default Wi-Fi configs
sudo tee /etc/dnsmasq.conf >/dev/null <<'EOF'
interface=wlan0
dhcp-range=192.168.4.10,192.168.4.100,255.255.255.0,24h
EOF

sudo tee /etc/hostapd/hostapd.conf >/dev/null <<'EOF'
country_code=GB
interface=wlan0
ssid=JS8CALL-PI
hw_mode=g
channel=7
wmm_enabled=0
auth_algs=1
ignore_broadcast_ssid=0
EOF

sudo tee /etc/wpa_supplicant/wpa_supplicant.conf >/dev/null <<'EOF'
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=GB

network={
    ssid="YourHomeSSID"
    psk="YourHomePassword"
    key_mgmt=WPA-PSK
    priority=10
}
EOF

# ===========================================================
# STEP 5: JS8Call Installation
# ===========================================================

echo "📦 Installing JS8Call..."
cd /tmp

LATEST_URL=$(curl -s https://api.github.com/repos/js8call/js8call/releases/latest | jq -r '.assets[].browser_download_url' | grep -i armhf.deb | head -n 1)

if [ -z "$LATEST_URL" ]; then
  echo "⚠️ Could not detect latest version automatically. Downloading fallback..."
  LATEST_URL="https://files.js8call.com/2.2/js8call_2.2_armhf.deb"
fi

wget -O js8call-latest.deb "$LATEST_URL"
sudo apt install -y ./js8call-latest.deb || true

sudo -u pi mkdir -p /home/pi/.config/openbox
sudo -u pi tee /home/pi/.config/openbox/autostart >/dev/null <<'EOF'
(js8call >/dev/null 2>&1 &)
EOF

# ===========================================================
# STEP 6: Install Trippnology JS8-CLI
# ===========================================================

echo "🧩 Installing @trippnology/js8-cli..."
sudo npm install -g @trippnology/js8-cli

# ===========================================================
# STEP 7: Finish
# ===========================================================

echo
echo "✅ Setup Complete!"
echo "Access from browser:"
echo "  Home Wi-Fi:   http://<pi-ip>:6080"
echo "  Field (AP):   http://192.168.4.1:6080"
echo
echo "JS8Call will auto-launch in a headless virtual desktop."
echo "The JS8Call CLI is now available via the 'js8' command."
echo "Logs: $LOGFILE"

