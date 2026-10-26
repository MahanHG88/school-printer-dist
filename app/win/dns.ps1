# dns.ps1 - School Printer: answers the school address (e.g. print.school) on this network (task "MacPrint DNS", SYSTEM).
# When the router hands out the School Printer computers as DNS servers, every device can type the school address:
# it resolves to the main station; every other name is passed on unchanged to this PC's own DNS server.
# Off while no school address is set (admin page), or when "Answer DNS" is switched off on this station.
$root = if ($env:SP_ROOT) { $env:SP_ROOT } else { 'C:\ProgramData\MacPrint' }
. (Join-Path $PSScriptRoot 'sync.ps1')
$state = Join-Path $SpSync 'dns.json'
function Say([string]$s, [string]$err = '') { try { Sp-Write $state ([ordered]@{ state = $s; err = $err; at = (Sp-Now) }) } catch {} }
function Upstreams {    # this PC's own DNS servers (never itself), else the router
    $mine = @(Sp-LanIPs | ForEach-Object { $_.IPAddress })
    $u = @(Get-DnsClientServerAddress -AddressFamily IPv4 -EA SilentlyContinue | ForEach-Object { $_.ServerAddresses } |
           Where-Object { $_ -and $_ -notmatch '^(127\.|0\.)' -and $_ -notin $mine } | Select-Object -Unique)
    if (-not $u.Count) { $u = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue | ForEach-Object { $_.NextHop } | Where-Object { $_ -ne '0.0.0.0' } | Select-Object -Unique) }
    $u
}
function Qname([byte[]]$b, [int]$n) {    # (name, offset after the question) from a query
    $i = 12; $parts = @()
    while ($i -lt $n -and $b[$i] -ne 0) { $l = [int]$b[$i]; if ($l -gt 63 -or $i + 1 + $l -gt $n) { return $null }; $parts += [Text.Encoding]::ASCII.GetString($b, $i + 1, $l); $i += 1 + $l }
    if ($i + 5 -gt $n) { return $null }
    @{ name = ($parts -join '.').ToLower(); end = $i + 5; type = ([int]$b[$i + 1] -shl 8) -bor [int]$b[$i + 2] }
}
function Answer([byte[]]$q, $qn, [byte[]]$ip) {    # A record for the school address (AAAA and others: no data)
    $ms = New-Object IO.MemoryStream
    $ms.Write($q, 0, 2)                                                       # same id
    $ms.WriteByte(0x84 -bor ($q[2] -band 0x01)); $ms.WriteByte(0x80)          # response, authoritative, recursion available
    $isA = $qn.type -eq 1 -or $qn.type -eq 255
    $ms.Write([byte[]](0, 1, 0, $(if ($isA) { 1 } else { 0 }), 0, 0, 0, 0), 0, 8)
    $ms.Write($q, 12, $qn.end - 12)                                           # the question
    if ($isA) { $ms.Write([byte[]](0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4), 0, 12); $ms.Write($ip, 0, 4) }
    $ms.ToArray()
}

$srv = $null; $out = $null; $pending = @{}; $nextId = Get-Random -Maximum 65535; $lastCheck = [datetime]::MinValue; $c = $null; $ups = @()
while ($true) {
    if (((Get-Date) - $lastCheck).TotalSeconds -ge 5) {
        $lastCheck = Get-Date; $c = Sp-Cfg
        if (-not $c.domain -or $c.dns -eq '0') { if ($srv) { $srv.Close(); $out.Close(); $srv = $null }; Say 'off'; Start-Sleep -Seconds 5; continue }
        if (-not $srv) {
            try {
                $srv = New-Object Net.Sockets.UdpClient (New-Object Net.IPEndPoint ([Net.IPAddress]::Any, $(if ($env:SP_DNSPORT) { [int]$env:SP_DNSPORT } else { 53 })))
                $out = New-Object Net.Sockets.UdpClient 0
            } catch { $srv = $null; Say 'busy' $_.Exception.Message; Start-Sleep -Seconds 60; continue }    # port 53 in use (another DNS server)
        }
        $ups = @(Upstreams); Say 'on'
        $l = Sp-Leader; $lip = ([uri][string]$l.url).Host
        if ($l.id -ne (Sp-NodeId) -and -not (Sp-Stations | Where-Object { $_.id -eq $l.id -and $_.online })) { $lip = ([uri](Sp-MyUrl)).Host }
        try { $ansIp = ([Net.IPAddress]::Parse($lip)).GetAddressBytes() } catch { $ansIp = ([Net.IPAddress]::Parse(([uri](Sp-MyUrl)).Host)).GetAddressBytes() }
        foreach ($k in @($pending.Keys)) { if (((Get-Date) - $pending[$k].t).TotalSeconds -gt 5) { $pending.Remove($k) } }
    }
    $r = New-Object Collections.ArrayList; [void]$r.Add($srv.Client); [void]$r.Add($out.Client)
    try { [Net.Sockets.Socket]::Select($r, $null, $null, 1000000) } catch { continue }
    foreach ($sock in $r) {
        $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any, 0)
        try { $b = if ($sock -eq $srv.Client) { $srv.Receive([ref]$ep) } else { $out.Receive([ref]$ep) } } catch { continue }
        if ($b.Length -lt 12) { continue }
        if ($sock -eq $srv.Client) {    # a question from a device
            $qn = Qname $b $b.Length
            if ($qn -and ($qn.name -eq $c.domain -or $qn.name.EndsWith('.' + $c.domain))) { $a = Answer $b $qn $ansIp; [void]$srv.Send($a, $a.Length, $ep); continue }
            if (-not $ups.Count) { continue }
            $nextId = ($nextId + 1) % 65536; $pending[$nextId] = @{ ep = $ep; id0 = $b[0]; id1 = $b[1]; t = Get-Date }
            $b[0] = [byte]($nextId -shr 8); $b[1] = [byte]($nextId -band 255)
            [void]$out.Send($b, $b.Length, (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($ups[0]), 53)))
        } else {    # the upstream answer: back to the device that asked
            $id = ([int]$b[0] -shl 8) -bor [int]$b[1]; $p = $pending[$id]; if (-not $p) { continue }
            $pending.Remove($id); $b[0] = $p.id0; $b[1] = $p.id1
            [void]$srv.Send($b, $b.Length, $p.ep)
        }
    }
}
