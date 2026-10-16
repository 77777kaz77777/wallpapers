#!/usr/bin/env bash
# pve-lab-web-login.sh - replace the browser pop-up login with a login inside the terminal
# Run INSIDE the pve-lab-web container as root:   bash pve-lab-web-login.sh
set -euo pipefail
CONF=/etc/pve-lab-web
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -f /etc/systemd/system/pve-lab-web.service ]] || { echo "Run pve-lab-web-setup.sh first."; exit 1; }

read -rp "Login name [admin]: " u
u=${u:-admin}
while :; do
    read -rsp "New password: " p1; echo
    read -rsp "Repeat password: " p2; echo
    [[ ${#p1} -ge 8 && $p1 == "$p2" ]] && break
    echo "Passwords differ or are shorter than 8 characters - try again."
done
# Only a salted SHA-512 hash is stored, never the password
printf '%s:%s\n' "$u" "$(printf '%s' "$p1" | openssl passwd -6 -stdin)" >"$CONF/login"
chown root:pvelab "$CONF/login"
chmod 640 "$CONF/login"

cat >/usr/local/bin/pve-lab-web <<'EOF'
#!/usr/bin/env bash
# Login, then open the pve-lab menu on the first Proxmox node that answers.
IFS=: read -r USER_OK HASH </etc/pve-lab-web/login
SALT=$(cut -d'$' -f3 <<<"$HASH")
clear
echo "pve-lab - sign in"
for try in 1 2 3; do
    read -rp "Login: " u
    read -rsp "Password: " p; echo
    if [[ $u == "$USER_OK" && $(printf '%s' "$p" | openssl passwd -6 -salt "$SALT" -stdin) == "$HASH" ]]; then
        ok=1; break
    fi
    sleep 2
    echo "Wrong login."
done
[[ ${ok:-0} == 1 ]] || { echo "Too many attempts - reload the page to try again."; sleep 5; exit 1; }

mapfile -t NODES </etc/pve-lab-web/nodes
while :; do
    clear
    for n in "${NODES[@]}"; do
        ssh -t -o BatchMode=yes -o ConnectTimeout=4 "root@$n"
        rc=$?
        ((rc != 255)) && break
        echo "Can't reach $n - trying the next node..."
        sleep 1
    done
    ((rc == 255)) && echo "No Proxmox node reachable (${NODES[*]})."
    echo
    read -rp "Press Enter to open the pve-lab menu again " _
done
EOF
chmod 755 /usr/local/bin/pve-lab-web

# Drop the browser pop-up login (and the plain-text password file it needed)
sed -i '/--credential/d; /^EnvironmentFile=/d' /etc/systemd/system/pve-lab-web.service
rm -f "$CONF/credentials"
systemctl daemon-reload
systemctl restart pve-lab-web
echo "Done. Reload https://<container-ip>:7681 - the login is now inside the page."
