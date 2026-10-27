#!/bin/bash
# office-mac.sh - School Printer on a Mac: turns Word / Excel / PowerPoint files into PDF with Microsoft Office.
# Runs in the signed-in user's session (LaunchAgent com.mahanmirzaee.schoolprinter.office), because Office cannot be
# driven by the service itself (it runs as "nobody", outside any session). Same idea as convert.ps1 on Windows.
# Protocol (folder Office/): the service writes <id>.<ext> + <id>.todo (= the extension); this claims it (-> <id>.doing)
# and writes <id>.pdf or <id>.fail. office.alive says this helper is running and which Office apps it has.
# Office apps are sandboxed: files are opened and saved inside Office's own shared folder (no "Grant access" dialogs).
# The first conversion with each app shows "... wants to control Microsoft Word": click OK (once per app).
X="${1:-/Library/Application Support/SchoolPrinter/Office}"
GC="$HOME/Library/Group Containers/UBF8T346G9.Office"    # shared by Word, Excel and PowerPoint
W="$GC/SchoolPrinter"

apps() { local a=""; for n in Word Excel PowerPoint; do [ -d "/Applications/Microsoft $n.app" ] && a="$a${a:+,}$n"; done; echo "$a"; }
APPS="$(apps)"
if [ -z "$APPS" ] || [ ! -d "$X" ]; then sleep 600; exit 0; fi    # no Microsoft Office (yet): launchd starts this again later

script_for() {    # app -> AppleScript (arguments: in, out) that opens the file, saves it as PDF and closes it
    case "$1" in
    Word) cat <<'EOF'
on run argv
    tell application "Microsoft Word"
        open (POSIX file (item 1 of argv))
        set d to active document
        save as d file name ((POSIX file (item 2 of argv)) as text) file format format PDF
        close d saving no
    end tell
end run
EOF
    ;;
    Excel) cat <<'EOF'
on run argv
    tell application "Microsoft Excel"
        set display alerts to false
        open (POSIX file (item 1 of argv))
        set wb to active workbook
        save workbook as wb filename ((POSIX file (item 2 of argv)) as text) file format PDF file format
        close wb saving no
    end tell
end run
EOF
    ;;
    PowerPoint) cat <<'EOF'
on run argv
    tell application "Microsoft PowerPoint"
        open (POSIX file (item 1 of argv))
        set p to active presentation
        save p in ((POSIX file (item 2 of argv)) as text) as save as PDF
        close p
    end tell
end run
EOF
    ;;
    esac
}

convert_one() {    # id ext
    local id="$1" ext="$2" app="" in out was pid n err
    case "$ext" in doc|docx|rtf|odt|txt) app=Word;; xls|xlsx|csv|ods) app=Excel;; ppt|pptx|odp) app=PowerPoint;; esac
    if [ -z "$app" ] || [ ! -d "/Applications/Microsoft $app.app" ]; then echo "Microsoft $app is not installed." > "$X/$id.fail"; return; fi
    if [ ! -d "$GC" ]; then open -g -a "Microsoft $app"; n=0; while [ ! -d "$GC" ] && [ $n -lt 30 ]; do sleep 1; n=$((n + 1)); done; fi
    mkdir -p "$W"; in="$W/$id.$ext"; out="$W/$id.pdf"; rm -f "$out"
    if ! cp "$X/$id.$ext" "$in"; then echo "Could not read the file." > "$X/$id.fail"; return; fi
    was="$(osascript -e "application \"Microsoft $app\" is running" 2>/dev/null)"
    script_for "$app" > "$W/$id.scpt.txt"
    osascript "$W/$id.scpt.txt" "$in" "$out" > "$W/$id.err" 2>&1 & pid=$!
    n=0; while kill -0 "$pid" 2>/dev/null && [ $n -lt 240 ]; do sleep 0.5; n=$((n + 1)); done    # 2 minutes at most
    kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
    err="$(cat "$W/$id.err" 2>/dev/null)"
    if [ -s "$out" ] && [ "$(head -c 4 "$out")" = "%PDF" ]; then cp "$out" "$X/$id.pdf.part" && chmod 644 "$X/$id.pdf.part" && mv -f "$X/$id.pdf.part" "$X/$id.pdf"
    else
        case "$err" in
            *-1743*) echo "macOS did not allow School Printer to use Microsoft $app. Open System Settings > Privacy & Security > Automation and allow it." > "$X/$id.fail";;
            *) echo "Microsoft $app could not convert this file. ${err:0:200}" > "$X/$id.fail";;
        esac
    fi
    [ "$was" = "false" ] && osascript -e "tell application \"Microsoft $app\" to quit saving no" >/dev/null 2>&1    # it was not open before: close it again
    rm -f "$in" "$out" "$W/$id.scpt.txt" "$W/$id.err"
}

n=0
while true; do
    printf 'user=%s\napps=%s\n' "$(id -un)" "$APPS" > "$X/office.alive.$$" 2>/dev/null && mv -f "$X/office.alive.$$" "$X/office.alive" 2>/dev/null
    for t in "$X"/*.todo; do
        [ -e "$t" ] || continue
        id="$(basename "$t" .todo)"
        case "$id" in *[!0-9a-f]*|"") continue;; esac
        mv "$t" "$X/$id.doing" 2>/dev/null || continue    # another signed-in user's helper took it
        convert_one "$id" "$(tr -cd 'a-z' < "$X/$id.doing")"
        rm -f "$X/$id.doing"
    done
    n=$((n + 1)); [ $((n % 120)) = 0 ] && APPS="$(apps)"    # Office installed or removed meanwhile
    sleep 1
done
