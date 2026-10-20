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
              pdf => 'application/pdf', png => 'image/png', jpg => 'image/jpeg', gif => 'image/gif', bmp => 'image/bmp', tif => 'image/tiff',
              woff2 => 'font/woff2');

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
    push @o, '-o', 'orientation-requested=' . ($s->{land} ? 4 : 3) unless $s->{orient_auto};
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
    if ($ENV{SP_TESTOUT}) { rename $file, "$ENV{SP_TESTOUT}/$label" } else { unlink $file }    # test hook, like watch.ps1
}


# ---------------------------------------------------------------- IPP printer ("Add to this device")
# Devices add ipp://<this computer>:8631/ipp/print with their own driverless driver (macOS/Linux IPP Everywhere,
# Windows IPP Class Driver) and print PDF/JPEG/PNG from any app; jobs go through do_print like the web page's.
my $IPP_JOB = time % 100000;
sub read_chunked {
    my ($c, $buf) = @_; my $out = '';
    while (1) {
        while ($buf !~ /\r\n/) { my $n = sysread($c, my $b, 65536); return undef unless $n; $buf .= $b }
        $buf =~ s/^([0-9a-fA-F]+)[^\r\n]*\r\n// or return undef; my $sz = hex $1;
        last if $sz == 0;
        while (length($buf) < $sz + 2) { my $n = sysread($c, my $b, 65536); return undef unless $n; $buf .= $b }
        $out .= substr($buf, 0, $sz); $buf = substr($buf, $sz + 2);
        return undef if length $out > $MAX + 1048576;
    }
    $out;
}
sub ipp_parse {
    my $b = shift; my %r = (major => ord(substr($b, 0, 1)), op => unpack('n', substr($b, 2, 2)), id => unpack('N', substr($b, 4, 4)), a => {}, mx => 0, my => 0);
    my ($i, $name, $depth, $member) = (8, '', 0, '');
    while ($i < length $b) {
        my $tag = ord(substr($b, $i, 1)); $i++;
        last if $tag == 0x03; next if $tag <= 0x0F;
        my $nl = unpack('n', substr($b, $i, 2)); $i += 2; $name = substr($b, $i, $nl) if $nl; $i += $nl;
        my $vl = unpack('n', substr($b, $i, 2)); $i += 2; my $v = substr($b, $i, $vl); $i += $vl;
        if ($tag == 0x34) { $depth++; next } if ($tag == 0x37) { $depth--; next } if ($tag == 0x4A) { $member = $v; next }
        if ($depth) { $r{mx} = unpack('N', $v) if $tag == 0x21 && $member eq 'x-dimension'; $r{my} = unpack('N', $v) if $tag == 0x21 && $member eq 'y-dimension'; next }
        my $val = ($tag == 0x21 || $tag == 0x23) ? unpack('l>', $v) : $tag == 0x22 ? ord($v) : $v;
        push @{ $r{a}{$name} }, $val;
    }
    $r{data} = substr($b, $i); \%r;
}
sub ia { my ($r, $k, $d) = @_; $r->{a}{$k} ? $r->{a}{$k}[0] : $d }
sub ia_attr {    # one attribute with one or more values
    my ($tag, $name, @vals) = @_; my $o = ''; my $first = 1;
    for my $v (@vals) {
        $o .= chr($tag) . pack('n', $first ? length $name : 0) . ($first ? $name : ''); $first = 0;
        if ($tag == 0x21 || $tag == 0x23) { $o .= pack('n', 4) . pack('l>', $v) }
        elsif ($tag == 0x22) { $o .= pack('n', 1) . chr($v ? 1 : 0) }
        elsif ($tag == 0x33) { $o .= pack('n', 8) . pack('l>l>', @$v) }
        elsif ($tag == 0x32) { $o .= pack('n', 9) . pack('l>l>C', $v, $v, 3) }
        else { $o .= pack('n', length $v) . $v }
    }
    $o;
}
sub ia_member { my $m = shift; chr(0x4A) . pack('n', 0) . pack('n', length $m) . $m }
sub ia_mediacol {
    my ($name, $w, $h) = @_;
    my $o = chr(0x34) . pack('n', length $name) . $name . pack('n', 0) . ia_member('media-size') . chr(0x34) . pack('nn', 0, 0);
    $o .= ia_member('x-dimension') . chr(0x21) . pack('nn', 0, 4) . pack('l>', int($w * 100 + .5));
    $o .= ia_member('y-dimension') . chr(0x21) . pack('nn', 0, 4) . pack('l>', int($h * 100 + .5));
    $o .= chr(0x37) . pack('nn', 0, 0);
    $o .= ia_member("media-$_-margin") . chr(0x21) . pack('nn', 0, 4) . pack('l>', 0) for qw(bottom left right top);   # 0: see ipp.ps1
    $o . chr(0x37) . pack('nn', 0, 0);
}
my %PWG = (letter => 'na_letter_8.5x11in', legal => 'na_legal_8.5x14in', a4 => 'iso_a4_210x297mm', a5 => 'iso_a5_148x210mm', a3 => 'iso_a3_297x420mm',
           a6 => 'iso_a6_105x148mm', b5 => 'iso_b5_176x250mm', executive => 'na_executive_7.25x10.5in', tabloid => 'na_ledger_11x17in', statement => 'na_invoice_5.5x8.5in');
sub pwg { my $p = shift; my $k = lc $p->{n}; return $PWG{$k} if $PWG{$k}; return $p->{n} if $p->{n} =~ /^[a-z]+_[a-z0-9.-]+_[\d.]+x[\d.]+(mm|in)$/;
          (my $slug = lc $p->{n}) =~ s/[^a-z0-9]+/-/g; sprintf('custom_%s_%sx%smm', $slug || 'paper', ${ $p->{w} } + 0, ${ $p->{h} } + 0) }
sub ipp_reply {
    my ($c, $r, $status, $body) = @_;
    my $maj = ($r->{major} == 1 || $r->{major} == 2) ? $r->{major} : 2;
    my $o = chr($maj) . chr($maj == 1 ? 1 : 0) . pack('n', $status) . pack('N', $r->{id});
    $o .= chr(0x01) . ia_attr(0x47, 'attributes-charset', 'utf-8') . ia_attr(0x48, 'attributes-natural-language', 'en') . ($body || '') . chr(0x03);
    reply($c, 200, 'application/ipp', $o);
}
sub ipp_handle {
    my ($c, $body, $peer, $hostport, $H) = @_;
    return reply($c, 400, 'text/plain', 'bad request') if length $body < 9;
    my $r = ipp_parse($body); my %cf = get_cfg(); my $cp = caps($cf{printer});
    my $uri = "ipp://$hostport/ipp/print"; my $open = $cf{open} ne '0';
    if (length $cf{pin} && ($r->{op} == 0x0002 || $r->{op} == 0x0004)) {    # PIN only for printing (see ipp.ps1)
        my ($b64) = ($H->{authorization} || '') =~ /^Basic\s+(\S+)/; my $ok = 0;
        if ($b64) { require MIME::Base64; my $up = MIME::Base64::decode_base64($b64); $up =~ s/^[^:]*://; $ok = $up eq $cf{pin} }
        unless ($ok) { print $c "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"School Printer\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"; return }
    }
    my $op = $r->{op};
    if ($op == 0x000B) {
        my @papers = @{ $cp->{papers} }; my @media = map { pwg($_) } @papers; @media = ('iso_a4_210x297mm') unless @media;
        my ($def) = grep { $_->{n} eq $cp->{def} } @papers; my $mdef = $def ? pwg($def) : $media[0];
        my ($color, $duplex) = (${ $cp->{color} }, ${ $cp->{duplex} });
        my $o = chr(0x04);
        $o .= ia_attr(0x45, 'printer-uri-supported', $uri) . ia_attr(0x44, 'uri-security-supported', 'none') . ia_attr(0x44, 'uri-authentication-supported', length $cf{pin} ? 'basic' : 'none');
        $o .= ia_attr(0x42, 'printer-name', 'School Printer') . ia_attr(0x41, 'printer-info', "School Printer - $cf{printer}") . ia_attr(0x41, 'printer-location', $HOSTNAME);
        $o .= ia_attr(0x41, 'printer-make-and-model', "School Printer ($cf{printer})") . ia_attr(0x45, 'printer-more-info', "http://$hostport/");
        $o .= ia_attr(0x45, 'printer-uuid', 'urn:uuid:' . uuid()) . ia_attr(0x41, 'printer-device-id', "MFG:School Printer;MDL:$cf{printer};CMD:PDF,JPEG,PNG;");
        $o .= ia_attr(0x23, 'printer-state', $open ? 3 : 5) . ia_attr(0x44, 'printer-state-reasons', $open ? 'none' : 'paused') . ia_attr(0x22, 'printer-is-accepting-jobs', $open ? 1 : 0);
        $o .= ia_attr(0x21, 'queued-job-count', 0) . ia_attr(0x21, 'printer-up-time', time % 2147483647) . ia_attr(0x44, 'ipp-versions-supported', '1.1', '2.0');
        $o .= ia_attr(0x23, 'operations-supported', 0x02, 0x04, 0x08, 0x09, 0x0A, 0x0B);
        $o .= ia_attr(0x47, 'charset-configured', 'utf-8') . ia_attr(0x47, 'charset-supported', 'utf-8') . ia_attr(0x48, 'natural-language-configured', 'en') . ia_attr(0x48, 'generated-natural-language-supported', 'en');
        $o .= ia_attr(0x49, 'document-format-default', 'application/pdf') . ia_attr(0x49, 'document-format-supported', 'application/pdf', 'image/jpeg', 'image/png', 'application/octet-stream');
        $o .= ia_attr(0x44, 'compression-supported', 'none') . ia_attr(0x44, 'pdl-override-supported', 'attempted') . ia_attr(0x44, 'printer-kind', 'document', 'photo');
        $o .= ia_attr(0x21, 'copies-default', 1) . ia_attr(0x33, 'copies-supported', [1, 20]) . ia_attr(0x23, 'finishings-default', 3) . ia_attr(0x23, 'finishings-supported', 3);
        $o .= ia_attr(0x44, 'media-default', $mdef) . ia_attr(0x44, 'media-supported', @media) . ia_attr(0x44, 'media-ready', $mdef);
        $o .= ia_attr(0x21, "media-$_-margin-supported", 0) for qw(bottom top left right);
        my ($dw, $dh) = $def ? (${ $def->{w} }, ${ $def->{h} }) : (210, 297);
        $o .= ia_mediacol('media-col-default', $dw, $dh) . ia_mediacol('media-col-ready', $dw, $dh);
        my $first = 1; for my $p (@papers) { $o .= ia_mediacol($first ? 'media-col-database' : '', ${ $p->{w} }, ${ $p->{h} }); $first = 0 }
        $o .= ia_attr(0x44, 'media-col-supported', 'media-size', 'media-bottom-margin', 'media-left-margin', 'media-right-margin', 'media-top-margin');
        $o .= ia_attr(0x23, 'orientation-requested-default', 3) . ia_attr(0x23, 'orientation-requested-supported', 3, 4);
        $o .= ia_attr(0x44, 'print-color-mode-default', $color ? 'color' : 'monochrome') . ia_attr(0x44, 'print-color-mode-supported', $color ? ('monochrome', 'color') : ('monochrome'));
        $o .= ia_attr(0x22, 'color-supported', $color ? 1 : 0) . ia_attr(0x44, 'sides-default', 'one-sided');
        $o .= ia_attr(0x44, 'sides-supported', $duplex ? ('one-sided', 'two-sided-long-edge', 'two-sided-short-edge') : ('one-sided'));
        $o .= ia_attr(0x44, 'print-scaling-default', 'fit') . ia_attr(0x44, 'print-scaling-supported', 'auto', 'fit', 'none');
        $o .= ia_attr(0x23, 'print-quality-default', 4) . ia_attr(0x23, 'print-quality-supported', 4) . ia_attr(0x32, 'printer-resolution-default', 300) . ia_attr(0x32, 'printer-resolution-supported', 300);
        $o .= ia_attr(0x22, 'page-ranges-supported', 0) . ia_attr(0x21, 'number-up-default', 1) . ia_attr(0x21, 'number-up-supported', 1);
        $o .= ia_attr(0x44, 'job-creation-attributes-supported', 'copies', 'media', 'media-col', 'orientation-requested', 'print-color-mode', 'print-scaling', 'sides');
        $o .= ia_attr(0x44, 'multiple-document-handling-supported', 'separate-documents-uncollated-copies') . ia_attr(0x44, 'which-jobs-supported', 'completed', 'not-completed');
        return ipp_reply($c, $r, 0, $o);
    }
    if ($op == 0x0004) { return $open ? ipp_reply($c, $r, 0) : ipp_reply($c, $r, 0x0506, ia_attr(0x41, 'status-message', 'Printing is closed right now.')) }
    if ($op == 0x0002) {
        return ipp_reply($c, $r, 0x0506, ia_attr(0x41, 'status-message', 'Printing is closed right now.')) unless $open;
        my $d = $r->{data}; my $ext = substr($d, 0, 4) eq '%PDF' ? 'pdf' : substr($d, 0, 4) eq "\x89PNG" ? 'png' : substr($d, 0, 2) eq "\xFF\xD8" ? 'jpg' : '';
        return ipp_reply($c, $r, 0x040A, ia_attr(0x41, 'status-message', 'Send PDF, JPEG or PNG.')) unless $ext;
        my $copies = ia($r, 'copies', 1); $copies = 1 if $copies < 1; $copies = 20 if $copies > 20;
        my $sides = ia($r, 'sides', 'one-sided'); my $o = ia($r, 'orientation-requested', 0); my $cm = ia($r, 'print-color-mode', 'auto');
        my %s = (copies => $copies, pages => '', nup => 1, margins => 'none', name => ia($r, 'job-name', 'Document'),
                 duplex => !${ $cp->{duplex} } ? 'off' : $sides eq 'two-sided-long-edge' ? 'long' : $sides eq 'two-sided-short-edge' ? 'short' : 'off',
                 color => (${ $cp->{color} } && $cm !~ /monochrome/) ? 'color' : 'gray', scale => ia($r, 'print-scaling', 'fit') eq 'none' ? 'actual' : 'fit',
                 land => ($o == 4 || $o == 5) ? 1 : 0, orient_auto => ($o == 3 || $o == 4 || $o == 5) ? 0 : 1);
        my ($wmm, $hmm) = $r->{mx} ? ($r->{mx} / 100, $r->{my} / 100) : (0, 0);
        my $mk = ia($r, 'media', ''); $s{paper} = $cp->{def};
        for my $p (@{ $cp->{papers} }) { if (pwg($p) eq $mk) { $s{paper} = $p->{n}; $wmm = 0 } }
        if (!$wmm && $mk =~ /_([\d.]+)x([\d.]+)(mm|in)$/) { my $f = $3 eq 'in' ? 25.4 : 1; ($wmm, $hmm) = ($1 * $f, $2 * $f) }
        if ($wmm) { my ($a, $b) = sort { $a <=> $b } ($wmm, $hmm); for my $p (@{ $cp->{papers} }) { $s{paper} = $p->{n} if abs(${ $p->{w} } - $a) < 2 && abs(${ $p->{h} } - $b) < 2 } }
        (my $from = $peer) =~ s/[^0-9A-Fa-f.]/_/g;
        my $label = strftime('%Y%m%d-%H%M%S', localtime) . '-' . int(rand(99999)) . "-from$from-c$copies.$ext";
        spit("$UP/job-$label", $d); my $jid = ++$IPP_JOB;
        ipp_reply($c, $r, 0, chr(0x02) . ia_attr(0x21, 'job-id', $jid) . ia_attr(0x45, 'job-uri', "$uri/$jid") . ia_attr(0x23, 'job-state', 9) . ia_attr(0x44, 'job-state-reasons', 'job-completed-successfully'));
        close $c; do_print("$UP/job-$label", \%s, $label); return;
    }
    if ($op == 0x0009) { my $j = ia($r, 'job-id', 0); return ipp_reply($c, $r, 0, chr(0x02) . ia_attr(0x21, 'job-id', $j) . ia_attr(0x45, 'job-uri', "$uri/$j") . ia_attr(0x23, 'job-state', 9) . ia_attr(0x44, 'job-state-reasons', 'job-completed-successfully')) }
    return ipp_reply($c, $r, 0) if $op == 0x000A || $op == 0x0008;
    ipp_reply($c, $r, 0x0501, ia_attr(0x41, 'status-message', 'Operation not supported.'));
}
sub uuid { my $f = "$DIR/printer-uuid.txt"; my $u = slurp($f); $u =~ s/\s+//g; return $u if $u;
           $u = join('-', map { join '', map { sprintf '%02x', int rand 256 } 1 .. $_ } 4, 2, 2, 2, 6); spit($f, $u); $u }
sub add_script {    # same as Ipp-AddScript in ipp.ps1
    my $hp = shift;
    return <<"EOS";
#!/bin/bash
# School Printer - add the printer at $hp to this Mac (or Linux computer) so every app can print to it.
# Uses the system's own driverless "IPP Everywhere" driver; nothing else is installed.
set -e
URI="ipp://$hp/ipp/print"; Q="School_Printer"
B=\$'\\e[1m'; G=\$'\\e[38;5;42m'; D=\$'\\e[2m'; R=\$'\\e[0m'
printf '\\n  %sSchool Printer%s  %sadding %s%s\\n' "\$B" "\$R" "\$D" "\$URI" "\$R"
add() { lpadmin -p "\$Q" -D "School Printer" -L "$hp" -E -v "\$URI" -m everywhere "\$@"; }
if ! add 2>/dev/null; then echo "  Your password is needed to add a printer:"; sudo -p "  Password: " lpadmin -p "\$Q" -D "School Printer" -L "$hp" -E -v "\$URI" -m everywhere; fi
if [ "\$(uname -s)" = Darwin ]; then
    # macOS never sends a copies count to a driverless printer and silently prints one copy; with
    # cupsManualCopies True its own PDF converter writes the copies into the job instead (tested 2026-10-20)
    P="/etc/cups/ppd/\$Q.ppd"; T="\$(mktemp)"
    if [ -r "\$P" ] && ! grep -q cupsManualCopies "\$P"; then
        awk '{print} /^\\*cupsVersion:/{print "*cupsManualCopies: True"}' "\$P" > "\$T"
        lpadmin -p "\$Q" -P "\$T" 2>/dev/null || sudo lpadmin -p "\$Q" -P "\$T"
    fi
    rm -f "\$T"
fi
printf '  %sDone.%s Choose %s"School Printer"%s in any app'"'"'s Print dialog.\\n\\n' "\$G" "\$R" "\$B" "\$R"
EOS
}
sub add_cmd {
    my $hp = shift; my $u = "http://$hp/ipp/print";
    join("\r\n", '@echo off', 'title Add School Printer', 'echo.', "echo   School Printer  -  adding $u", 'echo.',
        qq{powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Add-Printer -IppURL '$u' -ErrorAction Stop; Write-Host '  Added. Choose School Printer in any app''s Print dialog.' -ForegroundColor Green; exit 0 } catch { Write-Host ('  Could not add it automatically: ' + \$_.Exception.Message) -ForegroundColor Yellow; exit 1 }"},
        'if errorlevel 1 (', '  echo   Opening printer settings: press "Add device" and choose "School Printer".', '  start ms-settings:printers', ')', 'echo.', 'pause') . "\r\n";
}
sub announce {    # mDNS _ipp._tcp so the printer shows up in print dialogs; child process lives as long as we do
    my %cf = get_cfg(); my $cp = caps($cf{printer});
    my @txt = ('txtvers=1', 'qtotal=1', 'rp=ipp/print', "ty=School Printer ($cf{printer})", 'product=(School Printer)', 'pdl=application/pdf,image/jpeg,image/png',
               'Color=' . (${ $cp->{color} } ? 'T' : 'F'), 'Duplex=' . (${ $cp->{duplex} } ? 'T' : 'F'), 'UUID=' . uuid(), "note=$HOSTNAME", "adminurl=http://$HOSTNAME:$PORT/");
    my @cmd = $^O eq 'darwin' ? ('dns-sd', '-R', 'School Printer', '_ipp._tcp', 'local', $PORT, @txt)
            : which('avahi-publish-service') ? ('avahi-publish-service', 'School Printer', '_ipp._tcp', $PORT, @txt) : ();
    return unless @cmd && which($cmd[0]);
    my $pid = fork; if (defined $pid && !$pid) { open(STDOUT, '>', '/dev/null'); open(STDERR, '>', '/dev/null'); exec @cmd; exit 0 }
    return $pid;
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

    if ($m eq 'GET' && $path =~ m{^/assets/([a-z0-9.-]+\.(css|js|woff2))$}) {
        my $f = "$WEB/$1"; return -f $f ? reply($c, 200, $MIME{$2}, slurp($f), $1 =~ /^pdf|woff2$/) : jreply($c, 404, { error => 'Not found' });
    }
    my $hostport = $H{host} || "$HOSTNAME:$PORT";
    if ($m eq 'GET' && $path eq '/add.sh') { return reply($c, 200, 'text/plain; charset=utf-8', add_script($hostport)) }
    if ($m eq 'GET' && $path eq '/add-printer.cmd') { return reply($c, 200, 'application/octet-stream', add_cmd($hostport)) }
    if ($m eq 'POST' && $path =~ m{^/ipp/print(/\d+)?$}) {
        return reply($c, 413, 'text/plain', 'too large') if $len > $MAX;
        my $body = ($H{'transfer-encoding'} || '') =~ /chunked/i ? read_chunked($c, $rest) : read_body($c, $len, $rest);
        return unless defined $body;
        return ipp_handle($c, $body, $peer, $hostport, \%H);
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
our $MAIN_PID = $$;
mkdir $DIR; mkdir $UP;
my $srv = IO::Socket::INET->new(LocalPort => $PORT, Listen => 64, ReuseAddr => 1, Proto => 'tcp') or die "cannot listen on port $PORT: $!\n";
my $MDNS = announce(); $SIG{TERM} = $SIG{INT} = sub { exit 0 }; END { kill 'TERM', $MDNS if $MDNS && $$ == $MAIN_PID }
print STDERR "School Printer listening on :$PORT (data: $DIR, LibreOffice: " . ($SOFFICE || 'none') . ")\n";
$SIG{CHLD} = sub { 1 while waitpid(-1, WNOHANG) > 0 };
while (1) {
    my $c = $srv->accept or next;
    my $pid = fork;
    if (!defined $pid) { close $c; next }
    if (!$pid) { $SIG{CHLD} = 'DEFAULT'; close $srv; eval { handle($c) }; close $c; exit 0 }
    close $c;
}
