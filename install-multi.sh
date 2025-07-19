#!/bin/bash

# -------- CONFIGURABLE SECTION ---------
IRAN_SERVERS=(
  "192.168.1.1"   # Sample Iran 1
  "192.168.1.2"   # Sample Iran 2
  # "IRAN_2"
  # ...
)

KHAREJ_SERVERS=(
  "8.8.8.8"   # Sample Kharej 1
  "8.8.4.4"   # Sample Kharej 2
  # "KHAREJ_2"
  # ...
)

VXLAN_BASE_PORT=10000
VXLAN_BASE_ID=10000
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo "[*] Local IP is: $LOCAL_IP"

# Detect role
ROLE=""
IRAN_INDEX=0
KHAREJ_INDEX=0

for i in "${!IRAN_SERVERS[@]}"; do
  if [[ "$LOCAL_IP" == "${IRAN_SERVERS[$i]}" ]]; then
    ROLE="iran"
    IRAN_INDEX=$((i+1))
    break
  fi
done

if [[ -z "$ROLE" ]]; then
  for i in "${!KHAREJ_SERVERS[@]}"; do
    if [[ "$LOCAL_IP" == "${KHAREJ_SERVERS[$i]}" ]]; then
      ROLE="kharej"
      KHAREJ_INDEX=$((i+1))
      break
    fi
  done
fi

if [[ -z "$ROLE" ]]; then
  echo "[x] Cannot determine role for IP: $LOCAL_IP"
  exit 1
fi

echo "[*] Role detected: $ROLE"
echo "[*] Index: IRAN=$IRAN_INDEX, KHAREJ=$KHAREJ_INDEX"

# Dependencies
echo "[*] Installing dependencies..."
apt update -y && apt install -y iproute2 iputils-ping net-tools curl sudo iptables

INTERFACE=$(ip route get 1.1.1.1 | awk '{print $5}' | head -n1)
echo "[*] Detected interface: $INTERFACE"

# Loop over peers
for i in "${!IRAN_SERVERS[@]}"; do
  iran_ip="${IRAN_SERVERS[$i]}"
  iran_idx=$((i+1))
  for j in "${!KHAREJ_SERVERS[@]}"; do
    kharej_ip="${KHAREJ_SERVERS[$j]}"
    kharej_idx=$((j+1))

    PORT=$((iran_idx * VXLAN_BASE_ID + kharej_idx))
    VNI=$PORT
    VXLAN_IF="vxlan$VNI"

    if [[ "$ROLE" == "iran" && "$IRAN_INDEX" == "$iran_idx" ]]; then
      REMOTE_IP="$kharej_ip"
      VXLAN_LOCAL_IP="30.101.${iran_idx}.${kharej_idx}/24"
      VXLAN_REMOTE_IP="30.102.${iran_idx}.${kharej_idx}"
    elif [[ "$ROLE" == "kharej" && "$KHAREJ_INDEX" == "$kharej_idx" ]]; then
      REMOTE_IP="$iran_ip"
      VXLAN_LOCAL_IP="30.102.${iran_idx}.${kharej_idx}/24"
      VXLAN_REMOTE_IP="30.101.${iran_idx}.${kharej_idx}"
    else
      continue
    fi

    echo
    echo "===== Config for $VXLAN_IF ====="
    echo "[*] VNI: $VNI"
    echo "[*] Port: $PORT"
    echo "[*] Remote IP: $REMOTE_IP"
    echo "[*] VXLAN Local IP: $VXLAN_LOCAL_IP"
    echo "[*] VXLAN Remote IP: $VXLAN_REMOTE_IP"
    echo "================================"

    # Cleanup if exists
    ip link del $VXLAN_IF 2>/dev/null

    # Setup VXLAN
    echo "[*] Creating interface..."
    ip link add $VXLAN_IF type vxlan id $VNI local $LOCAL_IP remote $REMOTE_IP dev $INTERFACE dstport $PORT nolearning
    ip addr add $VXLAN_LOCAL_IP dev $VXLAN_IF
    ip link set $VXLAN_IF up
	REMOTE_IP_NO_MASK=${VXLAN_REMOTE_IP%/*}
	ip route add $REMOTE_IP_NO_MASK/32 dev $VXLAN_IF 2>/dev/null || echo "[!] Route for $REMOTE_IP_NO_MASK may already exist."


    # Firewall
    echo "[*] Adding iptables rules..."
    iptables -I INPUT -p udp --dport $PORT -j ACCEPT
    iptables -I INPUT -s $REMOTE_IP -j ACCEPT
    iptables -I INPUT -s ${VXLAN_LOCAL_IP%/*} -j ACCEPT

    # Persistent service
    SCRIPT_PATH="/usr/local/bin/$VXLAN_IF.sh"
    SERVICE_PATH="/etc/systemd/system/vxlan-$VXLAN_IF.service"

    echo "[*] Creating script $SCRIPT_PATH"
    cat <<EOF > $SCRIPT_PATH
#!/bin/bash
ip link add $VXLAN_IF type vxlan id $VNI local $LOCAL_IP remote $REMOTE_IP dev $INTERFACE dstport $PORT nolearning
ip addr add $VXLAN_LOCAL_IP dev $VXLAN_IF
ip link set $VXLAN_IF up
REMOTE_IP_NO_MASK=${VXLAN_REMOTE_IP%/*}
ip route add $REMOTE_IP_NO_MASK/32 dev $VXLAN_IF 2>/dev/null || echo "[!] Route for $REMOTE_IP_NO_MASK may already exist."

EOF

    chmod +x $SCRIPT_PATH

    echo "[*] Creating systemd service $SERVICE_PATH"
    cat <<EOF > $SERVICE_PATH
[Unit]
Description=VXLAN Tunnel $VXLAN_IF
After=network.target

[Service]
ExecStart=$SCRIPT_PATH
Type=simple
RemainAfterExit=yes
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable vxlan-$VXLAN_IF.service
    systemctl restart vxlan-$VXLAN_IF.service
  done
done

echo
echo "[✓] All VXLAN tunnels setup completed."