# control.ps1 - School Printer: the "Start School Printer" / "Stop School Printer" desktop shortcuts.
#   start: starts every School Printer task, waits until the page answers, opens the admin page in the browser
#   stop:  stops them all (they start again with Windows, or with "Start School Printer")
param([ValidateSet('start', 'stop')][string]$Do = 'start')
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" $Do"
    exit
}
Add-Type -AssemblyName PresentationFramework
$tasks = 'MacPrint Web', 'MacPrint Inbox', 'MacPrint Sync', 'MacPrint DNS'
if ($Do -eq 'stop') {
    foreach ($t in $tasks + 'MacPrint Convert') { Stop-ScheduledTask -TaskName $t -EA SilentlyContinue }
    [void][Windows.MessageBox]::Show('School Printer is stopped. Nobody can print or scan here until you start it again (or restart this computer).', 'School Printer', 'OK', 'Information')
    exit
}
foreach ($t in $tasks) { $x = Get-ScheduledTask -TaskName $t -EA SilentlyContinue; if ($x -and $x.State -ne 'Running') { Start-ScheduledTask -TaskName $t } }
Start-ScheduledTask -TaskName 'MacPrint Convert' -EA SilentlyContinue
$ok = $false
for ($i = 0; $i -lt 40 -and -not $ok; $i++) { try { $null = Invoke-WebRequest -UseBasicParsing 'http://localhost:8631/status' -TimeoutSec 2; $ok = $true } catch { Start-Sleep -Milliseconds 500 } }
if ($ok) { Start-Process 'http://localhost:8631/admin' }
else { [void][Windows.MessageBox]::Show('School Printer did not start. Restart this computer; if it still does not start, run the installer again.', 'School Printer', 'OK', 'Warning') }
