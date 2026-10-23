#!/usr/bin/env bash
# gitea-backup-test.sh - does the Git (Gitea) backup of class guides (notes) and
# add-ons (scripts) really work - including getting them back?
#
# Docker / Podman (container mode) - run on the Docker host:
#     ./gitea-backup-test.sh                      # compose folder /opt/pve-range-docker
#     ./gitea-backup-test.sh /path/to/pve-range-docker
# Node mode - run on a Proxmox node with pve-range installed:
#     ./gitea-backup-test.sh --node
#
# It only touches its own test files (folder "BackupTest") and removes them again.
# pve-range must already be connected to the repository (./setup.sh repo, or the
# menu: Save & share -> Connect). Full output: /tmp/gitea-backup-test.out
#
OUT=/tmp/gitea-backup-test.out LAST=/tmp/gitea-backup-test.last
ID=$(date +%Y%m%d%H%M%S)-$$
TF=BackupTest                       # test folder (class) name
pass=0 fail=0
ok()   { echo "  PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail + 1)); }
step() { echo; echo "=== $*"; echo "=== $*" >>"$OUT"; }
: >"$OUT"

###############################################################################
# Where pve-range keeps things, and how to run commands there
###############################################################################
if [[ ${1:-} == --node ]]; then
    MODE=node SHARE=/etc/pve/pve-range TOKEN=/etc/pve/priv/pve-range-repo.token KEY=""
    run() { bash -c "$1"; }                     # run a shell snippet where pve-range lives
    put() { cat >"$1"; }                        # write stdin to a file there
    pr()  { pve-range "$@"; }
    command -v pve-range >/dev/null || { echo "pve-range isn't installed on this node."; exit 1; }
else
    DIR=${1:-/opt/pve-range-docker}
    cd "$DIR" 2>/dev/null || { echo "No compose folder at $DIR (use --node on a Proxmox node)."; exit 1; }
    if docker compose version >/dev/null 2>&1; then DC=(docker compose)
    elif podman compose version >/dev/null 2>&1; then DC=(podman compose)
    else DC=(docker-compose); fi
    MODE=container SHARE=/data/share TOKEN=/data/priv/pve-range-repo.token KEY=/data/ssh/git_ed25519
    run() { "${DC[@]}" exec -T -u pverange pve-range-web sh -c "$1"; }
    put() { "${DC[@]}" exec -T -u pverange pve-range-web sh -c "cat >'$1'"; }
    pr()  { "${DC[@]}" exec -T pve-range-web pve-range "$@"; }
fi
ADDONS=$SHARE/addons
CLONE=/tmp/bt-clone-$$ GITW=/tmp/bt-git-$$.sh

# A git wrapper with the same address, token and certificate setting pve-range uses
put "$GITW" <<EOF
#!/bin/sh
f=$SHARE/save.conf
url=\$(grep -m1 '^REPO_URL=' \$f | cut -d= -f2-); user=\$(grep -m1 '^REPO_USER=' \$f | cut -d= -f2-)
ins=\$(grep -m1 '^REPO_INSECURE=' \$f | cut -d= -f2-)
case \$url in http*://*@*) ;; http*://*) [ -n "\$user" ] && url="\${url%%://*}://\$user@\${url#*://}" ;; esac
[ "\$1" = --url ] && { echo "\$url"; exit 0; }
[ "\$1" = --branch ] && { b=\$(grep -m1 '^REPO_BRANCH=' \$f | cut -d= -f2-); echo "\${b:-main}"; exit 0; }
a=\$(mktemp); printf '#!/bin/sh\ncat $TOKEN\n' >\$a; chmod 700 \$a
GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=\$a GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new${KEY:+ -o IdentitiesOnly=yes -i $KEY}" \\
  git -c user.name=backup-test -c user.email=backup-test@pve-range -c http.sslVerify=\$([ "\$ins" = 1 ] && echo false || echo true) "\$@"
r=\$?; rm -f \$a; exit \$r
EOF
run "chmod 700 $GITW"
fresh_clone() { run "rm -rf $CLONE; sh $GITW clone -q -b \"\$(sh $GITW --branch)\" \"\$(sh $GITW --url)\" $CLONE" >"$LAST" 2>&1; }
sum_local()  { run "sha256sum '$1' 2>/dev/null | cut -d' ' -f1"; }
sum_remote() { run "sha256sum '$CLONE/$1' 2>/dev/null | cut -d' ' -f1"; }
same() { [[ -n $1 && $1 == "$2" ]]; }   # same non-empty checksum
cleanup() { run "rm -rf $CLONE $GITW" 2>/dev/null; }
trap cleanup EXIT

SCRIPT_REL="addons/$TF/bt-$ID.sh" GUIDE_REL="guides/$TF.txt"

###############################################################################
step "1. connected to a repository?"
url=$(run "sh $GITW --url" 2>/dev/null | sed -E 's#//[^@/]+@#//#')
[[ -n $url ]] || { bad "pve-range isn't connected to a repository - run ./setup.sh repo first"; exit 1; }
ok "repository: $url ($MODE mode)"
if run "sh $GITW ls-remote \"\$(sh $GITW --url)\"" >"$LAST" 2>&1; then ok "address and token work"
else bad "can't reach the repository: $(tail -1 "$LAST")"; exit 1; fi

step "2. a save sends everything"
pr save "backup-test $ID: start" >"$LAST" 2>&1; cat "$LAST" >>"$OUT"
grep -q '^Pushed to' "$LAST" && ok "save pushed to the repository" || { bad "save didn't push: $(tail -1 "$LAST")"; exit 1; }
fresh_clone && ok "fresh copy downloaded from the repository" || { bad "can't download: $(tail -1 "$LAST")"; exit 1; }
for d in addons guides; do
    l=$(run "cd $SHARE/$d 2>/dev/null && find . -type f -exec sha256sum {} + | sort -k2")
    r=$(run "cd $CLONE/$d 2>/dev/null && find . -type f -exec sha256sum {} + | sort -k2")
    if [[ $l == "$r" ]]; then ok "all $d ($(grep -c . <<<"$l") files) in the repository match pve-range, byte for byte"
    else bad "$d differ between pve-range and the repository:"; diff <(echo "$l") <(echo "$r") | head -6 | sed 's/^/        /'; fi
done

step "3. a new script and new class notes are backed up"
run "mkdir -p $ADDONS/$TF $SHARE/guides"
put "$SHARE/$SCRIPT_REL.tmp" <<EOF
#!/usr/bin/env bash
# NAME:   Backup test $ID
# DESC:   made by gitea-backup-test.sh - removed again at the end
# GUESTS: no
echo "backup test $ID version 1"
EOF
put "$SHARE/$GUIDE_REL.tmp" <<EOF
Class guide - $TF (backup test $ID)
version 1: notes written by the test
EOF
run "mv $SHARE/$SCRIPT_REL.tmp $SHARE/$SCRIPT_REL && mv $SHARE/$GUIDE_REL.tmp $SHARE/$GUIDE_REL"
v1_script=$(sum_local "$SHARE/$SCRIPT_REL") v1_guide=$(sum_local "$SHARE/$GUIDE_REL")
[[ -n $v1_script && -n $v1_guide ]] && ok "test script and class notes created" || { bad "couldn't create the test files"; exit 1; }
pr save "backup-test $ID: add" >"$LAST" 2>&1; cat "$LAST" >>"$OUT"
grep -q '^Pushed to' "$LAST" && ok "save pushed" || bad "save didn't push: $(tail -1 "$LAST")"
fresh_clone
same "$(sum_remote "$SCRIPT_REL")" "$v1_script" && ok "the script is in the repository, byte for byte" || bad "script missing or different in the repository"
same "$(sum_remote "$GUIDE_REL")" "$v1_guide" && ok "the class notes are in the repository, byte for byte" || bad "class notes missing or different in the repository"
run "cd $CLONE && git log -1 --format=%s -- $GUIDE_REL" | grep -q "backup-test $ID: add" &&
    ok "the commit says what was saved" || bad "commit message not found"

step "4. changes are backed up with their history"
run "for f in $SHARE/$SCRIPT_REL $SHARE/$GUIDE_REL; do sed 's/version 1/version 2/' \$f >/tmp/bt-edit.$$ && cat /tmp/bt-edit.$$ >\$f; done; rm -f /tmp/bt-edit.$$"
v2_script=$(sum_local "$SHARE/$SCRIPT_REL") v2_guide=$(sum_local "$SHARE/$GUIDE_REL")
[[ $v2_script != "$v1_script" && $v2_guide != "$v1_guide" ]] && ok "test files edited" || bad "couldn't edit the test files"
pr save "backup-test $ID: edit" >"$LAST" 2>&1; cat "$LAST" >>"$OUT"
fresh_clone
same "$(sum_remote "$SCRIPT_REL")" "$v2_script" && ok "the edited script is in the repository" || bad "edited script not in the repository"
same "$(sum_remote "$GUIDE_REL")" "$v2_guide" && ok "the edited notes are in the repository" || bad "edited notes not in the repository"
n=$(run "cd $CLONE && git log --format=%h -- $GUIDE_REL | wc -l")
((n >= 2)) && ok "the notes have $n versions in the history" || bad "history has only $n version(s) of the notes"
old=$(run "cd $CLONE && git log --format=%h --grep='backup-test $ID: add' -- $GUIDE_REL | head -1")
run "cd $CLONE && git show $old:$GUIDE_REL" | grep -q 'version 1' &&
    ok "an older version can still be read from the history" || bad "older version not readable"

step "5. restore after the files are lost"
run "rm -f $SHARE/$SCRIPT_REL $SHARE/$GUIDE_REL"
[[ -z $(sum_local "$SHARE/$GUIDE_REL") ]] && ok "test files deleted (as if by accident, not saved)" || bad "couldn't delete the test files"
pr --yes pull >"$LAST" 2>&1; rc=$?; cat "$LAST" >>"$OUT"
((rc == 0)) && ok "pull from the repository (exit 0)" || bad "pull failed: $(tail -1 "$LAST")"
same "$(sum_local "$SHARE/$SCRIPT_REL")" "$v2_script" && ok "the script is back, byte for byte" || bad "the script did NOT come back"
same "$(sum_local "$SHARE/$GUIDE_REL")" "$v2_guide" && ok "the class notes are back, byte for byte" || bad "the class notes did NOT come back"

step "6. a change made in Gitea comes back into pve-range"
run "cd $CLONE && echo 'edited in Gitea by the test' >>$GUIDE_REL && git add -A && sh $GITW commit -qm 'backup-test $ID: edited in Gitea' && sh $GITW push -q origin HEAD" >"$LAST" 2>&1 &&
    ok "pushed a change straight to the repository (like editing in Gitea)" || bad "couldn't push to the repository: $(tail -1 "$LAST")"
pr --yes pull >"$LAST" 2>&1; cat "$LAST" >>"$OUT"
run "grep -q 'edited in Gitea by the test' $SHARE/$GUIDE_REL" && ok "pve-range now has the change from Gitea" || bad "the change from Gitea didn't arrive"

step "7. removing them is backed up too (cleanup)"
run "rm -rf $ADDONS/$TF $SHARE/$GUIDE_REL"
pr save "backup-test $ID: remove" >"$LAST" 2>&1; cat "$LAST" >>"$OUT"
grep -q '^Pushed to' "$LAST" && ok "save pushed" || bad "save didn't push: $(tail -1 "$LAST")"
fresh_clone
run "[ ! -e $CLONE/$SCRIPT_REL ] && [ ! -e $CLONE/$GUIDE_REL ]" && ok "the test files are gone from the repository too" ||
    bad "test files are still in the repository"
run "[ ! -e $SHARE/$SCRIPT_REL ] && [ ! -e $SHARE/$GUIDE_REL ]" && ok "and from pve-range" || bad "test files still in pve-range"

echo
echo "=================================="
echo " $pass passed, $fail failed"
echo " repository: $url"
echo " full log: $OUT"
echo "=================================="
((fail == 0))
