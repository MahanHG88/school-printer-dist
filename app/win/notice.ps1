# notice.ps1 - School Printer: "this computer is now the main station" pop-up on the signed-in user's screen.
# Started by convert.ps1 (the user's session) when syncd.ps1 writes Uploads\main.notice. Closes itself after 2 minutes.
param([string]$File)
$n = $null; try { $n = Get-Content -Raw -LiteralPath $File | ConvertFrom-Json } catch {}
$fa = $n -and [string]$n.lang -eq 'fa'
$t = if ($fa) {
    @{ title = 'این رایانه اکنون ایستگاه اصلی است'
       text  = 'چاپگر مدرسه این رایانه را به‌عنوان ایستگاه اصلی شبکه انتخاب کرد. صفحهٔ چاپ و اسکن همه از این رایانه باز می‌شود؛ لطفاً آن را روشن و متصل نگه دارید.'
       open  = 'باز کردن صفحهٔ مدیریت'; ok = 'باشه' }
} else {
    @{ title = 'This computer is now the main station'
       text  = "School Printer chose this computer as the network's main station. Everyone's print and scan page is now served from here, so please keep it switched on and connected."
       open  = 'Open admin page'; ok = 'OK' }
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$w = New-Object Windows.Window
$w.WindowStyle = 'None'; $w.AllowsTransparency = $true; $w.Background = 'Transparent'; $w.Topmost = $true; $w.ShowInTaskbar = $true
$w.SizeToContent = 'Height'; $w.Width = 400; $w.Title = 'School Printer'
if ($fa) { $w.FlowDirection = 'RightToLeft' }
$card = New-Object Windows.Controls.Border
$card.CornerRadius = 14; $card.Padding = 22; $card.Margin = 12; $card.Background = '#FFFFFFFF'; $card.BorderBrush = '#FF5B5BF6'; $card.BorderThickness = 2
$card.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ BlurRadius = 18; ShadowDepth = 3; Opacity = 0.3 }
$sp = New-Object Windows.Controls.StackPanel
$badge = New-Object Windows.Controls.TextBlock -Property @{ Text = [string][char]0x2605; FontSize = 30; Foreground = '#FF5B5BF6'; Margin = '0,0,0,6' }
$h = New-Object Windows.Controls.TextBlock -Property @{ Text = $t.title; FontSize = 17; FontWeight = 'SemiBold'; TextWrapping = 'Wrap'; Foreground = '#FF1E1E2E' }
$p = New-Object Windows.Controls.TextBlock -Property @{ Text = $t.text; FontSize = 13; TextWrapping = 'Wrap'; Margin = '0,8,0,16'; Foreground = '#FF44475A' }
$row = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal'; HorizontalAlignment = 'Right' }
if ($fa) { $row.HorizontalAlignment = 'Left' }
$b1 = New-Object Windows.Controls.Button -Property @{ Content = $t.open; Padding = '12,6'; Margin = '0,0,8,0' }
$b2 = New-Object Windows.Controls.Button -Property @{ Content = $t.ok; Padding = '18,6'; IsDefault = $true }
$b1.Add_Click({ Start-Process 'http://localhost:8631/admin'; $w.Close() }); $b2.Add_Click({ $w.Close() })
[void]$row.Children.Add($b1); [void]$row.Children.Add($b2)
foreach ($c in $badge, $h, $p, $row) { [void]$sp.Children.Add($c) }
$card.Child = $sp; $w.Content = $card
$w.Add_Loaded({ $a = [Windows.SystemParameters]::WorkArea; $w.Left = $a.Right - $w.ActualWidth - 8; $w.Top = $a.Bottom - $w.ActualHeight - 8 })
$timer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromMinutes(2) }; $timer.Add_Tick({ $w.Close() }); $timer.Start()
[void]$w.ShowDialog()
