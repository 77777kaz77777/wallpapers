#!/usr/bin/env bash
# range-test.sh - automatic end-to-end test of pve-range on the fake range from range-seed.sh
#
# Run on the node with the 613 guests (where you ran "range-seed.sh create"), as root:
#     ./range-test.sh
# It only touches guests tagged "fake-range", takes snapshots T1/T2/T3 and removes them again.
# Full output of every pve-range call goes to /tmp/range-test.out
#
PVERANGE=${PVERANGE:-/usr/local/bin/pve-range}
TO=15                                  # graceful-shutdown timeout (no-OS VMs ignore ACPI)
ME=$(hostname -s)
OUT=/tmp/range-test.out
LAST=/tmp/range-test.last
TAG=fake-range
pass=0 fail=0 skip=0

ok()   { echo "  PASS  $*"; ((pass++)); }
bad()  { echo "  FAIL  $*"; ((fail++)); }
skp()  { echo "  SKIP  $*"; ((skip++)); }
step() { echo; echo "=== $*"; echo "=== $*" >>"$OUT"; }
pr()   { "$PVERANGE" --yes "$@" >"$LAST" 2>&1; local rc=$?; cat "$LAST" >>"$OUT"; return $rc; }
check_rc() {
    if (($1 == 0)); then ok "$2 (exit 0)"; return; fi
    bad "$2 (exit $1)"
    grep -E '^\s+\^ failed|^\[[0-9]+/[0-9]+\]|[Ee]rror|[Ff]ailed|unable|can.t|not ' "$LAST" |
        grep -B1 -E '[Ee]rror|[Ff]ailed|unable|can.t|not ' | grep -v '^--$' | head -12 | sed 's/^/        /'
}

conf()     { compgen -G "/etc/pve/nodes/*/qemu-server/$1.conf" || compgen -G "/etc/pve/nodes/*/lxc/$1.conf"; }
node_of()  { conf "$1" | cut -d/ -f5; }
kind_of()  { if [[ $(conf "$1") == */lxc/* ]]; then echo lxc; else echo qemu; fi; }
gcmd()     { if [[ $(kind_of "$1") == lxc ]]; then echo pct; else echo qm; fi; }
main_cfg() { awk '/^\[/ {exit} {print}' "$(conf "$1")"; }
tags_of()  { main_cfg "$1" | awk -F': ' '$1 == "tags" {print $2}'; }
status()   {
    pvesh get "/nodes/$(node_of "$1")/$(kind_of "$1")/$1/status/current" --output-format json 2>/dev/null |
        perl -MJSON::PP -e 'local $/; print decode_json(<STDIN>)->{status}' 2>/dev/null
}
has_snap()   { grep -qxF "[$2]" "$(conf "$1")" 2>/dev/null; }
# Rollback marker "onboot: 1" (a description can't be used - Proxmox keeps it on rollback)
has_marker() { main_cfg "$1" | grep -qx 'onboot: 1'; }
declare -A HAD_ONBOOT=()
on_node() {   # on_node ID cmd...  (runs on the guest's node)
    local n; n=$(node_of "$1"); shift
    if [[ $n == "$ME" ]]; then "$@"; else ssh -n -o BatchMode=yes "root@$n" "$(printf '%q ' "$@")"; fi
}
expect() {   # expect running|stopped ids...
    local want=$1 id st; shift
    sleep 2
    for id in "$@"; do
        st=$(status "$id")
        if [[ $st == "$want" ]]; then ok "$id is $want"; else bad "$id is '${st:-?}', expected $want"; fi
    done
}
list_join() { local IFS=,; echo "$*"; }
exists()    { [[ -n $(conf "$1") ]]; }

###############################################################################
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -x $PVERANGE ]] || { echo "Can't find $PVERANGE (set PVERANGE=/path/to/pve-range)"; exit 1; }
v=$(grep -m1 '^VERSION=' "$PVERANGE" | tr -dc '0-9.')
if [[ $(printf '%s\n' "$v" 2.4 | sort -V | head -1) != 2.4 ]] || (($(grep -c '^cmd_start() {' "$PVERANGE") != 1)); then
    echo "$PVERANGE is version ${v:-?} or a damaged copy - install pve-range 2.4 or newer first."; exit 1
fi

# The fake range: tagged guests on this node (L) and on the other node (R)
L=() R=()
for f in /etc/pve/nodes/*/qemu-server/*.conf /etc/pve/nodes/*/lxc/*.conf; do
    [[ -e $f ]] || continue
    id=$(basename "$f" .conf)
    [[ ";$(tags_of "$id");" == *";$TAG;"* ]] || continue
    if [[ $(node_of "$id") == "$ME" ]]; then L+=("$id"); else R+=("$id"); fi
done
mapfile -t L < <(printf '%s\n' "${L[@]}" | sort -n)
mapfile -t R < <(printf '%s\n' "${R[@]}" | sort -n)
((${#L[@]})) || { echo "No '$TAG' guests on $ME - run: ./range-seed.sh create <other-node>"; exit 1; }
LS=$(list_join "${L[@]}")
: >"$OUT"
echo "Testing pve-range $v on $ME"
echo "Fake range here : ${L[*]}"
echo "Fake range other: ${R[*]:-none}"

step "1. list, folders and the VMID map"
"$PVERANGE" list >"$LAST" 2>&1; rc=$?; cat "$LAST" >>"$OUT"
check_rc $rc "list"
grep -q "^${L[0]} " "$LAST" && ok "list shows ${L[0]}" || bad "list doesn't show ${L[0]}"
grep -q '613 v0 Enterprise Clients' "$LAST" && ok "VMIDs are decoded (613 v0 Enterprise Clients)" || bad "VMID meaning missing in list"
"$PVERANGE" folders >"$LAST" 2>&1; cat "$LAST" >>"$OUT"
for f in 612 613 NetWars; do grep -qw "$f" "$LAST" && ok "folder $f detected" || bad "folder $f missing"; done
"$PVERANGE" list --folder 613 >"$LAST" 2>&1
if grep -qE '^5[02][0-9]{4} ' "$LAST"; then bad "--folder 613 also lists other classes"
else ok "--folder 613 lists only 613 guests"; fi

step "2. dry-run changes nothing"
declare -A before=()
for id in "${L[@]}"; do before[$id]=$(status "$id"); done
"$PVERANGE" --yes --dry-run power-off --only "$LS" >>"$OUT" 2>&1
"$PVERANGE" --yes --dry-run class-start --only "$LS" >>"$OUT" 2>&1
changed=0
for id in "${L[@]}"; do [[ $(status "$id") == "${before[$id]}" ]] || changed=1; done
((changed)) && bad "a dry-run changed a guest's power state" || ok "power states unchanged"

step "3. folder scope: class-start --folder 612 (dry-run) only plans 612 guests"
"$PVERANGE" --yes --dry-run class-start --folder 612 --cluster >"$LAST" 2>&1
if grep -qE '\] (qm|pct) (rollback|start) 5[13][0-9]{4}' "$LAST"; then bad "612 plan contains guests of other classes"
elif grep -qE '\] (qm|pct) (rollback|start) 50[0-9]{4}' "$LAST"; then ok "612 plan only has 50xxxx guests"
else skp "no 612 guests found (range-seed.sh puts them on the other node)"; fi

step "4. snapshot T1"
pr snapshot T1 --only "$LS" --replace
check_rc $? "snapshot T1"
for id in "${L[@]}"; do has_snap "$id" T1 && ok "$id has T1" || bad "$id has no T1"; done

step "5. class-start to T1 (--keep ${L[0]} = not restored)"
for id in "${L[@]}"; do
    main_cfg "$id" | grep -q '^onboot:' && { HAD_ONBOOT[$id]=1; continue; }
    on_node "$id" "$(gcmd "$id")" set "$id" --onboot 1 >/dev/null
done
pr class-start --snap T1 --keep "${L[0]}" --only "$LS"
check_rc $? "class-start --snap T1"
expect running "${L[@]}"
if [[ -z ${HAD_ONBOOT[${L[0]}]} ]]; then
    has_marker "${L[0]}" && ok "${L[0]} was kept (not restored)" || bad "${L[0]} was restored"
fi
for id in "${L[@]:1}"; do
    [[ -n ${HAD_ONBOOT[$id]} ]] && { skp "$id already had onboot set - can't check"; continue; }
    has_marker "$id" && bad "$id was NOT restored" || ok "$id was restored"
done

step "6. power-off, graceful (forced after ${TO}s)"
pr power-off --only "$LS" --timeout "$TO"
check_rc $? "power-off"
expect stopped "${L[@]}"

step "7. power-on (nothing restored)"
pr power-on --only "$LS"
check_rc $? "power-on"
expect running "${L[@]}"

step "8. class-end to T1 + hard power-off"
pr class-end --snap T1 --only "$LS" --hard
check_rc $? "class-end --hard"
expect stopped "${L[@]}"
for id in "${L[@]}"; do has_snap "$id" T1 || bad "$id lost T1"; done

step "9. RAM snapshot (500101 ClassStart): class-end must stop it, class-start must not double-start"
if exists 500101 && awk '$0 == "[ClassStart]" {f = 1; next} /^\[/ {f = 0} f && /^vmstate:/ {x = 1} END {exit !x}' "$(conf 500101)"; then
    pr class-end --snap ClassStart --only 500101 --hard
    check_rc $? "class-end 500101 (RAM snapshot)"
    expect stopped 500101
    pr class-start --snap ClassStart --only 500101
    check_rc $? "class-start 500101 (RAM snapshot)"
    expect running 500101
    pr power-off --only 500101 --hard
else
    skp "500101 has no RAM ClassStart snapshot"
fi

step "10. snapshot T2 with --off-first (shut down, then snapshot)"
pr power-on --only "$LS"
pr snapshot T2 --only "$LS" --off-first --hard --replace
check_rc $? "snapshot T2 --off-first"
expect stopped "${L[@]}"
for id in "${L[@]}"; do has_snap "$id" T2 && ok "$id has T2" || bad "$id has no T2"; done

step "11. snapshot T3 with --off (snapshot, then graceful shutdown)"
pr power-on --only "$LS"
pr snapshot T3 --only "$LS" --off --timeout "$TO" --replace
check_rc $? "snapshot T3 --off"
expect stopped "${L[@]}"
for id in "${L[@]}"; do has_snap "$id" T3 && ok "$id has T3" || bad "$id has no T3"; done

step "12. protected guests are never touched"
if ((${#L[@]} >= 2)); then
    "$PVERANGE" --yes --protect "${L[0]}" power-on --only "${L[0]},${L[1]}" >>"$OUT" 2>&1
    expect stopped "${L[0]}"
    expect running "${L[1]}"
    pr power-off --only "${L[1]}" --hard
fi

step "13. guests on the other node (over SSH)"
RT=()
for id in 521001 521101; do exists "$id" && [[ $(node_of "$id") != "$ME" ]] && RT+=("$id"); done
if ((${#RT[@]})); then
    RS=$(list_join "${RT[@]}")
    pr power-on --only "$RS"
    check_rc $? "remote power-on"
    expect running "${RT[@]}"
    pr power-off --only "$RS" --hard
    check_rc $? "remote power-off"
    expect stopped "${RT[@]}"
else
    skp "no NetWars Grid guests on the other node"
fi

step "14. port mirroring (vmbr2 -> 510002:net1, the 613 Tenable sensor)"
MF=/etc/pve-range/mirrors.conf
if command -v ovs-vsctl >/dev/null && ovs-vsctl br-exists vmbr2 && exists 510002 && [[ $(node_of 510002) == "$ME" ]]; then
    mkdir -p /etc/pve-range
    [[ -f $MF ]] && cp "$MF" "$MF.range-test-backup"
    echo "$ME|vmbr2|510002:net1" >"$MF"
    pr power-on --only 510002
    pr mirror-apply
    check_rc $? "mirror-apply"
    n=$(ovs-vsctl get bridge vmbr2 mirrors | tr -d '[] ' | tr ',' '\n' | grep -c .)
    ((n == 1)) && ok "vmbr2 has 1 mirror" || bad "vmbr2 has $n mirrors, expected 1"
    pr mirror-status
    grep -q 'tap510002i1' "$LAST" && ok "mirror-status shows the sensor port" || bad "mirror-status doesn't show tap510002i1"
    pr mirror-clear vmbr2
    check_rc $? "mirror-clear"
    [[ $(ovs-vsctl get bridge vmbr2 mirrors) == "[]" ]] && ok "mirrors removed" || bad "mirrors still there"
    if [[ -f $MF.range-test-backup ]]; then mv "$MF.range-test-backup" "$MF"; else rm -f "$MF"; fi
    pr power-off --only 510002 --hard
else
    skp "needs OVS bridge vmbr2 and 510002 on this node"
fi

step "15. class guide, storage overview, add-ons"
"$PVERANGE" guide --folder 613 >"$LAST" 2>&1
grep -q 'Class guide - 613' "$LAST" && ok "class guide for 613 is there" || skp "no class guide for 613 (range-seed.sh writes one)"
"$PVERANGE" storage >"$LAST" 2>&1
grep -q 'local-lvm' "$LAST" && ok "storage overview lists local-lvm" || bad "storage overview missing local-lvm"
grep -qE '^ +5[0-9]{5} .* (raw|qcow2) ' "$LAST" && ok "storage overview lists disks with their format" || bad "no disks in the storage overview"
[[ -d /etc/pve/pve-range/addons ]] && ok "add-ons are in the cluster file system" ||
    skp "no /etc/pve/pve-range/addons yet (open Add-ons once in the menu)"

step "16. save & share"
if command -v git >/dev/null; then
    pr save "range-test $(date +%F_%T)"
    check_rc $? "save (history$(grep -q '^REPO_URL=.' /etc/pve/pve-range/save.conf 2>/dev/null && echo ' + repository'))"
    git -C /var/lib/pve-range/repo log -1 --format=%s 2>/dev/null | grep -q 'range-test\|No changes' &&
        ok "history has the save" || ok "history up to date"
else
    skp "git not installed (apt-get install git) - no history"
fi
if grep -q '^BACKUP_STORAGE=.' /etc/pve/pve-range/save.conf 2>/dev/null; then
    pr backup
    check_rc $? "backup"
    [[ -f $(tail -1 "$LAST") ]] && ok "backup file written: $(tail -1 "$LAST")" || bad "no backup file"
else
    skp "no backup storage set (Save & share -> Settings)"
fi

step "Cleanup"
pr power-off --only "$LS" --hard
for id in "${L[@]}"; do
    for s in T3 T2 T1; do has_snap "$id" "$s" && on_node "$id" "$(gcmd "$id")" delsnapshot "$id" "$s" >>"$OUT" 2>&1; done
    [[ -z ${HAD_ONBOOT[$id]} ]] && has_marker "$id" && on_node "$id" "$(gcmd "$id")" set "$id" --delete onboot >>"$OUT" 2>&1
done
echo "  removed T1/T2/T3 and test markers"

echo
echo "=================================="
echo " $pass passed, $fail failed, $skip skipped"
echo " full log: $OUT"
echo "=================================="
((fail == 0))
