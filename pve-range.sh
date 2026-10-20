#!/usr/bin/env bash
#
# pve-range.sh - one script for running the Proxmox VE lab / cyber range
# (formerly pve-lab.sh - old settings in /etc/pve-lab are picked up automatically)
#
# Replaces the per-server startvms.sh / startmirror.sh scripts and the
# copy-paste loops for disks, EFI keys, networking, snapshots and migration.
# Nothing is hard-coded - everything is detected live from the cluster:
#
#   guests, names, nodes, status, tags  -> pvesh /cluster/resources
#   snapshots, NICs, disks, EFI state   -> /etc/pve/nodes/*/{qemu-server,lxc}/*.conf
#   nodes, bridges, OVS bridges         -> pvesh /nodes
#   storages                            -> pvesm status
#
# It can be run from ANY node: commands for guests on other nodes are sent
# there over the cluster's root SSH trust.
#
#   ./pve-range.sh                 whiptail menu
#   ./pve-range.sh --help          command-line usage (for cron / automation)
#
set -o pipefail

VERSION="2.1"
PVE_ROOT=${PVE_ROOT:-/etc/pve}
CONF_DIR=${PVE_RANGE_CONF_DIR:-/etc/pve-range}
SETTINGS_FILE="$CONF_DIR/settings.conf"
GROUPS_FILE="$CONF_DIR/groups.conf"
MIRRORS_FILE="$CONF_DIR/mirrors.conf"
LOG_FILE=${PVE_RANGE_LOG:-/var/log/pve-range.log}
LOCAL_NODE=${PVE_RANGE_NODE:-$(hostname -s)}

# One-time move of the settings from the old name (pve-lab)
if [[ -z ${PVE_RANGE_CONF_DIR:-} && ! -e $CONF_DIR && -d /etc/pve-lab ]]; then
    cp -a /etc/pve-lab "$CONF_DIR" 2>/dev/null
fi

# Defaults - can be changed in the Settings menu (saved to $SETTINGS_FILE)
START_DELAY=1
SHUTDOWN_TIMEOUT=180   # seconds before a graceful shutdown is forced off
MAX_PARALLEL=8         # shutdowns running at the same time
DEFAULT_SNAP="ClassStart"
SENSOR_PATTERN='dragos|sensor|tenable|zeek|suricata|snort|onion|nsm'
PROTECTED=""        # VMIDs/ranges pve-range never touches, e.g. "100-103"
THEME=midnight      # midnight | ocean | classic
ASK_FOLDER=1        # ask for the folder (class) when the menu opens
LAST_FOLDER=""
ADDON_EDIT_WEB=0    # 1 = web users may create/edit add-ons (they run as root!)
FOLDER=""           # current folder; "" or all = everything
# shellcheck source=/dev/null
[[ -r $SETTINGS_FILE ]] && . "$SETTINGS_FILE"

DRY_RUN=${DRY_RUN:-0}
AUTO_YES=0
INTERACTIVE=0

if [[ -t 1 ]]; then
    C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_C=$'\e[36m' C_B=$'\e[1m' C_0=$'\e[0m'
else
    C_R='' C_G='' C_Y='' C_C='' C_B='' C_0=''
fi

# Web users are passed in by pve-range-web (LC_PVERANGE_USER) so the log shows who did what
WEB_USER=${LC_PVERANGE_USER:-}
[[ $WEB_USER =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || WEB_USER=""
log() { printf '%s %s%s\n' "$(date '+%F %T')" "${WEB_USER:+[$WEB_USER] }" "$*" >>"$LOG_FILE" 2>/dev/null; }
die() { echo "${C_R}error:${C_0} $*" >&2; exit 1; }
trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

###############################################################################
# Detection
###############################################################################
declare -A G_TYPE=() G_NODE=() G_STATUS=() G_NAME=() G_TAGS=()
GUEST_IDS=()
PROTECTED_IDS=()   # "id<TAB>type<TAB>node<TAB>status<TAB>name" of hidden guests

# in_ranges ID "100-103,9000"  -> true if ID is inside
in_ranges() {
    local id=$1 tok lo hi
    for tok in ${2//,/ }; do
        if [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo=$((10#${BASH_REMATCH[1]})) hi=$((10#${BASH_REMATCH[2]}))
        elif [[ $tok =~ ^[0-9]+$ ]]; then
            lo=$((10#$tok)) hi=$lo
        else
            continue
        fi
        ((id >= lo && id <= hi)) && return 0
    done
    return 1
}
NODES=()

INV_OK=0
INV_TTL=${INV_TTL:-15}   # seconds the inventory is reused before it is read again
inventory_dirty() { INV_OK=0; }

load_inventory() {
    if ((INV_OK && SECONDS - INV_AT < INV_TTL)); then return 0; fi
    # Fast path: read the cluster files directly (pvesh costs ~1 s of CPU per call)
    if [[ -r $PVE_ROOT/.vmlist ]] && load_inventory_fast; then
        apply_folder
        INV_OK=1 INV_AT=$SECONDS
        return 0
    fi
    load_inventory_pvesh || return 1
    apply_folder
    INV_OK=1 INV_AT=$SECONDS
}

inv_add_guest() {   # id type node status name tags
    local id=$1 type=$2 node=$3 status=$4 name=$5 tags=$6
    if [[ -n $PROTECTED ]] && in_ranges "$id" "$PROTECTED"; then
        PROTECTED_IDS+=("$id"$'\t'"$type"$'\t'"$node"$'\t'"$status"$'\t'"$name")
        return
    fi
    GUEST_IDS+=("$id")
    G_TYPE[$id]=$type G_NODE[$id]=$node G_STATUS[$id]=$status G_NAME[$id]=$name
    [[ $tags == - ]] && tags=""
    G_TAGS[$id]=$tags
}

# Shell snippet that prints "<vmid> running|stopped" for every guest on one node
status_snippet() {
    local d="$PVE_ROOT/nodes/$1"
    cat <<EOF
for f in $d/qemu-server/*.conf; do [ -e "\$f" ] || continue; id=\${f##*/}; id=\${id%.conf}
  p=\$(cat /var/run/qemu-server/\$id.pid 2>/dev/null)
  if [ -n "\$p" ] && kill -0 "\$p" 2>/dev/null; then echo "\$id running"; else echo "\$id stopped"; fi; done
for f in $d/lxc/*.conf; do [ -e "\$f" ] || continue; id=\${f##*/}; id=\${id%.conf}
  if lxc-info -n "\$id" -s 2>/dev/null | grep -q RUNNING; then echo "\$id running"; else echo "\$id stopped"; fi; done
echo END-OF-STATUS
EOF
}

load_inventory_fast() {
    local tmp kind id type node status name tags n
    tmp=$(mktemp -d)
    # Guests (.vmlist), names/tags (configs) and online nodes (.members) in one perl run
    perl -MJSON::PP -e '
        my $root = shift;
        sub rd { local $/; open(my $f, "<", $_[0]) or return undef; my $c = <$f>; return $c }
        my $vl = decode_json(rd("$root/.vmlist") // die "no .vmlist\n");
        my $m  = eval { decode_json(rd("$root/.members") // "{}") } // {};
        my $nl = $m->{nodelist} // {};
        for my $n (sort keys %$nl) { print "N\t$n\n" if $nl->{$n}{online} }
        my $ids = $vl->{ids} // {};
        for my $id (sort { $a <=> $b } keys %$ids) {
            my $e = $ids->{$id};
            next unless ($e->{type} // "") =~ /^(qemu|lxc)$/;
            my $dir = $e->{type} eq "lxc" ? "lxc" : "qemu-server";
            my $c = rd("$root/nodes/$e->{node}/$dir/$id.conf") // next;
            $c =~ s/\n\[.*//s;                       # current config only
            next if $c =~ /^template:\s*1/m;
            my ($name) = $c =~ /^(?:name|hostname):\s*(\S+)/m;
            my ($tags) = $c =~ /^tags:\s*(\S+)/m;
            print join("\t", "G", $id, $e->{type}, $e->{node}, "unknown", $name // "-", $tags // "-"), "\n";
        }' "$PVE_ROOT" >"$tmp/inv" 2>/dev/null || { rm -rf "$tmp"; return 1; }

    G_TYPE=() G_NODE=() G_STATUS=() G_NAME=() G_TAGS=() GUEST_IDS=() PROTECTED_IDS=() NODES=()
    while IFS=$'\t' read -r kind id type node status name tags; do
        if [[ $kind == N ]]; then NODES+=("$id"); else inv_add_guest "$id" "$type" "$node" "$status" "$name" "$tags"; fi
    done <"$tmp/inv"
    ((${#NODES[@]})) || NODES=("$LOCAL_NODE")

    # Live power state: one quick shell run per node (over SSH for the others), in parallel
    for n in "${NODES[@]}"; do
        run_on "$n" "$(status_snippet "$n")" >"$tmp/st.$n" 2>/dev/null &
    done
    wait
    local -A st=()
    for n in "${NODES[@]}"; do
        if grep -q '^END-OF-STATUS$' "$tmp/st.$n"; then
            while read -r id status; do
                [[ $id =~ ^[0-9]+$ ]] && st[$id]=$status
            done <"$tmp/st.$n"
        else
            # Couldn't reach the node over SSH - fall back to the API for it
            local kind2
            for kind2 in qemu lxc; do
                while IFS=$'\t' read -r id status; do st[$id]=$status; done < <(
                    pvesh get "/nodes/$n/$kind2" --output-format json 2>/dev/null | perl -MJSON::PP -e '
                        local $/; print "$_->{vmid}\t$_->{status}\n" for @{decode_json(<STDIN>)}' 2>/dev/null)
            done
        fi
    done
    for id in "${GUEST_IDS[@]}"; do [[ -n ${st[$id]} ]] && G_STATUS[$id]=${st[$id]}; done
    rm -rf "$tmp"
}

load_inventory_pvesh() {
    local tmp id type node status name tags n kind f
    tmp=$(mktemp -d)
    if ! pvesh get /cluster/resources --output-format json >"$tmp/res" 2>/dev/null; then
        rm -rf "$tmp"
        echo "Could not query the cluster (pvesh get /cluster/resources)." >&2
        return 1
    fi
    G_TYPE=() G_NODE=() G_STATUS=() G_NAME=() G_TAGS=() GUEST_IDS=() PROTECTED_IDS=() NODES=()
    while IFS=$'\t' read -r kind id type node status name tags; do
        if [[ $kind == N ]]; then NODES+=("$id"); continue; fi
        [[ $id =~ ^[0-9]+$ ]] && inv_add_guest "$id" "$type" "$node" "$status" "$name" "$tags"
    done < <(perl -MJSON::PP -e '
        local $/; my $d = decode_json(<STDIN>);
        print "N\t$_->{node}\n" for sort { $a->{node} cmp $b->{node} }
            grep { $_->{type} eq "node" && ($_->{status} // "") eq "online" } @$d;
        for my $r (sort { $a->{vmid} <=> $b->{vmid} } grep { $_->{type} =~ /^(qemu|lxc)$/ } @$d) {
            next if $r->{template};
            my $n = (defined $r->{name} && length $r->{name}) ? $r->{name} : "-";
            my $t = (defined $r->{tags} && length $r->{tags}) ? $r->{tags} : "-";
            print join("\t", "G", $r->{vmid}, $r->{type}, $r->{node}, $r->{status} // "unknown", $n, $t), "\n";
        }' <"$tmp/res" 2>/dev/null)
    ((${#NODES[@]})) || NODES=("$LOCAL_NODE")
    for n in "${NODES[@]}"; do
        for kind in qemu lxc; do
            pvesh get "/nodes/$n/$kind" --output-format json >"$tmp/live.$n.$kind" 2>/dev/null &
        done
    done
    wait
    for f in "$tmp"/live.*; do
        [[ -s $f ]] || continue
        while IFS=$'\t' read -r id status; do
            [[ -n $id && -n ${G_TYPE[$id]} ]] && G_STATUS[$id]=$status
        done < <(perl -MJSON::PP -e 'local $/; my $d = decode_json(<STDIN>);
            print "$_->{vmid}\t$_->{status}\n" for @$d' <"$f" 2>/dev/null)
    done
    rm -rf "$tmp"
}

# node_bridges NODE [any_bridge|OVSBridge|bridge] -> "iface<TAB>type" lines
node_bridges() {
    local want=${2:-any_bridge} out
    # Read /etc/network/interfaces on the node (fast); fall back to the API
    out=$(run_on "$1" 'cat /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null' 2>/dev/null |
        awk -v want="$want" '
            $1 == "iface" {cur = $2}
            $1 == "ovs_type" && $2 == "OVSBridge" {t[cur] = "OVSBridge"}
            ($1 == "bridge-ports" || $1 == "bridge_ports") && !(cur in t) {t[cur] = "bridge"}
            END {for (i in t) if (want == "any_bridge" || want == t[i]) print i "\t" t[i]}' | sort)
    if [[ -n $out ]]; then echo "$out"; return; fi
    pvesh get "/nodes/$1/network" --type "$want" --output-format json 2>/dev/null |
        perl -MJSON::PP -e 'local $/; my $d = decode_json(<STDIN>);
            print "$_->{iface}\t$_->{type}\n" for sort { $a->{iface} cmp $b->{iface} } @$d' 2>/dev/null
}

is_qemu()   { [[ ${G_TYPE[$1]} == qemu ]]; }
guest_cmd() { if is_qemu "$1"; then echo qm; else echo pct; fi; }

conf_file() {
    local dir=qemu-server
    [[ ${G_TYPE[$1]} == lxc ]] && dir=lxc
    echo "$PVE_ROOT/nodes/${G_NODE[$1]}/$dir/$1.conf"
}
# Current config only (stops at the first [snapshot] / [PENDING] section)
conf_main() { awk '/^\[/ {exit} {print}' "$(conf_file "$1")" 2>/dev/null; }
conf_get()  { conf_main "$1" | awk -v k="$2" 'index($0, k": ") == 1 {print substr($0, length(k) + 3); exit}'; }
snapshots_of() {
    grep -oE '^\[[^]]+\]' "$(conf_file "$1")" 2>/dev/null | tr -d '[]' | grep -vE '^PENDING$|:'
}
has_snapshot() { grep -qxF "[$2]" "$(conf_file "$1")" 2>/dev/null; }
snap_has_vmstate() {
    awk -v s="[$2]" '$0 == s {f = 1; next} /^\[/ {f = 0} f && /^vmstate: / {found = 1}
                     END {exit !found}' "$(conf_file "$1")" 2>/dev/null
}

guest_label() {
    local id=$1 t=""
    local st=${G_STATUS[$id]}
    if ((UI_UTF8)); then
        if [[ ${G_TYPE[$id]} == lxc ]]; then t="▣ "; else t="▢ "; fi
        case $st in running) st="● running" ;; stopped) st="○ stopped" ;; *) st="? $st" ;; esac
    else
        [[ ${G_TYPE[$id]} == lxc ]] && t="CT "
    fi
    printf '%-24.24s %-9.9s %-10s %s' "$t${G_NAME[$id]}" "${G_NODE[$id]}" "$st" "$(vmid_desc "$id")"
}

# ids_in_ranges "510400-510430,102 300-399"  -> existing VMIDs inside those ranges
ids_in_ranges() {
    local tok id i
    local -a los=() his=()
    for tok in ${1//,/ }; do
        if [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
            los+=($((10#${BASH_REMATCH[1]}))); his+=($((10#${BASH_REMATCH[2]})))
        elif [[ $tok =~ ^[0-9]+$ ]]; then
            los+=($((10#$tok))); his+=($((10#$tok)))
        else
            echo "Ignoring '$tok' (not a VMID or range)" >&2
        fi
    done
    for id in "${GUEST_IDS[@]}"; do
        for i in "${!los[@]}"; do
            if ((id >= los[i] && id <= his[i])); then echo "$id"; break; fi
        done
    done
}

# net_set "<netX value>" key=value ...   (an empty value removes the key)
# Keeps the model and MAC address, so guests don't see a "new" NIC.
net_set() {
    local str=$1 kv k v i found
    shift
    local -a parts
    IFS=',' read -ra parts <<<"$str"
    for kv in "$@"; do
        k=${kv%%=*} v=${kv#*=} found=0
        for i in "${!parts[@]}"; do
            [[ ${parts[i]%%=*} == "$k" ]] || continue
            found=1
            if [[ -n $v ]]; then parts[i]="$k=$v"; else unset 'parts[i]'; fi
        done
        ((found)) || [[ -z $v ]] || parts+=("$k=$v")
    done
    local IFS=,
    echo "${parts[*]}"
}
# net_set_model "<netX value>" e1000   (keeps the MAC)
net_set_model() {
    local str=$1 first rest
    first=${str%%,*} rest=${str#"$first"}
    if [[ $first == *=* ]]; then echo "$2=${first#*=}$rest"; else echo "$2$rest"; fi
}


# Device name of a guest NIC on the host bridge
nic_dev() {
    local n=${2#net}
    if [[ ${G_TYPE[$1]} == lxc ]]; then echo "veth${1}i$n"; else echo "tap${1}i$n"; fi
}

###############################################################################
# Command plan: build a list of commands, show it, then run it
###############################################################################
PLAN=()
PLAN_NOTES=()
FAILED=()

plan_reset() { PLAN=(); PLAN_NOTES=(); }
# shell-quote only the arguments that need it (keeps "a=b,c=d" readable)
shq() {
    local a out=""
    for a in "$@"; do
        if [[ $a =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then out+="$a "; else out+="$(printf '%q' "$a") "; fi
    done
    echo "${out% }"
}
plan_add()   { local node=$1; shift; PLAN+=("$node"$'\t'"$(shq "$@")"); }
# Background steps run in parallel (up to MAX_PARALLEL) until the next plan_wait
plan_add_bg() { local node=$1; shift; PLAN+=("@bg:$node"$'\t'"$(shq "$@")"); }
plan_wait()  { PLAN+=("@wait"$'\t'"-"); }
plan_sleep() { PLAN+=("@sleep"$'\t'"$1"); }
plan_note()  { PLAN_NOTES+=("$*"); }
plan_steps() {
    local e n=0
    for e in "${PLAN[@]}"; do [[ $e == @sleep* || $e == @wait* ]] || ((n++)); done
    echo "$n"
}

plan_text() {
    local e node
    for e in "${PLAN[@]}"; do
        node=${e%%$'\t'*}
        case $node in
            @sleep) continue ;;
            @wait) echo "    ... wait for the commands above to finish" ;;
            @bg:*) printf '[%s] %s   (in parallel)\n' "${node#@bg:}" "${e#*$'\t'}" ;;
            *) printf '[%s] %s\n' "$node" "${e#*$'\t'}" ;;
        esac
    done
    if ((${#PLAN_NOTES[@]})); then
        echo
        echo "Notes:"
        printf '  - %s\n' "${PLAN_NOTES[@]}"
    fi
}

run_on() {
    if [[ $1 == "$LOCAL_NODE" ]]; then
        bash -c "$2"
    else
        ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@$1" "$2"
    fi
}

BG_PIDS=() BG_DESC=() BG_OUT=()
bg_collect_first() {
    local rc=0
    wait "${BG_PIDS[0]}" || rc=$?
    echo "      ${C_C}finished:${C_0} ${BG_DESC[0]}"
    sed 's/^/      /' "${BG_OUT[0]}" | tee -a "$LOG_FILE"
    if ((rc == 0)); then
        ((PLAN_OK++))
    else
        FAILED+=("${BG_DESC[0]}")
        echo "      ${C_R}^ failed${C_0}"
        log "FAILED: ${BG_DESC[0]}"
    fi
    rm -f "${BG_OUT[0]}"
    BG_PIDS=("${BG_PIDS[@]:1}") BG_DESC=("${BG_DESC[@]:1}") BG_OUT=("${BG_OUT[@]:1}")
}
bg_collect_all() { while ((${#BG_PIDS[@]})); do bg_collect_first; done; }

# plan_run "Title"  -> 0 if executed, 1 if nothing to do / cancelled
plan_run() {
    local title=$1 n f
    n=$(plan_steps)
    if ((n == 0)); then
        local m="Nothing to do."
        ((${#PLAN_NOTES[@]})) && m+=$'\n\n'"$(printf -- '- %s\n' "${PLAN_NOTES[@]}")"
        ui_msg "$m" "$title"
        return 1
    fi

    if ((INTERACTIVE)); then
        f=$(mktemp)
        { echo "$title - $n command(s):"; echo; plan_text; } >"$f"
        textfile "Review: $title" "$f"
        rm -f "$f"
        local q="Run these $n command(s) now?"
        ((DRY_RUN)) && q+=$'\n\n'"DRY-RUN is on: commands will only be printed."
        confirm "$title" "$q" || return 1
        clear
    else
        echo "${C_B}$title - $n command(s):${C_0}"
        plan_text
        echo
        if ((!AUTO_YES)); then
            local a
            read -rp "Run them? [y/N] " a
            [[ $a == [yY]* ]] || return 1
        fi
    fi

    if ((UI_UTF8)); then echo "${C_C}━━━━${C_0} ${C_B}$title${C_0} ${C_C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_0}"
    else echo "${C_B}== $title ==${C_0}"; fi
    ((DRY_RUN)) && echo "${C_Y}DRY-RUN: nothing is being changed.${C_0}"
    log "== $title (dry-run=$DRY_RUN)"
    local e node cmd i=0 abort=0 bg out
    PLAN_OK=0 FAILED=() BG_PIDS=() BG_DESC=() BG_OUT=()
    trap 'abort=1' INT
    for e in "${PLAN[@]}"; do
        if ((abort)); then echo "${C_Y}Stopped by Ctrl-C.${C_0}"; log "aborted by user"; break; fi
        node=${e%%$'\t'*} cmd=${e#*$'\t'}
        case $node in
            @sleep) ((DRY_RUN)) || sleep "$cmd"; continue ;;
            @wait) bg_collect_all; continue ;;
        esac
        bg=0
        [[ $node == @bg:* ]] && bg=1 node=${node#@bg:}
        ((i++))
        printf '%s[%d/%d]%s %s[%s]%s %s%s\n' "$C_B" "$i" "$n" "$C_0" "$C_C" "$node" "$C_0" "$cmd" "$( ((bg)) && echo '   &')"
        log "[$node] $cmd"
        ((DRY_RUN)) && continue
        if ((bg)); then
            ((${#BG_PIDS[@]} >= MAX_PARALLEL)) && bg_collect_first
            out=$(mktemp)
            run_on "$node" "$cmd" >"$out" 2>&1 &
            BG_PIDS+=($!) BG_DESC+=("[$node] $cmd") BG_OUT+=("$out")
            continue
        fi
        if run_on "$node" "$cmd" 2>&1 | sed -u 's/^/      /' | tee -a "$LOG_FILE"; then
            ((PLAN_OK++))
        else
            FAILED+=("[$node] $cmd")
            echo "      ${C_R}^ failed${C_0}"
            log "FAILED: [$node] $cmd"
        fi
    done
    bg_collect_all
    trap - INT
    inventory_dirty
    local ok=$PLAN_OK

    echo
    if ((DRY_RUN)); then
        echo "${C_Y}Dry-run finished - $n command(s) shown.${C_0}"
    elif ((${#FAILED[@]})); then
        echo "${C_R}$ok succeeded, ${#FAILED[@]} failed.${C_0}"
    else
        echo "${C_G}All $ok command(s) succeeded.${C_0}"
    fi
    if ((${#PLAN_NOTES[@]})); then
        echo "Notes:"
        printf '  - %s\n' "${PLAN_NOTES[@]}"
    fi
    if ((INTERACTIVE)); then
        read -t "${PVE_RANGE_IDLE:-86400}" -rp "Press Enter to return to the menu... " _ ||
            { [[ -n $PVE_RANGE_IDLE ]] && : >"$IDLE_FLAG"; }
        if ((${#FAILED[@]})); then
            ui_msg "${#FAILED[@]} command(s) failed (details in $LOG_FILE):"$'\n\n'"$(printf '%s\n' "${FAILED[@]}")" "$title"
        fi
    fi
    return 0
}

###############################################################################
# whiptail helpers
###############################################################################
term_size() {
    local s
    s=$(stty size 2>/dev/null) || s="24 80"
    ROWS=${s% *} COLS=${s#* }
    H=$((ROWS - 4)) W=$((COLS - 6))
    ((W > 150)) && W=150
    ((H < 15)) && H=15
    ((W < 60)) && W=60
    MW=$W
    ((MW > 104)) && MW=104   # menus look better a bit narrower than the screen
}
# How many lines TEXT needs in a box WIDTH wide
text_lines() {
    local line n=0
    while IFS= read -r line; do n=$((n + 1 + ${#line} / ($2 - 6))); done <<<"$1"
    echo "$n"
}
# Box height that fits TEXT plus N list rows (never taller than the screen)
fit_box() {   # text rows -> sets BOX_H BOX_LH
    local tl
    tl=$(text_lines "$1" "$MW")
    BOX_LH=$2
    ((BOX_LH > H - 7 - tl)) && BOX_LH=$((H - 7 - tl))
    ((BOX_LH < 3)) && BOX_LH=3
    BOX_H=$((BOX_LH + tl + 7))
    ((BOX_H > H)) && BOX_H=$H
}

###############################################################################
# Look & feel
###############################################################################
apply_theme() {
    case $THEME in
        midnight)
            export NEWT_COLORS='
                root=white,black          roottext=brightcyan,black   helpline=black,cyan
                border=brightblue,gray    window=white,gray           shadow=black,black
                title=brightcyan,gray     label=white,gray            textbox=white,gray
                acttextbox=white,gray     listbox=white,gray          actlistbox=black,cyan
                sellistbox=brightcyan,gray actsellistbox=black,cyan
                checkbox=white,gray       actcheckbox=black,cyan
                button=white,blue         actbutton=black,brightcyan  compactbutton=white,gray
                entry=white,black         disentry=gray,gray
                emptyscale=,black         fullscale=,cyan' ;;
        ocean)
            export NEWT_COLORS='
                root=white,blue           roottext=yellow,blue        helpline=black,cyan
                border=blue,lightgray     window=black,lightgray      shadow=black,black
                title=blue,lightgray      label=black,lightgray       textbox=black,lightgray
                acttextbox=black,lightgray listbox=black,lightgray    actlistbox=white,blue
                sellistbox=blue,lightgray actsellistbox=white,blue
                checkbox=black,lightgray  actcheckbox=white,blue
                button=white,blue         actbutton=white,cyan        compactbutton=black,lightgray
                entry=white,blue          disentry=gray,lightgray
                emptyscale=,gray          fullscale=,blue' ;;
        *) unset NEWT_COLORS ;;
    esac
}

# Icons only when the terminal speaks UTF-8 (otherwise plain text)
UI_UTF8=0
setup_ui() {
    if [[ $(locale charmap 2>/dev/null) != UTF-8 ]]; then
        export LANG=C.UTF-8 LC_ALL=C.UTF-8
    fi
    [[ $(locale charmap 2>/dev/null) == UTF-8 ]] && UI_UTF8=1
    apply_theme
}
ic() { if ((UI_UTF8)); then printf '%s  ' "$1"; fi; }

# PVE_RANGE_IDLE=<seconds>: close the menu after that long without a key press
# (set by the pve-range-web key; dialogs run in subshells, so a flag file carries it)
IDLE_FLAG="/tmp/.pve-range-idle.$$"
wt() {
    local bt="pve-range $VERSION  |  node: $LOCAL_NODE" rc
    [[ -n $WEB_USER ]] && bt+="  |  user: $WEB_USER"
    ((DRY_RUN)) && bt+="  |  DRY-RUN (nothing will be changed)"
    [[ -e $IDLE_FLAG ]] && return 1
    if [[ $PVE_RANGE_IDLE =~ ^[1-9][0-9]*$ ]]; then
        timeout --foreground "$PVE_RANGE_IDLE" whiptail --backtitle "$bt" "$@" 3>&1 1>&2 2>&3
        rc=$?
        if ((rc == 124)); then
            : >"$IDLE_FLAG"
            stty sane 2>/dev/null
            log "menu closed after ${PVE_RANGE_IDLE}s idle"
            return 1
        fi
        return $rc
    fi
    whiptail --backtitle "$bt" "$@" 3>&1 1>&2 2>&3
}

ui_msg() {
    if ((!INTERACTIVE)); then echo "$1"; return; fi
    term_size
    local h
    h=$(($(wc -l <<<"$1") + ${#1} / (W - 4) + 7))
    ((h > H)) && h=$H
    wt --title "${2:-Info}" --scrolltext --msgbox "$1" "$h" "$W"
}
msg() { ui_msg "$@"; }
ask() { term_size; wt --title "$1" --inputbox "$2" 11 "$W" "$3"; }
confirm() {
    term_size
    local h=$(($(wc -l <<<"$2") + 8))
    ((h > H)) && h=$H
    wt --title "$1" "${@:3}" --yesno "$2" "$h" "$W"
}
menu() {
    term_size
    local -a extra=()
    [[ -n $MENU_DEFAULT ]] && extra=(--default-item "$MENU_DEFAULT")
    [[ -n $NOTAGS ]] && extra+=(--notags)
    fit_box "$2" $((($# - 2) / 2))
    wt --title " $1 " "${extra[@]}" --ok-button "${OK_LABEL:-Select}" --cancel-button "${CANCEL_LABEL:-Back}" \
        --menu "$2" "$BOX_H" "$MW" "$BOX_LH" "${@:3}"
}
checklist() {
    term_size
    fit_box "$2" $((($# - 2) / 3))
    wt --title " $1 " --ok-button "OK" --cancel-button "Back" --separate-output \
        --checklist "$2" "$BOX_H" "$MW" "$BOX_LH" "${@:3}"
}
textfile()  { term_size; wt --title "$1" --scrolltext --textbox "$2" "$H" "$W"; }

choose_node() {
    local -a items=()
    local n
    for n in "${NODES[@]}"; do
        if [[ $n == "$LOCAL_NODE" ]]; then items+=("$n" "(this node)"); else items+=("$n" ""); fi
    done
    MENU_DEFAULT=$LOCAL_NODE menu "$1" "${2:-Pick a node:}" "${items[@]}"
}

# choose_snapshot ALLOW_NONE id...  -> prints the name ("" = no rollback)
choose_snapshot() {
    local allow_none=$1 id s pick
    shift
    local -A cnt=()
    for id in "$@"; do
        while read -r s; do [[ -n $s ]] && cnt[$s]=$((${cnt[$s]:-0} + 1)); done < <(snapshots_of "$id")
    done
    local -a items=()
    while read -r s; do
        [[ -n $s ]] && items+=("$s" "found on ${cnt[$s]} of $# selected guest(s)")
    done < <(printf '%s\n' "${!cnt[@]}" | sort)
    ((allow_none)) && items+=("(none)" "Don't roll back anything")
    items+=("(type)" "Type a snapshot name...")
    local def=""
    [[ -n ${cnt[$DEFAULT_SNAP]} ]] && def=$DEFAULT_SNAP
    pick=$(MENU_DEFAULT=$def menu "Snapshot" "Snapshots detected on the selected guests:" "${items[@]}") || return 1
    case $pick in
        "(none)") echo "" ;;
        "(type)") ask "Snapshot" "Snapshot name:" "$DEFAULT_SNAP" ;;
        *) echo "$pick" ;;
    esac
}

read_groups() {   # -> "name<TAB>spec"
    [[ -r $GROUPS_FILE ]] || return 0
    local k v
    while IFS='=' read -r k v; do
        k=$(trim "$k")
        [[ -z $k || $k == \#* || -z $v ]] && continue
        printf '%s\t%s\n' "$k" "$(trim "$v")"
    done <"$GROUPS_FILE"
}

# select_guests "Title" [any|qemu|lxc]  -> fills SELECTED
SELECTED=()
select_guests() {
    local title=$1 filter=${2:-any} method spec pat tag node grp out id t
    local -a cand=() items=()
    SELECTED=()
    method=$(menu "$title" "How do you want to choose the guests?" \
        list  "Tick them from a list" \
        sub   "By class & sub-group (from the VMID, e.g. 613 Enterprise Clients)" \
        range "By VMID range(s)    e.g. 510400-510430,510500-510530" \
        name  "By name pattern     e.g. ews|ows" \
        tag   "By Proxmox tag" \
        node  "Everything on one node" \
        group "Saved group  ($GROUPS_FILE)" \
        all   "Every guest in the cluster") || return 1
    case $method in
        list | all) cand=("${GUEST_IDS[@]}") ;;
        sub)
            local -A bcount=() want=()
            local key label
            local -a sitems=()
            for id in "${GUEST_IDS[@]}"; do
                if ((id < 100000)); then key=mgmt; else key=$((id / 100)); fi
                bcount[$key]=$((${bcount[$key]:-0} + 1))
            done
            for key in $(printf '%s
' "${!bcount[@]}" | sort -n); do
                if [[ $key == mgmt ]]; then
                    label="Management (VMID below 100000)"
                else
                    label=$(vmid_desc $((key * 100)))
                    label=${label% #00}
                fi
                sitems+=("$key" "$(printf '%-40s %3s guest(s)' "$label" "${bcount[$key]}")" OFF)
            done
            ((${#sitems[@]})) || { msg "No guests in this folder." "$title"; return 1; }
            out=$(checklist "$title" "Pick one or more sub-groups:" "${sitems[@]}") || return 1
            [[ -n $out ]] || return 1
            while read -r key; do want[$key]=1; done <<<"$out"
            for id in "${GUEST_IDS[@]}"; do
                if ((id < 100000)); then key=mgmt; else key=$((id / 100)); fi
                [[ -n ${want[$key]} ]] && cand+=("$id")
            done
            ;;
        range)
            spec=$(ask "$title" "VMIDs and/or ranges, separated by commas or spaces:" "") || return 1
            mapfile -t cand < <(ids_in_ranges "$spec" 2>/dev/null)
            ;;
        name)
            pat=$(ask "$title" "Regex matched against the guest name (case-insensitive):" "") || return 1
            shopt -s nocasematch
            for id in "${GUEST_IDS[@]}"; do [[ ${G_NAME[$id]} =~ $pat ]] && cand+=("$id"); done
            shopt -u nocasematch
            ;;
        tag)
            local -A seen=()
            for id in "${GUEST_IDS[@]}"; do
                for t in ${G_TAGS[$id]//[;,]/ }; do seen[$t]=1; done
            done
            ((${#seen[@]})) || { msg "None of the guests have tags." "$title"; return 1; }
            while read -r t; do items+=("$t" ""); done < <(printf '%s\n' "${!seen[@]}" | sort)
            tag=$(menu "$title" "Pick a tag:" "${items[@]}") || return 1
            for id in "${GUEST_IDS[@]}"; do
                [[ ";${G_TAGS[$id]//[, ]/;};" == *";$tag;"* ]] && cand+=("$id")
            done
            ;;
        node)
            node=$(choose_node "$title") || return 1
            for id in "${GUEST_IDS[@]}"; do [[ ${G_NODE[$id]} == "$node" ]] && cand+=("$id"); done
            ;;
        group)
            local -A gspec=()
            local k v
            while IFS=$'\t' read -r k v; do gspec[$k]=$v; items+=("$k" "$v"); done < <(read_groups)
            ((${#items[@]})) || {
                msg "No groups saved yet. Add some under Settings -> Edit saved groups." "$title"
                return 1
            }
            grp=$(menu "$title" "Pick a group:" "${items[@]}") || return 1
            mapfile -t cand < <(ids_in_ranges "${gspec[$grp]}" 2>/dev/null)
            ;;
    esac

    local -a filt=()
    for id in "${cand[@]}"; do
        [[ -n $id ]] || continue
        [[ $filter == any || ${G_TYPE[$id]} == "$filter" ]] && filt+=("$id")
    done
    ((${#filt[@]})) || { msg "No matching guests found." "$title"; return 1; }

    local state=ON
    [[ $method == list ]] && state=OFF
    items=()
    for id in "${filt[@]}"; do items+=("$id" "$(guest_label "$id")" "$state"); done
    out=$(checklist "$title" "${#filt[@]} guest(s) matched. Space toggles, Enter confirms:" "${items[@]}") || return 1
    [[ -n $out ]] || { msg "Nothing selected." "$title"; return 1; }
    mapfile -t SELECTED <<<"$out"
}

###############################################################################
# Start lab (rollback + start)
###############################################################################
RB_IDS=()
START_IDS=()
OFF_IDS=()

# Containers first, then VMs, each in VMID order (reverse it for shutdown)
sort_ct_first() {
    local i
    for i in "$@"; do printf '%d %d\n' "$([[ ${G_TYPE[$i]} == lxc ]] && echo 0 || echo 1)" "$i"; done |
        sort -k1,1n -k2,2n | awk '{print $2}'
}

plan_rollbacks() {   # $1 = snapshot; uses RB_IDS
    local id
    for id in $(sort_ct_first "${RB_IDS[@]}"); do
        plan_add "${G_NODE[$id]}" "$(guest_cmd "$id")" rollback "$id" "$1"
    done
}

# plan_shutdown shutdown|stop ids...  - VMs first (in parallel), then containers
# (file/time servers go down last), i.e. the reverse of the start order.
plan_shutdown() {
    local mode=$1 id
    shift
    local -a vms=() cts=()
    for id in "$@"; do if is_qemu "$id"; then vms+=("$id"); else cts+=("$id"); fi; done
    _sd_group() {
        local i
        (($#)) || return 0
        for i in $(printf '%s\n' "$@" | sort -rn); do
            if [[ $mode == stop ]]; then
                plan_add_bg "${G_NODE[$i]}" "$(guest_cmd "$i")" stop "$i"
            else
                plan_add_bg "${G_NODE[$i]}" "$(guest_cmd "$i")" shutdown "$i" --timeout "$SHUTDOWN_TIMEOUT" --forceStop 1
            fi
        done
        plan_wait
    }
    _sd_group "${vms[@]}"
    _sd_group "${cts[@]}"
}

choose_shutdown_mode() {
    MENU_DEFAULT=shutdown menu "${1:-Shut down}" "How should the guests be turned off?" \
        shutdown "Graceful shutdown (forced off after ${SHUTDOWN_TIMEOUT}s if the OS doesn't react)" \
        stop     "Hard power-off right away (like pulling the plug)"
}

# Which guests will still be running after the rollbacks in RB_IDS?
#   - rolled back to a RAM snapshot (the rollback resumes them)
#   - not rolled back and currently running
# A rollback to a disk-only snapshot already leaves the guest stopped.
running_after_rollback() {   # $1 = snapshot, then ids
    local snap=$1 id
    shift
    local -A rb=()
    for id in "${RB_IDS[@]}"; do rb[$id]=1; done
    for id in "$@"; do
        if [[ -n ${rb[$id]} ]]; then
            is_qemu "$id" && snap_has_vmstate "$id" "$snap" && echo "$id"
        elif [[ ${G_STATUS[$id]} == running ]]; then
            echo "$id"
        fi
    done
}

build_start_plan() {   # $1 = snapshot name; uses RB_IDS / START_IDS
    local snap=$1 id
    local -A rb=()
    plan_reset
    plan_rollbacks "$snap"
    for id in "${RB_IDS[@]}"; do rb[$id]=1; done
    for id in $(sort_ct_first "${START_IDS[@]}"); do
        if [[ -n ${rb[$id]} ]] && is_qemu "$id" && snap_has_vmstate "$id" "$snap"; then
            plan_note "$id (${G_NAME[$id]}): snapshot includes RAM, the rollback resumes it - not started again"
            continue
        fi
        if [[ -z ${rb[$id]} && ${G_STATUS[$id]} == running ]]; then
            plan_note "$id (${G_NAME[$id]}) is already running - skipped"
            continue
        fi
        plan_add "${G_NODE[$id]}" "$(guest_cmd "$id")" start "$id"
        ((START_DELAY > 0)) && plan_sleep "$START_DELAY"
    done
}

build_off_plan() {   # $1 = snapshot, $2 = shutdown|stop; uses RB_IDS / OFF_IDS
    plan_reset
    [[ -n $1 ]] && plan_rollbacks "$1"
    plan_shutdown "$2" "${OFF_IDS[@]}"
    ((${#RB_IDS[@]})) && plan_note "A rollback to a disk-only snapshot already leaves the guest powered off, so those aren't shut down again"
}

# choose_scope "Title" -> fills SCOPE_IDS
SCOPE_IDS=()
choose_scope() {
    local scope id
    SCOPE_IDS=()
    scope=$(menu "$1" "Which guests?" \
        local   "Everything on this node ($LOCAL_NODE)" \
        cluster "Everything in the cluster (all nodes)" \
        pick    "Let me choose...") || return 1
    case $scope in
        local) for id in "${GUEST_IDS[@]}"; do [[ ${G_NODE[$id]} == "$LOCAL_NODE" ]] && SCOPE_IDS+=("$id"); done ;;
        cluster) SCOPE_IDS=("${GUEST_IDS[@]}") ;;
        pick) select_guests "$1" any || return 1; SCOPE_IDS=("${SELECTED[@]}") ;;
    esac
    ((${#SCOPE_IDS[@]})) || { msg "No guests found." "$1"; return 1; }
}

offer_mirror_reapply() {
    [[ -s $MIRRORS_FILE ]] || return 0
    load_inventory || return
    local -a mnodes=()
    local n
    for n in "${NODES[@]}"; do grep -q "^$n|" "$MIRRORS_FILE" && mnodes+=("$n"); done
    if ((${#mnodes[@]})) && confirm "Port mirroring" "Saved port mirrors exist for: ${mnodes[*]}"$'\n\n'"Re-apply them now? (the sensor VMs must be running)"; then
        plan_reset
        for n in "${mnodes[@]}"; do mirror_build_saved "$n"; done
        plan_run "Re-apply port mirrors"
    fi
}

action_class() {   # start|end - restore the class snapshot, then power on / off
    load_inventory || return
    local what=$1 title snap out id mode
    local -a items=() ids=()
    if [[ $what == start ]]; then title="Start class"; else title="End class"; fi
    choose_scope "$title" || return
    ids=("${SCOPE_IDS[@]}")

    snap=$(choose_snapshot 0 "${ids[@]}") || return
    [[ -n $snap ]] || return
    RB_IDS=()
    for id in "${ids[@]}"; do
        has_snapshot "$id" "$snap" && items+=("$id" "$(guest_label "$id")" ON)
    done
    if ((${#items[@]})); then
        out=$(checklist "$title" "Restore these to '$snap'?"$'\n'"Untick guests to keep as they are (e.g. Kali, servers) - they are still powered $([[ $what == start ]] && echo on || echo off)." "${items[@]}") || return
        [[ -n $out ]] && mapfile -t RB_IDS <<<"$out"
    else
        msg "None of these guests has a snapshot called '$snap' - nothing will be restored." "$title"
    fi

    items=()
    if [[ $what == start ]]; then
        for id in "${ids[@]}"; do items+=("$id" "$(guest_label "$id")" ON); done
        out=$(checklist "$title" "Power on which guests? (containers first, then VMs in VMID order, ${START_DELAY}s apart)" "${items[@]}") || return
        START_IDS=()
        [[ -n $out ]] && mapfile -t START_IDS <<<"$out"
        build_start_plan "$snap"
        plan_run "$title" || return
        ((DRY_RUN)) || offer_mirror_reapply
        return
    fi

    OFF_IDS=()
    while read -r id; do [[ -n $id ]] && items+=("$id" "$(guest_label "$id")" ON); done < <(running_after_rollback "$snap" "${ids[@]}")
    if ((${#items[@]})); then
        out=$(checklist "$title" "These guests would still be running afterwards. Power off which?" "${items[@]}") || return
        [[ -n $out ]] && mapfile -t OFF_IDS <<<"$out"
        if ((${#OFF_IDS[@]})); then mode=$(choose_shutdown_mode "$title") || return; fi
    fi
    build_off_plan "$snap" "${mode:-shutdown}"
    plan_run "$title"
}

action_power_on() {   # start guests as they are - no restore
    load_inventory || return
    local title="Power on" out id
    local -a items=()
    choose_scope "$title" || return
    for id in "${SCOPE_IDS[@]}"; do
        [[ ${G_STATUS[$id]} == running ]] || items+=("$id" "$(guest_label "$id")" ON)
    done
    ((${#items[@]})) || { msg "All of those guests are already running." "$title"; return; }
    out=$(checklist "$title" "Power on which guests? Nothing is restored. (containers first, then VMs, ${START_DELAY}s apart)" "${items[@]}") || return
    [[ -n $out ]] || return
    RB_IDS=()
    mapfile -t START_IDS <<<"$out"
    build_start_plan ""
    plan_run "$title" || return
    ((DRY_RUN)) || offer_mirror_reapply
}

action_stop() {   # power off - no restore
    load_inventory || return
    local title="Power off" out id mode
    local -a items=()
    choose_scope "$title" || return
    for id in "${SCOPE_IDS[@]}"; do
        [[ ${G_STATUS[$id]} == running ]] && items+=("$id" "$(guest_label "$id")" ON)
    done
    ((${#items[@]})) || { msg "None of those guests are running." "$title"; return; }
    out=$(checklist "$title" "Power off which guests? Nothing is restored. (VMs first, containers last, $MAX_PARALLEL at a time)" "${items[@]}") || return
    [[ -n $out ]] || return
    mapfile -t OFF_IDS <<<"$out"
    mode=$(choose_shutdown_mode "$title") || return
    plan_reset
    plan_shutdown "$mode" "${OFF_IDS[@]}"
    plan_run "$title"
}



###############################################################################
# Port mirroring (Open vSwitch)
###############################################################################
MB_NODE="" MB_BRIDGE=""

mirror_pick() {   # sets MB_NODE / MB_BRIDGE
    local -a items=()
    local b t
    MB_NODE=$LOCAL_NODE
    if ((${#NODES[@]} > 1)); then MB_NODE=$(choose_node "Port mirroring" "Mirrors live on one host. Which node?") || return 1; fi
    while IFS=$'\t' read -r b t; do [[ -n $b ]] && items+=("$b" "$t"); done < <(node_bridges "$MB_NODE" OVSBridge)
    ((${#items[@]})) || { msg "No Open vSwitch bridges found on $MB_NODE." "Port mirroring"; return 1; }
    if ((${#items[@]} == 2)); then
        MB_BRIDGE=${items[0]}
    else
        MB_BRIDGE=$(menu "Port mirroring" "Which OVS bridge on $MB_NODE?" "${items[@]}") || return 1
    fi
}

# mirror_build NODE BRIDGE id:netN ...  (appends to the plan)
mirror_build() {
    local node=$1 br=$2 ent id nic cur k=0 changed=0
    shift 2
    local -a ovs=() mirrors=()
    for ent in "$@"; do
        id=${ent%%:*} nic=${ent#*:}
        if [[ -z ${G_TYPE[$id]} ]]; then plan_note "$id doesn't exist or is protected - skipped"; continue; fi
        if [[ ${G_NODE[$id]} != "$node" ]]; then
            plan_note "$id is on ${G_NODE[$id]}, not $node - skipped (the sensor must be on the same host as the bridge)"
            continue
        fi
        cur=$(conf_get "$id" "$nic")
        if [[ -z $cur ]]; then plan_note "$id has no $nic - skipped"; continue; fi
        [[ ${G_STATUS[$id]} == running ]] ||
            plan_note "$id (${G_NAME[$id]}) is not running, so port $(nic_dev "$id" "$nic") doesn't exist - start it first"
        # With the PVE firewall on, the NIC hangs off a fwbr bridge instead of OVS
        if [[ ,$cur, == *,firewall=1,* ]]; then
            plan_add "$node" "$(guest_cmd "$id")" set "$id" "--$nic" "$(net_set "$cur" firewall=0)"
            changed=1
        fi
        ovs+=(-- "--id=@p$k" get port "$(nic_dev "$id" "$nic")"
              -- "--id=@m$k" create mirror "name=m-$id-$nic" select-all=true "output-port=@p$k")
        mirrors+=("@m$k")
        ((k++))
    done
    ((k)) || return 0
    ((changed)) && plan_sleep 3
    plan_add "$node" ovs-vsctl "${ovs[@]}" -- set bridge "$br" "mirrors=$(IFS=,; echo "${mirrors[*]}")"
}

mirror_build_saved() {   # NODE [BRIDGE]
    local n b ents
    [[ -r $MIRRORS_FILE ]] || return 0
    while IFS='|' read -r n b ents; do
        [[ $n == "$1" ]] || continue
        [[ -n $2 && $b != "$2" ]] && continue
        # shellcheck disable=SC2086
        mirror_build "$n" "$b" $ents
    done <"$MIRRORS_FILE"
}

mirror_save() {   # NODE BRIDGE ents...
    local node=$1 br=$2
    shift 2
    mkdir -p "$CONF_DIR"
    { [[ -r $MIRRORS_FILE ]] && awk -F'|' -v n="$node" -v b="$br" '!($1 == n && $2 == b)' "$MIRRORS_FILE"
      (($#)) && echo "$node|$br|$*"; } >"$MIRRORS_FILE.tmp" && mv "$MIRRORS_FILE.tmp" "$MIRRORS_FILE"
}

mirror_status_text() {   # NODE
    run_on "$1" '
        command -v ovs-vsctl >/dev/null || { echo "Open vSwitch is not installed on this node."; exit 0; }
        for br in $(ovs-vsctl list-br); do
            echo "Bridge $br"
            ms=$(ovs-vsctl get bridge "$br" mirrors | tr -d "[],")
            [ -z "$ms" ] && { echo "  (no mirrors)"; continue; }
            for m in $ms; do
                n=$(ovs-vsctl get mirror "$m" name)
                p=$(ovs-vsctl get mirror "$m" output_port | tr -d "[]")
                pn=-; [ -n "$p" ] && pn=$(ovs-vsctl get port "$p" name)
                tx=$(ovs-vsctl get mirror "$m" statistics:tx_packets 2>/dev/null || echo 0)
                echo "  $n  ->  $pn   (packets sent: $tx)"
            done
        done' 2>&1
    if [[ -s $MIRRORS_FILE ]]; then
        echo
        echo "Saved in $MIRRORS_FILE:"
        sed 's/^/  /' "$MIRRORS_FILE"
    fi
}

action_mirror_status() {
    load_inventory || return
    local f
    MB_NODE=$LOCAL_NODE
    if ((${#NODES[@]} > 1)); then MB_NODE=$(choose_node "Mirror status" "Show the port mirrors on which node?") || return; fi
    f=$(mktemp)
    mirror_status_text "$MB_NODE" >"$f"
    textfile "Mirror status on $MB_NODE" "$f"
    rm -f "$f"
}

action_mirror_setup() {
    load_inventory || return
    local id line nic val st fw out title="Set up mirrors"
    local -a items=() sel=()
    mirror_pick || return
    for id in "${GUEST_IDS[@]}"; do
        [[ ${G_NODE[$id]} == "$MB_NODE" ]] || continue
        while IFS= read -r line; do
            nic=${line%%:*} val=${line#*: }
            [[ ,$val, == *",bridge=$MB_BRIDGE,"* ]] || continue
            st=OFF
            shopt -s nocasematch
            [[ ${G_NAME[$id]} =~ $SENSOR_PATTERN ]] && st=ON
            shopt -u nocasematch
            fw=off
            [[ ,$val, == *,firewall=1,* ]] && fw=on
            items+=("$id:$nic" "$(printf '%-26.26s %-8s firewall=%s' "${G_NAME[$id]}" "${G_STATUS[$id]}" "$fw")" "$st")
        done < <(conf_main "$id" | grep -E '^net[0-9]+: ')
    done
    ((${#items[@]})) || { msg "No guest in this folder on $MB_NODE has a NIC on $MB_BRIDGE." "$title"; return; }
    out=$(checklist "$title" "Which NICs should RECEIVE a copy of all $MB_BRIDGE traffic?"$'\n'"(likely sensors are pre-ticked; this replaces any existing mirrors on $MB_BRIDGE)" "${items[@]}") || return
    [[ -n $out ]] || return
    mapfile -t sel <<<"$out"
    plan_reset
    mirror_build "$MB_NODE" "$MB_BRIDGE" "${sel[@]}"
    if plan_run "Set up mirrors on $MB_NODE/$MB_BRIDGE" && ((!DRY_RUN)); then
        mirror_save "$MB_NODE" "$MB_BRIDGE" "${sel[@]}"
    fi
}

action_mirror_apply() {
    load_inventory || return
    local out n b e title="Re-apply mirrors"
    local -a items=()
    [[ -s $MIRRORS_FILE ]] || { msg "Nothing saved yet - use 'Set up mirrors' first." "$title"; return; }
    while IFS='|' read -r n b e; do items+=("$n|$b" "$e" ON); done <"$MIRRORS_FILE"
    out=$(checklist "$title" "Put back which saved mirrors? (the sensor VMs must be running)" "${items[@]}") || return
    plan_reset
    while IFS='|' read -r n b; do [[ -n $n ]] && mirror_build_saved "$n" "$b"; done <<<"$out"
    plan_run "$title"
}

action_mirror_remove() {
    load_inventory || return
    local title="Remove mirrors"
    mirror_pick || return
    plan_reset
    plan_add "$MB_NODE" ovs-vsctl clear bridge "$MB_BRIDGE" mirrors
    if plan_run "Remove mirrors from $MB_NODE/$MB_BRIDGE" && ((!DRY_RUN)) &&
        grep -q "^$MB_NODE|$MB_BRIDGE|" "$MIRRORS_FILE" 2>/dev/null &&
        confirm "$title" "Also forget the saved mirrors for $MB_NODE/$MB_BRIDGE (so 'Re-apply' won't put them back)?" --defaultno; then
        mirror_save "$MB_NODE" "$MB_BRIDGE"
    fi
}


###############################################################################
# Snapshots
###############################################################################
snap_create() {
    select_guests "Take snapshot" any || return
    local title="Take snapshot" name desc vmstate=0 id n_exist=0 mode=new any_running=0 power=keep sdmode=shutdown c
    local -a targets=() running=() args=()
    name=$(ask "$title" "Snapshot name (letters, digits, - and _, must start with a letter):" "$DEFAULT_SNAP") || return
    [[ $name =~ ^[A-Za-z][A-Za-z0-9_-]{1,39}$ ]] || { msg "'$name' is not a valid snapshot name." "$title"; return; }
    desc=$(ask "$title" "Description (optional):" "") || return
    for id in "${SELECTED[@]}"; do has_snapshot "$id" "$name" && ((n_exist++)); done
    if ((n_exist)); then
        mode=$(menu "$title" "$n_exist of the selected guests already have '$name'." \
            replace "Delete the old '$name' and take a new one" \
            skip    "Leave those guests alone") || return
    fi
    plan_reset
    for id in "${SELECTED[@]}"; do
        if has_snapshot "$id" "$name" && [[ $mode == skip ]]; then
            plan_note "$id (${G_NAME[$id]}) already has '$name' - skipped"
            continue
        fi
        targets+=("$id")
        if [[ ${G_STATUS[$id]} == running ]]; then
            running+=("$id")
            is_qemu "$id" && any_running=1
        fi
    done
    ((${#targets[@]})) || { msg "Nothing to snapshot." "$title"; return; }
    if ((${#running[@]})); then
        power=$(menu "$title" "${#running[@]} of these guests are running. What about their power?" \
            keep   "Leave them running" \
            after  "Take the snapshot, then shut them down" \
            before "Shut them down first, then snapshot (clean disks, no RAM)") || return
        if [[ $power != keep ]]; then sdmode=$(choose_shutdown_mode "$title") || return; fi
    fi
    if ((any_running)) && [[ $power != before ]] &&
        confirm "$title" "Include RAM for running VMs? (slower and much bigger)" --defaultno; then vmstate=1; fi

    [[ $power == before ]] && plan_shutdown "$sdmode" "${running[@]}"
    for id in "${targets[@]}"; do
        c=$(guest_cmd "$id")
        has_snapshot "$id" "$name" && plan_add "${G_NODE[$id]}" "$c" delsnapshot "$id" "$name"
        args=("$c" snapshot "$id" "$name")
        [[ -n $desc ]] && args+=(--description "$desc")
        ((vmstate)) && is_qemu "$id" && [[ ${G_STATUS[$id]} == running ]] && args+=(--vmstate 1)
        plan_add "${G_NODE[$id]}" "${args[@]}"
    done
    [[ $power == after ]] && plan_shutdown "$sdmode" "${running[@]}"
    ((vmstate)) && [[ $power == after ]] && plan_note "Rolling back to a RAM snapshot resumes the VM (it comes back running)"
    plan_run "Create snapshot '$name'"
}

snap_rollback_or_delete() {   # rollback|delete
    local what=$1 title snap id after=leave sdmode=shutdown
    title="Restore snapshot"
    [[ $what == delete ]] && title="Delete snapshot"
    select_guests "$title" any || return
    snap=$(choose_snapshot 0 "${SELECTED[@]}") || return
    [[ -n $snap ]] || return
    local -a ids=() missing=()
    for id in "${SELECTED[@]}"; do
        if has_snapshot "$id" "$snap"; then ids+=("$id"); else missing+=("$id has no '$snap' - skipped"); fi
    done
    ((${#ids[@]})) || { msg "None of the selected guests have '$snap'." "$title"; return; }
    if [[ $what == rollback ]]; then
        after=$(menu "$title" "After rolling back:" \
            leave "Leave them as restored (disk-only snapshot = off, with RAM = running)" \
            start "Power them on" \
            off   "Make sure they are all powered off") || return
        [[ $after == off ]] && { sdmode=$(choose_shutdown_mode "$title") || return; }
    fi
    RB_IDS=("${ids[@]}")
    case $what:$after in
        delete:*)
            plan_reset
            for id in "${ids[@]}"; do plan_add "${G_NODE[$id]}" "$(guest_cmd "$id")" delsnapshot "$id" "$snap"; done
            ;;
        rollback:start) START_IDS=("${ids[@]}"); build_start_plan "$snap" ;;
        rollback:off) mapfile -t OFF_IDS < <(running_after_rollback "$snap" "${ids[@]}"); build_off_plan "$snap" "$sdmode" ;;
        *) plan_reset; plan_rollbacks "$snap" ;;
    esac
    PLAN_NOTES=("${missing[@]}" "${PLAN_NOTES[@]}")
    plan_run "$title '$snap'"
}


###############################################################################
# Network
###############################################################################
action_network() {
    load_inventory || return
    select_guests "Change network" any || return
    local id nic br tag fw model cur new b t any_qemu=0
    local -A nics=()
    for id in "${SELECTED[@]}"; do
        is_qemu "$id" && any_qemu=1
        while IFS= read -r nic; do nics[$nic]=$((${nics[$nic]:-0} + 1)); done < <(conf_main "$id" | grep -oE '^net[0-9]+')
    done
    ((${#nics[@]})) || { msg "The selected guests have no network devices." "Change network"; return; }
    local -a items=()
    while read -r nic; do items+=("$nic" "present on ${nics[$nic]} of ${#SELECTED[@]} guest(s)"); done < <(printf '%s\n' "${!nics[@]}" | sort -V)
    nic=$(MENU_DEFAULT=net0 menu "Change network" "Which interface?" "${items[@]}") || return

    items=("(keep)" "Don't change the bridge")
    while IFS=$'\t' read -r b t; do [[ -n $b ]] && items+=("$b" "$t"); done < <(node_bridges "$LOCAL_NODE")
    br=$(menu "Change network" "Bridge:" "${items[@]}") || return
    tag=$(ask "Change network" "VLAN tag: a number, empty = keep current, 'none' = remove tag" "") || return
    tag=$(trim "$tag")
    [[ -z $tag || $tag == none || $tag =~ ^[0-9]+$ ]] || { msg "'$tag' is not a valid VLAN tag." "Change network"; return; }
    fw=$(menu "Change network" "Proxmox firewall on this NIC:" keep "Don't change" 1 "On  (firewall=1)" 0 "Off (firewall=0)") || return
    model="keep"
    if ((any_qemu)); then
        model=$(menu "Change network" "NIC model for VMs (the MAC address is kept):" \
            keep "Don't change" virtio "VirtIO (paravirtualized)" e1000 "Intel E1000" \
            e1000e "Intel E1000E" vmxnet3 "VMware vmxnet3" rtl8139 "Realtek RTL8139") || return
    fi
    [[ $br == "(keep)" && -z $tag && $fw == keep && $model == keep ]] && { msg "Nothing to change." "Change network"; return; }

    plan_reset
    local -a kv
    for id in "${SELECTED[@]}"; do
        cur=$(conf_get "$id" "$nic")
        [[ -n $cur ]] || { plan_note "$id (${G_NAME[$id]}) has no $nic - skipped"; continue; }
        kv=()
        [[ $br != "(keep)" ]] && kv+=("bridge=$br")
        [[ $tag == none ]] && kv+=("tag=")
        [[ $tag =~ ^[0-9]+$ ]] && kv+=("tag=$tag")
        [[ $fw != keep ]] && kv+=("firewall=$fw")
        new=$(net_set "$cur" "${kv[@]}")
        [[ $model != keep ]] && is_qemu "$id" && new=$(net_set_model "$new" "$model")
        if [[ $new == "$cur" ]]; then plan_note "$id already matches - skipped"; continue; fi
        plan_add "${G_NODE[$id]}" "$(guest_cmd "$id")" set "$id" "--$nic" "$new"
    done
    plan_run "Change $nic"
}

###############################################################################
# Disks
###############################################################################
action_disks() {
    load_inventory || return
    select_guests "Move / convert disks" qemu || return
    local -a items=()
    local s t target fmt kinds del=0 id line key val vol store cur f
    while read -r s t; do items+=("$s" "$t"); done < <(pvesm status --content images 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1, $2}')
    ((${#items[@]})) || { msg "No active storage for VM images found on $LOCAL_NODE." "Disks"; return; }
    target=$(menu "Move / convert disks" "Target storage:" "${items[@]}") || return
    load_storages
    local -a fitems=()
    for f in $(storage_formats "$target"); do
        case $f in
            qcow2) fitems+=(qcow2 "QEMU image - thin, supports snapshots") ;;
            raw) fitems+=(raw "Raw") ;;
            vmdk) fitems+=(vmdk "VMware") ;;
        esac
    done
    fitems+=(keep "Don't change the format")
    if ((${#fitems[@]} == 4)); then
        fmt=raw   # block storage (LVM, ZFS, Ceph ...) only holds raw disks
    else
        fmt=$(MENU_DEFAULT=qcow2 menu "Move / convert disks" "Target format - '$target' is ${ST_TYPE[$target]:-?} storage and can hold: $(storage_formats "$target")" "${fitems[@]}") || return
    fi
    kinds=$(checklist "Move / convert disks" "Which disks of each VM?" \
        data "System/data disks (scsiN, sataN, virtioN, ideN)" ON \
        efi  "EFI vars disk (efidisk0)" ON) || return
    [[ -n $kinds ]] || return
    confirm "Move / convert disks" "Delete the source disk after a successful move?"$'\n'"(No = keep it attached as unusedN)" && del=1

    plan_reset
    local -a args
    local before
    for id in "${SELECTED[@]}"; do
        before=${#PLAN[@]}
        while IFS= read -r line; do
            key=${line%%:*} val=${line#*: }
            case $key in
                efidisk0) [[ $kinds == *efi* ]] || continue ;;
                *) [[ $kinds == *data* ]] || continue ;;
            esac
            [[ $val == none* || ,$val, == *,media=cdrom,* ]] && continue
            vol=${val%%,*}
            [[ $vol == /* || $vol != *:* ]] && continue   # passthrough devices
            store=${vol%%:*}
            cur=$(vol_format "$vol")
            if [[ $store == "$target" && ($fmt == keep || $fmt == "$cur") ]]; then
                plan_note "$id $key is already on $target ($cur) - skipped"
                continue
            fi
            args=(qm move_disk "$id" "$key" "$target")
            [[ $fmt != keep ]] && args+=(--format "$fmt")
            ((del)) && args+=(--delete 1)
            plan_add "${G_NODE[$id]}" "${args[@]}"
        done < <(conf_main "$id" | grep -E '^((scsi|sata|virtio|ide)[0-9]+|efidisk0): ')
        if ((del && ${#PLAN[@]} > before)) && [[ -n $(snapshots_of "$id") ]]; then
            plan_note "$id (${G_NAME[$id]}) has snapshots - Proxmox refuses 'move + delete source' for disks used by a snapshot; delete the snapshots first or don't delete the source"
        fi
    done
    plan_run "Move disks to $target"
}

###############################################################################
# EFI keys
###############################################################################
action_efi() {
    load_inventory || return
    local id val st out
    local -a items=() sel=()
    for id in "${GUEST_IDS[@]}"; do
        is_qemu "$id" || continue
        val=$(conf_get "$id" efidisk0)
        [[ -n $val ]] || continue
        st=ON
        [[ ,$val, == *,pre-enrolled-keys=1,* ]] && st=OFF
        items+=("$id" "$(guest_label "$id")$([[ $st == OFF ]] && echo '  (keys already enrolled)')" "$st")
    done
    ((${#items[@]})) || { msg "No VMs with an EFI disk were found." "EFI keys"; return; }
    out=$(checklist "Enroll EFI keys" "VMs with an EFI disk. Those WITHOUT pre-enrolled keys are ticked:" "${items[@]}") || return
    [[ -n $out ]] || return
    mapfile -t sel <<<"$out"
    plan_reset
    for id in "${sel[@]}"; do
        [[ ${G_STATUS[$id]} == running ]] && plan_note "$id (${G_NAME[$id]}) is running - if enrolling fails, stop it and retry"
        plan_add "${G_NODE[$id]}" qm enroll-efi-keys "$id"
    done
    plan_run "Enroll EFI keys"
}

###############################################################################
# Migration
###############################################################################
# Storages holding any volume of the guest, current config AND snapshots (no CD-ROMs)

action_migrate() {
    load_inventory || return
    ((${#NODES[@]} > 1)) || { msg "Only one online node detected - nothing to migrate to." "Migrate"; return; }
    select_guests "Migrate guests" any || return
    load_storages
    local n out mode=block opts id t src i k chunk st nblocked=0
    local -a items=() targets=() ids=() args=() locals=() snaps=()
    local -A blocked=() haslocal=()
    local -a cdnotes=()

    # Proxmox can't move snapshots on local non-ZFS storage (lvm-thin, dir...)
    for id in "${SELECTED[@]}"; do
        locals=()
        while read -r st; do
            [[ -n $st ]] && ! storage_is_shared "$st" && locals+=("$st")
        done < <(guest_storages "$id")
        ((${#locals[@]})) && haslocal[$id]=1
        # A mounted ISO on local storage also blocks migration
        st=$(conf_main "$id" | grep 'media=cdrom' | sed -E 's/^[^:]+: //; s/,.*//' | grep -E '^[A-Za-z0-9_.-]+:' | cut -d: -f1 | head -1)
        [[ -n $st ]] && ! storage_is_shared "$st" &&
            cdnotes+=("$id (${G_NAME[$id]}) has an ISO from local storage '$st' mounted - eject it if the migration fails")
        [[ -n $(snapshots_of "$id") ]] || continue
        for st in "${locals[@]}"; do
            if [[ ${ST_TYPE[$st]} != zfspool ]]; then blocked[$id]=$st; ((nblocked++)); break; fi
        done
    done

    for n in "${NODES[@]}"; do items+=("$n" "$([[ $n == "$LOCAL_NODE" ]] && echo '(this node)')" OFF); done
    out=$(checklist "Migrate guests" "Target node(s). Tick several to spread the guests across them:" "${items[@]}") || return
    [[ -n $out ]] || return
    mapfile -t targets <<<"$out"
    if ((${#targets[@]} > 1)); then
        mode=$(menu "Migrate guests" "How should the guests be spread over ${targets[*]}?" \
            block "Equal blocks in VMID order (first third -> node A, next -> B ...)" \
            rr    "Round-robin (1st -> A, 2nd -> B, 3rd -> C, 4th -> A ...)") || return
    fi
    items=(online  "Live-migrate running VMs (--online)" ON
           restart "Restart-migrate running containers (--restart)" ON)
    ((nblocked)) && items+=(delsnap "DELETE the snapshots of the $nblocked guest(s) that can't move with them" OFF)
    local warn=""
    ((nblocked)) && warn=$'\n\n'"$nblocked guest(s) have snapshots on local storage (e.g. lvm-thin). Proxmox can only migrate those with shared or ZFS storage - either delete their snapshots or they will be skipped."
    opts=$(checklist "Migrate guests" "Options:$warn" "${items[@]}") || return

    mapfile -t ids < <(printf '%s\n' "${SELECTED[@]}" | sort -n)
    k=${#targets[@]}
    chunk=$(((${#ids[@]} + k - 1) / k))
    plan_reset
    PLAN_NOTES=("${cdnotes[@]}")
    for i in "${!ids[@]}"; do
        id=${ids[i]} src=${G_NODE[${ids[i]}]}
        if [[ $mode == rr ]]; then t=${targets[i % k]}; else t=${targets[i / chunk]}; fi
        [[ $src == "$t" ]] && { plan_note "$id is already on $t"; continue; }
        if [[ -n ${blocked[$id]} ]]; then
            if [[ $opts != *delsnap* ]]; then
                plan_note "$id (${G_NAME[$id]}) skipped - it has snapshots on local storage '${blocked[$id]}'"
                continue
            fi
            mapfile -t snaps < <(snapshots_of "$id")
            for ((n = ${#snaps[@]} - 1; n >= 0; n--)); do
                plan_add "$src" "$(guest_cmd "$id")" delsnapshot "$id" "${snaps[n]}"
            done
        fi
        if is_qemu "$id"; then
            args=(qm migrate "$id" "$t")
            if [[ ${G_STATUS[$id]} == running ]]; then
                [[ $opts == *online* ]] || { plan_note "$id is running - skipped (enable --online)"; continue; }
                args+=(--online 1)
            fi
            [[ -n ${haslocal[$id]} ]] && args+=(--with-local-disks 1)
        else
            args=(pct migrate "$id" "$t")
            if [[ ${G_STATUS[$id]} == running ]]; then
                [[ $opts == *restart* ]] || { plan_note "CT $id is running - skipped (enable --restart)"; continue; }
                args+=(--restart 1)
            fi
        fi
        plan_add "$src" "${args[@]}"
    done
    [[ $opts == *delsnap* ]] && plan_note "Snapshots were deleted so the guests could move - take them again on the new node (Snapshots -> Create)"
    plan_run "Migrate guests"
}

###############################################################################
# VMID map and folders
#   VMIDs are AABCDD: AA = group/class, B = version (or module), C = sub-group,
#   DD = number. VMIDs below 100000 are the "Management" folder.
###############################################################################
VMID_MAP="$CONF_DIR/vmid-map.conf"
declare -A FOLDER_NAME=() FOLDER_DESC=() SUB_NAME=() MOD_NAME=()
ALL_GUEST_IDS=()

write_default_vmid_map() {
    mkdir -p "$CONF_DIR"
    cat >"$VMID_MAP" <<'EOF'
# pve-range VMID map - edit in the menu: Settings -> Edit VMID map
#
# VMIDs are AABCDD:  AA = group / class   B = version (or module)
#                    C  = sub-group       DD = number (00-99)
# VMIDs below 100000 are shown in the "Management" folder.
#
#   folder <AA> <folder name> <description>   one folder per class / group
#   module <AA> <B> <name>                    B is a module (not a version) in that class
#   sub    <AA> <C> <name>                    name of sub-group C in that class

folder 10 Mgmt      Management
folder 11 Office    Office
folder 12 Security  Security
folder 20 Lab       Lab
folder 40 SANS      SANS
folder 50 612       ICS612
folder 51 613       ICS613
folder 52 NetWars   NetWars v5
folder 53 727       ICS727 (draft)
folder 99 Templates Templates

sub 50 0 Mgmt
sub 50 1 Lvl 3 Servers
sub 50 2 Lvl 3 EWS
sub 50 3 Lvl 3 OWS
sub 50 4 iDMZ File Servers
sub 50 5 iDMZ Jump Hosts
sub 50 6 NSM

sub 51 0 Mgmt
sub 51 1 Enterprise Servers
sub 51 2 ICS Servers
sub 51 3 ABB Servers
sub 51 4 Enterprise Clients
sub 51 5 JumpHost Clients
sub 51 6 ICS EWS
sub 51 7 ABB OWS

module 52 0 Mgmt
module 52 1 Grid
module 52 2 Cookie
module 52 3 Injection
sub 52 0 Servers
sub 52 1 Clients L3
sub 52 2 Clients L4

sub 53 0 Mgmt
sub 53 1 Enterprise
sub 53 2 DMZ
sub 53 3 ICS
EOF
}

load_vmid_map() {
    [[ -r $VMID_MAP ]] || write_default_vmid_map 2>/dev/null
    FOLDER_NAME=() FOLDER_DESC=() SUB_NAME=() MOD_NAME=()
    local kind a b rest
    while read -r kind a b rest; do
        case $kind in
            folder) [[ $a =~ ^[0-9]{2}$ ]] && FOLDER_NAME[$a]=$b FOLDER_DESC[$a]=${rest:-$b} ;;
            sub) [[ $a =~ ^[0-9]{2}$ && $b =~ ^[0-9]$ ]] && SUB_NAME[$a.$b]=$rest ;;
            module) [[ $a =~ ^[0-9]{2}$ && $b =~ ^[0-9]$ ]] && MOD_NAME[$a.$b]=$rest ;;
        esac
    done < <(grep -vE '^\s*(#|$)' "$VMID_MAP" 2>/dev/null)
}

folder_of() {   # VMID -> folder name
    local id=$1 aa
    if ((id < 100000)); then echo Management; return; fi
    printf -v aa '%02d' $((id / 10000 % 100))
    echo "${FOLDER_NAME[$aa]:-Group-$aa}"
}

vmid_desc() {   # VMID -> e.g. "613 v0 Enterprise Clients #04"
    local id=$1 aa b c dd part
    ((id >= 100000)) || { echo "Management"; return; }
    printf -v aa '%02d' $((id / 10000 % 100))
    b=$((id / 1000 % 10)) c=$((id / 100 % 10))
    printf -v dd '%02d' $((id % 100))
    if [[ -n ${MOD_NAME[$aa.$b]} ]]; then part=${MOD_NAME[$aa.$b]}; else part="v$b"; fi
    echo "${FOLDER_NAME[$aa]:-$aa} $part ${SUB_NAME[$aa.$c]:-sub $c} #$dd"
}

# Keep only the guests of the current folder in GUEST_IDS (ALL_GUEST_IDS keeps all)
apply_folder() {
    ALL_GUEST_IDS=("${GUEST_IDS[@]}")
    [[ -n $FOLDER && $FOLDER != all ]] || return 0
    local id
    local -a keep=()
    for id in "${ALL_GUEST_IDS[@]}"; do [[ $(folder_of "$id") == "$FOLDER" ]] && keep+=("$id"); done
    GUEST_IDS=("${keep[@]}")
}

choose_folder() {   # sets FOLDER
    local id f pick
    local -A cnt=()
    local -a items=() order=()
    FOLDER=all
    inventory_dirty
    load_inventory || return 1
    for id in "${ALL_GUEST_IDS[@]}"; do
        f=$(folder_of "$id")
        [[ -z ${cnt[$f]} ]] && order+=("$f")
        cnt[$f]=$((${cnt[$f]:-0} + 1))
    done
    items=(all "$(ic "◎")$(printf '%-10s %-22s (%s)' All "every guest" "${#ALL_GUEST_IDS[@]}")")
    [[ -n ${cnt[Management]} ]] && items+=(Management "$(ic "⚑")$(printf '%-10s %-22s (%s)' Management "VMID below 100000" "${cnt[Management]}")")
    local aa
    for aa in $(printf '%s\n' "${!FOLDER_NAME[@]}" | sort -n); do
        f=${FOLDER_NAME[$aa]}
        [[ -n ${cnt[$f]} ]] && items+=("$f" "$(ic "▣")$(printf '%-10s %-22s (%s)' "$f" "${FOLDER_DESC[$aa]}" "${cnt[$f]}")")
    done
    for f in "${order[@]}"; do   # VMIDs in groups that aren't in the map yet
        [[ $f == Group-* ]] && items+=("$f" "$(ic "▢")$(printf '%-10s %-22s (%s)' "$f" "not in the VMID map" "${cnt[$f]}")")
    done
    pick=$(MENU_DEFAULT=${LAST_FOLDER:-all} NOTAGS=1 menu "Choose a folder" \
        "What do you want to manage? Everything you do is limited to this folder."$'\n'"(Folders come from the VMID numbers - see Settings -> Edit VMID map.)" \
        "${items[@]}") || return 1
    FOLDER=$pick LAST_FOLDER=$pick
    save_settings
    inventory_dirty
    load_inventory
}

###############################################################################
# Storage: types, formats, overview
###############################################################################
declare -A ST_TYPE=() ST_SHARED=() ST_CONTENT=()
load_storages() {
    local id type shared content
    ST_TYPE=() ST_SHARED=() ST_CONTENT=()
    if [[ -r $PVE_ROOT/storage.cfg ]]; then
        while IFS=$'\t' read -r id type shared content; do
            [[ -n $id ]] && ST_TYPE[$id]=$type ST_SHARED[$id]=$shared ST_CONTENT[$id]=$content
        done < <(awk '
            /^[a-z0-9]+: / { if (id != "") print id "\t" t "\t" sh "\t" ct
                             t = $1; sub(":", "", t); id = $2; sh = 0; ct = ""; next }
            $1 == "shared"  { sh = $2 }
            $1 == "content" { ct = $2 }
            END { if (id != "") print id "\t" t "\t" sh "\t" ct }' "$PVE_ROOT/storage.cfg")
        return
    fi
    while IFS=$'\t' read -r id type shared content; do
        [[ -n $id ]] && ST_TYPE[$id]=$type ST_SHARED[$id]=$shared ST_CONTENT[$id]=$content
    done < <(pvesh get /storage --output-format json 2>/dev/null | perl -MJSON::PP -e '
        local $/; my $d = decode_json(<STDIN>);
        print join("\t", $_->{storage}, $_->{type} // "?", $_->{shared} // 0, $_->{content} // ""), "\n" for @$d' 2>/dev/null)
}
storage_is_shared() {
    [[ ${ST_SHARED[$1]} == 1 || ${ST_TYPE[$1]} =~ ^(nfs|cifs|rbd|cephfs|glusterfs|iscsi|iscsidirect|pbs)$ ]]
}
# Disk formats a storage type can hold
storage_formats() {
    case ${ST_TYPE[$1]} in
        dir | nfs | cifs | glusterfs | cephfs) echo "qcow2 raw vmdk" ;;
        "") echo "?" ;;
        *) echo "raw" ;;
    esac
}
vol_format() {
    case $1 in
        *.qcow2*) echo qcow2 ;;
        *.vmdk*) echo vmdk ;;
        *subvol-*) echo subvol ;;
        *) echo raw ;;
    esac
}
# Storages holding any volume of the guest, current config AND snapshots (no CD-ROMs)
guest_storages() {
    grep -E '^((scsi|sata|virtio|ide|efidisk|tpmstate|unused|mp)[0-9]+|rootfs|vmstate): ' "$(conf_file "$1")" 2>/dev/null |
        grep -v 'media=cdrom' | sed -E 's/^[^:]+: //; s/,.*//' | grep -E '^[A-Za-z0-9_.-]+:' | cut -d: -f1 | sort -u
}
# "disk<TAB>volume<TAB>size" for every disk in the guest's current config
guest_disks() {
    conf_main "$1" | grep -E '^((scsi|sata|virtio|ide|efidisk|tpmstate|mp)[0-9]+|rootfs): ' | grep -v 'media=cdrom' |
        while IFS= read -r line; do
            local key=${line%%:*} val=${line#*: } vol size
            vol=${val%%,*}
            [[ $vol == none || $vol != *:* ]] && continue
            size=$(grep -oE '(^|,)size=[^,]+' <<<"$val" | head -1 | cut -d= -f2)
            printf '%s\t%s\t%s\n' "$key" "$vol" "${size:--}"
        done
}

storage_text() {
    local s id key vol size st fmt n
    local -A per=()
    echo "STORAGES"
    printf '  %-16s %-10s %-7s %-16s %s\n' NAME TYPE SHARED "DISK FORMATS" CONTENT
    for s in $(printf '%s\n' "${!ST_TYPE[@]}" | sort); do
        printf '  %-16s %-10s %-7s %-16s %s\n' "$s" "${ST_TYPE[$s]}" \
            "$(storage_is_shared "$s" && echo yes || echo no)" "$(storage_formats "$s")" "${ST_CONTENT[$s]}"
    done
    echo
    echo "DISKS IN FOLDER: ${FOLDER:-all}"
    printf '  %-8s %-22s %-10s %-14s %-7s %s\n' VMID NAME DISK STORAGE FORMAT SIZE
    for id in "${GUEST_IDS[@]}"; do
        while IFS=$'\t' read -r key vol size; do
            st=${vol%%:*} fmt=$(vol_format "$vol")
            per["$st $fmt"]=$((${per["$st $fmt"]:-0} + 1))
            printf '  %-8s %-22.22s %-10s %-14s %-7s %s\n' "$id" "${G_NAME[$id]}" "$key" "$st" "$fmt" "$size"
        done < <(guest_disks "$id")
    done
    echo
    echo "SUMMARY (disks per storage and format)"
    for n in $(printf '%s\n' "${!per[@]}" | tr ' ' '|' | sort); do
        printf '  %-16s %-7s %s disk(s)\n' "${n%|*}" "${n#*|}" "${per[${n/|/ }]}"
    done
}

action_storage() {
    load_inventory || return
    load_storages
    local f
    f=$(mktemp)
    storage_text >"$f"
    textfile "Storage overview" "$f"
    rm -f "$f"
}

###############################################################################
# Add-ons: your own scripts, listed in the menu and editable from it
#   Files: /etc/pve-range/addons/*.sh  with a header like
#     # NAME:   Unlock guests
#     # DESC:   Clear a stuck lock
#     # GUESTS: yes        (ask which guests first; they're passed as arguments)
###############################################################################
ADDON_DIR="$CONF_DIR/addons"

addon_meta() { awk -v k="$2" 'NR <= 25 && index($0, "# " k ":") == 1 {sub("^# " k ":[ \t]*", ""); print; exit}' "$1"; }
can_edit_addons() { [[ -z $WEB_USER ]] || ((ADDON_EDIT_WEB)); }
addon_editor() {
    if [[ -n $WEB_USER ]]; then rnano "$1"; else "${EDITOR:-nano}" "$1"; fi
    if ! bash -n "$1" 2>/tmp/.pve-range-addon-err; then
        ui_msg "The add-on has a syntax error - fix it before running it:"$'\n\n'"$(cat /tmp/.pve-range-addon-err)" "Add-ons"
    fi
    rm -f /tmp/.pve-range-addon-err
}

addons_init() {
    [[ -d $ADDON_DIR ]] && return
    mkdir -p "$ADDON_DIR"
    cat >"$ADDON_DIR/unlock-guests.sh" <<'EOF'
#!/usr/bin/env bash
# NAME:   Unlock guests
# DESC:   Clear a stuck lock (after a failed backup, snapshot or migration)
# GUESTS: yes
#
# How add-ons work: pve-range runs this file as root on the node you're on.
#   $@                 the VMIDs that were picked
#   PVE_RANGE_GUESTS   one line per guest: "vmid node type name"  (type = qemu|lxc)
#   PVE_RANGE_DRY_RUN  1 = dry-run is on: only show what you would do
#   PVE_RANGE_USER     who is signed in (web) - empty on the console
while read -r id node type name; do
    [[ -n $id ]] || continue
    if [[ $type == lxc ]]; then cmd="pct unlock $id"; else cmd="qm unlock $id"; fi
    echo "[$node] $cmd   ($name)"
    ((PVE_RANGE_DRY_RUN)) && continue
    if [[ $node == "$(hostname -s)" ]]; then $cmd; else ssh -n "root@$node" "$cmd"; fi
done <<<"$PVE_RANGE_GUESTS"
EOF
    cat >"$ADDON_DIR/guest-ips.sh" <<'EOF'
#!/usr/bin/env bash
# NAME:   Show IP addresses
# DESC:   IPv4 addresses of running guests (VMs need the QEMU guest agent)
# GUESTS: yes
while read -r id node type name; do
    [[ -n $id ]] || continue
    if [[ $type == lxc ]]; then
        cmd="pct exec $id -- sh -c 'ip -4 -o addr show scope global 2>/dev/null | awk \"{print \\\$4}\"'"
    else
        cmd="qm guest cmd $id network-get-interfaces 2>/dev/null | grep -o '\"ip-address\" *: *\"[0-9.]*\"' | grep -o '[0-9.]*\"\$' | tr -d '\"' | grep -v '^127\\.'"
    fi
    if [[ $node == "$(hostname -s)" ]]; then ips=$(bash -c "$cmd"); else ips=$(ssh -n "root@$node" "$cmd"); fi
    printf '%-8s %-26s %s\n' "$id" "$name" "${ips//$'\n'/, }"
done <<<"$PVE_RANGE_GUESTS"
EOF
    chmod 700 "$ADDON_DIR"/*.sh
}

run_addon() {
    local file=$1 name guests id
    local -a ids=()
    name=$(addon_meta "$file" NAME)
    name=${name:-$(basename "$file" .sh)}
    if [[ $(addon_meta "$file" GUESTS) == yes ]]; then
        select_guests "Add-on: $name" any || return
        ids=("${SELECTED[@]}")
    fi
    confirm "Add-on: $name" "Run '$name'$( ((${#ids[@]})) && echo " on ${#ids[@]} guest(s)")?$( ((DRY_RUN)) && printf '\n\nDRY-RUN is on - the add-on is told to only show what it would do.')" || return
    guests=""
    for id in "${ids[@]}"; do guests+="$id ${G_NODE[$id]} ${G_TYPE[$id]} ${G_NAME[$id]}"$'\n'; done
    clear
    echo "${C_B}Add-on: $name${C_0}"
    log "add-on '$name' started (${#ids[@]} guests)"
    PVE_RANGE_GUESTS=$guests PVE_RANGE_DRY_RUN=$DRY_RUN PVE_RANGE_USER=$WEB_USER PVE_RANGE_NODE=$LOCAL_NODE \
        bash "$file" "${ids[@]}" 2>&1 | tee -a "$LOG_FILE"
    log "add-on '$name' finished (exit ${PIPESTATUS[0]})"
    inventory_dirty
    read -t "${PVE_RANGE_IDLE:-86400}" -rp "Press Enter to return to the menu... " _ ||
        { [[ -n $PVE_RANGE_IDLE ]] && : >"$IDLE_FLAG"; }
}

pick_addon() {   # title -> prints file
    local f
    local -a items=()
    for f in "$ADDON_DIR"/*.sh; do
        [[ -e $f ]] && items+=("$(basename "$f")" "$(addon_meta "$f" NAME)")
    done
    ((${#items[@]})) || { ui_msg "There are no add-ons yet." "$1"; return 1; }
    f=$(menu "$1" "Which add-on?" "${items[@]}") || return 1
    echo "$ADDON_DIR/$f"
}

action_addons() {
    local c f slug title desc
    addons_init
    while true; do
        local -a items=()
        for f in "$ADDON_DIR"/*.sh; do
            [[ -e $f ]] || continue
            items+=("run:$(basename "$f")" "$(ic "▸")$(printf '%-24.24s %s' "$(addon_meta "$f" NAME)" "$(addon_meta "$f" DESC)")")
        done
        if can_edit_addons; then
            items+=(new "$(ic "+")New add-on" edit "$(ic "✎")Edit an add-on" delete "$(ic "−")Delete an add-on")
        fi
        c=$(NOTAGS=1 menu "Add-ons" "Your own scripts. Pick one to run it.$(can_edit_addons || printf '\n(Editing is only allowed on the node console.)')" "${items[@]}") || return
        case $c in
            run:*) run_addon "$ADDON_DIR/${c#run:}" ;;
            new)
                slug=$(ask "New add-on" "File name (letters, digits and -):" "my-addon") || continue
                [[ $slug =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || { ui_msg "'$slug' isn't a valid file name." "New add-on"; continue; }
                f="$ADDON_DIR/$slug.sh"
                [[ -e $f ]] && { ui_msg "$slug.sh already exists." "New add-on"; continue; }
                title=$(ask "New add-on" "Name shown in the menu:" "My add-on") || continue
                desc=$(ask "New add-on" "One-line description:" "") || continue
                cat >"$f" <<EOF
#!/usr/bin/env bash
# NAME:   $title
# DESC:   $desc
# GUESTS: yes
#
# Runs as root on this node.  \$@ = picked VMIDs.
# PVE_RANGE_GUESTS: one "vmid node type name" line per guest.  PVE_RANGE_DRY_RUN=1: only show.
while read -r id node type name; do
    [[ -n \$id ]] || continue
    echo "\$id  \$name  (\$type on \$node)"
done <<<"\$PVE_RANGE_GUESTS"
EOF
                chmod 700 "$f"
                log "add-on $slug.sh created"
                addon_editor "$f"
                ;;
            edit) f=$(pick_addon "Edit an add-on") && { addon_editor "$f"; log "add-on $(basename "$f") edited"; } ;;
            delete)
                f=$(pick_addon "Delete an add-on") || continue
                confirm "Delete an add-on" "Delete $(basename "$f")?" --defaultno && rm -f "$f" && log "add-on $(basename "$f") deleted"
                ;;
        esac
        [[ -e $IDLE_FLAG ]] && return
    done
}

###############################################################################
# Inventory / settings
###############################################################################
inventory_text() {
    local id n b t
    echo "Node you are on: $LOCAL_NODE      Online nodes: ${NODES[*]}"
    for n in "${NODES[@]}"; do
        b=""
        while IFS=$'\t' read -r t _; do [[ -n $t ]] && b+="$t "; done < <(node_bridges "$n" OVSBridge)
        [[ -n $b ]] && echo "  OVS bridges on $n: $b"
    done
    echo
    echo "Folder: ${FOLDER:-all}"
    echo
    printf '%-8s %-4s %-12s %-8s %-26s %-30s %s\n' VMID TYPE NODE STATUS NAME "CLASS / GROUP" SNAPSHOTS
    printf '%s\n' "------------------------------------------------------------------------------------------"
    for id in "${GUEST_IDS[@]}"; do
        t=CT
        is_qemu "$id" && t=VM
        printf '%-8s %-4s %-12.12s %-8s %-26.26s %-30.30s %s\n' "$id" "$t" "${G_NODE[$id]}" "${G_STATUS[$id]}" \
            "${G_NAME[$id]}" "$(vmid_desc "$id")" "$(snapshots_of "$id" | paste -sd, -)"
    done
    echo
    echo "${#GUEST_IDS[@]} guest(s)"
    if ((${#PROTECTED_IDS[@]})); then
        echo
        echo "Protected - hidden from every action (Settings -> Protected guests: $PROTECTED):"
        local p pid ptype pnode pst pname
        for p in "${PROTECTED_IDS[@]}"; do
            IFS=$'\t' read -r pid ptype pnode pst pname <<<"$p"
            t=CT; [[ $ptype == qemu ]] && t=VM
            printf '%-8s %-4s %-12.12s %-8s %s\n' "$pid" "$t" "$pnode" "$pst" "$pname"
        done
    fi
}

save_settings() {
    mkdir -p "$CONF_DIR"
    printf 'START_DELAY=%q\nSHUTDOWN_TIMEOUT=%q\nMAX_PARALLEL=%q\nDEFAULT_SNAP=%q\nSENSOR_PATTERN=%q\nPROTECTED=%q\nTHEME=%q\nASK_FOLDER=%q\nLAST_FOLDER=%q\nADDON_EDIT_WEB=%q\n' \
        "$START_DELAY" "$SHUTDOWN_TIMEOUT" "$MAX_PARALLEL" "$DEFAULT_SNAP" "$SENSOR_PATTERN" "$PROTECTED" "$THEME" \
        "$ASK_FOLDER" "$LAST_FOLDER" "$ADDON_EDIT_WEB" >"$SETTINGS_FILE"
}

edit_groups() {
    mkdir -p "$CONF_DIR"
    if [[ ! -e $GROUPS_FILE ]]; then
        cat >"$GROUPS_FILE" <<'EOF'
# Saved guest groups for pve-range.sh
# name = VMIDs and/or ranges (commas or spaces)
#
# Backend      = 510001-510002
# Ent Servers  = 510101-510102
# Prod Servers = 510200
# ABB Servers  = 510300-510302
# Ent Clients  = 510400-510430
# JumpHosts    = 510500-510530
# EWS          = 510600-510630
# ABB OWS      = 510700-510730
EOF
    fi
    "${EDITOR:-nano}" "$GROUPS_FILE"
}

action_settings() {
    local c v f
    while true; do
        local -a extra_items=()
        [[ -z $WEB_USER ]] && extra_items=(addweb "Web users may edit add-ons: $( ((ADDON_EDIT_WEB)) && echo yes || echo no) (console only)")
        c=$(menu "Settings" "" \
            theme  "Colour theme: $THEME" \
            dry    "Dry-run mode: $( ((DRY_RUN)) && echo ON || echo OFF)  (show commands, change nothing)" \
            snap   "Default snapshot name: $DEFAULT_SNAP" \
            delay  "Delay between starts: ${START_DELAY}s" \
            sdtime "Shutdown timeout before forcing off: ${SHUTDOWN_TIMEOUT}s" \
            par    "Shutdowns at the same time: $MAX_PARALLEL" \
            sensor "Sensor name pattern: $SENSOR_PATTERN" \
            protect "Protected guests (never touched): ${PROTECTED:-none}" \
            askf   "Ask for the folder when the menu opens: $( ((ASK_FOLDER)) && echo yes || echo no)" \
            vmap   "Edit VMID map - folders, classes, sub-groups ($VMID_MAP)" \
            groups "Edit saved groups ($GROUPS_FILE)" \
            "${extra_items[@]}" \
            log    "View log ($LOG_FILE)" \
            back   "Back") || return
        case $c in
            theme)
                v=$(MENU_DEFAULT=$THEME menu "Settings" "Colour theme:" \
                    midnight "Dark, cyan highlights (default)" \
                    ocean    "Blue background, light windows" \
                    classic  "Plain whiptail colours") || continue
                THEME=$v
                apply_theme
                save_settings
                ;;
            dry) DRY_RUN=$((1 - DRY_RUN)) ;;
            snap) v=$(ask "Settings" "Default snapshot name:" "$DEFAULT_SNAP") && [[ -n $v ]] && DEFAULT_SNAP=$v && save_settings ;;
            delay)
                v=$(ask "Settings" "Seconds to wait between starting guests:" "$START_DELAY") || continue
                [[ $v =~ ^[0-9]+$ ]] && START_DELAY=$v && save_settings
                ;;
            sdtime)
                v=$(ask "Settings" "Seconds to wait for a graceful shutdown before forcing the guest off:" "$SHUTDOWN_TIMEOUT") || continue
                [[ $v =~ ^[0-9]+$ ]] && SHUTDOWN_TIMEOUT=$v && save_settings
                ;;
            par)
                v=$(ask "Settings" "How many guests to shut down at the same time (1 = one by one):" "$MAX_PARALLEL") || continue
                [[ $v =~ ^[1-9][0-9]*$ ]] && MAX_PARALLEL=$v && save_settings
                ;;
            sensor)
                v=$(ask "Settings" "Regex (case-insensitive) used to pre-tick sensor NICs for port mirroring:" "$SENSOR_PATTERN") &&
                    [[ -n $v ]] && SENSOR_PATTERN=$v && save_settings
                ;;
            protect)
                v=$(ask "Settings" "VMIDs/ranges pve-range must never touch (hidden from every list), e.g. 100-103. Empty = none:" "$PROTECTED") || continue
                PROTECTED=$(trim "$v")
                save_settings
                inventory_dirty
                load_inventory
                ;;
            groups) edit_groups ;;
            askf) ASK_FOLDER=$((1 - ASK_FOLDER)); save_settings ;;
            vmap)
                if [[ -n $WEB_USER ]]; then rnano "$VMID_MAP"; else "${EDITOR:-nano}" "$VMID_MAP"; fi
                load_vmid_map
                inventory_dirty
                ;;
            addweb)
                if [[ -z $WEB_USER ]]; then
                    if ((ADDON_EDIT_WEB)) || confirm "Settings" "Allow signed-in web users to create and edit add-ons?"$'\n\n'"Add-ons run as root on the node, so this gives every web user full control of the cluster." --defaultno; then
                        ADDON_EDIT_WEB=$((1 - ADDON_EDIT_WEB))
                        save_settings
                    fi
                fi
                ;;
            log)
                f=$(mktemp)
                tail -n 1000 "$LOG_FILE" >"$f" 2>/dev/null
                [[ -s $f ]] || echo "(log is empty)" >"$f"
                textfile "Log" "$f"
                rm -f "$f"
                ;;
            back) return ;;
        esac
    done
}

action_inventory() {
    inventory_dirty
    load_inventory || return
    local f
    f=$(mktemp)
    inventory_text >"$f"
    textfile "Detected guests" "$f"
    rm -f "$f"
}

help_text() {
    cat <<'EOF'
pve-range - quick guide
=======================

FOLDERS
  At the start you pick a folder: Management (VMID below 100000), a class
  (612, 613, NetWars, 727 ...) or All guests. Every list and every action only
  shows guests from that folder. Change it with "Switch folder".
  Folders come from the VMID number (AABCDD) - see Settings -> Edit VMID map.

CLASS
  Start class       Restore the class snapshot (e.g. ClassStart), then power on.
                    Containers start first, then VMs in VMID order.
  End class         Restore the class snapshot, then power everything off.
  Power on          Start guests as they are - nothing is restored.
  Power off         Shut guests down as they are - nothing is restored.
                    Graceful (forced off after the timeout) or hard power-off.

SNAPSHOTS
  Take snapshot     Snapshot many guests at once. Optionally shut them down
                    before (cleanest) or after.
  Restore snapshot  Roll guests back; afterwards leave them, power on, or off.
  Delete snapshot   Remove a snapshot from many guests.

SENSORS (PORT MIRRORING)
  Mirror status     Which sensor NICs receive copied traffic, packets sent.
  Set up mirrors    Pick an Open vSwitch bridge and the sensor NICs (names like
                    Dragos/Tenable are pre-ticked). The setup is saved.
  Re-apply mirrors  Mirrors vanish when a sensor restarts or a host reboots -
                    this puts the saved ones back.
  Remove mirrors    Stop mirroring on a bridge.

BUILD & MAINTENANCE
  Network settings  Bridge, VLAN tag, firewall and NIC model (MAC is kept).
  Storage overview  Storages, their types, which disk formats they can hold,
                    and every disk in the folder with its format and size.
  Move / convert    Move disks to another storage and convert the format
                    (only formats the target storage supports are offered).
  EFI keys          Enroll Secure Boot keys on VMs that don't have them.
  Migrate           Move guests to other nodes (blocks or round-robin).
  Add-ons           Your own scripts in /etc/pve-range/addons - run them from
                    the menu, create and edit them on the node console.

PICKING GUESTS
  By VMID range, by class & sub-group (from the VMID), by name, by tag, by
  node, from a saved group, or tick them from a list. You always get a final
  list to untick guests before anything runs.

SAFETY
  - Every action shows the exact commands and asks before running them.
  - Settings -> Dry-run shows the commands without running anything.
  - Settings -> Protected guests are never shown or touched.
  - Everything is logged in /var/log/pve-range.log (with the web user's name).

KEYS
  Arrows move, Space ticks, Enter confirms, Tab jumps to the buttons,
  Esc goes back.
EOF
}

action_help() {
    local f
    f=$(mktemp)
    help_text >"$f"
    textfile "Help & user guide" "$f"
    rm -f "$f"
}

sep_item() {   # section title, padded to a fixed width
    local t=" $1 " ch="─" line
    ((UI_UTF8)) || ch="-"
    printf -v line '%*s' $((60 - ${#t} - 2)) ''
    printf '%s%s%s\n' "$ch$ch" "$t" "${line// /$ch}"
}
mi() {   # icon name description
    printf '%s%-18s %s' "$(ic "$1")" "$2" "$3"
}

tui() {
    [[ -t 0 && -t 1 ]] || die "No terminal - use a command instead (see --help)."
    if ! command -v whiptail >/dev/null; then
        local a
        read -rp "whiptail is not installed. Install it now (apt-get install whiptail)? [Y/n] " a
        [[ $a == [nN]* ]] && exit 1
        apt-get install -y whiptail || die "Could not install whiptail."
    fi
    INTERACTIVE=1
    setup_ui
    rm -f "$IDLE_FLAG"
    trap 'rm -f "$IDLE_FLAG"' EXIT
    log "menu opened"
    if ((ASK_FOLDER)) || [[ -z $LAST_FOLDER ]]; then
        choose_folder || { FOLDER=${LAST_FOLDER:-all}; inventory_dirty; }
    else
        FOLDER=$LAST_FOLDER
    fi
    load_inventory || die "Could not read the cluster inventory."
    local c last=class_start id run head dot_on="*" dot_off="-"
    ((UI_UTF8)) && dot_on="●" dot_off="○"
    while true; do
        [[ -e $IDLE_FLAG ]] && break
        load_inventory || true
        run=0
        for id in "${GUEST_IDS[@]}"; do [[ ${G_STATUS[$id]} == running ]] && ((run++)); done
        head="Folder: ${FOLDER:-all}   |   node $LOCAL_NODE   |   ${#NODES[@]} node(s) online"
        head+=$'\n'"${#GUEST_IDS[@]} guests:  $dot_on $run running   $dot_off $((${#GUEST_IDS[@]} - run)) stopped"
        ((${#PROTECTED_IDS[@]})) && head+="   (${#PROTECTED_IDS[@]} protected hidden)"
        ((DRY_RUN)) && head+=$'\n'"$(ic "⚠")DRY-RUN is ON - commands are only shown"
        c=$(MENU_DEFAULT=$last NOTAGS=1 CANCEL_LABEL=Quit menu "pve-range" "$head" \
            _1 "$(sep_item "Class")" \
            class_start  "$(mi "▶" "Start class" "restore the class snapshot, then power on")" \
            class_end    "$(mi "■" "End class" "restore the class snapshot, then power off")" \
            power_on     "$(mi "▷" "Power on" "start guests as they are (no restore)")" \
            power_off    "$(mi "□" "Power off" "shut guests down as they are (no restore)")" \
            _2 "$(sep_item "Snapshots")" \
            snap_take    "$(mi "+" "Take snapshot" "save the current state of guests")" \
            snap_restore "$(mi "↺" "Restore snapshot" "roll guests back to a snapshot")" \
            snap_delete  "$(mi "−" "Delete snapshot" "remove a snapshot from guests")" \
            _3 "$(sep_item "Sensors - port mirroring")" \
            mir_status   "$(mi "⇄" "Mirror status" "which sensors receive copied traffic")" \
            mir_setup    "$(mi "⇄" "Set up mirrors" "copy a bridge's traffic to sensor NICs")" \
            mir_apply    "$(mi "⇄" "Re-apply mirrors" "after a reboot or sensor restart")" \
            mir_remove   "$(mi "⇄" "Remove mirrors" "stop copying traffic on a bridge")" \
            _4 "$(sep_item "Build & maintenance")" \
            network      "$(mi "◈" "Network settings" "bridge, VLAN, firewall, NIC model")" \
            storage      "$(mi "▤" "Storage overview" "storages, disk formats and sizes")" \
            disks        "$(mi "▤" "Move / convert" "move disks, change disk format")" \
            efi          "$(mi "◇" "EFI keys" "enroll Secure Boot keys")" \
            migrate      "$(mi "→" "Migrate" "move guests to another node")" \
            addons       "$(mi "✱" "Add-ons" "run and edit your own scripts")" \
            _5 "$(sep_item "General")" \
            overview     "$(mi "≡" "Overview" "guests, nodes and snapshots in this folder")" \
            folder       "$(mi "▸" "Switch folder" "now: ${FOLDER:-all}")" \
            settings     "$(mi "⚙" "Settings" "dry-run, protected guests, theme ...")" \
            help         "$(mi "?" "Help" "user guide")" \
            quit         "$(mi "✕" "Quit" "")") || break
        [[ $c == _* ]] && continue
        last=$c
        case $c in
            class_start) action_class start ;;
            class_end) action_class end ;;
            power_on) action_power_on ;;
            power_off) action_stop ;;
            snap_take) load_inventory && snap_create ;;
            snap_restore) load_inventory && snap_rollback_or_delete rollback ;;
            snap_delete) load_inventory && snap_rollback_or_delete delete ;;
            mir_status) action_mirror_status ;;
            mir_setup) action_mirror_setup ;;
            mir_apply) action_mirror_apply ;;
            mir_remove) action_mirror_remove ;;
            network) action_network ;;
            storage) action_storage ;;
            disks) action_disks ;;
            efi) action_efi ;;
            migrate) action_migrate ;;
            addons) action_addons ;;
            overview) action_inventory ;;
            folder) choose_folder ;;
            settings) action_settings ;;
            help) action_help ;;
            quit) break ;;
        esac
    done
    clear
    if [[ -e $IDLE_FLAG ]]; then echo "Closed after ${PVE_RANGE_IDLE}s without activity."; fi
    log "menu closed"
}

###############################################################################
# Command line
###############################################################################
usage() {
    cat <<EOF
pve-range.sh $VERSION - Proxmox lab / range toolkit

Usage: $0 [--dry-run] [--yes] [--protect RANGES] [--folder NAME] [COMMAND [options]]

  (no command)          Open the menu
  list                  Guests, nodes and snapshots (in the folder)
  folders               Folders (classes) and how many guests each has
  storage               Storages, disk formats and every disk with its size
  help-guide            Print the user guide

  class-start           Restore the class snapshot, then power on       (old name: start)
  class-end             Restore the class snapshot, then power off      (old name: reset)
  power-on              Power on as they are - nothing restored
  power-off             Power off as they are - nothing restored        (old name: stop)
  snapshot NAME         Take a snapshot  [--off | --off-first] [--replace]

  mirror-status         Port mirrors on this node
  mirror-apply          Re-apply the saved port mirrors for this node
  mirror-clear BRIDGE   Remove all mirrors from BRIDGE on this node

Which guests (default: the guests on this node, $LOCAL_NODE):
  --folder NAME         Only one folder, e.g. 613, NetWars, Management, all
  --cluster             All nodes
  --only RANGES         Only these VMIDs, e.g. 510400-510430,9102
  --exclude RANGES      Leave these alone
  --keep RANGES         Don't restore these (still powered on / off)

Options:
  --snap NAME           Snapshot to restore (default: $DEFAULT_SNAP)
  --hard                Hard power-off instead of a graceful shutdown
  --timeout S           Seconds before a graceful shutdown is forced (default $SHUTDOWN_TIMEOUT)
  --dry-run             Show the commands but don't run them
  --yes                 Don't ask for confirmation
  --protect RANGES      Never touch these VMIDs

Examples:
  $0 --dry-run class-start --folder 613 --keep 510001-510002
  $0 --yes class-start --folder 612 && $0 --yes mirror-apply
  $0 --yes class-end --folder 613 --cluster
  $0 snapshot ClassStart --folder NetWars --cluster --off-first --replace
EOF
}

# cli_parse [shared options...]  -> SCOPE_IDS, CLI_* vars; unknown args go to CLI_REST
CLI_REST=()
cli_parse() {
    CLI_CLUSTER=0 CLI_ONLY="" CLI_EXCLUDE="" CLI_KEEP="" CLI_SNAP=$DEFAULT_SNAP CLI_HARD=0 CLI_REST=()
    while (($#)); do
        case $1 in
            --cluster) CLI_CLUSTER=1 ;;
            --only) CLI_ONLY=$2; shift ;;
            --exclude) CLI_EXCLUDE=$2; shift ;;
            --keep) CLI_KEEP=$2; shift ;;
            --snap) CLI_SNAP=$2; shift ;;
            --no-rollback) CLI_SNAP="" ;;
            --hard) CLI_HARD=1 ;;
            --timeout) SHUTDOWN_TIMEOUT=$2; shift ;;
            --folder) FOLDER=$2; shift ;;
            *) CLI_REST+=("$1") ;;
        esac
        shift
    done
    load_inventory || exit 1
    local id
    SCOPE_IDS=()
    for id in "${GUEST_IDS[@]}"; do
        if [[ -n $CLI_ONLY ]]; then
            in_ranges "$id" "$CLI_ONLY" || continue
        elif ((!CLI_CLUSTER)); then
            [[ ${G_NODE[$id]} == "$LOCAL_NODE" ]] || continue
        fi
        [[ -n $CLI_EXCLUDE ]] && in_ranges "$id" "$CLI_EXCLUDE" && continue
        SCOPE_IDS+=("$id")
    done
}

cli_rollback_ids() {   # RB_IDS = scope guests that have CLI_SNAP, minus --keep
    local id
    RB_IDS=()
    [[ -n $CLI_SNAP ]] || return 0
    for id in "${SCOPE_IDS[@]}"; do
        [[ -n $CLI_KEEP ]] && in_ranges "$id" "$CLI_KEEP" && continue
        has_snapshot "$id" "$CLI_SNAP" && RB_IDS+=("$id")
    done
}

cli_sdmode() { if ((CLI_HARD)); then echo stop; else echo shutdown; fi; }

cmd_start() {   # roll back + start
    cli_parse "$@"
    ((${#CLI_REST[@]})) && die "Unknown start option: ${CLI_REST[0]}"
    cli_rollback_ids
    START_IDS=("${SCOPE_IDS[@]}")
    build_start_plan "$CLI_SNAP"
    plan_run "$([[ -n $CLI_SNAP ]] && echo "Start class" || echo "Power on")"
    ((${#FAILED[@]} == 0))
}

cmd_reset() {   # roll back + leave everything shut down
    cli_parse "$@"
    ((${#CLI_REST[@]})) && die "Unknown reset option: ${CLI_REST[0]}"
    cli_rollback_ids
    mapfile -t OFF_IDS < <(running_after_rollback "$CLI_SNAP" "${SCOPE_IDS[@]}")
    build_off_plan "$CLI_SNAP" "$(cli_sdmode)"
    plan_run "End class"
    ((${#FAILED[@]} == 0))
}

cmd_stop() {   # shut down, no rollback
    cli_parse "$@"
    ((${#CLI_REST[@]})) && die "Unknown stop option: ${CLI_REST[0]}"
    local id
    OFF_IDS=()
    for id in "${SCOPE_IDS[@]}"; do [[ ${G_STATUS[$id]} == running ]] && OFF_IDS+=("$id"); done
    plan_reset
    plan_shutdown "$(cli_sdmode)" "${OFF_IDS[@]}"
    plan_run "Power off"
    ((${#FAILED[@]} == 0))
}

cmd_snapshot() {   # snapshot NAME [--off | --off-first] [--replace] [scope options]
    local name power=keep replace=0 a id c sdmode
    local -a pass=() running=()
    for a in "$@"; do
        case $a in
            --off) power=after ;;
            --off-first) power=before ;;
            --replace) replace=1 ;;
            *) pass+=("$a") ;;
        esac
    done
    cli_parse "${pass[@]}"
    name=${CLI_REST[0]:-}
    [[ $name =~ ^[A-Za-z][A-Za-z0-9_-]{1,39}$ ]] ||
        die "Usage: $0 snapshot NAME [--off|--off-first] [--replace] [--cluster|--only R] [--exclude R] [--hard]"
    ((${#CLI_REST[@]} > 1)) && die "Unknown snapshot option: ${CLI_REST[1]}"
    sdmode=$(cli_sdmode)
    local -a targets=()
    plan_reset
    for id in "${SCOPE_IDS[@]}"; do
        if has_snapshot "$id" "$name" && ((!replace)); then
            plan_note "$id already has '$name' - skipped (use --replace)"
            continue
        fi
        targets+=("$id")
        [[ ${G_STATUS[$id]} == running ]] && running+=("$id")
    done
    [[ $power == before ]] && plan_shutdown "$sdmode" "${running[@]}"
    for id in "${targets[@]}"; do
        c=$(guest_cmd "$id")
        has_snapshot "$id" "$name" && plan_add "${G_NODE[$id]}" "$c" delsnapshot "$id" "$name"
        plan_add "${G_NODE[$id]}" "$c" snapshot "$id" "$name"
    done
    [[ $power == after ]] && plan_shutdown "$sdmode" "${running[@]}"
    plan_run "Create snapshot '$name'"
    ((${#FAILED[@]} == 0))
}

main() {
    local cmd=""
    local -a rest=()
    # Global options may appear anywhere on the line
    while (($#)); do
        case $1 in
            --dry-run | -n) DRY_RUN=1 ;;
            --yes | -y) AUTO_YES=1 ;;
            --protect) PROTECTED=$2; shift ;;
            --folder) FOLDER=$2; shift ;;
            -h | --help | help) usage; exit 0 ;;
            *) if [[ -z $cmd && $1 != -* ]]; then cmd=$1; else rest+=("$1"); fi ;;
        esac
        shift
    done
    [[ -z $cmd && ${#rest[@]} -gt 0 ]] && die "Unknown option: ${rest[0]} (see --help)"
    set -- "${rest[@]}"

    [[ $EUID -eq 0 ]] || die "Please run as root."
    local c
    for c in pvesh perl; do
        command -v "$c" >/dev/null || die "'$c' not found - run this on a Proxmox VE node."
    done
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/tmp/pve-range.log
    load_vmid_map

    case $cmd in
        "") tui ;;
        list) load_inventory || exit 1; inventory_text ;;
        help-guide) help_text ;;
        start | class-start) cmd_start "$@" ;;
        reset | class-end) cmd_reset "$@" ;;
        power-on) cmd_start --no-rollback "$@" ;;
        stop | power-off) cmd_stop "$@" ;;
        folders)
            FOLDER=all
            load_inventory || exit 1
            local f
            for f in $(for c in "${ALL_GUEST_IDS[@]}"; do folder_of "$c"; done | sort | uniq -c | awk '{print $2 ":" $1}'); do
                printf '  %-14s %s guest(s)\n' "${f%%:*}" "${f#*:}"
            done
            ;;
        storage) FOLDER=${FOLDER:-all}; load_inventory || exit 1; load_storages; storage_text ;;
        snapshot) cmd_snapshot "$@" ;;
        mirror-apply)
            load_inventory || exit 1
            plan_reset
            mirror_build_saved "$LOCAL_NODE"
            plan_run "Re-apply port mirrors" || true
            ((${#FAILED[@]} == 0))
            ;;
        mirror-status) mirror_status_text "$LOCAL_NODE" ;;
        mirror-clear)
            [[ -n $1 ]] || die "Usage: $0 mirror-clear BRIDGE"
            plan_reset
            plan_add "$LOCAL_NODE" ovs-vsctl clear bridge "$1" mirrors
            plan_run "Remove mirrors from $1"
            ;;
        *) die "Unknown command: $cmd (see --help)" ;;
    esac
}

main "$@"
