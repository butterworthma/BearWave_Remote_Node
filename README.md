# 🛰️ Headless JS8Call Raspberry Pi Zero  
### Remote HF Data Node with Browser-Accessible Desktop and Auto Wi-Fi Fallback

This project turns a Raspberry Pi Zero (or any Pi) into a self-contained, headless JS8Call node.  
It automatically launches JS8Call inside a virtual desktop and serves that desktop via noVNC so it can be controlled from any web browser.  

If the Pi detects your home Wi-Fi, it joins it automatically; otherwise it creates its own Wi-Fi access point (AP) called **JS8CALL-PI**.

---

## ⚙️ System Overview

| Component | Purpose |
|------------|----------|
| Xvfb + Openbox | Virtual lightweight desktop |
| x11vnc | Bridges the virtual display to VNC |
| noVNC | Serves the VNC desktop over HTTP/HTML5 |
| hostapd + dnsmasq | Provide fallback access point |
| wifi-autoswitch | Toggles between Wi-Fi client and AP modes |
| JS8Call | HF digital communications application |

---

## 1. Base System

Flash **Raspberry Pi OS Lite** (Bookworm or Bullseye).  
Boot and connect via SSH:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

---

## 2. Install Core Packages

```bash
sudo apt install -y   xvfb openbox x11vnc novnc websockify   lxterminal pcmanfm lightdm-gtk-greeter
```

---

## 3. Virtual Desktop Service (Xvfb + Openbox)

```bash
sudo tee /usr/local/bin/start-virtual-desktop.sh > /dev/null <<'EOF'
#!/bin/bash
export DISPLAY=:0
pkill -f "Xvfb :0" 2>/dev/null || true
Xvfb :0 -screen 0 1280x800x24 -nolisten tcp &
sleep 1
exec /usr/bin/openbox-session
EOF
sudo chmod +x /usr/local/bin/start-virtual-desktop.sh
```

```bash
sudo tee /etc/systemd/system/virtual-desktop.service > /dev/null <<'EOF'
[Unit]
Description=Virtual X desktop on :0 (Xvfb + Openbox)
After=network.target

[Service]
User=mark        # change to your username
Environment=DISPLAY=:0
ExecStart=/usr/local/bin/start-virtual-desktop.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now virtual-desktop
```

---

## 4. x11vnc Service

```bash
sudo tee /etc/systemd/system/x11vnc.service > /dev/null <<'EOF'
[Unit]
Description=x11vnc on virtual desktop :0
After=virtual-desktop.service
Requires=virtual-desktop.service

[Service]
User=mark
Environment=DISPLAY=:0
ExecStart=/usr/bin/x11vnc -display :0 -forever -shared -rfbport 5900 -nopw -noxdamage
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now x11vnc
```

---

## 5. noVNC Service

```bash
sudo chmod +x /usr/share/novnc/utils/novnc_proxy

sudo tee /etc/systemd/system/novnc.service > /dev/null <<'EOF'
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
```

---

## 6. Access the JS8Call Desktop

- **Home Wi-Fi:**  
  `http://<pi-ip>:6080/vnc.html?host=<pi-ip>&port=6080`

- **AP Mode:**  
  `http://192.168.4.1:6080/vnc.html?host=192.168.4.1&port=6080`

---

## 7. Auto-start JS8Call

```bash
mkdir -p ~/.config/openbox
cat > ~/.config/openbox/autostart <<'EOF'
(js8call >/dev/null 2>&1 &)
EOF
```

---

## 8. Optional Redirect (Port 80 → 6080)

```bash
sudo tee /etc/systemd/system/novnc-redirect.service > /dev/null <<'EOF'
[Unit]
Description=Redirect HTTP :80 to noVNC :6080
After=novnc.service
Wants=novnc.service

[Service]
Type=simple
ExecStart=/bin/sh -c 'while true; do { read r; while [ "$r" != $'\r' ]; do read r; done;   echo -ne "HTTP/1.1 302 Found\r\nLocation: http://$HOSTNAME:6080/\r\n\r\n"; } | nc -l -p 80 -q 0; done'
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now novnc-redirect
```

Now open simply:  
`http://<pi-ip>`

---

## 9. Automatic Wi-Fi Fallback (Client ↔ AP)

```bash
sudo apt install -y hostapd dnsmasq
sudo systemctl disable --now hostapd dnsmasq
```

### Access Point Config

```bash
sudo tee /etc/dnsmasq.conf > /dev/null <<'EOF'
interface=wlan0
dhcp-range=192.168.4.10,192.168.4.100,255.255.255.0,24h
EOF

sudo tee /etc/hostapd/hostapd.conf > /dev/null <<'EOF'
country_code=GB
interface=wlan0
ssid=JS8CALL-PI
hw_mode=g
channel=7
wmm_enabled=0
auth_algs=1
ignore_broadcast_ssid=0
EOF
```

### Client Wi-Fi Config

```bash
sudo tee /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null <<'EOF'
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
```

### Wi-Fi Auto-Switcher Script

```bash
sudo tee /usr/local/bin/wifi-autoswitch.sh > /dev/null <<'EOF'
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
```

### Wi-Fi Auto-Switcher Service

```bash
sudo tee /etc/systemd/system/wifi-autoswitch.service > /dev/null <<'EOF'
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
```

---

## 10. HTTPS Access (Optional)

```bash
sudo apt install -y openssl
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048   -keyout /etc/ssl/private/novnc.key   -out /etc/ssl/certs/novnc.crt -subj "/CN=JS8CALL-PI"
```

Edit `/etc/systemd/system/novnc.service`:

```ini
ExecStart=/usr/share/novnc/utils/novnc_proxy --vnc localhost:5900   --listen 0.0.0.0:6080   --cert /etc/ssl/certs/novnc.crt   --key /etc/ssl/private/novnc.key
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart novnc
```

Now connect using:  
`https://<pi-ip>:6080/vnc.html`

---

## ✅ Health Check

```bash
systemctl status virtual-desktop x11vnc novnc wifi-autoswitch --no-pager
ss -ltnp | grep -E '(:5900|:6080|:80)'
```

---

## 🧩 Troubleshooting

| Symptom | Likely Cause | Fix |
|----------|---------------|-----|
| “Failed to open page” | noVNC not running | `sudo systemctl restart novnc` |
| Black screen | X DAMAGE issue | add `-noxdamage` in x11vnc service |
| Port 5900 conflict | RealVNC active | `sudo systemctl disable --now vncserver-x11-serviced` |
| Directory listing | Wrong web path | Use `novnc_proxy` |
| No AP appears | `journalctl -u wifi-autoswitch -b` |
| No IP on AP | `sudo systemctl restart dnsmasq` |

---

## 🧠 Credits

| Component | Source |
|------------|---------|
| JS8Call | [https://js8call.com](https://js8call.com) |
| noVNC / websockify | [https://novnc.com](https://novnc.com) |
| Openbox / Xvfb / x11vnc | Debian & Raspberry Pi OS packages |
| Guide Author | ChatGPT (GPT-5) |

---

## 🪶 Summary

Your Pi Zero is now a **fully autonomous JS8Call node** that:

- boots completely headless  
- runs JS8Call inside a virtual desktop  
- serves that desktop to any web browser  
- joins known Wi-Fi automatically  
- creates its own AP when no network is found  

Perfect for **field operations**, **expeditions**, and **remote digital HF communication**.
