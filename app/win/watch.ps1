# watch.ps1 - School Printer print engine for Windows (task "MacPrint Inbox", runs as SYSTEM).
# Prints each job in the Inbox: <base>.json (settings from the web page) + <base>.pdf|png|jpg|gif.
# A bare .pdf/.png/.jpg without .json (e.g. from the Mac "Print on Windows PC" menu) prints with defaults.
# PDFs are drawn with Windows' own PDF renderer (Windows.Data.Pdf) - no extra software. The sheet layout is
# the SAME maths as the web preview (print.js), so what you see is what comes out.
# Every document is read into memory first: the file itself is never held open, so it can always be deleted after
# printing. (Windows' PDF reader kept the file open; the delete failed silently, the leftover PDF was picked up again
# as a new job, and the log filled with failing prints every few seconds.) Each file is tried once.
$root  = if ($env:SP_ROOT) { $env:SP_ROOT } else { 'C:\ProgramData\MacPrint' }   # SP_ROOT / SP_TESTOUT: test copies only
$inbox = Join-Path $root 'Inbox'
$log   = Join-Path $root 'log.txt'
Add-Type -AssemblyName System.Drawing, System.Runtime.WindowsRuntime
. (Join-Path $PSScriptRoot 'sync.ps1')
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$wrt = [System.WindowsRuntimeSystemExtensions].GetMethods()
$asOp  = $wrt | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
$asAct = $wrt | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
function Await($op, [Type]$t) { $task = $asOp.MakeGenericMethod($t).Invoke($null, @($op)); [void]$task.Wait(120000); $task.Result }
function AwaitA($a) { [void]$asAct.Invoke($null, @($a)).Wait(120000) }

$MARG = @{ none = 0.0; narrow = 6.35; normal = 12.7; wide = 25.4 }
$H = 100 / 25.4    # millimetres -> hundredths of an inch (System.Drawing printer units)

function Get-PrinterName { (Sp-Cfg).printer }    # never a "School Printer" queue (see sync.ps1)

# ---- source document: list of page sizes (mm) + a renderer
function Open-Source($path) {
    $mem = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path))
    if ([IO.Path]::GetExtension($path) -eq '.pdf') {
        $ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($mem)
        $d = Await ([Windows.Data.Pdf.PdfDocument]::LoadFromStreamAsync($ras)) ([Windows.Data.Pdf.PdfDocument])
        if (-not $d) { $ras.Dispose(); $mem.Dispose(); throw 'This PDF could not be opened.' }
        $sizes = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $d.PageCount; $i++) { $p = $d.GetPage($i); $sizes.Add(@(($p.Size.Width * 25.4 / 96), ($p.Size.Height * 25.4 / 96))); $p.Dispose() }
        return @{ kind = 'pdf'; doc = $d; sizes = $sizes; mem = $mem; ras = $ras }
    }
    $img = [System.Drawing.Image]::FromStream($mem)
    if ($img.PropertyIdList -contains 274) {    # phone photos: turn them the right way up
        switch ([int]$img.GetPropertyItem(274).Value[0]) {
            3 { $img.RotateFlip('Rotate180FlipNone') } 6 { $img.RotateFlip('Rotate90FlipNone') } 8 { $img.RotateFlip('Rotate270FlipNone') }
        }
    }
    $sizes = New-Object System.Collections.Generic.List[object]
    $sizes.Add(@(($img.Width * 25.4 / 96), ($img.Height * 25.4 / 96)))
    @{ kind = 'img'; img = $img; sizes = $sizes; mem = $mem }
}
function Render-Page($src, $i, $wpx) {
    if ($src.kind -eq 'img') { return $src.img }
    $p = $src.doc.GetPage($i)
    $ms = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
    $o = New-Object Windows.Data.Pdf.PdfPageRenderOptions
    $o.DestinationWidth = [uint32]$wpx
    $o.DestinationHeight = [uint32][math]::Max(1, [math]::Round($wpx * $p.Size.Height / $p.Size.Width))
    AwaitA ($p.RenderToStreamAsync($ms, $o)); $p.Dispose()
    $s = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($ms.GetInputStreamAt(0))
    $tmp = [System.Drawing.Image]::FromStream($s)
    $bmp = New-Object System.Drawing.Bitmap $tmp; $tmp.Dispose(); $s.Dispose(); $ms.Dispose()
    $bmp
}

# ---- layout (identical to print.js)
function Get-Selection($txt, $n) {
    $all = 0..($n - 1)
    if (-not $txt -or -not $txt.Trim()) { return $all }
    $out = New-Object System.Collections.Generic.SortedSet[int]
    foreach ($part in $txt.Split(',')) {
        if (-not $part.Trim()) { continue }
        $ab = $part.Split('-'); $a = [int]$ab[0]; $b = if ($ab.Count -gt 1) { [int]$ab[1] } else { $a }
        if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
        for ($k = [math]::Max(1, $a); $k -le [math]::Min($n, $b); $k++) { [void]$out.Add($k - 1) }
    }
    if ($out.Count) { return @($out) } else { return $all }
}
function Get-Layout($s, $sizes, $pw, $ph, $hm) {
    $sel = @(Get-Selection $s.pages $sizes.Count)
    $first = $sizes[$sel[0]]; $pageLand = $first[0] -gt $first[1]; $nup = [int]$s.nup
    switch ($s.orientation) { 'portrait' { $land = $false } 'landscape' { $land = $true } default { $land = if ($nup -eq 2) { -not $pageLand } else { $pageLand } } }
    $W = if ($land) { $ph } else { $pw }; $Hh = if ($land) { $pw } else { $ph }
    $m = [math]::Max($MARG[[string]$s.margins], [double]$hm)
    $cols = 1; $rows = 1; if ($nup -eq 4) { $cols = 2; $rows = 2 } elseif ($nup -eq 2) { if ($land) { $cols = 2 } else { $rows = 2 } }
    $sheets = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $sel.Count; $i += $nup) { $sheets.Add(@($sel[$i..([math]::Min($i + $nup, $sel.Count) - 1)])) }
    @{ land = $land; W = $W; H = $Hh; m = $m; cols = $cols; rows = $rows; cw = ($W - 2 * $m) / $cols; ch = ($Hh - 2 * $m) / $rows; sheets = $sheets }
}
function Get-Place($L, $k, $size, $scale) {
    $c = $k % $L.cols; $r = [math]::Floor($k / $L.cols); $x0 = $L.m + $c * $L.cw; $y0 = $L.m + $r * $L.ch
    $f = if ($scale -eq 'fit') { [math]::Min($L.cw / $size[0], $L.ch / $size[1]) } else { 1 }
    $w = $size[0] * $f; $h = $size[1] * $f
    @{ cx = $x0; cy = $y0; x = $x0 + ($L.cw - $w) / 2; y = $y0 + ($L.ch - $h) / 2; w = $w; h = $h }
}

$gray = New-Object System.Drawing.Imaging.ImageAttributes
$gray.SetColorMatrix((New-Object System.Drawing.Imaging.ColorMatrix(, [single[][]]@(
    [single[]](.299, .299, .299, 0, 0), [single[]](.587, .587, .587, 0, 0), [single[]](.114, .114, .114, 0, 0),
    [single[]](0, 0, 0, 1, 0), [single[]](0, 0, 0, 0, 1)))))

function Print-Job($file, $s, $printer) {
    $src = $null
    try {
        if (-not $printer) { return 'printer-not-found' }
        $src = Open-Source $file
        $pd = New-Object System.Drawing.Printing.PrintDocument
        $pd.PrinterSettings.PrinterName = $printer
        if ($env:SP_TESTOUT) { $pd.PrinterSettings.PrintToFile = $true; $pd.PrinterSettings.PrintFileName = Join-Path $env:SP_TESTOUT ([IO.Path]::GetFileNameWithoutExtension($file) + '.pdf') }   # test hook
        if (-not $pd.PrinterSettings.IsValid) { return 'printer-not-found' }
        $ps = $pd.PrinterSettings
        $paper = $ps.PaperSizes | Where-Object { $_.PaperName -eq $s.paper } | Select-Object -First 1
        if (-not $paper) { $paper = $pd.DefaultPageSettings.PaperSize }
        $pw = [math]::Min($paper.Width, $paper.Height) * 0.254; $ph = [math]::Max($paper.Width, $paper.Height) * 0.254
        $hm = if ($null -ne $s.hm) { [double]$s.hm } else { [math]::Max($pd.DefaultPageSettings.HardMarginX, $pd.DefaultPageSettings.HardMarginY) * 0.254 }
        $L = Get-Layout $s $src.sizes $pw $ph $hm
        $pd.DefaultPageSettings.PaperSize = $paper
        $pd.DefaultPageSettings.Landscape = $L.land
        $pd.DefaultPageSettings.Color = ($s.color -eq 'color' -and $ps.SupportsColor)
        if ($ps.CanDuplex) {
            $ps.Duplex = switch ($s.duplex) {
                'long'  { if ($L.land) { 'Horizontal' } else { 'Vertical' } }
                'short' { if ($L.land) { 'Vertical' } else { 'Horizontal' } }
                default { 'Simplex' }
            }
        }
        $pd.DocumentName = $(if ($s.name) { "School Printer - $($s.name)" } else { 'School Printer' }) + $(if ($s.jid) { " [$(([string]$s.jid).Substring(0, 6))]" } else { '' })
        $pd.PrintController = New-Object System.Drawing.Printing.StandardPrintController
        $order = New-Object System.Collections.Generic.List[object]          # collated copies
        for ($c = 0; $c -lt [int]$s.copies; $c++) { foreach ($sh in $L.sheets) { $order.Add($sh) } }
        $script:si = 0
        $pd.add_PrintPage({
            param($sender, $e)
            $g = $e.Graphics
            $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'HighQuality'; $g.PixelOffsetMode = 'HighQuality'
            $hx = $e.PageSettings.HardMarginX; $hy = $e.PageSettings.HardMarginY      # drawing origin = printable corner
            $sheet = $order[$script:si]
            for ($k = 0; $k -lt $sheet.Count; $k++) {
                $i = $sheet[$k]; $p = Get-Place $L $k $src.sizes[$i] $s.scale
                $wpx = [int][math]::Min(3400, [math]::Max(300, $p.w / 25.4 * 300))   # ~300 dpi
                $bmp = Render-Page $src $i $wpx
                $g.SetClip((New-Object System.Drawing.RectangleF ([single]($p.cx * $H - $hx)), ([single]($p.cy * $H - $hy)), ([single]($L.cw * $H)), ([single]($L.ch * $H))))
                $dest = New-Object System.Drawing.Rectangle ([int][math]::Round($p.x * $H - $hx)), ([int][math]::Round($p.y * $H - $hy)), ([int][math]::Round($p.w * $H)), ([int][math]::Round($p.h * $H))
                if ($s.color -eq 'gray') { $g.DrawImage($bmp, $dest, 0, 0, $bmp.Width, $bmp.Height, [System.Drawing.GraphicsUnit]::Pixel, $gray) }
                else { $g.DrawImage($bmp, $dest) }
                $g.ResetClip()
                if ($src.kind -eq 'pdf') { $bmp.Dispose() }
            }
            $script:si++
            $e.HasMorePages = $script:si -lt $order.Count
        })
        $pd.Print()
        return 0
    } catch {
        return 'error: ' + $_.Exception.Message
    } finally {
        if ($src) { if ($src.kind -eq 'img') { $src.img.Dispose() }; if ($src.ras) { $src.ras.Dispose() }; if ($src.mem) { $src.mem.Dispose() } }
    }
}

$defaults = @{ copies = 1; pages = ''; paper = ''; orientation = 'auto'; color = 'color'; duplex = 'off'; margins = 'none'; scale = 'fit'; nup = 1 }
$tried = @{}    # file -> time: every file is printed at most once, even if it cannot be deleted
function Done-With([string[]]$paths) {
    foreach ($p in $paths) {
        Remove-Item -LiteralPath $p -Force -EA SilentlyContinue
        if (Test-Path -LiteralPath $p) { try { Move-Item -LiteralPath $p -Destination "$p.done" -Force -EA Stop } catch { $script:tried[$p] = Get-Date } }
    }
}
while ($true) {
    foreach ($k in @($tried.Keys)) { if (-not (Test-Path -LiteralPath $k)) { $tried.Remove($k) } elseif (((Get-Date) - $tried[$k]).TotalMinutes -gt 30) { Remove-Item -LiteralPath $k -Force -EA SilentlyContinue } }
    Get-ChildItem $inbox -Filter *.done -File -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
    $printer = Get-PrinterName
    $jobs = @(Get-ChildItem $inbox -File -Filter *.json -EA SilentlyContinue | Sort-Object LastWriteTime)
    $loose = @(Get-ChildItem $inbox -File -EA SilentlyContinue | Where-Object {
        $_.Extension -in '.pdf', '.png', '.jpg', '.jpeg', '.gif' -and -not $tried.ContainsKey($_.FullName) -and -not (Test-Path ([IO.Path]::ChangeExtension($_.FullName, '.json'))) -and
        ((Get-Date) - $_.LastWriteTime).TotalSeconds -gt 3 })
    foreach ($j in $jobs) {
        $s = $null; try { $s = [IO.File]::ReadAllText($j.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch {}
        $file = if ($s) { Join-Path $inbox $s.file } else { $null }
        if (-not $s -or -not (Test-Path $file) -or $tried.ContainsKey($file)) { Remove-Item $j.FullName -Force -EA SilentlyContinue; continue }
        $code = Print-Job $file $s $printer
        Add-Content $log "$(Get-Date -Format s)  $($s.file)  copies=$($s.copies)  exit=$code"
        if ($s.jid) { if ($code -eq 0) { Sp-JobSet ([string]$s.jid) @{ state = 'printing' } } else { Sp-JobSet ([string]$s.jid) @{ state = 'failed'; err = [string]$code } } }
        Done-With @($file, $j.FullName)
    }
    foreach ($f in $loose) {    # Mac PDF menu / older senders
        try { $h = [IO.File]::Open($f.FullName, 'Open', 'Read', 'None'); $h.Close() } catch { continue }
        $s = $defaults.Clone()
        if ($f.BaseName -match '-c(\d+)$') { $s.copies = [Math]::Min([Math]::Max([int]$Matches[1], 1), 20) }
        $s = [pscustomobject]$s
        $code = Print-Job $f.FullName $s $printer
        Add-Content $log "$(Get-Date -Format s)  $($f.Name)  copies=$($s.copies)  exit=$code"
        Done-With @($f.FullName)
    }
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Get-Content $log -Tail 500 | Set-Content "$log.tmp"; Move-Item "$log.tmp" $log -Force }
    Start-Sleep -Seconds 2
}
