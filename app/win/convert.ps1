# convert.ps1 - School Printer: turns Word / Excel / PowerPoint / text uploads into PDF.
# Runs hidden in the signed-in user's session (task "MacPrint Convert", at sign-in), because Microsoft Office
# refuses to run as SYSTEM. Uses Microsoft Office if installed, otherwise LibreOffice. Macros are disabled.
# Protocol: PrintServer.ps1 writes Uploads\<id>.<ext> + <id>.todo; this writes <id>.pdf or <id>.fail.
param([string]$Up = 'C:\ProgramData\MacPrint\Uploads')   # -Up: test copies only
$up = $Up
$mutex = New-Object System.Threading.Mutex($false, 'Local\SchoolPrinterConvert')
if (-not $mutex.WaitOne(0)) { exit }       # one converter per signed-in session

$lo = @('C:\Program Files\LibreOffice\program\soffice.exe', 'C:\Program Files (x86)\LibreOffice\program\soffice.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
$has = @{}; foreach ($a in 'Word', 'Excel', 'PowerPoint') { $has[$a] = Test-Path "Registry::HKEY_CLASSES_ROOT\$a.Application\CLSID" }
$app = @{ doc = 'Word'; docx = 'Word'; rtf = 'Word'; odt = 'Word'; txt = 'Word'; xls = 'Excel'; xlsx = 'Excel'; csv = 'Excel'; ods = 'Excel'; ppt = 'PowerPoint'; pptx = 'PowerPoint'; odp = 'PowerPoint' }

# Runs in a separate process so a stuck Office can be killed after the time limit.
$job = {
    param($in, $out, $kind, $ext, $lo)
    $ErrorActionPreference = 'Stop'
    function Free($o) { if ($o) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch {} } }
    if ($kind -eq 'Word') {
        $w = New-Object -ComObject Word.Application
        try {
            $w.Visible = $false; $w.DisplayAlerts = 0; $w.AutomationSecurity = 3
            # password '-' instead of a prompt; text opened as UTF-8 without the encoding dialog
            if ($ext -eq 'txt') { $d = $w.Documents.Open($in, $false, $true, $false, '-', '-', $false, '-', '-', 5, 65001, $false, $false, 0, $true) }
            else { $d = $w.Documents.Open($in, $false, $true, $false, '-', '-', $false, '-', '-') }
            $d.ExportAsFixedFormat($out, 17); $d.Close($false); Free $d
        } finally { $w.Quit(); Free $w }
    } elseif ($kind -eq 'Excel') {
        $x = New-Object -ComObject Excel.Application
        try {
            $x.Visible = $false; $x.DisplayAlerts = $false; $x.AutomationSecurity = 3; $x.ScreenUpdating = $false
            $b = $x.Workbooks.Open($in, 0, $true, [Type]::Missing, '-', '-', $true)
            foreach ($ws in $b.Worksheets) { try { $ws.PageSetup.Zoom = $false; $ws.PageSetup.FitToPagesWide = 1; $ws.PageSetup.FitToPagesTall = $false } catch {} }
            $b.ExportAsFixedFormat(0, $out); $b.Close($false); Free $b
        } finally { $x.Quit(); Free $x }
    } elseif ($kind -eq 'PowerPoint') {
        $p = New-Object -ComObject PowerPoint.Application
        try {
            try { $p.AutomationSecurity = 3 } catch {}
            $r = $p.Presentations.Open($in, -1, 0, 0)
            $r.SaveAs($out, 32); $r.Close(); Free $r
        } finally { $p.Quit(); Free $p }
    } else {
        $dir = Split-Path $out
        $prof = 'file:///' + ($env:LOCALAPPDATA -replace '\\', '/') + '/SchoolPrinter/lo'
        & $lo "-env:UserInstallation=$prof" --headless --norestore --nolockcheck --convert-to pdf --outdir $dir $in | Out-Null
        $made = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($in) + '.pdf')
        if (-not (Test-Path $made)) { throw 'LibreOffice could not convert the file.' }
        Move-Item $made $out -Force
    }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}

while ($true) {
    try { [IO.File]::WriteAllText("$up\converter.alive", "$env:USERNAME $(Get-Date -Format o)") } catch {}
    foreach ($t in @(Get-ChildItem $up -Filter *.todo -EA SilentlyContinue)) {
        $id = $t.BaseName
        $claim = "$up\$id.doing"
        try { Rename-Item $t.FullName $claim -EA Stop } catch { continue }     # another session took it
        $ext = ([IO.File]::ReadAllText($claim)).Trim()
        $in = "$up\$id.$ext"; $out = "$up\$id.out.pdf"
        $kind = $app[$ext]; if (-not $has[$kind]) { $kind = if ($lo) { 'LibreOffice' } else { '' } }
        $err = ''
        if (-not $kind -or -not (Test-Path $in)) { $err = 'No program to convert this file.' }
        else {
            $started = Get-Date
            $j = Start-Job -ScriptBlock $job -ArgumentList $in, $out, $kind, $ext, $lo
            if (Wait-Job $j -Timeout 120) { try { Receive-Job $j -ErrorAction Stop | Out-Null } catch { $err = $_.Exception.Message } }
            else {
                $err = 'Timed out.'
                Stop-Job $j
                $me = (Get-Process -Id $PID).SessionId
                Get-Process WINWORD, EXCEL, POWERPNT, soffice.bin -EA SilentlyContinue | Where-Object { $_.SessionId -eq $me -and $_.StartTime -ge $started } | Stop-Process -Force -EA SilentlyContinue
            }
            Remove-Job $j -Force -EA SilentlyContinue
            if (-not $err -and -not (Test-Path $out)) { $err = 'No PDF was produced.' }
        }
        if ($err) { [IO.File]::WriteAllText("$up\$id.fail", $err) } else { Move-Item $out "$up\$id.pdf" -Force }
        Remove-Item $claim -Force -EA SilentlyContinue
    }
    Start-Sleep -Milliseconds 700
}
