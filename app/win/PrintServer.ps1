# PrintServer.ps1 - School Printer web server for Windows (https://print.mahanmirzaee.com)
#   Everyone on the network:  http://<this PC>:8631  (and port 80 when it is free)   upload, preview, print, scan
#   On this PC only:          http://localhost:8631/admin  (desktop shortcut "School Printer (Admin)")
# Flow: POST /upload -> Uploads\<id>.<ext> (+ <id>.todo for Office files, converted by convert.ps1 in the signed-in
# user's session, or <id>.remote: converted on the station with the most free power) -> GET /file/<id> for the
# preview -> POST /print {id, settings, target} -> Inbox\ job that watch.ps1 prints, or Outbox\ job that syncd.ps1
# sends to another station. Runs as SYSTEM from the task "MacPrint Web". PowerShell 5.1, nothing to install.
# The printing network (several stations, one address, scanners): see sync.ps1 and syncd.ps1.

$root    = if ($env:SP_ROOT) { $env:SP_ROOT } else { 'C:\ProgramData\MacPrint' }   # SP_ROOT / SP_PORT: test copies only
$inbox   = Join-Path $root 'Inbox'
$up      = Join-Path $root 'Uploads'
$web     = Join-Path $root 'web'
$port    = if ($env:SP_PORT) { [int]$env:SP_PORT } else { 8631 }
$maxMB   = 50
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'sync.ps1')

$BaseTypes   = @('pdf', 'jpg', 'jpeg', 'png', 'gif', 'bmp', 'tif', 'tiff')
$OfficeTypes = @('doc', 'docx', 'rtf', 'odt', 'txt', 'xls', 'xlsx', 'csv', 'ods', 'ppt', 'pptx', 'odp')
$Mime = @{ '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'
           '.pdf' = 'application/pdf'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'; '.woff2' = 'font/woff2' }

function Get-Cfg { Sp-Cfg }
function Get-Caps($printer) { Sp-Caps $printer }
function Waiting { Sp-Waiting }

function Send($res, $code, $type, [byte[]]$b, $cache) {
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.Headers.Add('Cache-Control', $(if ($cache) { 'max-age=86400' } else { 'no-store' }))
    $res.Headers.Add('X-Content-Type-Options', 'nosniff')
    $res.ContentLength64 = $b.Length
    $res.OutputStream.Write($b, 0, $b.Length)
    $res.OutputStream.Close()
}
function Json($res, $code, $obj) { Send $res $code 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -Depth 8 -InputObject $obj))) }
function SendFile($res, $path, $cache) {
    $ext = [IO.Path]::GetExtension($path).ToLower()
    $type = if ($Mime[$ext]) { $Mime[$ext] } else { 'application/octet-stream' }
    Send $res 200 $type ([IO.File]::ReadAllBytes($path)) $cache
}
function Redirect($res, $url) { $res.StatusCode = 302; $res.RedirectLocation = $url; $res.Headers.Add('Cache-Control', 'no-store'); $res.ContentLength64 = 0; $res.OutputStream.Close() }

# ---- Word/Excel/PowerPoint here, or on another station (peer)
function Get-Office { $o = Sp-LocalOffice; if ($o -notin 'office', 'lo' -and @(Sp-ConvPeers (Get-Cfg)).Count) { 'peer' } else { $o } }
function Get-Types($office) { if ($office -in 'office', 'lo', 'peer') { $BaseTypes + $OfficeTypes } else { $BaseTypes } }
function Net-Caps($c) {    # this printer's paper sizes; colour / two-sided when any connected printer has them (the job goes there)
    $caps = (Get-Caps $c.printer).Clone()
    if (Sp-Group) { foreach ($x in @(Sp-Stations | Where-Object { $_.online -and $_.s.ready })) { if ($x.s.color) { $caps.color = $true }; if ($x.s.duplex) { $caps.duplex = $true } } }
    $caps
}

function Get-Info {
    $c = Get-Cfg
    $urls = @(Sp-LanIPs | ForEach-Object { "http://$($_.IPAddress):$port" })
    if (Sp-Group) { $l = Sp-Leader; if ($l.id -ne (Sp-NodeId)) { $urls = @([string]$l.url) }; $urls = @("http://$($SpAlias):$port") + $urls; if ($c.domain) { $urls = @("http://$($c.domain)") + $urls } }
    $pr = if ($c.printer) { Get-Printer -Name $c.printer -EA SilentlyContinue } else { $null }
    $pstat = 'Not found'
    if ($pr) { $pstat = "$($pr.PrinterStatus)"; if ($pr.WorkOffline) { $pstat = 'Offline' } }
    $log = @()
    if (Test-Path $SpLog) { $log = @(Get-Content $SpLog -Tail 15 -Encoding UTF8 | ForEach-Object { [string]$_ }); [array]::Reverse($log) }
    $net = Sp-NetInfo $c; $net.domain = [string]$c.domain; $net.dns = ($c.dns -ne '0'); $net.dnsState = Dns-State
    @{ urls = $urls; name = "http://$($env:COMPUTERNAME):$port"; open = ($c.open -ne '0'); lang = $c.lang; pin = $c.pin; printer = $c.printer
       printers = @(Sp-RealPrinters); pstatus = $pstat; waiting = (Waiting)
       jobs = @(if ($c.printer) { Get-PrintJob -PrinterName $c.printer -EA SilentlyContinue }).Count; log = $log; office = (Get-Office); net = $net }
}
function Dns-State { $s = Sp-Read (Join-Path $SpSync 'dns.json'); if ($s -and ((Sp-Now) - [int64]$s.at) -lt 30) { [string]$s.state } else { 'off' } }

# ---- file checks: the extension must match the file's real first bytes
function Test-Magic($path, $ext) {
    $fs = [IO.File]::OpenRead($path); $buf = New-Object byte[] 4096; $n = $fs.Read($buf, 0, 4096); $fs.Close()
    if ($n -lt 4) { return $false }
    $h = [Text.Encoding]::ASCII.GetString($buf, 0, [math]::Min($n, 8))
    switch -regex ($ext) {
        '^pdf$'                          { return $h.StartsWith('%PDF') }
        '^jpe?g$'                        { return $buf[0] -eq 0xFF -and $buf[1] -eq 0xD8 }
        '^png$'                          { return $buf[0] -eq 0x89 -and $h.Substring(1, 3) -eq 'PNG' }
        '^gif$'                          { return $h.StartsWith('GIF8') }
        '^bmp$'                          { return $h.StartsWith('BM') }
        '^tiff?$'                        { return $h.StartsWith("II*`0") -or $h.StartsWith("MM`0*") }
        '^(docx|xlsx|pptx|odt|ods|odp)$' { return $buf[0] -eq 0x50 -and $buf[1] -eq 0x4B -and $buf[2] -eq 3 -and $buf[3] -eq 4 }
        '^(doc|xls|ppt)$'                { return $buf[0] -eq 0xD0 -and $buf[1] -eq 0xCF -and $buf[2] -eq 0x11 -and $buf[3] -eq 0xE0 }
        '^rtf$'                          { return $h.StartsWith('{\rtf') }
        '^(txt|csv)$'                    { for ($i = 0; $i -lt $n; $i++) { if ($buf[$i] -eq 0) { return $false } }; return $true }
    }
    $false
}
function Sniff($path) {    # no usable file name: accept PDF / PNG / JPEG by content
    foreach ($e in 'pdf', 'png', 'jpg') { if (Test-Magic $path $e) { return $e } }
    ''
}
function Read-Meta($id) {
    if ($id -notmatch '^[a-f0-9]{32}$') { return $null }
    $f = Join-Path $up "$id.meta"
    if (-not (Test-Path $f)) { return $null }
    [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
}
function Get-State($id, $meta) {
    if ($meta.kind -eq 'image') { return 'ready' }
    if (Test-Path (Join-Path $up "$id.pdf")) { return 'ready' }
    if (Test-Path (Join-Path $up "$id.fail")) { return 'failed' }
    if (((Get-Date) - [datetime]$meta.created).TotalSeconds -gt 180) { return 'failed' }
    'converting'
}
function Clean-Uploads {
    Get-ChildItem $up -File -EA SilentlyContinue | Where-Object { $_.Name -ne 'converter.alive' -and $_.LastWriteTime -lt (Get-Date).AddMinutes(-60) } |
        Remove-Item -Force -EA SilentlyContinue
}
function Read-Body($req) { (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() }
function Save-Body($req, $path) {    # request body -> file; $false when bigger than 50 MB
    $fs = [IO.File]::Create($path); $buf = New-Object byte[] 65536; $total = 0; $ok = $true
    while (($n = $req.InputStream.Read($buf, 0, $buf.Length)) -gt 0) { $total += $n; if ($total -gt $maxMB * 1MB) { $ok = $false; break }; $fs.Write($buf, 0, $n) }
    $fs.Close(); if (-not $ok) { Remove-Item $path -Force -EA SilentlyContinue }
    $ok
}

$sets = @{ orientation = 'auto', 'portrait', 'landscape'; color = 'color', 'gray'; duplex = 'off', 'long', 'short'
           margins = 'none', 'narrow', 'normal', 'wide'; scale = 'fit', 'actual' }
function Norm-Job($j, $caps) {    # settings from the print page or another station -> clean settings, or $null
    $copies = 1; [void][int]::TryParse([string]$j.copies, [ref]$copies); $copies = [Math]::Min([Math]::Max($copies, 1), 20)
    $nup = 1; [void][int]::TryParse([string]$j.nup, [ref]$nup)
    foreach ($k in $sets.Keys) { if ([string]$j.$k -notin $sets[$k]) { return $null } }
    if ($nup -notin 1, 2, 4 -or [string]$j.pages -notmatch '^[0-9,\-\s]{0,200}$') { return $null }
    $paper = [string]$j.paper; $p = $caps.papers | Where-Object { $_.n -eq $paper } | Select-Object -First 1
    if (-not $p -and [string]$j.pw -match '^[\d.]+$' -and [string]$j.ph -match '^[\d.]+$') {    # another station's paper name: match by size
        $a = [math]::Min([double]$j.pw, [double]$j.ph); $b = [math]::Max([double]$j.pw, [double]$j.ph)
        $p = $caps.papers | Where-Object { [math]::Abs($_.w - $a) -lt 2 -and [math]::Abs($_.h - $b) -lt 2 } | Select-Object -First 1
    }
    $sheets = 0; [void][int]::TryParse([string]$j.sheets, [ref]$sheets); if ($sheets -lt 1) { $sheets = $copies }
    @{ copies = $copies; pages = [string]$j.pages; paper = $(if ($p) { $p.n } else { $caps.def }); pw = $(if ($p) { $p.w } else { '' }); ph = $(if ($p) { $p.h } else { '' })
       orientation = [string]$j.orientation; color = $(if ($caps.color) { [string]$j.color } else { 'gray' }); duplex = $(if ($caps.duplex) { [string]$j.duplex } else { 'off' })
       margins = [string]$j.margins; scale = [string]$j.scale; nup = $nup; land = [bool]$j.land; sheets = [math]::Min($sheets, 5000) }
}
function Add-Job([string]$src, [string]$ext, [string]$base, $job, $x, [bool]$picked) {    # document + settings -> Inbox (print here) or Outbox (send to $x)
    $dir = $inbox; $pre = ''
    if ($x) { $dir = $SpOut; $pre = "$($x.id)~"; $job.picked = $picked; $job.first = (Sp-Now) }
    $job.file = "$pre$base$ext"
    Move-Item -LiteralPath $src -Destination (Join-Path $dir "$pre$base$ext") -Force
    [IO.File]::WriteAllText((Join-Path $dir "$pre$base.tmp"), (ConvertTo-Json -Compress -InputObject $job), [Text.Encoding]::UTF8)
    Move-Item (Join-Path $dir "$pre$base.tmp") (Join-Path $dir "$pre$base.json") -Force
}
function Spool-Count($c) { @(if ($c.printer) { Get-PrintJob -PrinterName $c.printer -EA SilentlyContinue }).Count }

New-Item -ItemType Directory -Path $inbox, $up -Force | Out-Null
$pages = @{}
foreach ($p in 'print', 'admin') {
    $f = Join-Path $web "$p.html"
    $pages[$p] = if (Test-Path $f) { [IO.File]::ReadAllBytes($f) } else { [Text.Encoding]::UTF8.GetBytes("missing $f - run the installer again") }
}
$probe = New-Object byte[] 1048576; (New-Object Random 7).NextBytes($probe)     # 1 MB for the other stations' speed test

# port 8631 always; port 80 too when nothing else uses it, so "http://<school address>" works without :8631
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$port/")
if (-not $env:SP_PORT) { $listener.Prefixes.Add('http://+:80/') }
try { $listener.Start() } catch { $listener = New-Object System.Net.HttpListener; $listener.Prefixes.Add("http://+:$port/"); $listener.Start() }

. (Join-Path $PSScriptRoot 'ipp.ps1')                     # "Add to this device": the printer as a real IPP printer
$c0 = Get-Cfg; if (-not $env:SP_NOMDNS) { [void](Ipp-Announce $c0 (Get-Caps $c0.printer) $port) } else { $script:IppUuid = [guid]::NewGuid().ToString() }

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request; $res = $ctx.Response
    try {
        $path = $req.Url.AbsolutePath.TrimEnd('/'); if (-not $path) { $path = '/' }
        $m = $req.HttpMethod

        # ------------------------------------------------ static files (page styles + scripts + pdf.js)
        if ($m -eq 'GET' -and $path -match '^/assets/([a-z0-9.-]+\.(css|js|woff2))$') {
            $name = $Matches[1]; $f = Join-Path $web $name
            if (Test-Path $f) { SendFile $res $f ($name -like 'pdf*' -or $name -like '*.woff2') } else { Json $res 404 @{ error = 'Not found' } }
            continue
        }

        if ($m -eq 'GET' -and $path -eq '/add-printer.cmd') {    # "Add to this device" on Windows
            $res.Headers.Add('Content-Disposition', 'attachment; filename="Add School Printer.cmd"')
            Send $res 200 'application/octet-stream' ([Text.Encoding]::ASCII.GetBytes((Ipp-AddCmd $req.Url.Authority))); continue
        }
        if ($m -eq 'GET' -and $path -eq '/add.sh') {    # "Add to this device" on macOS / Linux
            $sh = (Ipp-AddScript $req.Url.Authority) -replace "`r`n", "`n"     # not inside GetBytes( ): there ',' splits arguments
            Send $res 200 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($sh)); continue
        }

        # ------------------------------------------------ IPP printer (devices that added "School Printer")
        if ($m -eq 'POST' -and ($path -eq '/ipp/print' -or $path -like '/ipp/print/*')) {
            $c = Get-Cfg; Ipp-Handle $ctx $c (Net-Caps $c); continue
        }

        # ------------------------------------------------ printing network
        if ($m -eq 'GET' -and $path -eq '/sync/hello') {    # public: lets other stations find this one (gid says which network)
            $c = Get-Cfg; $g = Sp-Group; $i = Sp-Identity; $id = Sp-NodeId
            Json $res 200 ([ordered]@{ app = 'school-printer'; proto = 2; id = $id; station = (Sp-StationName $c); gid = $(if ($g) { [string]$g.gid } else { '' }); net = $(if ($g) { $g.mode } else { 'alone' })
                                       pk = [string]$i.pk; pkmac = $(if ($g) { Sp-PkMac $g $id ([string]$i.pk) } else { '' }) }); continue
        }
        if ($m -eq 'POST' -and $path -eq '/sync/join') {    # joining a private network: the token proves itself, no signature
            $q = $null; if ($req.ContentLength64 -le 4096) { try { $q = (Read-Body $req) | ConvertFrom-Json } catch {} }
            if (-not $q) { Json $res 400 @{ error = 'BAD' }; continue }
            $a = Sp-JoinAnswer $q; Json $res $a.code $a.body; continue
        }
        if ($path -like '/sync/*') {    # another station: encrypted and sealed both ways (always POST)
            if ($m -ne 'POST') { Json $res 405 @{ error = 'POST' }; continue }
            if ($req.ContentLength64 -gt $maxMB * 1MB + 65536) { Json $res 413 @{ error = 'File is bigger than 50 MB.' }; continue }
            $ms = New-Object IO.MemoryStream; $req.InputStream.CopyTo($ms); $body = $ms.ToArray(); $ms.Dispose()
            $x = $null; try { $x = Sp-Open $req $body } catch {}
            if (-not $x) { Json $res 401 @{ error = 'SIGNATURE'; time = (Sp-Now) }; continue }
            $from = $x.from; $mt = $x.meta; $pl = $x.payload
            # a station that knows us but we do not know it (its announce got lost): look again now, not in a minute
            $sn = Join-Path $SpSync 'scan-now'
            if (-not (Test-Path $sn) -and -not (Sp-Peers | Where-Object { $_.id -eq $from })) { [IO.File]::WriteAllText($sn, '') }
            if ($path -eq '/sync/announce') { Sp-SJson $res $x 200 @{ ok = $true }; continue }
            if ($path -eq '/sync/status') {
                $f = Join-Path $SpSync 'self.json'
                if (Test-Path $f) { Sp-SReply $res $x 200 ([IO.File]::ReadAllBytes($f)) } else { Sp-SJson $res $x 503 @{ error = 'STARTING' } }
                continue
            }
            if ($path -eq '/sync/probe') { Sp-SReply $res $x 200 $probe; continue }
            if ($path -eq '/sync/job') {
                $c = Get-Cfg
                if ($c.accept -eq '0' -or $c.open -eq '0') { Sp-SJson $res $x 403 @{ error = 'NOT_ACCEPTING' }; continue }
                $ext = if ($mt) { [string]$mt.ext } else { '' }
                if ($ext -notin 'pdf', 'png', 'jpg', 'gif') { Sp-SJson $res $x 415 @{ error = "This type of file can't be printed." }; continue }
                $s = Norm-Job $mt (Get-Caps $c.printer); if (-not $s) { Sp-SJson $res $x 400 @{ error = 'Bad settings.' }; continue }
                $tmp = Join-Path $up ((Sp-Rand 16) + '.part'); [IO.File]::WriteAllBytes($tmp, $pl)
                if (-not (Test-Magic $tmp $ext)) { Remove-Item $tmp -Force; Sp-SJson $res $x 415 @{ error = "This type of file can't be printed." }; continue }
                $sx = Sp-Stations | Where-Object { $_.id -eq $from } | Select-Object -First 1
                $via = (([string]$(if ($sx) { $sx.station } else { 'station' })) -replace '[^A-Za-z0-9_]+', '_'); if ($via.Length -gt 24) { $via = $via.Substring(0, 24) }
                $src = ([string]$mt.from) -replace '[^0-9A-Fa-f.]', '_'
                $base = '{0}-{1}-from{2}-via{3}-c{4}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), (Get-Random -Maximum 99999), $src, $via, $s.copies
                $jid = Sp-Rand 8; $caps = Get-Caps $c.printer
                $job = @{ name = ([string]$mt.name -replace '[\x00-\x1f]', ''); copies = $s.copies; pages = $s.pages; paper = $s.paper; orientation = $s.orientation; color = $s.color
                          duplex = $s.duplex; margins = $s.margins; scale = $s.scale; nup = $s.nup; hm = $caps.hm; via = 'station'; jid = $jid; sheets = $s.sheets }
                $ahead = (Waiting) + (Spool-Count $c)
                Sp-JobSet $jid @{ state = 'queued'; station = (Sp-StationName $c); sid = (Sp-NodeId); sheets = $s.sheets; ahead = $ahead }
                Add-Job $tmp ".$ext" $base $job $null $false
                Sp-SJson $res $x 200 @{ ok = $true; jid = $jid; ahead = $ahead }; continue
            }
            if ($path -match '^/sync/job/([0-9a-f]{16})$') {
                $j = Sp-JobGet $Matches[1]
                if ($j) { Sp-SJson $res $x 200 @{ state = [string]$j.state; ahead = [int]$j.ahead; err = [string]$j.err } } else { Sp-SJson $res $x 404 @{ error = 'GONE' } }
                continue
            }
            if ($path -eq '/sync/convert') {
                $c = Get-Cfg; $ext = ([string]$(if ($mt) { $mt.ext })).ToLower()
                if ($c.conv -eq '0' -or (Sp-LocalOffice) -notin 'office', 'lo') { Sp-SJson $res $x 503 @{ error = 'NO_CONVERTER' }; continue }
                if ($ext -notin $OfficeTypes) { Sp-SJson $res $x 415 @{ error = "This type of file can't be printed." }; continue }
                $rid = Sp-Rand 16; $f = Join-Path $up "$rid.$ext"; [IO.File]::WriteAllBytes($f, $pl)
                if (-not (Test-Magic $f $ext)) { Remove-Item $f -Force; Sp-SJson $res $x 415 @{ error = "This type of file can't be printed." }; continue }
                [IO.File]::WriteAllText((Join-Path $up "$rid.todo"), $ext)
                Sp-SJson $res $x 200 @{ rid = $rid }; continue
            }
            if ($path -match '^/sync/converted/([0-9a-f]{32})$') {
                $rid = $Matches[1]; $pdf = Join-Path $up "$rid.pdf"
                if (Test-Path $pdf) { $d = [IO.File]::ReadAllBytes($pdf); Get-ChildItem $up -Filter "$rid.*" | Remove-Item -Force -EA SilentlyContinue; Sp-SReply $res $x 200 $d }
                elseif (Test-Path (Join-Path $up "$rid.fail")) { Get-ChildItem $up -Filter "$rid.*" | Remove-Item -Force -EA SilentlyContinue; Sp-SJson $res $x 410 @{ error = 'FAILED' } }
                elseif (@(Get-ChildItem $up -Filter "$rid.*" -EA SilentlyContinue).Count) { Sp-SJson $res $x 202 @{ state = 'converting' } }
                else { Sp-SJson $res $x 404 @{ error = 'GONE' } }
                continue
            }
            if ($path -eq '/sync/scan') {
                $n = Sp-ScanNorm $mt (Sp-Scanners); if (-not $n.q) { Sp-SJson $res $x 404 @{ error = $n.err }; continue }
                $sid = Sp-Rand 8; Sp-ScanSet $sid @{ state = 'waiting'; target = (Sp-NodeId); q = $n.q }
                Sp-SJson $res $x 200 @{ sid = $sid }; continue
            }
            if ($path -match '^/sync/scan/([0-9a-f]{16})(/file)?$') {
                $sid = $Matches[1]; $file = $Matches[2]; $j = Sp-ScanGet $sid
                if (-not $j) { Sp-SJson $res $x 404 @{ error = 'GONE' }; continue }
                if (-not $file) { Sp-SJson $res $x 200 @{ state = [string]$j.state; err = [string]$j.err; ext = [string]$j.ext; pages = [int]$j.pages }; continue }
                $f = Join-Path $SpScans "$sid.$($j.ext)"
                if (-not (Test-Path $f)) { Sp-SJson $res $x 404 @{ error = 'GONE' }; continue }
                $d = [IO.File]::ReadAllBytes($f); Remove-Item $f, (Join-Path $SpScans "$sid.json") -Force -EA SilentlyContinue
                Sp-SReply $res $x 200 $d; continue
            }
            Sp-SJson $res $x 404 @{ error = 'Not found' }; continue
        }
        if ($m -eq 'GET' -and $path -eq '/stations') {    # public: the stations a person can pick on the print page
            $c = Get-Cfg; $me = Sp-Self
            $l = @([ordered]@{ id = (Sp-NodeId); station = (Sp-StationName $c); printer = $c.printer; here = $true; online = $true; ready = [bool]$me.ready; url = (Sp-MyUrl)
                               queue = [int]$me.queue; jobs = [int]$me.jobs; color = [bool]$me.color; duplex = [bool]$me.duplex })
            if (Sp-Group) {
                foreach ($x in @(Sp-Stations | Where-Object { $_.s.hasPrinter -ne $false } | Sort-Object station)) {
                    $l += [ordered]@{ id = $x.id; station = $x.station; printer = [string]$x.s.printer; here = $false; online = [bool]$x.online
                                      ready = [bool]($x.online -and $x.s.ready -and $x.s.accept); queue = [int]$x.s.queue; jobs = [int]$x.s.jobs; color = [bool]$x.s.color; duplex = [bool]$x.s.duplex; url = $x.url }
                }
            }
            Json $res 200 ([ordered]@{ here = (Sp-NodeId); auto = [bool]((Sp-Group) -and $c.share -ne '0'); list = $l }); continue
        }
        if ($m -eq 'GET' -and $path -match '^/job/([0-9a-f]{16})$') {    # public: the print page follows its job
            $j = Sp-JobGet $Matches[1]
            if ($j) { Json $res 200 @{ state = [string]$j.state; station = [string]$j.station; ahead = [int]$j.ahead; moved = [bool]$j.moved; why = [string]$j.why; err = [string]$j.err } } else { Json $res 200 @{ state = 'gone' } }
            continue
        }
        if ($m -eq 'GET' -and $path -eq '/scanners') { Json $res 200 @{ list = @(Sp-ScannersAll) }; continue }
        if ($m -eq 'POST' -and $path -eq '/scan') {
            $c = Get-Cfg
            if ($c.open -eq '0') { Json $res 503 @{ error = 'Printing is closed right now.' }; continue }
            if ($c.pin -and $req.Headers['X-Pin'] -ne $c.pin) { Json $res 403 @{ error = 'Wrong PIN.' }; continue }
            $q = $null; try { $q = (Read-Body $req) | ConvertFrom-Json } catch {}
            $all = @(Sp-ScannersAll | Where-Object { $_.station -eq [string]$q.station })
            $n = Sp-ScanNorm $q $all; if (-not $n.q) { Json $res 404 @{ error = $n.err }; continue }
            $dev = $all | Where-Object { $_.id -eq $n.q.device } | Select-Object -First 1
            $sid = Sp-Rand 8; Sp-ScanSet $sid @{ state = 'waiting'; target = [string]$q.station; q = $n.q; station = [string]$dev.stationName; name = [string]$dev.name }
            Json $res 200 @{ sid = $sid; station = [string]$dev.stationName }; continue
        }
        if ($m -eq 'GET' -and $path -match '^/scan/([0-9a-f]{16})(/file)?$') {
            $sid = $Matches[1]; $file = $Matches[2]; $j = Sp-ScanGet $sid
            if (-not $j) { Json $res 200 @{ state = 'gone' }; continue }
            if (-not $file) { Json $res 200 @{ state = [string]$j.state; err = [string]$j.err; ext = [string]$j.ext; size = [int]$j.size; pages = [int]$j.pages; station = [string]$j.station }; continue }
            $f = Join-Path $SpScans "$sid.$($j.ext)"
            if ($j.state -ne 'ready' -or -not (Test-Path $f)) { Json $res 404 @{ error = 'GONE' }; continue }
            $res.Headers.Add('Content-Disposition', "attachment; filename=`"scan-$(Get-Date -Format 'yyyyMMdd-HHmmss').$($j.ext)`"")
            SendFile $res $f $false; continue
        }

        # ------------------------------------------------ admin (this PC only)
        if ($path -like '/admin*') {
            if (-not $req.IsLocal) { Json $res 403 @{ error = 'The admin page only works on the printer computer.' }; continue }
            if ($m -eq 'GET' -and $path -eq '/admin') { Send $res 200 'text/html; charset=utf-8' $pages.admin; continue }
            if ($req.Headers['X-Admin'] -ne '1') { Json $res 403 @{ error = 'Forbidden' }; continue }
            if ($m -eq 'GET' -and $path -eq '/admin/info') { Json $res 200 (Get-Info); continue }
            if ($m -ne 'POST') { Json $res 404 @{ error = 'Not found' }; continue }
            $body = Read-Body $req
            $j = $null; if ($body) { $j = $body | ConvertFrom-Json }
            $c = Get-Cfg
            if ($path -eq '/admin/scan') { [IO.File]::WriteAllText((Join-Path $SpSync 'scan-now'), ''); Json $res 200 @{ ok = $true }; continue }
            if ($path -eq '/admin/net') {    # public | private (create) | alone | join (token) | token (show one)
                $do = [string]$j.do
                if ($do -in 'public', 'alone') { Sp-SetNet $do ''; Json $res 200 @{ ok = $true } }
                elseif ($do -eq 'private') { Sp-SetNet 'private' (Sp-Rand 32); Json $res 200 @{ ok = $true; token = (Sp-TokNew) } }
                elseif ($do -eq 'token') { $t = Sp-TokNew; if ($t) { Json $res 200 @{ token = $t; left = 900 } } else { Json $res 400 @{ error = 'NOT_PRIVATE' } } }
                elseif ($do -eq 'trust') {    # the computer was reinstalled: accept its new identity
                    $id = [string]$j.id; if ($id -cnotmatch '^[0-9a-f]{32}$') { Json $res 400 @{ error = 'Bad settings.' }; continue }
                    Sp-Locked { foreach ($n in 'pins.json', 'alerts.json') { $f = Join-Path $SpSync $n; $h = Sp-Hash (Sp-Read $f); if ($h.Contains($id)) { $h.Remove($id); Sp-Write $f $h } } }
                    Remove-Item (Join-Path $SpSync "pairs\$id.json") -Force -EA SilentlyContinue; [IO.File]::WriteAllText((Join-Path $SpSync 'scan-now'), '')
                    Json $res 200 @{ ok = $true }
                }
                elseif ($do -eq 'join') { $r = Sp-JoinNetwork ([string]$j.token); if ($r -eq 'ok') { Json $res 200 @{ ok = $true } } else { Json $res 400 @{ error = $r } } }
                else { Json $res 400 @{ error = 'Bad settings.' } }
                continue
            }
            if ($path -eq '/admin/set') {
                if ($null -ne $j.open) { $c.open = if ($j.open) { '1' } else { '0' } }
                if ($null -ne $j.lang) { if ($j.lang -notin 'fa', 'en') { Json $res 400 @{ error = 'Unknown language.' }; continue }; $c.lang = $j.lang }
                if ($null -ne $j.pin) {
                    if ($j.pin -notmatch '^[A-Za-z0-9]{0,20}$') { Json $res 400 @{ error = 'PIN: letters and numbers only, up to 20.' }; continue }
                    $c.pin = $j.pin
                }
                if ($null -ne $j.printer) {
                    $p = Get-Printer -Name $j.printer -EA SilentlyContinue
                    if ($p -and (Sp-IsOwnQueue $p)) { Json $res 400 @{ error = 'SELF_QUEUE' }; continue }
                    if (-not $p) { Json $res 400 @{ error = 'That printer does not exist.' }; continue }
                    $c.printer = $j.printer
                }
                if ($null -ne $j.station) {
                    $st = ([string]$j.station -replace '[\x00-\x1f<>"\\]', '').Trim(); if ($st.Length -gt 40) { $st = $st.Substring(0, 40) }
                    if (-not $st) { Json $res 400 @{ error = 'STATION_EMPTY' }; continue }
                    $c.station = $st
                }
                foreach ($k in 'share', 'accept', 'conv', 'dns') { if ($null -ne $j.$k) { $c[$k] = if ($j.$k) { '1' } else { '0' } } }
                if ($null -ne $j.domain) {
                    $d = ([string]$j.domain).Trim().ToLower() -replace '^https?://', '' -replace '/.*$', ''
                    if ($d -and $d -notmatch '^(?=.{3,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$') { Json $res 400 @{ error = 'DOMAIN_FORMAT' }; continue }
                    $c.domain = $d; $c.domainAt = [string](Sp-Now)
                }
                Sp-SaveCfg $c; Json $res 200 @{ ok = $true }
            }
            elseif ($path -eq '/admin/clear') {
                $n = @(Get-ChildItem $inbox -File -EA SilentlyContinue).Count
                Get-ChildItem $inbox -File -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
                $pj = @(if ($c.printer) { Get-PrintJob -PrinterName $c.printer -EA SilentlyContinue })
                $pj | Remove-PrintJob -EA SilentlyContinue
                Json $res 200 @{ removed = ($n + $pj.Count) }
            }
            elseif ($path -eq '/admin/testpage') {
                $p = Get-CimInstance Win32_Printer -EA SilentlyContinue | Where-Object { $_.Name -eq $c.printer }
                if (-not $p) { Json $res 500 @{ error = 'Printer not found.' }; continue }
                $rv = (Invoke-CimMethod -InputObject $p -MethodName PrintTestPage).ReturnValue
                if ($rv -eq 0) { Json $res 200 @{ ok = $true } } else { Json $res 500 @{ error = "Windows could not print a test page (code $rv)." } }
            }
            else { Json $res 404 @{ error = 'Not found' } }
            continue
        }

        # ------------------------------------------------ everyone
        if ($m -eq 'GET' -and $path -eq '/') {    # one address for everyone: other stations send people to the main station
            $l = Sp-Leader
            if ($l.id -ne (Sp-NodeId) -and $req.Url.Query -notmatch 'here' -and (Sp-Stations | Where-Object { $_.id -eq $l.id -and $_.online })) { Redirect $res "$($l.url)/"; continue }
            Send $res 200 'text/html; charset=utf-8' $pages.print; continue
        }

        if ($m -eq 'GET' -and $path -eq '/status') {
            $c = Get-Cfg; $office = Get-Office
            Json $res 200 @{ waiting = (Waiting); pin = [bool]$c.pin; open = ($c.open -ne '0'); printer = $c.printer; lang = $c.lang; station = (Sp-StationName $c)
                             office = $office; types = @(Get-Types $office); caps = (Net-Caps $c); scan = [bool]@(Sp-ScannersAll).Count; hasPrinter = [bool]$c.printer }
            continue
        }

        if ($m -eq 'POST' -and $path -eq '/upload') {
            $c = Get-Cfg
            if ($c.open -eq '0') { Json $res 503 @{ error = 'Printing is closed right now.' }; continue }
            if ($c.pin -and $req.Headers['X-Pin'] -ne $c.pin) { Json $res 403 @{ error = 'Wrong PIN.' }; continue }
            if ($req.ContentLength64 -gt $maxMB * 1MB) { Json $res 413 @{ error = 'File is bigger than 50 MB.' }; continue }
            Clean-Uploads
            $name = ''; try { $name = [Uri]::UnescapeDataString([string]$req.Headers['X-Filename']) } catch {}
            $name = $name -replace '[\\/:*?"<>|\x00-\x1f]', '_'; if ($name.Length -gt 120) { $name = $name.Substring($name.Length - 120) }
            $ext = ''; if ($name -match '\.([A-Za-z0-9]{1,5})$') { $ext = $Matches[1].ToLower() }
            $id = [guid]::NewGuid().ToString('N')
            $tmp = Join-Path $up "$id.part"
            if (-not (Save-Body $req $tmp)) { Json $res 413 @{ error = 'File is bigger than 50 MB.' }; continue }
            if (-not $ext) { $ext = Sniff $tmp }
            if ($ext -eq 'jpeg') { $ext = 'jpg' }; if ($ext -eq 'tiff') { $ext = 'tif' }
            $office = Get-Office
            if ($ext -in $OfficeTypes -and $office -eq 'signin') { Remove-Item $tmp -Force; Json $res 503 @{ error = 'NO_CONVERTER' }; continue }
            if ($ext -notin (Get-Types $office) -or -not (Test-Magic $tmp $ext)) { Remove-Item $tmp -Force; Json $res 415 @{ error = "This type of file can't be printed." }; continue }

            $kind = 'pdf'; $src = "$id.$ext"; $state = 'ready'
            if ($ext -in 'jpg', 'png', 'gif') { $kind = 'image'; Move-Item $tmp (Join-Path $up $src) }
            elseif ($ext -in 'bmp', 'tif') {   # browsers can't show these: keep a PNG copy (first frame) for preview + print
                $kind = 'image'; $src = "$id.png"
                try { $img = [System.Drawing.Image]::FromFile($tmp); $img.Save((Join-Path $up $src), [System.Drawing.Imaging.ImageFormat]::Png); $img.Dispose() }
                catch { Remove-Item $tmp -Force -EA SilentlyContinue; Json $res 415 @{ error = "This type of file can't be printed." }; continue }
                Remove-Item $tmp -Force
            }
            elseif ($ext -eq 'pdf') { Move-Item $tmp (Join-Path $up $src) }
            else {    # Word/Excel/PowerPoint/text: here (convert.ps1), or on the station with the most free power (syncd.ps1)
                Move-Item $tmp (Join-Path $up $src); $state = 'converting'
                $x = Sp-PickConverter $c
                if ($x) { [IO.File]::WriteAllText((Join-Path $up "$id.remote"), "$($x.id) $ext") } else { [IO.File]::WriteAllText((Join-Path $up "$id.todo"), $ext) }
            }
            $from = $req.RemoteEndPoint.Address.ToString() -replace '[^0-9A-Fa-f.]', '_'
            $meta = @{ name = $name; ext = $ext; kind = $kind; src = $src; from = $from; created = (Get-Date).ToString('o') }
            [IO.File]::WriteAllText((Join-Path $up "$id.meta"), (ConvertTo-Json -Compress $meta), [Text.Encoding]::UTF8)
            Json $res 200 @{ id = $id; kind = $kind; state = $state }
            continue
        }

        if ($m -eq 'GET' -and $path -match '^/info/([a-f0-9]{32})$') {
            $id = $Matches[1]; $meta = Read-Meta $id
            if (-not $meta) { Json $res 200 @{ state = 'gone' }; continue }
            Json $res 200 @{ state = (Get-State $id $meta); kind = $meta.kind }
            continue
        }

        if ($m -eq 'GET' -and $path -match '^/file/([a-f0-9]{32})$') {
            $id = $Matches[1]; $meta = Read-Meta $id
            if (-not $meta -or (Get-State $id $meta) -ne 'ready') { Json $res 404 @{ error = 'GONE' }; continue }
            $f = if ($meta.kind -eq 'image') { Join-Path $up $meta.src } else { Join-Path $up "$id.pdf" }
            SendFile $res $f $false
            continue
        }

        if ($m -eq 'POST' -and $path -eq '/print') {
            $c = Get-Cfg
            if ($c.open -eq '0') { Json $res 503 @{ error = 'Printing is closed right now.' }; continue }
            if ($c.pin -and $req.Headers['X-Pin'] -ne $c.pin) { Json $res 403 @{ error = 'Wrong PIN.' }; continue }
            $j = $null; try { $j = (Read-Body $req) | ConvertFrom-Json } catch {}
            $id = if ($j) { [string]$j.id } else { '' }
            $meta = Read-Meta $id
            if (-not $meta -or (Get-State $id $meta) -ne 'ready') { Json $res 410 @{ error = 'GONE' }; continue }
            $s = Norm-Job $j (Net-Caps $c); if (-not $s) { Json $res 400 @{ error = 'Bad settings.' }; continue }
            $want = [string]$j.target; if ($want -notmatch '^(auto|[0-9a-f]{32})$') { $want = 'auto' }
            $pick = Sp-PickStation $want @{ color = ($s.color -eq 'color'); duplex = ($s.duplex -ne 'off'); pw = $s.pw; ph = $s.ph } $c
            if ($pick.err) { Json $res 409 @{ error = $pick.err }; continue }
            $caps = Get-Caps $c.printer
            if (-not $pick.x) { if (-not $caps.color) { $s.color = 'gray' }; if (-not $caps.duplex) { $s.duplex = 'off' } }    # printing here after all
            $stamp = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), (Get-Random -Maximum 99999)
            $srcFile = if ($meta.kind -eq 'image') { Join-Path $up $meta.src } else { Join-Path $up "$id.pdf" }
            $ext = [IO.Path]::GetExtension($srcFile)
            $base = "$stamp-from$($meta.from)-c$($s.copies)"
            $jid = Sp-Rand 8; $here = Sp-StationName $c
            $job = @{ name = $meta.name; copies = $s.copies; pages = $s.pages; paper = $s.paper; orientation = $s.orientation; color = $s.color; duplex = $s.duplex
                      margins = $s.margins; scale = $s.scale; nup = $s.nup; hm = $caps.hm; jid = $jid; sheets = $s.sheets; pw = $s.pw; ph = $s.ph; land = $s.land; from = $meta.from }
            $ahead = if ($pick.x) { [int]$pick.x.s.jobs } else { (Waiting) + (Spool-Count $c) }
            Sp-JobSet $jid @{ state = $(if ($pick.x) { 'sending' } else { 'queued' }); station = $(if ($pick.x) { $pick.x.station } else { $here }); sid = $(if ($pick.x) { $pick.x.id } else { (Sp-NodeId) })
                              sheets = $s.sheets; ahead = $ahead }
            Sp-Hold $jid $srcFile $ext $job
            Sp-JobSet $jid @{ picked = ($want -ne 'auto') }
            Add-Job $srcFile $ext $base $job $pick.x ($want -ne 'auto')
            Get-ChildItem $up -File -Filter "$id.*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
            Json $res 200 @{ ok = $true; jid = $jid; station = $(if ($pick.x) { $pick.x.station } else { $here }); here = (-not $pick.x); waiting = (Waiting) }
            continue
        }

        Json $res 404 @{ error = 'Not found' }
    } catch {
        try { $res.Abort() } catch {}
    }
}
