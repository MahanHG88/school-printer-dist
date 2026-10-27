# School Printer - installer for the Windows PC the printer is plugged into.
# https://print.mahanmirzaee.com
#
# Works everywhere (Command Prompt, Run box or PowerShell, any execution policy):
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=3072; iex ((New-Object Net.WebClient).DownloadString('https://print.mahanmirzaee.com/install.ps1'))"
# Short (PowerShell 5+, Windows 10/11):   irm https://print.mahanmirzaee.com/install.ps1 | iex
# Offline:         download SchoolPrinter-windows.zip, unzip it, double-click Install.cmd
#
# What it does (undo: the same commands with uninstall.ps1, or Uninstall.cmd from the zip):
#   - C:\ProgramData\MacPrint\  PrintServer.ps1, watch.ps1, convert.ps1, sync.ps1, syncd.ps1, dns.ps1, control.ps1, notice.ps1, web\,
#     config.txt, Inbox\, Uploads\, Outbox\, Sync\ (printing network: only SYSTEM and administrators can read it)
#   - scheduled tasks "MacPrint Web", "MacPrint Inbox", "MacPrint Sync", "MacPrint DNS" (SYSTEM, at startup, auto-restart)
#   - scheduled task "MacPrint Convert" (whoever signs in; turns Word/Excel/PowerPoint into PDF with Microsoft Office)
#   - firewall rules "MacPrint Web" (TCP 8631 + 80) and "MacPrint DNS" (UDP 53): from the local network only
#   - desktop shortcuts for every user: "School Printer (Admin)", "Start School Printer", "Stop School Printer"

function Install-SchoolPrinter {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $Version = '1.7.5'
    $Base    = 'https://print.mahanmirzaee.com/app'          # direct: print.mahanmirzaee.com  |  -ir: jsDelivr mirror (fast inside Iran)
    $Pack    = ''          # -rf: every file in one npm package through Runflare's npm mirror (Iran); else empty
    $Root    = 'C:\ProgramData\MacPrint'
    $Port    = 8631
    $Files   = [ordered]@{    # path under /app/  =  SHA-256, size   (filled in by build.sh)
        'win/PrintServer.ps1' = @('DE72AE8309881EBCA89B50C38853F04AC1782A1658C2AB2B534FBE99EDCF0424', 38030)
        'win/watch.ps1' = @('01B558F33297CCF1FFE67EA6FF6DE2376014EC1032876CA900D2C507D35A229A', 13388)
        'win/convert.ps1' = @('B927921C187A6DB910CC22ADFB8D504EEEBD23BE555FC18C43FEB6D9072ECCA5', 5781)
        'win/ipp.ps1' = @('037153FEF862F76BBF72CB0AE6D1B2BBF695E5F45E6069EB2292D659FA3CF6FA', 23063)
        'win/sync.ps1' = @('3E4713843A27D61729FE74FD964F7484419B608A839F61FC1A4865BDEE4C588C', 45035)
        'win/syncd.ps1' = @('BED6380E4775D04D2D0DC27FB6D225E3AABF28A04085CB9C77BE57AA555FA7D6', 42202)
        'win/dns.ps1' = @('409515475605CF8E4B245B8B593BB2D6FE86708017C774DC55A886139CBCA9EB', 5293)
        'win/control.ps1' = @('4B98219C7F23117F8CEB00EFBBE863D37253A07105C60C3F837E5EB758E560CF', 1863)
        'win/notice.ps1' = @('605B260242A2049307402C93E557C3D1087848FFDDD6B5650FCBE292DEBF692F', 3349)
        'web/admin.html' = @('E10FC55B745F0C637F2DEA18068D0A8EA6F6A5E9A0201B43871FB7D93EF0A846', 9597)
        'web/admin.js' = @('F9CE28AD474DB8C3B1F94E23081F393BD06A118A41BFB4CC4342B162FDAB9FF5', 13758)
        'web/app.css' = @('9E53C50430CDAF0158A29F6878B05B90A713AB3EE8A73E71274FF3AFAB751D77', 24778)
        'web/i18n.js' = @('58A236DE9A7D71B76B1CE435B5605C602116DD6AD06773C3BB063CA38E85C886', 38929)
        'web/pdf.min.js' = @('978FD1B2D134A98E98966186A97777BEBF87D8E770DADAB1ECE3687E21A5AA6C', 377116)
        'web/pdf.worker.min.js' = @('38CDE5311957B86BC3669F93E7D2566DE333A90055ED6635BEF60D9BF00E96F2', 1133660)
        'web/print.html' = @('6026C274FDF45A13602CC66DD320905C971A39AB03C9276D10DB42E37564F437', 13876)
        'web/print.js' = @('42F4152BD637ABF3255C0B5E309E4B9DA2B9969958B848834980FEDF12D1FB86', 35529)
        'web/vazirmatn.woff2' = @('4E3FA217D38FDAFC1FEA4414CEB58CA5E662CF0AB5FA735A8C8C20E8B42CAD92', 111152)
    }
    $OneLiner = "[Net.ServicePointManager]::SecurityProtocol=3072; iex ((New-Object Net.WebClient).DownloadString('https://print.mahanmirzaee.com/install.ps1'))"

    # ================================================================ look: live dashboard
    $E = [char]27
    $tty = (-not [Console]::IsOutputRedirected) -and $Host.Name -eq 'ConsoleHost'
    $stops = @(@(91, 91, 246), @(177, 83, 245), @(244, 114, 182))     # brand: indigo -> violet -> pink
    function Rgb([double]$t) {
        if ($t -le 0.5) { $a = $stops[0]; $b = $stops[1]; $u = $t * 2 } else { $a = $stops[1]; $b = $stops[2]; $u = ($t - 0.5) * 2 }
        '{0};{1};{2}' -f [int]($a[0] + ($b[0] - $a[0]) * $u), [int]($a[1] + ($b[1] - $a[1]) * $u), [int]($a[2] + ($b[2] - $a[2]) * $u)
    }
    $R = "$E[0m"; $B = "$E[1m"; $D = "$E[2m"
    $OK = "$E[38;2;52;211;153m"; $WN = "$E[38;2;251;191;36m"; $ER = "$E[38;2;255;107;112m"; $AC = "$E[38;2;140;140;255m"; $MU = "$E[38;2;120;124;150m"
    $dot = [string][char]0x00B7
    function Grad($text) { $s = ''; for ($i = 0; $i -lt $text.Length; $i++) { $s += "$E[38;2;$(Rgb ($i / [math]::Max(1, $text.Length - 1)))m" + $text[$i] }; $s + $R }
    function KB([double]$bytes) { '{0:N1} KB' -f ($bytes / 1024) }
    function Secs([double]$s) {
        if ($s -lt 1) { return '<1 s' }
        if ($s -lt 90) { return ('{0:N0} s' -f [math]::Ceiling($s)) }
        '{0}m {1:00}s' -f [math]::Floor($s / 60), [math]::Ceiling($s % 60)
    }
    function Pad($s, $n) { if ($s.Length -ge $n) { $s } else { $s + (' ' * ($n - $s.Length)) } }

    $Steps = [ordered]@{}
    function Add-Step($id, $title, $est) { $Steps[$id] = @{ title = $title; est = [double]$est; state = 'pending'; detail = ''; t = $null; el = 0.0; frac = 0.0 } }
    Add-Step 'check'    'Check this PC'                   0.5
    if ($Pack) { Add-Step 'net' 'Download the package'      3.0 }    # Runflare: every file in one download
    Add-Step 'files'    'Download & verify files'         5.0
    Add-Step 'printer'  'Choose the printer'              1.0
    Add-Step 'network'  'Open the local network'          2.0
    Add-Step 'service'  'Start the print service'         3.0
    Add-Step 'office'   'Word / Excel / PowerPoint'       1.5
    Add-Step 'shortcut' 'Desktop shortcuts'               0.4
    Add-Step 'verify'   'Check it answers'                2.0
    $script:plan = @("$($MU)Download   $R$D-$R", "$($MU)Estimate   $R$D-$R")
    $script:t0 = Get-Date; $script:drawn = 0; $script:last = [datetime]::MinValue; $script:frame = 0
    $spin = @('|', '/', '-', '\')

    function Draw([switch]$Force) {
        if (-not $tty) { return }
        $now = Get-Date
        if (-not $Force -and ($now - $script:last).TotalMilliseconds -lt 100) { return }
        $script:last = $now; $script:frame++
        $cols = 120; try { $cols = $Host.UI.RawUI.WindowSize.Width } catch {}; $script:room = [math]::Max(10, $cols - 47)
        $L = New-Object System.Collections.Generic.List[string]
        foreach ($p in $script:plan) { $L.Add("   $p") }
        $L.Add('')
        $total = 0.0; $done = 0.0; $rem = 0.0
        foreach ($s in $Steps.Values) {
            $el = if ($s.state -eq 'active') { ($now - $s.t).TotalSeconds } else { $s.el }
            switch ($s.state) {
                'pending' { $ic = "$MU$dot$R"; $tm = $(if ($s.est -lt 1) { '<1 s' } else { "~$(Secs $s.est)" }); $tc = $MU; $ti = "$MU$(Pad $s.title 28)$R" }
                'active'  { $ic = "$AC$($spin[$script:frame % 4])$R"; $tm = ('{0:N1}s' -f $el); $tc = $AC; $ti = "$B$(Pad $s.title 28)$R" }
                'done'    { $ic = "$OK$([char]0x221A)$R"; $tm = ('{0:N1}s' -f $el); $tc = $D; $ti = Pad $s.title 28 }
                'warn'    { $ic = "$WN!$R"; $tm = ('{0:N1}s' -f $el); $tc = $D; $ti = Pad $s.title 28 }
                'fail'    { $ic = "$ER$([char]0x00D7)$R"; $tm = ('{0:N1}s' -f $el); $tc = $D; $ti = "$ER$(Pad $s.title 28)$R" }
            }
            $det = [string]$s.detail; if ($det.Length -gt $script:room) { $det = $det.Substring(0, [math]::Max(0, $script:room - 3)) + '...' }   # never wrap: wrapping breaks the redraw
            $L.Add("   $ic  $ti $tc$((' ' * [math]::Max(0, 7 - $tm.Length)) + $tm)$R   $D$det$R")
            $total += $s.est
            if ($s.state -in 'done', 'warn') { $done += $s.est }
            elseif ($s.state -eq 'active') {
                $f = if ($s.frac -gt 0) { $s.frac } else { [math]::Min(0.95, $el / [math]::Max(0.1, $s.est)) }
                $done += $s.est * $f; $rem += [math]::Max($s.est * (1 - $f), 0)
            } elseif ($s.state -eq 'pending') { $rem += $s.est }
        }
        $L.Add('')
        $pct = [int][math]::Min(100, [math]::Floor(100 * $done / [math]::Max(0.1, $total)))
        $w = 34; $fill = [int][math]::Floor($w * $pct / 100); $bar = ''
        for ($i = 0; $i -lt $w; $i++) { if ($i -lt $fill) { $bar += "$E[38;2;$(Rgb ($i / ($w - 1)))m" + [char]0x2588 } else { $bar += "$E[38;2;58;60;86m" + [char]0x2591 } }
        $L.Add("   $bar$R  $B$('{0,3}' -f $pct)%$R   $D$(if ($rem -lt 1) { '<1 s' } else { "~$(Secs $rem)" }) left  $dot  $(Secs ($now - $script:t0).TotalSeconds) elapsed$R")
        $sb = New-Object Text.StringBuilder
        if ($script:drawn) { [void]$sb.Append("$E[$($script:drawn)A") }
        foreach ($line in $L) { [void]$sb.Append("`r$E[2K$line`n") }   # not $l: PowerShell names ignore case ($l IS $L)
        $script:drawn = $L.Count
        Write-Host -NoNewline $sb.ToString()
    }
    function Begin($id, $detail) { $s = $Steps[$id]; $s.state = 'active'; $s.t = Get-Date; if ($detail) { $s.detail = $detail }; Draw -Force }
    function Prog($id, $frac, $detail) { $s = $Steps[$id]; $s.frac = [math]::Max(0.001, [math]::Min(1, $frac)); if ($detail) { $s.detail = $detail }; Draw }
    function Finish($id, $detail, $state = 'done') {
        $s = $Steps[$id]; $s.state = $state; $s.el = ((Get-Date) - $s.t).TotalSeconds; if ($null -ne $detail) { $s.detail = $detail }
        if ($tty) { Draw -Force } else { Write-Host ("  [{0}] {1} ({2:N1}s) {3}" -f $state, $s.title, $s.el, $s.detail) }
    }
    function Fail($id, $t, $hint) {
        Finish $id $t 'fail'
        Write-Host ''; Write-Host "   $ER$([char]0x00D7)  $t$R"; if ($hint) { Write-Host "      $hint" }; Write-Host ''
    }
    function Ask($lines, $q) {
        foreach ($l in $lines) { Write-Host "   $l" }
        $a = Read-Host "   $AC?$R  $q"
        if ($tty) { Write-Host -NoNewline "$E[$($lines.Count + 1)A$E[J" }
        $a
    }
    function Header($sub) {
        $h = [string][char]0x2500; $v = [string][char]0x2502
        $t1 = 'School Printer'; $t1r = "installer $Version"; $t2 = $sub; $w = [math]::Max(62, $t2.Length + 4)   # $sub = system  -  download source
        Write-Host ''
        Write-Host "  $MU$([char]0x250C)$($h * $w)$([char]0x2510)$R"
        Write-Host "  $MU$v$R  $B$(Grad $t1)$R$(' ' * [math]::Max(1, $w - 4 - $t1.Length - $t1r.Length))$D$t1r$R  $MU$v$R"
        Write-Host "  $MU$v$R  $D$(Pad $t2 ($w - 4))$R  $MU$v$R"
        Write-Host "  $MU$([char]0x2514)$($h * $w)$([char]0x2518)$R"
        Write-Host ''
    }

    # ================================================================ downloads
    function Get-File($url, $dest, $onBytes) {
        $req = [Net.HttpWebRequest]::Create($url)
        $req.AutomaticDecompression = [Net.DecompressionMethods]'GZip,Deflate'
        $req.UserAgent = "SchoolPrinterInstaller/$Version"
        $res = $req.GetResponse(); $in = $res.GetResponseStream(); $out = [IO.File]::Create($dest)
        try {
            $buf = New-Object byte[] 65536
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n); & $onBytes $n }
        } finally { $out.Close(); $in.Close(); $res.Close() }
    }
    function Open-Pack($url, $dir) {    # npm package (.tgz) -> files in $dir; a tiny tar reader, no tar.exe needed. -> download stats
        $sw = [Diagnostics.Stopwatch]::StartNew(); $tgz = Join-Path $env:TEMP 'sp-pack.tgz'
        $script:packGot = 0; Get-File $url $tgz { param($n) $script:packGot += $n }
        $lat = 0.05; $secs = $sw.Elapsed.TotalSeconds
        $gz = New-Object IO.Compression.GZipStream ([IO.File]::OpenRead($tgz)), ([IO.Compression.CompressionMode]::Decompress)
        $ms = New-Object IO.MemoryStream; $gz.CopyTo($ms); $gz.Close(); Remove-Item $tgz -Force -EA SilentlyContinue
        $t = $ms.ToArray(); $i = 0; $a = [Text.Encoding]::ASCII
        while ($i + 512 -le $t.Length -and $t[$i] -ne 0) {
            $name = $a.GetString($t, $i, 100).Split([char]0)[0]; $pre = $a.GetString($t, $i + 345, 155).Split([char]0)[0]; if ($pre) { $name = "$pre/$name" }
            $size = [Convert]::ToInt64(($a.GetString($t, $i + 124, 12).Split([char]0)[0].Trim()) + '0', 8) / 8; $type = [char]$t[$i + 156]
            $i += 512
            if (($type -eq '0' -or $type -eq [char]0) -and $name -notmatch '\.\.' ) {
                $dest = Join-Path $dir ($name -replace '/', '\'); New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
                $f = [IO.File]::Create($dest); $f.Write($t, $i, $size); $f.Close()
            }
            $i += [math]::Ceiling($size / 512) * 512
        }
        @{ bytes = $script:packGot; lat = $lat; kbps = ($script:packGot / 1024) / [math]::Max(0.001, $secs); total = $secs }
    }

    $here = $null
    if ($PSCommandPath) { $here = Split-Path -Parent $PSCommandPath }

    # ================================================================ administrator
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        Write-Host ''
        Write-Host "  $B$(Grad 'School Printer')$R needs administrator permission."
        Write-Host "  $($D)Click Yes on the next window - the install continues there with a live progress screen.$R"
        if ($here) { $a = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`"" }
        else { $a = "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"$OneLiner`"" }
        try { Start-Process powershell -Verb RunAs -ArgumentList $a } catch { Write-Host "  $($ER)Permission was not given. Nothing was changed.$R" }
        Write-Host ''
        return
    }

    try { $host.UI.RawUI.WindowTitle = 'School Printer installer' } catch {}
    try { [Console]::CursorVisible = $false } catch {}
    $os = (Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue).Caption -replace '^Microsoft ', ''
    Header "$os  $dot  direct from print.mahanmirzaee.com"
    try {
    Draw -Force

    # ---------------------------------------------------------------- 1. check
    Begin 'check'
    $free = [math]::Round((Get-PSDrive C).Free / 1MB)
    if ($free -lt 60) { Fail 'check' "Not enough space on C: ($free MB free, about 60 MB needed)." 'Free some space and run this again.'; return }
    if ($PSVersionTable.PSVersion.Major -lt 5) { Fail 'check' 'Windows PowerShell 5.1 is required (Windows 10 or 11).'; return }
    New-Item -ItemType Directory -Path "$Root\Inbox", "$Root\Uploads", "$Root\web" -Force | Out-Null
    function Dest($k) { if ($k -like 'win/*') { Join-Path $Root $k.Substring(4) } else { Join-Path $Root ($k -replace '/', '\') } }
    $need = New-Object System.Collections.Generic.List[string]; $needBytes = 0
    foreach ($k in $Files.Keys) {
        $d = Dest $k
        if (-not ((Test-Path $d) -and ((Get-FileHash $d -Algorithm SHA256).Hash -eq $Files[$k][0]))) { $need.Add($k); $needBytes += $Files[$k][1] }
    }
    $allBytes = 0; foreach ($k in $Files.Keys) { $allBytes += $Files[$k][1] }
    Finish 'check' ("{0:N1} GB free on C:  $dot  PowerShell {1}" -f ($free / 1024), $PSVersionTable.PSVersion.ToString(2))

    # ---------------------------------------------------------------- 2. Runflare package (other sources: no speed test - the download shows its own speed)
    $net = $null
    if ($Pack -and $need.Count -and -not ($here -and (Test-Path (Join-Path $here 'win')))) {    # Runflare: the whole package in one download
        Begin 'net' 'downloading every file in one package (Runflare mirror)'
        $pdir = Join-Path $env:TEMP ('sp-pack-' + [guid]::NewGuid().ToString('N'))
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $net = Open-Pack $Pack $pdir }
        catch { Fail 'net' 'Could not download from the Runflare mirror.' 'Try the other Iran mirror (jsDelivr) on print.mahanmirzaee.com, or Plan B: download SchoolPrinter-windows.zip on any device, copy it here (a USB stick is fine), unzip it and double-click Install.cmd.'; return }
        $here = Join-Path $pdir 'package\app'
        Finish 'net' ("{0:N1} KB/s  $dot  {1} in one package  $dot  every file is checked next" -f $net.kbps, (KB $net.bytes))
    }
    elseif ($Steps.Contains('net')) { Begin 'net'; Finish 'net' $(if ($need.Count) { 'offline install - using the files next to this script' } else { 'skipped - all files already up to date' }) }
    $local = $here -and (Test-Path (Join-Path $here 'win'))
    # no speed test: until the download starts, assume ~400 KB/s; then the progress bar follows the real download
    $Steps.files.est = if ($local -or -not $need.Count) { 0.5 } else { ($needBytes / 1024) / 400 + $need.Count * 0.05 }
    $totalEst = 0.0; foreach ($s in $Steps.Values) { $totalEst += $s.est }
    $srcNote = if ($net) { "$D  from Runflare in one package$R" } elseif ($local) { "$D  offline (zip)$R" } else { '' }
    $script:plan = @(
        "$($MU)Download   $R$B$(KB $needBytes)$R$D  in $($need.Count) of $($Files.Count) files  $dot  $(KB $allBytes) in total$R$srcNote",
        "$($MU)Estimate   $R$B~$(Secs $totalEst)$R$D  for all $($Steps.Count) steps$(if (-not $local -and $need.Count) { ', depends on the connection' })$R")
    Draw -Force

    # ---------------------------------------------------------------- 3. files
    Begin 'files'
    $script:got = 0; $script:dlStart = Get-Date; $fetched = 0; $stopped = $false
    foreach ($name in $need) {
        $want = $Files[$name][0]; $dest = Dest $name; $short = Split-Path $name -Leaf
        $src = if ($local) { Join-Path $here ($name -replace '/', '\') } else { Join-Path $env:TEMP "sp-$short" }
        if (-not $local) {
            $script:short = $short
            try {
                Get-File "$Base/$name`?v=$Version" $src {    # ?v=: each release is its own CDN cache entry
                    param($n)
                    $script:got += $n
                    $secs = [math]::Max(0.05, ((Get-Date) - $script:dlStart).TotalSeconds); $kbps = ($script:got / 1024) / $secs
                    $left = (($needBytes - $script:got) / 1024) / [math]::Max(1, $kbps)
                    Prog 'files' ($script:got / [math]::Max(1, $needBytes)) ("{0} / {1}  $dot  {2:N1} KB/s  $dot  ~{3} left  $dot  {4}" -f (KB $script:got), (KB $needBytes), $kbps, (Secs $left), $script:short)
                }
            } catch {
                Fail 'files' "Could not download $short." 'Plan B: download SchoolPrinter-windows.zip from print.mahanmirzaee.com on any device, copy it here (a USB stick is fine), unzip it and double-click Install.cmd.'
                return
            }
        } else { $script:got += $Files[$name][1]; Prog 'files' ($script:got / [math]::Max(1, $needBytes)) "copying $short" }
        if ((Get-FileHash $src -Algorithm SHA256).Hash -ne $want) {
            if (-not $local) { Remove-Item $src -Force -EA SilentlyContinue }
            Fail 'files' "$short failed its safety check (fingerprint does not match)." 'Nothing was installed.'
            return
        }
        if (-not $stopped) {
            foreach ($t in 'MacPrint Inbox', 'MacPrint Web', 'MacPrint Convert', 'MacPrint Sync', 'MacPrint DNS') { Stop-ScheduledTask -TaskName $t -EA SilentlyContinue }
            Get-Process SumatraPDF -EA SilentlyContinue | Where-Object { $_.Path -like "$Root*" } | Stop-Process -Force -EA SilentlyContinue
            $stopped = $true
        }
        Copy-Item $src $dest -Force
        if (-not $local) { Remove-Item $src -Force -EA SilentlyContinue }
        $fetched++
    }
    Remove-Item "$Root\SumatraPDF.exe", "$Root\SumatraPDF-settings.txt" -Force -EA SilentlyContinue   # no longer needed
    icacls "$Root\Uploads" /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null       # the Office helper (signed-in user) writes PDFs here
    New-Item -ItemType Directory -Path "$Root\Sync", "$Root\Outbox" -Force | Out-Null
    icacls "$Root\Sync" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null    # the network key: SYSTEM + administrators only
    $dlSecs = ((Get-Date) - $script:dlStart).TotalSeconds
    if ($fetched) { Finish 'files' ("{0} files  $dot  {1}  $dot  {2:N1} KB/s average  $dot  SHA-256 verified" -f $fetched, (KB $needBytes), (($needBytes / 1024) / [math]::Max(0.05, $dlSecs))) }
    else { Finish 'files' 'already up to date' }
    if ($pdir) { Remove-Item $pdir -Recurse -Force -EA SilentlyContinue }

    # ---------------------------------------------------------------- 4. printer
    Begin 'printer'
    $cfgFile = Join-Path $Root 'config.txt'
    $cfg = @{ printer = ''; pin = ''; open = '1'; lang = 'fa' }
    if (Test-Path $cfgFile) { Get-Content $cfgFile -Encoding UTF8 | ForEach-Object { if ($_ -match '^\s*(\w+)\s*=\s*(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() } } }
    $all = @(Get-Printer -EA SilentlyContinue)
    $real = @($all | Where-Object { $_.DriverName -notmatch 'Microsoft|OneNote|Fax|PDF|XPS|Send To' -and $_.PortName -notmatch '^(PORTPROMPT|nul|FILE|XPS|SHRFAX)' })
    $kept = $cfg.printer -and ($all | Where-Object { $_.Name -eq $cfg.printer })
    if (-not $kept) {
        $usb = @($real | Where-Object { $_.PortName -like 'USB*' })
        if ($usb.Count -eq 1) { $cfg.printer = $usb[0].Name }
        elseif ($real.Count -eq 1) { $cfg.printer = $real[0].Name }
        else {
            $list = if ($real.Count) { $real } else { $all }
            if (-not $list.Count) {    # no printer: fine for a computer that only has a scanner
                $scanners = 0; try { $scanners = @((New-Object -ComObject WIA.DeviceManager).DeviceInfos | Where-Object { $_.Type -eq 1 }).Count } catch {}
                if (-not $scanners) { Fail 'printer' 'No printers or scanners are installed.' 'Plug the printer or scanner in, check Windows can use it, then run this again.'; return }
                $cfg.printer = ''; $list = @()
            }
            $lines = @("$($B)Which printer should everyone use?$R")
            for ($i = 0; $i -lt $list.Count; $i++) { $lines += "   $AC$($i + 1)$R  $($list[$i].Name)  $D$($list[$i].PortName)$R" }
            if ($list.Count) {
                do { $n = Ask $lines 'Number' } until ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $list.Count)
                $cfg.printer = $list[[int]$n - 1].Name
            }
        }
    }
    $keys = @('printer', 'pin', 'open', 'lang') + @($cfg.Keys | Where-Object { $_ -notin 'printer', 'pin', 'open', 'lang' } | Sort-Object)    # keeps the network settings
    Set-Content $cfgFile (@('# School Printer settings (also changeable on the admin page)') + @($keys | ForEach-Object { "$_=$($cfg[$_])" })) -Encoding UTF8
    Finish 'printer' $(if ($cfg.printer) { $cfg.printer + $(if ($kept) { '  (kept)' } else { '' }) } else { 'no printer - a scan station' })

    # ---------------------------------------------------------------- 5. network
    Begin 'network'
    $profiles = @()
    foreach ($np in @(Get-NetConnectionProfile -EA SilentlyContinue)) {
        if ($np.NetworkCategory -eq 'Public') {
            $a = Ask @("$WN!$R  '$($np.Name)' is a $($B)Public$R network, so other devices can't reach this PC.") 'Switch it to Private (recommended for a home or school network)? [Y/n]'
            if ($a -notmatch '^[nN]') { Set-NetConnectionProfile -InterfaceIndex $np.InterfaceIndex -NetworkCategory Private; $profiles += "$($np.Name): now Private" }
            else { $profiles += "$($np.Name): Public (left as is)" }
        } else { $profiles += "$($np.Name): $($np.NetworkCategory)" }
    }
    Remove-NetFirewallRule -DisplayName 'MacPrint Web', 'MacPrint DNS' -EA SilentlyContinue
    New-NetFirewallRule -DisplayName 'MacPrint Web' -Description 'School Printer web page and printing network (print.mahanmirzaee.com). Local network only.' `
        -Direction Inbound -Protocol TCP -LocalPort $Port, 80 -RemoteAddress LocalSubnet -Profile Private, Domain -Action Allow | Out-Null
    New-NetFirewallRule -DisplayName 'MacPrint DNS' -Description 'School Printer: answers the school address (when one is set). Local network only.' `
        -Direction Inbound -Protocol UDP -LocalPort 53 -RemoteAddress LocalSubnet -Profile Private, Domain -Action Allow | Out-Null
    Finish 'network' ("port $Port, local network only  $dot  " + ($profiles -join ', '))

    # ---------------------------------------------------------------- 6. service
    Begin 'service'
    $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $trg  = New-ScheduledTaskTrigger -AtStartup
    $k = 0
    foreach ($t in @(@('MacPrint Web', 'PrintServer.ps1'), @('MacPrint Inbox', 'watch.ps1'), @('MacPrint Sync', 'syncd.ps1'), @('MacPrint DNS', 'dns.ps1'))) {
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Root\$($t[1])`""
        Stop-ScheduledTask -TaskName $t[0] -EA SilentlyContinue
        Register-ScheduledTask -TaskName $t[0] -Action $act -Trigger $trg -Settings $set -Principal $prin -Force | Out-Null
        Start-ScheduledTask -TaskName $t[0]
        $k++; Prog 'service' ($k / 4) "$($t[0]) started"
    }
    Finish 'service' 'web page, print engine, printing network, school address  -  start with Windows, restart themselves'

    # ---------------------------------------------------------------- 7. Office helper
    Begin 'office'
    $hasMs = Test-Path 'Registry::HKEY_CLASSES_ROOT\Word.Application\CLSID'
    $hasLo = (Test-Path 'C:\Program Files\LibreOffice\program\soffice.exe') -or (Test-Path 'C:\Program Files (x86)\LibreOffice\program\soffice.exe')
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Root\convert.ps1`""
    $cset = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
    Register-ScheduledTask -TaskName 'MacPrint Convert' -Action $act -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Settings $cset `
        -Principal (New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited) -Force | Out-Null
    Start-ScheduledTask -TaskName 'MacPrint Convert' -EA SilentlyContinue
    if ($hasMs) { Finish 'office' 'Microsoft Office found  -  works while someone is signed in' }
    elseif ($hasLo) { Finish 'office' 'LibreOffice found  -  works while someone is signed in' }
    else { Finish 'office' 'needs Microsoft Office or LibreOffice  -  PDFs and photos work now' 'warn' }

    # ---------------------------------------------------------------- 8. shortcut
    Begin 'shortcut'
    Set-Content "$env:PUBLIC\Desktop\School Printer (Admin).url" @('[InternetShortcut]', "URL=http://localhost:$Port/admin", 'IconFile=C:\Windows\System32\shell32.dll', 'IconIndex=16') -Encoding ascii
    $sh = New-Object -ComObject WScript.Shell
    foreach ($x in @(@('Start School Printer', 'start', 137), @('Stop School Printer', 'stop', 131))) {    # start: then opens the admin page
        $l = $sh.CreateShortcut("$env:PUBLIC\Desktop\$($x[0]).lnk")
        $l.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $l.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Root\control.ps1`" $($x[1])"
        $l.IconLocation = "$env:SystemRoot\System32\shell32.dll,$($x[2])"; $l.WindowStyle = 7; $l.Description = "$($x[0]) (asks for permission)"; $l.Save()
    }
    Finish 'shortcut' '"School Printer (Admin)", "Start School Printer", "Stop School Printer" on every desktop'

    # ---------------------------------------------------------------- 9. verify
    Begin 'verify'
    $ok = $false; $ms = 0
    for ($i = 0; $i -lt 30 -and -not $ok; $i++) {
        Start-Sleep -Milliseconds 500; Draw
        try { $sw = [Diagnostics.Stopwatch]::StartNew(); $null = Invoke-WebRequest -UseBasicParsing "http://localhost:$Port/status" -TimeoutSec 2; $ms = $sw.Elapsed.TotalMilliseconds; $ok = $true } catch {}
    }
    if (-not $ok) { Fail 'verify' 'Installed, but the web page did not answer yet.' 'Restart the PC; if it still does not open, run this again.'; return }
    Finish 'verify' ("answered in {0:N0} ms" -f $ms)

    # ---------------------------------------------------------------- summary
    $took = ((Get-Date) - $script:t0).TotalSeconds
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -notmatch 'vEthernet|Loopback|WSL|VirtualBox|VMware' } | ForEach-Object { $_.IPAddress })
    Write-Host ''
    Write-Host "   $OK$([char]0x221A)$R  $B$(Grad 'School Printer is running')$R   $D$('{0:N1}' -f $took) s  (estimated ~$(Secs $totalEst))$R"
    Write-Host ''
    Write-Host "   $($B)On every other device$R, type this in the browser:"
    foreach ($ip in $ips) { Write-Host "      $(Grad "http://${ip}:$Port")" }
    Write-Host "      $($D)or http://$($env:COMPUTERNAME):$Port$R"
    Write-Host ''
    Write-Host "   $($B)On this PC$($R): double-click $B`"School Printer (Admin)`"$R on the desktop  $D($B`"Start`"$R$D / $B`"Stop School Printer`"$R$D start and stop it)$R."
    Write-Host ''
    Start-Process "http://localhost:$Port/admin"
    } finally { try { [Console]::CursorVisible = $true } catch {} }
}
Install-SchoolPrinter
