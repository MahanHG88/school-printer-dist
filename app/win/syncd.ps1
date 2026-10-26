# syncd.ps1 - School Printer: the printing network's worker for Windows (task "MacPrint Sync", runs as SYSTEM).
# Every few seconds: this station's status (Sync\self.json, what /sync/status answers), the other stations' statuses,
# jobs and Office files waiting to go to another station, scans, and which station is the main one.
# Every minute: a scan of the local network for other School Printers (port 8631) and for scanners on this PC.
#   -Scan <id>: makes one scan with Windows' own scanner support (WIA) in a separate process, so the worker keeps
#    answering while a scanner is busy.
param([string]$Scan = '')
$root = if ($env:SP_ROOT) { $env:SP_ROOT } else { 'C:\ProgramData\MacPrint' }
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'sync.ps1')
$JPEG = '{B96B3CAE-0728-11D3-9D7B-0000F81EF32E}'

# ================================================================ scanners (WIA)
function Wia-Prop($props, [int]$id) { foreach ($p in $props) { if ($p.PropertyID -eq $id) { return $p } }; $null }
function Wia-Set($props, [int]$id, $val) { $p = Wia-Prop $props $id; if ($p) { try { $p.Value = $val } catch {} } }
function Find-Scanners {    # -> Sync\scanners.json: id, name, dpis, modes, sources (capabilities read once per device)
    $old = @{}; foreach ($d in Sp-Scanners) { $old[[string]$d.id] = $d }
    $out = @()
    try {
        $dm = New-Object -ComObject WIA.DeviceManager
        foreach ($di in @($dm.DeviceInfos)) {
            if ($di.Type -ne 1) { continue }      # 1 = scanner
            $id = [string]$di.DeviceID
            if ($old.ContainsKey($id)) { $out += $old[$id]; continue }
            $name = [string](Wia-Prop $di.Properties 7).Value; if (-not $name) { $name = 'Scanner' }
            $dpis = @(75, 150, 300, 600); $src = @('flatbed')
            try {
                $dev = $di.Connect(); $item = $dev.Items.Item(1); $r = Wia-Prop $item.Properties 6147
                if ($r) {
                    if ($r.SubType -eq 2) { $dpis = @($r.SubTypeValues | ForEach-Object { [int]$_ }) }
                    elseif ($r.SubType -eq 1) { $lo = [int]$r.SubTypeMin; $hi = [int]$r.SubTypeMax; $dpis = @(75, 100, 150, 200, 300, 400, 600, 1200 | Where-Object { $_ -ge $lo -and $_ -le $hi }) }
                }
                $cap = Wia-Prop $dev.Properties 3086          # document handling capabilities: 1 = feeder, 2 = glass
                if ($cap) { $v = [int]$cap.Value; $src = @(); if ($v -band 2) { $src += 'flatbed' }; if ($v -band 1) { $src += 'feeder' }; if (-not $src.Count) { $src = @('flatbed') } }
            } catch {}
            $dpis = @($dpis | Where-Object { $_ -ge 50 -and $_ -le 2400 }); if (-not $dpis.Count) { $dpis = @(150, 300) }
            $out += [ordered]@{ id = $id; name = $name; dpis = $dpis; modes = @('color', 'gray'); sources = $src }
        }
    } catch {}
    Sp-Write (Join-Path $SpSync 'scanners.json') @($out)
}
function To-Jpeg($img) {    # WIA image (any format) -> JPEG bytes
    if ($img.FormatID -ne $JPEG) {
        $ip = New-Object -ComObject WIA.ImageProcess
        $ip.Filters.Add($ip.FilterInfos.Item('Convert').FilterID)
        $ip.Filters.Item(1).Properties.Item('FormatID').Value = $JPEG
        $ip.Filters.Item(1).Properties.Item('Quality').Value = 85
        $img = $ip.Apply($img)
    }
    [byte[]]$img.FileData.BinaryData
}
function Do-Scan([string]$sid) {    # one scan, in its own process (syncd.ps1 -Scan <sid>)
    $j = Sp-ScanGet $sid; if (-not $j) { return }
    $q = $j.q; $dev = $null; $info = $null
    $lock = New-Object Threading.Mutex($false, ('Global\SchoolPrinterScan-' + ((Sp-Hmac 'scan' [string]$q.device).Substring(0, 12))))
    try {
        if (-not $lock.WaitOne(0)) { Sp-ScanSet $sid @{ state = 'waiting' }; [void]$lock.WaitOne() }    # one scan at a time per scanner
    } catch [Threading.AbandonedMutexException] {}
    try {
        Sp-ScanSet $sid @{ state = 'scanning' }
        $dm = New-Object -ComObject WIA.DeviceManager
        foreach ($di in @($dm.DeviceInfos)) { if ([string]$di.DeviceID -eq [string]$q.device) { $info = $di } }
        if (-not $info) { Sp-ScanSet $sid @{ state = 'failed'; err = 'NO_SCANNER' }; return }
        $dev = $info.Connect(); $feeder = $q.source -eq 'feeder'
        Wia-Set $dev.Properties 3088 $(if ($feeder) { 1 } else { 2 })      # document handling select: 1 feeder, 2 glass
        if ($feeder) { Wia-Set $dev.Properties 3096 1 }                     # pages: 1 at a time, repeated below
        $pages = New-Object Collections.ArrayList
        while ($true) {
            $item = $dev.Items.Item(1)
            Wia-Set $item.Properties 6147 ([int]$q.dpi); Wia-Set $item.Properties 6148 ([int]$q.dpi)
            Wia-Set $item.Properties 6146 $(if ($q.mode -eq 'gray') { 2 } else { 1 })    # intent: 1 colour, 2 grayscale
            foreach ($e in 6151, 6152) { $p = Wia-Prop $item.Properties $e; if ($p) { try { $p.Value = $p.SubTypeMax } catch {} } }    # whole glass
            try { $img = $item.Transfer($JPEG) }
            catch { if ($feeder -and $pages.Count) { break }; throw }    # feeder empty after the last page
            [void]$pages.Add((To-Jpeg $img))
            if (-not $feeder -or $pages.Count -ge 200) { break }
        }
        $ext = [string]$q.format
        if ($ext -eq 'pdf') { $data = Sp-JpegsPdf $pages ([int]$q.dpi) }
        elseif ($ext -eq 'png') {
            $msIn = New-Object IO.MemoryStream (, [byte[]]$pages[0]); $bmp = [System.Drawing.Image]::FromStream($msIn); $msOut = New-Object IO.MemoryStream
            $bmp.Save($msOut, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $msIn.Dispose(); $data = $msOut.ToArray()
        } else { $data = [byte[]]$pages[0] }
        [IO.File]::WriteAllBytes((Join-Path $SpScans "$sid.$ext"), $data)
        Sp-ScanSet $sid @{ state = 'ready'; ext = $ext; size = $data.Length; pages = $pages.Count }
    } catch {
        $m = $_.Exception.Message
        Sp-ScanSet $sid @{ state = 'failed'; err = $(if ($q.source -eq 'feeder' -and $m -match '80210003|paper|empty') { 'FEEDER_EMPTY' } else { 'SCAN_FAILED' }); detail = $m }
    } finally { try { $lock.ReleaseMutex() } catch {}; $lock.Dispose() }
}
if ($Scan) { Do-Scan $Scan; exit }

# ================================================================ this station's status
$script:cpu = -1
function Self-Status {
    $c = Sp-Cfg; $pr = $c.printer; $caps = Sp-Caps $pr
    $p = if ($pr) { Get-Printer -Name $pr -EA SilentlyContinue } else { $null }
    $pst = if (-not $p) { 'Not found' } elseif ($p.WorkOffline) { 'Offline' } else { [string]$p.PrinterStatus }
    $spool = @(if ($p) { Get-PrintJob -PrinterName $pr -EA SilentlyContinue })
    $sheets = 0; foreach ($j in $spool) { $sheets += [math]::Max(1, [int]$j.TotalPages - [int]$j.PagesPrinted) }
    $inb = @(Get-ChildItem $SpInbox -Filter *.json -EA SilentlyContinue); foreach ($f in $inb) { $x = Sp-Read $f.FullName; $sheets += [math]::Max(1, [int]$x.sheets) }
    $load = 0; try { $load = [double](@(Get-CimInstance Win32_Processor -EA Stop | Measure-Object LoadPercentage -Average).Average) } catch {}
    $script:cpu = if ($script:cpu -lt 0) { $load } else { 0.6 * $script:cpu + 0.4 * $load }      # smoothed
    $os = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue
    $office = Sp-LocalOffice; $busy = @(Get-ChildItem $SpUp -File -EA SilentlyContinue | Where-Object { $_.Extension -in '.todo', '.doing' }).Count
    $open = $c.open -ne '0'; $u = Sp-Read (Join-Path $SpSync 'uptime.json')
    [ordered]@{ app = 'school-printer'; proto = 2; id = (Sp-NodeId); name = $env:COMPUTERNAME; station = (Sp-StationName $c); version = '1.7.0'
        open = $open; ready = ($open -and $pst -eq 'Normal'); accept = ($c.accept -ne '0'); printer = $pr; pstatus = $pst
        jobs = ($spool.Count + $inb.Count); queue = $sheets; color = [bool]$caps.color; duplex = [bool]$caps.duplex; papers = @($caps.papers)
        conv = [ordered]@{ ok = ($office -in 'office', 'lo'); kind = $office; busy = $busy; share = ($c.conv -ne '0') }
        cores = [Environment]::ProcessorCount; cpu = [int][math]::Round($script:cpu)
        memFree = $(if ($os) { [int]($os.FreePhysicalMemory / 1024) } else { 0 }); memTotal = $(if ($os) { [int]($os.TotalVisibleMemorySize / 1024) } else { 0 })
        url = (Sp-MyUrl); at = (Sp-Now); bw = (Bw-Now); up = $(if ($u) { [int]$u.blocks } else { 0 })
        hasPrinter = [bool]($pr -and $p); scanners = @(Sp-Scanners); lead = (Sp-Leader).id; domain = [string]$c.domain; domainAt = [int64]$c.domainAt }
}
function Uptime-Tick {    # running time in 5-minute blocks, kept across restarts (Sync\uptime.json)
    $f = Join-Path $SpSync 'uptime.json'; $u = Sp-Read $f; $now = Sp-Now
    $blocks = if ($u) { [int64]$u.blocks } else { 0 }; $part = if ($u) { [int64]$u.part } else { 0 }; $last = if ($u) { [int64]$u.last } else { 0 }
    $d = if ($last) { $now - $last } else { 0 }; if ($d -lt 0 -or $d -gt 120) { $d = 0 }       # was stopped in between: not counted
    $part += $d; while ($part -ge 300) { $part -= 300; $blocks++ }
    Sp-Write $f ([ordered]@{ blocks = $blocks; part = $part; last = $now })
}

# ================================================================ finding stations
function Find-Stations {    # -> Sync\peers.json (same password), Sync\others.json (School Printers with another password)
    $g = Sp-Group; if (-not $g) { return }
    $me = Sp-NodeId; $old = @{}; foreach ($x in Sp-Peers) { $old[[string]$x.id] = $x }
    $found = @{}; $gone = @{}; $others = 0
    $hosts = Sp-ScanOpen (Sp-ScanTargets)
    $calls = @(foreach ($h in $hosts) { $wc = New-Object Net.WebClient; @{ t = $h; wc = $wc; k = $wc.DownloadStringTaskAsync("http://$($h[0]):$($h[1])/sync/hello") } })
    if ($calls.Count) { try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($calls | ForEach-Object { $_.k }), 3000) } catch {} }
    foreach ($cl in $calls) {
        if ($cl.k.Status -ne 'RanToCompletion') { try { $cl.wc.CancelAsync() } catch {}; continue }
        $h = $null; try { $h = $cl.k.Result | ConvertFrom-Json } catch {}
        if (-not $h -or $h.app -ne 'school-printer' -or [string]$h.id -cnotmatch '^[0-9a-f]{32}$' -or $h.id -eq $me) { continue }
        if ([string]$h.gid -eq $g.gid) {
            if (-not (Sp-PinOk $g ([string]$h.id) ([string]$h.pk) ([string]$h.pkmac))) { continue }    # not who it claims to be: ignore
            $found[[string]$h.id] = [ordered]@{ id = [string]$h.id; url = "http://$($cl.t[0]):$($cl.t[1])"; pk = [string]$h.pk; station = ([string]$h.station -replace '[\x00-\x1f<>"\\]', ''); seen = (Sp-Now) }
        }
        else { $others++; $gone[[string]$h.id] = 1 }    # answered from another network: not ours any more
    }
    foreach ($id in $old.Keys) { if (-not $found.ContainsKey($id) -and -not $gone[$id] -and ((Sp-Now) - [int64]$old[$id].seen) -lt 600) { $found[$id] = $old[$id] } }    # missed one scan: keep 10 min
    $list = @($found.Values | Sort-Object { - [int64]$_.seen } | Select-Object -First ($SpMax - 1))
    Sp-Write (Join-Path $SpSync 'peers.json') $list
    Sp-Write (Join-Path $SpSync 'others.json') ([ordered]@{ n = $others; at = (Sp-Now) })
    foreach ($x in $list) { if (-not $old.ContainsKey([string]$x.id)) { [void](Sp-Peer $x '/sync/announce' $null $null 2000) } }    # new here: they look again at once
}
function Poll-Stations {    # every station's /sync/status at once -> Sync\st\<id>.json (or .err)
    $g = Sp-Group; if (-not $g) { return }
    $calls = @(foreach ($x in Sp-Peers) {    # encrypted POSTs, all at once
        $sl = $null; try { $sl = Sp-Seal $x '/sync/status' $null $null } catch {}
        if (-not $sl) { Sp-Write (Join-Path $SpSt "$($x.id).err") ([ordered]@{ at = (Sp-Now); err = 'UNREACHABLE' }); continue }
        $wc = New-Object Net.WebClient; foreach ($k in $sl.hdr.Keys) { $wc.Headers.Add($k, $sl.hdr[$k]) }
        @{ x = $x; wc = $wc; sl = $sl; k = $wc.UploadDataTaskAsync("$($x.url)/sync/status", 'POST', [byte[]]$sl.ct) } })
    if (-not $calls.Count) { return }
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($calls | ForEach-Object { $_.k }), 3500) } catch {}
    foreach ($cl in $calls) {
        $id = [string]$cl.x.id; $err = 'UNREACHABLE'
        if ($cl.k.Status -eq 'RanToCompletion') {
            $pl = $null; try { $pl = Sp-Unseal $cl.sl 200 ([byte[]]$cl.k.Result) ([string]$cl.wc.ResponseHeaders['X-Sync-Mac']) } catch {}
            $txt = if ($null -ne $pl) { $SpUtf8.GetString($pl) } else { '' }; $s = $null; try { $s = $txt | ConvertFrom-Json } catch {}
            if ($s -and [string]$s.id -eq $id) { [IO.File]::WriteAllText((Join-Path $SpSt "$id.json.tmp"), "{`"at`":$(Sp-Now),`"s`":$txt}", $SpUtf8); Move-Item (Join-Path $SpSt "$id.json.tmp") (Join-Path $SpSt "$id.json") -Force; continue }
            $err = 'BAD_REPLY'
        } elseif ($cl.k.Status -eq 'Faulted') {
            $ex = $cl.k.Exception; while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
            if ($ex -and $ex.Response -and [int]$ex.Response.StatusCode -eq 401) { $err = 'PASSWORD' }
        } else { try { $cl.wc.CancelAsync() } catch {} }
        Sp-Write (Join-Path $SpSt "$id.err") ([ordered]@{ at = (Sp-Now); err = $err })
    }
}

# ================================================================ one address: the main station
function Bw-Now { $h = Sp-Read (Join-Path $SpSync 'bw.json'); if (-not $h) { return 0 }; $v = @($h | Sort-Object { [double]$_ }); [double]$v[[math]::Floor(($v.Count - 1) / 2)] }
function Measure-Bw {    # fetch 1 MB from a random station; keep the last 5 results (the median goes into the status)
    $on = @(Sp-Stations | Where-Object { $_.online }); if (-not $on.Count) { return $false }
    $x = $on[(Get-Random -Maximum $on.Count)]
    $r = Sp-Peer $x '/sync/probe' $null $null 10000
    if ($r.code -ne 200 -or $r.bytes.Length -lt 1000000) { return $false }
    $mbps = [math]::Min(10000, $r.bytes.Length * 8 / 1e6 / [math]::Max(0.001, [double]$r.secs))    # the transfer only, not the decryption
    $f = Join-Path $SpSync 'bw.json'; $v = @(Sp-Read $f) | Where-Object { $null -ne $_ }; $v = @($v) + [math]::Round($mbps, 1); if ($v.Count -gt 5) { $v = $v[($v.Count - 5)..($v.Count - 1)] }
    Sp-Write $f @($v); $true
}
function Lead-Score($s) { $bw = [double]$s.bw; [math]::Log(1 + $bw, 2) * 2 + [math]::Max(1, [int]$s.cores) * (100 - [double]$s.cpu) / 100 + [math]::Min([double]$s.memFree, 8192) / 2048 }
function Elect {    # the main station, the same way on every station (see elect in schoolprinter.pl)
    $self = Sp-Self; if (-not $self) { return (Sp-NodeId) }
    $g = Sp-Group; $gid = if ($g) { [string]$g.gid } else { '' }
    $sha1 = [Security.Cryptography.SHA1]::Create()
    $c = @(@{ id = (Sp-NodeId); url = (Sp-MyUrl); s = $self })
    if ($g) { foreach ($x in @(Sp-Stations | Where-Object { $_.online })) { $c += @{ id = $x.id; url = $x.url; s = $x.s } } }
    foreach ($k in $c) {
        $k.score = Lead-Score $k.s; $k.rank = [int][math]::Floor($k.score * 2 + 0.5); $k.up = [int64]$k.s.up
        $k.lot = Sp-Hex ($sha1.ComputeHash($SpUtf8.GetBytes("$gid/$($k.id)")))
    }
    # equal (to half a point) -> most running time (5-minute blocks) -> a random pick every station makes the same way
    $order = { param($l) @($l | Sort-Object @{ e = { $_.rank }; Descending = $true }, @{ e = { $_.up }; Descending = $true }, @{ e = { $_.lot }; Descending = $false }) }
    $best = (& $order $c)[0]
    $votes = @{}; foreach ($k in $c) { $v = [string]$k.s.lead; $votes[$v] = [int]$votes[$v] + 1 }
    $keep = $null; $kv = 0
    foreach ($k in (& $order $c)) { $n = [int]$votes[$k.id]; if ($n -ge 2 -and $n -gt $kv) { $keep = $k; $kv = $n } }
    # a station joined (or this one did) in the last 90 seconds: a fresh election, the best station wins outright;
    # otherwise keep the main station most stations follow while it is not clearly worse (no flapping)
    $fresh = $false; $now = Sp-Now
    if ($now - $script:joinedAt -lt 90) { $fresh = $true }
    foreach ($k in $c) { if ($script:since.ContainsKey($k.id) -and $now - $script:since[$k.id] -lt 90) { $fresh = $true } }
    $l = if (-not $fresh -and $keep -and $keep.score -ge $best.score * 0.75) { $keep } else { $best }
    # every 5 minutes (the same 20 seconds on every station's clock) a review with live load: a main station that has
    # become busy (another program started) hands over to a station at least half a point better
    if ($now % 300 -lt 20 -and $best.rank -gt $l.rank) { $l = $best }
    $cur = Sp-Read (Join-Path $SpSync 'leader.json')
    if (-not $cur -or [string]$cur.id -ne $l.id -or [string]$cur.url -ne $l.url) { Sp-Write (Join-Path $SpSync 'leader.json') ([ordered]@{ id = $l.id; url = $l.url }) }
    $l.id
}
# who is online since when (seen from here): a station that (re)joins starts a fresh election
$script:since = @{}; $script:joinedAt = Sp-Now; $script:sinceGid = ''
function Track-Online {
    $g = Sp-Group; $gid = if ($g) { [string]$g.gid } else { '' }
    if ($gid -ne $script:sinceGid) { $script:since = @{}; $script:joinedAt = Sp-Now; $script:sinceGid = $gid }    # another network: everyone is new
    $on = @{}; if ($g) { foreach ($x in @(Sp-Stations | Where-Object { $_.online })) { $on[$x.id] = 1 } }
    foreach ($id in @($script:since.Keys)) { if (-not $on[$id]) { $script:since.Remove($id) } }
    foreach ($id in $on.Keys) { if (-not $script:since.ContainsKey($id)) { $script:since[$id] = Sp-Now } }
    $on.Count
}
# "this PC is now the main station": a pop-up on the signed-in user's screen (convert.ps1 shows Uploads\main.notice)
$script:otherLead = $true; $script:mainSince = 0
function Main-Notice([string]$lead, [int]$online) {
    if (-not (Sp-Group) -or $online -lt 1) { return }    # alone: every PC is its own main station, nothing to tell
    if ($lead -ne (Sp-NodeId)) { $script:otherLead = $true; $script:mainSince = 0; return }
    if (-not $script:mainSince) { $script:mainSince = Sp-Now }
    if ((Sp-Now) - $script:mainSince -lt 20) { return }    # settled for 20 seconds first (no pop-up while stations start up)
    if (-not $script:otherLead) { return }    # still the same turn as main station (a station flickered): no second pop-up
    $script:otherLead = $false
    if ($env:SP_NOPOPUP) { return }
    try { Sp-Write (Join-Path $SpUp 'main.notice') ([ordered]@{ at = (Sp-Now); lang = [string](Sp-Cfg).lang; url = (Sp-MyUrl) }) } catch {}
}
$script:aliasOn = $false
function Alias([bool]$on) {    # schoolprinter.local -> this PC while it is the main station (mDNS, Windows 10 1809+)
    if ($env:SP_NOMDNS) { return }    # simulation (Test-SchoolPrinter.ps1): stay off the real network
    try {
        if (-not ('SpAlias' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class SpAlias {
    public delegate void Done(uint status, IntPtr ctx, IntPtr instance);
    [StructLayout(LayoutKind.Sequential)] public struct Req {
        public uint Version; public uint InterfaceIndex; public IntPtr pServiceInstance; public Done pRegisterCompletionCallback;
        public IntPtr pQueryContext; public IntPtr hCredentials; public int unicastEnabled; }
    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)] static extern IntPtr DnsServiceConstructInstance(string name, string host,
        IntPtr ip4, IntPtr ip6, ushort port, ushort prio, ushort weight, uint count, string[] keys, string[] values);
    [DllImport("dnsapi.dll")] static extern uint DnsServiceRegister(IntPtr req, IntPtr cancel);
    [DllImport("dnsapi.dll")] static extern uint DnsServiceDeRegister(IntPtr req, IntPtr cancel);
    static Done keep = (s, c, i) => { }; static IntPtr reqMem = IntPtr.Zero; static IntPtr ipMem = IntPtr.Zero;
    public static uint On(string name, string host, byte[] ip, ushort port) {
        if (reqMem != IntPtr.Zero) return 0;
        ipMem = Marshal.AllocHGlobal(4); Marshal.Copy(ip, 0, ipMem, 4);
        IntPtr inst = DnsServiceConstructInstance(name, host, ipMem, IntPtr.Zero, port, 0, 0, 1, new string[] { "path" }, new string[] { "/" });
        Req r = new Req(); r.Version = 1; r.pServiceInstance = inst; r.pRegisterCompletionCallback = keep;
        reqMem = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Req))); Marshal.StructureToPtr(r, reqMem, false);
        return DnsServiceRegister(reqMem, IntPtr.Zero);
    }
    public static uint Off() { if (reqMem == IntPtr.Zero) return 0; uint r = DnsServiceDeRegister(reqMem, IntPtr.Zero); reqMem = IntPtr.Zero; return r; }
}
'@
        }
        if ($on -and -not $script:aliasOn) {
            $ip = ([uri](Sp-MyUrl)).Host; $b = ([Net.IPAddress]::Parse($ip)).GetAddressBytes()
            [void][SpAlias]::On("School Printer (web)._http._tcp.local", $SpAlias, $b, [uint16]$SpPort); $script:aliasOn = $true
        } elseif (-not $on -and $script:aliasOn) { [void][SpAlias]::Off(); $script:aliasOn = $false }
    } catch {}
}

# ================================================================ jobs going to other stations (Outbox\<station id>~<name>) and failover
function Reroute($j, [string]$why) {    # print a job again from its held copy: on the best other printer, else here; else it failed
    $jid = [string]$j.jid
    $doc = Get-ChildItem $SpHeld -Filter "$jid.*" -EA SilentlyContinue | Where-Object { $_.Extension -ne '.json' } | Select-Object -First 1
    $h = Sp-Read (Join-Path $SpHeld "$jid.json")
    if (-not $doc -or -not $h) { Sp-JobSet $jid @{ state = 'failed'; err = $why }; return }
    $tried = @(@($j.tried) + [string]$j.sid | Where-Object { $_ } | Select-Object -Unique)
    $b = Sp-Best @{ color = ($h.color -eq 'color'); duplex = ($h.duplex -ne 'off'); pw = $h.pw; ph = $h.ph } $tried
    if (-not $b) { Sp-JobSet $jid @{ state = 'failed'; err = $why; tried = $tried }; Sp-Unhold $jid; return }
    $c = Sp-Cfg; $job = Sp-Hash $h; $base = '{0}-{1}-from{2}-c{3}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), (Get-Random -Maximum 99999), $job.from, $job.copies
    $dir = $SpInbox; $pre = ''
    if (-not $b.here) { $dir = $SpOut; $pre = "$($b.x.id)~"; $job.picked = $false; $job.first = (Sp-Now) }
    else { if (-not (Sp-Caps $c.printer).color) { $job.color = 'gray' }; if (-not (Sp-Caps $c.printer).duplex) { $job.duplex = 'off' } }
    $job.file = "$pre$base$($doc.Extension)"
    Copy-Item -LiteralPath $doc.FullName -Destination (Join-Path $dir $job.file) -Force
    Sp-Write (Join-Path $dir "$pre$base.json") $job
    Sp-JobSet $jid @{ state = $(if ($b.here) { 'queued' } else { 'sending' }); station = $(if ($b.here) { Sp-StationName $c } else { $b.x.station }); sid = $(if ($b.here) { Sp-NodeId } else { $b.x.id })
                      moved = $true; why = $why; tried = $tried; rjid = ''; url = ''; at = (Sp-Now); lost = 0; errSince = 0 }
}
function Send-Outbox {
    foreach ($jf in @(Get-ChildItem $SpOut -Filter *.json -EA SilentlyContinue)) {
        $j = Sp-Read $jf.FullName; if (-not $j) { continue }
        $doc = Join-Path $SpOut ([string]$j.file); if (-not (Test-Path -LiteralPath $doc)) { Remove-Item -LiteralPath $jf.FullName -Force -EA SilentlyContinue; continue }
        $sid = $jf.Name.Split('~')[0]; $x = Sp-Stations | Where-Object { $_.id -eq $sid } | Select-Object -First 1
        $limit = if ($j.picked) { 120 } else { 6 }          # a picked printer: keep trying for 2 minutes
        $ok = $false
        if ($x -and $x.online) {
            $meta = [ordered]@{}; foreach ($k in 'copies', 'pages', 'paper', 'orientation', 'color', 'duplex', 'margins', 'scale', 'nup', 'land', 'pw', 'ph', 'name', 'sheets', 'from') { $meta[$k] = $j.$k }
            $meta.ext = [IO.Path]::GetExtension($doc).TrimStart('.')
            $r = Sp-Peer $x '/sync/job' $meta ([IO.File]::ReadAllBytes($doc)) 60000
            $a = if ($r.code -eq 200) { Sp-Json $r } else { $null }
            if ($a -and [string]$a.jid -cmatch '^[0-9a-f]{16}$') {
                $ok = $true
                Sp-JobSet ([string]$j.jid) @{ state = 'queued'; ahead = [int]$a.ahead; rjid = [string]$a.jid; url = $x.url }
                Sp-LogLine "$([IO.Path]::GetFileName($doc) -replace '^[^~]*~', '')  copies=$($j.copies)  exit=sent:$($x.station)"
                Remove-Item -LiteralPath $doc, $jf.FullName -Force -EA SilentlyContinue
            }
        }
        if (-not $ok -and ((Sp-Now) - [int64]$j.first) -ge $limit) {    # that station did not take it: the next best printer
            Remove-Item -LiteralPath $doc, $jf.FullName -Force -EA SilentlyContinue
            $rec = Sp-JobGet ([string]$j.jid); if ($rec) { Reroute $rec 'NOT_TAKEN' }
        }
    }
}
function Spool-Bad($sp, $p) {    # a printer or job that is stuck: error, offline, out of paper, jammed, waiting for someone
    ([string]$sp.JobStatus -match 'Error|Offline|PaperOut|Blocked|UserIntervention') -or ($p -and [string]$p.PrinterStatus -match 'Error|Offline|Paper|Jam|NotAvailable|NoToner|UserIntervention|DoorOpen') -or ($p -and $p.WorkOffline)
}
function Follow-Jobs {    # mirror jobs that went to another station; live "jobs ahead"; move jobs off printers and stations that fail
    $me = Sp-NodeId; $now = Sp-Now; $spool = $null; $c = $null; $prn = $null
    foreach ($f in @(Get-ChildItem $SpJobs -Filter *.json -EA SilentlyContinue)) {
        $j = Sp-Read $f.FullName; if (-not $j) { continue }
        $jid = [string]$j.jid
        if ($j.state -in 'done', 'failed') { if ($j.state -eq 'done') { Sp-Unhold $jid }; continue }
        if (($now - [int64]$j.at) -gt 1800) { continue }
        $held = [bool](Get-ChildItem $SpHeld -Filter "$jid.json" -EA SilentlyContinue)
        if ($j.rjid) {    # on another station
            $x = Sp-Stations | Where-Object { $_.id -eq [string]$j.sid } | Select-Object -First 1
            if (-not $x -or -not $x.online) {    # that station went quiet: give it 20 seconds, then print elsewhere
                if (-not [int64]$j.lost) { Sp-JobSet $jid @{ lost = $now } }
                elseif ($now - [int64]$j.lost -ge 20 -and $held) { Reroute $j 'STATION_LOST' }
                continue
            }
            if ([int64]$j.lost) { Sp-JobSet $jid @{ lost = 0 } }
            $r = Sp-Peer $x "/sync/job/$($j.rjid)" $null $null 4000; $q = if ($r.code -eq 200) { Sp-Json $r } else { $null }
            if (-not $q) { continue }
            if ($q.state -eq 'failed' -and $held) { Reroute $j $(if ($q.err -eq 'PRINTER_ERROR') { 'PRINTER_ERROR' } else { 'FAILED' }); continue }
            if ($q.state -in 'queued', 'printing', 'done', 'failed' -and ($q.state -ne $j.state -or [int]$q.ahead -ne [int]$j.ahead)) {
                Sp-JobSet $jid @{ state = [string]$q.state; ahead = [int]$q.ahead; err = [string]$q.err }
                if ($q.state -eq 'done') { Sp-Unhold $jid }
            }
            continue
        }
        if ([string]$j.sid -ne $me -or $j.state -notin 'queued', 'printing') { continue }
        if ($null -eq $spool) {
            if (-not $c) { $c = Sp-Cfg }
            $prn = if ($c.printer) { Get-Printer -Name $c.printer -EA SilentlyContinue } else { $null }
            $spool = @(if ($prn) { Get-PrintJob -PrinterName $c.printer -EA SilentlyContinue | Sort-Object Id })
        }
        if ($j.state -eq 'printing') {
            $tag = "[$($jid.Substring(0, 6))]"; $pos = -1
            for ($i = 0; $i -lt $spool.Count; $i++) { if ([string]$spool[$i].DocumentName -like "*$tag*") { $pos = $i; break } }
            if ($pos -lt 0) { Sp-JobSet $jid @{ state = 'done'; ahead = 0 }; Sp-Unhold $jid; continue }
            if (Spool-Bad $spool[$pos] $prn) {    # stuck at the printer for 45 seconds: cancel it here, print it elsewhere
                if (-not [int64]$j.errSince) { Sp-JobSet $jid @{ errSince = $now } }
                elseif ($now - [int64]$j.errSince -ge 45) {
                    try { $spool[$pos] | Remove-PrintJob -EA SilentlyContinue } catch {}
                    if ($held) { Reroute $j 'PRINTER_ERROR' } else { Sp-JobSet $jid @{ state = 'failed'; err = 'PRINTER_ERROR' } }
                }
                continue
            } elseif ([int64]$j.errSince) { Sp-JobSet $jid @{ errSince = 0 } }
            if ($pos -ne [int]$j.ahead) { Sp-JobSet $jid @{ ahead = $pos } }
        } else {    # waiting for the print engine here
            if (-not $prn -or $prn.WorkOffline -or [string]$prn.PrinterStatus -match 'Error|Offline|NotAvailable') {
                if (-not [int64]$j.errSince) { Sp-JobSet $jid @{ errSince = $now } }
                elseif ($now - [int64]$j.errSince -ge 45 -and $held) {
                    Get-ChildItem $SpInbox -Filter *.json -EA SilentlyContinue | Where-Object { (Sp-Read $_.FullName).jid -eq $jid } | ForEach-Object {
                        $d = Join-Path $SpInbox ([string](Sp-Read $_.FullName).file); Remove-Item -LiteralPath $_.FullName, $d -Force -EA SilentlyContinue }
                    Reroute $j 'PRINTER_ERROR'
                }
                continue
            }
            $ahead = $spool.Count + @(Get-ChildItem $SpInbox -Filter *.json -EA SilentlyContinue | Where-Object { $_.LastWriteTime -lt $f.CreationTime }).Count
            if ($ahead -ne [int]$j.ahead) { Sp-JobSet $jid @{ ahead = $ahead } }
        }
    }
}

# ================================================================ Office files converted on another station
function Remote-Convert {
    $c = Sp-Cfg
    foreach ($f in @(Get-ChildItem $SpUp -Filter *.remote -EA SilentlyContinue)) {    # <id>.remote = "<station id> <ext>"
        $id = $f.BaseName; $a = ([IO.File]::ReadAllText($f.FullName)).Trim().Split(' '); $ext = $a[1]
        $x = Sp-Stations | Where-Object { $_.id -eq $a[0] -and $_.online } | Select-Object -First 1
        $src = Join-Path $SpUp "$id.$ext"; $r = $null
        if ($x -and (Test-Path $src)) { $r = Sp-Peer $x '/sync/convert' @{ ext = $ext } ([IO.File]::ReadAllBytes($src)) 60000 }
        $q = if ($r -and $r.code -eq 200) { Sp-Json $r } else { $null }
        if ($q -and [string]$q.rid -cmatch '^[0-9a-f]{32}$') { [IO.File]::WriteAllText((Join-Path $SpUp "$id.rid"), "$($x.id) $($q.rid) $ext $(Sp-Now)") }
        else { Conv-Here $id $ext }
        Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue
    }
    foreach ($f in @(Get-ChildItem $SpUp -Filter *.rid -EA SilentlyContinue)) {    # <id>.rid = "<station id> <remote id> <ext> <since>"
        $id = $f.BaseName; $a = ([IO.File]::ReadAllText($f.FullName)).Trim().Split(' ')
        $x = Sp-Stations | Where-Object { $_.id -eq $a[0] } | Select-Object -First 1
        $r = if ($x) { Sp-Peer $x "/sync/converted/$($a[1])" $null $null 30000 } else { @{ code = 0 } }
        if ($r.code -eq 200 -and $r.bytes.Length -gt 4 -and $r.bytes[0] -eq 0x25 -and $r.bytes[1] -eq 0x50) {
            [IO.File]::WriteAllBytes((Join-Path $SpUp "$id.pdf.part"), $r.bytes); Move-Item (Join-Path $SpUp "$id.pdf.part") (Join-Path $SpUp "$id.pdf") -Force
            Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue
        } elseif ($r.code -in 404, 410, 401 -or ((Sp-Now) - [int64]$a[3]) -gt 150) { Conv-Here $id $a[2]; Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue }
    }
}
function Conv-Here($id, $ext) {    # convert here after all (convert.ps1), or tell the page it failed
    if ((Sp-LocalOffice) -in 'office', 'lo') { [IO.File]::WriteAllText((Join-Path $SpUp "$id.todo"), $ext) }
    else { [IO.File]::WriteAllText((Join-Path $SpUp "$id.fail"), 'No computer could convert this file.') }
}

# ================================================================ scans requested here
function Run-Scans {
    $me = Sp-NodeId
    foreach ($f in @(Get-ChildItem $SpScans -Filter *.json -EA SilentlyContinue)) {
        $j = Sp-Read $f.FullName; if (-not $j -or $j.state -in 'ready', 'failed') { continue }
        $sid = [string]$j.sid
        if (-not $j.run) {
            if ([string]$j.target -eq $me) {    # the scanner is on this PC: scan in a separate process
                $pr = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Scan $sid"
                Sp-ScanSet $sid @{ run = 1; pid = $pr.Id }
            } else {
                $x = Sp-Stations | Where-Object { $_.id -eq [string]$j.target -and $_.online } | Select-Object -First 1
                if (-not $x) { Sp-ScanSet $sid @{ state = 'failed'; err = 'STATION_OFFLINE'; run = 1 }; continue }
                $r = Sp-Peer $x '/sync/scan' $j.q $null 10000
                $a = if ($r.code -eq 200) { Sp-Json $r } else { $null }
                if ($a -and [string]$a.sid -cmatch '^[0-9a-f]{16}$') { Sp-ScanSet $sid @{ run = 1; rsid = [string]$a.sid; url = $x.url } }
                else { $e = Sp-Json $r; Sp-ScanSet $sid @{ state = 'failed'; err = $(if ($e -and $e.error) { [string]$e.error } else { 'SCAN_FAILED' }); run = 1 } }
            }
            continue
        }
        if ($j.pid -and -not (Get-Process -Id ([int]$j.pid) -EA SilentlyContinue)) { $k = Sp-ScanGet $sid; if ($k.state -notin 'ready', 'failed') { Sp-ScanSet $sid @{ state = 'failed'; err = 'SCAN_FAILED' } }; continue }    # scan process died
        if ($j.rsid) {    # scanning on another station: follow it, then fetch the file
            $x = Sp-Stations | Where-Object { $_.id -eq [string]$j.target } | Select-Object -First 1
            if (-not $x -or -not $x.online) {    # the scanner's station went quiet in the middle: 20 seconds, then tell the page
                if (-not [int64]$j.lost) { Sp-ScanSet $sid @{ lost = (Sp-Now) } } elseif ((Sp-Now) - [int64]$j.lost -ge 20) { Sp-ScanSet $sid @{ state = 'failed'; err = 'STATION_LOST' } }
                continue
            }
            $r = Sp-Peer $x "/sync/scan/$($j.rsid)" $null $null 4000; $q = if ($r.code -eq 200) { Sp-Json $r } else { $null }
            if (-not $q) { if (((Sp-Now) - [int64]$j.at) -gt 900 -or $r.code -eq 404) { Sp-ScanSet $sid @{ state = 'failed'; err = 'SCAN_FAILED' } }; continue }
            if ($q.state -eq 'ready') {
                $d = Sp-Peer $x "/sync/scan/$($j.rsid)/file" $null $null 120000
                if ($d.code -eq 200 -and $d.bytes.Length) { [IO.File]::WriteAllBytes((Join-Path $SpScans "$sid.$($q.ext)"), $d.bytes); Sp-ScanSet $sid @{ state = 'ready'; ext = [string]$q.ext; size = $d.bytes.Length; pages = [int]$q.pages } }
                else { Sp-ScanSet $sid @{ state = 'failed'; err = 'SCAN_FAILED' } }
            } elseif ($q.state -eq 'failed') { Sp-ScanSet $sid @{ state = 'failed'; err = [string]$q.err } }
            elseif ($q.state -ne $j.state) { Sp-ScanSet $sid @{ state = [string]$q.state } }
        }
    }
}

function Adopt-Domain {    # the school address (e.g. print.school) is set on any station; the newest setting wins everywhere
    $c = Sp-Cfg; $best = $null
    foreach ($x in @(Sp-Stations | Where-Object { $_.online -and $null -ne $_.s.domainAt })) { if ([int64]$x.s.domainAt -gt [int64]$c.domainAt -and (-not $best -or [int64]$x.s.domainAt -gt [int64]$best.s.domainAt)) { $best = $x } }
    if ($best -and ([string]$best.s.domain -eq '' -or [string]$best.s.domain -match '^[a-z0-9.-]{3,253}$')) { $c.domain = [string]$best.s.domain; $c.domainAt = [string]$best.s.domainAt; Sp-SaveCfg $c }
}

# ================================================================ housekeeping
function Clean-Sync {
    $old = (Get-Date).AddDays(-1)
    Get-ChildItem $SpJobs, $SpSt -File -EA SilentlyContinue | Where-Object { $_.LastWriteTime -lt $old } | Remove-Item -Force -EA SilentlyContinue
    Get-ChildItem $SpScans -File -EA SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-30) } | Remove-Item -Force -EA SilentlyContinue
    Get-ChildItem (Join-Path $SpSync 'nonces') -File -EA SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) } | Remove-Item -Force -EA SilentlyContinue    # older than 5 minutes is refused anyway
    $ids = @{}; foreach ($x in Sp-Peers) { $ids[[string]$x.id] = 1 }
    Get-ChildItem $SpSt -File -EA SilentlyContinue | Where-Object { $_.BaseName -match '^([0-9a-f]{32})' -and -not $ids[$Matches[1]] } | Remove-Item -Force -EA SilentlyContinue
}

# ================================================================ main loop
$lastFind = [datetime]::MinValue; $started = Get-Date; $lastDet = [datetime]::MinValue; $lastBw = [datetime]::MinValue; $lastClean = Get-Date
while ($true) {
    $t0 = Get-Date
    try { Uptime-Tick } catch {}
    if (($t0 - $lastDet).TotalSeconds -ge 60) { $lastDet = $t0; try { Find-Scanners } catch {} }
    try { Sp-Write (Join-Path $SpSync 'self.json') (Self-Status) } catch {}
    if (Sp-Group) {
        $now = Join-Path $SpSync 'scan-now'
        $every = if (((Get-Date) - $started).TotalSeconds -lt 180) { 15 } else { 60 }    # the first 3 minutes: look often, stations start at different times
        if (($t0 - $lastFind).TotalSeconds -ge $every -or (Test-Path $now)) { Remove-Item $now -Force -EA SilentlyContinue; $lastFind = $t0; try { Find-Stations } catch {} }
        try { Poll-Stations } catch {}
        try { Adopt-Domain } catch {}
    }
    # right after the poll: a main station that just went quiet is replaced within one round (2-3 seconds)
    $online = 0; try { $online = Track-Online } catch {}
    $lead = (Sp-NodeId); try { $lead = Elect } catch {}
    Alias ($lead -eq (Sp-NodeId) -and [bool](Sp-Group))
    try { Main-Notice $lead $online } catch {}
    if (Sp-Group) {
        if (($t0 - $lastBw).TotalSeconds -ge 300) { $ok = $false; try { $ok = Measure-Bw } catch {}; $lastBw = if ($ok) { $t0 } else { $t0.AddSeconds(-280) } }    # failed: again in 20 s
    }
    try { Send-Outbox } catch {}
    try { Follow-Jobs } catch {}
    try { Remote-Convert } catch {}
    try { Run-Scans } catch {}
    if (((Get-Date) - $lastClean).TotalSeconds -ge 600) { $lastClean = Get-Date; try { Clean-Sync } catch {} }
    $n = @(Sp-Peers).Count; $iv = if ($n -gt 24) { 6 } elseif ($n -gt 10) { 4 } else { 2.5 }
    $left = $iv - ((Get-Date) - $t0).TotalSeconds; if ($left -gt 0) { Start-Sleep -Milliseconds ([int]($left * 1000)) }
}
