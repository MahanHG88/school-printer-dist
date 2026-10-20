# PrintServer.ps1 - School Printer web server for Windows (https://print.mahanmirzaee.com)
#   Everyone on the network:  http://<this PC>:8631        upload, preview, choose settings, print
#   On this PC only:          http://localhost:8631/admin  (desktop shortcut "School Printer (Admin)")
# Flow: POST /upload -> Uploads\<id>.<ext> (+ <id>.todo for Office files, converted by convert.ps1 in the
# signed-in user's session) -> GET /file/<id> for the preview -> POST /print {id, settings} -> Inbox\ job
# that watch.ps1 prints. Runs as SYSTEM from the task "MacPrint Web". PowerShell 5.1, nothing to install.

$root    = if ($env:SP_ROOT) { $env:SP_ROOT } else { 'C:\ProgramData\MacPrint' }   # SP_ROOT / SP_PORT: test copies only
$inbox   = Join-Path $root 'Inbox'
$up      = Join-Path $root 'Uploads'
$web     = Join-Path $root 'web'
$cfgFile = Join-Path $root 'config.txt'
$logFile = Join-Path $root 'log.txt'
$port    = if ($env:SP_PORT) { [int]$env:SP_PORT } else { 8631 }
$maxMB   = 50
Add-Type -AssemblyName System.Drawing

$BaseTypes   = @('pdf', 'jpg', 'jpeg', 'png', 'gif', 'bmp', 'tif', 'tiff')
$OfficeTypes = @('doc', 'docx', 'rtf', 'odt', 'txt', 'xls', 'xlsx', 'csv', 'ods', 'ppt', 'pptx', 'odp')
$Mime = @{ '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'
           '.pdf' = 'application/pdf'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif' }

function Get-Cfg {
    $c = @{ pin = ''; open = '1'; printer = ''; lang = 'fa' }
    if (Test-Path $cfgFile) {
        Get-Content $cfgFile -Encoding UTF8 | ForEach-Object { if ($_ -match '^\s*(\w+)\s*=\s*(.*)$') { $c[$Matches[1]] = $Matches[2].Trim() } }
    }
    if (-not $c.printer) { $c.printer = (Get-CimInstance Win32_Printer -Filter 'Default=TRUE' -EA SilentlyContinue).Name }
    $c
}
function Save-Cfg($c) {
    Set-Content $cfgFile @('# School Printer settings (also changeable on the admin page)', "printer=$($c.printer)", "pin=$($c.pin)", "open=$($c.open)", "lang=$($c.lang)") -Encoding UTF8
}

function Send($res, $code, $type, [byte[]]$b, $cache) {
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.Headers.Add('Cache-Control', $(if ($cache) { 'max-age=86400' } else { 'no-store' }))
    $res.Headers.Add('X-Content-Type-Options', 'nosniff')
    $res.ContentLength64 = $b.Length
    $res.OutputStream.Write($b, 0, $b.Length)
    $res.OutputStream.Close()
}
function Json($res, $code, $obj) { Send $res $code 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -Depth 5 -InputObject $obj))) }
function SendFile($res, $path, $cache) {
    $ext = [IO.Path]::GetExtension($path).ToLower()
    $type = if ($Mime[$ext]) { $Mime[$ext] } else { 'application/octet-stream' }
    Send $res 200 $type ([IO.File]::ReadAllBytes($path)) $cache
}

function Waiting { @(Get-ChildItem $inbox -File -Filter *.json -EA SilentlyContinue).Count + @(Get-ChildItem $inbox -File -Filter *.pdf -EA SilentlyContinue | Where-Object { -not (Test-Path ([IO.Path]::ChangeExtension($_.FullName, '.json'))) }).Count }

# ---- printer capabilities (paper sizes from the driver, colour, duplex, unprintable edge) - cached 60 s
$script:capsCache = @{ printer = ''; at = [datetime]::MinValue; caps = $null }
function Get-Caps($printer) {
    if ($script:capsCache.printer -eq $printer -and ((Get-Date) - $script:capsCache.at).TotalSeconds -lt 60) { return $script:capsCache.caps }
    $caps = @{ papers = @(); def = ''; color = $false; duplex = $false; hm = 4.2 }
    try {
        $ps = New-Object System.Drawing.Printing.PrinterSettings
        $ps.PrinterName = $printer
        if ($ps.IsValid) {
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
    $script:capsCache = @{ printer = $printer; at = Get-Date; caps = $caps }
    $caps
}

# ---- Word/Excel/PowerPoint: converted by convert.ps1 in the signed-in user's session (Office will not run as SYSTEM)
function Get-Office {
    $hasMs = Test-Path 'Registry::HKEY_CLASSES_ROOT\Word.Application\CLSID'
    $hasLo = (Test-Path 'C:\Program Files\LibreOffice\program\soffice.exe') -or (Test-Path 'C:\Program Files (x86)\LibreOffice\program\soffice.exe')
    if (-not ($hasMs -or $hasLo)) { return 'none' }
    $alive = Join-Path $up 'converter.alive'
    if ((Test-Path $alive) -and ((Get-Date) - (Get-Item $alive).LastWriteTime).TotalSeconds -lt 20) { if ($hasMs) { 'office' } else { 'lo' } } else { 'signin' }
}
function Get-Types($office) { if ($office -eq 'office' -or $office -eq 'lo') { $BaseTypes + $OfficeTypes } else { $BaseTypes } }

function Get-Info {
    $c = Get-Cfg
    $urls = @(Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -notmatch 'vEthernet|Loopback|WSL|VirtualBox|VMware' } |
        ForEach-Object { "http://$($_.IPAddress):$port" })
    $pr = Get-Printer -Name $c.printer -EA SilentlyContinue
    $pstat = 'Not found'
    if ($pr) { $pstat = "$($pr.PrinterStatus)"; if ($pr.WorkOffline) { $pstat = 'Offline' } }
    $log = @()
    if (Test-Path $logFile) { $log = @(Get-Content $logFile -Tail 15 | ForEach-Object { [string]$_ }); [array]::Reverse($log) }
    @{ urls = $urls; name = "http://$($env:COMPUTERNAME):$port"; open = ($c.open -ne '0'); lang = $c.lang; pin = $c.pin; printer = $c.printer
       printers = @(Get-Printer -EA SilentlyContinue | ForEach-Object { [string]$_.Name }); pstatus = $pstat; waiting = (Waiting)
       jobs = @(Get-PrintJob -PrinterName $c.printer -EA SilentlyContinue).Count; log = $log; office = (Get-Office) }
}

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

$sets = @{ orientation = 'auto', 'portrait', 'landscape'; color = 'color', 'gray'; duplex = 'off', 'long', 'short'
           margins = 'none', 'narrow', 'normal', 'wide'; scale = 'fit', 'actual' }

New-Item -ItemType Directory -Path $inbox, $up -Force | Out-Null
$pages = @{}
foreach ($p in 'print', 'admin') {
    $f = Join-Path $web "$p.html"
    $pages[$p] = if (Test-Path $f) { [IO.File]::ReadAllBytes($f) } else { [Text.Encoding]::UTF8.GetBytes("missing $f - run the installer again") }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$port/")
$listener.Start()

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request; $res = $ctx.Response
    try {
        $path = $req.Url.AbsolutePath.TrimEnd('/'); if (-not $path) { $path = '/' }
        $m = $req.HttpMethod

        # ------------------------------------------------ static files (page styles + scripts + pdf.js)
        if ($m -eq 'GET' -and $path -match '^/assets/([a-z0-9.-]+\.(css|js))$') {
            $name = $Matches[1]; $f = Join-Path $web $name
            if (Test-Path $f) { SendFile $res $f ($name -like 'pdf*') } else { Json $res 404 @{ error = 'Not found' } }
            continue
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
            if ($path -eq '/admin/set') {
                if ($null -ne $j.open) { $c.open = if ($j.open) { '1' } else { '0' } }
                if ($null -ne $j.lang) { if ($j.lang -notin 'fa', 'en') { Json $res 400 @{ error = 'Unknown language.' }; continue }; $c.lang = $j.lang }
                if ($null -ne $j.pin) {
                    if ($j.pin -notmatch '^[A-Za-z0-9]{0,20}$') { Json $res 400 @{ error = 'PIN: letters and numbers only, up to 20.' }; continue }
                    $c.pin = $j.pin
                }
                if ($null -ne $j.printer) {
                    if (-not (Get-Printer -Name $j.printer -EA SilentlyContinue)) { Json $res 400 @{ error = 'That printer does not exist.' }; continue }
                    $c.printer = $j.printer
                }
                Save-Cfg $c; Json $res 200 @{ ok = $true }
            }
            elseif ($path -eq '/admin/clear') {
                $n = @(Get-ChildItem $inbox -File -EA SilentlyContinue).Count
                Get-ChildItem $inbox -File -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
                $pj = @(Get-PrintJob -PrinterName $c.printer -EA SilentlyContinue)
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
        if ($m -eq 'GET' -and $path -eq '/') { Send $res 200 'text/html; charset=utf-8' $pages.print; continue }

        if ($m -eq 'GET' -and $path -eq '/status') {
            $c = Get-Cfg; $office = Get-Office
            Json $res 200 @{ waiting = (Waiting); pin = [bool]$c.pin; open = ($c.open -ne '0'); printer = $c.printer; lang = $c.lang
                             office = $office; types = @(Get-Types $office); caps = (Get-Caps $c.printer) }
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
            $fs = [IO.File]::Create($tmp); $buf = New-Object byte[] 65536; $total = 0; $tooBig = $false
            while (($n = $req.InputStream.Read($buf, 0, $buf.Length)) -gt 0) {
                $total += $n
                if ($total -gt $maxMB * 1MB) { $tooBig = $true; break }
                $fs.Write($buf, 0, $n)
            }
            $fs.Close()
            if ($tooBig) { Remove-Item $tmp -Force; Json $res 413 @{ error = 'File is bigger than 50 MB.' }; continue }
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
            else { Move-Item $tmp (Join-Path $up $src); [IO.File]::WriteAllText((Join-Path $up "$id.todo"), $ext); $state = 'converting' }
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
            $caps = Get-Caps $c.printer
            $copies = 1; [void][int]::TryParse([string]$j.copies, [ref]$copies); $copies = [Math]::Min([Math]::Max($copies, 1), 20)
            $nup = 1; [void][int]::TryParse([string]$j.nup, [ref]$nup)
            $okSet = $true
            foreach ($k in $sets.Keys) { if ([string]$j.$k -notin $sets[$k]) { $okSet = $false } }
            if ($nup -notin 1, 2, 4 -or [string]$j.pages -notmatch '^[0-9,\-\s]{0,200}$') { $okSet = $false }
            if (-not $okSet) { Json $res 400 @{ error = 'Bad settings.' }; continue }
            $paper = [string]$j.paper; if (-not ($caps.papers | Where-Object { $_.n -eq $paper })) { $paper = $caps.def }
            $color = if ($caps.color) { [string]$j.color } else { 'gray' }
            $duplex = if ($caps.duplex) { [string]$j.duplex } else { 'off' }

            $stamp = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), (Get-Random -Maximum 99999)
            $srcFile = if ($meta.kind -eq 'image') { Join-Path $up $meta.src } else { Join-Path $up "$id.pdf" }
            $ext = [IO.Path]::GetExtension($srcFile)
            $base = "$stamp-from$($meta.from)-c$copies"
            Move-Item $srcFile (Join-Path $inbox "$base$ext")
            $job = @{ file = "$base$ext"; name = $meta.name; copies = $copies; pages = [string]$j.pages; paper = $paper; orientation = [string]$j.orientation
                      color = $color; duplex = $duplex; margins = [string]$j.margins; scale = [string]$j.scale; nup = $nup; hm = $caps.hm }
            [IO.File]::WriteAllText((Join-Path $inbox "$base.tmp"), (ConvertTo-Json -Compress $job), [Text.Encoding]::UTF8)
            Move-Item (Join-Path $inbox "$base.tmp") (Join-Path $inbox "$base.json")
            Get-ChildItem $up -File -Filter "$id.*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
            Json $res 200 @{ ok = $true; waiting = (Waiting) }
            continue
        }

        Json $res 404 @{ error = 'Not found' }
    } catch {
        try { $res.Abort() } catch {}
    }
}
