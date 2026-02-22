#!/bin/bash

# --- Colors ---
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

TELEGRAM_CONF="/etc/tunnel_telegram.conf"
HEALER_SCRIPT="/usr/local/bin/tunnel_healer.sh"
HAPROXY_CONF="/etc/haproxy/haproxy.cfg"

# --- 1. Optimization ---
optimize_system() {
    echo -e "${YELLOW}[*] Optimizing System & BBR...${NC}"
    cat <<EOF > /etc/sysctl.d/99-gre-pro.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.ipv4.conf.all.proxy_arp=1
EOF
    sysctl --system > /dev/null 2>&1
}

# --- 2. GRE Core (Manual IP - Sepehr Logic) ---
setup_gre_tunnel() {
    optimize_system
    apt update && apt install -y iproute2 iptables-persistent net-tools curl
    
    echo -e "\n${CYAN}--- GRE TUNNEL SETUP ---${NC}"
    read -p "Enter Local IP (Internal IP of THIS server): " LOCAL_IP
    read -p "Enter Remote IP (Public IP of OPPOSITE server): " REMOTE_IP
    
    echo -e "\n1) Kharej (Destination)\n2) Iran (Forwarder)"
    read -p "Role: " role

    ip link delete gre1 2>/dev/null

    if [ "$role" == "1" ]; then
        ip tunnel add gre1 mode gre local $LOCAL_IP remote $REMOTE_IP ttl 255
        ip addr add 192.168.168.1/30 dev gre1
        ip link set gre1 up
        echo -e "${GREEN}✔ Kharej GRE Ready (192.168.168.1)${NC}"
    else
        ip tunnel add gre1 mode gre local $LOCAL_IP remote $REMOTE_IP ttl 255
        ip addr add 192.168.168.2/30 dev gre1
        ip link set gre1 up
        echo -e "${GREEN}✔ Iran GRE Ready (192.168.168.2)${NC}"
    fi
}

# --- 3. HAProxy Manager ---
manage_haproxy() {
    if [ ! -f "$HAPROXY_CONF" ]; then
        echo -e "${YELLOW}[*] Installing HAProxy...${NC}"
        apt update && apt install -y haproxy
        cat <<EOF > $HAPROXY_CONF
global
    ulimit-n  51200
defaults
    mode    tcp
    timeout connect 5s
    timeout client  1m
    timeout server  1m
EOF
        systemctl enable --now haproxy
    fi

    echo -e "\n${CYAN}--- HAProxy Port Forwarding ---${NC}"
    read -p "Enter Port(s) to Forward (comma separated, e.g. 80,443): " PORTS
    IFS=',' read -ra ADDR <<< "$PORTS"
    for port in "${ADDR[@]}"; do
        if ! grep -q "listen port_$port" "$HAPROXY_CONF"; then
            cat <<EOF >> $HAPROXY_CONF
listen port_$port
    bind *:$port
    server srv1 192.168.168.1:$port maxconn 2048
EOF
            echo -e "${GREEN}✔ Port $port added.${NC}"
        else
            echo -e "${YELLOW}✔ Port $port already exists.${NC}"
        fi
    done
    systemctl restart haproxy
}

# --- 4. Telegram & Healer ---
setup_monitor() {
    echo -e "\n${CYAN}--- Telegram & Healer Setup ---${NC}"
    read -p "Bot Token: " BTN
    read -p "Chat ID: " CID
    read -p "Worker/Proxy URL (Enter to skip): " W_URL
    TG_BASE="https://api.telegram.org"
    [ -n "$W_URL" ] && TG_BASE="https://$(echo $W_URL | sed 's|https://||g')"

    echo "TOKEN=$BTN" > $TELEGRAM_CONF
    echo "CHATID=$CID" >> $TELEGRAM_CONF
    echo "TG_URL=$TG_BASE" >> $TELEGRAM_CONF

    cat <<'EOF' > $HEALER_SCRIPT
#!/bin/bash
source /etc/tunnel_telegram.conf
TARGET="192.168.168.1"; ip addr show | grep -q "192.168.168.1" && TARGET="192.168.168.2"

if ! ping -c 2 -W 3 $TARGET > /dev/null 2>&1; then
    ip link set gre1 down && sleep 1 && ip link set gre1 up
    [ -n "$TOKEN" ] && curl -sk -X POST "$TG_URL/bot$TOKEN/sendMessage" -d "chat_id=$CHATID" -d "text=🚨 GRE Tunnel Healed on $(hostname)" >/dev/null
fi
EOF
    chmod +x $HEALER_SCRIPT
    (crontab -l 2>/dev/null | grep -v "tunnel_healer.sh"; echo "* * * * * $HEALER_SCRIPT") | crontab -
    echo -e "${GREEN}✔ Healer & Telegram Active.${NC}"
}

# --- Main Menu ---
while true; do
clear
echo -e "${CYAN}==================================${NC}"
echo -e "${WHITE}    YS-GRE PRO (SEPEHR EDITION)   ${NC}"
echo -e "${CYAN}==================================${NC}"
echo "1) Setup GRE Tunnel"
echo "2) Add Ports (HAProxy)"
echo "3) Setup Monitor (Telegram/Healer)"
echo "4) Show Status"
echo "5) Uninstall & Reset"
echo "6) Exit"
read -p "Select: " opt

case $opt in
    1) setup_gre_tunnel; read -p "Press Enter..." ;;
    2) manage_haproxy; read -p "Press Enter..." ;;
    3) setup_monitor; read -p "Press Enter..." ;;
    4) 
       echo -e "${YELLOW}--- Interface ---${NC}"
       ip addr show gre1 2>/dev/null || echo "GRE Down"
       echo -e "${YELLOW}--- Tunnel Ping ---${NC}"
       ping -c 2 192.168.168.1 2>/dev/null || ping -c 2 192.168.168.2
       read -p "Press Enter..." ;;
    5) 
       ip link delete gre1 2>/dev/null; apt purge haproxy -y; 
       crontab -l | grep -v "tunnel_healer.sh" | crontab -;
       rm -f $HEALER_SCRIPT $TELEGRAM_CONF /etc/sysctl.d/99-gre-pro.conf;
       echo "Everything removed."; sleep 2 ;;
    6) exit 0 ;;
esac
done
