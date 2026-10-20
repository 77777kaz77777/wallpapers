#!/usr/bin/env bash
# pve-lab-web-auth.sh - better sign-in for the pve-lab browser menu
#   * one account per person (no shared password)
#   * optional 2FA codes from an authenticator app (Google/Microsoft Authenticator, Aegis...)
#   * lock-out after repeated wrong sign-ins
#   * every sign-in (good or bad) in the journal; the pve-lab log shows WHO ran each command
#   * signs out by itself when idle
#
# Run INSIDE the pve-lab-web container as root:   bash pve-lab-web-auth.sh
set -euo pipefail
CONF=/etc/pve-lab-web
STATE=/var/lib/pve-lab-web
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -f /etc/systemd/system/pve-lab-web.service ]] || { echo "Run pve-lab-web-setup.sh first."; exit 1; }

echo "== Packages (2FA codes and QR codes)"
rpm -q epel-release &>/dev/null || dnf -y install epel-release
dnf -y install oathtool qrencode

install -d -o pvelab -g pvelab -m 750 "$STATE"
touch "$STATE/failures" && chown pvelab:pvelab "$STATE/failures" && chmod 600 "$STATE/failures"
touch "$CONF/users" && chown root:pvelab "$CONF/users" && chmod 640 "$CONF/users"

# Keep the account from pve-lab-web-login.sh (same password hash, no 2FA yet)
if [[ -f $CONF/login && ! -s $CONF/users ]]; then
    IFS=: read -r u h <"$CONF/login"
    echo "$u:$h:" >"$CONF/users"
    rm -f "$CONF/login"
    echo "Kept existing user '$u' (add 2FA with: pve-lab-web-users 2fa $u on)"
fi

echo "== Admin tool: pve-lab-web-users"
cat >/usr/local/sbin/pve-lab-web-users <<'EOF'
#!/usr/bin/env bash
# pve-lab-web-users - manage sign-ins for the pve-lab browser menu
set -euo pipefail
F=/etc/pve-lab-web/users
FAILS=/var/lib/pve-lab-web/failures
usage() {
    cat <<USAGE
Usage: pve-lab-web-users COMMAND [NAME]
  list                 show users and whether 2FA is on
  add NAME [--no-2fa]  create a user (asks for a password, sets up 2FA)
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
    chown root:pvelab "$F.new"; chmod 640 "$F.new"; mv "$F.new" "$F"
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
    local name=$1 secret code i
    secret=$(head -c 20 /dev/urandom | base32 | tr -d '=')
    echo >&2
    echo "Scan this with an authenticator app (Google/Microsoft Authenticator, Aegis, ...):" >&2
    qrencode -t ANSIUTF8 "otpauth://totp/pve-lab:$name?secret=$secret&issuer=pve-lab" >&2
    echo "Or type the key by hand: $secret" >&2
    for i in 1 2 3; do
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
        [[ ${3:-} == --no-2fa ]] || s=$(new_2fa "$name")
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
EOF
chmod 700 /usr/local/sbin/pve-lab-web-users

echo "== New sign-in screen"
cat >/usr/local/bin/pve-lab-web <<'EOF'
#!/usr/bin/env bash
# Sign-in, then the pve-lab menu on the first Proxmox node that answers.
USERS=/etc/pve-lab-web/users
FAILS=/var/lib/pve-lab-web/failures
MAX_FAIL=5        # wrong sign-ins ...
LOCK_MIN=10       # ... within this many minutes lock everyone out for that long
IDLE=300          # seconds without input before signing out
say() { logger -t pve-lab-web -- "$*" 2>/dev/null; }
recent_failures() {
    local cut=$(($(date +%s) - LOCK_MIN * 60))
    awk -v c="$cut" '$1 >= c' "$FAILS" 2>/dev/null | wc -l
}
clear
printf '\n  pve-lab - sign in\n  ------------------\n\n'
if (($(recent_failures) >= MAX_FAIL)); then
    echo "  Too many wrong sign-ins. Try again in $LOCK_MIN minutes."
    say "sign-in refused: locked out"
    sleep 10; exit 1
fi
ok=""
for try in 1 2 3; do
    read -t "$IDLE" -rp "  Login: " u || exit 0
    read -t "$IDLE" -rsp "  Password: " p || exit 0; echo
    line=""
    [[ $u =~ ^[A-Za-z0-9_.-]{1,32}$ ]] && line=$(awk -F: -v u="$u" '$1 == u {print; exit}' "$USERS")
    IFS=: read -r _ hash secret <<<"$line"
    [[ -n $hash ]] || hash='$6$nosuchuser$x'          # same amount of work for unknown names
    good=0
    if [[ -n $line && $(printf '%s' "$p" | openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$hash")" -stdin) == "$hash" ]]; then
        good=1
        if [[ -n $secret ]]; then
            read -t "$IDLE" -rp "  Code from your authenticator app: " code || exit 0
            [[ $code =~ ^[0-9]{6}$ ]] && oathtool --totp -b -w 1 "$secret" "$code" >/dev/null 2>&1 || good=0
        fi
    fi
    unset p
    if ((good)); then ok=$u; break; fi
    date +%s >>"$FAILS"
    say "sign-in FAILED for '${u:0:32}' (try $try)"
    sleep 3
    echo "  Wrong login."
    if (($(recent_failures) >= MAX_FAIL)); then echo "  Locked for $LOCK_MIN minutes."; sleep 5; exit 1; fi
done
[[ -n $ok ]] || exit 1
say "sign-in OK: $ok"

mapfile -t NODES </etc/pve-lab-web/nodes
while :; do
    clear
    for n in "${NODES[@]}"; do
        ssh -t -o BatchMode=yes -o ConnectTimeout=4 -o GSSAPIAuthentication=no -o AddressFamily=inet \
            -o SetEnv=LC_PVELAB_USER="$ok" "root@$n"
        rc=$?
        ((rc != 255)) && break
        echo "Can't reach $n - trying the next node..."
        sleep 1
    done
    ((rc == 255)) && echo "No Proxmox node reachable (${NODES[*]})."
    echo
    read -t "$IDLE" -rp "Press Enter to open the pve-lab menu again (signs out after ${IDLE}s) " _ || break
done
say "signed out: $ok"
echo; echo "Signed out. Reload the page to sign in again."
EOF
chmod 755 /usr/local/bin/pve-lab-web
systemctl restart pve-lab-web

echo
echo "Done."
if [[ ! -s $CONF/users ]]; then
    echo "Create the first user now:   pve-lab-web-users add <name>"
else
    pve-lab-web-users list
fi
