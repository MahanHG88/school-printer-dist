# sync.ps1 - School Printer: settings, printer choice and the printing network. Dot-sourced by PrintServer.ps1,
# watch.ps1 and syncd.ps1 (needs $root). Same protocol as schoolprinter.pl, so Windows, Mac and Linux stations
# share one network:
#   - stations with the same network password find each other: syncd.ps1 scans this PC's local network for port
#     8631 every minute (GET /sync/hello answers with a group id made from the password) and asks every station of
#     the group for its status every few seconds (Sync\st\<id>.json);
#   - every /sync/* request is signed: X-Sync-Node / X-Sync-Time / X-Sync-Sig = HMAC-SHA256(key, "time\nMETHOD\npath\nnode");
#   - the key comes from the password (20000 rounds of HMAC-SHA256); the password itself is never stored.
# A "School Printer" queue (added with "Add to this device") prints back into School Printer, so it is never used as
# THE printer: that loop is what printed a failing job every few seconds.

$SpSync  = Join-Path $root 'Sync'
$SpSt    = Join-Path $SpSync 'st'
$SpJobs  = Join-Path $SpSync 'jobs'
$SpScans = Join-Path $SpSync 'scans'
$SpHeld  = Join-Path $SpSync 'held'      # a copy of every job until it has printed: moved to another printer if needed
$SpOut   = Join-Path $root 'Outbox'
$SpUp    = Join-Path $root 'Uploads'
$SpInbox = Join-Path $root 'Inbox'
$SpCfgF  = Join-Path $root 'config.txt'
$SpLog   = Join-Path $root 'log.txt'
$SpPort  = if ($env:SP_PORT) { [int]$env:SP_PORT } else { 8631 }
$SpAlias = 'schoolprinter.local'
$SpFresh = 25          # a station's status older than this (seconds) = not answering
$SpMax   = 50
$SpUtf8  = New-Object Text.UTF8Encoding $false
foreach ($d in $SpSync, $SpSt, $SpJobs, $SpScans, $SpHeld, $SpOut, $SpUp, $SpInbox) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

function Sp-Now { [int64](([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds) }
function Sp-Read($f) { if (-not (Test-Path -LiteralPath $f)) { return $null }; try { [IO.File]::ReadAllText($f, $SpUtf8) | ConvertFrom-Json } catch { $null } }
function Sp-Write($f, $obj) {
    $t = "$f.$PID.tmp"
    [IO.File]::WriteAllText($t, (ConvertTo-Json -Compress -Depth 8 -InputObject $obj), $SpUtf8)
    Move-Item -LiteralPath $t -Destination $f -Force
}
function Sp-Hex([byte[]]$b) { $sb = New-Object Text.StringBuilder; foreach ($x in $b) { [void]$sb.Append($x.ToString('x2')) }; $sb.ToString() }
function Sp-Rand([int]$n) { $b = New-Object byte[] $n; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); Sp-Hex $b }
function Sp-Hash($obj) { $h = @{}; if ($obj) { foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }; $h }
function Sp-LogLine([string]$t) { try { Add-Content -LiteralPath $SpLog "$(Get-Date -Format s)  $t" -Encoding UTF8 } catch {} }

# ---------------------------------------------------------------- settings
function Sp-Cfg {
    $c = @{ pin = ''; open = '1'; printer = ''; lang = 'fa'; station = ''; share = '1'; accept = '1'; conv = '1'; domain = ''; domainAt = '0'; dns = '1' }
    if (Test-Path $SpCfgF) {
        Get-Content $SpCfgF -Encoding UTF8 | ForEach-Object { if ($_ -match '^\s*(\w+)\s*=\s*(.*)$') { $c[$Matches[1]] = $Matches[2].Trim() } }
    }
    $c.printer = Sp-Printer $c.printer
    $c
}
function Sp-SaveCfg($c) {
    $keys = 'printer', 'pin', 'open', 'lang', 'station', 'share', 'accept', 'conv', 'domain', 'domainAt', 'dns'
    Set-Content $SpCfgF (@('# School Printer settings (also changeable on the admin page)') + @($keys | ForEach-Object { "$_=$($c[$_])" })) -Encoding UTF8
    $script:SpPrn = @{ want = $null; at = [datetime]::MinValue; name = '' }
}
function Sp-StationName($c) { if ($c.station) { [string]$c.station } else { $env:COMPUTERNAME } }

# ---------------------------------------------------------------- which printer prints (never a School Printer queue)
function Sp-IsOwnQueue($p) { ([string]$p.PortName -match ':8631(/|$)') -or ([string]$p.Name -match '^School Printer' -and [string]$p.DriverName -match 'IPP') }
$script:SpPrn = @{ want = $null; at = [datetime]::MinValue; name = '' }
function Sp-Printer([string]$want) {
    if ($script:SpPrn.want -eq $want -and ((Get-Date) - $script:SpPrn.at).TotalSeconds -lt 15) { return $script:SpPrn.name }
    $all = @(Get-Printer -EA SilentlyContinue)
    $p = if ($want) { $all | Where-Object { $_.Name -eq $want } | Select-Object -First 1 } else { $null }
    $name = $want
    if (-not $want -or ($p -and (Sp-IsOwnQueue $p))) {    # not set, or set to School Printer itself: the installer's choice
        $real = @($all | Where-Object { -not (Sp-IsOwnQueue $_) -and $_.DriverName -notmatch 'Microsoft|OneNote|Fax|PDF|XPS|Send To' -and $_.PortName -notmatch '^(PORTPROMPT|nul|FILE|XPS|SHRFAX)' })
        $usb = @($real | Where-Object { $_.PortName -like 'USB*' })
        $name = if ($usb.Count) { $usb[0].Name } elseif ($real.Count) { $real[0].Name } else { '' }
    }
    $script:SpPrn = @{ want = $want; at = Get-Date; name = $name }
    $name
}
function Sp-RealPrinters { @(Get-Printer -EA SilentlyContinue | Where-Object { -not (Sp-IsOwnQueue $_) } | ForEach-Object { [string]$_.Name }) }

# ---- printer capabilities (paper sizes from the driver, colour, duplex, unprintable edge) - cached 60 s
$script:SpCaps = @{ printer = $null; at = [datetime]::MinValue; caps = $null }
function Sp-Caps([string]$printer) {
    if ($script:SpCaps.printer -eq $printer -and ((Get-Date) - $script:SpCaps.at).TotalSeconds -lt 60) { return $script:SpCaps.caps }
    $caps = @{ papers = @(); def = ''; color = $false; duplex = $false; hm = 4.2 }
    try {
        $ps = New-Object System.Drawing.Printing.PrinterSettings
        $ps.PrinterName = $printer
        if ($printer -and $ps.IsValid) {
            $seen = @{}
            $papers = foreach ($p in $ps.PaperSizes) {
                if ($p.Width -gt 0 -and $p.Height -gt 0 -and $p.Kind -ne 'Custom' -and -not $seen[$p.PaperName]) {
                    $seen[$p.PaperName] = 1
                    @{ n = $p.PaperName; w = [math]::Round([math]::Min($p.Width, $p.Height) * 0.254, 1); h = [math]::Round([math]::Max($p.Width, $p.Height) * 0.254, 1) }
                }
            }
            $dp = $ps.DefaultPageSettings
            $caps = @{ papers = @($papers); def = $dp.PaperSize.PaperName; color = $ps.SupportsColor; duplex = $ps.CanDuplex
                       hm = [math]::Round([math]::Max($dp.HardMarginX, $dp.HardMarginY) * 0.254, 1) }
        }
    } catch {}
    $script:SpCaps = @{ printer = $printer; at = Get-Date; caps = $caps }
    $caps
}

# ---- Word/Excel/PowerPoint: converted by convert.ps1 in the signed-in user's session (Office will not run as SYSTEM)
function Sp-LocalOffice {
    $hasMs = Test-Path 'Registry::HKEY_CLASSES_ROOT\Word.Application\CLSID'
    $hasLo = (Test-Path 'C:\Program Files\LibreOffice\program\soffice.exe') -or (Test-Path 'C:\Program Files (x86)\LibreOffice\program\soffice.exe')
    if (-not ($hasMs -or $hasLo)) { return 'none' }
    $alive = Join-Path $SpUp 'converter.alive'
    if ((Test-Path $alive) -and ((Get-Date) - (Get-Item $alive).LastWriteTime).TotalSeconds -lt 20) { if ($hasMs) { 'office' } else { 'lo' } } else { 'signin' }
}
function Sp-Waiting { @(Get-ChildItem $SpInbox -File -Filter *.json -EA SilentlyContinue).Count + @(Get-ChildItem $SpInbox -File -Filter *.pdf -EA SilentlyContinue | Where-Object { -not (Test-Path ([IO.Path]::ChangeExtension($_.FullName, '.json'))) }).Count }

# ---------------------------------------------------------------- identity, password, signatures
function Sp-NodeId {
    if ($script:SpId) { return $script:SpId }
    $f = Join-Path $SpSync 'node-id'; $id = ''
    if (Test-Path $f) { $id = ([IO.File]::ReadAllText($f)).Trim() }
    if ($id -cnotmatch '^[0-9a-f]{32}$') { $id = Sp-Rand 16; [IO.File]::WriteAllText($f, $id) }
    $script:SpId = $id; $id
}
function Sp-Group { $g = Sp-Read (Join-Path $SpSync 'group.json'); if ($g -and [string]$g.key -cmatch '^[0-9a-f]{64}$') { $g } else { $null } }
function Sp-Hmac([string]$key, [string]$msg) { $h = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::ASCII.GetBytes($key)); Sp-Hex ($h.ComputeHash($SpUtf8.GetBytes($msg))) }
function Sp-Derive([string]$pw) {    # network password -> key + group id (same maths as derive_group in schoolprinter.pl)
    $h = [Security.Cryptography.HMACSHA256]::new($SpUtf8.GetBytes($pw))
    $x = $h.ComputeHash($SpUtf8.GetBytes('school-printer/1'))
    for ($i = 0; $i -lt 20000; $i++) { $x = $h.ComputeHash($x) }        # slow on purpose: makes guessing the password costly
    $key = Sp-Hex $x
    @{ key = $key; gid = (Sp-Hmac $key 'group').Substring(0, 16) }
}
function Sp-Same([string]$a, [string]$b) { if ($a.Length -ne $b.Length) { return $false }; $d = 0; for ($i = 0; $i -lt $a.Length; $i++) { $d = $d -bor ([int][char]$a[$i] -bxor [int][char]$b[$i]) }; $d -eq 0 }
function Sp-SignHdr($g, [string]$method, [string]$path) { $t = Sp-Now; $id = Sp-NodeId; @{ 'X-Sync-Node' = $id; 'X-Sync-Time' = "$t"; 'X-Sync-Sig' = (Sp-Hmac $g.key "$t`n$method`n$path`n$id") } }
function Sp-Auth($req) {    # -> id of the station that signed this request, or '' (wrong password, clock off by > 5 min, not a station)
    $g = Sp-Group; if (-not $g) { return '' }
    $id = [string]$req.Headers['X-Sync-Node']; $t = [string]$req.Headers['X-Sync-Time']; $sig = [string]$req.Headers['X-Sync-Sig']
    if ($id -cnotmatch '^[0-9a-f]{32}$' -or $t -notmatch '^\d{9,11}$' -or $sig -cnotmatch '^[0-9a-f]{64}$') { return '' }
    if ([math]::Abs((Sp-Now) - [int64]$t) -gt 300) { return '' }
    if (Sp-Same (Sp-Hmac $g.key "$t`n$($req.HttpMethod)`n$($req.Url.AbsolutePath)`n$id") $sig) { $id } else { '' }
}

# ---------------------------------------------------------------- HTTP client (to other stations)
function Sp-Http([string]$url, [string]$method, [string]$path, $hdr, [byte[]]$body, [int]$timeoutMs = 5000) {
    try {
        $rq = [Net.HttpWebRequest]::Create($url.TrimEnd('/') + $path)
        $rq.Method = $method; $rq.Timeout = $timeoutMs; $rq.ReadWriteTimeout = [math]::Max($timeoutMs, 30000)
        $rq.KeepAlive = $false; $rq.Proxy = $null; $rq.AllowAutoRedirect = $false
        if ($hdr) { foreach ($k in @($hdr.Keys)) { $rq.Headers[$k] = [string]$hdr[$k] } }
        if ($null -ne $body -and $body.Length) { $rq.ContentType = 'application/octet-stream'; $rq.ContentLength = $body.Length; $s = $rq.GetRequestStream(); $s.Write($body, 0, $body.Length); $s.Close() }
        elseif ($method -eq 'POST') { $rq.ContentLength = 0 }
        $rs = $null
        try { $rs = $rq.GetResponse() }
        catch { $ex = $_.Exception; while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }; if ($ex -and $ex.Response) { $rs = $ex.Response } else { return @{ code = 0; bytes = $null } } }
        $ms = New-Object IO.MemoryStream; $st = $rs.GetResponseStream(); $st.CopyTo($ms); $st.Close()
        $code = [int]$rs.StatusCode; $rs.Close()
        @{ code = $code; bytes = $ms.ToArray() }
    } catch { @{ code = 0; bytes = $null } }
}
function Sp-Peer([string]$url, [string]$method, [string]$path, $hdr, [byte[]]$body, [int]$timeoutMs = 5000) {    # signed request to a station
    $g = Sp-Group; if (-not $g) { return @{ code = 0; bytes = $null } }
    $h = Sp-SignHdr $g $method $path; if ($hdr) { foreach ($k in @($hdr.Keys)) { $h[$k] = $hdr[$k] } }
    Sp-Http $url $method $path $h $body $timeoutMs
}
function Sp-Text($r) { if ($r -and $r.bytes) { $SpUtf8.GetString($r.bytes) } else { '' } }
function Sp-Json($r) { try { (Sp-Text $r) | ConvertFrom-Json } catch { $null } }

# ---------------------------------------------------------------- this PC's address
$script:SpUrl = @{ at = [datetime]::MinValue; url = '' }
function Sp-LanIPs {
    @(Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue | Where-Object {
        $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -notmatch 'vEthernet|Loopback|WSL|VirtualBox|VMware|Bluetooth' })
}
function Sp-MyUrl {
    if ($env:SP_ADDR) { return $env:SP_ADDR }
    if (((Get-Date) - $script:SpUrl.at).TotalSeconds -lt 60) { return $script:SpUrl.url }
    $ip = Sp-LanIPs | Sort-Object { if ($_.PrefixOrigin -eq 'Dhcp') { 0 } else { 1 } } | Select-Object -First 1
    $u = if ($ip) { "http://$($ip.IPAddress):$SpPort" } else { "http://$($env:COMPUTERNAME):$SpPort" }
    $script:SpUrl = @{ at = Get-Date; url = $u }; $u
}

# ---------------------------------------------------------------- the other stations
function Sp-Peers { $p = Sp-Read (Join-Path $SpSync 'peers.json'); if ($p) { @($p | Where-Object { [string]$_.id -cmatch '^[0-9a-f]{32}$' }) } else { @() } }
function Sp-Self { $s = Sp-Read (Join-Path $SpSync 'self.json'); if ($s -and ((Sp-Now) - [int64]$s.at) -lt 30) { $s } else { $null } }
function Sp-Stations {    # every other station: id, url, station, s (status), online, age, err
    $now = Sp-Now
    foreach ($x in Sp-Peers) {
        $st = Sp-Read (Join-Path $SpSt "$($x.id).json"); $e = Sp-Read (Join-Path $SpSt "$($x.id).err")
        $at = if ($st -and $st.at) { [int64]$st.at } else { 0 }; $eat = if ($e -and $e.at) { [int64]$e.at } else { 0 }
        $age = if ($at) { $now - $at } else { 1000000000 }
        $s = if ($st) { $st.s } else { $null }
        [pscustomobject]@{ id = [string]$x.id; url = [string]$x.url; station = $(if ($s -and $s.station) { [string]$s.station } else { [string]$x.station }); s = $s
                           online = ($age -le $SpFresh -and $eat -le $at); age = $age; err = $(if ($eat -gt $at) { [string]$e.err } else { '' }) }
    }
}
function Sp-Leader { $l = Sp-Read (Join-Path $SpSync 'leader.json'); if ($l -and $l.id) { $l } else { [pscustomobject]@{ id = (Sp-NodeId); url = (Sp-MyUrl) } } }

# ---------------------------------------------------------------- choosing where a job prints / a file is converted
function Sp-PaperFits($s, $w, $h) {
    if (-not $w -or -not $s -or -not $s.papers) { return $true }
    $a = [math]::Min([double]$w, [double]$h); $b = [math]::Max([double]$w, [double]$h)
    foreach ($p in @($s.papers)) { if ([math]::Abs([double]$p.w - $a) -lt 2 -and [math]::Abs([double]$p.h - $b) -lt 2) { return $true } }
    $false
}
function Sp-Pending {    # sheets this station is still sending to each station
    $h = @{}
    foreach ($f in @(Get-ChildItem $SpJobs -Filter *.json -EA SilentlyContinue)) { $j = Sp-Read $f.FullName; if ($j -and $j.state -eq 'sending') { $h[[string]$j.sid] = [int]$h[[string]$j.sid] + [math]::Max(1, [int]$j.sheets) } }
    $h
}
function Sp-PickStation([string]$want, $need, $c) {    # -> @{ x = station to send to (or $null = print here); err }
    $me = Sp-NodeId
    if (-not $want -or $want -eq $me -or -not (Sp-Group)) { return @{ x = $null; err = '' } }
    $on = @(Sp-Stations | Where-Object { $_.online -and $_.s.ready -and $_.s.accept })
    if ($want -ne 'auto') {
        $x = $on | Where-Object { $_.id -eq $want } | Select-Object -First 1
        if ($x) { return @{ x = $x; err = '' } } else { return @{ x = $null; err = 'STATION_OFFLINE' } }
    }
    if ($c.share -eq '0') { return @{ x = $null; err = '' } }
    $self = Sp-Self; $pend = Sp-Pending; $cand = @()
    if ($self -and $self.ready) { $cand += @{ here = $true; s = $self; load = [double]$self.queue + [int]$pend[$me] } }
    foreach ($x in $on) { $cand += @{ here = $false; x = $x; s = $x.s; load = [double]$x.s.queue + [int]$pend[$x.id] } }
    if (-not $cand.Count) { return @{ x = $null; err = '' } }
    $fit = @($cand | Where-Object { (-not $need.color -or $_.s.color) -and (-not $need.duplex -or $_.s.duplex) -and (Sp-PaperFits $_.s $need.pw $need.ph) })
    if (-not $fit.Count) { $fit = $cand }
    $best = $fit[0]; foreach ($k in $fit) { if ($k.load -lt $best.load) { $best = $k } }    # ties: this station (first)
    if ($best.here) { @{ x = $null; err = '' } } else { @{ x = $best.x; err = '' } }
}
function Sp-Best($need, [string[]]$exclude) {    # failover: the least busy printer that can take the job, never one in $exclude -> @{ here; x } or $null
    $me = Sp-NodeId; $self = Sp-Self; $pend = Sp-Pending; $cand = @()
    if ($self -and $self.ready -and $me -notin $exclude) { $cand += @{ here = $true; x = $null; s = $self; load = [double]$self.queue + [int]$pend[$me] } }
    if (Sp-Group) { foreach ($x in @(Sp-Stations | Where-Object { $_.online -and $_.s.ready -and $_.s.accept -and $_.id -notin $exclude })) { $cand += @{ here = $false; x = $x; s = $x.s; load = [double]$x.s.queue + [int]$pend[$x.id] } } }
    if (-not $cand.Count) { return $null }
    $fit = @($cand | Where-Object { (-not $need.color -or $_.s.color) -and (-not $need.duplex -or $_.s.duplex) -and (Sp-PaperFits $_.s $need.pw $need.ph) })
    if (-not $fit.Count) { $fit = $cand }
    $best = $fit[0]; foreach ($k in $fit) { if ($k.load -lt $best.load) { $best = $k } }
    $best
}
function Sp-Hold([string]$jid, [string]$src, [string]$ext, $job) {    # keep a copy of the job until it has printed
    try { Copy-Item -LiteralPath $src -Destination (Join-Path $SpHeld "$jid$ext") -Force; Sp-Write (Join-Path $SpHeld "$jid.json") $job } catch {}
}
function Sp-Unhold([string]$jid) { Get-ChildItem $SpHeld -Filter "$jid.*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue }
function Sp-ConvScore($s) {
    $v = [double]([math]::Max(1, [int]$s.cores)) * (100 - [double]$s.cpu) / 100 - 1.5 * [double]$s.conv.busy
    if ([double]$s.memFree -gt 0 -and [double]$s.memFree -lt 800) { $v -= 2 }
    $v
}
function Sp-ConvPeers($c) { if ($c.conv -eq '0' -or -not (Sp-Group)) { return @() }; @(Sp-Stations | Where-Object { $_.online -and $_.s.conv.ok -and $_.s.conv.share }) }
function Sp-PickConverter($c) {    # -> station to convert on, or $null = here
    $p = Sp-ConvPeers $c; if (-not $p.Count) { return $null }
    $best = $p[0]; foreach ($x in $p) { if ((Sp-ConvScore $x.s) -gt (Sp-ConvScore $best.s)) { $best = $x } }
    if ((Sp-LocalOffice) -notin 'office', 'lo') { return $best }
    $self = Sp-Self; if (-not $self) { return $null }
    $mine = Sp-ConvScore $self; $margin = [math]::Max(0.75, [math]::Abs($mine) * 0.3)
    if ((Sp-ConvScore $best.s) -gt $mine + $margin) { $best } else { $null }
}

# ---------------------------------------------------------------- jobs (the print page follows them) and scans
function Sp-Locked([scriptblock]$sb) {
    $m = New-Object Threading.Mutex($false, 'Global\SchoolPrinterSync')
    try { try { [void]$m.WaitOne(5000) } catch [Threading.AbandonedMutexException] {} ; & $sb } finally { try { $m.ReleaseMutex() } catch {}; $m.Dispose() }
}
function Sp-JobGet([string]$id) { if ($id -cnotmatch '^[0-9a-f]{16}$') { return $null }; Sp-Read (Join-Path $SpJobs "$id.json") }
function Sp-JobSet([string]$id, [hashtable]$kv) {
    if ($id -cnotmatch '^[0-9a-f]{16}$') { return }
    Sp-Locked {
        $j = Sp-Hash (Sp-JobGet $id); if (-not $j.Count) { $j = @{ jid = $id; at = (Sp-Now) } }
        foreach ($k in $kv.Keys) { $j[$k] = $kv[$k] }
        Sp-Write (Join-Path $SpJobs "$id.json") $j
    }
}
function Sp-ScanGet([string]$id) { if ($id -cnotmatch '^[0-9a-f]{16}$') { return $null }; Sp-Read (Join-Path $SpScans "$id.json") }
function Sp-ScanSet([string]$id, [hashtable]$kv) {
    if ($id -cnotmatch '^[0-9a-f]{16}$') { return }
    Sp-Locked {
        $j = Sp-Hash (Sp-ScanGet $id); if (-not $j.Count) { $j = @{ sid = $id; at = (Sp-Now) } }
        foreach ($k in $kv.Keys) { $j[$k] = $kv[$k] }
        Sp-Write (Join-Path $SpScans "$id.json") $j
    }
}
function Sp-Scanners {    # scanners on this PC (found by syncd.ps1 every minute)
    $l = Sp-Read (Join-Path $SpSync 'scanners.json'); if ($l) { @($l) } else { @() }
}
function Sp-ScannersAll {    # every scanner in the network, for the print page
    $c = Sp-Cfg; $me = Sp-NodeId; $out = @()
    foreach ($d in Sp-Scanners) { $out += [ordered]@{ station = $me; stationName = (Sp-StationName $c); here = $true; online = $true; id = $d.id; name = $d.name; dpis = @($d.dpis); modes = @($d.modes); sources = @($d.sources) } }
    if (Sp-Group) {
        foreach ($x in @(Sp-Stations | Where-Object { $_.online })) {
            foreach ($d in @($x.s.scanners)) { if ($d -and $d.id) { $out += [ordered]@{ station = $x.id; stationName = $x.station; here = $false; online = $true; id = $d.id; name = $d.name; dpis = @($d.dpis); modes = @($d.modes); sources = @($d.sources) } } }
        }
    }
    $out
}
function Sp-ScanNorm($q, $list) {    # request -> clean scan settings for a known scanner: @{ q; err }
    $dev = $list | Where-Object { $_.id -eq [string]$q.device } | Select-Object -First 1
    if (-not $dev) { return @{ q = $null; err = 'NO_SCANNER' } }
    $dpis = @($dev.dpis | ForEach-Object { [int]$_ }); $want = 300; [void][int]::TryParse([string]$q.dpi, [ref]$want)
    $dpi = $dpis | Sort-Object { [math]::Abs($_ - $want) } | Select-Object -First 1; if (-not $dpi) { $dpi = 300 }
    $mode = [string]$q.mode; if ($mode -notin @($dev.modes)) { $mode = @($dev.modes)[0] }
    $src = [string]$q.source; if ($src -notin @($dev.sources)) { $src = 'flatbed' }
    $fmt = [string]$q.format; if ($fmt -notin 'pdf', 'jpg', 'png') { $fmt = 'pdf' }; if ($src -eq 'feeder') { $fmt = 'pdf' }
    @{ q = @{ device = [string]$dev.id; dpi = [int]$dpi; mode = $mode; source = $src; format = $fmt }; err = '' }
}

# ---------------------------------------------------------------- JPEG pages -> PDF (same layout as jpegs_pdf in schoolprinter.pl)
function Sp-JpegSize([byte[]]$d) {
    $i = 2
    while ($i + 9 -lt $d.Length) {
        if ($d[$i] -ne 0xFF) { return $null }
        $t = [int]$d[$i + 1]; $len = ([int]$d[$i + 2] -shl 8) -bor [int]$d[$i + 3]
        if ($t -ge 0xC0 -and $t -le 0xCF -and $t -notin 0xC4, 0xC8, 0xCC) {
            return @{ h = (([int]$d[$i + 5] -shl 8) -bor [int]$d[$i + 6]); w = (([int]$d[$i + 7] -shl 8) -bor [int]$d[$i + 8]); c = [int]$d[$i + 9] }
        }
        $i += 2 + $len
    }
    $null
}
function Sp-JpegsPdf($imgs, [int]$dpi) {
    $ms = New-Object IO.MemoryStream; $off = @{}; $inv = [Globalization.CultureInfo]::InvariantCulture
    $W = { param([string]$s) $b = [Text.Encoding]::ASCII.GetBytes($s); $ms.Write($b, 0, $b.Length) }
    $n = @($imgs).Count; $kids = @(); $objs = 2 + 3 * $n
    & $W "%PDF-1.4`n%"; $ms.Write([byte[]](0xE2, 0xE3, 0xCF, 0xD3, 0x0A), 0, 5)
    for ($k = 0; $k -lt $n; $k++) {
        $img = [byte[]]@($imgs)[$k]; $sz = Sp-JpegSize $img; if (-not $sz) { continue }
        $po = 3 + 3 * $k; $co = 4 + 3 * $k; $io = 5 + 3 * $k; $kids += "$po 0 R"
        $pw = ($sz.w * 72.0 / $dpi).ToString('0.00', $inv); $ph = ($sz.h * 72.0 / $dpi).ToString('0.00', $inv)
        $off[$po] = $ms.Position; & $W "$po 0 obj`n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pw $ph] /Resources << /XObject << /Im$k $io 0 R >> >> /Contents $co 0 R >>`nendobj`n"
        $cs = "q $pw 0 0 $ph 0 0 cm /Im$k Do Q"
        $off[$co] = $ms.Position; & $W "$co 0 obj`n<< /Length $($cs.Length) >>`nstream`n$cs`nendstream`nendobj`n"
        $space = switch ($sz.c) { 1 { 'DeviceGray' } 4 { 'DeviceCMYK' } default { 'DeviceRGB' } }
        $off[$io] = $ms.Position
        & $W "$io 0 obj`n<< /Type /XObject /Subtype /Image /Width $($sz.w) /Height $($sz.h) /ColorSpace /$space /BitsPerComponent 8 /Filter /DCTDecode /Length $($img.Length) >>`nstream`n"
        $ms.Write($img, 0, $img.Length); & $W "`nendstream`nendobj`n"
    }
    $off[1] = $ms.Position; & $W "1 0 obj`n<< /Type /Catalog /Pages 2 0 R >>`nendobj`n"
    $off[2] = $ms.Position; & $W "2 0 obj`n<< /Type /Pages /Kids [$($kids -join ' ')] /Count $($kids.Count) >>`nendobj`n"
    $x = $ms.Position; & $W "xref`n0 $($objs + 1)`n0000000000 65535 f `n"
    for ($i = 1; $i -le $objs; $i++) { if ($off.ContainsKey($i)) { & $W ("{0:D10} 00000 n `n" -f [int64]$off[$i]) } else { & $W "0000000000 65535 f `n" } }
    & $W "trailer`n<< /Size $($objs + 1) /Root 1 0 R >>`nstartxref`n$x`n%%EOF`n"
    $ms.ToArray()
}

# ---------------------------------------------------------------- the admin page's "Printing network" card
function Sp-NetInfo($c) {
    $g = Sp-Group; $me = Sp-Self; $o = Sp-Read (Join-Path $SpSync 'others.json'); $id = Sp-NodeId
    $row = {
        param($x, $s, $here)
        [ordered]@{ id = $x.id; station = $x.station; url = [string]$x.url; here = $here; online = [bool]$x.online; age = $(if ($x.age -lt 100000000) { [int64]$x.age } else { -1 }); err = [string]$x.err
                    printer = [string]$s.printer; pstatus = [string]$s.pstatus; ready = [bool]$s.ready; accept = [bool]$s.accept; queue = [int]$s.queue; jobs = [int]$s.jobs
                    cpu = [int]$s.cpu; cores = [int]$s.cores; memFree = [int]$s.memFree; memTotal = [int]$s.memTotal; conv = $(if ($s.conv.kind) { [string]$s.conv.kind } else { 'none' })
                    convBusy = [int]$s.conv.busy; color = [bool]$s.color; duplex = [bool]$s.duplex }
    }
    $rows = @(& $row ([pscustomobject]@{ id = $id; station = (Sp-StationName $c); url = (Sp-MyUrl); online = $true; age = 0; err = '' }) $me $true)
    if ($g) { foreach ($x in @(Sp-Stations | Sort-Object @{ e = { -not $_.online } }, @{ e = { $_.station } })) { $rows += & $row $x $x.s $false } }
    $ls = Join-Path $SpSync 'others.json'
    $last = if ($g -and (Test-Path $ls)) { [int]((Get-Date) - (Get-Item $ls).LastWriteTime).TotalSeconds } else { -1 }
    [ordered]@{ ok = $true; joined = [bool]$g; gid = $(if ($g) { [string]$g.gid } else { '' }); station = (Sp-StationName $c); share = ($c.share -ne '0'); accept = ($c.accept -ne '0')
                conv = ($c.conv -ne '0'); others = $(if ($g -and $o) { [int]$o.n } else { 0 }); lastScan = $last; max = $SpMax; stations = $rows
                main = (Sp-Leader).id; alias = "http://$($SpAlias):$SpPort" }
}
