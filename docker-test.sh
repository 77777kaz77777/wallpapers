#!/usr/bin/env bash
# docker-test.sh - end-to-end test of pve-range in container mode (Docker or Podman)
#
# Run on the Docker host (e.g. CT 105), as root:
#     ./docker-test.sh                       # compose folder /opt/pve-range-docker
#     ./docker-test.sh /path/to/pve-range-docker
#
# Tests the containers, the Proxmox API connection, sign-in, and every pve-range
# action on the fake range (guests tagged "fake-range", VMIDs 51xxxx = class 613) -
# all of it from INSIDE the container. Snapshots T1/T2/T3, a test user and test
# markers are removed again at the end. Full output: /tmp/docker-test.out
#
DIR=${1:-/opt/pve-range-docker}
SVC=pve-range-web
A=/usr/local/lib/pve-range/api          # the qm/pct/pvesh stand-ins inside the container
TO=15                                   # graceful-shutdown timeout (no-OS VMs ignore ACPI)
TAG=fake-range
TUSER=rtest-$$ TPASS="Rtest-pass-$$-xyz"
OUT=/tmp/docker-test.out LAST=/tmp/docker-test.last
pass=0 fail=0 skip=0

ok()   { echo "  PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail + 1)); }
skp()  { echo "  SKIP  $*"; skip=$((skip + 1)); }
step() { echo; echo "=== $*"; echo "=== $*" >>"$OUT"; }

cd "$DIR" 2>/dev/null || { echo "No compose folder at $DIR"; exit 1; }
if docker compose version >/dev/null 2>&1; then DC=(docker compose) ENG=docker
elif podman compose version >/dev/null 2>&1; then DC=(podman compose) ENG=podman
elif command -v docker-compose >/dev/null; then DC=(docker-compose) ENG=docker
else echo "Neither 'docker compose' nor 'podman compose' found."; exit 1; fi

cx()  { "${DC[@]}" exec -T "$SVC" "$@"; }                    # run in the container (root)
cxu() { "${DC[@]}" exec -T -u pverange "$SVC" "$@"; }        # ... as the service user
pr()  { cx pve-range --yes "$@" >"$LAST" 2>&1; local rc=$?; cat "$LAST" >>"$OUT"; return $rc; }
check_rc() {
    if (($1 == 0)); then ok "$2 (exit 0)"; return; fi
    bad "$2 (exit $1)"
    grep -E '^\[[0-9]+/[0-9]+\]|[Ee]rror|[Ff]ailed|task failed|HTTP [0-9]' "$LAST" | head -10 | sed 's/^/        /'
}
gtool()  { if [[ ${TYPE[$1]} == lxc ]]; then echo "$A/pct"; else echo "$A/qm"; fi; }
status() { cx "$(gtool "$1")" status "$1" 2>/dev/null | awk '{print $2}'; }
has_snap() { cx "$(gtool "$1")" listsnapshot "$1" 2>/dev/null | grep -qx "$2"; }
has_marker() { cx "$(gtool "$1")" config "$1" 2>/dev/null | grep -qx 'onboot: 1'; }
expect() {   # expect running|stopped ids...
    local want=$1 id st; shift
    sleep 2
    for id in "$@"; do
        st=$(status "$id")
        if [[ $st == "$want" ]]; then ok "$id is $want"; else bad "$id is '${st:-?}', expected $want"; fi
    done
}
list_join() { local IFS=,; echo "$*"; }
: >"$OUT"

###############################################################################
step "1. containers"
for s in pve-range-web pve-range-dist; do
    st=$($ENG inspect -f '{{.State.Status}}' "$s" 2>/dev/null)
    [[ $st == running ]] && ok "$s is running" || bad "$s is '${st:-missing}'"
done
h=$($ENG inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' pve-range-web 2>/dev/null)
[[ -z $h || $h == healthy ]] && ok "pve-range-web health: ${h:-no healthcheck}" || bad "pve-range-web health: $h"
port=$(grep -m1 '^PORT=' .env 2>/dev/null | cut -d= -f2); port=${port:-7681}
code=$(curl -ks -o /dev/null -w '%{http_code}' "https://127.0.0.1:$port/")
[[ $code == 200 ]] && ok "web page answers on https :$port" || bad "web page on :$port answered '$code'"
dport=$(grep -m1 '^DIST_PORT=' .env 2>/dev/null | cut -d= -f2); dport=${dport:-8080}
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$dport/CHANGELOG.md")
[[ $code == 200 ]] && ok "download page serves the changelog on :$dport" || bad "download page :$dport answered '$code'"

step "2. container mode and the Proxmox API"
url=$(cx sh -c 'echo "$PVE_API_URL"')
[[ -n $url ]] && ok "container mode is on (PVE_API_URL=$url)" || { bad "PVE_API_URL is empty - this tests container mode only"; exit 1; }
if ver=$(cx "$A/pvesh" get /version 2>"$LAST"); then
    ok "Proxmox API answers (version $(cx sh -c "echo '$ver' | jq -r .version"))"
else
    bad "Proxmox API: $(tail -1 "$LAST")"; exit 1
fi
perms=$(cx sh -c "$A/pvesh get /access/permissions | jq -r '.\"/\" // {} | keys[]'" 2>/dev/null)
for p in VM.Audit VM.PowerMgmt VM.Snapshot VM.Snapshot.Rollback VM.Config.Network VM.Config.Disk VM.Migrate Datastore.AllocateSpace Sys.Audit; do
    grep -qx "$p" <<<"$perms" && ok "token may $p" || bad "token lacks $p (roles: PVEVMAdmin, PVEDatastoreUser, PVEAuditor on /)"
done
grep -qx 'Sys.Modify\|Permissions.Modify\|User.Modify' <<<"$perms" &&
    bad "token can change the nodes or users - give it fewer rights" || ok "token can't change nodes or users"
cx sh -c "PVE_API_URL='https://192.0.2.1:8006 $url' $A/pvesh get /version" >/dev/null 2>&1 &&
    ok "an unreachable first address falls over to the next one" || bad "failover to the next API address didn't work"
cx sh -c "PVE_API_TOKEN='nobody@pve!x=00000000-0000-0000-0000-000000000000' $A/pvesh get /version" >"$LAST" 2>&1 &&
    bad "a wrong token was accepted" || { grep -q 'HTTP 401' "$LAST" && ok "a wrong token is refused (401)" || ok "a wrong token is refused"; }
cx "$A/qm" unlock 1 >"$LAST" 2>&1 && bad "'qm unlock' should be refused in container mode" ||
    { grep -q "needs a shell on the node" "$LAST" && ok "shell-only commands give a clear message" || bad "unclear message for shell-only commands"; }

step "3. the fake range (through the API)"
declare -A TYPE=()
L=()
while read -r id t _; do
    [[ -n $id ]] || continue
    TYPE[$id]=$t
    ((id >= 510000 && id <= 519999)) && L+=("$id")
done < <(cx sh -c "$A/pvesh get /cluster/resources --type vm |
    jq -r '.[] | select((.tags // \"\") | split(\";\") | index(\"$TAG\")) | \"\(.vmid) \(.type) \(.node)\"'" | sort -n)
mapfile -t L < <(printf '%s\n' "${L[@]}" | sort -n)
((${#L[@]})) || { bad "no '$TAG' 613 guests - run: ./range-seed.sh create <other-node> (on a node)"; exit 1; }
ok "${#L[@]} fake-range 613 guests: ${L[*]}"
LS=$(list_join "${L[@]}")

step "4. list, folders, VMID map"
pr list; check_rc $? "list"
grep -qE '613 v0 [A-Z]' "$LAST" && ok "VMIDs are decoded (613 v0 ...)" || bad "VMID meaning missing"
pr folders
for f in 612 613; do grep -qw "$f" "$LAST" && ok "folder $f detected" || bad "folder $f missing"; done
grep -qw NetWars "$LAST" && ok "folder NetWars detected" || skp "no NetWars guests"
pr list --folder 613
grep -qE '^5[02][0-9]{4} ' "$LAST" && bad "--folder 613 also lists other classes" || ok "--folder 613 lists only 613"
pr storage
grep -qE '^ +51[0-9]{4} .* (raw|qcow2) ' "$LAST" && ok "storage overview lists disks and formats" || bad "storage overview has no 613 disks"

step "5. dry-run changes nothing"
declare -A before=()
for id in "${L[@]}"; do before[$id]=$(status "$id"); done
cx pve-range --yes --dry-run power-off --only "$LS" >>"$OUT" 2>&1
cx pve-range --yes --dry-run class-start --only "$LS" >>"$OUT" 2>&1
changed=0
for id in "${L[@]}"; do [[ $(status "$id") == "${before[$id]}" ]] || changed=1; done
((changed)) && bad "a dry-run changed a power state" || ok "power states unchanged"

step "6. snapshot T1"
pr snapshot T1 --only "$LS" --replace; check_rc $? "snapshot T1"
for id in "${L[@]}"; do has_snap "$id" T1 && ok "$id has T1" || bad "$id has no T1"; done

step "7. class-start to T1 (--keep ${L[0]} = not restored)"
declare -A HAD=()
for id in "${L[@]}"; do
    if cx "$(gtool "$id")" config "$id" 2>/dev/null | grep -q '^onboot:'; then HAD[$id]=1; continue; fi
    cx "$(gtool "$id")" set "$id" --onboot 1 >/dev/null 2>&1
done
pr class-start --snap T1 --keep "${L[0]}" --only "$LS"; check_rc $? "class-start --snap T1"
expect running "${L[@]}"
[[ -z ${HAD[${L[0]}]} ]] && { has_marker "${L[0]}" && ok "${L[0]} was kept" || bad "${L[0]} was restored"; }
for id in "${L[@]:1}"; do
    [[ -n ${HAD[$id]} ]] && { skp "$id had onboot already"; continue; }
    has_marker "$id" && bad "$id was NOT restored" || ok "$id was restored"
done

step "8. power-off (graceful, forced after ${TO}s) and power-on"
pr power-off --only "$LS" --timeout "$TO"; check_rc $? "power-off"
expect stopped "${L[@]}"
pr power-on --only "$LS"; check_rc $? "power-on"
expect running "${L[@]}"

step "9. class-end to T1 + hard power-off"
pr class-end --snap T1 --only "$LS" --hard; check_rc $? "class-end --hard"
expect stopped "${L[@]}"

step "10. RAM snapshot (500101 ClassStart)"
if cx sh -c "$A/pvesh get /cluster/resources --type vm | jq -e '.[] | select(.vmid == 500101)'" >/dev/null 2>&1 &&
    cx sh -c "n=\$($A/pvesh get /cluster/resources --type vm | jq -r '.[] | select(.vmid == 500101) | .node');
              $A/pvesh get /nodes/\$n/qemu/500101/snapshot | jq -e '.[] | select(.name == \"ClassStart\" and .vmstate == 1)'" >/dev/null 2>&1; then
    TYPE[500101]=qemu
    pr class-end --snap ClassStart --only 500101 --hard; check_rc $? "class-end 500101"
    expect stopped 500101
    pr class-start --snap ClassStart --only 500101; check_rc $? "class-start 500101 (no double start)"
    expect running 500101
    pr power-off --only 500101 --hard
else
    skp "500101 has no RAM ClassStart snapshot"
fi

step "11. snapshots T2 (--off-first) and T3 (--off)"
pr power-on --only "$LS"
pr snapshot T2 --only "$LS" --off-first --hard --replace; check_rc $? "snapshot T2 --off-first"
expect stopped "${L[@]}"
pr power-on --only "$LS"
pr snapshot T3 --only "$LS" --off --timeout "$TO" --replace; check_rc $? "snapshot T3 --off"
expect stopped "${L[@]}"
for id in "${L[@]}"; do has_snap "$id" T2 && has_snap "$id" T3 && ok "$id has T2 and T3" || bad "$id misses T2/T3"; done

step "12. protected guests"
if ((${#L[@]} >= 2)); then
    cx pve-range --yes --protect "${L[0]}" power-on --only "${L[0]},${L[1]}" >>"$OUT" 2>&1
    expect stopped "${L[0]}"
    expect running "${L[1]}"
    pr power-off --only "${L[1]}" --hard
fi

step "13. port mirroring through the ovs-vsctl-only key"
SN=$(cx sh -c "$A/pvesh get /cluster/resources --type vm | jq -r '.[] | select(.vmid == 510002) | .node'" 2>/dev/null)
if [[ -n $SN ]] && cxu env PVE_TARGET_NODE="$SN" "$A/ovs-vsctl" list-br >"$LAST" 2>&1; then
    ok "the key may run ovs-vsctl on $SN ($(tr '\n' ' ' <"$LAST"))"
    ip=$(cx sh -c "$A/pvesh get /cluster/status | jq -r '.[] | select(.name == \"$SN\") | .ip'")
    cxu ssh -n -i /data/ssh/ovs_ed25519 -o BatchMode=yes -o IdentitiesOnly=yes -o UserKnownHostsFile=/data/ssh/known_hosts \
        "root@$ip" id >"$LAST" 2>&1
    grep -q 'uid=' "$LAST" && bad "the mirroring key can run OTHER commands - check the authorized_keys line" ||
        ok "the key can't run anything else ($(tail -1 "$LAST"))"
    TYPE[510002]=qemu
    cx sh -c "cp -f /data/conf/mirrors.conf /data/conf/mirrors.conf.dtest 2>/dev/null; echo '$SN|vmbr2|510002:net1' > /data/conf/mirrors.conf"
    pr power-on --only 510002
    cx env PVE_RANGE_NODE="$SN" pve-range --yes mirror-apply >"$LAST" 2>&1; check_rc $? "mirror-apply"
    cx env PVE_RANGE_NODE="$SN" pve-range mirror-status >"$LAST" 2>&1
    grep -q 'tap510002i1' "$LAST" && ok "mirror-status shows the sensor port" || bad "mirror not found in mirror-status"
    cx env PVE_RANGE_NODE="$SN" pve-range --yes mirror-clear vmbr2 >"$LAST" 2>&1; check_rc $? "mirror-clear"
    cx sh -c "if [ -f /data/conf/mirrors.conf.dtest ]; then mv /data/conf/mirrors.conf.dtest /data/conf/mirrors.conf; else rm -f /data/conf/mirrors.conf; fi"
    pr power-off --only 510002 --hard
else
    skp "port mirroring not set up (optional - the ovs-vsctl key line from the log)"
fi

step "14. web sign-in (as the web page does it)"
printf '%s\n%s\n' "$TPASS" "$TPASS" | cx pve-range-web-users add "$TUSER" >>"$OUT" 2>&1 &&
    ok "test user $TUSER created" || bad "couldn't create a test user"
cx pve-range-web-users unlock >/dev/null 2>&1
printf '%s\n%s\n' "$TUSER" "$TPASS" | cxu env LOGIN_IDLE=3 pve-range-web >/dev/null 2>&1
cx tail -n 20 /data/auth.log 2>/dev/null | grep -q "sign-in OK: $TUSER" && ok "correct password signs in" || bad "sign-in with the right password not logged"
printf '%s\n%s\n' "$TUSER" "wrong-password" | cxu env LOGIN_IDLE=3 pve-range-web >/dev/null 2>&1
cx tail -n 20 /data/auth.log 2>/dev/null | grep -q "sign-in FAILED for '$TUSER'" && ok "wrong password is refused and logged" || bad "wrong password not logged"
cx pve-range-web-users del "$TUSER" >/dev/null 2>&1 && ok "test user removed" || bad "couldn't remove the test user"
cx pve-range-web-users unlock >/dev/null 2>&1

step "15. save & share"
if cx sh -c 'command -v git' >/dev/null; then
    pr save "docker-test $(date +%F_%T)"; check_rc $? "save (history$(cx sh -c 'grep -q "^REPO_URL=." /data/share/save.conf 2>/dev/null' && echo ' + repository'))"
else
    bad "git missing in the image"
fi
if cx sh -c 'grep -q "^BACKUP_STORAGE=." /data/share/save.conf 2>/dev/null'; then
    pr backup; check_rc $? "backup"
    cx test -f "$(tail -1 "$LAST")" && ok "backup file written in the volume" || bad "no backup file"
else
    skp "no backup storage set (Save & share -> Settings -> container volume)"
fi

step "Cleanup"
pr power-off --only "$LS" --hard
for id in "${L[@]}"; do
    for s in T3 T2 T1; do has_snap "$id" "$s" && cx "$(gtool "$id")" delsnapshot "$id" "$s" >>"$OUT" 2>&1; done
    [[ -z ${HAD[$id]} ]] && has_marker "$id" && cx "$(gtool "$id")" set "$id" --delete onboot >>"$OUT" 2>&1
done
echo "  removed T1/T2/T3, test markers and the test user"

echo
echo "=================================="
echo " $pass passed, $fail failed, $skip skipped   ($ENG)"
echo " full log: $OUT"
echo "=================================="
((fail == 0))
