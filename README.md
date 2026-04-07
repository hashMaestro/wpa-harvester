# WPA2/3 Captive Portal Harvester

A fully automated, headless-ready Evil Twin framework for Red Teaming and Wi-Fi security assessments. 
This tool dynamically generates captive portals based on MAC address OUI lookups and forcefully captures credentials using a built-in CNA (Captive Network Assistant) trigger mechanism.

## Disclaimer
**For educational purposes and authorized engagements testing only.** Using this tool against networks you do not own or have explicit permission to test is illegal. The author is not responsible for any misuse.

## Features
- **Dynamic OUI Lookup:** Automatically fetches the IEEE database to brand the portal (e.g., "Cisco System Update").
- **CNA Triggering:** Custom Python webserver that intercepts iOS/Android connectivity checks and forces the captive portal to open.
- **Dual-Injection Templating:** Injects target SSID and Vendor directly into the HTML payloads.
- **Auto-Cleanup (OPSEC):** Self-destructs the Rogue AP instantly upon capturing credentials to release the target back to their legitimate network.

## Prerequisites
You need a Linux environment (Kali/Ubuntu) and a Wi-Fi adapter that supports **AP (Master) Mode**.
```bash
sudo apt update
sudo apt install hostapd dnsmasq wget python3
```

##  Usage
**Note:** Included templates are intentionally generic for demonstration purposes. Please craft custom payloads that align with your authorized Rules of Engagement (RoE).

Make the script executable:
```bash
chmod +x portal_hoster.sh
```

**Basic Attack (Auto-Vendor Lookup):**
```bash
sudo ./portal_hoster.sh -i wlan0 -m 48:4E:FC:B1:C8:2F -s "Target_Network" -t wpa
```

**Targeted Attack (Manual Vendor Override):**
```bash
sudo ./portal_hoster.sh -i wlan0 -m 48:4E:FC:B1:C8:2F -s "Vodafone-Guest" -v "Vodafone" -t admin
```
