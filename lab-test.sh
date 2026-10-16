#!/usr/bin/env bash
# lab-test.sh - automatic end-to-end test of pve-lab.sh on the lab-seed guests
#
# Run on the node that holds the 9xxx test guests (TDpve2), next to pve-lab.sh:
#     ./lab-test.sh
# It only touches the test guests, takes snapshots T1/T2/T3 and removes them again.
# Full output of every pve-lab.sh call goes to /tmp/lab-test.out
#
PVELAB=${PVELAB:-./pve-lab.sh}
LOCAL_RANGE=${LOCAL_RANGE:-"9102-9210,501402"}   # test guests on this node
REMOTE_RANGE=${REMOTE_RANGE:-"9303-9304"}        # test guests on the other node
TO=15                                            # graceful-shutdown timeout (no-OS VMs ignore ACPI)
ME=$(hostname -s)
OUT=/tmp/lab-test.out
pass=0 fail=0

ok()   { echo "  PASS  $*"; ((pass++)); }
bad()  { echo "  FAIL  $*"; ((fail++)); }
step() { echo; echo "=== $*"; echo "=== $*" >>"$OUT"; }
lab()  { "$PVELAB" --yes "$@" >>"$OUT" 2>&1; }
check_rc() { if (($1 == 0)); then ok "$2 (exit 0)"; else bad "$2 (exit $1, see $OUT)"; fi; }

conf()    { compgen -G "/etc/pve/nodes/*/qemu-server/$1.conf" || compgen -G "/etc/pve/nodes/*/lxc/$1.conf"; }
node_of() { conf "$1" | cut -d/ -f5; }
kind_of() { if [[ $(conf "$1") == */lxc/* ]]; then echo lxc; else echo qemu; fi; }
gcmd()    { if [[ $(kind_of "$1") == lxc ]]; then echo pct; else echo qm; fi; }
status()  {
    pvesh get "/nodes/$(node_of "$1")/$(kind_of "$1")/$1/status/current" --output-format json 2>/dev/null |
        perl -MJSON::PP -e 'local $/; print decode_json(<STDIN>)->{status}' 2>/dev/null
}
has_snap() { grep -qxF "[$2]" "$(conf "$1")" 2>/dev/null; }
desc_has() { awk '/^\[/ {exit} /^description:/' "$(conf "$1")" | grep -q "$2"; }
on_node()  {   # on_node ID cmd...  (runs on the guest's node)
    local n; n=$(node_of "$1"); shift
    if [[ $n == "$ME" ]]; then "$@"; else ssh -n -o BatchMode=yes "root@$n" "$(printf '%q ' "$@")"; fi
}
in_ranges() {
    local id=$1 tok
    for tok in ${2//,/ }; do
        if [[ $tok == *-* ]]; then ((id >= ${tok%-*} && id <= ${tok#*-})) && return 0
        else ((id == tok)) && return 0; fi
    done
    return 1
}
ids_of() {   # existing guests inside a range spec
    local f id
    for f in /etc/pve/nodes/*/qemu-server/*.conf /etc/pve/nodes/*/lxc/*.conf; do
        id=$(basename "$f" .conf)
        [[ $id =~ ^[0-9]+$ ]] && in_ranges "$id" "$1" && echo "$id"
    done | sort -n
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

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -x $PVELAB ]] || { echo "Can't find $PVELAB (set PVELAB=/path/to/pve-lab.sh)"; exit 1; }
mapfile -t L < <(ids_of "$LOCAL_RANGE")
mapfile -t R < <(ids_of "$REMOTE_RANGE")
((${#L[@]})) || { echo "No test guests in $LOCAL_RANGE - run lab-seed.sh first."; exit 1; }
LS=$(list_join "${L[@]}")
: >"$OUT"
echo "Testing $PVELAB on $ME"
echo "Local test guests : ${L[*]}"
echo "Remote test guests: ${R[*]:-none}"

step "1. list"
"$PVELAB" list >>"$OUT" 2>&1
check_rc $? "list"
grep -q "^${L[0]} " "$OUT" && ok "list shows ${L[0]}" || bad "list doesn't show ${L[0]}"

step "2. dry-run changes nothing"
declare -A before=()
for id in "${L[@]}"; do before[$id]=$(status "$id"); done
"$PVELAB" --yes --dry-run stop --only "$LS" >>"$OUT" 2>&1
"$PVELAB" --yes --dry-run start --only "$LS" >>"$OUT" 2>&1
changed=0
for id in "${L[@]}"; do [[ $(status "$id") == "${before[$id]}" ]] || changed=1; done
((changed)) && bad "a dry-run changed a guest's power state" || ok "power states unchanged"

step "3. snapshot T1"
lab snapshot T1 --only "$LS" --replace
check_rc $? "snapshot T1"
for id in "${L[@]}"; do has_snap "$id" T1 && ok "$id has T1" || bad "$id has no T1"; done

step "4. start with rollback to T1 (--keep ${L[0]} = not rolled back)"
for id in "${L[@]}"; do on_node "$id" "$(gcmd "$id")" set "$id" --description marker-after-T1 >/dev/null; done
lab start --snap T1 --keep "${L[0]}" --only "$LS"
check_rc $? "start --snap T1"
expect running "${L[@]}"
desc_has "${L[0]}" marker-after-T1 && ok "${L[0]} was kept (not rolled back)" || bad "${L[0]} was rolled back"
for id in "${L[@]:1}"; do
    desc_has "$id" marker-after-T1 && bad "$id was NOT rolled back" || ok "$id was rolled back"
done

step "5. graceful shutdown (forced after ${TO}s)"
lab stop --only "$LS" --timeout "$TO"
check_rc $? "stop"
expect stopped "${L[@]}"

step "6. start without rollback"
lab start --no-rollback --only "$LS"
check_rc $? "start --no-rollback"
expect running "${L[@]}"

step "7. reset to T1 + hard power-off"
lab reset --snap T1 --only "$LS" --hard
check_rc $? "reset --hard"
expect stopped "${L[@]}"
for id in "${L[@]}"; do has_snap "$id" T1 || bad "$id lost T1"; done

step "8. RAM snapshot (9203 ClassStart): reset must stop it, start must not double-start"
if [[ " ${L[*]} " == *" 9203 "* ]] && grep -A5 -xF '[ClassStart]' "$(conf 9203)" | grep -q '^vmstate:'; then
    lab reset --snap ClassStart --only 9203 --hard
    check_rc $? "reset 9203 to RAM snapshot"
    expect stopped 9203
    lab start --snap ClassStart --only 9203
    check_rc $? "start 9203 from RAM snapshot"
    expect running 9203
    lab stop --only 9203 --hard
else
    echo "  SKIP  9203 has no RAM ClassStart snapshot"
fi

step "9. snapshot T2 with --off-first (shut down, then snapshot)"
lab start --no-rollback --only "$LS"
lab snapshot T2 --only "$LS" --off-first --hard --replace
check_rc $? "snapshot T2 --off-first"
expect stopped "${L[@]}"
for id in "${L[@]}"; do has_snap "$id" T2 && ok "$id has T2" || bad "$id has no T2"; done

step "10. snapshot T3 with --off (snapshot, then graceful shutdown)"
lab start --no-rollback --only "$LS"
lab snapshot T3 --only "$LS" --off --timeout "$TO" --replace
check_rc $? "snapshot T3 --off"
expect stopped "${L[@]}"
for id in "${L[@]}"; do has_snap "$id" T3 && ok "$id has T3" || bad "$id has no T3"; done

step "11. protected guests are never touched"
if ((${#L[@]} >= 2)); then
    "$PVELAB" --yes --protect "${L[0]}" start --no-rollback --only "${L[0]},${L[1]}" >>"$OUT" 2>&1
    expect stopped "${L[0]}"
    expect running "${L[1]}"
    lab stop --only "${L[1]}" --hard
fi

step "12. guests on the other node (over SSH)"
if ((${#R[@]})); then
    RS=$(list_join "${R[@]}")
    lab start --no-rollback --only "$RS"
    check_rc $? "remote start"
    expect running "${R[@]}"
    lab stop --only "$RS" --hard
    check_rc $? "remote stop"
    expect stopped "${R[@]}"
else
    echo "  SKIP  no guests in $REMOTE_RANGE"
fi

step "13. port mirroring (vmbr2 -> 501402:net1 + 9207:net1)"
MF=/etc/pve-lab/mirrors.conf
if command -v ovs-vsctl >/dev/null && ovs-vsctl br-exists vmbr2 && [[ -n $(conf 501402) && -n $(conf 9207) ]] &&
    [[ $(node_of 501402) == "$ME" && $(node_of 9207) == "$ME" ]]; then
    mkdir -p /etc/pve-lab
    [[ -f $MF ]] && cp "$MF" "$MF.lab-test-backup"
    echo "$ME|vmbr2|501402:net1 9207:net1" >"$MF"
    lab start --no-rollback --only 501402,9207
    lab mirror-apply
    check_rc $? "mirror-apply"
    n=$(ovs-vsctl get bridge vmbr2 mirrors | tr -d '[] ' | tr ',' '\n' | grep -c .)
    ((n == 2)) && ok "vmbr2 has 2 mirrors" || bad "vmbr2 has $n mirrors, expected 2"
    lab mirror-clear vmbr2
    check_rc $? "mirror-clear"
    [[ $(ovs-vsctl get bridge vmbr2 mirrors) == "[]" ]] && ok "mirrors removed" || bad "mirrors still there"
    if [[ -f $MF.lab-test-backup ]]; then mv "$MF.lab-test-backup" "$MF"; else rm -f "$MF"; fi
    lab stop --only 501402,9207 --hard
else
    echo "  SKIP  needs OVS bridge vmbr2 and 501402 + 9207 on this node"
fi

step "Cleanup"
lab stop --only "$LS" --hard
for id in "${L[@]}"; do
    for s in T3 T2 T1; do has_snap "$id" "$s" && on_node "$id" "$(gcmd "$id")" delsnapshot "$id" "$s" >>"$OUT" 2>&1; done
    desc_has "$id" marker-after-T1 && on_node "$id" "$(gcmd "$id")" set "$id" --delete description >>"$OUT" 2>&1
done
echo "  removed T1/T2/T3 and test markers"

echo
echo "=================================="
echo " $pass passed, $fail failed"
echo " full log: $OUT"
echo "=================================="
((fail == 0))
