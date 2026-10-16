#!/usr/bin/env bash
# zabbix-loadgen.sh - synthetic CPU, network and storage load for Zabbix testing
# Works on Rocky Linux, Arch Linux and Linux Mint (and their relatives).
#
# Examples:
#   ./zabbix-loadgen.sh                     # everything, 10 minutes, defaults
#   ./zabbix-loadgen.sh -d 30 -c 90         # 30 minutes, CPU at ~90%
#   ./zabbix-loadgen.sh -m cpu,disk -s 5    # no network, leave 5 GB of fill
#   ./zabbix-loadgen.sh -r 2M               # cap download speed (metered links)
#   ./zabbix-loadgen.sh -u http://192.168.77.50:8080/  # internal traffic only
#
# Press Ctrl+C at any time; all load stops and temp files are removed.

set -uo pipefail

# ---- defaults ------------------------------------------------------------
DURATION_MIN=10
CPU_PCT=70
DISK_GB=2
CHURN_MB=256
URL="https://speed.cloudflare.com/__down?bytes=100000000"
RATE=""
MODES="cpu,net,disk"
KEEP=0
WORKDIR="/var/tmp/zabbix-loadgen"

usage() {
  cat <<EOF
Usage: $0 [options]
  -d MIN    how long to run, in minutes            (default: $DURATION_MIN)
  -c PCT    CPU load per core, 1-100               (default: $CPU_PCT)
  -s GB     disk space to fill while running       (default: $DISK_GB)
  -u URL    URL to download repeatedly for traffic (default: Cloudflare speed test)
  -r RATE   download speed cap, e.g. 500K or 5M    (default: unlimited)
  -m LIST   loads to run: cpu,net,disk             (default: all)
  -k        keep the fill file afterwards, so disk usage stays visible
  -h        show this help
EOF
}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

while getopts "d:c:s:u:r:m:kh" opt; do
  case "$opt" in
    d) DURATION_MIN=$OPTARG ;;
    c) CPU_PCT=$OPTARG ;;
    s) DISK_GB=$OPTARG ;;
    u) URL=$OPTARG ;;
    r) RATE=$OPTARG ;;
    m) MODES=$OPTARG ;;
    k) KEEP=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

is_int() { [[ $1 =~ ^[0-9]+$ ]]; }
is_int "$DURATION_MIN" && (( DURATION_MIN > 0 )) || { echo "-d must be a positive whole number"; exit 1; }
is_int "$CPU_PCT" && (( CPU_PCT >= 1 && CPU_PCT <= 100 )) || { echo "-c must be 1-100"; exit 1; }
is_int "$DISK_GB" || { echo "-s must be a whole number"; exit 1; }

want() { [[ ",$MODES," == *",$1,"* ]]; }

# ---- distro detection, only used for install hints -----------------------
PKG_HINT="your package manager"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" arch "*)                               PKG_HINT="sudo pacman -S" ;;
    *" rhel "*|*" fedora "*|*" rocky "*)      PKG_HINT="sudo dnf install" ;;
    *" debian "*|*" ubuntu "*|*" linuxmint "*) PKG_HINT="sudo apt install" ;;
  esac
  log "Detected ${PRETTY_NAME:-unknown distro}"
fi

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'. Install it with: $PKG_HINT $2"; exit 1; }
}
need timeout coreutils
need nproc   coreutils
need dd      coreutils
need df      coreutils
want net && need curl curl

# ---- cleanup ---------------------------------------------------------------
PIDS=()
cleanup() {
  trap - EXIT INT TERM
  echo
  log "Stopping all load..."
  for p in "${PIDS[@]}"; do kill -TERM "$p" 2>/dev/null; done
  wait 2>/dev/null
  if (( KEEP )); then
    log "Keeping $WORKDIR/fill.bin (remove it later with: rm -rf $WORKDIR)"
    rm -f "$WORKDIR/seed.bin" "$WORKDIR/churn.bin"
  else
    rm -rf "$WORKDIR"
    log "Removed $WORKDIR"
  fi
  log "Done."
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Each worker runs its commands in the background and waits on them,
# so a TERM from cleanup interrupts it immediately instead of after
# the current command finishes.
worker_trap='trap '"'"'[[ -n ${CHILD:-} ]] && kill $CHILD 2>/dev/null; exit 0'"'"' TERM'
run() { "$@" & CHILD=$!; wait "$CHILD"; }

# ---- CPU -------------------------------------------------------------------
cpu_worker() {
  eval "$worker_trap"
  local busy idle
  busy=$(printf '%d.%02d' $((CPU_PCT / 100)) $((CPU_PCT % 100)))
  idle=$(printf '%d.%02d' $(((100 - CPU_PCT) / 100)) $(((100 - CPU_PCT) % 100)))
  while :; do
    run timeout "$busy" bash -c 'while :; do :; done'
    (( CPU_PCT < 100 )) && run sleep "$idle"
  done
}

# ---- network ---------------------------------------------------------------
net_worker() {
  eval "$worker_trap"
  local args=(-s -o /dev/null --max-time 120)
  [[ -n $RATE ]] && args+=(--limit-rate "$RATE")
  while :; do
    run curl "${args[@]}" "$URL" || run sleep 5
  done
}

# ---- storage ---------------------------------------------------------------
disk_worker() {
  eval "$worker_trap"
  # Random data, not zeros: ZFS and btrfs compress zeros to almost nothing,
  # which would hide the usage from Zabbix.
  if (( DISK_GB > 0 )); then
    log "Filling ${DISK_GB} GB in $WORKDIR (this takes a moment)..."
    run dd if=/dev/urandom of="$WORKDIR/fill.bin" bs=1M count=$((DISK_GB * 1024)) \
        conv=fdatasync status=none
    log "Fill complete; now generating continuous disk writes."
  fi
  run dd if=/dev/urandom of="$WORKDIR/seed.bin" bs=1M count="$CHURN_MB" status=none
  while :; do
    run dd if="$WORKDIR/seed.bin" of="$WORKDIR/churn.bin" bs=1M conv=fdatasync status=none
    run sleep 1
  done
}

# ---- start -----------------------------------------------------------------
if want disk; then
  mkdir -p "$WORKDIR"
  avail_gb=$(df -BG --output=avail "$WORKDIR" | tail -1 | tr -dc '0-9')
  max_gb=$(( avail_gb / 2 ))
  if (( DISK_GB > max_gb )); then
    log "Only ${avail_gb} GB free; limiting fill to ${max_gb} GB (half of free space)."
    DISK_GB=$max_gb
  fi
fi

CORES=$(nproc)
log "Running for ${DURATION_MIN} min: ${MODES}"

if want cpu; then
  for ((i = 0; i < CORES; i++)); do cpu_worker & PIDS+=($!); done
  log "CPU: ${CORES} workers at ~${CPU_PCT}% each"
fi
if want net; then
  net_worker & PIDS+=($!)
  log "Network: downloading ${URL}${RATE:+ (capped at $RATE/s)}"
fi
if want disk; then
  disk_worker & PIDS+=($!)
  log "Storage: ${DISK_GB} GB fill + ${CHURN_MB} MB rewrite loop in $WORKDIR"
fi

end=$(( $(date +%s) + DURATION_MIN * 60 ))
while (( $(date +%s) < end )); do
  left=$(( end - $(date +%s) ))
  printf '\r[%s] %d min %02d s remaining (Ctrl+C to stop) ' \
    "$(date +%H:%M:%S)" $((left / 60)) $((left % 60))
  sleep 5
done
