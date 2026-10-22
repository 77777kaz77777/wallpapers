#!/usr/bin/env bash
# range-seed.sh - small fake range for testing pve-range in a nested cluster
#
# Uses your real VMID scheme (AABCDD), so the folders 612 / 613 / NetWars work:
#   612 (50xxxx) on the OTHER node, 613 (51xxxx) on THIS node, NetWars (52xxxx) on both.
# Guests have no OS (they sit at the BIOS) - that's all pve-range needs.
# Every guest it makes is tagged "fake-range", and only tagged guests are ever removed.
#
# Run on one node as root:
#   ./range-seed.sh clean  TDpve1      remove the OLD dummies (lab-*, dragos-sensor-1)
#   ./range-seed.sh create TDpve1      build the fake range
#   ./range-seed.sh remove TDpve1      delete the fake range again (tag fake-range)
#   add --dry-run to only show what would happen, --with-104 (clean) to also remove CT 104
set -u
CMD=${1:-}
OTHER=${2:-}
shift 2 2>/dev/null || true
DRY=0 WITH104=0
for a in "$@"; do
    case $a in --dry-run) DRY=1 ;; --with-104) WITH104=1 ;; esac
done
LOCAL=$(hostname -s)
STORE=local-lvm
TAG=fake-range

usage() { sed -n '2,15p' "$0"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ $CMD =~ ^(clean|create|remove)$ && -n $OTHER ]] || usage
[[ $OTHER != "$LOCAL" ]] || { echo "Give the OTHER node's name (you are on $LOCAL)."; exit 1; }
ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$OTHER" true || { echo "Can't ssh to root@$OTHER."; exit 1; }

run_on() {   # node cmd...
    local n=$1; shift
    if ((DRY)); then echo "   [dry-run] [$n] $*"; return 0; fi
    if [[ $n == "$LOCAL" ]]; then bash -c "$*"; else ssh -n -o BatchMode=yes "root@$n" "$*"; fi
}
conf_of() { compgen -G "/etc/pve/nodes/*/qemu-server/$1.conf" || compgen -G "/etc/pve/nodes/*/lxc/$1.conf"; }
exists()  { [[ -n $(conf_of "$1") ]]; }
node_of() { conf_of "$1" | cut -d/ -f5; }
is_ct()   { [[ $(conf_of "$1") == */lxc/* ]]; }
name_of() { awk -F': ' '/^\[/ {exit} $1 == "name" || $1 == "hostname" {print $2; exit}' "$(conf_of "$1")"; }
tags_of() { awk -F': ' '/^\[/ {exit} $1 == "tags" {print $2; exit}' "$(conf_of "$1")"; }

destroy() {   # id
    local id=$1 n
    n=$(node_of "$id")
    if is_ct "$id"; then
        run_on "$n" "pct unlock $id 2>/dev/null; pct stop $id >/dev/null 2>&1; pct destroy $id --purge 1 --force 1"
    else
        run_on "$n" "qm unlock $id 2>/dev/null; qm stop $id --skiplock 1 >/dev/null 2>&1; qm destroy $id --purge 1 --destroy-unreferenced-disks 1 --skiplock 1"
    fi && echo "   removed $id"
}

confirm_list() {   # ids...
    local id
    (($#)) || { echo "Nothing to remove."; exit 0; }
    echo "These will be DELETED (with all their disks and snapshots):"
    for id in "$@"; do printf '   %-8s %-24s on %s\n' "$id" "$(name_of "$id")" "$(node_of "$id")"; done
    ((DRY)) && return 0
    read -rp "Type yes to delete them: " a
    [[ $a == yes ]] || { echo "Cancelled."; exit 1; }
}

###############################################################################
if [[ $CMD == clean ]]; then
    # Old lab-seed.sh guests: only if the name still matches what the seed created
    ids=()
    for f in /etc/pve/nodes/*/qemu-server/*.conf /etc/pve/nodes/*/lxc/*.conf; do
        [[ -e $f ]] || continue
        id=$(basename "$f" .conf)
        nm=$(name_of "$id")
        if [[ $id =~ ^9[0-9]{3}$ && $nm == lab-* ]] ||
            [[ $id == 501402 && $nm == dragos-sensor-1 ]] ||
            [[ $id =~ ^51040[0-5]$ && $nm == lab-ent-client-* ]]; then
            ids+=("$id")
        fi
    done
    ((WITH104)) && exists 104 && ids+=(104)
    confirm_list "${ids[@]}"
    for id in "${ids[@]}"; do destroy "$id"; done
    if ((WITH104)) && ((!DRY)); then
        sed -i '/from="192.168.77.90"/d' /etc/pve/priv/authorized_keys && echo "   removed CT 104's key line"
    fi
    echo "Old dummies removed. Next: $0 create $OTHER"
    exit 0
fi

if [[ $CMD == remove ]]; then
    ids=()
    for f in /etc/pve/nodes/*/qemu-server/*.conf /etc/pve/nodes/*/lxc/*.conf; do
        [[ -e $f ]] || continue
        id=$(basename "$f" .conf)
        [[ ";$(tags_of "$id");" == *";$TAG;"* ]] && ids+=("$id")
    done
    confirm_list "${ids[@]}"
    for id in "${ids[@]}"; do destroy "$id"; done
    exit 0
fi

###############################################################################
# create
###############################################################################
echo "== Bridges and storage"
for n in "$LOCAL" "$OTHER"; do
    run_on "$n" "command -v ovs-vsctl >/dev/null || apt-get install -y openvswitch-switch >/dev/null
        grep -q '^iface vmbr2' /etc/network/interfaces || { pvesh create /nodes/$n/network --iface vmbr2 --type OVSBridge --autostart 1 && pvesh set /nodes/$n/network; }"
done
pvesm status | grep -q '^lab-qcow2 ' || run_on "$LOCAL" "pvesm add dir lab-qcow2 --path /var/lib/lab-qcow2 --content images"

echo "== Container template on both nodes"
TMPL=$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/ {print $2; exit}')
[[ -n $TMPL ]] || { pveam update >/dev/null; TMPL=$(pveam available --section system | awk '/debian-12-standard/ {print $2; exit}'); }
for n in "$LOCAL" "$OTHER"; do
    run_on "$n" "[ -f /var/lib/vz/template/cache/$TMPL ] || { pveam update >/dev/null; pveam download local $TMPL; }"
done

# vm NODE ID NAME CLASS-TAG SNAP [extra qm create options]
#   SNAP: snap = ClassStart, ram = ClassStart with RAM (left running), none
vm() {
    local n=$1 id=$2 name=$3 cls=$4 snap=$5; shift 5
    if exists "$id"; then echo "   $id exists - skipped"; return; fi
    run_on "$n" "qm create $id --name $name --memory 256 --cores 1 --kvm 0 --ostype l26 \
        --scsihw virtio-scsi-single --scsi0 $STORE:1 --net0 virtio,bridge=vmbr0 --tags '$TAG;$cls' $*" || return
    case $snap in
        snap) run_on "$n" "qm snapshot $id ClassStart" ;;
        ram) run_on "$n" "qm start $id && qm snapshot $id ClassStart --vmstate 1" ;;
    esac
    echo "   + $id $name ($snap) on $n"
}
ct() {   # NODE ID NAME CLASS-TAG SNAP
    local n=$1 id=$2 name=$3 cls=$4 snap=$5
    if exists "$id"; then echo "   $id exists - skipped"; return; fi
    run_on "$n" "pct create $id local:vztmpl/$TMPL --hostname $name --memory 256 --rootfs $STORE:1 \
        --net0 name=eth0,bridge=vmbr0,ip=dhcp --unprivileged 1 --tags '$TAG;$cls'" || return
    [[ $snap == snap ]] && run_on "$n" "pct snapshot $id ClassStart"
    echo "   + $id $name (container, $snap) on $n"
}
EFI='--bios ovmf --machine q35 --efidisk0'

echo "== 612 (50xxxx) on $OTHER"
ct "$OTHER" 500001 612-mgmt-01       612 snap
vm "$OTHER" 500101 612-l3-srv-01     612 ram
vm "$OTHER" 500102 612-l3-srv-02     612 snap
vm "$OTHER" 500201 612-ews-01        612 snap
vm "$OTHER" 500301 612-ows-01        612 snap
vm "$OTHER" 500401 612-idmz-fs-01    612 snap
vm "$OTHER" 500501 612-jump-01       612 none
vm "$OTHER" 500601 612-dragos-sensor "612;sensor" snap --net1 virtio,bridge=vmbr2,firewall=1

echo "== 613 (51xxxx) on $LOCAL"
ct "$LOCAL" 510001 613-mgmt-01       613 snap
vm "$LOCAL" 510002 613-tenable       "613;sensor" snap --net1 virtio,bridge=vmbr2,firewall=0
vm "$LOCAL" 510101 613-ent-srv-01    613 snap
vm "$LOCAL" 510201 613-ics-srv-01    613 snap
vm "$LOCAL" 510401 613-ent-client-01 613 none "$EFI $STORE:1,efitype=4m,pre-enrolled-keys=1"
vm "$LOCAL" 510402 613-ent-client-02 613 none "$EFI $STORE:1,efitype=4m,pre-enrolled-keys=0"
vm "$LOCAL" 510403 613-ent-client-03 613 none "$EFI $STORE:1,efitype=4m,pre-enrolled-keys=0"
vm "$LOCAL" 510501 613-jump-01       613 none
vm "$LOCAL" 510601 613-ews-01        613 snap

echo "== NetWars (52xxxx) on both nodes"
vm "$OTHER" 521001 nw-grid-srv-01     netwars snap
vm "$OTHER" 521101 nw-grid-l3-01      netwars snap
vm "$LOCAL" 522001 nw-cookie-srv-01   netwars snap

echo "== Example class guides"
G=/etc/pve/pve-range/guides
if ((!DRY)); then
    mkdir -p "$G"
    [[ -e $G/612.txt ]] || cat >"$G/612.txt" <<'EOF'
Class guide - 612 (fake test range)
===================================
BEFORE CLASS
  - Check both nodes are online (Overview)

START OF CLASS
  1. Start class - snapshot ClassStart
     Keep as they are: 500501 612-jump-01 (has no snapshot)
     500101 has a RAM snapshot - it comes back running by itself
  2. Set up / Re-apply mirrors: vmbr2 -> 500601 612-dragos-sensor
  3. Mirror status - packets should go up

END OF CLASS
  1. End class (graceful, or hard power-off - no OS in this lab)

ADD-ONS FOR THIS CLASS
  - Unlock guests (if a start fails with a lock)
EOF
    [[ -e $G/613.txt ]] || cat >"$G/613.txt" <<'EOF'
Class guide - 613 (fake test range)
===================================
PREP (once, before snapshotting)
  1. Move / convert: 510401-510403 to lab-qcow2 as qcow2
  2. EFI keys: 510402, 510403 (510401 already has them)
  3. Network settings: clients net0 -> vmbr2, VLAN 50
  4. Take snapshot ClassStart on the clients

START OF CLASS
  1. Start class - snapshot ClassStart
     Keep as they are: 510501 613-jump-01
  2. Re-apply mirrors: vmbr2 -> 510002 613-tenable

END OF CLASS
  1. End class
EOF
fi

echo
echo "Done. In pve-range: Settings -> Protected guests = 100-105 (your real guests),"
echo "then pick a folder (612, 613, NetWars) and try the menu."
