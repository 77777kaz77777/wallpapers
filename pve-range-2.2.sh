#!/usr/bin/env bash
# pve-range-web-setup.sh - the pve-range menu in a browser, on a Rocky Linux 9 container
#
# One script with everything: ttyd web terminal, per-user sign-in with 2FA, lock-out,
# sign-in log, idle sign-out and the dark theme. Safe to run again (keeps users/keys).
# Also upgrades an old "pve-lab-web" install in place.
#
# Run INSIDE the container as root:
#     bash pve-range-web-setup.sh                                 # re-run / upgrade (keeps the saved IPs)
set -euo pipefail

DATA=/var/lib/pve-range-web
SVC_USER=pverange
PORT=${PORT:-7681}
LOGIN_IDLE=${LOGIN_IDLE:-300}
MENU_IDLE=${MENU_IDLE:-900}
TTYD_VERSION=1.7.7
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

###############################################################################
# Upgrade from the old name (pve-lab-web)
###############################################################################
MIGRATED=0
if [[ -d /etc/pve-lab-web ]]; then
    echo "== Moving the old pve-lab-web install to pve-range-web"
    systemctl disable --now pve-lab-web 2>/dev/null || true
    rm -f /etc/systemd/system/pve-lab-web.service
    if id pvelab &>/dev/null && ! id "$SVC_USER" &>/dev/null; then
        usermod -l "$SVC_USER" pvelab
        groupmod -n "$SVC_USER" pvelab
    fi
    install -d -m 755 "$DATA" "$DATA/tls" "$DATA/ssh"
    [[ -f /var/lib/pve-lab-web/.ssh/id_ed25519 ]] && cp -a /var/lib/pve-lab-web/.ssh/. "$DATA/ssh/"
    [[ -f /var/lib/pve-lab-web/failures ]] && cp -a /var/lib/pve-lab-web/failures "$DATA/failures"
    [[ -f /etc/pve-lab-web/users ]] && cp -a /etc/pve-lab-web/users "$DATA/users"
    if [[ -f /etc/pve-lab-web/login && ! -s $DATA/users ]]; then
        IFS=: read -r u h </etc/pve-lab-web/login
        echo "$u:$h:" >"$DATA/users"
    fi
    for f in cert.pem key.pem; do [[ -f /etc/pve-lab-web/$f ]] && cp -a "/etc/pve-lab-web/$f" "$DATA/tls/$f"; done
    [[ -f /etc/pve-lab-web/nodes && ! -f $DATA/nodes ]] && cp /etc/pve-lab-web/nodes "$DATA/nodes"
    rm -rf /etc/pve-lab-web /var/lib/pve-lab-web /usr/local/bin/pve-lab-web /usr/local/sbin/pve-lab-web-users
    systemctl daemon-reload
    MIGRATED=1
fi

NODES=("$@")
if ((${#NODES[@]} == 0)) && [[ -s $DATA/nodes ]]; then mapfile -t NODES <"$DATA/nodes"; fi
((${#NODES[@]})) || { echo "Usage: $0 <node-ip> [node-ip ...]"; exit 1; }

###############################################################################
# Packages
###############################################################################
echo "== Packages"
rpm -q epel-release &>/dev/null || dnf -y install epel-release
dnf -y install openssh-clients openssl ncurses util-linux oathtool qrencode
if ! command -v ttyd >/dev/null; then dnf -y install ttyd || true; fi
TTYD=$(command -v ttyd || true)
if [[ -z $TTYD ]] || ! "$TTYD" --help 2>&1 | grep -q -- '--writable'; then
    echo "Getting ttyd $TTYD_VERSION from GitHub"
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/$TTYD_VERSION/ttyd.$(uname -m)" -o /usr/local/bin/ttyd
    chmod 755 /usr/local/bin/ttyd
    TTYD=/usr/local/bin/ttyd
fi
echo "Using $TTYD ($("$TTYD" --version))"

###############################################################################
# User, folders, SSH key, certificate
###############################################################################
echo "== Service user and data in $DATA"
id "$SVC_USER" &>/dev/null || useradd -r -M -d "$DATA/home" -s /sbin/nologin "$SVC_USER"
usermod -d "$DATA/home" "$SVC_USER" 2>/dev/null || true
install -d -o root -g "$SVC_USER" -m 750 "$DATA" "$DATA/tls"
install -d -o "$SVC_USER" -g "$SVC_USER" -m 700 "$DATA/ssh" "$DATA/home"
[[ -e $DATA/users ]] || : >"$DATA/users"
[[ -e $DATA/failures ]] || : >"$DATA/failures"
[[ -e $DATA/auth.log ]] || : >"$DATA/auth.log"
chown root:"$SVC_USER" "$DATA/users" && chmod 640 "$DATA/users"
chown "$SVC_USER:$SVC_USER" "$DATA/failures" "$DATA/auth.log" && chmod 600 "$DATA/failures" && chmod 640 "$DATA/auth.log"
chown -R "$SVC_USER:$SVC_USER" "$DATA/ssh"
printf '%s\n' "${NODES[@]}" >"$DATA/nodes"

NEW_KEY=0
if [[ ! -f $DATA/ssh/id_ed25519 ]]; then
    runuser -u "$SVC_USER" -- ssh-keygen -q -t ed25519 -N "" -C "pve-range-web" -f "$DATA/ssh/id_ed25519"
    NEW_KEY=1
fi
touch "$DATA/ssh/known_hosts"
for n in "${NODES[@]}"; do
    ssh-keygen -F "$n" -f "$DATA/ssh/known_hosts" >/dev/null ||
        ssh-keyscan -T 5 "$n" 2>/dev/null >>"$DATA/ssh/known_hosts" || echo "WARNING: can't reach $n"
done
chown "$SVC_USER:$SVC_USER" "$DATA/ssh/known_hosts"

if [[ ! -f $DATA/tls/cert.pem || ! -f $DATA/tls/key.pem ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=pve-range-web" \
        -keyout "$DATA/tls/key.pem" -out "$DATA/tls/cert.pem" 2>/dev/null
fi
chown root:"$SVC_USER" "$DATA/tls/cert.pem" "$DATA/tls/key.pem"
chmod 640 "$DATA/tls/key.pem"

###############################################################################
# Sign-in screen and user tool
###############################################################################
echo "== Sign-in screen and pve-range-web-users"
cat >/usr/local/bin/pve-range-web <<'LAUNCHER'
#!/usr/bin/env bash
# Sign-in, then the pve-range menu on the first Proxmox node that answers.
DATA=${DATA_DIR:-/var/lib/pve-range-web}
USERS=$DATA/users
FAILS=$DATA/failures
MAX_FAIL=${MAX_FAIL:-5}     # wrong sign-ins ...
LOCK_MIN=${LOCK_MIN:-10}    # ... within this many minutes lock everyone out for that long
IDLE=${LOGIN_IDLE:-300}     # seconds without input before signing out
say() {
    printf '%s pve-range-web: %s\n' "$(date '+%F %T')" "$*" >>"$DATA/auth.log" 2>/dev/null
    logger -t pve-range-web -- "$*" 2>/dev/null || true
}
A=$'\e[96m' B=$'\e[1;97m' D=$'\e[38;5;245m' R=$'\e[91m' G=$'\e[92m' Z=$'\e[0m'
banner() {
    clear
    printf '\n\n'
    printf '   %s╭──────────────────────────────────────────────╮%s\n' "$A" "$Z"
    printf '   %s│%s   %s▲  pve-range%s                               %s│%s\n' "$A" "$Z" "$B" "$Z" "$A" "$Z"
    printf '   %s│%s   %sProxmox range control%s                      %s│%s\n' "$A" "$Z" "$D" "$Z" "$A" "$Z"
    printf '   %s╰──────────────────────────────────────────────╯%s\n\n' "$A" "$Z"
    printf '   %sSign in to continue. All sign-ins are logged.%s\n\n' "$D" "$Z"
}
recent_failures() {
    local cut=$(($(date +%s) - LOCK_MIN * 60))
    awk -v c="$cut" '$1 >= c' "$FAILS" 2>/dev/null | wc -l
}
banner
if (($(recent_failures) >= MAX_FAIL)); then
    echo "   ${R}Too many wrong sign-ins. Try again in $LOCK_MIN minutes.${Z}"
    say "sign-in refused: locked out"
    sleep 10; exit 1
fi
ok=""
for try in 1 2 3; do
    read -t "$IDLE" -rp "   ${A}Login     ${Z} " u || exit 0
    read -t "$IDLE" -rsp "   ${A}Password  ${Z} " p || exit 0; echo
    line=""
    [[ $u =~ ^[A-Za-z0-9_.-]{1,32}$ ]] && line=$(awk -F: -v u="$u" '$1 == u {print; exit}' "$USERS")
    IFS=: read -r _ hash secret <<<"$line"
    [[ -n $hash ]] || hash='$6$nosuchuser$x'          # same amount of work for unknown names
    good=0
    if [[ -n $line && $(printf '%s' "$p" | openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$hash")" -stdin) == "$hash" ]]; then
        good=1
        if [[ -n $secret ]]; then
            read -t "$IDLE" -rp "   ${A}2FA code  ${Z} " code || exit 0
            [[ $code =~ ^[0-9]{6}$ ]] && oathtool --totp -b -w 1 "$secret" "$code" >/dev/null 2>&1 || good=0
        fi
    fi
    unset p
    if ((good)); then ok=$u; break; fi
    date +%s >>"$FAILS"
    say "sign-in FAILED for '${u:0:32}' (try $try)"
    sleep 3
    echo "   ${R}✕ Wrong login.${Z}"; echo
    if (($(recent_failures) >= MAX_FAIL)); then echo "   ${R}Locked for $LOCK_MIN minutes.${Z}"; sleep 5; exit 1; fi
done
[[ -n $ok ]] || exit 1
say "sign-in OK: $ok"
echo; echo "   ${G}✔ Welcome, $ok${Z} - opening the menu..."; sleep 1

read -ra NODES <<<"$PVE_NODES"
while :; do
    clear
    for n in "${NODES[@]}"; do
        ssh -t -i "$DATA/ssh/id_ed25519" -o UserKnownHostsFile="$DATA/ssh/known_hosts" -o StrictHostKeyChecking=yes \
            -o BatchMode=yes -o ConnectTimeout=4 -o GSSAPIAuthentication=no -o AddressFamily=inet \
            -o SetEnv=LC_PVERANGE_USER="$ok" "root@$n"
        rc=$?
        ((rc != 255)) && break
        echo "Can't reach $n - trying the next node..."
        sleep 1
    done
    ((rc == 255)) && echo "No Proxmox node reachable (${NODES[*]})."
    echo
    read -t "$IDLE" -rp "   ${D}Press Enter to open the menu again (signs out after ${IDLE}s)${Z} " _ || break
done
say "signed out: $ok"
banner; echo "   ${D}Signed out. Reload the page to sign in again.${Z}"
LAUNCHER
chmod 755 /usr/local/bin/pve-range-web

cat >/usr/local/sbin/pve-range-web-users <<'USERTOOL'
#!/usr/bin/env bash
# pve-range-web-users - manage sign-ins for the pve-range browser menu
set -euo pipefail
F=${DATA_DIR:-/var/lib/pve-range-web}/users
FAILS=${DATA_DIR:-/var/lib/pve-range-web}/failures
usage() {
    cat <<USAGE
Usage: pve-range-web-users COMMAND [NAME]
  list                 show users and whether 2FA is on
  add NAME [--2fa]     create a user (asks for a password; --2fa also sets up a 2FA code)
  passwd NAME          change a user's password
  2fa NAME on|off      turn 2FA on (new QR code) or off
  del NAME             remove a user
  unlock               clear the lock-out after too many wrong sign-ins
USAGE
    exit 1
}
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
get()  { awk -F: -v u="$1" '$1 == u' "$F"; }
save() {   # name hash secret  (empty hash = delete)
    { awk -F: -v u="$1" '$1 != u' "$F"; [[ -n $2 ]] && echo "$1:$2:$3"; } >"$F.new"
    chown root:pverange "$F.new"; chmod 640 "$F.new"; mv "$F.new" "$F"
}
need_user() { [[ -n $(get "$1") ]] || { echo "No user '$1'."; exit 1; }; }
ask_pw() {
    local a b
    while :; do
        read -rsp "Password (min. 10 characters): " a; echo >&2
        read -rsp "Repeat password: " b; echo >&2
        [[ ${#a} -ge 10 && $a == "$b" ]] && break
        echo "Too short or not the same - try again." >&2
    done
    printf '%s' "$a" | openssl passwd -6 -stdin
}
new_2fa() {   # name -> prints secret after the user proved the app works
    local name=$1 secret code
    secret=$(head -c 20 /dev/urandom | base32 | tr -d '=')
    echo >&2
    echo "Scan this with an authenticator app (Google/Microsoft Authenticator, Aegis, ...):" >&2
    qrencode -t ANSIUTF8 "otpauth://totp/pve-range:$name?secret=$secret&issuer=pve-range" >&2
    echo "Or type the key by hand: $secret" >&2
    for _ in 1 2 3; do
        read -rp "Enter the 6-digit code the app shows: " code
        if [[ $code =~ ^[0-9]{6}$ ]] && oathtool --totp -b -w 1 "$secret" "$code" >/dev/null 2>&1; then
            echo "$secret"; return 0
        fi
        echo "That code doesn't match - check the phone's clock and try again." >&2
    done
    echo "2FA not set up." >&2; return 1
}
cmd=${1:-}; name=${2:-}
case $cmd in
    list)
        printf '%-20s %s\n' USER 2FA
        awk -F: '{printf "%-20s %s\n", $1, ($3 != "" ? "on" : "OFF")}' "$F"
        ;;
    add)
        [[ $name =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || { echo "Names: letters, digits, . _ - (max 32)."; exit 1; }
        [[ -z $(get "$name") ]] || { echo "User '$name' already exists."; exit 1; }
        h=$(ask_pw); s=""
        [[ ${3:-} == --2fa ]] && s=$(new_2fa "$name")   # 2FA is optional (off by default)
        save "$name" "$h" "$s"; echo "User '$name' added."
        ;;
    passwd)
        need_user "$name"
        s=$(get "$name" | cut -d: -f3)
        save "$name" "$(ask_pw)" "$s"; echo "Password changed."
        ;;
    2fa)
        need_user "$name"
        h=$(get "$name" | cut -d: -f2)
        case ${3:-} in
            on) save "$name" "$h" "$(new_2fa "$name")"; echo "2FA is on for '$name'." ;;
            off) save "$name" "$h" ""; echo "2FA is OFF for '$name'." ;;
            *) usage ;;
        esac
        ;;
    del) need_user "$name"; save "$name" "" ""; echo "User '$name' removed." ;;
    unlock) : >"$FAILS"; echo "Lock-out cleared." ;;
    *) usage ;;
esac
USERTOOL
chmod 700 /usr/local/sbin/pve-range-web-users

###############################################################################
# Service (ttyd with the dark theme)
###############################################################################
echo "== systemd service"
THEME='{"background":"#0f111a","foreground":"#c0caf5","cursor":"#7dcfff","selectionBackground":"#33467c","black":"#0f111a","red":"#f7768e","green":"#9ece6a","yellow":"#e0af68","blue":"#3d59a1","magenta":"#bb9af7","cyan":"#7dcfff","white":"#c0caf5","brightBlack":"#1f2335","brightRed":"#ff7a93","brightGreen":"#b9f27c","brightYellow":"#ff9e64","brightBlue":"#7aa2f7","brightMagenta":"#bb9af7","brightCyan":"#2ac3de","brightWhite":"#ffffff"}'
cat >/etc/systemd/system/pve-range-web.service <<EOF
[Unit]
Description=pve-range menu in the browser (ttyd)
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
Environment=LANG=C.UTF-8
Environment=HOME=$DATA/home
Environment=DATA_DIR=$DATA
Environment="PVE_NODES=${NODES[*]}"
Environment=LOGIN_IDLE=$LOGIN_IDLE
ExecStart=$TTYD --port $PORT --writable --max-clients 5 \\
    --ssl --ssl-cert $DATA/tls/cert.pem --ssl-key $DATA/tls/key.pem \\
    -t titleFixed=pve-range -t fontSize=16 -t lineHeight=1.15 -t cursorStyle=bar -t disableLeaveAlert=true -t enableZmodem=true \\
    "-t" "fontFamily=Cascadia Mono, JetBrains Mono, Fira Code, DejaVu Sans Mono, Consolas, monospace" \\
    -t 'theme=$THEME' \\
    /usr/local/bin/pve-range-web
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable pve-range-web >/dev/null
systemctl restart pve-range-web
if systemctl is-active -q firewalld; then
    firewall-cmd -q --permanent --add-port="$PORT/tcp" && firewall-cmd -q --reload
fi

###############################################################################
# What's left to do
###############################################################################
IP=$( (ip -4 -o addr show scope global 2>/dev/null || true) | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n $IP ]] || IP="<container-ip>"
echo
echo "====================================================================="
if ((MIGRATED)) && ((!NEW_KEY)); then
    echo " Upgraded from pve-lab-web - same SSH key. On ANY Proxmox node run once:"
    echo
    echo "sed -i 's|PVE_LAB_IDLE=|PVE_RANGE_IDLE=|; s|/usr/local/bin/pve-lab\"|/usr/local/bin/pve-range\"|' /etc/pve/priv/authorized_keys"
else
    echo " On ANY Proxmox node run this ONE line (allows this container's key):"
    echo
    echo "echo 'from=\"$IP\",restrict,pty,command=\"env EDITOR=rnano PVE_RANGE_IDLE=$MENU_IDLE /usr/local/bin/pve-range\" $(cat "$DATA/ssh/id_ed25519.pub")' >>/etc/pve/priv/authorized_keys"
fi
echo
echo " The key can ONLY open the pve-range menu - no shell, no other commands."
echo " Browse from the jumpbox to:   https://$IP:$PORT"
echo "====================================================================="
if [[ ! -s $DATA/users ]] && [[ -t 0 ]]; then
    echo
    read -rp "No users yet. Name for the first user (empty = later): " first
    [[ -n $first ]] && /usr/local/sbin/pve-range-web-users add "$first"
fi
echo
/usr/local/sbin/pve-range-web-users list
