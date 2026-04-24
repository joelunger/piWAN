#!/usr/bin/env bash

# PiWAN Main Dashboard
# Complete implementation v2.0 

# --- Global Variables & Paths ---
VERSION="1.5.0"
CONFIG_DIR="/etc/piwan"
SNAPSHOT_DIR="$CONFIG_DIR/snapshots"
WIFI_IFACE="wlan0"
ETH_IFACE="eth0"

# Colors for terminal (not used in whiptail, but handy for shell output)
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Ensure root access
check_root() {
    if [ "$EUID" -ne 0 ]; then
        if command -v whiptail &> /dev/null; then
            whiptail --title " Error " --msgbox "PiWAN must be run as Root (sudo)." 10 50
        else
            echo "Error: PiWAN must be run as Root (sudo)."
        fi
        exit 1
    fi
}

# Verify dependencies before anything else
if ! command -v whiptail &> /dev/null; then
    echo "Error: 'whiptail' is not installed."
    echo "Please run 'sudo ./install.sh' first or install whiptail manually."
    exit 1
fi

check_root
mkdir -p "$SNAPSHOT_DIR" 2>/dev/null

# --- System Polling (Dashboard Info) ---

get_current_status() {
    if nmcli -t -f NAME,STATE con show --active 2>/dev/null | grep -q "^PiWAN_AP:activated"; then
        echo "Access Point (AP)"
    elif nmcli -t -f NAME,STATE con show --active 2>/dev/null | grep -q "^PiWAN_WISP_AP:activated"; then
        echo "WISP (Repeater)"
    elif nmcli -t -f NAME,STATE con show --active 2>/dev/null | grep -q "^PiWAN_LAN_RCV:activated"; then
        echo "LAN Receiver"
    else
        local wf_mode=$(iw dev $WIFI_IFACE info 2>/dev/null | grep type | awk '{print $2}')
        if [ "$wf_mode" == "AP" ]; then
            echo "Access Point (External)"
        elif [ "$wf_mode" == "managed" ]; then
            echo "WiFi Client"
        else
            echo "Offline / Unknown"
        fi
    fi
}

get_current_ssid() {
    # Check if AP is running, get its SSID
    if nmcli -t -f NAME,STATE con show --active 2>/dev/null | grep -qE "^PiWAN_(AP|WISP_AP):activated"; then
        # Parse the SSID from the connection file
        local prof=$(nmcli -t -f NAME,STATE con show --active | grep -E "^PiWAN_(AP|WISP_AP)" | cut -d: -f1)
        local ssid=$(nmcli -t -f 802-11-wireless.ssid con show "$prof" | cut -d: -f2)
        echo "$ssid"
    else
        # Otherwise, what are we connected to?
        local ssid=$(iw dev $WIFI_IFACE info 2>/dev/null | grep ssid | awk '{print $2}')
        if [ -z "$ssid" ]; then
            echo "Not connected"
        else
            echo "$ssid"
        fi
    fi
}

get_current_ip() {
    local ip=$(ip -4 addr show $WIFI_IFACE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    if [ -z "$ip" ]; then
        echo "No IP (wlan0)"
    else
        echo "$ip"
    fi
}

get_uptime() {
    uptime -p | cut -d ' ' -f 2-
}

# --- Cleanup Function ---
delete_piwan_connections() {
    nmcli con delete "PiWAN_AP" >/dev/null 2>&1
    nmcli con delete "PiWAN_WISP_Uplink" >/dev/null 2>&1
    nmcli con delete "PiWAN_WISP_AP" >/dev/null 2>&1
    nmcli con delete "PiWAN_LAN_RCV" >/dev/null 2>&1
}

# --- Mode: Access Point (AP) ---
setup_ap() {
    local ssid=$1
    local password=$2
    
    {
        echo 10
        delete_piwan_connections
        echo 30
        
        # Create AP connection using 'shared' method which auto-configures NAT and dnsmasq
        nmcli con add type wifi ifname $WIFI_IFACE con-name "PiWAN_AP" autoconnect yes ssid "$ssid" >/dev/null 2>&1
        echo 50
        
        nmcli con modify "PiWAN_AP" 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared 802-11-wireless-security.pmf 1 wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$password" >/dev/null 2>&1
        echo 80
        
        # Fix for 802.1X timeout/deadlock: explicitly set p2p interface unmanaged
        nmcli device set p2p-dev-wlan0 managed no >/dev/null 2>&1 || true
        
        # Stepwise connection build-up to prevent timeout
        if ! nmcli con up "PiWAN_AP" >/dev/null 2>&1; then
            sleep 3
            nmcli radio wifi off
            sleep 2
            nmcli radio wifi on
            sleep 5
            nmcli con up "PiWAN_AP" >/dev/null 2>&1
        fi
        echo 100
        sleep 1
    } | whiptail --title " Mode Switch " --gauge "Configuring Access Point ($ssid)..." 6 50 0

    if nmcli -t -f NAME,STATE con show --active 2>/dev/null | grep -q "^PiWAN_AP:activated"; then
        whiptail --title " Success " --msgbox "Access Point successfully started!\n\nSSID: $ssid" 10 50
    else
        whiptail --title " Error " --msgbox "Failed to start AP.\nCheck if your WiFi chip supports AP mode." 10 50
    fi
}

# --- Mode: WISP (Wireless ISP) ---
# Connects to an existing WiFi, and splits the adapter to broadcast another AP
setup_wisp() {
    local uplnk_ssid=$1
    local uplnk_pass=$2
    local ap_ssid=$3
    local ap_pass=$4

    {
        echo 10
        delete_piwan_connections
        echo 20
        
        # 1. Connect to Uplink (Client)
        if [ -z "$uplnk_pass" ]; then
            nmcli dev wifi connect "$uplnk_ssid" ifname $WIFI_IFACE name "PiWAN_WISP_Uplink" >/dev/null 2>&1
        else
            nmcli dev wifi connect "$uplnk_ssid" password "$uplnk_pass" ifname $WIFI_IFACE name "PiWAN_WISP_Uplink" >/dev/null 2>&1
        fi
        echo 40

        # Wait to get IP
        sleep 5
        echo 50
        
        # 2. Add an AP interface. On modern Linux, NetworkManager can create a virtual AP if the hardware supports it.
        # We bind the AP to the same physical interface but as a separate connection logic, shared.
        nmcli con add type wifi ifname $WIFI_IFACE con-name "PiWAN_WISP_AP" autoconnect yes ssid "$ap_ssid" >/dev/null 2>&1
        echo 60
        
        # Modify for AP mode and NAT
        nmcli con modify "PiWAN_WISP_AP" 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared 802-11-wireless-security.pmf 1 wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$ap_pass" >/dev/null 2>&1
        echo 80
        
        # Fix for 802.1X timeout/deadlock: explicitly set p2p interface unmanaged
        nmcli device set p2p-dev-wlan0 managed no >/dev/null 2>&1 || true
        
        # Turn up AP interface (with stepwise retry for timeouts)
        if ! nmcli con up "PiWAN_WISP_AP" >/dev/null 2>&1; then
            sleep 3
            nmcli radio wifi off
            sleep 2
            nmcli radio wifi on
            sleep 5
            nmcli con up "PiWAN_WISP_AP" >/dev/null 2>&1
        fi
        echo 100
        sleep 2
    } | whiptail --title " Mode Switch " --gauge "Configuring WISP Mode..." 6 50 0

    if nmcli -t -f NAME,STATE con show --active 2>/dev/null | grep -q "^PiWAN_WISP_AP:activated"; then
        whiptail --title " Success " --msgbox "WISP Mode successfully established!\n\nBroadcasting: $ap_ssid" 10 50
    else
        whiptail --title " Error " --msgbox "Failed to start WISP Mode.\nEnsure your adapter supports concurrent Client & AP." 10 50
    fi
}

# --- Mode: LAN Receiver ---
setup_lan_receiver() {
    local ssid=$1
    local pass=$2

    {
        echo 10
        delete_piwan_connections
        echo 30
        
        # Connect WiFi as client
        if [ -z "$pass" ]; then
            nmcli dev wifi connect "$ssid" ifname $WIFI_IFACE name "PiWAN_LAN_RCV" >/dev/null 2>&1
        else
            nmcli dev wifi connect "$ssid" password "$pass" ifname $WIFI_IFACE name "PiWAN_LAN_RCV" >/dev/null 2>&1
        fi
        echo 60
        
        # Provide Internet to the Ethernet Port via Shared Method
        nmcli con modify "Wired connection 1" ipv4.method shared >/dev/null 2>&1 || true
        nmcli con modify "eth0" ipv4.method shared >/dev/null 2>&1 || true
        # In case the user has a dynamically named eth profile, we just restart eth0 if possible
        nmcli dev connect $ETH_IFACE >/dev/null 2>&1
        
        echo 100
        sleep 1
    } | whiptail --title " Mode Switch " --gauge "Configuring LAN Receiver..." 6 50 0
    whiptail --title " Success " --msgbox "LAN Receiver Mode active.\nWiFi traffic is now routed to $ETH_IFACE." 10 50
}

# --- Snapshot Manager (Phase 4) ---
manage_snapshots() {
    local ACTION=$(whiptail --title " Snapshot Manager " --menu "Choose an action:" 15 50 4 \
        "1" "Create Snapshot" \
        "2" "Restore Snapshot" \
        "3" "List Snapshots" \
        "4" "Back" \
        3>&1 1>&2 2>&3)

    case $ACTION in
        1)
            local sname=$(whiptail --inputbox "Enter snapshot name (no spaces):" 10 50 "backup-$(date +%F)" 3>&1 1>&2 2>&3)
            if [ -n "$sname" ]; then
                sname=$(echo "$sname" | tr -d ' ')
                tar -czf "$SNAPSHOT_DIR/$sname.tar.gz" -C /etc/NetworkManager/system-connections . >/dev/null 2>&1
                whiptail --title " Success " --msgbox "Snapshot '$sname' saved!" 10 50
            fi
            ;;
        2)
            # Find stored snapshots
            local snaps=$(ls "$SNAPSHOT_DIR" | grep "\.tar\.gz" 2>/dev/null)
            if [ -z "$snaps" ]; then
                whiptail --title " Error " --msgbox "No snapshots found." 10 50
                return
            fi
            
            # Format list for whiptail
            local options=()
            for s in $snaps; do
                options+=("$s" "")
            done
            
            local chosen=$(whiptail --title " Restore Snapshot " --menu "Select a snapshot to restore:" 15 50 5 "${options[@]}" 3>&1 1>&2 2>&3)
            if [ -n "$chosen" ]; then
                if whiptail --title " Warning " --yesno "This will overwrite current network settings. Proceed?" 10 50; then
                    rm -f /etc/NetworkManager/system-connections/*
                    tar -xzf "$SNAPSHOT_DIR/$chosen" -C /etc/NetworkManager/system-connections >/dev/null 2>&1
                    nmcli con reload
                    whiptail --msgbox "Snapshot restored! NetworkManager reloaded." 10 50
                fi
            fi
            ;;
        3)
            local snaps=$(ls -lh "$SNAPSHOT_DIR" | awk '{print $9 "  [" $5 "]"}' | tail -n +2)
            if [ -z "$snaps" ]; then
                whiptail --title " Snapshots " --msgbox "No snapshots available." 10 50
            else
                whiptail --title " Snapshots " --msgbox "Available Snapshots:\n\n$snaps" 15 50
            fi
            ;;
        *)
            return
            ;;
    esac
}

# --- Dashboard Function (Refactored) ---
configure_router() {
    local ROUTE_CHOICE=$(whiptail --title " Configure Router " --nocancel --menu "Select your desired network mode:" 16 65 5 \
        "1" "Repeater / Hotspot Wizard (WISP)" \
        "2" "LAN Receiver (WiFi to ETH)" \
        "3" "Isolated Router (Local WLAN only, no Uplink)" \
        "0" "Back to Dashboard" \
        3>&1 1>&2 2>&3)

    case "$ROUTE_CHOICE" in
        1)
            # Wizard for Repeater/Hotspot
            local UPLINK_MODE=$(whiptail --title " Repeater Wizard " --nocancel --menu "How should the Pi receive the Internet signal?" 16 65 4 \
                "1" "From LAN Cable (LAN to WLAN)" \
                "2" "From existing WiFi (WLAN to WLAN / WISP)" \
                "0" "Cancel" \
                3>&1 1>&2 2>&3)
            
            if [ "$UPLINK_MODE" = "1" ]; then
                # LAN to WLAN (Access Point)
                local SSID=$(whiptail --title " Hotspot Setup " --inputbox "Enter the SSID for your new Hotspot:" 10 50 "PiWAN_Hotspot" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 -a -n "$SSID" ]; then
                    local PASS=$(whiptail --title " Hotspot Setup " --passwordbox "Enter the password (min. 8 chars):" 10 50 3>&1 1>&2 2>&3)
                    if [ $? -eq 0 ]; then
                        if [ ${#PASS} -lt 8 ]; then
                            whiptail --title " Error " --msgbox "Password must be at least 8 characters long!" 10 50
                        else
                            setup_ap "$SSID" "$PASS"
                        fi
                    fi
                fi
            elif [ "$UPLINK_MODE" = "2" ]; then
                # WLAN to WLAN (WISP)
                local UPLINK_SSID=$(whiptail --title " Repeater Setup (Uplink) " --inputbox "Enter the target WiFi SSID to repeat:" 10 50 "" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 -a -n "$UPLINK_SSID" ]; then
                    local UPLINK_PASS=$(whiptail --title " Repeater Setup (Uplink) " --passwordbox "Enter target WiFi password (leave blank if open):" 10 50 3>&1 1>&2 2>&3)
                    if [ $? -eq 0 ]; then
                        local AP_SSID=$(whiptail --title " Repeater Setup (Hotspot) " --inputbox "Enter the NEW Hotspot SSID to broadcast:" 10 50 "PiWAN_Repeater" 3>&1 1>&2 2>&3)
                        if [ $? -eq 0 -a -n "$AP_SSID" ]; then
                            local AP_PASS=$(whiptail --title " Repeater Setup (Hotspot) " --passwordbox "Enter Hotspot password (min. 8 chars):" 10 50 3>&1 1>&2 2>&3)
                            if [ $? -eq 0 ]; then
                                 if [ ${#AP_PASS} -lt 8 ]; then
                                     whiptail --msgbox "Hotspot password must be at least 8 characters!" 10 50
                                 else
                                     setup_wisp "$UPLINK_SSID" "$UPLINK_PASS" "$AP_SSID" "$AP_PASS"
                                 fi
                            fi
                        fi
                    fi
                fi
            fi
            ;;
        2)
            # LAN Receiver
            local TARGET_SSID=$(whiptail --title " LAN Receiver " --inputbox "Enter the WiFi SSID to connect to:" 10 50 "" 3>&1 1>&2 2>&3)
            if [ $? -eq 0 -a -n "$TARGET_SSID" ]; then
                local TARGET_PASS=$(whiptail --title " LAN Receiver " --passwordbox "Enter password (leave blank if open):" 10 50 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ]; then
                    setup_lan_receiver "$TARGET_SSID" "$TARGET_PASS"
                fi
            fi
            ;;
        3)
            # Isolated Router (Same config logic as AP, but structurally clear what it does)
            local SSID=$(whiptail --title " Isolated Router Setup " --inputbox "Enter the SSID for the Local Network:" 10 50 "PiWAN_Local" 3>&1 1>&2 2>&3)
            if [ $? -eq 0 -a -n "$SSID" ]; then
                local PASS=$(whiptail --title " Isolated Router Setup " --passwordbox "Enter the password (min. 8 chars):" 10 50 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ]; then
                    if [ ${#PASS} -lt 8 ]; then
                        whiptail --title " Error " --msgbox "Password must be at least 8 characters long!" 10 50
                    else
                        setup_ap "$SSID" "$PASS"
                    fi
                fi
            fi
            ;;
        0|*)
            return
            ;;
    esac
}

# --- PiWAN Live Traffic Monitor ---
start_monitor() {
    clear
    tput civis # Hide cursor
    
    # Restore cursor on ctrl+c
    trap 'tput cnorm; return' SIGINT
    
    local iface=$WIFI_IFACE
    local max_speed=50000 # 50 Mbit visual cap
    local hashes="####################"
    local dashes="--------------------"
    
    while true; do
        # Top-left anchor for smooth redraws
        tput cup 0 0
        
        # Measure 1: Read proc
        local rx1=$(grep "$iface:" /proc/net/dev | awk '{print $2}')
        local tx1=$(grep "$iface:" /proc/net/dev | awk '{print $10}')
        
        # Catch key for 1 second instead of rigid sleep
        read -t 1 -n 1 key
        if [[ $key == "q" || $key == "Q" ]]; then
            tput cnorm
            return
        fi

        # Measure 2
        local rx2=$(grep "$iface:" /proc/net/dev | awk '{print $2}')
        local tx2=$(grep "$iface:" /proc/net/dev | awk '{print $10}')
        
        local rx_speed=0
        local tx_speed=0
        if [[ -n "$rx1" && -n "$rx2" ]]; then
            rx_speed=$(( (rx2 - rx1) / 1024 * 8 ))
            tx_speed=$(( (tx2 - tx1) / 1024 * 8 ))
        fi
        
        local rx_bars=$(( rx_speed * 20 / max_speed ))
        local tx_bars=$(( tx_speed * 20 / max_speed ))
        
        [[ $rx_bars -gt 20 ]] && rx_bars=20
        [[ $tx_bars -gt 20 ]] && tx_bars=20
        [[ $rx_bars -lt 0 ]] && rx_bars=0
        [[ $tx_bars -lt 0 ]] && tx_bars=0
        
        local rx_str="${hashes:0:rx_bars}${dashes:0:$((20-rx_bars))}"
        local tx_str="${hashes:0:tx_bars}${dashes:0:$((20-tx_bars))}"
        
        local total_usage="No vnstat"
        if command -v vnstat &> /dev/null; then
            total_usage=$(vnstat -i $iface --oneline 2>/dev/null | awk -F';' '{print $6}')
            [[ -z "$total_usage" ]] && total_usage="pending..."
        fi
        
        echo -e "\033[1;36m+------------------- PiWAN Live Monitor -------------------+\033[0m"
        echo -e "| Interface: \033[1;33m%-10s\033[0m   Total Usage: \033[1;33m%-18s\033[0m |" "$iface" "$total_usage"
        echo -e "\033[1;36m|----------------------------------------------------------|\033[0m"
        echo -e "| Traffic Live:                                            |"
        printf  "|  In:  [%s] %-10s                            |\n" "\033[1;32m$rx_str\033[0m" "${rx_speed} kbit/s"
        printf  "|  Out: [%s] %-10s                            |\n" "\033[1;31m$tx_str\033[0m" "${tx_speed} kbit/s"
        echo -e "\033[1;36m|----------------------------------------------------------|\033[0m"
        echo -e "| Connected Clients (DHCP Leases):                         |"
        printf  "|  %-15s %-15s %-20s |\n" "IP" "Hostname" "MAC"
        
        local lease_file=""
        if [ -f "/var/lib/misc/dnsmasq.leases" ]; then
            lease_file="/var/lib/misc/dnsmasq.leases"
        else
            lease_file=$(ls /var/lib/NetworkManager/dnsmasq-*.leases 2>/dev/null | head -n 1)
        fi
        
        local clients_found=0
        if [[ -n "$lease_file" && -f "$lease_file" ]]; then
            while read -r time mac ip host clid; do
                [[ -z "$ip" ]] && continue
                [[ "$host" == "*" ]] && host="Unknown"
                printf "|  %-15s %-15s %-20s |\n" "$ip" "${host:0:15}" "$mac"
                clients_found=$((clients_found + 1))
            done < "$lease_file"
        fi
        
        if [ $clients_found -eq 0 ]; then
            echo -e "|  \033[0;31mNo connected clients found.\033[0m                              |"
        fi
        
        # Padding to overwrite previous UI remnants
        for i in {1..7}; do echo "|                                                          |"; done
        
        echo -e "\033[1;36m+----------------------------------------------------------+\033[0m"
        echo -e "   [Q] Exit Monitor"
        
    done
    tput cnorm
}

# --- Dashboard Function (Refactored) ---
show_dashboard() {
    local status=$(get_current_status)
    local ssid=$(get_current_ssid)
    local ip=$(get_current_ip)
    local uptime=$(get_uptime)

    local HEADER="Mode: $status | SSID: $ssid | IP: $ip    [Uptime: $uptime]"

    whiptail --title " PiWAN Dashboard v$VERSION " --nocancel --menu "$HEADER" 16 65 7 \
        "1" "Configure Router Modes" \
        "2" "Live Traffic Monitor" \
        "3" "Manage Snapshots" \
        "4" "Toggle Autostart Settings" \
        "5" "Factory Reset NM Connections" \
        "R" "Refresh Dashboard" \
        "0" "Exit PiWAN" \
        2>/tmp/piwan_choice.tmp
}

# --- Main Loop ---

while true; do
    show_dashboard
    RET=$?
    CHOICE=$(cat /tmp/piwan_choice.tmp 2>/dev/null)
    
    # Text Fallback if whiptail crashes
    if [ $RET -ne 0 ] && [ -z "$CHOICE" ]; then
        clear
        echo -e "\033[0;31m[!] Whiptail GUI failed to draw. Terminal size issues.\033[0m"
        echo "Switching to pure text mode fallback:"
        echo ""
        echo "1) Configure Router"
        echo "2) Live Traffic Monitor"
        echo "3) Manage Snapshots"
        echo "4) Toggle Autostart Settings"
        echo "5) Factory Reset"
        echo "R) Refresh"
        echo "0) Exit"
        echo ""
        read -p "Select option: " CHOICE
    fi
    
    case "$CHOICE" in
        1)
            configure_router
            ;;
        2)
            start_monitor
            ;;
        3)
            manage_snapshots
            ;;
        4)
            whiptail --title " Autostart " --msgbox "Autostart is inherently handled by NetworkManager.\nAny mode you select (AP, WISP, LAN) is saved persistently and will start automatically upon a reboot of the Raspberry Pi." 12 55
            ;;
        5)
            if whiptail --title " Factory Reset " --yesno "Are you sure you want to delete all PiWAN profiles and clear the network?" 10 50; then
                {
                    echo 50
                    delete_piwan_connections
                    echo 100
                    sleep 1
                } | whiptail --title " Reset " --gauge "Deleting network profiles..." 6 50 0
                whiptail --title " Success " --msgbox "Network has been reset to defaults." 10 50
            fi
            ;;
        R|r)
            sleep 0.1 
            ;;
        0)
            break
            ;;
        *)
            echo "Unexpected output from whiptail: '$CHOICE'"
            break
            ;;
    esac
done

echo "=== PiWAN exited ==="
echo "Debug Info: whiptail returned code $RET."
echo "If this is 1, it means 'Cancel' or 'Esc' was pressed."
echo "If it is something else, whiptail encountered a syntax error."
