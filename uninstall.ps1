# School Printer - uninstaller. Removes the tasks, firewall rule and shortcut.
# Asks before deleting C:\ProgramData\MacPrint (it may also hold the Mac PDF inbox share).
function Uninstall-SchoolPrinter {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        if ($PSCommandPath) { Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`"" }
        else { Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"[Net.ServicePointManager]::SecurityProtocol=3072; iex ((New-Object Net.WebClient).DownloadString('https://print.mahanmirzaee.com/uninstall.ps1'))`"" }
        return
    }
    foreach ($t in 'MacPrint Web', 'MacPrint Inbox', 'MacPrint Convert') {
        Stop-ScheduledTask -TaskName $t -EA SilentlyContinue
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -EA SilentlyContinue
    }
    Remove-NetFirewallRule -DisplayName 'MacPrint Web' -EA SilentlyContinue
    Remove-Item "$env:PUBLIC\Desktop\School Printer (Admin).url" -EA SilentlyContinue
    Write-Host 'School Printer stopped and removed from startup.' -ForegroundColor Green
    $a = Read-Host 'Also delete C:\ProgramData\MacPrint (program files, settings, print log)? [y/N]'
    if ($a -match '^[yY]') {
        Get-SmbShare -EA SilentlyContinue | Where-Object { $_.Path -like 'C:\ProgramData\MacPrint*' } | Remove-SmbShare -Force -EA SilentlyContinue
        Remove-Item 'C:\ProgramData\MacPrint' -Recurse -Force -EA SilentlyContinue
        Write-Host 'Deleted.' -ForegroundColor Green
    }
}
Uninstall-SchoolPrinter
