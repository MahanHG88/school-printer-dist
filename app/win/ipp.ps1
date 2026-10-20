# ipp.ps1 - School Printer: a real network printer (IPP) for "Add to this device" (dot-sourced by PrintServer.ps1)
#   Printer URI:  ipp://<this PC>:8631/ipp/print      (also http://<this PC>:8631/ipp/print)
# Devices add it like any driverless printer (macOS/Linux "IPP Everywhere", Windows "Microsoft IPP Class Driver"),
# then print from any app. They send PDF / JPEG / PNG; the job goes into the same Inbox as the web page's jobs and
# watch.ps1 prints it with the printer's own Windows driver. Announced on the network with mDNS (_ipp._tcp).
# If a PIN is set, the device must send it as the password (HTTP Basic, any user name).

$script:IppJobId = [int](Get-Date -UFormat %s) % 100000
$script:IppUuid = $null

# ---------------------------------------------------------------- IPP wire format (RFC 8010)
function Read-Ipp([byte[]]$b) {
    # [int] first: PowerShell keeps a byte a byte when shifting ([byte]0x8F -shl 8 = 0)
    function I32($o) { [int](([int]$b[$o] -shl 24) -bor ([int]$b[$o + 1] -shl 16) -bor ([int]$b[$o + 2] -shl 8) -bor [int]$b[$o + 3]) }
    function I16($o) { ([int]$b[$o] -shl 8) -bor [int]$b[$o + 1] }
    $r = @{ major = [int]$b[0]; minor = [int]$b[1]; op = (I16 2); id = (I32 4); a = @{}; mx = 0; my = 0; data = $null }
    $i = 8; $name = ''; $depth = 0; $member = ''
    while ($i -lt $b.Length) {
        $tag = $b[$i]; $i++
        if ($tag -eq 0x03) { break }
        if ($tag -le 0x0F) { continue }                                    # group delimiter
        $nl = I16 $i; $i += 2
        if ($nl -gt 0) { $name = [Text.Encoding]::UTF8.GetString($b, $i, $nl) }; $i += $nl
        $vl = I16 $i; $i += 2
        $vo = $i; $i += $vl
        if ($tag -eq 0x34) { $depth++; continue }                           # begCollection (e.g. media-col)
        if ($tag -eq 0x37) { $depth--; continue }                           # endCollection
        if ($tag -eq 0x4A) { $member = [Text.Encoding]::UTF8.GetString($b, $vo, $vl); continue }
        if ($depth -gt 0) {                                                  # only media-size from media-col
            if ($tag -eq 0x21 -and $member -eq 'x-dimension') { $r.mx = I32 $vo }
            if ($tag -eq 0x21 -and $member -eq 'y-dimension') { $r.my = I32 $vo }
            continue
        }
        $v = switch ($tag) {
            { $_ -in 0x21, 0x23 } { I32 $vo }
            0x22 { $b[$vo] -ne 0 }
            0x33 { , @((I32 $vo), (I32 ($vo + 4))) }
            default { [Text.Encoding]::UTF8.GetString($b, $vo, $vl) }
        }
        if (-not $r.a.ContainsKey($name)) { $r.a[$name] = New-Object System.Collections.ArrayList }
        [void]$r.a[$name].Add($v)
    }
    $n = $b.Length - $i; $r.data = New-Object byte[] ([math]::Max(0, $n)); if ($n -gt 0) { [Array]::Copy($b, $i, $r.data, 0, $n) }
    $r
}
function First($req, $name, $def) { if ($req.a.ContainsKey($name) -and $req.a[$name].Count) { $req.a[$name][0] } else { $def } }

$script:ippOut = $null
function W([byte[]]$x) { $script:ippOut.Write($x, 0, $x.Length) }
function W16([int]$n) { W ([byte[]]@((($n -shr 8) -band 255), ($n -band 255))) }   # each byte in its own ( ): ',' binds tighter than -band
function W32($n) { $n = [int64]$n; W ([byte[]]@((($n -shr 24) -band 255), (($n -shr 16) -band 255), (($n -shr 8) -band 255), ($n -band 255))) }
function A($tag, $name, $values) {    # one attribute, one or more values
    $first = $true
    foreach ($v in @($values)) {
        W ([byte[]]@($tag)); if ($first) { $nb = [Text.Encoding]::UTF8.GetBytes($name); W16 $nb.Length; W $nb; $first = $false } else { W16 0 }
        switch ($tag) {
            { $_ -in 0x21, 0x23 } { W16 4; W32 $v }
            0x22 { W16 1; W ([byte[]]@([int][bool]$v)) }
            0x33 { W16 8; W32 $v[0]; W32 $v[1] }
            0x32 { W16 9; W32 $v; W32 $v; W ([byte[]]@(3)) }               # resolution, dots per inch
            default { $vb = [Text.Encoding]::UTF8.GetBytes([string]$v); W16 $vb.Length; W $vb }
        }
    }
}
function MediaCol($name, $p, $hm) {    # one media-col collection: size in 1/100 mm + margins
    W ([byte[]]@(0x34)); $nb = [Text.Encoding]::UTF8.GetBytes($name); W16 $nb.Length; W $nb; W16 0
    Member 'media-size'; W ([byte[]]@(0x34)); W16 0; W16 0
    Member 'x-dimension'; W ([byte[]]@(0x21)); W16 0; W16 4; W32 ([int]([double]$p.w * 100))
    Member 'y-dimension'; W ([byte[]]@(0x21)); W16 0; W16 4; W32 ([int]([double]$p.h * 100))
    W ([byte[]]@(0x37)); W16 0; W16 0
    foreach ($side in 'bottom', 'left', 'right', 'top') { Member "media-$side-margin"; W ([byte[]]@(0x21)); W16 0; W16 4; W32 $hm }
    W ([byte[]]@(0x37)); W16 0; W16 0
}
function Member($m) { $mb = [Text.Encoding]::UTF8.GetBytes($m); W ([byte[]]@(0x4A)); W16 0; W16 $mb.Length; W $mb }
function Ipp-Begin($req, $status) {
    $script:ippOut = New-Object IO.MemoryStream
    $maj = if ($req.major -in 1, 2) { $req.major } else { 2 }; $min = if ($maj -eq 1) { 1 } else { 0 }
    W ([byte[]]@($maj, $min)); W16 $status; W32 $req.id      # answer in the version the client used
    W ([byte[]]@(0x01)); A 0x47 'attributes-charset' 'utf-8'; A 0x48 'attributes-natural-language' 'en'
}
function Ipp-End($res) {
    W ([byte[]]@(0x03))
    $bytes = $script:ippOut.ToArray()
    $res.StatusCode = 200; $res.ContentType = 'application/ipp'; $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length); $res.OutputStream.Close()
}
function Ipp-Error($res, $req, $status, $msg) { Ipp-Begin $req $status; A 0x41 'status-message' $msg; Ipp-End $res }

# ---------------------------------------------------------------- paper names <-> PWG media names
$PwgKnown = @{ 'letter' = 'na_letter_8.5x11in'; 'legal' = 'na_legal_8.5x14in'; 'a4' = 'iso_a4_210x297mm'; 'a5' = 'iso_a5_148x210mm'
    'a3' = 'iso_a3_297x420mm'; 'a6' = 'iso_a6_105x148mm'; 'b5 (jis)' = 'jis_b5_182x257mm'; 'executive' = 'na_executive_7.25x10.5in'
    'tabloid' = 'na_ledger_11x17in'; 'statement' = 'na_invoice_5.5x8.5in' }
function Pwg($p) {
    $k = $p.n.ToLower(); if ($PwgKnown[$k]) { return $PwgKnown[$k] }
    $slug = ($p.n.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'); if (-not $slug) { $slug = 'paper' }
    'custom_{0}_{1:0.##}x{2:0.##}mm' -f $slug, $p.w, $p.h
}
function Paper-From($req, $caps) {    # media keyword or media-col size (1/100 mm) -> printer paper name
    $wmm = 0; $hmm = 0
    if ($req.mx -gt 0) { $wmm = $req.mx / 100; $hmm = $req.my / 100 }
    else {
        $m = First $req 'media' ''
        foreach ($p in $caps.papers) { if ((Pwg $p) -eq $m) { return $p.n } }
        if ($m -match '_([\d.]+)x([\d.]+)(mm|in)$') { $f = if ($Matches[3] -eq 'in') { 25.4 } else { 1 }; $wmm = [double]$Matches[1] * $f; $hmm = [double]$Matches[2] * $f }
    }
    if ($wmm -gt 0) {
        $a = [math]::Min($wmm, $hmm); $b2 = [math]::Max($wmm, $hmm)
        foreach ($p in $caps.papers) { if ([math]::Abs($p.w - $a) -lt 2 -and [math]::Abs($p.h - $b2) -lt 2) { return $p.n } }
    }
    $caps.def
}

# ---------------------------------------------------------------- the printer
function Ipp-PrinterAttrs($c, $caps, $uri, $hostUrl) {
    $media = @($caps.papers | ForEach-Object { Pwg $_ }); if (-not $media.Count) { $media = @('iso_a4_210x297mm') }
    $def = ($caps.papers | Where-Object { $_.n -eq $caps.def } | Select-Object -First 1); $mdef = if ($def) { Pwg $def } else { $media[0] }
    $hm = 0   # report no unprintable edge: the print engine fits pages inside the real one (caps.hm); reporting it
              # here too made macOS shrink pages first and the engine shrink them again
    $open = $c.open -ne '0'
    W ([byte[]]@(0x04))
    A 0x45 'printer-uri-supported' $uri
    A 0x44 'uri-security-supported' 'none'
    A 0x44 'uri-authentication-supported' $(if ($c.pin) { 'basic' } else { 'none' })
    A 0x42 'printer-name' 'School Printer'
    A 0x41 'printer-info' "School Printer - $($c.printer)"
    A 0x41 'printer-location' $env:COMPUTERNAME
    A 0x41 'printer-make-and-model' "School Printer ($($c.printer))"
    A 0x45 'printer-more-info' $hostUrl
    A 0x45 'printer-uuid' "urn:uuid:$($script:IppUuid)"
    A 0x41 'printer-device-id' "MFG:School Printer;MDL:$($c.printer -replace '[;:]', ' ');CMD:PDF,JPEG,PNG;"
    A 0x23 'printer-state' $(if ($open) { 3 } else { 5 })
    A 0x44 'printer-state-reasons' $(if ($open) { 'none' } else { 'paused' })
    A 0x22 'printer-is-accepting-jobs' $open
    A 0x21 'queued-job-count' 0
    A 0x21 'printer-up-time' ([int]([Environment]::TickCount / 1000))
    A 0x44 'ipp-versions-supported' @('1.1', '2.0')
    A 0x23 'operations-supported' @(0x0002, 0x0004, 0x0008, 0x0009, 0x000A, 0x000B)
    A 0x47 'charset-configured' 'utf-8'; A 0x47 'charset-supported' 'utf-8'
    A 0x48 'natural-language-configured' 'en'; A 0x48 'generated-natural-language-supported' 'en'
    A 0x49 'document-format-default' 'application/pdf'
    A 0x49 'document-format-supported' @('application/pdf', 'image/jpeg', 'image/png', 'application/octet-stream')
    A 0x44 'compression-supported' 'none'
    A 0x44 'pdl-override-supported' 'attempted'
    A 0x44 'printer-kind' @('document', 'photo')
    # Copies: Windows sends a count or writes the copies into the PDF; macOS never sends one to a driverless queue, so
    # add.sh sets *cupsManualCopies: True and macOS's own PDF converter writes the copies into the PDF.
    A 0x21 'copies-default' 1; A 0x33 'copies-supported' (, @(1, 20))
    A 0x23 'finishings-default' 3; A 0x23 'finishings-supported' 3
    A 0x44 'media-default' $mdef; A 0x44 'media-supported' $media; A 0x44 'media-ready' $mdef
    $dp = if ($def) { $def } else { @{ w = 210; h = 297 } }
    MediaCol 'media-col-default' $dp $hm
    MediaCol 'media-col-ready' $dp $hm
    $firstCol = $true
    foreach ($p in $caps.papers) { MediaCol $(if ($firstCol) { 'media-col-database' } else { '' }) $p $hm; $firstCol = $false }
    A 0x44 'media-col-supported' @('media-size', 'media-bottom-margin', 'media-left-margin', 'media-right-margin', 'media-top-margin')
    A 0x21 'media-bottom-margin-supported' $hm; A 0x21 'media-top-margin-supported' $hm
    A 0x21 'media-left-margin-supported' $hm; A 0x21 'media-right-margin-supported' $hm
    A 0x23 'orientation-requested-default' 3; A 0x23 'orientation-requested-supported' @(3, 4)
    A 0x44 'print-color-mode-default' $(if ($caps.color) { 'color' } else { 'monochrome' })
    A 0x44 'print-color-mode-supported' $(if ($caps.color) { @('monochrome', 'color') } else { @('monochrome') })
    A 0x22 'color-supported' ([bool]$caps.color)
    A 0x44 'sides-default' 'one-sided'
    A 0x44 'sides-supported' $(if ($caps.duplex) { @('one-sided', 'two-sided-long-edge', 'two-sided-short-edge') } else { @('one-sided') })
    A 0x44 'print-scaling-default' 'fit'; A 0x44 'print-scaling-supported' @('auto', 'fit', 'none')
    A 0x23 'print-quality-default' 4; A 0x23 'print-quality-supported' 4
    A 0x32 'printer-resolution-default' 300; A 0x32 'printer-resolution-supported' 300
    A 0x22 'page-ranges-supported' $false
    A 0x21 'number-up-default' 1; A 0x21 'number-up-supported' 1
    A 0x44 'job-creation-attributes-supported' @('copies', 'media', 'media-col', 'orientation-requested', 'print-color-mode', 'print-scaling', 'sides')
    A 0x44 'multiple-document-handling-supported' 'separate-documents-uncollated-copies'
    A 0x44 'which-jobs-supported' @('completed', 'not-completed')
}
function Ipp-Handle($ctx, $c, $caps) {
    $req = $ctx.Request; $res = $ctx.Response
    $ms = New-Object IO.MemoryStream; $buf = New-Object byte[] 65536; $total = 0
    while (($n = $req.InputStream.Read($buf, 0, $buf.Length)) -gt 0) { $total += $n; if ($total -gt 52MB) { break }; $ms.Write($buf, 0, $n) }
    $body = $ms.ToArray()
    if ($body.Length -lt 9) { $res.StatusCode = 400; $res.OutputStream.Close(); return }
    $r = Read-Ipp $body
    # PIN = HTTP Basic password (any user name), asked only when printing: a device must be able to read the
    # printer's details to add it before anyone has typed the PIN.
    if ($c.pin -and $r.op -in 0x0002, 0x0004) {
        $ok = $false; $h = [string]$req.Headers['Authorization']
        if ($h -match '^Basic\s+(.+)$') { try { $up = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])); $ok = ($up -replace '^[^:]*:', '') -eq $c.pin } catch {} }
        if (-not $ok) { $res.StatusCode = 401; $res.Headers.Add('WWW-Authenticate', 'Basic realm="School Printer"'); $res.ContentLength64 = 0; $res.OutputStream.Close(); return }
    }
    $hostPort = $req.Url.Authority
    $uri = "ipp://$hostPort/ipp/print"; $hostUrl = "http://$hostPort/"
    switch ($r.op) {
        0x000B {    # Get-Printer-Attributes
            Ipp-Begin $r 0; Ipp-PrinterAttrs $c $caps $uri $hostUrl; Ipp-End $res
        }
        0x0004 {    # Validate-Job
            if ($c.open -eq '0') { Ipp-Error $res $r 0x0506 'Printing is closed right now.' } else { Ipp-Begin $r 0; Ipp-End $res }
        }
        0x0002 {    # Print-Job
            if ($c.open -eq '0') { Ipp-Error $res $r 0x0506 'Printing is closed right now.'; return }
            if ($total -gt 50MB) { Ipp-Error $res $r 0x0409 'File is bigger than 50 MB.'; return }
            $d = $r.data; $ext = ''
            if ($d.Length -ge 4 -and $d[0] -eq 0x25 -and $d[1] -eq 0x50 -and $d[2] -eq 0x44 -and $d[3] -eq 0x46) { $ext = 'pdf' }
            elseif ($d.Length -ge 4 -and $d[0] -eq 0x89 -and $d[1] -eq 0x50 -and $d[2] -eq 0x4E -and $d[3] -eq 0x47) { $ext = 'png' }
            elseif ($d.Length -ge 2 -and $d[0] -eq 0xFF -and $d[1] -eq 0xD8) { $ext = 'jpg' }
            if (-not $ext) { Ipp-Error $res $r 0x040A 'Send PDF, JPEG or PNG.'; return }
            $copies = [math]::Min([math]::Max([int](First $r 'copies' 1), 1), 20)
            $sides = First $r 'sides' 'one-sided'
            $duplex = if ($caps.duplex) { switch ($sides) { 'two-sided-long-edge' { 'long' } 'two-sided-short-edge' { 'short' } default { 'off' } } } else { 'off' }
            $o = [int](First $r 'orientation-requested' 0)
            $orient = if ($o -eq 3) { 'portrait' } elseif ($o -in 4, 5) { 'landscape' } else { 'auto' }
            $cm = First $r 'print-color-mode' 'auto'
            $color = if ($caps.color -and $cm -notmatch 'monochrome') { 'color' } else { 'gray' }
            $scale = if ((First $r 'print-scaling' 'fit') -eq 'none') { 'actual' } else { 'fit' }
            $jobName = [string](First $r 'job-name' 'Document'); $user = [string](First $r 'requesting-user-name' '')
            $from = $req.RemoteEndPoint.Address.ToString() -replace '[^0-9A-Fa-f.]', '_'
            $stamp = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), (Get-Random -Maximum 99999)
            $base = "$stamp-from$from-c$copies"
            [IO.File]::WriteAllBytes((Join-Path $inbox "$base.$ext.part"), $d)
            Move-Item (Join-Path $inbox "$base.$ext.part") (Join-Path $inbox "$base.$ext")
            $job = @{ file = "$base.$ext"; name = "$jobName (from $(if ($user) { $user } else { $from }))"; copies = $copies; pages = ''; paper = (Paper-From $r $caps)
                      orientation = $orient; color = $color; duplex = $duplex; margins = 'none'; scale = $scale; nup = 1; hm = $caps.hm; via = 'ipp' }
            [IO.File]::WriteAllText((Join-Path $inbox "$base.tmp"), (ConvertTo-Json -Compress $job), [Text.Encoding]::UTF8)
            Move-Item (Join-Path $inbox "$base.tmp") (Join-Path $inbox "$base.json")
            $script:IppJobId++
            Ipp-Begin $r 0
            W ([byte[]]@(0x02))
            A 0x21 'job-id' $script:IppJobId; A 0x45 'job-uri' "$uri/$($script:IppJobId)"
            A 0x23 'job-state' 9; A 0x44 'job-state-reasons' 'job-completed-successfully'
            Ipp-End $res
        }
        0x0009 {    # Get-Job-Attributes: jobs are handed to the print engine at once
            Ipp-Begin $r 0; W ([byte[]]@(0x02))
            $jid = [int](First $r 'job-id' 0); A 0x21 'job-id' $jid; A 0x45 'job-uri' "$uri/$jid"
            A 0x23 'job-state' 9; A 0x44 'job-state-reasons' 'job-completed-successfully'; Ipp-End $res
        }
        0x000A { Ipp-Begin $r 0; Ipp-End $res }                  # Get-Jobs: none kept here
        0x0008 { Ipp-Begin $r 0; Ipp-End $res }                  # Cancel-Job: accepted (already queued)
        default { Ipp-Error $res $r 0x0501 'Operation not supported.' }
    }
}

# ---------------------------------------------------------------- mDNS (_ipp._tcp) announcement, Windows 10 1809+ dnsapi
function Ipp-Announce($c, $caps, $port) {
    $uuidFile = Join-Path $root 'printer-uuid.txt'
    if (-not (Test-Path $uuidFile)) { [IO.File]::WriteAllText($uuidFile, [guid]::NewGuid().ToString()) }
    $script:IppUuid = ([IO.File]::ReadAllText($uuidFile)).Trim()
    try {
        if (-not ('SpMdns' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class SpMdns {
    public delegate void Done(uint status, IntPtr ctx, IntPtr instance);
    [StructLayout(LayoutKind.Sequential)] public struct Req {
        public uint Version; public uint InterfaceIndex; public IntPtr pServiceInstance; public Done pRegisterCompletionCallback;
        public IntPtr pQueryContext; public IntPtr hCredentials; public int unicastEnabled; }
    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)] static extern IntPtr DnsServiceConstructInstance(string name, string host,
        IntPtr ip4, IntPtr ip6, ushort port, ushort prio, ushort weight, uint count, string[] keys, string[] values);
    [DllImport("dnsapi.dll")] static extern uint DnsServiceRegister(IntPtr req, IntPtr cancel);
    static Done keep; static IntPtr reqMem;
    public static uint Status = 0;
    public static uint Register(string name, string host, ushort port, string[] keys, string[] values) {
        IntPtr inst = DnsServiceConstructInstance(name, host, IntPtr.Zero, IntPtr.Zero, port, 0, 0, (uint)keys.Length, keys, values);
        keep = (s, c, i) => { Status = s; };
        Req r = new Req(); r.Version = 1; r.pServiceInstance = inst; r.pRegisterCompletionCallback = keep;
        reqMem = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Req))); Marshal.StructureToPtr(r, reqMem, false);
        return DnsServiceRegister(reqMem, IntPtr.Zero);    // 9506 = DNS_REQUEST_PENDING = accepted
    }
}
'@
        }
        $keys = @('txtvers', 'qtotal', 'rp', 'ty', 'product', 'pdl', 'Color', 'Duplex', 'UUID', 'note', 'adminurl', 'priority')
        $vals = @('1', '1', 'ipp/print', "School Printer ($($c.printer))", '(School Printer)', 'application/pdf,image/jpeg,image/png',
                  $(if ($caps.color) { 'T' } else { 'F' }), $(if ($caps.duplex) { 'T' } else { 'F' }), $script:IppUuid, $env:COMPUTERNAME,
                  "http://$($env:COMPUTERNAME).local:$port/", '50')
        $rv = [SpMdns]::Register("School Printer._ipp._tcp.local", "$($env:COMPUTERNAME).local", [uint16]$port, [string[]]$keys, [string[]]$vals)
        "mDNS register: $rv"
    } catch { "mDNS register failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- "Add to this device" helper for macOS / Linux
function Ipp-AddScript($hostPort) {
@"
#!/bin/bash
# School Printer - add the printer at $hostPort to this Mac (or Linux computer) so every app can print to it.
# Uses the system's own driverless "IPP Everywhere" driver; nothing else is installed.
set -e
URI="ipp://$hostPort/ipp/print"; Q="School_Printer"
B=`$'\e[1m'; G=`$'\e[38;5;42m'; D=`$'\e[2m'; R=`$'\e[0m'
printf '\n  %sSchool Printer%s  %sadding %s%s\n' "`$B" "`$R" "`$D" "`$URI" "`$R"
add() { lpadmin -p "`$Q" -D "School Printer" -L "$hostPort" -E -v "`$URI" -m everywhere "`$@"; }
if ! add 2>/dev/null; then echo "  Your password is needed to add a printer:"; sudo -p "  Password: " lpadmin -p "`$Q" -D "School Printer" -L "$hostPort" -E -v "`$URI" -m everywhere; fi
if [ "`$(uname -s)" = Darwin ]; then
    # macOS never sends a copies count to a driverless printer and silently prints one copy; with
    # cupsManualCopies True its own PDF converter writes the copies into the job instead (tested 2026-10-20)
    P="/etc/cups/ppd/`$Q.ppd"; T="`$(mktemp)"
    if [ -r "`$P" ] && ! grep -q cupsManualCopies "`$P"; then
        awk '{print} /^\*cupsVersion:/{print "*cupsManualCopies: True"}' "`$P" > "`$T"
        lpadmin -p "`$Q" -P "`$T" 2>/dev/null || sudo lpadmin -p "`$Q" -P "`$T"
    fi
    rm -f "`$T"
fi
lpadmin -p "`$Q" -o auth-info-required=none 2>/dev/null || true
printf '  %sDone.%s Choose %s"School Printer"%s in any app'"'"'s Print dialog.\n\n' "`$G" "`$R" "`$B" "`$R"
"@
}

# ---------------------------------------------------------------- "Add to this device" helper for Windows (double-click)
function Ipp-AddCmd($hostPort) {
    $u = "http://$hostPort/ipp/print"
    (@(
        '@echo off', 'title Add School Printer', 'echo.', "echo   School Printer  -  adding $u", 'echo.',
        "powershell -NoProfile -ExecutionPolicy Bypass -Command ""try { Add-Printer -IppURL '$u' -ErrorAction Stop; Write-Host '  Added. Choose School Printer in any app''s Print dialog.' -ForegroundColor Green; exit 0 } catch { Write-Host ('  Could not add it automatically: ' + `$_.Exception.Message) -ForegroundColor Yellow; exit 1 }""",
        'if errorlevel 1 (', '  echo   Opening printer settings: press "Add device" and choose "School Printer".', '  start ms-settings:printers', ')',
        'echo.', 'pause'
    ) -join "`r`n") + "`r`n"
}
