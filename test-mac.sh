#!/bin/bash
# School Printer - test on a Mac (also works on Linux).
#   curl -fsSL https://print.mahanmirzaee.com/test-mac.sh | bash
#   curl -fsSL https://print.mahanmirzaee.com/test-mac.sh | bash -s 192.168.1.20     # also test one computer by its address
# Part 1 looks at the School Printer installed on this computer: is it running, which network, what it found, and an
#        independent search of this computer's networks (so you can see whether a problem is the network or the program).
# Part 2 runs 4 simulated stations on this computer (ports 8701-8704, a fake printer, nothing is printed, nothing is
#        announced on the network) with the latest program from print.mahanmirzaee.com, and tests the printing network.
# Nothing is installed or changed. A report is saved to the Desktop (school-printer-test.txt) to send.
# Needs: bash, curl, perl (all built into macOS). No administrator password.

PORT=8631; ONE="${1:-}"
SITE="https://print.mahanmirzaee.com"; CDN="https://cdn.jsdelivr.net/gh/MahanHG88/school-printer-dist"
if [ "$(uname)" = Darwin ]; then DIR="/Library/Application Support/SchoolPrinter"; else DIR="/opt/schoolprinter"; fi
REPORT="$HOME/Desktop/school-printer-test.txt"; [ -d "$HOME/Desktop" ] || REPORT="/tmp/school-printer-test.txt"
WORK="$(mktemp -d /tmp/sp-test.XXXXXX)"; PIDS=""
if [ -t 1 ]; then G=$'\e[32m'; RD=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; R=$'\e[0m'; else G=; RD=; Y=; B=; D=; R=; fi
NPASS=0; NFAIL=0; NWARN=0; : > "$WORK/report"

out()  { printf '%s\n' "$1"; printf '%s\n' "$1" | sed $'s/\e\\[[0-9;]*m//g' >> "$WORK/report"; }
step() { out ""; out "${B}== $1${R}"; }
pass() { NPASS=$((NPASS + 1)); out "  ${G}[PASS]${R} $1${2:+  ${D}- $2${R}}"; }
fail() { NFAIL=$((NFAIL + 1)); out "  ${RD}[FAIL]${R} $1${2:+  ${D}- $2${R}}"; }
warn() { NWARN=$((NWARN + 1)); out "  ${Y}[WARN]${R} $1${2:+  ${D}- $2${R}}"; }
info() { out "  ${D}[INFO]${R} $1"; }
rec()  { if [ "$1" = 1 ]; then pass "$2" "$3"; else fail "$2" "$3"; fi; }
# json: echo '{...}' | js '<perl expression on $d>'   (JSON::PP is part of every perl since 5.14)
js()   { perl -MJSON::PP -e 'my $t = join "", <STDIN>; my $d = eval { JSON::PP->new->decode($t) }; exit 0 unless ref $d; my $v = eval $ARGV[0]; print defined $v ? $v : ""' "$1"; }
get()  { curl -s -m "${3:-5}" "$1$2"; }
adm()  { curl -s -m "${3:-5}" -H 'X-Admin: 1' "$1$2"; }    # admin information: only from this computer
post() { curl -s -m 30 -H 'Content-Type: application/json' -H 'X-Admin: 1' --data "$3" "$1$2"; }
code() { curl -s -m "${3:-5}" -o /dev/null -w '%{http_code}' "$1$2"; }
wait_for() { local end=$(( $(date +%s) + $2 )); while [ "$(date +%s)" -lt "$end" ]; do eval "$1" && return 0; sleep 1; done; return 1; }
cleanup() {
    for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    sleep 1; for p in $PIDS; do pkill -9 -P "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

out "${B}School Printer test${R}  ${D}$(date '+%Y-%m-%d %H:%M')  ·  $(uname -sr)  ·  $(sw_vers -productVersion 2>/dev/null)${R}"

# ================================================================ Part 1: the School Printer on this computer
step "1. School Printer on this computer"
LATEST="$(curl -fsSL -m 15 "$SITE/install.sh" 2>/dev/null | sed -n 's/^VERSION="\([0-9.]*\)".*/\1/p' | head -1)"
MINE=""; [ -r "$DIR/schoolprinter.pl" ] && MINE="$(sed -n "s/.*my \$VERSION = '\([0-9.]*\)'.*/\1/p" "$DIR/schoolprinter.pl" | head -1)"
if [ -z "$MINE" ]; then fail "installed" "not found in $DIR - install it from $SITE first (part 2 still runs)"
elif [ -n "$LATEST" ] && [ "$MINE" != "$LATEST" ]; then warn "installed version $MINE" "the latest is $LATEST - install again from $SITE to update"
else pass "installed" "version $MINE${LATEST:+ (latest)}"; fi
HERE="http://127.0.0.1:$PORT"
if [ "$(code "$HERE" /status 4)" = 200 ]; then pass "the service answers" "$HERE"
else fail "the service answers" "nothing on port $PORT - use the \"Start School Printer\" shortcut, or restart the computer"; fi
H="$(get "$HERE" /sync/hello)"; MYID="$(echo "$H" | js '$d->{id}')"
if [ -n "$MYID" ]; then
    NET="$(echo "$H" | js '$d->{net}')"; GID="$(echo "$H" | js '$d->{gid}')"
    rec "$( [ "$(echo "$H" | js '$d->{proto}')" = 2 ] && echo 1 )" "encrypted station protocol" "protocol $(echo "$H" | js '$d->{proto}')"
    info "station \"$(echo "$H" | js '$d->{station}')\"  ·  network: $NET${GID:+ ($GID)}  ·  id ${MYID:0:8}"
    I="$(adm "$HERE" /admin/info 8)"
    if [ -n "$I" ]; then
        echo "$I" | js 'join "", map { sprintf "     %-3s %-24s %-24s %s\n", ($_->{online} ? "on" : "OFF"), $_->{station}, $_->{url}, ($_->{here} ? "(this computer)" : $_->{err}) } @{ $d->{net}{stations} || [] }' > "$WORK/st"
        N="$(echo "$I" | js 'scalar grep { $_->{online} } @{ $d->{net}{stations} || [] }')"; info "stations this one sees online: ${N:-0}"
        while IFS= read -r l; do out "$l"; done < "$WORK/st"
        MAIN="$(echo "$I" | js '$d->{net}{main}')"; MN="$(echo "$I" | js 'my $m = $d->{net}{main}; (map { $_->{station} } grep { $_->{id} eq $m } @{ $d->{net}{stations} || [] })[0]')"
        info "main station: ${MN:-?}${MAIN:+ (${MAIN:0:8})}"
        S="$(echo "$I" | js 'my $s = $d->{net}{search}; $s ? "searched $s->{targets} addresses on " . join(", ", @{ $s->{nets} || [] }) . " - $s->{open} answered, $s->{printers} School Printers, " . (time - $s->{at}) . " s ago" : ""')"
        [ -n "$S" ] && info "its last search: $S" || info "its last search: (not shown - this version is older than 1.7.2)"
        AL="$(echo "$I" | js 'join ", ", map { $_->{station} } @{ $d->{net}{alerts} || [] }')"
        [ -n "$AL" ] && warn "identity changed" "$AL - if that computer was reinstalled, press \"Trust again\" on the admin page"
        echo "$I" | js 'join "\n", map { $_->{id} } @{ $d->{net}{stations} || [] }' > "$WORK/known"
    else warn "admin information" "the admin page did not answer from this computer"; fi
fi

step "2. This computer's networks"
NETS=""
if [ "$(uname)" = Darwin ]; then
    DEF="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')"
    ifconfig | perl -ne 'if (/^(\S+):/) { $if = $1 } elsif (/inet (\d+\.\d+\.\d+\.\d+) (?:--> \S+ )?netmask 0x([0-9a-f]{8})/i) { printf "%s %s %d\n", $if, $1, unpack("%32b*", pack("H8", $2)) }' > "$WORK/ifs"
else
    DEF="$(ip route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1); exit }')"
    ip -4 -o addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); print $2, a[1], a[2] }' > "$WORK/ifs"
fi
while read -r IF IP PRE; do
    case "$IP" in 127.*|169.254.*) continue;; esac
    kind=""; case "$IF" in utun*|ipsec*|ppp*|tun*|wg*|tailscale*|zt*) kind="VPN";; bridge*|docker*|br-*|vmnet*|vboxnet*|veth*|virbr*) kind="virtual";; esac
    note="$IF $IP/$PRE"; [ "$IF" = "$DEF" ] && note="$note  (internet goes this way)"
    if [ "$kind" = VPN ]; then warn "VPN interface $note" "a VPN can route the school network away - if stations are missing, turn the VPN off or exclude the local network (LAN) in its settings"
    elif [ "$kind" = virtual ]; then info "virtual network $note (ignored)"
    elif [ "$PRE" -gt 30 ]; then info "$note (single address, nothing to search)"
    else pass "local network" "$note"; NETS="$NETS $IP/$PRE"; fi
done < "$WORK/ifs"
[ -z "$NETS" ] && fail "a local network to search" "no Wi-Fi or cable network with room for other computers - is this computer on the school network?"
[ "$(uname)" = Darwin ] && [ -n "$DEF" ] && case "$DEF" in utun*|ipsec*|ppp*) warn "all traffic goes through a VPN ($DEF)" "School Printer only works when this computer reaches the school network directly";; esac

step "3. Searching for School Printers myself (port $PORT)"
: > "$WORK/targets"
for n in $NETS; do perl -e 'my ($ip, $p) = split m{/}, $ARGV[0]; $p = 22 if $p < 22; my $x = unpack "N", pack "C4", split /\./, $ip; my $net = $x & ((0xFFFFFFFF << (32 - $p)) & 0xFFFFFFFF);
    for my $k (1 .. 2 ** (32 - $p) - 2) { my $a = join ".", unpack "C4", pack "N", $net + $k; print "$a\n" unless $a eq $ip }' "$n" >> "$WORK/targets"; done
[ -n "$ONE" ] && echo "$ONE" >> "$WORK/targets"
NT="$(sort -u "$WORK/targets" | grep -c .)"
if [ "$NT" -gt 0 ]; then
    info "asking $NT addresses (about $(( NT / 64 + 3 )) s)..."
    sort -u "$WORK/targets" | xargs -P 64 -I{} sh -c 'r=$(curl -s -m 2 "http://{}:'"$PORT"'/sync/hello" 2>/dev/null); case "$r" in *school-printer*) printf "%s %s\n" "{}" "$r";; esac' > "$WORK/found" 2>/dev/null
    NF=0
    while read -r A J; do
        NF=$((NF + 1)); id="$(echo "$J" | js '$d->{id}')"; st="$(echo "$J" | js '$d->{station}')"; gid="$(echo "$J" | js '$d->{gid}')"; net="$(echo "$J" | js '$d->{net}')"
        if [ "$id" = "$MYID" ]; then info "$A  \"$st\"  (this computer)"; continue; fi
        same=""; [ -n "$GID" ] && [ "$gid" = "$GID" ] && same=1
        if [ -z "$same" ]; then info "$A  \"$st\"  on another network ($net) - not ours, which is fine"
        elif grep -qx "$id" "$WORK/known" 2>/dev/null; then pass "$A  \"$st\"" "same network, and the service knows it"
        else fail "$A  \"$st\"" "same network, but the service does not list it - please send this report"; fi
    done < "$WORK/found"
    [ "$NF" = 0 ] && warn "no School Printer answered on this computer's networks" "if another computer runs School Printer: check it is on the same network, and (Windows) that its firewall allows the local network"
fi
if [ -n "$ONE" ]; then
    c="$(code "http://$ONE:$PORT" /sync/hello 4)"
    if [ "$c" = 200 ]; then pass "$ONE answers on port $PORT"; else fail "$ONE answers on port $PORT" "no answer (code $c) - wrong address, computer off, School Printer stopped, or a firewall in between"; fi
fi

# ================================================================ Part 2: simulated stations with the latest program
step "4. Simulation: getting the latest program"
SRC="$WORK/schoolprinter.pl"
if [ -n "${SP_TEST_SRC:-}" ]; then cp "$SP_TEST_SRC" "$SRC"    # (developers: test a local copy)
else for u in ${LATEST:+"$CDN@v$LATEST/app/unix/schoolprinter.pl"} "$SITE/app/unix/schoolprinter.pl"; do curl -fsSL -m 90 -o "$SRC" "$u" 2>/dev/null && break; done; fi
if ! perl -c "$SRC" >/dev/null 2>&1; then fail "program downloaded" "could not download it - part 2 skipped"; out ""; out "${B}Result:${R} $NPASS passed, $NFAIL failed, $NWARN warnings"; cp "$WORK/report" "$REPORT"; exit 1; fi
pass "program downloaded" "version $(sed -n "s/.*my \$VERSION = '\([0-9.]*\)'.*/\1/p" "$SRC" | head -1)"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/lp" <<'EOF'
#!/bin/bash
Q="${FAKEQ:?}"; n=$(( $(wc -l < "$Q" 2>/dev/null || echo 0) + RANDOM ))
echo "TestPrinter-$n user 1024 now" >> "$Q"; echo "request id is TestPrinter-$n (1 file(s))"
EOF
cat > "$WORK/bin/lpstat" <<'EOF'
#!/bin/bash
Q="${FAKEQ:?}"; touch "$Q"
case "$1" in -e) echo TestPrinter;; -d) echo "system default destination: TestPrinter";; -p) echo "printer $2 is idle.  enabled since today";; -o) cat "$Q";; -v) echo "device for TestPrinter: usb://Fake/Printer";; esac
EOF
cat > "$WORK/bin/lpoptions" <<'EOF'
#!/bin/bash
echo "PageSize/Media Size: *A4 Letter A5"; echo "ColorModel/Color Mode: Gray *RGB"
EOF
for f in dns-sd avahi-publish; do printf '#!/bin/bash\nexec sleep 100000\n' > "$WORK/bin/$f"; done    # simulated stations stay off the real network's Bonjour
cat > "$WORK/bin/cancel" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$WORK/bin/"*
LIST="127.0.0.1:8701,127.0.0.1:8702,127.0.0.1:8703"
start_station() {    # number, scan list
    local i=$1 d="$WORK/s$1"; mkdir -p "$d/web"
    printf 'printer=TestPrinter\npin=\nopen=1\nlang=en\nstation=Test %s\nshare=1\naccept=1\nconv=1\n' "$i" > "$d/config.txt"
    SP_DIR="$d" SP_PORT="870$i" SP_ADDR="http://127.0.0.1:870$i" SP_SCAN="$2" SP_PATH="$WORK/bin" FAKEQ="$d/q" SP_DNSPORT="1535$i" \
        SP_NOMDNS=1 SP_NOPOPUP=1 perl "$SRC" > "$d/server.log" 2>&1 &
    eval "P$i=$!"; PIDS="$PIDS $!"
}
U() { echo "http://127.0.0.1:870$1"; }
online() { adm "$(U "$1")" /admin/info 5 | js 'scalar grep { $_->{online} } @{ $d->{net}{stations} || [] }'; }
mainof() { adm "$(U "$1")" /admin/info 5 | js '$d->{net}{main}'; }
sees() { adm "$(U "$1")" /admin/info 5 | js 'join ",", map { $_->{station} } grep { $_->{online} } @{ $d->{net}{stations} || [] }'; }
busy=""; for p in 8701 8702 8703 8704; do [ "$(code "http://127.0.0.1:$p" / 1)" != 000 ] && busy="$busy $p"; done
if [ -n "$busy" ]; then fail "test ports free" "in use:$busy - close what uses them and run again"; else
start_station 1 "$LIST"; start_station 2 "$LIST"; start_station 3 "$LIST"
ok=1; for i in 1 2 3; do wait_for "[ \"\$(code $(U $i) /status 2)\" = 200 ]" 30 || ok=0; done
rec "$ok" "3 simulated stations start" "ports 8701-8703"

step "5. Simulation: the printing network"
t0=$(date +%s); wait_for '[ "$(online 1)" = 3 ] && [ "$(online 2)" = 3 ] && [ "$(online 3)" = 3 ]' 90 && ok=1 || ok=0
rec "$ok" "all 3 find each other (public network, nothing typed)" "$(( $(date +%s) - t0 )) s"
rec "$( [ "$(code "$(U 1)" /sync/status 4)" = 401 ] && echo 1 )" "a request without the network's encryption is refused"
wait_for '[ -n "$(mainof 1)" ] && [ "$(mainof 1)" = "$(mainof 2)" ] && [ "$(mainof 2)" = "$(mainof 3)" ]' 45 && ok=1 || ok=0
M="$(mainof 1)"; MN=""; for i in 1 2 3; do [ "$(get "$(U $i)" /sync/hello | js '$d->{id}')" = "$M" ] && MN=$i; done
rec "$ok" "all agree on one main station" "Test $MN"
printf '%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > "$WORK/t.pdf"
T3="$(get "$(U 3)" /sync/hello | js '$d->{id}')"
UP="$(curl -s -m 20 -H 'X-Filename: test.pdf' --data-binary @"$WORK/t.pdf" "$(U 1)/upload" | js '$d->{id}')"
BJ='{"id":"'"$UP"'","copies":1,"pages":"","paper":"A4","orientation":"auto","color":"gray","duplex":"off","margins":"none","scale":"fit","nup":1,"land":false,"sheets":1,"target":"'"$T3"'"}'
J="$(post "$(U 1)" /print "$BJ")"
JID="$(echo "$J" | js '$d->{jid}')"
wait_for '[ -s "$WORK/s3/q" ]' 30 && ok=1 || ok=0
rec "$ok" "a job for a picked printer prints there" "sent at Test 1, printed at Test 3"

step "6. Simulation: private network with a one-time token"
TOK="$(post "$(U 1)" /admin/net '{"do":"private"}' | js '$d->{token}')"
rec "$(echo "$TOK" | grep -Eq '^[A-HJKMNP-Z2-9]{12}$' && echo 1)" "station 1 creates a private network and shows a token" "$TOK"
rec "$( [ -n "$(post "$(U 2)" /admin/net '{"do":"join","token":"AAAA-BBBB-CCCC"}' | js '$d->{error}')" ] && echo 1 )" "a wrong token is refused"
TF="$(echo "$TOK" | sed 's/\(....\)\(....\)\(....\)/\1-\2-\3/' | tr 'A-Z' 'a-z')"
# (JSON built in a variable first: the bash 3.2 of macOS misreads \" inside $( ) inside " ")
BJ='{"do":"join","token":"'"$TF"'"}'; R2="$(post "$(U 2)" /admin/net "$BJ")"; ok=0; [ "$(echo "$R2" | js '$d->{ok} ? 1 : 0')" = 1 ] && ok=1
rec "$ok" "station 2 joins with it (typed with dashes, lower case)" "$(echo "$R2" | js '$d->{error}')"
BJ='{"do":"join","token":"'"$TOK"'"}'; R3="$(post "$(U 3)" /admin/net "$BJ")"; ok=0; [ -n "$(echo "$R3" | js '$d->{error}')" ] && ok=1
rec "$ok" "the same token cannot be used twice"
wait_for '[ "$(online 1)" = 2 ] && [ "$(online 2)" = 2 ] && [ "$(online 3)" = 1 ]' 60 && ok=1 || ok=0
rec "$ok" "private: stations 1 + 2 together, station 3 left out" "1 sees: $(sees 1)  ·  3 sees: $(sees 3)"
post "$(U 1)" /admin/net '{"do":"public"}' >/dev/null; post "$(U 2)" /admin/net '{"do":"public"}' >/dev/null
wait_for '[ "$(online 1)" = 3 ] && [ "$(online 3)" = 3 ]' 60 && ok=1 || ok=0
rec "$ok" "back to the public network: all 3 together again"

step "7. Simulation: a station nobody's search can see"
start_station 4 "127.0.0.1:8701,127.0.0.1:8704"    # 4 finds station 1; stations 1-3 never search for 4
t0=$(date +%s); wait_for '[ "$(online 1)" = 4 ] && [ "$(online 4)" -ge 2 ]' 90 && ok=1 || ok=0
rec "$ok" "station 1 learns it from its first contact" "$(( $(date +%s) - t0 )) s  ·  1 sees: $(sees 1)"
pkill -P "$P4" 2>/dev/null; kill "$P4" 2>/dev/null    # station 4 leaves again

step "8. Simulation: the main station goes away"
wait_for '[ "$(online 1)" = 3 ] && [ -n "$(mainof 1)" ] && [ "$(mainof 1)" = "$(mainof 2)" ] && [ "$(mainof 2)" = "$(mainof 3)" ]' 60
M="$(mainof 1)"; MI=""; for i in 1 2 3; do [ "$(get "$(U $i)" /sync/hello | js '$d->{id}')" = "$M" ] && MI=$i; done
if [ -n "$MI" ]; then
    eval "mp=\$P$MI"; pkill -P "$mp" 2>/dev/null; kill "$mp" 2>/dev/null; t0=$(date +%s)
    REST=""; for i in 1 2 3; do [ "$i" != "$MI" ] && REST="$REST $i"; done
    set -- $REST
    wait_for "n=\$(mainof $1); [ -n \"\$n\" ] && [ \"\$n\" != \"$M\" ] && [ \"\$n\" = \"\$(mainof $2)\" ]" 60 && ok=1 || ok=0
    rec "$ok" "the others elect a new main station (Test $MI was switched off)" "$(( $(date +%s) - t0 )) s"
else fail "the others elect a new main station" "could not tell which station was main"; fi
fi

out ""
WN=""; [ "$NWARN" != 0 ] && WN="  ${D}($NWARN warnings)${R}"
if [ "$NFAIL" = 0 ]; then out "${G}${B}All $NPASS checks passed${R}$WN"
else out "${RD}${B}$NFAIL of $((NPASS + NFAIL)) checks failed${R}$WN"; fi
cp "$WORK/report" "$REPORT" && out "${D}Report saved: $REPORT${R}"
