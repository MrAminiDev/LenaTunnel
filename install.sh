#!/bin/bash

# ---------------- COLORS ----------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ---------------- CHECK ROOT ----------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}[!] This script must be run as root.${NC}"
    echo -e "${YELLOW}[!] Please use 'sudo' or switch to root user.${NC}"
    exit 1
fi

# ---------------- INSTALL DEPENDENCIES ----------------
echo -e "${YELLOW}[*] Updating package list...${NC}"
apt-get update -y -qq

for pkg in iproute2 net-tools grep awk iputils-ping jq curl iptables; do
    if ! command -v $pkg &> /dev/null; then
        echo -e "${YELLOW}[*] Installing $pkg...${NC}"
        apt-get install -y -qq $pkg
    fi
done


# ---------------- FUNCTIONS ----------------

check_core_status() {
    ip link show | grep -q 'vxlan' && echo "Active" || echo "Inactive"
}

Lena_menu() {
    clear
    SERVER_IP=$(hostname -I | awk '{print $1}')
    SERVER_COUNTRY=$(curl -sS "http://ip-api.com/json/$SERVER_IP" | jq -r '.country')
    SERVER_ISP=$(curl -sS "http://ip-api.com/json/$SERVER_IP" | jq -r '.isp')

    echo "+-------------------------------------------------------------------------+"
    echo "| _                      									|"
    echo "|| |                     									|"
    echo "|| |     ___ _ __   __ _ 									|"
    echo "|| |    / _ \ '_ \ / _  |									|"
    echo "|| |___|  __/ | | | (_| |									|"
    echo "|\_____/\___|_| |_|\__,_|	V1.0.0			            |"
    echo "+-------------------------------------------------------------------------+"
    echo -e "| Telegram Channel : ${MAGENTA}@AminiDev ${NC}| Version : ${GREEN} 1.0.0 ${NC} "
    echo "+-------------------------------------------------------------------------+"
    echo -e "|${GREEN}Server Country    |${NC} $SERVER_COUNTRY"
    echo -e "|${GREEN}Server IP         |${NC} $SERVER_IP"
    echo -e "|${GREEN}Server ISP        |${NC} $SERVER_ISP"
    echo "+-------------------------------------------------------------------------+"
    echo -e "|${YELLOW}Please choose an option:${NC}"
    echo "+-------------------------------------------------------------------------+"
    echo -e "1- Install new tunnel"
    echo -e "2- Uninstall tunnel(s)"
    echo -e "3- Install BBR"
    echo -e "4- Cronjob settings"
    echo -e "0- Exit"
    echo "+-------------------------------------------------------------------------+"
    echo -e "\033[0m"
}

uninstall_all_vxlan() {
    echo "[!] Deleting all VXLAN interfaces and cleaning up..."
    for i in $(ip -d link show | grep -o 'vxlan[0-9]\+'); do
        ip link del $i 2>/dev/null
    done

    systemctl stop haproxy vxlan-tunnel 2>/dev/null
    systemctl disable haproxy vxlan-tunnel 2>/dev/null

    rm -f /usr/local/bin/vxlan_bridge.sh /etc/ping_vxlan.sh /etc/systemd/system/vxlan-tunnel.service

    systemctl daemon-reload

    # Remove HAProxy package
    apt remove -y haproxy -qq
    apt purge -y haproxy -qq
    apt autoremove -y 2>/dev/null

    # Remove related cronjobs
    crontab -l 2>/dev/null | grep -v 'systemctl restart haproxy' | grep -v 'systemctl restart vxlan-tunnel' | grep -v '/etc/ping_vxlan.sh' > /tmp/cron_tmp || true
    crontab /tmp/cron_tmp
    rm /tmp/cron_tmp
    echo "[+] All VXLAN tunnels and related cronjobs deleted."
}

install_bbr() {
    echo "Running BBR script..."
    curl -fsSLk https://raw.githubusercontent.com/MrAminiDev/NetOptix/main/scripts/bbr.sh | bash
}

install_haproxy_and_configure() {
    echo "[*] Configuring HAProxy..."

    # Ensure haproxy is installed
    if ! command -v haproxy >/dev/null 2>&1; then
        echo "[x] HAProxy is not installed. Installing..."
        apt update -qq && apt install -y haproxy -qq
    fi

    # Ensure config directory exists
    mkdir -p /etc/haproxy

    # Default HAProxy config file
    local CONFIG_FILE="/etc/haproxy/haproxy.cfg"
    local BACKUP_FILE="/etc/haproxy/haproxy.cfg.bak"

    # Backup old config
    [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$BACKUP_FILE"

    # Write base config
    cat <<EOL > "$CONFIG_FILE"
global
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 4096

defaults
    mode    tcp
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms
    retries 3
    option  tcpka
EOL

    read -p "Enter ports (comma-separated): " user_ports
    local local_ip=$(hostname -I | awk '{print $1}')

    IFS=',' read -ra ports <<< "$user_ports"

    for port in "${ports[@]}"; do
        cat <<EOL >> "$CONFIG_FILE"

frontend frontend_$port
    bind *:$port
    default_backend backend_$port
    option tcpka

backend backend_$port
    option tcpka
    server server1 $local_ip:$port check maxconn 2048
EOL
    done

    # Validate haproxy config
    if haproxy -c -f "$CONFIG_FILE"; then
        echo "[*] Restarting HAProxy service..."
        systemctl enable haproxy && systemctl restart haproxy
        echo -e "${GREEN}HAProxy configured and restarted successfully.${NC}"
    else
        echo -e "${YELLOW}Warning: HAProxy configuration is invalid!${NC}"
    fi
}

# ---------------- MAIN ----------------
while true; do
    Lena_menu
    read -p "Enter your choice [0-4]: " main_action
    case $main_action in
        0)
            echo "Exiting..."
            exit 0
            ;;
        1)
            break
            ;;
        2)
            uninstall_all_vxlan
            read -p "Press Enter to return to menu..."
            ;;
        3)
            install_bbr
            read -p "Press Enter to return to menu..."
            ;;
        4)
            while true; do
                clear
                echo "+-----------------------------+"
                echo "|      Cronjob settings       |"
                echo "+-----------------------------+"
                echo "1- Install cronjob"
                echo "2- Edit cronjob"
                echo "3- Delete cronjob"
                echo "4- Back to main menu"
                read -p "Enter your choice [1-4]: " cron_action
                case $cron_action in
                    1)
                        while true; do
                            read -p "How many hours between each restart? (1-24, b=Back): " cron_hours
                            if [[ "$cron_hours" == "b" || "$cron_hours" == "B" ]]; then
                                break
                            elif [[ $cron_hours =~ ^[0-9]+$ ]] && (( cron_hours >= 1 && cron_hours <= 24 )); then
                                # Remove any previous cronjobs for these services
                                crontab -l 2>/dev/null | grep -v 'systemctl restart haproxy' | grep -v 'systemctl restart vxlan-tunnel' > /tmp/cron_tmp || true
                                echo "0 */$cron_hours * * * systemctl restart haproxy >/dev/null 2>&1" >> /tmp/cron_tmp
                                echo "0 */$cron_hours * * * systemctl restart vxlan-tunnel >/dev/null 2>&1" >> /tmp/cron_tmp
                                crontab /tmp/cron_tmp
                                rm /tmp/cron_tmp
                                echo -e "${GREEN}Cronjob set successfully to restart haproxy and vxlan-tunnel every $cron_hours hour(s).${NC}"
                                read -p "Press Enter to return to Cronjob settings..."
                                break
                            else
                                echo "Invalid input. Please enter a number between 1 and 24 or 'b' to go back."
                            fi
                        done
                        ;;
                    2)
                        if crontab -l 2>/dev/null | grep -q 'systemctl restart haproxy'; then
                            while true; do
                                read -p "Enter new hours for cronjob (1-24, b=Back): " new_cron_hours
                                if [[ "$new_cron_hours" == "b" || "$new_cron_hours" == "B" ]]; then
                                    break
                                elif [[ $new_cron_hours =~ ^[0-9]+$ ]] && (( new_cron_hours >= 1 && new_cron_hours <= 24 )); then
                                    crontab -l 2>/dev/null | grep -v 'systemctl restart haproxy' | grep -v 'systemctl restart vxlan-tunnel' > /tmp/cron_tmp || true
                                    echo "0 */$new_cron_hours * * * systemctl restart haproxy >/dev/null 2>&1" >> /tmp/cron_tmp
                                    echo "0 */$new_cron_hours * * * systemctl restart vxlan-tunnel >/dev/null 2>&1" >> /tmp/cron_tmp
                                    crontab /tmp/cron_tmp
                                    rm /tmp/cron_tmp
                                    echo -e "${GREEN}Cronjob updated successfully to every $new_cron_hours hour(s).${NC}"
                                    read -p "Press Enter to return to Cronjob settings..."
                                    break
                                else
                                    echo "Invalid input. Please enter a number between 1 and 24 or 'b' to go back."
                                fi
                            done
                        else
                            echo -e "${YELLOW}No cronjob found to edit. Please install first.${NC}"
                            read -p "Press Enter to return to Cronjob settings..."
                        fi
                        ;;
                    3)
                        if crontab -l 2>/dev/null | grep -q 'systemctl restart haproxy'; then
                            crontab -l 2>/dev/null | grep -v 'systemctl restart haproxy' | grep -v 'systemctl restart vxlan-tunnel' > /tmp/cron_tmp || true
                            crontab /tmp/cron_tmp
                            rm /tmp/cron_tmp
                            echo -e "${GREEN}Cronjob deleted successfully.${NC}"
                        else
                            echo -e "${YELLOW}No cronjob found to delete.${NC}"
                        fi
                        read -p "Press Enter to return to Cronjob settings..."
                        ;;
                    4)
                        break
                        ;;
                    *)
                        echo "[x] Invalid option. Try again."
                        sleep 1
                        ;;
                esac
            done
            ;;
        *)
            echo "[x] Invalid option. Try again."
            sleep 1
            ;;
    esac
done

# Check if ip command is available
if ! command -v ip >/dev/null 2>&1; then
    echo "[x] iproute2 is not installed. Aborting."
    exit 1
fi

# ------------- VARIABLES --------------
VNI=88
VXLAN_IF="vxlan${VNI}"

# --------- Choose Server Role ----------
echo "Choose server role:"
echo "1- Iran"
echo "2- Kharej"
read -p "Enter choice (1/2): " role_choice

if [[ "$role_choice" == "1" ]]; then
    read -p "Enter IRAN IP: " IRAN_IP
    read -p "Enter Kharej IP: " KHAREJ_IP

    # Port validation loop
    while true; do
        read -p "Tunnel port (1 ~ 64435): " DSTPORT
        if [[ $DSTPORT =~ ^[0-9]+$ ]] && (( DSTPORT >= 1 && DSTPORT <= 64435 )); then
            break
        else
            echo "Invalid port. Try again."
        fi
    done

    # Strict input validation for haproxy_choice
    while true; do
        read -p "Should port forwarding be done automatically? (It is done with haproxy tool) [1-yes, 2-no]: " haproxy_choice
        if [[ "$haproxy_choice" == "1" || "$haproxy_choice" == "2" ]]; then
            break
        else
            echo "Please enter 1 (yes) or 2 (no)."
        fi
    done
    if [[ "$haproxy_choice" == "1" ]]; then
        install_haproxy_and_configure
    else
        ipv4_local=$(hostname -I | awk '{print $1}')
        echo "IRAN Server setup complete."
        echo -e "####################################"
        echo -e "# Your IPv4 :                      #"
        echo -e "#  30.0.0.1                     #"
        echo -e "####################################"
    fi

    VXLAN_IP="30.0.0.1/24"
    REMOTE_IP=$KHAREJ_IP

elif [[ "$role_choice" == "2" ]]; then
    read -p "Enter IRAN IP: " IRAN_IP
    read -p "Enter Kharej IP: " KHAREJ_IP

    # Port validation loop
    while true; do
        read -p "Tunnel port (1 ~ 64435): " DSTPORT
        if [[ $DSTPORT =~ ^[0-9]+$ ]] && (( DSTPORT >= 1 && DSTPORT <= 64435 )); then
            break
        else
            echo "Invalid port. Try again."
        fi
    done

    ipv4_local=$(hostname -I | awk '{print $1}')
    echo "Kharej Server setup complete."
    echo -e "####################################"
    echo -e "# Your IPv4 :                      #"
    echo -e "#  30.0.0.2                        #"
    echo -e "####################################"

    VXLAN_IP="30.0.0.2/24"
    REMOTE_IP=$IRAN_IP

else
    echo "[x] Invalid role selected."
    exit 1
fi

# Detect default interface
INTERFACE=$(ip route get 1.1.1.1 | awk '{print $5}' | head -n1)
echo "Detected main interface: $INTERFACE"

# ------------ Setup VXLAN --------------
echo "[+] Creating VXLAN interface..."
ip link add $VXLAN_IF type vxlan id $VNI local $(hostname -I | awk '{print $1}') remote $REMOTE_IP dev $INTERFACE dstport $DSTPORT nolearning

echo "[+] Assigning IP $VXLAN_IP to $VXLAN_IF"
ip addr add $VXLAN_IP dev $VXLAN_IF
ip link set $VXLAN_IF up

echo "[+] Adding iptables rules"
iptables -I INPUT 1 -p udp --dport $DSTPORT -j ACCEPT
iptables -I INPUT 1 -s $REMOTE_IP -j ACCEPT
iptables -I INPUT 1 -s ${VXLAN_IP%/*} -j ACCEPT

# ---------------- CREATE SYSTEMD SERVICE ----------------
echo "[+] Creating systemd service for VXLAN..."

cat <<EOF > /usr/local/bin/vxlan_bridge.sh
#!/bin/bash
ip link add $VXLAN_IF type vxlan id $VNI local $(hostname -I | awk '{print $1}') remote $REMOTE_IP dev $INTERFACE dstport $DSTPORT nolearning
ip addr add $VXLAN_IP dev $VXLAN_IF
ip link set $VXLAN_IF up
# Persistent keepalive: ping remote every 30s in background
( while true; do ping -c 1 $REMOTE_IP >/dev/null 2>&1; sleep 30; done ) &
EOF

chmod +x /usr/local/bin/vxlan_bridge.sh

cat <<EOF > /etc/systemd/system/vxlan-tunnel.service
[Unit]
Description=VXLAN Tunnel Interface
After=network.target

[Service]
ExecStart=/usr/local/bin/vxlan_bridge.sh
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

chmod 644 /etc/systemd/system/vxlan-tunnel.service
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable vxlan-tunnel.service
systemctl start vxlan-tunnel.service

echo -e "\n${GREEN}[✓] VXLAN tunnel service enabled to run on boot.${NC}"

echo "[✓] VXLAN tunnel setup completed successfully."
