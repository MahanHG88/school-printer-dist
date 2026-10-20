#!/bin/bash
# School Printer - installer for the Mac or Linux computer the printer is connected to.
# https://print.mahanmirzaee.com
#
#   curl -fsSL https://print.mahanmirzaee.com/install.sh | sudo bash
#
# Offline: unzip SchoolPrinter-mac-linux.zip and run  sudo bash install.sh  in that folder.
# What it does (undo: curl -fsSL https://print.mahanmirzaee.com/uninstall.sh | sudo bash):
#   macOS: /Library/Application Support/SchoolPrinter + LaunchDaemon com.mahanmirzaee.schoolprinter
#   Linux: /opt/schoolprinter + systemd unit schoolprinter.service (+ ufw/firewalld rule, LAN only)
#   Both:  runs as user "nobody", port 8631, "School Printer (Admin)" shortcut on the desktop
# Works with the bash 3.2 that macOS ships (no associative arrays, no EPOCHREALTIME).
set -euo pipefail

VERSION="1.4.0"
BASE="https://print.mahanmirzaee.com/app"          # direct: print.mahanmirzaee.com  |  -ir: jsDelivr mirror (fast inside Iran)
PORT=8631
FILES=("unix/schoolprinter.pl:7F6051B7A0218A29AEE3F4CD934BE8BC6B47D4B70413068CE6AB82124E0B046D:22754" "web/admin.html:9916FC55C2003477400CE4777D28DEBE6AD4E2781F9EFAAADA9A25234932848F:3575" "web/admin.js:18D5A88D21E9140AD57C70DAF3E1D465BB70E8A9726F1BE67563CF75688F57A5:3804" "web/app.css:08E7A35572A53ED1C76EBCAC0BDA15E2912E4D4C52F3213DD1BC4EDFF7D9CD50:12608" "web/i18n.js:7D7D2147064473E6CE493848F7E95FC032D4A49BC4ACD3966D22207B33DFF928:11527" "web/pdf.min.js:978FD1B2D134A98E98966186A97777BEBF87D8E770DADAB1ECE3687E21A5AA6C:377116" "web/pdf.worker.min.js:38CDE5311957B86BC3669F93E7D2566DE333A90055ED6635BEF60D9BF00E96F2:1133660" "web/print.html:5031F5CD5B5CFCB098BDB34A5E0D68F0AC36E02A4B035E88B6D6F0F082068471:5318" "web/print.js:F86C682E2B293CA2C96FA441860FB970D7E6AE3A9DE1428379882C146DD393EE:19109")   # "path under /app/:SHA-256:bytes"  (filled in by build.sh)
OS="$(uname -s)"
if [ "$OS" = Darwin ]; then DIR="/Library/Application Support/SchoolPrinter"; else DIR="/opt/schoolprinter"; fi

# ================================================================ look: live dashboard
TTY=0; [ -t 1 ] && TTY=1
E=$'\e'; R="$E[0m"; B="$E[1m"; D="$E[2m"
OK="$E[38;5;42m"; WN="$E[38;5;214m"; ER="$E[38;5;203m"; AC="$E[38;5;105m"; MU="$E[38;5;244m"; BR="$E[38;5;60m"
GRAD=(63 63 99 99 135 135 171 171 207 205)          # brand gradient: indigo -> violet -> pink (256 colours)
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
kb() { local t w f g=""; t=$(( ($1 * 10 + 512) / 1024 )); w=$((t / 10)); f=$((t % 10))
       while (( w >= 1000 )); do g="$(printf ',%03d' $((w % 1000)))$g"; w=$((w / 1000)); done; echo "$w$g.$f KB"; }
kbps() { local ms=$2; (( ms < 1 )) && ms=1; local t=$(( $1 * 10000 / 1024 / ms )); echo "$((t / 10)).$((t % 10)) KB/s"; }   # bytes, ms
secs() { local ms=$1 s; s=$(( (ms + 999) / 1000 )); if (( ms < 1000 )); then echo "<1 s"; elif (( s < 90 )); then echo "$s s"; else printf '%dm %02ds' $((s / 60)) $((s % 60)); fi; }
tenths() { echo "$(($1 / 1000)).$(( ($1 % 1000) / 100 ))s"; }
grad() { local t="$1" i out=""; for (( i = 0; i < ${#t}; i++ )); do out+="$E[38;5;${GRAD[$(( i * ${#GRAD[@]} / ${#t} ))]}m${t:$i:1}"; done; printf '%s%s' "$out" "$R"; }

S_ID=(); S_TITLE=(); S_EST=(); S_STATE=(); S_DETAIL=(); S_T0=(); S_EL=(); S_FRAC=()
add_step() { S_ID+=("$1"); S_TITLE+=("$2"); S_EST+=("$3"); S_STATE+=(pending); S_DETAIL+=(""); S_T0+=(0); S_EL+=(0); S_FRAC+=(0); }
add_step check   "Check this computer"        500
add_step net     "Measure network speed"      1000
add_step files   "Download & verify files"    5000
add_step printer "Choose the printer"         1000
add_step service "Start the print service"    2500
add_step network "Open the local network"     1000
add_step extras  "Shortcut & Office files"    800
add_step verify  "Check it answers"           2000
ix() { local i; for (( i = 0; i < ${#S_ID[@]}; i++ )); do [ "${S_ID[$i]}" = "$1" ] && { echo $i; return; }; done; }
PLAN=("${MU}Network    ${R}${D}measuring...${R}" "${MU}Download   ${R}${D}-${R}" "${MU}Estimate   ${R}${D}-${R}")
T0=$(now_ms); DRAWN=0; LAST=0; FRAME=0

draw() {
    [ $TTY = 1 ] || return 0
    local now; now=$(now_ms)
    if [ -z "${1:-}" ] && (( now - LAST < 100 )); then return 0; fi
    LAST=$now; FRAME=$((FRAME + 1))
    local out="" n=0 i st el ic tm tc ti total=0 dn=0 rem=0 f p pct w=34 fill bar=""
    (( DRAWN > 0 )) && out+="$E[${DRAWN}A"
    for p in "${PLAN[@]}"; do out+=$'\r'"$E[2K   $p"$'\n'; n=$((n + 1)); done
    out+=$'\r'"$E[2K"$'\n'; n=$((n + 1))
    for (( i = 0; i < ${#S_ID[@]}; i++ )); do
        st=${S_STATE[$i]}
        if [ "$st" = active ]; then el=$((now - S_T0[i])); else el=${S_EL[$i]}; fi
        ti="$(printf '%-28s' "${S_TITLE[$i]}")"
        case $st in
            pending) ic="$MU·$R"; tm="~$(secs ${S_EST[$i]})"; tc=$MU; ti="$MU$ti$R" ;;
            active)  ic="$AC${SPIN[$((FRAME % 10))]}$R"; tm="$(tenths $el)"; tc=$AC; ti="$B$ti$R" ;;
            done)    ic="$OK✓$R"; tm="$(tenths $el)"; tc=$D ;;
            warn)    ic="$WN!$R"; tm="$(tenths $el)"; tc=$D ;;
            fail)    ic="$ER✗$R"; tm="$(tenths $el)"; tc=$D; ti="$ER$ti$R" ;;
        esac
        out+=$'\r'"$E[2K   $ic  $ti $tc$(printf '%7s' "$tm")$R   $D${S_DETAIL[$i]}$R"$'\n'; n=$((n + 1))
        total=$((total + S_EST[i]))
        case $st in
            done|warn) dn=$((dn + S_EST[i])) ;;
            active) f=${S_FRAC[$i]}; if (( f == 0 )); then f=$(( el * 1000 / (S_EST[i] > 0 ? S_EST[i] : 1) )); (( f > 950 )) && f=950; fi
                    dn=$((dn + S_EST[i] * f / 1000)); rem=$((rem + S_EST[i] * (1000 - f) / 1000)) ;;
            pending) rem=$((rem + S_EST[i])) ;;
        esac
    done
    out+=$'\r'"$E[2K"$'\n'; n=$((n + 1))
    pct=$(( dn * 100 / (total > 0 ? total : 1) )); (( pct > 100 )) && pct=100
    fill=$(( w * pct / 100 ))
    for (( i = 0; i < w; i++ )); do if (( i < fill )); then bar+="$E[38;5;${GRAD[$(( i * ${#GRAD[@]} / w ))]}m█"; else bar+="$E[38;5;237m░"; fi; done
    out+=$'\r'"$E[2K   $bar$R  $B$(printf '%3d' $pct)%$R   $D~$(secs $rem) left  ·  $(secs $((now - T0))) elapsed$R"$'\n'; n=$((n + 1))
    DRAWN=$n
    printf '%s' "$out"
}
begin()  { local i; i=$(ix "$1"); S_STATE[$i]=active; S_T0[$i]=$(now_ms); [ -n "${2:-}" ] && S_DETAIL[$i]="$2"; draw force; }
prog()   { local i; i=$(ix "$1"); S_FRAC[$i]=$2; [ -n "${3:-}" ] && S_DETAIL[$i]="$3"; draw; }
finish() {
    local i; i=$(ix "$1"); S_STATE[$i]=${3:-done}; S_EL[$i]=$(( $(now_ms) - S_T0[i] )); S_DETAIL[$i]="${2:-}"
    if [ $TTY = 1 ]; then draw force; else printf '  [%s] %s (%s) %s\n' "${S_STATE[$i]}" "${S_TITLE[$i]}" "$(tenths ${S_EL[$i]})" "${S_DETAIL[$i]}"; fi
}
fail() { finish "$1" "$2" fail; printf '\n   %s✗  %s%s\n' "$ER" "$2" "$R"; [ -n "${3:-}" ] && printf '      %s\n' "$3"; printf '\n'; exit 1; }
ask() {    # ask "question" line1 line2 ... -> answer on stdout; the lines disappear afterwards
    local q="$1" a k l; shift; k=$(( $# + 1 ))
    for l in "$@"; do printf '   %s\n' "$l" >&2; done
    printf '   %s?%s  %s ' "$AC" "$R" "$q" >&2; read -r a </dev/tty || a=""
    [ $TTY = 1 ] && printf '%s[%dA%s[J' "$E" "$k" "$E" >&2
    printf '%s' "$a"
}
header() {
    local w=62 h="" t1="School Printer" t1r="installer $VERSION" t2="$1  ·  print.mahanmirzaee.com" i
    for (( i = 0; i < w; i++ )); do h+="─"; done
    printf '\n  %s┌%s┐%s\n' "$BR" "$h" "$R"
    printf '  %s│%s  %s%s%s%*s%s%s%s  %s│%s\n' "$BR" "$R" "$B" "$(grad "$t1")" "$R" $(( w - 4 - ${#t1} - ${#t1r} )) "" "$D" "$t1r" "$R" "$BR" "$R"
    printf '  %s│%s  %s%-*s%s  %s│%s\n' "$BR" "$R" "$D" $(( w - 3 )) "$t2" "$R" "$BR" "$R"
    printf '  %s└%s┘%s\n\n' "$BR" "$h" "$R"
}

# ================================================================ start
HERE=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fi
if [ "$(id -u)" -ne 0 ]; then
    if [ -n "$HERE" ]; then echo "School Printer needs your password to install."; exec sudo bash "${BASH_SOURCE[0]}"; fi
    echo "Run it with sudo:  curl -fsSL https://print.mahanmirzaee.com/install.sh | sudo bash"; exit 1
fi
command -v perl >/dev/null || { echo "Perl is missing - install it (e.g. sudo apt install perl) and run this again."; exit 1; }
tmpd="$(mktemp -d)"
cleanup() { rm -rf "$tmpd"; [ $TTY = 1 ] && printf '%s[?25h' "$E"; return 0; }
trap cleanup EXIT
[ $TTY = 1 ] && printf '%s[?25l' "$E"
if [ "$OS" = Darwin ]; then header "macOS $(sw_vers -productVersion)  ·  print.mahanmirzaee.com"; else header "$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo Linux)  ·  print.mahanmirzaee.com"; fi
draw force

# ---------------------------------------------------------------- 1. check
begin check
[ "$OS" = Darwin ] || [ "$OS" = Linux ] || fail check "This installer is for macOS and Linux." "For Windows, see the Windows tab on https://print.mahanmirzaee.com"
command -v lp >/dev/null && command -v lpstat >/dev/null || fail check "The printing system (CUPS) is missing." "Install it (e.g. sudo apt install cups), add the printer, print a test page, then run this again."
free_mb=$(df -Pm / | awk 'NR==2{print $4}')
[ "$free_mb" -ge 20 ] || fail check "Not enough free space (need about 20 MB, have ${free_mb} MB)."
mkdir -p "$DIR/Uploads" "$DIR/web"
dest() { case "$1" in unix/*) echo "$DIR/${1#unix/}" ;; *) echo "$DIR/$1" ;; esac; }
sha() { local s; s="$(shasum -a 256 "$1" 2>/dev/null || sha256sum "$1")"; printf '%s' "${s%% *}" | tr a-f A-F; }
NEED=(); NEED_BYTES=0; ALL_BYTES=0
for entry in "${FILES[@]}"; do
    name="${entry%%:*}"; rest="${entry#*:}"; want="${rest%%:*}"; size="${rest##*:}"; ALL_BYTES=$((ALL_BYTES + size)); d="$(dest "$name")"
    if ! { [ -f "$d" ] && [ "$(sha "$d")" = "$want" ]; }; then NEED+=("$entry"); NEED_BYTES=$((NEED_BYTES + size)); fi
done
finish check "$(awk -v m="$free_mb" 'BEGIN{printf "%.1f GB free", m/1024}')  ·  $(perl -e 'printf "Perl %vd", $^V')  ·  CUPS ready"

# ---------------------------------------------------------------- 2. network speed + plan
LOCAL=""; [ -n "$HERE" ] && [ -d "$HERE/web" ] && LOCAL=1
NET_KBPS_T=0; LAT=0
begin net "downloading a 128 KB test file"
if [ -n "$LOCAL" ]; then finish net "offline install - using the files next to this script"
elif [ ${#NEED[@]} -eq 0 ]; then finish net "skipped - all files already up to date"
else
    m="$(curl -fsS -o /dev/null -w '%{size_download} %{time_starttransfer} %{time_total}' "$BASE/probe.bin?t=$RANDOM$RANDOM" 2>/dev/null)" \
        || fail net "Could not reach the download server (print.mahanmirzaee.com)." "Plan B: download SchoolPrinter-mac-linux.zip from print.mahanmirzaee.com on any device, copy it here, unzip, and run: sudo bash install.sh"
    read -r PB PST PTT <<< "$m"
    LAT=$(awk -v s="$PST" 'BEGIN{printf "%d", s*1000}'); XFER=$(awk -v a="$PST" -v b="$PTT" 'BEGIN{x=(b-a)*1000; if (x<1) x=1; printf "%d", x}')
    NET_KBPS_T=$(( PB * 10000 / 1024 / XFER ))     # tenths of KB/s
    finish net "$(kbps "$PB" "$XFER")  ·  ${LAT} ms latency  ·  measured with $(kb "$PB")"
fi
fi_=$(ix files)
if (( NET_KBPS_T > 0 )); then S_EST[$fi_]=$(( NEED_BYTES * 10000 / 1024 / NET_KBPS_T + ${#NEED[@]} * LAT + 300 ))
elif [ ${#NEED[@]} -gt 0 ]; then S_EST[$fi_]=500; else S_EST[$fi_]=200; fi
TOTAL_EST=0; for e in "${S_EST[@]}"; do TOTAL_EST=$((TOTAL_EST + e)); done
if (( NET_KBPS_T > 0 )); then netline="$B$((NET_KBPS_T / 10)).$((NET_KBPS_T % 10)) KB/s$R  $D·  ${LAT} ms latency$R"; elif [ -n "$LOCAL" ]; then netline="${D}offline (zip)$R"; else netline="${D}not needed$R"; fi
PLAN=("${MU}Network    $R$netline" "${MU}Download   $R$B$(kb $NEED_BYTES)$R$D  in ${#NEED[@]} of ${#FILES[@]} files  ·  $(kb $ALL_BYTES) in total$R" "${MU}Estimate   $R$B~$(secs $TOTAL_EST)$R$D  for all ${#S_ID[@]} steps$R")
draw force

# ---------------------------------------------------------------- 3. files
begin files
GOT=0; DL0=$(now_ms)
for entry in "${NEED[@]:-}"; do
    [ -n "$entry" ] || continue
    name="${entry%%:*}"; rest="${entry#*:}"; want="${rest%%:*}"; size="${rest##*:}"; short="${name##*/}"
    if [ -n "$LOCAL" ]; then cp "$HERE/$name" "$tmpd/$short"
    else
        curl -fsSL --retry 2 -o "$tmpd/$short" "$BASE/$name" & pid=$!
        while kill -0 $pid 2>/dev/null; do
            cur=$(( GOT + $(wc -c < "$tmpd/$short" 2>/dev/null || echo 0) )); el=$(( $(now_ms) - DL0 )); (( el < 50 )) && el=50
            left=$(( (NEED_BYTES - cur) * el / (cur > 0 ? cur : 1) ))
            prog files $(( cur * 1000 / (NEED_BYTES > 0 ? NEED_BYTES : 1) )) "$(kb $cur) / $(kb $NEED_BYTES)  ·  $(kbps $cur $el)  ·  ~$(secs $left) left  ·  $short"
            sleep 0.1
        done
        wait $pid || fail files "Could not download $short." "Plan B: download SchoolPrinter-mac-linux.zip from print.mahanmirzaee.com on any device, copy it here, unzip, and run: sudo bash install.sh"
    fi
    GOT=$((GOT + size))
    [ "$(sha "$tmpd/$short")" = "$want" ] || fail files "$short failed its safety check (fingerprint does not match)." "Nothing was installed."
done
if [ "$OS" = Darwin ]; then launchctl bootout system /Library/LaunchDaemons/com.mahanmirzaee.schoolprinter.plist 2>/dev/null || true
else systemctl stop schoolprinter 2>/dev/null || true; fi
for entry in "${NEED[@]:-}"; do [ -n "$entry" ] || continue; name="${entry%%:*}"; install -m 644 "$tmpd/${name##*/}" "$(dest "$name")"; done
rm -rf "$DIR/Inbox" "$DIR/print.html" "$DIR/admin.html"     # from version 1.2
[ "$OS" = Darwin ] && xattr -cr "$DIR" 2>/dev/null || true
if [ ${#NEED[@]} -gt 0 ]; then finish files "${#NEED[@]} files  ·  $(kb $NEED_BYTES)  ·  $(kbps $NEED_BYTES $(( $(now_ms) - DL0 ))) average  ·  SHA-256 verified"
else finish files "already up to date"; fi

# ---------------------------------------------------------------- 4. printer
begin printer
cfg="$DIR/config.txt"
getv() { [ -f "$cfg" ] && sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$cfg" | head -1 || true; }
printer="$(getv printer)"; pin="$(getv pin)"; open="$(getv open)"; lang="$(getv lang)"; kept=""
: "${open:=1}"; : "${lang:=fa}"
list=(); while IFS= read -r line; do [ -n "$line" ] && list+=("$line"); done < <(lpstat -e 2>/dev/null || true)
if [ -n "$printer" ] && printf '%s\n' "${list[@]:-}" | grep -qxF "$printer"; then kept="  (kept)"
elif [ "${#list[@]}" -eq 0 ]; then fail printer "No printers are set up on this computer." "Add the printer in the system settings, print a test page, then run this again."
elif [ "${#list[@]}" -eq 1 ]; then printer="${list[0]}"
else
    def="$(lpstat -d 2>/dev/null | sed -n 's/^.*: //p')"; lines=("${B}Which printer should everyone use?${R}")
    for i in "${!list[@]}"; do m=""; [ "${list[$i]}" = "$def" ] && m="  ${D}(default)${R}"; lines+=("   $AC$((i + 1))$R  ${list[$i]}$m"); done
    while :; do
        a="$(ask "Number:" "${lines[@]}")"
        if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#list[@]}" ]; then printer="${list[$((a - 1))]}"; break; fi
    done
fi
printf '# School Printer settings (also changeable on the admin page)\nprinter=%s\npin=%s\nopen=%s\nlang=%s\n' "$printer" "$pin" "$open" "$lang" > "$cfg"
chown -R nobody "$DIR/Uploads" "$cfg"; chown nobody "$DIR"; [ -f "$DIR/log.txt" ] && chown nobody "$DIR/log.txt"
finish printer "$printer$kept"

# ---------------------------------------------------------------- 5. service
begin service
if [ "$OS" = Darwin ]; then
    plist=/Library/LaunchDaemons/com.mahanmirzaee.schoolprinter.plist
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.mahanmirzaee.schoolprinter</string>
  <key>ProgramArguments</key><array><string>/usr/bin/perl</string><string>$DIR/schoolprinter.pl</string></array>
  <key>UserName</key><string>nobody</string>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>
  <key>StandardErrorPath</key><string>/tmp/schoolprinter.log</string>
</dict></plist>
EOF
    chmod 644 "$plist"; chown root:wheel "$plist"
    launchctl bootstrap system "$plist"; launchctl enable system/com.mahanmirzaee.schoolprinter
    finish service "LaunchDaemon com.mahanmirzaee.schoolprinter  -  starts with the Mac, restarts itself"
else
    cat > /etc/systemd/system/schoolprinter.service <<EOF
[Unit]
Description=School Printer (print.mahanmirzaee.com)
After=network-online.target cups.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/env perl $DIR/schoolprinter.pl
User=nobody
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable --now schoolprinter >/dev/null 2>&1
    finish service "systemd unit schoolprinter.service  -  starts with the computer, restarts itself"
fi

# ---------------------------------------------------------------- 6. network
begin network
if [ "$OS" = Linux ]; then
    net="$(ip -4 route 2>/dev/null | awk '/proto kernel/ && /scope link/ && $1 !~ /^(172\.17\.|169\.254\.)/ {print $1; exit}')"
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow from "${net:-192.168.0.0/16}" to any port $PORT proto tcp comment 'School Printer' >/dev/null
        finish network "ufw: port $PORT from ${net:-the local network} only"
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${net:-192.168.0.0/16} port port=$PORT protocol=tcp accept" >/dev/null
        firewall-cmd --reload >/dev/null; finish network "firewalld: port $PORT from ${net:-the local network} only"
    else finish network "no firewall active - port $PORT reachable on the local network"; fi
else
    finish network "port $PORT  -  macOS allows its built-in Perl automatically"
fi

# ---------------------------------------------------------------- 7. shortcut, Office, sleep
begin extras
if [ "$OS" = Darwin ]; then u="$(stat -f %Su /dev/console 2>/dev/null || true)"; else u="${SUDO_USER:-$(logname 2>/dev/null || true)}"; fi
notes=()
if [ -n "$u" ] && [ "$u" != root ] && [ "$u" != loginwindow ]; then
    home="$(eval echo "~$u")"
    if [ -d "$home/Desktop" ]; then
        if [ "$OS" = Darwin ]; then
            printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>URL</key><string>http://localhost:%s/admin</string></dict></plist>\n' $PORT > "$home/Desktop/School Printer (Admin).webloc"
            chown "$u" "$home/Desktop/School Printer (Admin).webloc"
        else
            f="$home/Desktop/school-printer-admin.desktop"
            printf '[Desktop Entry]\nType=Link\nName=School Printer (Admin)\nIcon=printer\nURL=http://localhost:%s/admin\n' $PORT > "$f"; chown "$u" "$f"; chmod 755 "$f"
        fi
        notes+=("desktop shortcut")
    fi
fi
state=done
if command -v soffice >/dev/null || command -v libreoffice >/dev/null || [ -x /Applications/LibreOffice.app/Contents/MacOS/soffice ]; then notes+=("Word/Excel/PowerPoint via LibreOffice")
else notes+=("Word/Excel/PowerPoint need LibreOffice (PDF, photos, text work now)"); state=warn; fi
if [ "$OS" = Darwin ] && [ "$(pmset -g custom 2>/dev/null | awk '/AC Power/{f=1} f&&$1=="sleep"{print $2; exit}')" != "0" ]; then
    a="$(ask "Keep this Mac awake while it's plugged in, so printing always works? [Y/n]")"
    if [[ ! "$a" =~ ^[nN] ]]; then pmset -c sleep 0; notes+=("Mac stays awake on power"); fi
fi
joined=""; for nt in "${notes[@]}"; do joined="${joined:+$joined  ·  }$nt"; done
finish extras "$joined" $state

# ---------------------------------------------------------------- 8. verify
begin verify
up=""; vms=0
for _ in $(seq 1 30); do
    t1=$(now_ms); if curl -fs -m 2 "http://127.0.0.1:$PORT/status" >/dev/null; then vms=$(( $(now_ms) - t1 )); up=1; break; fi
    draw; sleep 0.5
done
[ -n "$up" ] || fail verify "Installed, but the web page did not answer yet." "Restart the computer; if it still does not open, run the installer again."
finish verify "answered in ${vms} ms"

# ---------------------------------------------------------------- summary
TOOK=$(( $(now_ms) - T0 ))
if [ "$OS" = Darwin ]; then ips=$(for i in 0 1 2 3 4 5 6 7 8; do ipconfig getifaddr en$i 2>/dev/null || true; done)
else ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '$2 !~ /^(docker|br-|veth|virbr)/ {sub(/\/.*/,"",$4); print $4}'); fi
printf '\n   %s✓%s  %s%s%s   %s%s  (estimated ~%s)%s\n\n' "$OK" "$R" "$B" "$(grad 'School Printer is running')" "$R" "$D" "$(tenths $TOOK)" "$(secs $TOTAL_EST)" "$R"
printf '   %sOn every other device%s, type this in the browser:\n' "$B" "$R"
for ip in $ips; do printf '      %s\n' "$(grad "http://$ip:$PORT")"; done
printf '\n   %sOn this computer%s: double-click %s"School Printer (Admin)"%s on the desktop.\n\n' "$B" "$R" "$B" "$R"
if [ "$OS" = Darwin ] && [ -n "${u:-}" ] && [ "$u" != root ]; then launchctl asuser "$(id -u "$u")" sudo -u "$u" open "http://localhost:$PORT/admin" 2>/dev/null || true; fi
