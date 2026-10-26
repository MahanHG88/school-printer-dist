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
function Sp-Sha256Hex([string]$s) { Sp-Hex ([Security.Cryptography.SHA256]::Create().ComputeHash($SpUtf8.GetBytes($s))) }
$SpPublicKey = Sp-Sha256Hex 'school-printer/public/1'    # the same everywhere: the public network
function Sp-Group {    # -> mode (public|private), key, gid; $null = this station works alone
    if (Test-Path (Join-Path $SpSync 'alone')) { return $null }
    $g = Sp-Read (Join-Path $SpSync 'group.json')
    if ($g -and [string]$g.mode -eq 'private' -and [string]$g.key -cmatch '^[0-9a-f]{64}$') { return [pscustomobject]@{ mode = 'private'; key = [string]$g.key; gid = [string]$g.gid } }
    [pscustomobject]@{ mode = 'public'; key = $SpPublicKey; gid = (Sp-Hmac $SpPublicKey 'group').Substring(0, 16) }
}
function Sp-SetNet([string]$mode, [string]$key) {    # public | private (with key) | alone; forget the old network's stations
    Remove-Item (Join-Path $SpSync 'peers.json'), (Join-Path $SpSync 'tokens.json') -Force -EA SilentlyContinue
    Get-ChildItem $SpSt -File -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
    if ($mode -eq 'alone') { [IO.File]::WriteAllText((Join-Path $SpSync 'alone'), '') } else { Remove-Item (Join-Path $SpSync 'alone') -Force -EA SilentlyContinue }
    if ($mode -eq 'private') { Sp-Write (Join-Path $SpSync 'group.json') ([ordered]@{ mode = 'private'; key = $key; gid = (Sp-Hmac $key 'group').Substring(0, 16); since = (Sp-Now) }) }
    else { Remove-Item (Join-Path $SpSync 'group.json') -Force -EA SilentlyContinue }
    [IO.File]::WriteAllText((Join-Path $SpSync 'scan-now'), '')
}

# ---- joining a private network with a one-time token (12 letters, e.g. K7QM-2XPD-9RTA; 15 minutes, works once).
# Same exchange as join_answer / join_network in schoolprinter.pl: the joining station never sends the token; it sends
# the token's id and a proof, and the issuer answers with the network key encrypted (HMAC-SHA256 counter-mode stream)
# and authenticated with keys made from the token - useless to anyone, in the middle or listening, without the token.
$SpTokChars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
function Sp-HmacRaw([byte[]]$key, [byte[]]$msg) { [Security.Cryptography.HMACSHA256]::new($key).ComputeHash($msg) }
function Sp-TokNorm([string]$t) { ($t.ToUpper() -replace '[^A-Z0-9]', '') }
function Sp-TokId([string]$t) { (Sp-Sha256Hex "school-printer/tid/$t").Substring(0, 16) }
function Sp-TokStream([byte[]]$k, [int]$n) {
    $o = New-Object IO.MemoryStream; $i = 0
    while ($o.Length -lt $n) { $c = [BitConverter]::GetBytes([uint32]$i); [Array]::Reverse($c); $b = Sp-HmacRaw $k $c; $o.Write($b, 0, $b.Length); $i++ }
    $r = $o.ToArray(); , $r[0..($n - 1)]
}
function Sp-TokKeys([string]$t, [string]$n1, [string]$n2) {
    $tk = [Text.Encoding]::ASCII.GetBytes($t)
    @{ enc = (Sp-HmacRaw $tk $SpUtf8.GetBytes("enc`n$n1`n$n2")); mac = (Sp-HmacRaw $tk $SpUtf8.GetBytes("mac`n$n1`n$n2")) }
}
function Sp-Xor([byte[]]$a, [byte[]]$b) { $o = New-Object byte[] $a.Length; for ($i = 0; $i -lt $a.Length; $i++) { $o[$i] = $a[$i] -bxor $b[$i] }; , $o }
function Sp-FromHex([string]$h) { $o = New-Object byte[] ($h.Length / 2); for ($i = 0; $i -lt $o.Length; $i++) { $o[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) }; , $o }
function Sp-TokNew {    # a member of a private network shows this on its admin page
    $g = Sp-Group; if (-not $g -or $g.mode -ne 'private') { return $null }
    $b = New-Object byte[] 12; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    $t = -join ($b | ForEach-Object { $SpTokChars[$_ % $SpTokChars.Length] })
    Sp-Write (Join-Path $SpSync 'tokens.json') ([ordered]@{ t = $t; until = (Sp-Now) + 900; tries = 0 }); $t
}
function Sp-TokGet { $x = Sp-Read (Join-Path $SpSync 'tokens.json'); if ($x -and [int64]$x.until -gt (Sp-Now)) { $x } else { $null } }
function Sp-JoinAnswer($q) {    # (issuer) -> @{ code; body }
    $tk = Sp-TokGet; $g = Sp-Group
    if (-not $tk -or -not $g -or $g.mode -ne 'private' -or [string]$q.tid -ne (Sp-TokId $tk.t)) { return @{ code = 404; body = @{ error = 'NO_TOKEN' } } }
    $id = [string]$q.id; $n1 = [string]$q.nonce
    if ($id -cnotmatch '^[0-9a-f]{32}$' -or $n1 -cnotmatch '^[0-9a-f]{32}$') { return @{ code = 400; body = @{ error = 'BAD' } } }
    if (-not (Sp-Same (Sp-Hmac $tk.t "join`n$id`n$n1") ([string]$q.proof))) {
        $tries = [int]$tk.tries + 1
        if ($tries -ge 5) { Remove-Item (Join-Path $SpSync 'tokens.json') -Force -EA SilentlyContinue } else { Sp-Write (Join-Path $SpSync 'tokens.json') ([ordered]@{ t = $tk.t; until = [int64]$tk.until; tries = $tries }) }
        return @{ code = 403; body = @{ error = 'TOKEN' } }
    }
    Remove-Item (Join-Path $SpSync 'tokens.json') -Force -EA SilentlyContinue    # works once
    $n2 = Sp-Rand 16; $k = Sp-TokKeys $tk.t $n1 $n2
    $plain = $SpUtf8.GetBytes((ConvertTo-Json -Compress -InputObject ([ordered]@{ key = $g.key; gid = $g.gid })))
    $ct = Sp-Hex (Sp-Xor $plain (Sp-TokStream $k.enc $plain.Length))
    @{ code = 200; body = [ordered]@{ nonce = $n2; ct = $ct; mac = (Sp-Hex (Sp-HmacRaw $k.mac ([Text.Encoding]::ASCII.GetBytes($ct)))) } }
}
function Sp-JoinNetwork([string]$token) {    # (joiner) ask every School Printer on this network for the token's network -> 'ok' | error code
    $t = Sp-TokNorm $token; if ($t.Length -ne 12) { return 'TOKEN_FORMAT' }
    $me = Sp-NodeId; $n1 = Sp-Rand 16
    $body = $SpUtf8.GetBytes((ConvertTo-Json -Compress -InputObject ([ordered]@{ tid = (Sp-TokId $t); id = $me; nonce = $n1; proof = (Sp-Hmac $t "join`n$me`n$n1") })))
    $open = Sp-ScanOpen (Sp-ScanTargets)    # one list object (not unrolled in a pipeline): walk it with foreach
    $urls = @(@(Sp-Peers | ForEach-Object { [string]$_.url }) + @(foreach ($h in $open) { "http://$($h[0]):$($h[1])" }) | Select-Object -Unique)
    $bad = 0
    foreach ($u in $urls) {
        if ($u -eq (Sp-MyUrl)) { continue }
        $r = Sp-Http $u 'POST' '/sync/join' @{ 'X-Join' = '1' } $body 4000
        if ($r.code -eq 403) { $bad++ }; if ($r.code -ne 200) { continue }
        $a = Sp-Json $r; if (-not $a -or [string]$a.nonce -cnotmatch '^[0-9a-f]{32}$' -or [string]$a.ct -cnotmatch '^([0-9a-f]{2})+$') { continue }
        $k = Sp-TokKeys $t $n1 ([string]$a.nonce)
        if (-not (Sp-Same (Sp-Hex (Sp-HmacRaw $k.mac ([Text.Encoding]::ASCII.GetBytes([string]$a.ct)))) ([string]$a.mac))) { continue }    # not from the token's network
        $ct = Sp-FromHex ([string]$a.ct); $x = $null; try { $x = $SpUtf8.GetString((Sp-Xor $ct (Sp-TokStream $k.enc $ct.Length))) | ConvertFrom-Json } catch {}
        if (-not $x -or [string]$x.key -cnotmatch '^[0-9a-f]{64}$') { continue }
        Sp-SetNet 'private' ([string]$x.key); return 'ok'
    }
    if ($bad) { 'TOKEN_WRONG' } else { 'TOKEN_NOT_FOUND' }
}

# ---- finding School Printers on this PC's networks (also used by syncd.ps1)
function Sp-ScanTargets {    # every address of this PC's networks (each at most a /22 = 1022 addresses)
    $t = New-Object Collections.ArrayList; $seen = @{}
    if ($env:SP_SCAN) { foreach ($x in $env:SP_SCAN.Split(',')) { $a = $x.Split(':'); [void]$t.Add(@($a[0], [int]$a[1])) }; return , $t }
    foreach ($ip in Sp-LanIPs) {
        $pre = [math]::Max(22, [int]$ip.PrefixLength); if ($pre -gt 30) { continue }
        $b = ([Net.IPAddress]::Parse($ip.IPAddress)).GetAddressBytes(); [Array]::Reverse($b); $n = [BitConverter]::ToUInt32($b, 0)
        $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $pre)); $net = $n -band $mask; $cnt = [math]::Pow(2, 32 - $pre)
        for ($k = 1; $k -lt $cnt - 1; $k++) {
            $v = [BitConverter]::GetBytes([uint32]($net + $k)); [Array]::Reverse($v); $a = ([Net.IPAddress]::new($v)).ToString()
            if ($a -ne $ip.IPAddress -and -not $seen[$a]) { $seen[$a] = 1; [void]$t.Add(@($a, $SpPort)) }
        }
    }
    , $t
}
function Sp-ScanOpen($targets) {    # connect to 256 addresses at a time -> the ones that answer
    $open = New-Object Collections.ArrayList
    for ($i = 0; $i -lt $targets.Count; $i += 256) {
        $items = @()
        foreach ($t in $targets[$i..([math]::Min($i + 255, $targets.Count - 1))]) { $cl = New-Object Net.Sockets.TcpClient; $items += @{ c = $cl; t = $t; k = $cl.ConnectAsync([string]$t[0], [int]$t[1]) } }
        try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($items | ForEach-Object { $_.k }), 1500) } catch {}
        foreach ($it in $items) { if ($it.k.Status -eq 'RanToCompletion' -and $it.c.Connected) { [void]$open.Add($it.t) }; try { $it.c.Close() } catch {} }
    }
    , $open
}
function Sp-Hmac([string]$key, [string]$msg) { $h = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::ASCII.GetBytes($key)); Sp-Hex ($h.ComputeHash($SpUtf8.GetBytes($msg))) }
function Sp-Derive([string]$pw) {    # (1.6.0 password networks; kept for the test vectors, no longer used)
    $h = [Security.Cryptography.HMACSHA256]::new($SpUtf8.GetBytes($pw))
    $x = $h.ComputeHash($SpUtf8.GetBytes('school-printer/1'))
    for ($i = 0; $i -lt 20000; $i++) { $x = $h.ComputeHash($x) }        # slow on purpose: makes guessing the password costly
    $key = Sp-Hex $x
    @{ key = $key; gid = (Sp-Hmac $key 'group').Substring(0, 16) }
}
function Sp-Same([string]$a, [string]$b) { if ($a.Length -ne $b.Length) { return $false }; $d = 0; for ($i = 0; $i -lt $a.Length; $i++) { $d = $d -bor ([int][char]$a[$i] -bxor [int][char]$b[$i]) }; $d -eq 0 }

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
        $ms = New-Object IO.MemoryStream; $st = $rs.GetResponseStream(); $sw = [Diagnostics.Stopwatch]::StartNew(); $st.CopyTo($ms); $st.Close()
        $code = [int]$rs.StatusCode; $mac = [string]$rs.Headers['X-Sync-Mac']; $rs.Close()
        @{ code = $code; bytes = $ms.ToArray(); mac = $mac; secs = $sw.Elapsed.TotalSeconds }    # secs: the answer's transfer only (speed test)
    } catch { @{ code = 0; bytes = $null } }
}
# ---------------------------------------------------------------- encryption between stations (protocol 2)
# Same as schoolprinter.pl: every station has a permanent Diffie-Hellman identity (RFC 3526 group 14, 2048 bit); two
# stations derive their own pair key from it and the network key; every /sync/* request and answer is encrypted
# (AES-256-CTR) and sealed (HMAC-SHA256 over the encrypted bytes, path, time and a one-use nonce), so nobody in the
# middle can read, change or replay it. Private network: the network key vouches for each identity. Public network:
# an identity is remembered on first contact and a change is refused and shown on the admin page.
if (-not ('SpCrypto' -as [type])) {
    $refs = if ($PSVersionTable.PSEdition -eq 'Core') { 'System.Runtime.Numerics', 'System.Security.Cryptography' } else { 'System.Numerics' }    # PowerShell 7 too
    Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System; using System.Numerics; using System.Globalization; using System.Security.Cryptography;
public static class SpCrypto {
    static readonly BigInteger P = BigInteger.Parse("00FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF", NumberStyles.HexNumber);
    static BigInteger FromHex(string h) { return BigInteger.Parse("0" + h, NumberStyles.HexNumber); }
    public static string Hex512(BigInteger v) {
        byte[] b = v.ToByteArray(); Array.Reverse(b);
        string h = BitConverter.ToString(b).Replace("-", "").ToLowerInvariant().TrimStart('0');
        return h.PadLeft(512, '0');
    }
    public static string Pub(string x) { return Hex512(BigInteger.ModPow(2, FromHex(x), P)); }
    public static string Shared(string pk, string x) { return Hex512(BigInteger.ModPow(FromHex(pk), FromHex(x), P)); }
    public static byte[] Ctr(byte[] key, byte[] iv, byte[] data) {    // AES-256-CTR, 128-bit big-endian counter (as openssl)
        byte[] o = new byte[data.Length]; if (data.Length == 0) return o;
        using (Aes a = Aes.Create()) {
            a.Mode = CipherMode.ECB; a.Padding = PaddingMode.None; a.Key = key;
            using (ICryptoTransform t = a.CreateEncryptor()) {
                byte[] ctr = (byte[])iv.Clone(); const int B = 4096; byte[] cin = new byte[B * 16]; byte[] ks = new byte[B * 16];
                for (int off = 0; off < data.Length; off += B * 16) {
                    int blocks = Math.Min(B, (data.Length - off + 15) / 16);
                    for (int i = 0; i < blocks; i++) { Buffer.BlockCopy(ctr, 0, cin, i * 16, 16); for (int j = 15; j >= 0; j--) { if (++ctr[j] != 0) break; } }
                    t.TransformBlock(cin, 0, blocks * 16, ks, 0);
                    int n = Math.Min(blocks * 16, data.Length - off);
                    for (int i = 0; i < n; i++) o[off + i] = (byte)(data[off + i] ^ ks[i]);
                }
            }
        }
        return o;
    }
}
'@
}
function Sp-Sha256([byte[]]$b) { [Security.Cryptography.SHA256]::Create().ComputeHash($b) }
function Sp-Cat([byte[]]$a, [byte[]]$b) { $o = New-Object byte[] ($a.Length + $b.Length); [Buffer]::BlockCopy($a, 0, $o, 0, $a.Length); [Buffer]::BlockCopy($b, 0, $o, $a.Length, $b.Length); , $o }
function Sp-Identity {    # -> secret hex, public key hex; made once (under a lock, so two processes never make two)
    $f = Join-Path $SpSync 'identity.json'; $i = Sp-Read $f
    if ($i -and [string]$i.x -cmatch '^[0-9a-f]{64}$' -and [string]$i.pk -cmatch '^[0-9a-f]{512}$') { return $i }
    Sp-Locked { $i = Sp-Read $f; if (-not ($i -and [string]$i.x -cmatch '^[0-9a-f]{64}$')) { $x = Sp-Rand 32; Sp-Write $f ([ordered]@{ x = $x; pk = [SpCrypto]::Pub($x) }) } }
    Sp-Read $f
}
function Sp-PkMac($g, [string]$id, [string]$pk) { Sp-Hmac $g.key "pk`n$id`n$pk" }
function Sp-PinOk($g, [string]$id, [string]$pk, [string]$mac) {    # is $pk really station $id?
    if ($id -cnotmatch '^[0-9a-f]{32}$' -or $pk -cnotmatch '^[0-9a-f]{512}$') { return $false }
    $vouched = $g.mode -eq 'private' -and (Sp-Same (Sp-PkMac $g $id $pk) $mac)
    if ($g.mode -eq 'private' -and -not $vouched) { return $false }
    $script:pinRes = $false
    Sp-Locked {
        $pf = Join-Path $SpSync 'pins.json'; $pins = Sp-Hash (Sp-Read $pf)
        if ([string]$pins[$id] -eq $pk) { $script:pinRes = $true }
        elseif (-not $pins[$id] -or $vouched) { $pins[$id] = $pk; Sp-Write $pf $pins; $script:pinRes = $true }
        else { $af = Join-Path $SpSync 'alerts.json'; $al = Sp-Hash (Sp-Read $af); $al[$id] = [ordered]@{ at = (Sp-Now); pk = $pk }; Sp-Write $af $al }    # public network, key changed
    }
    $script:pinRes
}
function Sp-PairKeys($g, [string]$id, [string]$pk) {    # -> @{ e; mk } shared with station $id
    $f = Join-Path $SpSync "pairs\$id.json"; $p = Sp-Read $f
    if ($p -and [string]$p.pk -eq $pk -and [string]$p.gid -eq $g.gid) { return @{ e = (Sp-FromHex $p.e); mk = (Sp-FromHex $p.m) } }
    $i = Sp-Identity; $z = Sp-FromHex ([SpCrypto]::Shared($pk, [string]$i.x))    # ~0.1 s
    $ids = @((Sp-NodeId), $id) | Sort-Object -CaseSensitive
    $m = Sp-HmacRaw ([Text.Encoding]::ASCII.GetBytes($g.key)) (Sp-Cat ($SpUtf8.GetBytes("pair`n$($ids[0])`n$($ids[1])`n")) (Sp-Sha256 $z))
    $e = Sp-HmacRaw $m ([Text.Encoding]::ASCII.GetBytes('enc')); $mk = Sp-HmacRaw $m ([Text.Encoding]::ASCII.GetBytes('mac'))
    New-Item -ItemType Directory (Join-Path $SpSync 'pairs') -Force | Out-Null
    Sp-Write $f ([ordered]@{ pk = $pk; gid = $g.gid; e = (Sp-Hex $e); m = (Sp-Hex $mk) })
    @{ e = $e; mk = $mk }
}
function Sp-Iv([byte[]]$mk, [string]$dir, [string]$n) { , (Sp-HmacRaw $mk $SpUtf8.GetBytes("iv`n$dir`n$n"))[0..15] }
function Sp-Envelope($meta, [byte[]]$payload) {
    $j = $SpUtf8.GetBytes((ConvertTo-Json -Compress -Depth 6 -InputObject $(if ($meta) { $meta } else { @{} })))
    $len = [BitConverter]::GetBytes([uint32]$j.Length); [Array]::Reverse($len)
    $o = Sp-Cat $len $j; if ($payload) { $o = Sp-Cat $o $payload }; , $o
}
function Sp-Unenvelope([byte[]]$p) {
    if ($p.Length -lt 4) { return @{ meta = $null; payload = (New-Object byte[] 0) } }
    $n = ([int]$p[0] -shl 24) -bor ([int]$p[1] -shl 16) -bor ([int]$p[2] -shl 8) -bor [int]$p[3]
    $meta = $null; try { $meta = $SpUtf8.GetString($p, 4, $n) | ConvertFrom-Json } catch {}
    $rest = New-Object byte[] ($p.Length - 4 - $n); [Buffer]::BlockCopy($p, 4 + $n, $rest, 0, $rest.Length)
    @{ meta = $meta; payload = $rest }
}
function Sp-Seal($x, [string]$path, $meta, [byte[]]$payload) {    # -> @{ ct; hdr; n; k } for a request to station $x (always POST)
    $g = Sp-Group; if (-not $g -or [string]$x.pk -cnotmatch '^[0-9a-f]{512}$') { return $null }
    $k = Sp-PairKeys $g ([string]$x.id) ([string]$x.pk); $i = Sp-Identity; $id = Sp-NodeId; $t = Sp-Now; $n = Sp-Rand 16
    $ct = [SpCrypto]::Ctr($k.e, (Sp-Iv $k.mk 'req' $n), (Sp-Envelope $meta $payload))
    @{ ct = $ct; n = $n; k = $k; hdr = [ordered]@{ 'X-Sync-Port' = "$SpPort"; 'X-Sync-Node' = $id; 'X-Sync-Time' = "$t"; 'X-Sync-Nonce' = $n; 'X-Sync-Pk' = [string]$i.pk; 'X-Sync-Pkmac' = (Sp-PkMac $g $id ([string]$i.pk))
        'X-Sync-Sig' = (Sp-Hex (Sp-HmacRaw $k.mk $SpUtf8.GetBytes("req`n$t`nPOST`n$path`n$id`n$n`n" + (Sp-Hex (Sp-Sha256 $ct))))) } }
}
function Sp-Unseal($sl, [int]$code, [byte[]]$body, [string]$mac) {    # answer -> plain bytes, or $null if not sealed by that station
    if (-not (Sp-Same (Sp-Hex (Sp-HmacRaw $sl.k.mk $SpUtf8.GetBytes("res`n$($sl.n)`n$code`n" + (Sp-Hex (Sp-Sha256 $body))))) $mac)) { return $null }
    , [SpCrypto]::Ctr($sl.k.e, (Sp-Iv $sl.k.mk 'res' $sl.n), $body)
}
function Sp-Peer($x, [string]$path, $meta, [byte[]]$payload, [int]$timeoutMs = 5000) {    # encrypted request to station $x -> @{ code; bytes }
    $sl = $null; try { $sl = Sp-Seal $x $path $meta $payload } catch {}; if (-not $sl) { return @{ code = 0; bytes = $null } }
    $r = Sp-Http ([string]$x.url) 'POST' $path $sl.hdr $sl.ct $timeoutMs
    if ($r.code -eq 0 -or $r.code -eq 401) { return @{ code = $r.code; bytes = $null } }
    $b = if ($r.bytes) { $r.bytes } else { New-Object byte[] 0 }
    $pl = Sp-Unseal $sl $r.code $b $r.mac; if ($null -eq $pl) { return @{ code = 0; bytes = $null } }
    @{ code = $r.code; bytes = [byte[]]$pl; secs = [double]$r.secs }
}
function Sp-Open($req, [byte[]]$body) {    # (server) a station's request -> @{ from; k; n; meta; payload } or $null
    $g = Sp-Group; if (-not $g) { return $null }
    $h = $req.Headers; $id = [string]$h['X-Sync-Node']; $t = [string]$h['X-Sync-Time']; $n = [string]$h['X-Sync-Nonce']; $sig = [string]$h['X-Sync-Sig']
    if ($id -cnotmatch '^[0-9a-f]{32}$' -or $t -notmatch '^\d{9,11}$' -or $n -cnotmatch '^[0-9a-f]{32}$' -or $sig -cnotmatch '^[0-9a-f]{64}$') { return $null }
    if ([math]::Abs((Sp-Now) - [int64]$t) -gt 300) { return $null }
    if (-not (Sp-PinOk $g $id ([string]$h['X-Sync-Pk']) ([string]$h['X-Sync-Pkmac']))) { return $null }
    $k = Sp-PairKeys $g $id ([string]$h['X-Sync-Pk'])
    $want = Sp-Hex (Sp-HmacRaw $k.mk $SpUtf8.GetBytes("req`n$t`n$($req.HttpMethod)`n$($req.Url.AbsolutePath)`n$id`n$n`n" + (Sp-Hex (Sp-Sha256 $body))))
    if (-not (Sp-Same $want $sig)) { return $null }
    $nd = Join-Path $SpSync 'nonces'; New-Item -ItemType Directory $nd -Force | Out-Null
    $nf = Join-Path $nd $n; if (Test-Path $nf) { return $null }; [IO.File]::WriteAllText($nf, '')    # each request counts once
    $e = Sp-Unenvelope ([SpCrypto]::Ctr($k.e, (Sp-Iv $k.mk 'req' $n), $body))
    @{ from = $id; k = $k; n = $n; meta = $e.meta; payload = $e.payload }
}
function Sp-SReply($res, $x, [int]$code, [byte[]]$data) {    # (server) encrypted, sealed answer
    if (-not $data) { $data = New-Object byte[] 0 }
    $ct = [SpCrypto]::Ctr($x.k.e, (Sp-Iv $x.k.mk 'res' $x.n), $data)
    $res.StatusCode = $code; $res.ContentType = 'application/octet-stream'; $res.Headers.Add('Cache-Control', 'no-store')
    $res.Headers.Add('X-Sync-Mac', (Sp-Hex (Sp-HmacRaw $x.k.mk $SpUtf8.GetBytes("res`n$($x.n)`n$code`n" + (Sp-Hex (Sp-Sha256 $ct))))))
    $res.ContentLength64 = $ct.Length; $res.OutputStream.Write($ct, 0, $ct.Length); $res.OutputStream.Close()
}
function Sp-SJson($res, $x, [int]$code, $obj) { Sp-SReply $res $x $code ($SpUtf8.GetBytes((ConvertTo-Json -Compress -Depth 8 -InputObject $obj))) }
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
        [pscustomobject]@{ id = [string]$x.id; url = [string]$x.url; pk = [string]$x.pk; station = $(if ($s -and $s.station) { [string]$s.station } else { [string]$x.station }); s = $s
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
    $tk = Sp-TokGet
    $names = @{}; foreach ($x in $rows) { $names[[string]$x.id] = [string]$x.station }
    $al = Sp-Hash (Sp-Read (Join-Path $SpSync 'alerts.json'))
    $alerts = @(foreach ($k in @($al.Keys | Sort-Object)) { if ((Sp-Now) - [int64]$al[$k].at -lt 86400) { [ordered]@{ id = $k; station = $(if ($names[$k]) { $names[$k] } else { $k.Substring(0, 8) }); at = [int64]$al[$k].at } } })
    [ordered]@{ ok = $true; joined = [bool]$g; alerts = $alerts; crypto = $true; mode = $(if ($g) { $g.mode } else { 'alone' }); token = $(if ($tk) { [string]$tk.t } else { '' }); tokenLeft = $(if ($tk) { [int64]$tk.until - (Sp-Now) } else { 0 })
                gid = $(if ($g) { [string]$g.gid } else { '' }); station = (Sp-StationName $c); share = ($c.share -ne '0'); accept = ($c.accept -ne '0')
                conv = ($c.conv -ne '0'); others = $(if ($g -and $o) { [int]$o.n } else { 0 }); lastScan = $last; search = $(if ($g) { Sp-Read (Join-Path $SpSync 'search.json') }); max = $SpMax; stations = $rows
                main = (Sp-Leader).id; alias = "http://$($SpAlias):$SpPort" }
}
