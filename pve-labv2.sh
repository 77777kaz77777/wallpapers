#!/usr/bin/env bash
#
# pve-lab.sh - one script for running the Proxmox VE lab
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
#   ./pve-lab.sh                 whiptail menu
#   ./pve-lab.sh --help          command-line usage (for cron / automation)
#
set -o pipefail

VERSION="1.2"
PVE_ROOT=${PVE_ROOT:-/etc/pve}
CONF_DIR=${PVE_LAB_CONF_DIR:-/etc/pve-lab}
SETTINGS_FILE="$CONF_DIR/settings.conf"
GROUPS_FILE="$CONF_DIR/groups.conf"
MIRRORS_FILE="$CONF_DIR/mirrors.conf"
LOG_FILE=${PVE_LAB_LOG:-/var/log/pve-lab.log}
LOCAL_NODE=${PVE_LAB_NODE:-$(hostname -s)}

# Defaults - can be changed in the Settings menu (saved to $SETTINGS_FILE)
START_DELAY=1
SHUTDOWN_TIMEOUT=180   # seconds before a graceful shutdown is forced off
MAX_PARALLEL=8         # shutdowns running at the same time
DEFAULT_SNAP="ClassStart"
SENSOR_PATTERN='dragos|sensor|tenable|zeek|suricata|snort|onion|nsm'
PROTECTED=""        # VMIDs/ranges pve-lab never touches, e.g. "100-103"
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

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null; }
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

load_inventory() {
    local json id type node status name tags
    json=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null) || {
        echo "Could not query the cluster (pvesh get /cluster/resources)." >&2
        return 1
    }
    G_TYPE=() G_NODE=() G_STATUS=() G_NAME=() G_TAGS=() GUEST_IDS=() PROTECTED_IDS=()
    while IFS=$'\t' read -r id type node status name tags; do
        [[ $id =~ ^[0-9]+$ ]] || continue
        if [[ -n $PROTECTED ]] && in_ranges "$id" "$PROTECTED"; then
            PROTECTED_IDS+=("$id"$'\t'"$type"$'\t'"$node"$'\t'"$status"$'\t'"$name")
            continue
        fi
        GUEST_IDS+=("$id")
        G_TYPE[$id]=$type
        G_NODE[$id]=$node
        G_STATUS[$id]=$status
        G_NAME[$id]=$name
        [[ $tags == - ]] && tags=""
        G_TAGS[$id]=$tags
    done < <(perl -MJSON::PP -e '
        local $/; my $d = decode_json(<STDIN>);
        for my $r (sort { $a->{vmid} <=> $b->{vmid} } @$d) {
            next if $r->{template};
            my $n = (defined $r->{name} && length $r->{name}) ? $r->{name} : "-";
            my $t = (defined $r->{tags} && length $r->{tags}) ? $r->{tags} : "-";
            print join("\t", $r->{vmid}, $r->{type}, $r->{node}, $r->{status} // "unknown", $n, $t), "\n";
        }' <<<"$json" 2>/dev/null)

    NODES=()
    json=$(pvesh get /nodes --output-format json 2>/dev/null) || json='[]'
    mapfile -t NODES < <(perl -MJSON::PP -e '
        local $/; my $d = decode_json(<STDIN>);
        print "$_->{node}\n" for sort { $a->{node} cmp $b->{node} }
                                grep { ($_->{status} // "") eq "online" } @$d' <<<"$json" 2>/dev/null)
    ((${#NODES[@]})) || NODES=("$LOCAL_NODE")
}

# node_bridges NODE [any_bridge|OVSBridge|bridge] -> "iface<TAB>type" lines
node_bridges() {
    pvesh get "/nodes/$1/network" --type "${2:-any_bridge}" --output-format json 2>/dev/null |
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
    [[ ${G_TYPE[$id]} == lxc ]] && t="CT "
    printf '%-26.26s %-10.10s %s' "$t${G_NAME[$id]}" "${G_NODE[$id]}" "${G_STATUS[$id]}"
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

vol_format() { case $1 in *.qcow2*) echo qcow2 ;; *.vmdk*) echo vmdk ;; *) echo raw ;; esac; }

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

    echo "${C_B}== $title ==${C_0}"
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
        read -rp "Press Enter to return to the menu... " _
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
    LH=$((H - 8))
}

wt() {
    local bt="pve-lab $VERSION  |  node: $LOCAL_NODE"
    ((DRY_RUN)) && bt+="  |  DRY-RUN (nothing will be changed)"
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
    wt --title "$1" "${extra[@]}" --menu "$2" "$H" "$W" "$LH" "${@:3}"
}
checklist() { term_size; wt --title "$1" --separate-output --checklist "$2" "$H" "$W" "$LH" "${@:3}"; }
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
        range "By VMID range(s)    e.g. 510400-510430,510500-510530" \
        name  "By name pattern     e.g. ews|ows" \
        tag   "By Proxmox tag" \
        node  "Everything on one node" \
        group "Saved group  ($GROUPS_FILE)" \
        all   "Every guest in the cluster") || return 1
    case $method in
        list | all) cand=("${GUEST_IDS[@]}") ;;
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

action_start() {   # Start / reset lab
    load_inventory || return
    local title="Start / reset lab" snap out id after mode
    local -a items=()
    choose_scope "$title" || return
    local -a ids=("${SCOPE_IDS[@]}")

    snap=$(choose_snapshot 1 "${ids[@]}") || return
    RB_IDS=()
    if [[ -n $snap ]]; then
        for id in "${ids[@]}"; do
            has_snapshot "$id" "$snap" && items+=("$id" "$(guest_label "$id")" ON)
        done
        if ((${#items[@]})); then
            out=$(checklist "$title" "Roll these back to '$snap'? (only guests that HAVE the snapshot are listed - untick e.g. Kali / servers you want to keep as-is)" "${items[@]}") || return
            [[ -n $out ]] && mapfile -t RB_IDS <<<"$out"
        else
            msg "None of these guests has a snapshot called '$snap'." "$title"
        fi
    fi

    after=$(menu "$title" "After the rollback, what should happen?" \
        start "Start the guests            (class start)" \
        off   "Shut everything down        (class end / reset and leave off)") || return

    items=()
    if [[ $after == start ]]; then
        for id in "${ids[@]}"; do items+=("$id" "$(guest_label "$id")" ON); done
        out=$(checklist "$title" "Start which guests? (containers start first, then VMs in VMID order, ${START_DELAY}s apart)" "${items[@]}") || return
        START_IDS=()
        [[ -n $out ]] && mapfile -t START_IDS <<<"$out"
        build_start_plan "$snap"
        plan_run "Start lab" || return
        ((DRY_RUN)) || offer_mirror_reapply
        return
    fi

    OFF_IDS=()
    while read -r id; do [[ -n $id ]] && items+=("$id" "$(guest_label "$id")" ON); done < <(running_after_rollback "$snap" "${ids[@]}")
    if ((${#items[@]})); then
        out=$(checklist "$title" "These guests would still be running afterwards. Shut down which?" "${items[@]}") || return
        [[ -n $out ]] && mapfile -t OFF_IDS <<<"$out"
        if ((${#OFF_IDS[@]})); then mode=$(choose_shutdown_mode "$title") || return; fi
    fi
    build_off_plan "$snap" "${mode:-shutdown}"
    plan_run "Reset lab and shut down"
}

action_stop() {   # Shut down without rolling back
    load_inventory || return
    local title="Shut down lab" out id mode
    local -a items=()
    choose_scope "$title" || return
    for id in "${SCOPE_IDS[@]}"; do
        [[ ${G_STATUS[$id]} == running ]] && items+=("$id" "$(guest_label "$id")" ON)
    done
    ((${#items[@]})) || { msg "None of those guests are running." "$title"; return; }
    out=$(checklist "$title" "Shut down which guests? (VMs first, containers last, $MAX_PARALLEL at a time)" "${items[@]}") || return
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

action_mirror() {
    local c f id line nic val st fw out
    while true; do
        load_inventory || return
        c=$(menu "Port mirroring (Open vSwitch)" \
            "Mirrors copy all traffic on an OVS bridge to a sensor NIC (Dragos, Tenable...)."$'\n'"They are lost when the sensor restarts or the host reboots - re-apply after starting the lab." \
            status "Show current mirrors" \
            create "Set up mirrors on a bridge (auto-detects sensor NICs)" \
            apply  "Re-apply saved mirrors" \
            clear  "Remove all mirrors from a bridge" \
            back   "Back") || return
        case $c in
            status)
                MB_NODE=$LOCAL_NODE
                if ((${#NODES[@]} > 1)); then MB_NODE=$(choose_node "Port mirroring") || continue; fi
                f=$(mktemp)
                mirror_status_text "$MB_NODE" >"$f"
                textfile "Mirrors on $MB_NODE" "$f"
                rm -f "$f"
                ;;
            create)
                mirror_pick || continue
                local -a items=() sel=()
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
                ((${#items[@]})) || { msg "No guest on $MB_NODE has a NIC on $MB_BRIDGE." "Port mirroring"; continue; }
                out=$(checklist "Port mirroring" "Which NICs should RECEIVE a copy of all $MB_BRIDGE traffic?"$'\n'"(likely sensors are pre-ticked; this replaces any existing mirrors on $MB_BRIDGE)" "${items[@]}") || continue
                [[ -n $out ]] || continue
                mapfile -t sel <<<"$out"
                plan_reset
                mirror_build "$MB_NODE" "$MB_BRIDGE" "${sel[@]}"
                if plan_run "Port mirroring on $MB_NODE/$MB_BRIDGE" && ((!DRY_RUN)); then
                    mirror_save "$MB_NODE" "$MB_BRIDGE" "${sel[@]}"
                fi
                ;;
            apply)
                [[ -s $MIRRORS_FILE ]] || { msg "Nothing saved yet - use 'Set up mirrors' first." "Port mirroring"; continue; }
                local -a items=()
                local n b e
                while IFS='|' read -r n b e; do items+=("$n|$b" "$e" ON); done <"$MIRRORS_FILE"
                out=$(checklist "Port mirroring" "Re-apply which saved mirror sets?" "${items[@]}") || continue
                plan_reset
                while IFS='|' read -r n b; do [[ -n $n ]] && mirror_build_saved "$n" "$b"; done <<<"$out"
                plan_run "Re-apply port mirrors"
                ;;
            clear)
                mirror_pick || continue
                plan_reset
                plan_add "$MB_NODE" ovs-vsctl clear bridge "$MB_BRIDGE" mirrors
                if plan_run "Remove mirrors from $MB_NODE/$MB_BRIDGE" && ((!DRY_RUN)) &&
                    grep -q "^$MB_NODE|$MB_BRIDGE|" "$MIRRORS_FILE" 2>/dev/null &&
                    confirm "Port mirroring" "Also forget the saved mirror config for $MB_NODE/$MB_BRIDGE?" --defaultno; then
                    mirror_save "$MB_NODE" "$MB_BRIDGE"
                fi
                ;;
            back) return ;;
        esac
    done
}

###############################################################################
# Snapshots
###############################################################################
snap_create() {
    select_guests "Create snapshot" any || return
    local title="Create snapshot" name desc vmstate=0 id n_exist=0 mode=new any_running=0 power=keep sdmode=shutdown c
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
    title="Roll back snapshot"
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
            leave "Leave them as the snapshot left them (disk-only = off, RAM = running)" \
            start "Start them" \
            off   "Make sure they are all shut down") || return
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

action_snapshots() {
    local c
    while true; do
        load_inventory || return
        c=$(menu "Snapshots" "" \
            create   "Create a snapshot  (optionally shut down before / after)" \
            rollback "Roll back to a snapshot  (then start / shut down / leave)" \
            delete   "Delete a snapshot from many guests" \
            back     "Back") || return
        case $c in
            create) snap_create ;;
            rollback) snap_rollback_or_delete rollback ;;
            delete) snap_rollback_or_delete delete ;;
            back) return ;;
        esac
    done
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
    local s t target fmt kinds del=0 id line key val vol store cur
    while read -r s t; do items+=("$s" "$t"); done < <(pvesm status --content images 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1, $2}')
    ((${#items[@]})) || { msg "No active storage for VM images found on $LOCAL_NODE." "Disks"; return; }
    target=$(menu "Move / convert disks" "Target storage:" "${items[@]}") || return
    fmt=$(MENU_DEFAULT=qcow2 menu "Move / convert disks" "Target format (qcow2/vmdk need a file-based storage: dir, NFS, CIFS...):" \
        qcow2 "QEMU image - thin, supports snapshots" raw "Raw" vmdk "VMware" keep "Don't specify (storage default)") || return
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
action_migrate() {
    load_inventory || return
    ((${#NODES[@]} > 1)) || { msg "Only one online node detected - nothing to migrate to." "Migrate"; return; }
    select_guests "Migrate guests" any || return
    local n out mode=block opts id t src i k chunk
    local -a items=() targets=() ids=() args=()
    for n in "${NODES[@]}"; do items+=("$n" "$([[ $n == "$LOCAL_NODE" ]] && echo '(this node)')" OFF); done
    out=$(checklist "Migrate guests" "Target node(s). Tick several to spread the guests across them:" "${items[@]}") || return
    [[ -n $out ]] || return
    mapfile -t targets <<<"$out"
    if ((${#targets[@]} > 1)); then
        mode=$(menu "Migrate guests" "How should the guests be spread over ${targets[*]}?" \
            block "Equal blocks in VMID order (first third -> node A, next -> B ...)" \
            rr    "Round-robin (1st -> A, 2nd -> B, 3rd -> C, 4th -> A ...)") || return
    fi
    opts=$(checklist "Migrate guests" "Options:" \
        online  "Live-migrate running VMs (--online)" ON \
        restart "Restart-migrate running containers (--restart)" ON \
        local   "Also move local disks (--with-local-disks)" OFF) || return

    mapfile -t ids < <(printf '%s\n' "${SELECTED[@]}" | sort -n)
    k=${#targets[@]}
    chunk=$(((${#ids[@]} + k - 1) / k))
    plan_reset
    for i in "${!ids[@]}"; do
        id=${ids[i]} src=${G_NODE[${ids[i]}]}
        if [[ $mode == rr ]]; then t=${targets[i % k]}; else t=${targets[i / chunk]}; fi
        [[ $src == "$t" ]] && { plan_note "$id is already on $t"; continue; }
        if is_qemu "$id"; then
            args=(qm migrate "$id" "$t")
            if [[ ${G_STATUS[$id]} == running ]]; then
                [[ $opts == *online* ]] || { plan_note "$id is running - skipped (enable --online)"; continue; }
                args+=(--online 1)
            fi
            [[ $opts == *local* ]] && args+=(--with-local-disks 1)
        else
            args=(pct migrate "$id" "$t")
            if [[ ${G_STATUS[$id]} == running ]]; then
                [[ $opts == *restart* ]] || { plan_note "CT $id is running - skipped (enable --restart)"; continue; }
                args+=(--restart 1)
            fi
        fi
        plan_add "$src" "${args[@]}"
    done
    plan_run "Migrate guests"
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
    printf '%-8s %-4s %-12s %-8s %-28s %s\n' VMID TYPE NODE STATUS NAME SNAPSHOTS
    printf '%s\n' "------------------------------------------------------------------------------------------"
    for id in "${GUEST_IDS[@]}"; do
        t=CT
        is_qemu "$id" && t=VM
        printf '%-8s %-4s %-12.12s %-8s %-28.28s %s\n' "$id" "$t" "${G_NODE[$id]}" "${G_STATUS[$id]}" \
            "${G_NAME[$id]}" "$(snapshots_of "$id" | paste -sd, -)"
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
    printf 'START_DELAY=%q\nSHUTDOWN_TIMEOUT=%q\nMAX_PARALLEL=%q\nDEFAULT_SNAP=%q\nSENSOR_PATTERN=%q\nPROTECTED=%q\n' \
        "$START_DELAY" "$SHUTDOWN_TIMEOUT" "$MAX_PARALLEL" "$DEFAULT_SNAP" "$SENSOR_PATTERN" "$PROTECTED" >"$SETTINGS_FILE"
}

edit_groups() {
    mkdir -p "$CONF_DIR"
    if [[ ! -e $GROUPS_FILE ]]; then
        cat >"$GROUPS_FILE" <<'EOF'
# Saved guest groups for pve-lab.sh
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
        c=$(menu "Settings" "" \
            dry    "Dry-run mode: $( ((DRY_RUN)) && echo ON || echo OFF)  (show commands, change nothing)" \
            snap   "Default snapshot name: $DEFAULT_SNAP" \
            delay  "Delay between starts: ${START_DELAY}s" \
            sdtime "Shutdown timeout before forcing off: ${SHUTDOWN_TIMEOUT}s" \
            par    "Shutdowns at the same time: $MAX_PARALLEL" \
            sensor "Sensor name pattern: $SENSOR_PATTERN" \
            protect "Protected guests (never touched): ${PROTECTED:-none}" \
            groups "Edit saved groups ($GROUPS_FILE)" \
            log    "View log ($LOG_FILE)" \
            back   "Back") || return
        case $c in
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
                v=$(ask "Settings" "VMIDs/ranges pve-lab must never touch (hidden from every list), e.g. 100-103. Empty = none:" "$PROTECTED") || continue
                PROTECTED=$(trim "$v")
                save_settings
                load_inventory
                ;;
            groups) edit_groups ;;
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
    load_inventory || return
    local f
    f=$(mktemp)
    inventory_text >"$f"
    textfile "Detected guests" "$f"
    rm -f "$f"
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
    load_inventory || die "Could not read the cluster inventory."
    local c
    while true; do
        c=$(menu "Main menu" "${#GUEST_IDS[@]} guests on ${#NODES[@]} node(s) detected. What do you want to do?" \
            1 "Show detected guests & snapshots" \
            2 "Start / reset lab (roll back, then start or shut down)" \
            3 "Shut down lab (VMs and containers)" \
            4 "Port mirroring (OVS -> sensors)" \
            5 "Snapshots (create / roll back / delete, with shutdown)" \
            6 "Change network (bridge / VLAN / firewall / model)" \
            7 "Move disks / convert format" \
            8 "Enroll EFI keys" \
            9 "Migrate guests between nodes" \
            s "Settings" \
            0 "Quit") || break
        case $c in
            1) action_inventory ;;
            2) action_start ;;
            3) action_stop ;;
            4) action_mirror ;;
            5) action_snapshots ;;
            6) action_network ;;
            7) action_disks ;;
            8) action_efi ;;
            9) action_migrate ;;
            s) action_settings ;;
            0) break ;;
        esac
    done
    clear
}

###############################################################################
# Command line
###############################################################################
usage() {
    cat <<EOF
pve-lab.sh $VERSION - Proxmox lab toolkit

Usage: $0 [--dry-run] [--yes] [--protect RANGES] [COMMAND [options]]

  (no command)               Open the whiptail menu
  list                       Show detected guests, nodes and snapshots

  start    [scope] [--snap NAME | --no-rollback] [--keep RANGES]
                             Roll back to the snapshot, then start (class start)
  reset    [scope] [--snap NAME] [--keep RANGES] [--hard] [--timeout S]
                             Roll back to the snapshot, then make sure all are off
  stop     [scope] [--hard] [--timeout S]
                             Shut down running guests (VMs first, containers last)
  snapshot NAME [scope] [--off | --off-first] [--replace] [--hard]
                             Snapshot guests; --off = shut down afterwards,
                             --off-first = shut down first (clean disks)

  mirror-apply               Re-apply the saved port mirrors for this node
  mirror-status              Show the OVS mirrors on this node
  mirror-clear BRIDGE        Remove all mirrors from BRIDGE on this node

  scope (default = guests on this node, $LOCAL_NODE):
    --cluster                All nodes
    --only RANGES            Only these VMIDs, e.g. 510400-510430,9102
    --exclude RANGES         Leave these alone
  --keep RANGES              Don't roll these back (still started / shut down)
  --hard                     Hard power-off instead of a graceful shutdown
  --timeout S                Seconds before a graceful shutdown is forced (default $SHUTDOWN_TIMEOUT)

  --dry-run                  Print the commands but don't run them
  --yes                      Don't ask for confirmation
  --protect RANGES           Never touch these VMIDs (overrides the saved setting)

Examples:
  $0 --dry-run start --keep 102,201-206
  $0 --yes start && $0 --yes mirror-apply
  $0 --yes reset --cluster                       # end of class: reset and power off
  $0 snapshot ClassStart --only 510400-510430 --off-first --replace
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
    plan_run "Start lab"
    ((${#FAILED[@]} == 0))
}

cmd_reset() {   # roll back + leave everything shut down
    cli_parse "$@"
    ((${#CLI_REST[@]})) && die "Unknown reset option: ${CLI_REST[0]}"
    cli_rollback_ids
    mapfile -t OFF_IDS < <(running_after_rollback "$CLI_SNAP" "${SCOPE_IDS[@]}")
    build_off_plan "$CLI_SNAP" "$(cli_sdmode)"
    plan_run "Reset lab and shut down"
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
    plan_run "Shut down lab"
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

main() { awk '/^\[/ {exit} {print}' "$(conf_file "$1")" 2>/dev/null; }
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
    [[ ${G_TYPE[$id]} == lxc ]] && t="CT "
    printf '%-26.26s %-10.10s %s' "$t${G_NAME[$id]}" "${G_NODE[$id]}" "${G_STATUS[$id]}"
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

vol_format() { case $1 in *.qcow2*) echo qcow2 ;; *.vmdk*) echo vmdk ;; *) echo raw ;; esac; }

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

    echo "${C_B}== $title ==${C_0}"
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
        read -rp "Press Enter to return to the menu... " _
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
    LH=$((H - 8))
}

wt() {
    local bt="pve-lab $VERSION  |  node: $LOCAL_NODE"
    ((DRY_RUN)) && bt+="  |  DRY-RUN (nothing will be changed)"
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
    wt --title "$1" "${extra[@]}" --menu "$2" "$H" "$W" "$LH" "${@:3}"
}
checklist() { term_size; wt --title "$1" --separate-output --checklist "$2" "$H" "$W" "$LH" "${@:3}"; }
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
        range "By VMID range(s)    e.g. 510400-510430,510500-510530" \
        name  "By name pattern     e.g. ews|ows" \
        tag   "By Proxmox tag" \
        node  "Everything on one node" \
        group "Saved group  ($GROUPS_FILE)" \
        all   "Every guest in the cluster") || return 1
    case $method in
        list | all) cand=("${GUEST_IDS[@]}") ;;
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

action_start() {   # Start / reset lab
    load_inventory || return
    local title="Start / reset lab" snap out id after mode
    local -a items=()
    choose_scope "$title" || return
    local -a ids=("${SCOPE_IDS[@]}")

    snap=$(choose_snapshot 1 "${ids[@]}") || return
    RB_IDS=()
    if [[ -n $snap ]]; then
        for id in "${ids[@]}"; do
            has_snapshot "$id" "$snap" && items+=("$id" "$(guest_label "$id")" ON)
        done
        if ((${#items[@]})); then
            out=$(checklist "$title" "Roll these back to '$snap'? (only guests that HAVE the snapshot are listed - untick e.g. Kali / servers you want to keep as-is)" "${items[@]}") || return
            [[ -n $out ]] && mapfile -t RB_IDS <<<"$out"
        else
            msg "None of these guests has a snapshot called '$snap'." "$title"
        fi
    fi

    after=$(menu "$title" "After the rollback, what should happen?" \
        start "Start the guests            (class start)" \
        off   "Shut everything down        (class end / reset and leave off)") || return

    items=()
    if [[ $after == start ]]; then
        for id in "${ids[@]}"; do items+=("$id" "$(guest_label "$id")" ON); done
        out=$(checklist "$title" "Start which guests? (containers start first, then VMs in VMID order, ${START_DELAY}s apart)" "${items[@]}") || return
        START_IDS=()
        [[ -n $out ]] && mapfile -t START_IDS <<<"$out"
        build_start_plan "$snap"
        plan_run "Start lab" || return
        ((DRY_RUN)) || offer_mirror_reapply
        return
    fi

    OFF_IDS=()
    while read -r id; do [[ -n $id ]] && items+=("$id" "$(guest_label "$id")" ON); done < <(running_after_rollback "$snap" "${ids[@]}")
    if ((${#items[@]})); then
        out=$(checklist "$title" "These guests would still be running afterwards. Shut down which?" "${items[@]}") || return
        [[ -n $out ]] && mapfile -t OFF_IDS <<<"$out"
        if ((${#OFF_IDS[@]})); then mode=$(choose_shutdown_mode "$title") || return; fi
    fi
    build_off_plan "$snap" "${mode:-shutdown}"
    plan_run "Reset lab and shut down"
}

action_stop() {   # Shut down without rolling back
    load_inventory || return
    local title="Shut down lab" out id mode
    local -a items=()
    choose_scope "$title" || return
    for id in "${SCOPE_IDS[@]}"; do
        [[ ${G_STATUS[$id]} == running ]] && items+=("$id" "$(guest_label "$id")" ON)
    done
    ((${#items[@]})) || { msg "None of those guests are running." "$title"; return; }
    out=$(checklist "$title" "Shut down which guests? (VMs first, containers last, $MAX_PARALLEL at a time)" "${items[@]}") || return
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

action_mirror() {
    local c f id line nic val st fw out
    while true; do
        load_inventory || return
        c=$(menu "Port mirroring (Open vSwitch)" \
            "Mirrors copy all traffic on an OVS bridge to a sensor NIC (Dragos, Tenable...)."$'\n'"They are lost when the sensor restarts or the host reboots - re-apply after starting the lab." \
            status "Show current mirrors" \
            create "Set up mirrors on a bridge (auto-detects sensor NICs)" \
            apply  "Re-apply saved mirrors" \
            clear  "Remove all mirrors from a bridge" \
            back   "Back") || return
        case $c in
            status)
                MB_NODE=$LOCAL_NODE
                if ((${#NODES[@]} > 1)); then MB_NODE=$(choose_node "Port mirroring") || continue; fi
                f=$(mktemp)
                mirror_status_text "$MB_NODE" >"$f"
                textfile "Mirrors on $MB_NODE" "$f"
                rm -f "$f"
                ;;
            create)
                mirror_pick || continue
                local -a items=() sel=()
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
                ((${#items[@]})) || { msg "No guest on $MB_NODE has a NIC on $MB_BRIDGE." "Port mirroring"; continue; }
                out=$(checklist "Port mirroring" "Which NICs should RECEIVE a copy of all $MB_BRIDGE traffic?"$'\n'"(likely sensors are pre-ticked; this replaces any existing mirrors on $MB_BRIDGE)" "${items[@]}") || continue
                [[ -n $out ]] || continue
                mapfile -t sel <<<"$out"
                plan_reset
                mirror_build "$MB_NODE" "$MB_BRIDGE" "${sel[@]}"
                if plan_run "Port mirroring on $MB_NODE/$MB_BRIDGE" && ((!DRY_RUN)); then
                    mirror_save "$MB_NODE" "$MB_BRIDGE" "${sel[@]}"
                fi
                ;;
            apply)
                [[ -s $MIRRORS_FILE ]] || { msg "Nothing saved yet - use 'Set up mirrors' first." "Port mirroring"; continue; }
                local -a items=()
                local n b e
                while IFS='|' read -r n b e; do items+=("$n|$b" "$e" ON); done <"$MIRRORS_FILE"
                out=$(checklist "Port mirroring" "Re-apply which saved mirror sets?" "${items[@]}") || continue
                plan_reset
                while IFS='|' read -r n b; do [[ -n $n ]] && mirror_build_saved "$n" "$b"; done <<<"$out"
                plan_run "Re-apply port mirrors"
                ;;
            clear)
                mirror_pick || continue
                plan_reset
                plan_add "$MB_NODE" ovs-vsctl clear bridge "$MB_BRIDGE" mirrors
                if plan_run "Remove mirrors from $MB_NODE/$MB_BRIDGE" && ((!DRY_RUN)) &&
                    grep -q "^$MB_NODE|$MB_BRIDGE|" "$MIRRORS_FILE" 2>/dev/null &&
                    confirm "Port mirroring" "Also forget the saved mirror config for $MB_NODE/$MB_BRIDGE?" --defaultno; then
                    mirror_save "$MB_NODE" "$MB_BRIDGE"
                fi
                ;;
            back) return ;;
        esac
    done
}

###############################################################################
# Snapshots
###############################################################################
snap_create() {
    select_guests "Create snapshot" any || return
    local title="Create snapshot" name desc vmstate=0 id n_exist=0 mode=new any_running=0 power sdmode=shutdown
    name=$(ask "$title" "Snapshot name (letters, digits, - and _, must start with a letter):" "$DEFAULT_SNAP") || return
    [[ $name =~ ^[A-Za-z][A-Za-z0-9_-]{1,39}$ ]] || { msg "'$name' is not a valid snapshot name." "$title"; return; }
    desc=$(ask "$title" "Description (optional):" "") || return
    local -a running=()
    for id in "${SELECTED[@]}"; do
        [[ ${G_STATUS[$id]} == running ]] && running+=("$id")
        is_qemu "$id" && [[ ${G_STATUS[$id]} == running ]] && any_running=1
        has_snapshot "$id" "$name" && ((n_exist++))
    done
    power=keep
    if ((${#running[@]})); then
        power=$(menu "$title" "${#running[@]} of the selected guests are running. Power afterwards?" \
            keep   "Leave them running" \
            after  "Take the snapshot, then shut them down" \
            before "Shut them down first, then snapshot (clean disks, no RAM)") || return
        if [[ $power != keep ]]; then sdmode=$(choose_shutdown_mode "$title") || return; fi
    fi
    if ((any_running)) && [[ $power != before ]] &&
        confirm "$title" "Include RAM for running VMs? (slower and much bigger)" --defaultno; then vmstate=1; fi
    if ((n_exist)); then
        mode=$(menu "$title" "$n_exist of the selected guests already have '$name'." \
            replace "Delete the old '$name' and take a new one" \
            skip    "Leave those guests alone") || return
    fi
    plan_reset
    [[ $power == before ]] && plan_shutdown "$sdmode" "${running[@]}"
    local c
    local -a args
    for id in "${SELECTED[@]}"; do
        c=$(guest_cmd "$id")
        if has_snapshot "$id" "$name"; then
            if [[ $mode == skip ]]; then plan_note "$id (${G_NAME[$id]}) already has '$name' - skipped"; continue; fi
            plan_add "${G_NODE[$id]}" "$c" delsnapshot "$id" "$name"
        fi
        args=("$c" snapshot "$id" "$name")
        [[ -n $desc ]] && args+=(--description "$desc")
        ((vmstate)) && is_qemu "$id" && [[ ${G_STATUS[$id]} == running ]] && args+=(--vmstate 1)
        plan_add "${G_NODE[$id]}" "${args[@]}"
    done
    [[ $power == after ]] && plan_shutdown "$sdmode" "${running[@]}"
    if ((vmstate)) && [[ $power == after ]]; then
        plan_note "RAM snapshots resume the VM when you roll back to them"
    fi
    plan_run "Create snapshot '$name'"
}

snap_rollback_or_delete() {   # rollback|delete
    local what=$1 title snap id after=leave sdmode=shutdown
    title="Roll back snapshot"
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
            leave "Leave them as the snapshot left them (disk-only = off, RAM = running)" \
            start "Start them" \
            off   "Make sure they are all shut down") || return
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

action_snapshots() {
    local c
    while true; do
        load_inventory || return
        c=$(menu "Snapshots" "" \
            create   "Create a snapshot  (optionally shut down before / after)" \
            rollback "Roll back to a snapshot  (then start / shut down / leave)" \
            delete   "Delete a snapshot from many guests" \
            back     "Back") || return
        case $c in
            create) snap_create ;;
            rollback) snap_rollback_or_delete rollback ;;
            delete) snap_rollback_or_delete delete ;;
            back) return ;;
        esac
    done
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
    local s t target fmt kinds del=0 id line key val vol store cur
    while read -r s t; do items+=("$s" "$t"); done < <(pvesm status --content images 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1, $2}')
    ((${#items[@]})) || { msg "No active storage for VM images found on $LOCAL_NODE." "Disks"; return; }
    target=$(menu "Move / convert disks" "Target storage:" "${items[@]}") || return
    fmt=$(MENU_DEFAULT=qcow2 menu "Move / convert disks" "Target format (qcow2/vmdk need a file-based storage: dir, NFS, CIFS...):" \
        qcow2 "QEMU image - thin, supports snapshots" raw "Raw" vmdk "VMware" keep "Don't specify (storage default)") || return
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
action_migrate() {
    load_inventory || return
    ((${#NODES[@]} > 1)) || { msg "Only one online node detected - nothing to migrate to." "Migrate"; return; }
    select_guests "Migrate guests" any || return
    local n out mode=block opts id t src i k chunk
    local -a items=() targets=() ids=() args=()
    for n in "${NODES[@]}"; do items+=("$n" "$([[ $n == "$LOCAL_NODE" ]] && echo '(this node)')" OFF); done
    out=$(checklist "Migrate guests" "Target node(s). Tick several to spread the guests across them:" "${items[@]}") || return
    [[ -n $out ]] || return
    mapfile -t targets <<<"$out"
    if ((${#targets[@]} > 1)); then
        mode=$(menu "Migrate guests" "How should the guests be spread over ${targets[*]}?" \
            block "Equal blocks in VMID order (first third -> node A, next -> B ...)" \
            rr    "Round-robin (1st -> A, 2nd -> B, 3rd -> C, 4th -> A ...)") || return
    fi
    opts=$(checklist "Migrate guests" "Options:" \
        online  "Live-migrate running VMs (--online)" ON \
        restart "Restart-migrate running containers (--restart)" ON \
        local   "Also move local disks (--with-local-disks)" OFF) || return

    mapfile -t ids < <(printf '%s\n' "${SELECTED[@]}" | sort -n)
    k=${#targets[@]}
    chunk=$(((${#ids[@]} + k - 1) / k))
    plan_reset
    for i in "${!ids[@]}"; do
        id=${ids[i]} src=${G_NODE[${ids[i]}]}
        if [[ $mode == rr ]]; then t=${targets[i % k]}; else t=${targets[i / chunk]}; fi
        [[ $src == "$t" ]] && { plan_note "$id is already on $t"; continue; }
        if is_qemu "$id"; then
            args=(qm migrate "$id" "$t")
            if [[ ${G_STATUS[$id]} == running ]]; then
                [[ $opts == *online* ]] || { plan_note "$id is running - skipped (enable --online)"; continue; }
                args+=(--online 1)
            fi
            [[ $opts == *local* ]] && args+=(--with-local-disks 1)
        else
            args=(pct migrate "$id" "$t")
            if [[ ${G_STATUS[$id]} == running ]]; then
                [[ $opts == *restart* ]] || { plan_note "CT $id is running - skipped (enable --restart)"; continue; }
                args+=(--restart 1)
            fi
        fi
        plan_add "$src" "${args[@]}"
    done
    plan_run "Migrate guests"
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
    printf '%-8s %-4s %-12s %-8s %-28s %s\n' VMID TYPE NODE STATUS NAME SNAPSHOTS
    printf '%s\n' "------------------------------------------------------------------------------------------"
    for id in "${GUEST_IDS[@]}"; do
        t=CT
        is_qemu "$id" && t=VM
        printf '%-8s %-4s %-12.12s %-8s %-28.28s %s\n' "$id" "$t" "${G_NODE[$id]}" "${G_STATUS[$id]}" \
            "${G_NAME[$id]}" "$(snapshots_of "$id" | paste -sd, -)"
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
    printf 'START_DELAY=%q\nSHUTDOWN_TIMEOUT=%q\nMAX_PARALLEL=%q\nDEFAULT_SNAP=%q\nSENSOR_PATTERN=%q\nPROTECTED=%q\n' \
        "$START_DELAY" "$SHUTDOWN_TIMEOUT" "$MAX_PARALLEL" "$DEFAULT_SNAP" "$SENSOR_PATTERN" "$PROTECTED" >"$SETTINGS_FILE"
}

edit_groups() {
    mkdir -p "$CONF_DIR"
    if [[ ! -e $GROUPS_FILE ]]; then
        cat >"$GROUPS_FILE" <<'EOF'
# Saved guest groups for pve-lab.sh
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
        c=$(menu "Settings" "" \
            dry    "Dry-run mode: $( ((DRY_RUN)) && echo ON || echo OFF)  (show commands, change nothing)" \
            snap   "Default snapshot name: $DEFAULT_SNAP" \
            delay  "Delay between starts: ${START_DELAY}s" \
            sdtime "Shutdown timeout before forcing off: ${SHUTDOWN_TIMEOUT}s" \
            par    "Shutdowns at the same time: $MAX_PARALLEL" \
            sensor "Sensor name pattern: $SENSOR_PATTERN" \
            protect "Protected guests (never touched): ${PROTECTED:-none}" \
            groups "Edit saved groups ($GROUPS_FILE)" \
            log    "View log ($LOG_FILE)" \
            back   "Back") || return
        case $c in
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
                v=$(ask "Settings" "VMIDs/ranges pve-lab must never touch (hidden from every list), e.g. 100-103. Empty = none:" "$PROTECTED") || continue
                PROTECTED=$(trim "$v")
                save_settings
                load_inventory
                ;;
            groups) edit_groups ;;
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
    load_inventory || return
    local f
    f=$(mktemp)
    inventory_text >"$f"
    textfile "Detected guests" "$f"
    rm -f "$f"
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
    load_inventory || die "Could not read the cluster inventory."
    local c
    while true; do
        c=$(menu "Main menu" "${#GUEST_IDS[@]} guests on ${#NODES[@]} node(s) detected. What do you want to do?" \
            1 "Show detected guests & snapshots" \
            2 "Start / reset lab (roll back, then start or shut down)" \
            3 "Shut down lab (VMs and containers)" \
            4 "Port mirroring (OVS -> sensors)" \
            5 "Snapshots (create / roll back / delete, with shutdown)" \
            6 "Change network (bridge / VLAN / firewall / model)" \
            7 "Move disks / convert format" \
            8 "Enroll EFI keys" \
            9 "Migrate guests between nodes" \
            s "Settings" \
            0 "Quit") || break
        case $c in
            1) action_inventory ;;
            2) action_start ;;
            3) action_stop ;;
            4) action_mirror ;;
            5) action_snapshots ;;
            6) action_network ;;
            7) action_disks ;;
            8) action_efi ;;
            9) action_migrate ;;
            s) action_settings ;;
            0) break ;;
        esac
    done
    clear
}

###############################################################################
# Command line
###############################################################################
usage() {
    cat <<EOF
pve-lab.sh $VERSION - Proxmox lab toolkit

Usage: $0 [--dry-run] [--yes] [COMMAND]

  (no command)            Open the whiptail menu
  list                    Show detected guests, nodes and snapshots
  start [options]         Roll back + start guests (non-interactive startvms.sh)
      --snap NAME           Snapshot to roll back to (default: $DEFAULT_SNAP)
      --no-rollback         Only start, never roll back
      --cluster             All nodes instead of only this node ($LOCAL_NODE)
      --keep RANGES         Start these without rolling back (e.g. 102,201-206)
      --exclude RANGES      Leave these alone completely
  mirror-apply            Re-apply the saved port mirrors for this node
  mirror-status           Show the OVS mirrors on this node
  mirror-clear BRIDGE     Remove all mirrors from BRIDGE on this node

  --dry-run               Print the commands but don't run them
  --yes                   Don't ask for confirmation
  --protect RANGES        Never touch these VMIDs (overrides the saved setting)

Examples:
  $0 --dry-run start --keep 102,201-206
  $0 --yes start && $0 --yes mirror-apply
EOF
}

cmd_start() {
    local snap=$DEFAULT_SNAP cluster=0 keep_spec="" exclude="" id
    while (($#)); do
        case $1 in
            --snap) snap=$2; shift ;;
            --no-rollback) snap="" ;;
            --cluster) cluster=1 ;;
            --keep) keep_spec=$2; shift ;;
            --exclude) exclude=$2; shift ;;
            *) die "Unknown start option: $1" ;;
        esac
        shift
    done
    load_inventory || exit 1
    local -A skip=() norb=()
    for id in $(ids_in_ranges "$exclude"); do skip[$id]=1; done
    for id in $(ids_in_ranges "$keep_spec"); do norb[$id]=1; done
    RB_IDS=() START_IDS=()
    for id in "${GUEST_IDS[@]}"; do
        ((cluster)) || [[ ${G_NODE[$id]} == "$LOCAL_NODE" ]] || continue
        [[ -n ${skip[$id]} ]] && continue
        START_IDS+=("$id")
        [[ -n $snap && -z ${norb[$id]} ]] && has_snapshot "$id" "$snap" && RB_IDS+=("$id")
    done
    build_start_plan "$snap"
    plan_run "Start lab"
    ((${#FAILED[@]} == 0))
}

main() {
    local cmd=""
    while (($#)); do
        case $1 in
            --dry-run | -n) DRY_RUN=1 ;;
            --yes | -y) AUTO_YES=1 ;;
            --protect) PROTECTED=$2; shift ;;
            -h | --help | help) usage; exit 0 ;;
            -*) die "Unknown option: $1 (see --help)" ;;
            *) cmd=$1; shift; break ;;
        esac
        shift
    done

    [[ $EUID -eq 0 ]] || die "Please run as root."
    local c
    for c in pvesh perl; do
        command -v "$c" >/dev/null || die "'$c' not found - run this on a Proxmox VE node."
    done
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/tmp/pve-lab.log

    case $cmd in
        "") tui ;;
        list) load_inventory || exit 1; inventory_text ;;
        start) cmd_start "$@" ;;
        reset) cmd_reset "$@" ;;
        stop) cmd_stop "$@" ;;
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
