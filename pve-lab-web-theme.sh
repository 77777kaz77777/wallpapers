#!/usr/bin/env bash
# pve-lab-web-theme.sh - dark colour theme + nicer font for the browser terminal
# Run INSIDE the pve-lab-web container as root:   bash pve-lab-web-theme.sh
set -euo pipefail
U=/etc/systemd/system/pve-lab-web.service
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -f $U ]] || { echo "Run pve-lab-web-setup.sh first."; exit 1; }
cp "$U" "$U.bak"

# The new ttyd look (font, size, cursor and a colour palette tuned for the menu)
opts=$(cat <<'EOF'
    -t titleFixed=pve-lab -t fontSize=16 -t lineHeight=1.15 -t cursorStyle=bar -t disableLeaveAlert=true \
    "-t" "fontFamily=Cascadia Mono, JetBrains Mono, Fira Code, DejaVu Sans Mono, Consolas, monospace" \
    -t 'theme={"background":"#0f111a","foreground":"#c0caf5","cursor":"#7dcfff","selectionBackground":"#33467c","black":"#0f111a","red":"#f7768e","green":"#9ece6a","yellow":"#e0af68","blue":"#3d59a1","magenta":"#bb9af7","cyan":"#7dcfff","white":"#c0caf5","brightBlack":"#1f2335","brightRed":"#ff7a93","brightGreen":"#b9f27c","brightYellow":"#ff9e64","brightBlue":"#7aa2f7","brightMagenta":"#bb9af7","brightCyan":"#2ac3de","brightWhite":"#ffffff"}' \
EOF
)
# Replace the old "-t ..." lines with the new ones, right before the launcher line
awk -v opts="$opts" '
    /^[[:space:]]+("-t"|-t) / {next}
    /\/usr\/local\/bin\/pve-lab-web[[:space:]]*$/ {print opts}
    {print}' "$U.bak" >"$U"
grep -q '^Environment=LANG=' "$U" || sed -i 's/^\[Service\]$/[Service]\nEnvironment=LANG=C.UTF-8/' "$U"

systemctl daemon-reload
if systemctl restart pve-lab-web && sleep 1 && systemctl is-active -q pve-lab-web; then
    echo "Done - reload the page in the browser."
else
    echo "ttyd didn't start with the new options - restoring the old ones."
    cp "$U.bak" "$U"; systemctl daemon-reload; systemctl restart pve-lab-web
    journalctl -u pve-lab-web -n 20 --no-pager
fi
