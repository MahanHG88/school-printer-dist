#!/usr/bin/perl
# schoolprinter.pl - School Printer for macOS and Linux (https://print.mahanmirzaee.com)
# Same web app as the Windows version, for a Mac or Linux computer the printer is connected to.
#   Everyone on the network:  http://<this computer>:8631        upload, preview, choose settings, print
#   On this computer only:    http://localhost:8631/admin
# Prints through CUPS (lp). Word/Excel/PowerPoint are converted with LibreOffice if installed; text with cupsfilter.
# Core Perl only - nothing to install. Runs as a launchd/systemd service (user "nobody").
# Env for testing: SP_DIR (data dir), SP_PORT, SP_DRYRUN=1 (do not call lp).
use strict;
use warnings;
use IO::Socket::INET;
use POSIX qw(strftime WNOHANG);
use Fcntl qw(:flock);

my $DIR  = $ENV{SP_DIR} || ($^O eq 'darwin' ? '/Library/Application Support/SchoolPrinter' : '/opt/schoolprinter');
my $PORT = $ENV{SP_PORT} || 8631;
my $DRY  = ($ENV{SP_DRYRUN} || '') eq '1';
my $CFG  = "$DIR/config.txt";
my $LOG  = "$DIR/log.txt";
my $UP   = "$DIR/Uploads";
my $WEB  = "$DIR/web";
my $MAX  = 50 * 1024 * 1024;
$ENV{PATH} = '/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin';
$ENV{HOME} = $DIR;    # LibreOffice needs a writable home

my @BASE   = qw(pdf jpg jpeg png gif bmp tif tiff);
my @OFFICE = qw(doc docx rtf odt xls xlsx csv ods ppt pptx odp);
my %MIME   = (html => 'text/html; charset=utf-8', css => 'text/css; charset=utf-8', js => 'application/javascript; charset=utf-8',
              pdf => 'application/pdf', png => 'image/png', jpg => 'image/jpeg', gif => 'image/gif', bmp => 'image/bmp', tif => 'image/tiff');

sub slurp { my $f = shift; open(my $h, '<:raw', $f) or return ''; local $/; my $d = <$h>; close $h; defined $d ? $d : '' }
sub spit  { my ($f, $d) = @_; open(my $h, '>:raw', "$f.tmp") or return; print $h $d; close $h; rename "$f.tmp", $f }
my %PAGE = (print => slurp("$WEB/print.html"), admin => slurp("$WEB/admin.html"));

# ---------------------------------------------------------------- helpers
sub cmd {    # run a program (no shell); returns (exit code, output)
    my @a = @_;
    my $pid = open(my $h, '-|');
    return (-1, '') unless defined $pid;
    if (!$pid) { open(STDERR, '>&', \*STDOUT); exec { $a[0] } @a or exit 127 }
    local $/; my $o = <$h>; close $h;
    return ($? >> 8, defined $o ? $o : '');
}
sub cmd_out {    # like cmd, but only stdout (stderr discarded) - for programs that write data to stdout
    my @a = @_;
    my $pid = open(my $h, '-|');
    return (-1, '') unless defined $pid;
    if (!$pid) { open(STDERR, '>', '/dev/null'); exec { $a[0] } @a or exit 127 }
    binmode $h; local $/; my $o = <$h>; close $h;
    return ($? >> 8, defined $o ? $o : '');
}
sub which { my $n = shift; for (split /:/, $ENV{PATH}) { return "$_/$n" if -x "$_/$n" } undef }
my $SOFFICE = which('soffice') || which('libreoffice') || (-x '/Applications/LibreOffice.app/Contents/MacOS/soffice' ? '/Applications/LibreOffice.app/Contents/MacOS/soffice' : undef);
my $CUPSFILTER = which('cupsfilter');
sub office_state { $SOFFICE ? 'lo' : 'none' }
sub types { my @t = @BASE; push @t, 'txt' if $CUPSFILTER || $SOFFICE; push @t, @OFFICE if $SOFFICE; @t }

sub printers { my (undef, $o) = cmd('lpstat', '-e'); grep { length } split /\n/, $o }
sub default_printer { my (undef, $o) = cmd('lpstat', '-d'); return $1 if $o =~ /:\s*(\S.*?)\s*$/m; my @p = printers(); @p ? $p[0] : '' }
sub get_cfg {
    my %c = (pin => '', open => '1', printer => '', lang => 'fa');
    for (split /\n/, slurp($CFG)) { next if /^\s*#/; $c{$1} = $2 if /^\s*(\w+)\s*=\s*(.*?)\s*$/ }
    $c{printer} = default_printer() unless length $c{printer};
    return %c;
}
sub save_cfg { my %c = @_; spit($CFG, "# School Printer settings (also changeable on the admin page)\nprinter=$c{printer}\npin=$c{pin}\nopen=$c{open}\nlang=$c{lang}\n") }
sub has_printer { my $n = shift; length $n && grep { $_ eq $n } printers() }
sub pstatus { my $n = shift; return 'Not found' unless has_printer($n); my (undef, $o) = cmd('lpstat', '-p', $n); $o =~ /disabled/ ? 'Offline' : 'Normal' }
sub jobs { my $n = shift; return 0 unless length $n; my (undef, $o) = cmd('lpstat', '-o', $n); scalar grep { length } split /\n/, $o }
sub ipv4s {
    my @ip;
    if ($^O eq 'darwin') { for my $i (0 .. 8) { my (undef, $o) = cmd('ipconfig', 'getifaddr', "en$i"); $o =~ s/\s+//g; push @ip, $o if $o =~ /^\d+\.\d+\.\d+\.\d+$/ } }
    else { my (undef, $o) = cmd('ip', '-4', '-o', 'addr', 'show', 'scope', 'global');
           while ($o =~ /^\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)/mg) { push @ip, $2 unless $1 =~ /^(docker|br-|veth|virbr|tun|wg|tailscale|zt|lxc|cni|flannel)/ } }
    @ip;
}
my $HOSTNAME = do { my (undef, $n) = $^O eq 'darwin' ? cmd('scutil', '--get', 'LocalHostName') : cmd('hostname', '-s'); $n =~ s/\s+//g; length $n ? "$n.local" : 'localhost' };
sub logline {
    my $line = strftime('%Y-%m-%dT%H:%M:%S', localtime) . "  " . shift() . "\n";
    open(my $h, '>>', $LOG) or return; flock($h, LOCK_EX); print $h $line; my $big = -s $LOG > 1_000_000; close $h;
    if ($big) { my @l = split /\n/, slurp($LOG); @l = @l[-500 .. -1] if @l > 500; spit($LOG, join("\n", @l) . "\n") }
}
sub recent { my @l = grep { length } split /\n/, slurp($LOG); @l = @l[-15 .. -1] if @l > 15; [reverse @l] }

# ---- printer capabilities from the CUPS driver (lpoptions -l)
my %PAPERMM = (letter => [215.9, 279.4], legal => [215.9, 355.6], a4 => [210, 297], a5 => [148, 210], a3 => [297, 420], a6 => [105, 148],
               b5 => [176, 250], executive => [184.2, 266.7], tabloid => [279.4, 431.8], ledger => [279.4, 431.8], statement => [139.7, 215.9],
               env10 => [104.8, 241.3], envdl => [110, 220], envc5 => [162, 229], postcard => [100, 148]);
sub paper_mm {
    my $l = lc shift; $l =~ s/\.(fullbleed|duplex|borderless)$//;
    return $PAPERMM{$l} if $PAPERMM{$l};
    return [$1 * 25.4 / 72, $2 * 25.4 / 72] if $l =~ /^w(\d+(?:\.\d+)?)h(\d+(?:\.\d+)?)$/;
    return [$1, $2] if $l =~ /_(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)mm$/;
    return [$1 * 25.4, $2 * 25.4] if $l =~ /_(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)in$/;
    undef;
}
sub caps {
    my $pr = shift; my (@papers, $def, %seen);
    my (undef, $o) = length $pr ? cmd('lpoptions', '-p', $pr, '-l') : (0, '');
    if ($o =~ /^(?:PageSize|media)\/[^:]*:\s*(.*)$/mi) {
        for my $k (split ' ', $1) {
            my $isdef = $k =~ s/^\*//; my $mm = paper_mm($k) or next; next if $seen{$k}++;
            my ($w, $h) = sort { $a <=> $b } @$mm;
            push @papers, { n => $k, w => N(sprintf('%.1f', $w)), h => N(sprintf('%.1f', $h)) }; $def = $k if $isdef;
        }
    }
    @papers = ({ n => 'A4', w => N(210), h => N(297) }, { n => 'Letter', w => N(215.9), h => N(279.4) }) unless @papers;
    my $color  = $o =~ /^(?:ColorModel|print-color-mode|ColorMode)[^:]*:.*\b(RGB|CMYK|Color|color|CMY)\b/mi ? 1 : 0;
    my $duplex = $o =~ /^(?:Duplex|sides)[^:]*:.*(DuplexNoTumble|DuplexTumble|two-sided)/mi ? 1 : 0;
    return { papers => \@papers, def => $def || $papers[0]{n}, color => B($color), duplex => B($duplex), hm => N(4.2) };
}

# ---------------------------------------------------------------- tiny JSON
sub B { my $v = shift; bless \$v, 'SP::Bool' }
sub N { my $v = shift; bless \$v, 'SP::Num' }
sub jstr { my $s = shift; $s = '' unless defined $s; $s =~ s/(["\\])/\\$1/g; $s =~ s/\n/\\n/g; $s =~ s/\r/\\r/g; $s =~ s/\t/\\t/g;
           $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord $1)/ge; "\"$s\"" }
sub json {
    my $v = shift; my $r = ref $v;
    return '{' . join(',', map { jstr($_) . ':' . json($v->{$_}) } sort keys %$v) . '}' if $r eq 'HASH';
    return '[' . join(',', map { json($_) } @$v) . ']' if $r eq 'ARRAY';
    return $$v ? 'true' : 'false' if $r eq 'SP::Bool';
    return 0 + $$v if $r eq 'SP::Num';
    jstr($v);
}
sub jget {    # one string / number / bool field from a small flat JSON object
    my ($body, $k) = @_;
    return ($1 eq 'true' ? 1 : 0) if $body =~ /"\Q$k\E"\s*:\s*(true|false)/;
    return $1 if $body =~ /"\Q$k\E"\s*:\s*(-?\d+(?:\.\d+)?)/;
    if ($body =~ /"\Q$k\E"\s*:\s*"((?:[^"\\]|\\.)*)"/) { my $s = $1; $s =~ s/\\u([0-9a-fA-F]{4})/chr(hex $1)/ge; $s =~ s/\\(.)/$1/g; return $s }
    undef;
}

# ---------------------------------------------------------------- uploads
sub magic_ok {
    my ($path, $ext) = @_;
    open(my $h, '<:raw', $path) or return 0; read($h, my $b, 4096); close $h; $b = '' unless defined $b;
    return 0 if length $b < 4;
    return substr($b, 0, 4) eq '%PDF'                     if $ext eq 'pdf';
    return substr($b, 0, 2) eq "\xFF\xD8"                 if $ext =~ /^jpe?g$/;
    return substr($b, 0, 4) eq "\x89PNG"                  if $ext eq 'png';
    return substr($b, 0, 4) eq 'GIF8'                     if $ext eq 'gif';
    return substr($b, 0, 2) eq 'BM'                       if $ext eq 'bmp';
    return $b =~ /^(II\*\x00|MM\x00\*)/                   if $ext =~ /^tiff?$/;
    return substr($b, 0, 4) eq "PK\x03\x04"               if $ext =~ /^(docx|xlsx|pptx|odt|ods|odp)$/;
    return substr($b, 0, 4) eq "\xD0\xCF\x11\xE0"         if $ext =~ /^(doc|xls|ppt)$/;
    return substr($b, 0, 5) eq '{\rtf'                    if $ext eq 'rtf';
    return index($b, "\x00") < 0                          if $ext =~ /^(txt|csv)$/;
    0;
}
sub meta { my $id = shift; return undef unless $id =~ /^[a-f0-9]{32}$/; my $m = slurp("$UP/$id.meta"); return undef unless length $m;
           my %h; $h{$_} = jget($m, $_) for qw(name ext kind src from created); \%h }
sub state_of {
    my ($id, $m) = @_;
    return 'ready' if $m->{kind} eq 'image' || -e "$UP/$id.pdf";
    return 'failed' if -e "$UP/$id.fail" || time - $m->{created} > 180;
    'converting';
}
sub clean_uploads { opendir(my $d, $UP) or return; for (readdir $d) { next if /^\./; my $f = "$UP/$_"; unlink $f if -f $f && time - (stat $f)[9] > 3600 } closedir $d }
sub convert {    # in a forked worker: <id>.<ext> -> <id>.pdf (or <id>.fail)
    my ($id, $ext) = @_;
    my $in = "$UP/$id.$ext"; my $ok = 0;
    if ($ext eq 'txt' && $CUPSFILTER) {
        my ($st, $o) = cmd_out($CUPSFILTER, '-m', 'application/pdf', '-i', 'text/plain', $in);
        if ($st == 0 && substr($o, 0, 4) eq '%PDF') { spit("$UP/$id.pdf", $o); $ok = 1 }
    }
    if (!$ok && $SOFFICE) {
        mkdir "$UP/lo-$id";
        cmd($SOFFICE, "-env:UserInstallation=file://$DIR/lo-profile", '--headless', '--norestore', '--convert-to', 'pdf', '--outdir', "$UP/lo-$id", $in);
        if (-e "$UP/lo-$id/$id.pdf") { rename "$UP/lo-$id/$id.pdf", "$UP/$id.pdf"; $ok = 1 }
        rmdir "$UP/lo-$id";
    }
    spit("$UP/$id.fail", 'conversion failed') unless $ok;
}
sub do_print {    # in the request's worker, after the reply: settings -> lp options
    my ($file, $s, $label) = @_;
    my %c = get_cfg(); my $pr = $c{printer};
    my @o = ('-d', $pr, '-n', $s->{copies}, '-o', 'collate=true', '-t', "School Printer - " . ($s->{name} || 'document'));
    push @o, '-o', "media=$s->{paper}" if length $s->{paper};
    push @o, '-o', 'orientation-requested=' . ($s->{land} ? 4 : 3);
    (my $pg = $s->{pages}) =~ s/\s+//g; push @o, '-o', "page-ranges=$pg" if length $pg;
    push @o, '-o', "number-up=$s->{nup}" if $s->{nup} > 1;
    push @o, '-o', 'print-color-mode=monochrome', '-o', 'ColorModel=Gray' if $s->{color} eq 'gray';
    push @o, '-o', 'sides=' . { off => 'one-sided', long => 'two-sided-long-edge', short => 'two-sided-short-edge' }->{$s->{duplex}};
    my $m = { none => 0, narrow => 6.35, normal => 12.7, wide => 25.4 }->{$s->{margins}};
    if ($m) { my $pt = int($m * 72 / 25.4 + 0.5); push @o, '-o', "page-$_=$pt" for qw(left right top bottom) }
    push @o, $s->{scale} eq 'fit' ? ('-o', 'fit-to-page') : ('-o', 'print-scaling=none', '-o', 'scaling=100');
    my $code = '0';
    unless ($DRY) { my ($st, $out) = cmd('lp', @o, $file); if ($st) { $out =~ s/\s+/ /g; $code = "lp-$st: $out" } }
    else { $code = '0 (dry run: lp ' . join(' ', @o) . ')' if $ENV{SP_SHOWLP} }
    logline("$label  copies=$s->{copies}  exit=$code");
    unlink $file;
}

# ---------------------------------------------------------------- HTTP
my %REASON = (200 => 'OK', 400 => 'Bad Request', 403 => 'Forbidden', 404 => 'Not Found', 410 => 'Gone', 413 => 'Payload Too Large',
              415 => 'Unsupported Media Type', 500 => 'Internal Server Error', 503 => 'Service Unavailable');
sub reply {
    my ($c, $code, $type, $body, $cache) = @_;
    print $c "HTTP/1.1 $code $REASON{$code}\r\nContent-Type: $type\r\nContent-Length: " . length($body) .
        "\r\nCache-Control: " . ($cache ? 'max-age=86400' : 'no-store') . "\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n$body";
}
sub jreply { my ($c, $code, $obj) = @_; reply($c, $code, 'application/json; charset=utf-8', json($obj)) }
sub read_body {
    my ($c, $len, $got_already, $fh) = @_;
    my $mem = $fh ? '' : $got_already; print $fh $got_already if $fh;
    my $got = length $got_already;
    while ($got < $len) {
        my $want = $len - $got; $want = 65536 if $want > 65536;
        my $n = sysread($c, my $b, $want); return undef unless $n;
        $got += $n; if ($fh) { print $fh $b } else { $mem .= $b }
    }
    $fh ? 1 : $mem;
}

sub handle {
    my $c = shift;
    binmode $c; $c->autoflush(1);
    local $SIG{ALRM} = sub { die "timeout\n" }; alarm 300;
    my $peer = $c->peerhost || ''; my $local = $peer eq '127.0.0.1';
    my $head = '';
    while ($head !~ /\r\n\r\n/) { my $n = sysread($c, my $b, 16384); return unless $n; $head .= $b; return if length $head > 65536 }
    my ($h, $rest) = split /\r\n\r\n/, $head, 2; $rest = '' unless defined $rest;
    my @l = split /\r\n/, $h;
    my ($m, $path) = split / /, shift @l; return unless $path;
    $path =~ s/\?.*//; $path =~ s{(?<=.)/+$}{};
    my %H; for (@l) { $H{lc $1} = $2 if /^([^:]+):\s*(.*)$/ }
    my $len = $H{'content-length'} || 0; $len = 0 unless $len =~ /^\d+$/;

    if ($m eq 'GET' && $path =~ m{^/assets/([a-z0-9.-]+\.(css|js))$}) {
        my $f = "$WEB/$1"; return -f $f ? reply($c, 200, $MIME{$2}, slurp($f), $1 =~ /^pdf/) : jreply($c, 404, { error => 'Not found' });
    }

    if ($path =~ m{^/admin}) {    # admin: this computer only; X-Admin stops other web pages posting here
        return jreply($c, 403, { error => 'The admin page only works on the printer computer.' }) unless $local;
        return reply($c, 200, $MIME{html}, $PAGE{admin}) if $m eq 'GET' && $path eq '/admin';
        return jreply($c, 403, { error => 'Forbidden' }) unless ($H{'x-admin'} || '') eq '1';
        my %cf = get_cfg(); my $pr = $cf{printer};
        if ($m eq 'GET' && $path eq '/admin/info') {
            return jreply($c, 200, { urls => [map {"http://$_:$PORT"} ipv4s()], name => "http://$HOSTNAME:$PORT", open => B($cf{open} ne '0'),
                pin => $cf{pin}, lang => $cf{lang}, printer => $pr, printers => [printers()], pstatus => pstatus($pr), waiting => N(jobs($pr)),
                jobs => N(jobs($pr)), log => recent(), office => office_state() });
        }
        return jreply($c, 404, { error => 'Not found' }) unless $m eq 'POST' && $len <= 65536;
        my $body = read_body($c, $len, $rest); return unless defined $body;
        if ($path eq '/admin/set') {
            my ($o, $lg, $pin, $p) = map { jget($body, $_) } qw(open lang pin printer);
            $cf{open} = $o ? '1' : '0' if defined $o;
            if (defined $lg) { return jreply($c, 400, { error => 'Unknown language.' }) unless $lg =~ /^(fa|en)$/; $cf{lang} = $lg }
            if (defined $pin) { return jreply($c, 400, { error => 'PIN: letters and numbers only, up to 20.' }) unless $pin =~ /^[A-Za-z0-9]{0,20}$/; $cf{pin} = $pin }
            if (defined $p) { return jreply($c, 400, { error => 'That printer does not exist.' }) unless has_printer($p); $cf{printer} = $p }
            save_cfg(%cf); return jreply($c, 200, { ok => B(1) });
        }
        if ($path eq '/admin/clear') { my $j = jobs($pr); cmd('cancel', '-a', $pr) if !$DRY && length $pr; return jreply($c, 200, { removed => N($j) }) }
        if ($path eq '/admin/testpage') {
            return jreply($c, 500, { error => 'Printer not found.' }) unless has_printer($pr);
            return jreply($c, 200, { ok => B(1) }) if $DRY;
            my $pid = open(my $lp, '|-'); if (!$pid) { exec 'lp', '-d', $pr, '-t', 'School Printer test page' or exit 127 }
            print $lp "School Printer - test page\n\nPrinter:  $pr\nComputer: $HOSTNAME\nTime:     " . localtime() . "\n\nIf you can read this, printing works.\n";
            close $lp; return $? ? jreply($c, 500, { error => 'Could not print a test page.' }) : jreply($c, 200, { ok => B(1) });
        }
        return jreply($c, 404, { error => 'Not found' });
    }

    return reply($c, 200, $MIME{html}, $PAGE{print}) if $m eq 'GET' && $path eq '/';
    if ($m eq 'GET' && $path eq '/status') {
        my %cf = get_cfg();
        return jreply($c, 200, { waiting => N(jobs($cf{printer})), pin => B(length $cf{pin}), open => B($cf{open} ne '0'), printer => $cf{printer},
            lang => $cf{lang}, office => office_state(), types => [types()], caps => caps($cf{printer}) });
    }
    if ($m eq 'POST' && $path eq '/upload') {
        my %cf = get_cfg();
        return jreply($c, 503, { error => 'Printing is closed right now.' }) if $cf{open} eq '0';
        return jreply($c, 403, { error => 'Wrong PIN.' }) if length $cf{pin} && ($H{'x-pin'} || '') ne $cf{pin};
        return jreply($c, 413, { error => 'File is bigger than 50 MB.' }) if $len > $MAX;
        clean_uploads();
        (my $name = $H{'x-filename'} || '') =~ s/%([0-9A-Fa-f]{2})/chr(hex $1)/ge; $name =~ s{[\\/:*?"<>|\x00-\x1f]}{_}g; $name = substr($name, -120);
        my $ext = $name =~ /\.([A-Za-z0-9]{1,5})$/ ? lc $1 : '';
        my $id = join '', map { sprintf '%02x', int rand 256 } 1 .. 16;
        my $tmp = "$UP/$id.part";
        open(my $fh, '>:raw', $tmp) or return jreply($c, 500, { error => 'Cannot save the file.' });
        my $ok = read_body($c, $len, $rest, $fh); close $fh;
        unless ($ok) { unlink $tmp; return }
        if (!$ext) { for my $e (qw(pdf png jpg)) { if (magic_ok($tmp, $e)) { $ext = $e; last } } }
        $ext = 'jpg' if $ext eq 'jpeg'; $ext = 'tif' if $ext eq 'tiff';
        unless (grep({ $_ eq $ext } types()) && magic_ok($tmp, $ext)) { unlink $tmp; return jreply($c, 415, { error => "This type of file can't be printed." }) }
        my ($kind, $src, $state) = ('pdf', "$id.$ext", 'ready');
        if ($ext =~ /^(jpg|png|gif)$/) { $kind = 'image'; rename $tmp, "$UP/$src" }
        elsif ($ext =~ /^(bmp|tif)$/) {
            $kind = 'image';
            if ($^O eq 'darwin') { cmd('sips', '-s', 'format', 'png', $tmp, '--out', "$UP/$id.png"); if (-e "$UP/$id.png") { $src = "$id.png"; unlink $tmp } else { rename $tmp, "$UP/$src" } }
            else { rename $tmp, "$UP/$src" }
        }
        elsif ($ext eq 'pdf') { rename $tmp, "$UP/$src" }
        else { rename $tmp, "$UP/$src"; $state = 'converting'; my $pid = fork; if (defined $pid && !$pid) { $SIG{ALRM} = 'DEFAULT'; alarm 170; convert($id, $ext); exit 0 } }
        (my $from = $peer) =~ s/[^0-9A-Fa-f.]/_/g;
        spit("$UP/$id.meta", json({ name => $name, ext => $ext, kind => $kind, src => $src, from => $from, created => N(time) }));
        return jreply($c, 200, { id => $id, kind => $kind, state => $state });
    }
    if ($m eq 'GET' && $path =~ m{^/info/([a-f0-9]{32})$}) {
        my $id = $1; my $mt = meta($id) or return jreply($c, 200, { state => 'gone' });
        return jreply($c, 200, { state => state_of($id, $mt), kind => $mt->{kind} });
    }
    if ($m eq 'GET' && $path =~ m{^/file/([a-f0-9]{32})$}) {
        my $id = $1; my $mt = meta($id);
        return jreply($c, 404, { error => 'GONE' }) unless $mt && state_of($id, $mt) eq 'ready';
        my $f = $mt->{kind} eq 'image' ? $mt->{src} : "$id.pdf"; my ($e) = $f =~ /\.(\w+)$/;
        return reply($c, 200, $MIME{$e} || 'application/octet-stream', slurp("$UP/$f"));
    }
    if ($m eq 'POST' && $path eq '/print') {
        my %cf = get_cfg();
        return jreply($c, 503, { error => 'Printing is closed right now.' }) if $cf{open} eq '0';
        return jreply($c, 403, { error => 'Wrong PIN.' }) if length $cf{pin} && ($H{'x-pin'} || '') ne $cf{pin};
        return jreply($c, 400, { error => 'Bad settings.' }) if $len > 65536;
        my $body = read_body($c, $len, $rest); return unless defined $body;
        my $id = jget($body, 'id') || ''; my $mt = meta($id);
        return jreply($c, 410, { error => 'GONE' }) unless $mt && state_of($id, $mt) eq 'ready';
        my %s = map { $_ => jget($body, $_) } qw(copies pages paper orientation color duplex margins scale nup land);
        $s{$_} = '' for grep { !defined $s{$_} } keys %s;
        my %ok = (orientation => qr/^(auto|portrait|landscape)$/, color => qr/^(color|gray)$/, duplex => qr/^(off|long|short)$/,
                  margins => qr/^(none|narrow|normal|wide)$/, scale => qr/^(fit|actual)$/, nup => qr/^[124]$/, pages => qr/^[0-9,\-\s]{0,200}$/);
        for (keys %ok) { return jreply($c, 400, { error => 'Bad settings.' }) unless $s{$_} =~ $ok{$_} }
        $s{copies} = ($s{copies} =~ /^\d+$/ && $s{copies} >= 1) ? ($s{copies} > 20 ? 20 : $s{copies}) : 1;
        $s{land} = $s{orientation} eq 'landscape' ? 1 : $s{orientation} eq 'portrait' ? 0 : ($s{land} ? 1 : 0);
        my $cp = caps($cf{printer});
        $s{paper} = $cp->{def} unless grep { $_->{n} eq $s{paper} } @{ $cp->{papers} };
        $s{color} = 'gray' unless ${ $cp->{color} }; $s{duplex} = 'off' unless ${ $cp->{duplex} };
        $s{name} = $mt->{name};
        my $f = $mt->{kind} eq 'image' ? "$UP/$mt->{src}" : "$UP/$id.pdf";
        my ($e) = $f =~ /(\.\w+)$/;
        my $label = strftime('%Y%m%d-%H%M%S', localtime) . '-' . int(rand(99999)) . "-from$mt->{from}-c$s{copies}$e";
        my $job = "$UP/job-$label"; rename $f, $job;
        unlink glob("$UP/$id.*");
        jreply($c, 200, { ok => B(1), waiting => N(jobs($cf{printer}) + 1) });
        close $c;
        do_print($job, \%s, $label);
        return;
    }
    jreply($c, 404, { error => 'Not found' });
}

# ---------------------------------------------------------------- main
$SIG{PIPE} = 'IGNORE';
mkdir $DIR; mkdir $UP;
my $srv = IO::Socket::INET->new(LocalPort => $PORT, Listen => 64, ReuseAddr => 1, Proto => 'tcp') or die "cannot listen on port $PORT: $!\n";
print STDERR "School Printer listening on :$PORT (data: $DIR, LibreOffice: " . ($SOFFICE || 'none') . ")\n";
$SIG{CHLD} = sub { 1 while waitpid(-1, WNOHANG) > 0 };
while (1) {
    my $c = $srv->accept or next;
    my $pid = fork;
    if (!defined $pid) { close $c; next }
    if (!$pid) { $SIG{CHLD} = 'DEFAULT'; close $srv; eval { handle($c) }; close $c; exit 0 }
    close $c;
}
