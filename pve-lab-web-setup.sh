#!/usr/bin/env bash
# pve-lab-web-setup.sh - pve-lab menu in a browser (ttyd) on a Rocky Linux 9 container
#
# Run INSIDE the container as root, with the IPs of your Proxmox nodes:
#     ./pve-lab-web-setup.sh 192.168.77.77 192.168.77.78
#
# Result: https://<container-ip>:7681  ->  login  ->  the pve-lab menu
set -euo pipefail

NODES=("$@")
PORT=${PORT:-7681}
SVC_USER=pvelab
HOME_DIR=/var/lib/pve-lab-web
CONF=/etc/pve-lab-web
TTYD_VERSION=1.7.7

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
((${#NODES[@]})) || { echo "Usage: $0 <node-ip> [node-ip ...]"; exit 1; }

echo "== Packages"
dnf -y install openssh-clients openssl ncurses
if ! command -v ttyd >/dev/null; then
    dnf -y install epel-release && dnf -y install ttyd || true
fi
if ! command -v ttyd >/dev/null; then
    echo "ttyd not in EPEL - downloading the release binary $TTYD_VERSION"
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/$TTYD_VERSION/ttyd.$(uname -m)" -o /usr/local/bin/ttyd
    chmod 755 /usr/local/bin/ttyd
fi
TTYD=$(command -v ttyd)
echo "Using $TTYD ($($TTYD --version))"

echo "== Service user and SSH key"
id "$SVC_USER" &>/dev/null || useradd -r -m -d "$HOME_DIR" -s /sbin/nologin "$SVC_USER"
install -d -m 700 -o "$SVC_USER" -g "$SVC_USER" "$HOME_DIR/.ssh"
[[ -f $HOME_DIR/.ssh/id_ed25519 ]] ||
    runuser -u "$SVC_USER" -- ssh-keygen -q -t ed25519 -N "" -C "pve-lab-web" -f "$HOME_DIR/.ssh/id_ed25519"
for n in "${NODES[@]}"; do
    ssh-keyscan -T 5 "$n" 2>/dev/null >>"$HOME_DIR/.ssh/known_hosts" || echo "WARNING: can't reach $n"
done
sort -u -o "$HOME_DIR/.ssh/known_hosts" "$HOME_DIR/.ssh/known_hosts"
chown "$SVC_USER:$SVC_USER" "$HOME_DIR/.ssh/known_hosts"

echo "== Web login"
mkdir -p "$CONF"
if [[ ! -f $CONF/credentials ]]; then
    read -rp "Web login user name [admin]: " u </dev/tty
    u=${u:-admin}
    while :; do
        read -rsp "Web login password: " p1 </dev/tty; echo
        read -rsp "Repeat password: " p2 </dev/tty; echo
        [[ -n $p1 && $p1 == "$p2" && $p1 != *:* ]] && break
        echo "Passwords empty, different or contain ':' - try again."
    done
    printf 'TTYD_CRED=%s:%s\n' "$u" "$p1" >"$CONF/credentials"
    chmod 600 "$CONF/credentials"
fi

echo "== TLS certificate (self-signed)"
if [[ ! -f $CONF/cert.pem ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=pve-lab-web" \
        -keyout "$CONF/key.pem" -out "$CONF/cert.pem" 2>/dev/null
fi
chown root:"$SVC_USER" "$CONF/key.pem" "$CONF/cert.pem"
chmod 640 "$CONF/key.pem"

echo "== Launcher"
printf '%s\n' "${NODES[@]}" >"$CONF/nodes"
cat >/usr/local/bin/pve-lab-web <<'EOF'
#!/usr/bin/env bash
# Opens the pve-lab menu on the first Proxmox node that answers.
mapfile -t NODES </etc/pve-lab-web/nodes
while :; do
    clear
    for n in "${NODES[@]}"; do
        ssh -t -o BatchMode=yes -o ConnectTimeout=4 "root@$n"
        rc=$?
        ((rc != 255)) && break        # 255 = couldn't connect, try the next node
        echo "Can't reach $n - trying the next node..."
        sleep 1
    done
    ((rc == 255)) && echo "No Proxmox node reachable (${NODES[*]})."
    echo
    read -rp "Press Enter to open the pve-lab menu again " _
done
EOF
chmod 755 /usr/local/bin/pve-lab-web

echo "== systemd service"
cat >/etc/systemd/system/pve-lab-web.service <<EOF
[Unit]
Description=pve-lab menu in the browser (ttyd)
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
EnvironmentFile=$CONF/credentials
ExecStart=$TTYD --port $PORT --writable --max-clients 5 \\
    --ssl --ssl-cert $CONF/cert.pem --ssl-key $CONF/key.pem \\
    --credential \${TTYD_CRED} \\
    -t titleFixed=pve-lab -t fontSize=15 -t disableLeaveAlert=true \\
    /usr/local/bin/pve-lab-web
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now pve-lab-web
if systemctl is-active -q firewalld; then
    firewall-cmd -q --permanent --add-port="$PORT/tcp" && firewall-cmd -q --reload
fi

IP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
cat <<EOF

=====================================================================
 Done. One step left - on ANY Proxmox node, run this ONE line
 (the cluster shares root's authorized_keys, so all nodes get it):

echo 'from="$IP",restrict,pty,command="env EDITOR=rnano /usr/local/bin/pve-lab" $(cat "$HOME_DIR/.ssh/id_ed25519.pub")' >>/etc/pve/priv/authorized_keys

 This key can ONLY open the pve-lab menu - no shell, no other commands.

 Then browse from the jumpbox to:   https://$IP:$PORT
=====================================================================
EOF
