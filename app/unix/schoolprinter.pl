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
use Socket qw(pack_sockaddr_in);
use POSIX qw(strftime WNOHANG);
use Fcntl qw(:flock);
use IO::Select;
use Time::HiRes ();
use MIME::Base64 ();

my $DIR  = $ENV{SP_DIR} || ($^O eq 'darwin' ? '/Library/Application Support/SchoolPrinter' : '/opt/schoolprinter');
my $PORT = $ENV{SP_PORT} || 8631;
my $DRY  = ($ENV{SP_DRYRUN} || '') eq '1';
my $CFG  = "$DIR/config.txt";
my $LOG  = "$DIR/log.txt";
my $UP   = "$DIR/Uploads";
my $WEB  = "$DIR/web";
my $MAX  = 50 * 1024 * 1024;
$ENV{PATH} = ($ENV{SP_PATH} ? "$ENV{SP_PATH}:" : '') . '/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin';    # SP_PATH: tests only
$ENV{HOME} = $DIR;    # LibreOffice needs a writable home

my @BASE   = qw(pdf jpg jpeg png gif bmp tif tiff);
my @OFFICE = qw(doc docx rtf odt xls xlsx csv ods ppt pptx odp);
my %MIME   = (html => 'text/html; charset=utf-8', css => 'text/css; charset=utf-8', js => 'application/javascript; charset=utf-8',
              pdf => 'application/pdf', png => 'image/png', jpg => 'image/jpeg', gif => 'image/gif', bmp => 'image/bmp', tif => 'image/tiff',
              woff2 => 'font/woff2');

sub slurp { my $f = shift; open(my $h, '<:raw', $f) or return ''; local $/; my $d = <$h>; close $h; defined $d ? $d : '' }
sub spit  { my ($f, $d) = @_; open(my $h, '>:raw', "$f.$$.tmp") or return; print $h $d; close $h; rename "$f.$$.tmp", $f }
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
sub office_state { $SOFFICE ? 'lo' : conv_peers() ? 'peer' : 'none' }    # peer: converted on another station
sub types { my $o = office_state(); my @t = @BASE; push @t, 'txt' if $CUPSFILTER || $o ne 'none'; push @t, @OFFICE if $o ne 'none'; @t }

# A "School Printer" queue (added with "Add to this device", on this computer or for another station) prints back into
# School Printer: choosing it as THE printer made every job come back here and be printed again, every few seconds.
sub own_queues { my (undef, $o) = cmd('lpstat', '-v'); my %q; while ($o =~ /^device for (\S+):\s*(\S+)/mg) { my ($n, $u) = ($1, $2); $q{$n} = 1 if $u =~ m{:8631/ipp/print} } %q }
sub printers { my %own = own_queues(); my (undef, $o) = cmd('lpstat', '-e'); grep { length && !$own{$_} } split /\n/, $o }
sub default_printer { my @p = printers(); my (undef, $o) = cmd('lpstat', '-d'); if ($o =~ /:\s*(\S.*?)\s*$/m) { my $d = $1; return $d if grep { $_ eq $d } @p } @p ? $p[0] : '' }
sub get_cfg {
    my %c = (pin => '', open => '1', printer => '', lang => 'fa', station => '', share => '1', accept => '1', conv => '1', domain => '', domainAt => '0', dns => '1');
    for (split /\n/, slurp($CFG)) { next if /^\s*#/; $c{$1} = $2 if /^\s*(\w+)\s*=\s*(.*?)\s*$/ }
    if (!length $c{printer}) { $c{printer} = default_printer() }
    else { my %own = own_queues(); $c{printer} = default_printer() if $own{$c{printer}} }
    return %c;
}
sub save_cfg { my %c = @_; spit($CFG, "# School Printer settings (also changeable on the admin page)\n" . join('', map { "$_=$c{$_}\n" } qw(printer pin open lang station share accept conv domain domainAt dns))) }
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
    my ($file, $s, $label, $jid) = @_;
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
    my ($code, $cups) = ('0', '');
    unless ($DRY) { my ($st, $out) = cmd('lp', @o, $file); if ($st) { $out =~ s/\s+/ /g; $code = "lp-$st: $out" } elsif ($out =~ /request id is (\S+)/) { $cups = $1 } }
    else { $code = '0 (dry run: lp ' . join(' ', @o) . ')' if $ENV{SP_SHOWLP} }
    logline("$label  copies=$s->{copies}  exit=$code");
    job_set($jid, $code !~ /^0( |$)/ ? (state => 'failed', err => $code) : $cups ? (state => 'printing', cups => $cups) : (state => 'done')) if $jid;
    if ($ENV{SP_TESTOUT}) { rename $file, "$ENV{SP_TESTOUT}/$label" } else { unlink $file }    # test hook, like watch.ps1
}


# ---------------------------------------------------------------- printing network (up to 50 School Printer computers)
# Every School Printer on the school network joins the PUBLIC network by itself (nothing to type). A station can instead
# create a PRIVATE network; others join it with a one-time token shown on a member's admin page (the token unlocks the
# network's random key, sent encrypted - see join_*). Computers in the same network find each other: a worker scans this
# computer's local network for port 8631 every minute (GET /sync/hello answers with a group id derived from the
# password) and asks every station of the same group for its status every few seconds. The print page sends each job
# to the least busy suitable printer, or to the station the person picked; Word/Excel/PowerPoint files are converted
# on the computer with the most free power. Every /sync/* request is signed with a key derived from the password;
# the password itself is never stored. Same protocol as sync.ps1/syncd.ps1 on Windows, so both mix in one network.
my $SYNC = "$DIR/Sync"; my $STD = "$SYNC/st"; my $JOBS = "$SYNC/jobs"; my $SCANS = "$SYNC/scans"; my $HELD = "$SYNC/held"; my $ALIAS = 'schoolprinter.local';
my $HAS_SHA = eval { require Digest::SHA; 1 } ? 1 : 0;
my $PROTO = 2; my $MAXNODES = 50; my $VERSION = '1.7.1'; my $FRESH = 25;

sub rnd_bytes { my $n = shift; my $b = ''; if (open(my $h, '<:raw', '/dev/urandom')) { read($h, $b, $n); close $h } $b .= chr(int rand 256) while length $b < $n; $b }
sub rnd_hex { unpack('H*', rnd_bytes(shift)) }
sub node_id { my $f = "$SYNC/node-id"; my $id = slurp($f); $id =~ s/\s+//g; return $id if $id =~ /^[0-9a-f]{32}$/; $id = rnd_hex(16); spit($f, $id); $id }
my $PUBLIC_KEY = $HAS_SHA ? Digest::SHA::sha256_hex('school-printer/public/1') : '';    # the same everywhere: the public network
sub group {    # -> {mode => public|private, key, gid}; undef = this station works alone
    return undef unless $HAS_SHA; return undef if -e "$SYNC/alone";
    my $g = jdec(slurp("$SYNC/group.json"));
    return { mode => 'private', key => $g->{key}, gid => $g->{gid}, since => $g->{since} || 0 } if ref $g eq 'HASH' && ($g->{key} || '') =~ /^[0-9a-f]{64}$/ && ($g->{mode} || '') eq 'private';
    { mode => 'public', key => $PUBLIC_KEY, gid => substr(Digest::SHA::hmac_sha256_hex('group', $PUBLIC_KEY), 0, 16) };
}
sub set_net {    # public | private (with key) | alone; forget the old network's stations
    my ($mode, $key) = @_; unlink "$SYNC/peers.json", "$SYNC/tokens.json", glob("$STD/*");
    if ($mode eq 'alone') { spit("$SYNC/alone", '') } else { unlink "$SYNC/alone" }
    if ($mode eq 'private') { spit("$SYNC/group.json", json({ mode => 'private', key => $key, gid => substr(Digest::SHA::hmac_sha256_hex('group', $key), 0, 16), since => N(time) })) }
    else { unlink "$SYNC/group.json" }
    spit("$SYNC/scan-now", '');
}
# ---- joining a private network with a one-time token (12 letters, e.g. K7QM-2XPD-9RTA; 15 minutes, works once)
# The joining station never sends the token: it asks every School Printer for the token's id (tid) and proves it knows
# the token (proof); the station that issued it answers with the network key encrypted and authenticated with keys made
# from the token, so neither an eavesdropper nor a station in the middle without the token learns the key.
my @TOK = split //, 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
sub tok_norm { my $t = uc(shift // ''); $t =~ s/[^A-Z0-9]//g; $t }
sub tok_id { substr(Digest::SHA::sha256_hex("school-printer/tid/" . shift), 0, 16) }
sub tok_stream {    # HMAC-SHA256 in counter mode: $n bytes of keystream
    my ($k, $n) = @_; my $o = ''; my $i = 0; $o .= Digest::SHA::hmac_sha256(pack('N', $i++), $k) while length $o < $n; substr($o, 0, $n) }
sub tok_keys { my ($t, $n1, $n2) = @_; (Digest::SHA::hmac_sha256("enc\n$n1\n$n2", $t), Digest::SHA::hmac_sha256("mac\n$n1\n$n2", $t)) }
sub token_new {    # a member of a private network shows this on its admin page
    my $g = group(); return undef unless $g && $g->{mode} eq 'private';
    my $t = join '', map { $TOK[ord($_) % @TOK] } split //, rnd_bytes(12);
    spit("$SYNC/tokens.json", json({ t => $t, until => N(time + 900), tries => N(0) })); $t;
}
sub token_get { my $x = jdec(slurp("$SYNC/tokens.json")); ref $x eq 'HASH' && ($x->{until} || 0) > time ? $x : undef }
sub join_answer {    # (issuer) -> (status, reply hash)
    my ($q, $peer) = @_; my $tk = token_get(); my $g = group();
    return (404, { error => 'NO_TOKEN' }) unless $tk && $g && $g->{mode} eq 'private' && ($q->{tid} || '') eq tok_id($tk->{t});
    my ($id, $n1) = map { $q->{$_} || '' } qw(id nonce);
    return (400, { error => 'BAD' }) unless $id =~ /^[0-9a-f]{32}$/ && $n1 =~ /^[0-9a-f]{32}$/;
    unless (same_text(Digest::SHA::hmac_sha256_hex("join\n$id\n$n1", $tk->{t}), $q->{proof} || '')) {
        $tk->{tries}++; if ($tk->{tries} >= 5) { unlink "$SYNC/tokens.json" } else { spit("$SYNC/tokens.json", json({ %$tk, tries => N($tk->{tries}), until => N($tk->{until}) })) }
        return (403, { error => 'TOKEN' });
    }
    unlink "$SYNC/tokens.json";    # works once
    my $n2 = rnd_hex(16); my ($ke, $km) = tok_keys($tk->{t}, $n1, $n2);
    my $plain = json({ key => $g->{key}, gid => $g->{gid} }); my $ct = unpack('H*', $plain ^ tok_stream($ke, length $plain));
    (200, { nonce => $n2, ct => $ct, mac => Digest::SHA::hmac_sha256_hex($ct, $km) });
}
sub join_network {    # (joiner) ask every School Printer on this network for the token's network -> 1 | error code
    my $t = tok_norm(shift); return 'TOKEN_FORMAT' unless length $t == 12;
    my $me = node_id(); my $n1 = rnd_hex(16);
    my $body = json({ tid => tok_id($t), id => $me, nonce => $n1, proof => Digest::SHA::hmac_sha256_hex("join\n$me\n$n1", $t) });
    my %seen; my @urls = grep { !$seen{$_}++ } map({ $_->{url} } @{ peers_list() }), map { "http://$_->[0]:$_->[1]" } scan_open(scan_targets());
    my $bad = 0;
    for my $u (@urls) {
        next if $u eq my_url();
        my ($c, $b) = http($u, 'POST', '/sync/join', { 'Content-Type' => 'application/json' }, $body, 4);
        $bad++ if $c == 403; next unless $c == 200;
        my $r = jdec($b); next unless ref $r eq 'HASH' && ($r->{nonce} || '') =~ /^[0-9a-f]{32}$/ && ($r->{ct} || '') =~ /^(?:[0-9a-f]{2})+$/;
        my ($ke, $km) = tok_keys($t, $n1, $r->{nonce});
        next unless same_text(Digest::SHA::hmac_sha256_hex($r->{ct}, $km), $r->{mac} || '');    # not from the token's network: ignore
        my $ct = pack('H*', $r->{ct}); my $k = jdec($ct ^ tok_stream($ke, length $ct));
        next unless ref $k eq 'HASH' && ($k->{key} || '') =~ /^[0-9a-f]{64}$/;
        set_net('private', $k->{key}); return 1;
    }
    $bad ? 'TOKEN_WRONG' : 'TOKEN_NOT_FOUND';
}
sub derive_group {    # (1.6.0 password networks; kept for reference, no longer used)
    my $pw = shift; my $h = Digest::SHA::hmac_sha256('school-printer/1', $pw);
    $h = Digest::SHA::hmac_sha256($h, $pw) for 1 .. 20000;       # slow on purpose: makes guessing the password costly
    my $key = unpack('H*', $h);
    return { key => $key, gid => substr(Digest::SHA::hmac_sha256_hex('group', $key), 0, 16) };
}
sub clean_text {    # printable text, at most $max characters (UTF-8 kept as bytes)
    my ($s, $max) = @_; $s = '' unless defined $s; $s =~ s/[\x00-\x1f\x7f<>"\\]//g; $s =~ s/^\s+|\s+$//g;
    my $u = $s; if (utf8::decode($u) && length $u > $max) { $u = substr($u, 0, $max); utf8::encode($u); return $u }
    length $s > $max * 4 ? substr($s, 0, $max) : $s;
}
sub station_of { my %c = @_; return $c{station} if length($c{station} // ''); (my $n = $HOSTNAME) =~ s/\.local$//; $n }
sub my_url { return $ENV{SP_ADDR} if $ENV{SP_ADDR}; my @ip = ipv4s(); @ip ? "http://$ip[0]:$PORT" : "http://$HOSTNAME:$PORT" }

# ---- tiny JSON decoder (objects, arrays, strings, numbers, true/false/null); strings stay UTF-8 bytes
sub jdec { my $t = shift; return undef unless defined $t && length $t; local $_ = $t; pos($_) = 0; my $v = eval { _jv() }; $v }    # (whitespace is skipped with \s+: Perl refuses two empty /g matches at one place)
sub _jv {
    /\G\s+/gc;
    if (/\G\{/gc) { my %h; /\G\s+/gc; return \%h if /\G\}/gc;
        while (1) { /\G\s+/gc; my $k = _js(); /\G\s*:/gc or die "json\n"; $h{$k} = _jv(); /\G\s+/gc; next if /\G,/gc; last if /\G\}/gc; die "json\n" }
        return \%h }
    if (/\G\[/gc) { my @a; /\G\s+/gc; return \@a if /\G\]/gc;
        while (1) { push @a, _jv(); /\G\s+/gc; next if /\G,/gc; last if /\G\]/gc; die "json\n" }
        return \@a }
    return _js() if substr($_, pos($_) // 0, 1) eq '"';
    return 1 if /\Gtrue/gc; return 0 if /\Gfalse/gc; return undef if /\Gnull/gc;
    return 0 + $1 if /\G(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)/gc;
    die "json\n";
}
sub _js {
    /\G"((?:[^"\\]|\\.)*)"/gc or die "json\n"; my $s = $1;
    $s =~ s{\\(u([0-9a-fA-F]{4})|.)}{ my ($e, $u) = ($1, $2); if (defined $u) { my $c = chr(hex $u); utf8::encode($c); $c } else { { n => "\n", r => "\r", t => "\t", b => "\b", f => "\f" }->{$e} // $e } }ge;
    $s;
}

# ---- signed requests between stations
sub sig { my ($key, $t, $m, $p, $id) = @_; Digest::SHA::hmac_sha256_hex("$t\n$m\n$p\n$id", $key) }
sub same_text { my ($x, $y) = @_; return 0 unless length $x == length $y; my $d = 0; $d |= ord(substr($x, $_, 1)) ^ ord(substr($y, $_, 1)) for 0 .. length($x) - 1; !$d }
sub sync_auth_v1 {    # (protocol 1) -> id of the station that signed this request, or '' (another network, old clock, not a station)
    my ($H, $m, $p) = @_; my $g = group() or return '';
    my ($id, $t, $s) = map { $H->{$_} || '' } qw(x-sync-node x-sync-time x-sync-sig);
    return '' unless $id =~ /^[0-9a-f]{32}$/ && $t =~ /^\d{9,11}$/ && $s =~ /^[0-9a-f]{64}$/ && abs(time - $t) <= 300;
    same_text(sig($g->{key}, $t, $m, $p, $id), $s) ? $id : '';
}
our $XFER = 0;    # seconds the last answer took to arrive, first byte to last (the speed test times only the network)
sub http {    # (base url, method, path, {headers}, body, timeout s) -> (status, body); status 0 = no answer
    my ($url, $m, $p, $hd, $body, $to) = @_; $body = '' unless defined $body; $to ||= 5;
    my ($host, $port) = $url =~ m{^http://([A-Za-z0-9.\-]+):(\d+)$} or return (0, 'bad address');
    my $s = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Timeout => $to) or return (0, 'unreachable');
    binmode $s; my $resp = '';
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" }; alarm($to + int(length($body) / 100_000));
        print $s "$m $p HTTP/1.0\r\nHost: $host:$port\r\nConnection: close\r\nContent-Length: " . length($body) . "\r\n" .
                 join('', map { "$_: $hd->{$_}\r\n" } sort keys %{ $hd || {} }) . "\r\n";
        print $s $body if length $body;
        my $first;
        while (1) { my $n = sysread($s, my $b, 65536); last unless $n; $first //= Time::HiRes::time(); $resp .= $b; die "big\n" if length $resp > $MAX + 65536 }
        $XFER = $first ? Time::HiRes::time() - $first : 0; alarm 0; 1 };
    alarm 0; close $s;
    return (0, 'timeout') unless $ok;
    my ($head, $rb) = split /\r\n\r\n/, $resp, 2;
    return (0, 'bad reply') unless defined $head && $head =~ m{^HTTP/\d\.\d (\d{3})};
    my $code = $1; $rb = '' unless defined $rb; my $hdrs = $head;
    if ($head =~ /^Transfer-Encoding:\s*chunked/mi) { my $o = ''; while ($rb =~ s/^([0-9a-fA-F]+)[^\r\n]*\r\n//) { my $n = hex $1; last unless $n; $o .= substr($rb, 0, $n); $rb = substr($rb, $n + 2) } $rb = $o }
    ($code, $rb, $hdrs);
}
sub peer_v1 {    # (protocol 1: signed only - replaced by the encrypted peer() below)
    my ($url, $m, $p, $hd, $body, $to) = @_; my $g = group() or return (0, 'no network');
    my $t = time; my $id = node_id();
    http($url, $m, $p, { %{ $hd || {} }, 'X-Sync-Node' => $id, 'X-Sync-Time' => $t, 'X-Sync-Sig' => sig($g->{key}, $t, $m, $p, $id) }, $body, $to);
}

# ---- this station's status (written by the worker every few seconds; what /sync/status answers)
sub perf {    # (cores, cpu %, free MB, total MB)
    my ($cores, $load, $free, $total) = (1, 0, 0, 0);
    if ($^O eq 'darwin') {
        my (undef, $n) = cmd('sysctl', '-n', 'hw.ncpu'); $cores = $1 if $n =~ /(\d+)/;
        my (undef, $l) = cmd('sysctl', '-n', 'vm.loadavg'); $load = $1 if $l =~ /([\d.]+)/;
        my (undef, $m) = cmd('sysctl', '-n', 'hw.memsize'); $total = int($1 / 1048576) if $m =~ /(\d+)/;
        my (undef, $v) = cmd('vm_stat'); my $pg = $v =~ /page size of (\d+)/ ? $1 : 4096; my $p = 0;
        $p += $1 while $v =~ /^Pages (?:free|inactive|speculative|purgeable):\s+(\d+)/mg; $free = int($p * $pg / 1048576);
    } else {
        my $ci = slurp('/proc/cpuinfo'); my $n = () = $ci =~ /^processor\s*:/mg; $cores = $n if $n;
        $load = $1 if slurp('/proc/loadavg') =~ /^([\d.]+)/;
        my $mi = slurp('/proc/meminfo'); $total = int($1 / 1024) if $mi =~ /^MemTotal:\s+(\d+)/m; $free = int($1 / 1024) if $mi =~ /^MemAvailable:\s+(\d+)/m;
    }
    my $cpu = int($load / ($cores || 1) * 100 + .5); $cpu = 100 if $cpu > 100;
    $cpu = $1 if $ENV{SP_FAKECPU} && slurp($ENV{SP_FAKECPU}) =~ /^(\d+)/;    # test copies only
    ($cores, $cpu, $free, $total);
}
sub cups_queue {    # (jobs, sheets) waiting on the printer; sheets of School Printer jobs are known, others count 1
    my $pr = shift; return (0, 0) unless length $pr;
    my (undef, $o) = cmd('lpstat', '-o', $pr); my %sheets = job_sheets_by_cups(); my ($n, $sh) = (0, 0);
    for (split /\n/, $o) { next unless /^(\S+)/; $n++; $sh += $sheets{$1} || 1 }
    ($n, $sh);
}
sub conv_busy { opendir(my $d, $UP) or return 0; my $n = grep { /^lo-/ } readdir $d; closedir $d; $n }
sub self_status {
    my %cf = get_cfg(); my $pr = $cf{printer}; my $cp = caps($pr); my $ps = pstatus($pr);
    my ($jobs, $sheets) = cups_queue($pr); my ($cores, $cpu, $free, $total) = perf(); my $open = $cf{open} ne '0';
    return { app => 'school-printer', proto => N($PROTO), id => node_id(), name => $HOSTNAME, station => station_of(%cf), version => $VERSION,
        open => B($open), ready => B($open && $ps eq 'Normal'), accept => B($cf{accept} ne '0'), printer => $pr, pstatus => $ps,
        jobs => N($jobs), queue => N($sheets), color => $cp->{color}, duplex => $cp->{duplex}, papers => $cp->{papers},
        conv => { ok => B($SOFFICE ? 1 : 0), kind => ($SOFFICE ? 'lo' : 'none'), busy => N(conv_busy()), share => B($cf{conv} ne '0') },
        cores => N($cores), cpu => N($cpu), memFree => N($free), memTotal => N($total), url => my_url(), at => N(time),
        bw => N(bw_now()), up => N(uptime_blocks()), domain => $cf{domain}, domainAt => N($cf{domainAt} || 0), hasPrinter => B(length $pr && $ps ne 'Not found'), scanners => scanner_list(), lead => leader()->{id} };
}
sub self_cached { my $s = jdec(slurp("$SYNC/self.json")); (ref $s eq 'HASH' && time - ($s->{at} || 0) < 30) ? $s : jdec(json(self_status())) }

# ---- the other stations: found by the scan (peers.json), status from the last poll (st/<id>.json)
sub peers_list { my $p = jdec(slurp("$SYNC/peers.json")); ref $p eq 'ARRAY' ? [grep { ref $_ eq 'HASH' && ($_->{id} || '') =~ /^[0-9a-f]{32}$/ } @$p] : [] }
sub stations {    # [{id, url, station, s (status), online, age, err}]
    my @out;
    for my $x (@{ peers_list() }) {
        my $st = jdec(slurp("$STD/$x->{id}.json")); $st = {} unless ref $st eq 'HASH';
        my $e = jdec(slurp("$STD/$x->{id}.err")); $e = {} unless ref $e eq 'HASH';
        my $at = $st->{at} || 0; my $age = $at ? time - $at : 1e9;
        my $s = ref $st->{s} eq 'HASH' ? $st->{s} : {};
        push @out, { id => $x->{id}, url => $x->{url}, pk => $x->{pk} || '', station => $s->{station} || $x->{station} || '', s => $s,
                     online => ($age <= $FRESH && ($e->{at} || 0) <= $at) ? 1 : 0, age => $age, err => (($e->{at} || 0) > $at ? $e->{err} || '' : '') };
    }
    @out;
}
sub subnets {    # [ip, prefix] for each LAN address of this computer
    my @r;
    if ($^O eq 'darwin') {
        my (undef, $o) = cmd('ifconfig');
        while ($o =~ /inet (\d+\.\d+\.\d+\.\d+) netmask 0x([0-9a-fA-F]{8})/g) { my ($ip, $nm) = ($1, $2); next if $ip =~ /^(127|169\.254)\./; push @r, [$ip, unpack('%32b*', pack('H8', $nm))] }
    } else {
        my (undef, $o) = cmd('ip', '-4', '-o', 'addr', 'show', 'scope', 'global');
        while ($o =~ /^\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)\/(\d+)/mg) { push @r, [$2, $3] unless $1 =~ /^(docker|br-|veth|virbr|tun|wg|tailscale|zt|lxc|cni|flannel)/ }
    }
    @r;
}
sub scan_targets {    # every address of this computer's networks (each at most a /22 = 1022 addresses), port 8631
    return map { [split /:/] } split /,/, $ENV{SP_SCAN} if $ENV{SP_SCAN};    # tests: "127.0.0.1:8701,127.0.0.1:8702"
    my (%seen, @t);
    for my $sn (subnets()) {
        my ($ip, $pre) = @$sn; $pre = 22 if $pre < 22; next if $pre > 30;
        my $n = unpack('N', pack('C4', split /\./, $ip)); my $net = $n & ((0xFFFFFFFF << (32 - $pre)) & 0xFFFFFFFF);
        for my $k (1 .. 2 ** (32 - $pre) - 2) { my $ad = join('.', unpack('C4', pack('N', $net + $k))); next if $ad eq $ip || $seen{$ad}++; push @t, [$ad, $PORT] }
    }
    @t;
}
sub scan_open {    # connect to many addresses at once (200 at a time) -> the ones that accept
    my @t = @_; my @open;
    while (my @batch = splice(@t, 0, 200)) {
        my %s; my $sel = IO::Select->new;
        for my $x (@batch) { my $k = IO::Socket::INET->new(PeerAddr => $x->[0], PeerPort => $x->[1], Proto => 'tcp', Blocking => 0) or next; $s{fileno $k} = [$k, $x]; $sel->add($k) }
        my $end = Time::HiRes::time() + 1.5;
        while ($sel->count && (my $left = $end - Time::HiRes::time()) > 0) {
            for my $w ($sel->can_write($left)) { $sel->remove($w); push @open, $s{fileno $w}[1] if $w->connected; close $w }
        }
        close $_->[0] for values %s;
    }
    @open;
}
sub scan {    # (in its own process) -> peers.json: stations of this network; others.json: School Printers in another one
    my $g = group() or return; my $me = node_id(); my %old = map { $_->{id} => $_ } @{ peers_list() };
    my (%found, %gone, $others);
    for my $x (scan_open(scan_targets())) {
        my ($c, $b) = http("http://$x->[0]:$x->[1]", 'GET', '/sync/hello', {}, '', 2); next unless $c == 200;
        my $h = jdec($b); next unless ref $h eq 'HASH' && ($h->{app} || '') eq 'school-printer' && ($h->{id} || '') =~ /^[0-9a-f]{32}$/ && $h->{id} ne $me;
        if (($h->{gid} || '') eq $g->{gid}) { next unless pin_ok($g, $h->{id}, $h->{pk}, $h->{pkmac});    # not who it claims to be: ignore
            $found{$h->{id}} = { id => $h->{id}, url => "http://$x->[0]:$x->[1]", pk => $h->{pk}, station => clean_text($h->{station}, 40), seen => time } }
        else { $others++; $gone{$h->{id}} = 1 }    # answered from another network: not ours any more
    }
    for my $id (keys %old) { $found{$id} ||= $old{$id} if !$gone{$id} && time - ($old{$id}{seen} || 0) < 600 }    # missed one scan: keep 10 minutes
    my @p = sort { ($b->{seen} || 0) <=> ($a->{seen} || 0) } values %found; @p = @p[0 .. $MAXNODES - 2] if @p > $MAXNODES - 1;
    $_->{seen} = N($_->{seen}) for @p;
    spit("$SYNC/peers.json", json(\@p)); spit("$SYNC/others.json", json({ n => N($others || 0), at => N(time) }));
    for my $x (grep { !$old{$_->{id}} } @p) { peer($x, 'POST', '/sync/announce', {}, '', 2) }    # new here: they look again at once
}
sub poll_peers {    # ask every station for its status at once; each answer -> st/<id>.json
    my @p = @{ peers_list() }; my %kids;
    for my $x (@p) {
        my $pid = fork; next unless defined $pid;
        if (!$pid) {
            my ($c, $b) = peer($x, 'GET', '/sync/status', {}, '', 3); my $s = $c == 200 ? jdec($b) : undef;
            if (ref $s eq 'HASH' && ($s->{id} || '') eq $x->{id}) { spit("$STD/$x->{id}.json", '{"at":' . time . ',"s":' . $b . '}') }
            else { spit("$STD/$x->{id}.err", json({ at => N(time), err => $c == 401 ? 'PASSWORD' : $c == 0 ? 'UNREACHABLE' : "HTTP $c" })) }
            exit 0;
        }
        $kids{$pid} = 1;
    }
    my $end = Time::HiRes::time() + 5;
    while (%kids && Time::HiRes::time() < $end) { for (keys %kids) { delete $kids{$_} if waitpid($_, WNOHANG) } Time::HiRes::sleep(0.05) if %kids }
    for (keys %kids) { kill 'KILL', $_; waitpid($_, 0) }
}

# ---- jobs: Sync/jobs/<jid>.json lets the print page follow its job ("waiting at X", "printing at X")
sub job_get { my $id = shift; return undef unless $id =~ /^[0-9a-f]{16}$/; my $j = jdec(slurp("$JOBS/$id.json")); ref $j eq 'HASH' ? $j : undef }
sub job_set {
    my ($id, %kv) = @_; return unless defined $id && $id =~ /^[0-9a-f]{16}$/;
    open(my $l, '>>', "$JOBS/.lock") or return; flock($l, LOCK_EX);
    my $j = job_get($id) || { jid => $id, at => time }; $j->{$_} = $kv{$_} for keys %kv;    # plain numbers: N() below, once
    $j->{$_} = N($j->{$_} || 0) for grep { defined $j->{$_} } qw(at ahead sheets lost errSince); $j->{moved} = B($j->{moved}) if defined $j->{moved};
    spit("$JOBS/$id.json", json($j)); close $l;
}
sub job_sheets_by_cups { my %h; opendir(my $d, $JOBS) or return %h; for (readdir $d) { next unless /^([0-9a-f]{16})\.json$/; my $j = job_get($1) or next; $h{$j->{cups}} = $j->{sheets} || 1 if $j->{cups} } closedir $d; %h }
sub job_refresh {    # follow jobs on other stations; printing -> done when CUPS has finished; move jobs off failing stations and printers
    opendir(my $d, $JOBS) or return; my @all = map { job_get(substr($_, 0, 16)) || () } grep { /^[0-9a-f]{16}\.json$/ } readdir $d; closedir $d;
    my $me = node_id(); my ($q, $pst); my %st = map { $_->{id} => $_ } stations();
    for my $j (@all) {
        my $jid = $j->{jid}; my $held = -e "$HELD/$jid.json";
        if ($j->{state} =~ /^(done|failed)$/) { unhold($jid) if $j->{state} eq 'done'; next }
        next if time - ($j->{at} || 0) > 1800;
        if ($j->{rjid}) {    # on another station
            my $x = $st{ $j->{sid} };
            if (!$x || !$x->{online}) {    # that station went quiet: give it 20 seconds, then print elsewhere
                if (!$j->{lost}) { job_set($jid, lost => time) } elsif (time - $j->{lost} >= 20 && $held) { reroute($j, 'STATION_LOST') }
                next;
            }
            job_set($jid, lost => 0) if $j->{lost};
            my ($c, $b) = peer($x, 'GET', "/sync/job/$j->{rjid}", {}, '', 4); next unless $c == 200;
            my $r = jdec($b); next unless ref $r eq 'HASH' && ($r->{state} || '') =~ /^(queued|printing|done|failed)$/;
            if ($r->{state} eq 'failed' && $held) { reroute($j, ($r->{err} || '') eq 'PRINTER_ERROR' ? 'PRINTER_ERROR' : 'FAILED'); next }
            job_set($jid, state => $r->{state}, ahead => $r->{ahead} || 0, err => $r->{err} || '') if $r->{state} ne $j->{state} || ($r->{ahead} || 0) != ($j->{ahead} || 0);
            unhold($jid) if $r->{state} eq 'done';
            next;
        }
        next unless ($j->{sid} || '') eq $me && $j->{state} eq 'printing' && $j->{cups};
        unless ($q) { my (undef, $o) = cmd('lpstat', '-o'); $q = [map { /^(\S+)/ ? $1 : () } split /\n/, $o] }
        my ($pos) = grep { $q->[$_] eq $j->{cups} } 0 .. $#$q;
        if (!defined $pos) { job_set($jid, state => 'done', ahead => 0); unhold($jid); next }
        (my $pq = $j->{cups}) =~ s/-\d+$//;
        unless (defined $pst) { my (undef, $o) = cmd('lpstat', '-l', '-p', $pq); $pst = $o }
        if ($pst =~ /disabled|not responding|offline|out of paper|media.?empty|jam|unable to|waiting for printer|stopped/i) {    # stuck: 45 s, then cancel here and print elsewhere
            if (!$j->{errSince}) { job_set($jid, errSince => time) }
            elsif (time - $j->{errSince} >= 45) { cmd('cancel', $j->{cups}) unless $DRY; $held ? reroute($j, 'PRINTER_ERROR') : job_set($jid, state => 'failed', err => 'PRINTER_ERROR') }
            next;
        }
        job_set($jid, errSince => 0) if $j->{errSince};
        my $ahead = grep { $_ < $pos && $q->[$_] =~ /^\Q$pq\E-\d+$/ } 0 .. $#$q; job_set($jid, ahead => $ahead) if $ahead != ($j->{ahead} || 0);
    }
    opendir(my $sd, $SCANS) or return;    # scans whose process died
    for (readdir $sd) { next unless /^([0-9a-f]{16})\.json$/; my $k = scan_get($1) or next; scan_set($1, state => 'failed', err => 'SCAN_FAILED') if $k->{state} =~ /^(waiting|scanning)$/ && $k->{pid} && !kill(0, $k->{pid}) }
    closedir $sd;
}
sub pending_sheets { my %h; opendir(my $d, $JOBS) or return %h; for (readdir $d) { next unless /^([0-9a-f]{16})\.json$/; my $j = job_get($1) or next; $h{$j->{sid}} += $j->{sheets} || 1 if $j->{state} eq 'sending' } closedir $d; %h }
sub cleanup_sync {
    for my $f (glob("$SCANS/*")) { unlink $f if -f $f && time - (stat $f)[9] > 1800 }    # scans: 30 minutes
    for my $f (glob("$SYNC/nonces/*")) { unlink $f if time - (stat $f)[9] > 600 }    # a request older than 5 minutes is refused anyway
    for my $dir ($JOBS, $STD) { opendir(my $d, $dir) or next; for (readdir $d) { my $f = "$dir/$_"; unlink $f if -f $f && !/^\./ && time - (stat $f)[9] > 86400 } closedir $d }
    my %ids = map { $_->{id} => 1 } @{ peers_list() }; opendir(my $d, $STD) or return;
    for (readdir $d) { unlink "$STD/$_" if /^([0-9a-f]{32})\.(json|err)$/ && !$ids{$1} } closedir $d;
}

# ---- choosing where a job prints / where a file is converted
sub paper_fits { my ($s, $w, $h) = @_; return 1 unless $w && ref $s->{papers} eq 'ARRAY' && @{ $s->{papers} };
                 my ($a1, $b1) = sort { $a <=> $b } ($w, $h); scalar grep { abs($_->{w} - $a1) < 2 && abs($_->{h} - $b1) < 2 } @{ $s->{papers} } }
sub pick_station {    # ($want = 'auto' | station id, {color, duplex, pw, ph}) -> (station to send to | undef = print here, error)
    my ($want, $j) = @_; my $me = node_id();
    return (undef, '') if !$want || $want eq $me || !group();
    my %cf = get_cfg();
    my @on = grep { $_->{online} && $_->{s}{ready} && $_->{s}{accept} } stations();
    if ($want ne 'auto') { my ($x) = grep { $_->{id} eq $want } @on; return $x ? ($x, '') : (undef, 'STATION_OFFLINE') }
    return (undef, '') if $cf{share} eq '0';
    my $self = self_cached(); my %pend = pending_sheets();
    my @c; push @c, { here => 1, s => $self, load => ($self->{queue} || 0) + ($pend{$me} || 0) } if $self->{ready};
    push @c, map { { x => $_, s => $_->{s}, load => ($_->{s}{queue} || 0) + ($pend{$_->{id}} || 0) } } @on;
    return (undef, '') unless @c;
    my @fit = grep { (!$j->{color} || $_->{s}{color}) && (!$j->{duplex} || $_->{s}{duplex}) && paper_fits($_->{s}, $j->{pw}, $j->{ph}) } @c;
    @fit = @c unless @fit;
    my $best = $fit[0]; for (@fit) { $best = $_ if $_->{load} < $best->{load} }    # ties: this station (first)
    $best->{here} ? (undef, '') : ($best->{x}, '');
}
sub net_info {    # the admin page's "Printing network" card
    my %cf = @_; my $g = group(); my $me = self_cached(); my $o = jdec(slurp("$SYNC/others.json")) || {};
    my $row = sub { my ($x, $s, $here) = @_; { id => $x->{id}, station => $x->{station}, url => $x->{url} || '', here => B($here), online => B($x->{online}),
        age => N($x->{age} < 1e8 ? $x->{age} : -1), err => $x->{err} || '', printer => $s->{printer} || '', pstatus => $s->{pstatus} || '', ready => B($s->{ready}),
        accept => B($s->{accept}), queue => N($s->{queue} || 0), jobs => N($s->{jobs} || 0), cpu => N($s->{cpu} || 0), cores => N($s->{cores} || 0),
        memFree => N($s->{memFree} || 0), memTotal => N($s->{memTotal} || 0), conv => ($s->{conv} || {})->{kind} || 'none',
        convBusy => N(($s->{conv} || {})->{busy} || 0), color => B($s->{color}), duplex => B($s->{duplex}) } };
    my @rows = ($row->({ id => node_id(), station => station_of(%cf), url => my_url(), online => 1, age => 0 }, $me, 1));
    push @rows, map { $row->($_, $_->{s}, 0) } sort { $b->{online} <=> $a->{online} || lc $a->{station} cmp lc $b->{station} } stations() if $g;
    my $ls = (stat "$SYNC/others.json")[9];
    my $tk = token_get(); my $al = jdec(slurp("$SYNC/alerts.json")); $al = {} unless ref $al eq 'HASH';
    my %names = map { $_->{id} => $_->{station} } @{ peers_list() };
    my @alerts = map { { id => $_, station => $names{$_} || substr($_, 0, 8), at => N($al->{$_}{at} || 0) } } grep { time - ($al->{$_}{at} || 0) < 86400 } sort keys %$al;
    return { ok => B($HAS_SHA), joined => B($g), alerts => \@alerts, crypto => B(which("openssl") ? 1 : 0), mode => $g ? $g->{mode} : 'alone', token => $tk ? $tk->{t} : '', tokenLeft => N($tk ? $tk->{until} - time : 0), gid => $g ? $g->{gid} : '', station => station_of(%cf), share => B($cf{share} ne '0'),
             accept => B($cf{accept} ne '0'), conv => B($cf{conv} ne '0'), others => N($g ? $o->{n} || 0 : 0), lastScan => N($ls && $g ? time - $ls : -1),
             max => N($MAXNODES), stations => \@rows, main => leader()->{id}, alias => "http://$ALIAS:$PORT", domain => $cf{domain}, dns => B($cf{dns} ne '0'),
             dnsState => do { my $x = jdec(slurp("$SYNC/dns.json")); ref $x eq 'HASH' && time - ($x->{at} || 0) < 30 ? $x->{state} : 'off' } };
}
sub net_caps {    # this printer's paper sizes; colour / two-sided when any connected printer has them (the job goes there)
    my $cp = caps(shift); return $cp unless group();
    my @on = grep { $_->{online} && $_->{s}{ready} } stations();
    return { %$cp, color => B(${ $cp->{color} } || grep { $_->{s}{color} } @on), duplex => B(${ $cp->{duplex} } || grep { $_->{s}{duplex} } @on) };
}
sub cscore { my $s = shift; my $c = $s->{conv} || {}; my $v = ($s->{cores} || 1) * (100 - ($s->{cpu} || 0)) / 100 - 1.5 * ($c->{busy} || 0);
             $v -= 2 if ($s->{memFree} || 0) > 0 && $s->{memFree} < 800; $v }
sub conv_peers { my %cf = get_cfg(); return () if $cf{conv} eq '0' || !group(); grep { $_->{online} && $_->{s}{conv} && $_->{s}{conv}{ok} && $_->{s}{conv}{share} } stations() }
sub pick_converter {    # -> station to convert on, or undef = here
    my @p = conv_peers() or return undef;
    my $best = $p[0]; for (@p) { $best = $_ if cscore($_->{s}) > cscore($best->{s}) }
    return $best unless $SOFFICE;
    my $mine = cscore(self_cached()); my $margin = abs($mine) * 0.3; $margin = 0.75 if $margin < 0.75;
    cscore($best->{s}) > $mine + $margin ? $best : undef;
}
sub remote_convert {    # Office file -> another station converts it -> <id>.pdf here (or convert here if that fails)
    my ($x, $id, $ext) = @_; alarm 0;
    my ($c, $b) = peer($x, 'POST', '/sync/convert', { ext => $ext }, slurp("$UP/$id.$ext"), 60);
    my $r = $c == 200 ? jdec($b) : undef;
    if (ref $r eq 'HASH' && ($r->{rid} || '') =~ /^[0-9a-f]{32}$/) {
        my $end = time + 150;
        while (time < $end) {
            Time::HiRes::sleep(0.8);
            my ($c2, $b2) = peer($x, 'GET', "/sync/converted/$r->{rid}", {}, '', 30);
            if ($c2 == 200 && substr($b2, 0, 4) eq '%PDF') { spit("$UP/$id.pdf", $b2); return }
            last if $c2 == 410 || $c2 == 404 || $c2 == 401;
        }
    }
    convert($id, $ext);
}
sub norm_settings {    # job settings from the print page or another station -> clean settings for this printer
    my ($g, $cp) = @_;    # $g: code ref name -> raw value
    my %s = map { $_ => $g->($_) } qw(copies pages paper orientation color duplex margins scale nup land pw ph name);
    $s{$_} = '' for grep { !defined $s{$_} } keys %s;
    my %ok = (orientation => qr/^(auto|portrait|landscape)$/, color => qr/^(color|gray)$/, duplex => qr/^(off|long|short)$/,
              margins => qr/^(none|narrow|normal|wide)$/, scale => qr/^(fit|actual)$/, nup => qr/^[124]$/, pages => qr/^[0-9,\-\s]{0,200}$/);
    for (keys %ok) { return undef unless $s{$_} =~ $ok{$_} }
    $s{copies} = ($s{copies} =~ /^\d+$/ && $s{copies} >= 1) ? ($s{copies} > 20 ? 20 : $s{copies}) : 1;
    $s{land} = $s{orientation} eq 'landscape' ? 1 : $s{orientation} eq 'portrait' ? 0 : ($s{land} ? 1 : 0);
    my ($p) = grep { $_->{n} eq $s{paper} } @{ $cp->{papers} };
    if (!$p && $s{pw} =~ /^[\d.]+$/ && $s{ph} =~ /^[\d.]+$/) { my ($a1, $b1) = sort { $a <=> $b } ($s{pw}, $s{ph}); ($p) = grep { abs(${ $_->{w} } - $a1) < 2 && abs(${ $_->{h} } - $b1) < 2 } @{ $cp->{papers} } }
    $s{paper} = $p ? $p->{n} : $cp->{def};
    $s{color} = 'gray' unless ${ $cp->{color} }; $s{duplex} = 'off' unless ${ $cp->{duplex} };
    $s{name} = clean_text($s{name}, 120);
    \%s;
}
sub hold {    # keep a copy of a job (document + settings) until it has printed, to move it if a station or printer fails
    my ($jid, $file, $s, $label) = @_; my ($ext) = $file =~ /\.(\w+)$/; return unless $ext;
    spit("$HELD/$jid.$ext", slurp($file)); spit("$HELD/$jid.json", json({ %$s, ext => $ext, label => $label }));
}
sub unhold { unlink glob("$HELD/$_[0].*") }
sub forward_job {    # (in a worker process) hand a job to another station; the network worker follows it there
    my ($x, $file, $s, $label, $jid, $picked) = @_; alarm 0;
    (my $ext = $file) =~ s/.*\.//;
    my %m = map { $_ => $s->{$_} } grep { defined $s->{$_} } qw(copies pages paper orientation color duplex margins scale nup land pw ph name sheets from);
    $m{ext} = $ext;
    my $data = slurp($file); my $until = time + ($picked ? 120 : 6); my ($c, $b);    # a picked printer: keep trying for 2 minutes
    while (1) { ($c, $b) = peer($x, 'POST', '/sync/job', \%m, $data, 60); last if $c == 200 || ($c >= 400 && $c != 503) || time >= $until; sleep 3 }
    my $r = $c == 200 ? jdec($b) : undef;
    if (ref $r eq 'HASH' && ($r->{jid} || '') =~ /^[0-9a-f]{16}$/) {
        unlink $file; job_set($jid, state => 'queued', ahead => $r->{ahead} || 0, rjid => $r->{jid}, url => $x->{url});
        logline("$label  copies=$s->{copies}  exit=sent:" . ($x->{station} || $x->{id}));
        return;
    }
    unlink $file; my $j = job_get($jid); reroute($j, 'NOT_TAKEN') if $j;    # that station did not take it: the next best printer
}
sub reroute {    # print a job again from its held copy: on the best other printer, else here; else it failed
    my ($j, $why) = @_; my $jid = $j->{jid};
    my $h = jdec(slurp("$HELD/$jid.json")); my $doc = ref $h eq 'HASH' ? "$HELD/$jid.$h->{ext}" : '';
    return job_set($jid, state => 'failed', err => $why) unless $doc && -e $doc;
    my %tried = map { $_ => 1 } grep { length } (split(/,/, $j->{tried} || ''), $j->{sid} || '');
    my $me = node_id(); my $self = self_cached(); my %pend = pending_sheets(); my @c;
    push @c, { here => 1, s => $self, load => ($self->{queue} || 0) + ($pend{$me} || 0) } if $self->{ready} && !$tried{$me};
    push @c, map { { x => $_, s => $_->{s}, load => ($_->{s}{queue} || 0) + ($pend{$_->{id}} || 0) } } grep { $_->{online} && $_->{s}{ready} && $_->{s}{accept} && !$tried{$_->{id}} } stations() if group();
    my @fit = grep { ($h->{color} ne 'color' || $_->{s}{color}) && ($h->{duplex} eq 'off' || $_->{s}{duplex}) && paper_fits($_->{s}, $h->{pw}, $h->{ph}) } @c; @fit = @c unless @fit;
    my $tr = join(',', sort keys %tried);
    unless (@fit) { unhold($jid); return job_set($jid, state => 'failed', err => $why, tried => $tr) }
    my $best = $fit[0]; for (@fit) { $best = $_ if $_->{load} < $best->{load} }
    my %cf = get_cfg(); my $copy = "$UP/job-r$jid-$h->{label}"; spit($copy, slurp($doc));
    job_set($jid, state => $best->{here} ? 'queued' : 'sending', station => $best->{here} ? station_of(%cf) : $best->{x}{station}, sid => $best->{here} ? $me : $best->{x}{id},
            moved => 1, why => $why, tried => $tr, rjid => '', url => '', at => time, lost => 0, errSince => 0);
    my $pid = fork; return if !defined $pid || $pid;
    $SIG{CHLD} = 'DEFAULT';
    if ($best->{here}) { my $cp = caps($cf{printer}); $h->{color} = 'gray' unless ${ $cp->{color} }; $h->{duplex} = 'off' unless ${ $cp->{duplex} }; do_print($copy, $h, $h->{label}, $jid) }
    else { forward_job($best->{x}, $copy, $h, $h->{label}, $jid, 0) }
    exit 0;
}

# ---- the worker: status, scan, polls (a separate process, restarted by the server if it stops)
sub worker {
    $0 = 'schoolprinter-network'; $SIG{CHLD} = 'DEFAULT'; $SIG{ALRM} = 'DEFAULT'; my ($last_scan, $scan_pid, $last_det, $last_bw, $started) = (0, 0, 0, 0, time);
    $SIG{TERM} = sub { alias_off(); exit 0 };
    while (1) {
        my $t0 = Time::HiRes::time();
        eval { uptime_tick() };
        if (time - $last_det >= 60) { $last_det = time; eval { detect_scanners() } }
        eval { spit("$SYNC/self.json", json(self_status())) };
        if (group() && time - $last_bw >= 300) { $last_bw = (eval { measure_bw() } ? time : time - 280) }    # failed: again in 20 s
        if (group()) {
            if ($scan_pid && waitpid($scan_pid, WNOHANG)) { $scan_pid = 0 }
            my $every = time - $started < 180 ? 15 : 60;    # the first 3 minutes: look often, stations start at different times
            if (!$scan_pid && (time - $last_scan >= $every || -e "$SYNC/scan-now")) {
                unlink "$SYNC/scan-now"; $last_scan = time;
                my $pid = fork; if (defined $pid && !$pid) { eval { scan() }; exit 0 } $scan_pid = $pid || 0;
            }
            eval { poll_peers() }; eval { adopt_domain() };
        }
        # right after the poll: a main station that just went quiet is replaced within one round (2-3 seconds)
        my $online = eval { track_online() } || 0;
        my ($lid) = eval { elect() }; $lid ||= node_id();
        if ($lid eq node_id() && group()) { alias_on() } else { alias_off() }
        eval { main_notice($lid, $online) };
        eval { job_refresh() }; eval { cleanup_sync() } if int($t0) % 60 < 3;
        my $n = @{ peers_list() }; my $iv = $n > 24 ? 6 : $n > 10 ? 4 : 2.5;
        my $left = $iv - (Time::HiRes::time() - $t0); Time::HiRes::sleep($left) if $left > 0;
    }
}

# ---------------------------------------------------------------- one address for everyone: the main station
# Every station measures how fast it can fetch 1 MB from another station (bw, Mbit/s) and reports its free power.
# All stations compute the same choice from the same statuses: the main station serves the address everyone uses,
# http://schoolprinter.local:8631 (mDNS), and every other station's print page forwards there. A main station keeps
# the job until another one is clearly better (25 %), so the address does not flip back and forth.
our (%SINCE, $JOINED_AT, $SINCE_GID); $JOINED_AT = time; $SINCE_GID = '';
sub lead_score { my $s = shift; my $bw = $s->{bw} || 0; log(1 + $bw) / log(2) * 2 + ($s->{cores} || 1) * (100 - ($s->{cpu} || 0)) / 100 + (($s->{memFree} || 0) > 8192 ? 8192 : ($s->{memFree} || 0)) / 2048 }
sub elect {    # -> (id, url) of the main station
    my $me = self_cached(); my @c = ({ id => node_id(), url => my_url(), s => $me });
    push @c, map { { id => $_->{id}, url => $_->{url}, s => $_->{s} } } grep { $_->{online} } stations() if group();
    $_->{score} = lead_score($_->{s}) for @c;
    # equal (to half a point) -> most running time (5-minute blocks) -> a random pick every station makes the same way
    my $gid = (group() || {})->{gid} || '';
    $_->{rank} = int($_->{score} * 2 + .5), $_->{up} = $_->{s}{up} || 0, $_->{lot} = Digest::SHA::sha1_hex("$gid/$_->{id}") for @c;
    my ($best) = sort { $b->{rank} <=> $a->{rank} || $b->{up} <=> $a->{up} || $a->{lot} cmp $b->{lot} } @c;
    # keep the main station most stations already follow, while it is online and not clearly worse than the best;
    # everyone sees the same statuses, so a fresh network settles on the same best station within one round
    my %votes; $votes{ $_->{s}{lead} || '' }++ for @c; my %by = map { $_->{id} => $_ } @c;
    my ($keep) = sort { $votes{$b->{id}} <=> $votes{$a->{id}} || $b->{rank} <=> $a->{rank} || $b->{up} <=> $a->{up} || $a->{lot} cmp $b->{lot} } grep { $votes{$_->{id}} && $votes{$_->{id}} >= 2 } values %by;
    # a station joined (or this one did) in the last 90 seconds: a fresh election, the best station wins outright;
    # otherwise keep the main station most stations follow while it is not clearly worse (no flapping)
    my $fresh = time - $JOINED_AT < 90 || grep { defined $SINCE{$_->{id}} && time - $SINCE{$_->{id}} < 90 } @c;
    my $l = (!$fresh && $keep && $keep->{score} >= $best->{score} * 0.75) ? $keep : $best;
    # every 5 minutes (the same 20 seconds on every station's clock) a review with live load: a main station that has
    # become busy (another program started) hands over to a station at least half a point better
    $l = $best if time % 300 < 20 && $best->{rank} > $l->{rank};
    my $cur = jdec(slurp("$SYNC/leader.json"));
    spit("$SYNC/leader.json", json({ id => $l->{id}, url => $l->{url} })) unless ref $cur eq 'HASH' && ($cur->{id} || '') eq $l->{id} && ($cur->{url} || '') eq $l->{url};
    ($l->{id}, $l->{url});
}
# who is online since when (seen from here): a station that (re)joins starts a fresh election
sub track_online {
    my $g = group(); my $gid = $g ? $g->{gid} : '';
    if ($gid ne $SINCE_GID) { %SINCE = (); $JOINED_AT = time; $SINCE_GID = $gid }    # another network: everyone is new
    my %on = $g ? map { $_->{id} => 1 } grep { $_->{online} } stations() : ();
    delete $SINCE{$_} for grep { !$on{$_} } keys %SINCE; $SINCE{$_} //= time for keys %on;
    scalar keys %on;
}
# "this computer is now the main station": a pop-up for whoever sits at it (macOS dialog, Linux desktop notification)
our ($OTHER_LEAD, $MAIN_SINCE) = (1, 0);
sub main_notice {
    my ($lid, $online) = @_; return unless group() && $online >= 1;    # alone: every computer is its own main station
    if ($lid ne node_id()) { $OTHER_LEAD = 1; $MAIN_SINCE = 0; return }
    $MAIN_SINCE ||= time; return if time - $MAIN_SINCE < 20;    # settled for 20 seconds first (no pop-up while stations start up)
    return unless $OTHER_LEAD; $OTHER_LEAD = 0;    # still the same turn as main station (a station flickered): no second pop-up
    return if $ENV{SP_NOPOPUP};
    my %cf = get_cfg(); my $fa = ($cf{lang} || '') eq 'fa';
    my ($title, $text) = $fa ? ("\x{0627}\x{06CC}\x{0646} \x{0631}\x{0627}\x{06CC}\x{0627}\x{0646}\x{0647} \x{0627}\x{06A9}\x{0646}\x{0648}\x{0646} \x{0627}\x{06CC}\x{0633}\x{062A}\x{06AF}\x{0627}\x{0647} \x{0627}\x{0635}\x{0644}\x{06CC} \x{0627}\x{0633}\x{062A}", '') : ('This computer is now the main station', '');
    $text = $fa ? "\x{0635}\x{0641}\x{062D}\x{0647}\x{0654} \x{0686}\x{0627}\x{067E} \x{0648} \x{0627}\x{0633}\x{06A9}\x{0646} \x{0647}\x{0645}\x{0647} \x{0627}\x{0632} \x{0627}\x{06CC}\x{0646} \x{0631}\x{0627}\x{06CC}\x{0627}\x{0646}\x{0647} \x{0628}\x{0627}\x{0632} \x{0645}\x{06CC}\x{200C}\x{0634}\x{0648}\x{062F}\x{061B} \x{0644}\x{0637}\x{0641}\x{0627}\x{064B} \x{0622}\x{0646} \x{0631}\x{0627} \x{0631}\x{0648}\x{0634}\x{0646} \x{0646}\x{06AF}\x{0647} \x{062F}\x{0627}\x{0631}\x{06CC}\x{062F}."
                : "School Printer chose this computer as the network's main station. Everyone's print and scan page is now served from here, so please keep it switched on and connected.";
    utf8::encode($_) for $title, $text;
    my $pid = fork; return unless defined $pid; if ($pid) { return }
    open(STDOUT, '>', '/dev/null'); open(STDERR, '>', '/dev/null');
    if ($^O eq 'darwin') {    # the daemon runs as root: show it in the signed-in user's session
        my $uid = (stat '/dev/console')[4]; my $u = defined $uid ? getpwuid($uid) : undef;
        if ($u && $u ne 'root') { (my $t = $text) =~ s/["\\]//g; (my $h = $title) =~ s/["\\]//g;
            exec 'launchctl', 'asuser', $uid, 'sudo', '-u', $u, 'osascript', '-e', qq{display dialog "$t" with title "$h" buttons {"OK"} default button 1 with icon note giving up after 120} }
    } elsif (which('notify-send')) {    # every signed-in desktop
        for my $bus (glob '/run/user/*/bus') { my ($uid) = $bus =~ m{/run/user/(\d+)/}; my $u = getpwuid($uid) or next;
            system('sudo', '-u', $u, 'env', "DBUS_SESSION_BUS_ADDRESS=unix:path=$bus", 'notify-send', '-a', 'School Printer', '-t', '120000', $title, $text) }
    }
    exit 0;
}
sub leader { my $l = jdec(slurp("$SYNC/leader.json")); ref $l eq 'HASH' && $l->{id} ? $l : { id => node_id(), url => my_url() } }
my $ALIAS_PID = 0;
sub alias_on {    # publish schoolprinter.local -> this computer (child process lives while we are the main station)
    return if $ALIAS_PID && kill 0, $ALIAS_PID;
    my ($ip) = my_url() =~ m{//([\d.]+):}; return unless $ip;
    my @cmd = $^O eq 'darwin' ? ('dns-sd', '-P', 'School Printer (web)', '_http._tcp', 'local', $PORT, $ALIAS, $ip, 'path=/')
            : which('avahi-publish') ? ('avahi-publish', '-a', '-R', $ALIAS, $ip) : ();
    return unless @cmd && which($cmd[0]);
    my $pid = fork; if (defined $pid && !$pid) { open(STDOUT, '>', '/dev/null'); open(STDERR, '>', '/dev/null'); exec @cmd; exit 0 }
    $ALIAS_PID = $pid || 0;
}
sub alias_off { if ($ALIAS_PID) { kill 'TERM', $ALIAS_PID; waitpid($ALIAS_PID, 0); $ALIAS_PID = 0 } }
sub measure_bw {    # fetch 1 MB from a random online station; keep the last 5 results (median = bw in status)
    my @on = grep { $_->{online} } stations(); return 0 unless @on;
    my $x = $on[int rand @on]; my ($c, $b) = peer($x, 'GET', '/sync/probe', {}, '', 10);
    return 0 unless $c == 200 && length $b >= 1_000_000;
    my $mbps = length($b) * 8 / 1e6 / ($XFER > 0.001 ? $XFER : 0.001); $mbps = 10000 if $mbps > 10000;    # the transfer only, not the decryption
    my $h = jdec(slurp("$SYNC/bw.json")); my @v = ref $h eq 'ARRAY' ? @$h : (); push @v, $mbps; @v = @v[-5 .. -1] if @v > 5;
    spit("$SYNC/bw.json", json([map { N(sprintf '%.1f', $_) } @v])); 1;
}
sub uptime_tick {    # running time in 5-minute blocks, kept across restarts (Sync/uptime.json)
    my $u = jdec(slurp("$SYNC/uptime.json")); $u = { blocks => 0, part => 0, last => 0 } unless ref $u eq 'HASH';
    my $now = time; my $d = $u->{last} ? $now - $u->{last} : 0; $d = 0 if $d < 0 || $d > 120;    # stopped in between: not counted
    $u->{part} += $d; while ($u->{part} >= 300) { $u->{part} -= 300; $u->{blocks}++ } $u->{last} = $now;
    spit("$SYNC/uptime.json", json({ blocks => N($u->{blocks}), part => N($u->{part}), last => N($now) }));
}
sub uptime_blocks { my $u = jdec(slurp("$SYNC/uptime.json")); ref $u eq 'HASH' ? $u->{blocks} || 0 : 0 }
sub bw_now { my $h = jdec(slurp("$SYNC/bw.json")); return 0 unless ref $h eq 'ARRAY' && @$h; my @s = sort { $a <=> $b } @$h; $s[$#s / 2] }
my $PROBE = join '', map { pack('N', $_ * 2654435761 % 4294967296) } 1 .. 262144;    # 1 MB, generated once

# ---------------------------------------------------------------- the school address (e.g. print.school) on the school's DNS
# Set once on any station's admin page; the newest setting spreads to every station. Each station then answers that
# name with the main station's address on UDP 53 (all other names are passed on to this computer's own DNS server),
# so the router can hand the stations out as DNS servers. The print page is served on port 80 too, when it is free.
sub adopt_domain {
    my %cf = get_cfg(); my ($best) = sort { ($b->{s}{domainAt} || 0) <=> ($a->{s}{domainAt} || 0) } grep { $_->{online} && defined $_->{s}{domainAt} } stations();
    return unless $best && ($best->{s}{domainAt} || 0) > ($cf{domainAt} || 0) && ($best->{s}{domain} // '') =~ /^([a-z0-9.-]{3,253})?$/;
    $cf{domain} = $best->{s}{domain} // ''; $cf{domainAt} = $best->{s}{domainAt}; save_cfg(%cf);
}
sub upstreams { my %mine = map { $_ => 1 } ipv4s(); grep { !$mine{$_} && !/^0\./ } slurp('/etc/resolv.conf') =~ /^\s*nameserver\s+(\d+\.\d+\.\d+\.\d+)/mg }
sub dns_server {    # (own process) UDP 53 on this computer's network address
    $0 = 'schoolprinter-dns'; $SIG{CHLD} = 'DEFAULT'; my ($srv, $out, $ans, $dom) = (undef, undef, undef, ''); my $bound = ''; my %pend; my @ups; my $next = int rand 65536;
    my $say = sub { spit("$SYNC/dns.json", json({ state => $_[0], err => $_[1] || '', at => N(time) })) };
    my $check = 0;
    while (1) {
        if (time - $check >= 5) {
            $check = time; my %cf = get_cfg(); $dom = lc $cf{domain};
            if (!length $dom || $cf{dns} eq '0') { close $srv if $srv; close $out if $out; ($srv, $out) = (); $say->('off'); sleep 5; next }
            my ($ip) = my_url() =~ m{//([\d.]+):};
            if (!$srv || $bound ne ($ip || '')) {
                close $srv if $srv; close $out if $out;
                $srv = IO::Socket::INET->new(LocalAddr => $ip || '0.0.0.0', LocalPort => $ENV{SP_DNSPORT} || 53, Proto => 'udp', ReuseAddr => 1);
                $out = IO::Socket::INET->new(Proto => 'udp');
                unless ($srv && $out) { $say->('busy', "$!"); ($srv, $out) = (); sleep 60; next }
                $bound = $ip || '';
            }
            @ups = upstreams(); $say->('on');
            my $l = leader(); my ($lip) = ($l->{url} || '') =~ m{//([\d.]+):};
            if ($l->{id} ne node_id() && !grep { $_->{id} eq $l->{id} && $_->{online} } stations()) { ($lip) = my_url() =~ m{//([\d.]+):} }
            $ans = $lip ? pack('C4', split /\./, $lip) : undef;
            delete $pend{$_} for grep { time - $pend{$_}{t} > 5 } keys %pend;
        }
        my $sel = IO::Select->new($srv, $out);
        for my $sock ($sel->can_read(1)) {
            my $from = $sock->recv(my $b, 4096); next unless defined $from && length $b >= 12;
            if ($sock == $srv) {    # a question from a device
                my ($i, @l) = (12); while ($i < length $b) { my $n = ord substr($b, $i, 1); last unless $n; last if $n > 63; push @l, lc substr($b, $i + 1, $n); $i += 1 + $n }
                my $name = join '.', @l; my $qtype = unpack('n', substr($b, $i + 1, 2) // "\0\0"); my $qend = $i + 5;
                if ($ans && ($name eq $dom || $name =~ /\.\Q$dom\E$/)) {
                    my $isA = $qtype == 1 || $qtype == 255;
                    my $r = substr($b, 0, 2) . chr(0x84 | (ord(substr($b, 2, 1)) & 1)) . chr(0x80) . pack('nnnn', 1, $isA ? 1 : 0, 0, 0) . substr($b, 12, $qend - 12);
                    $r .= pack('nnnNn', 0xC00C, 1, 1, 30, 4) . $ans if $isA;
                    $srv->send($r, 0, $from); next;
                }
                next unless @ups;
                $next = ($next + 1) % 65536; $pend{$next} = { to => $from, id => substr($b, 0, 2), t => time };
                substr($b, 0, 2) = pack('n', $next); $out->send($b, 0, pack_sockaddr_in(53, Socket::inet_aton($ups[0])));
            } else {    # the answer: back to the device that asked
                my $p = delete $pend{ unpack('n', substr($b, 0, 2)) } or next;
                substr($b, 0, 2) = $p->{id}; $srv->send($b, 0, $p->{to});
            }
        }
    }
}

# ---------------------------------------------------------------- scanning (SANE: scanimage)
# Scanners attached to any station are listed on the print page. Unlike printing, nothing is balanced: the person
# picks the scanner, because the paper is lying in it. The scan is made on that station, then handed back through
# the station the person is using, and offered as a download (kept 30 minutes).
my $SCANIMAGE = which('scanimage');
sub scanner_list {    # [{id, name, dpis, modes, sources}] - cached by the worker (scanimage -L is slow)
    my $l = jdec(slurp("$SYNC/scanners.json")); ref $l eq 'ARRAY' ? $l : [] }
sub detect_scanners {
    return spit("$SYNC/scanners.json", '[]') unless $SCANIMAGE;
    my (undef, $o) = cmd($SCANIMAGE, '-L'); my @l;
    while ($o =~ /^device [`'](.+?)' is an? (.+)$/mg) {
        my ($id, $name) = ($1, $2);         my (undef, $a) = cmd($SCANIMAGE, '-d', $id, '-A');
        my @dpi; if ($a =~ /--resolution\s+(\S+)/) { my $r = $1; if ($r =~ /^(\d+)\.\.(\d+)/) { my ($lo, $hi) = ($1, $2); @dpi = grep { $_ >= $lo && $_ <= $hi } 75, 100, 150, 200, 300, 400, 600, 1200 } else { @dpi = $r =~ /(\d+)/g } }
        @dpi = (75, 150, 300, 600) unless @dpi; @dpi = grep { $_ >= 50 && $_ <= 2400 } @dpi;
        my @modes = ('color', 'gray'); if ($a =~ /--mode\s+(\S+)/) { my $m = $1; @modes = (); push @modes, 'color' if $m =~ /Color/i; push @modes, 'gray' if $m =~ /Gray/i; @modes = ('gray') unless @modes }
        my @src = ('flatbed'); if ($a =~ /--source\s+(\S+)/) { my $s = $1; @src = (); push @src, 'flatbed' if $s =~ /Flatbed|Normal/i; push @src, 'feeder' if $s =~ /ADF|Feeder|Automatic/i; @src = ('flatbed') unless @src }
        push @l, { id => $id, name => clean_text($name, 60), dpis => [map { N($_) } @dpi], modes => \@modes, sources => \@src, srcnames => [$a =~ /--source\s+(\S+)/ ? split(/\|/, (split /\s/, $1)[0]) : ()] };
    }
    spit("$SYNC/scanners.json", json(\@l));
}
sub scan_get { my $id = shift; return undef unless $id =~ /^[0-9a-f]{16}$/; my $j = jdec(slurp("$SCANS/$id.json")); ref $j eq 'HASH' ? $j : undef }
sub scan_set { my ($id, %kv) = @_; my $j = scan_get($id) || { sid => $id, at => time }; $j->{$_} = $kv{$_} for keys %kv; $j->{$_} = N($j->{$_} || 0) for qw(at size pages dpi pid); spit("$SCANS/$id.json", json($j)) }
sub jpeg_size { my $d = shift; my $i = 2; while ($i + 9 < length $d) { my ($m, $t) = unpack('CC', substr($d, $i, 2)); return () unless $m == 0xFF;
    my $len = unpack('n', substr($d, $i + 2, 2)); if ($t >= 0xC0 && $t <= 0xCF && !grep { $_ == $t } 0xC4, 0xC8, 0xCC) { my ($h, $w) = unpack('nn', substr($d, $i + 5, 4)); return ($w, $h, ord substr($d, $i + 9, 1)) } $i += 2 + $len } () }
sub jpegs_pdf {    # one page per JPEG, page size = picture size at the scan resolution. Same as Jpegs-Pdf in syncd.ps1.
    my ($imgs, $dpi) = @_; my @o; my @kids; my $n = @$imgs;
    for my $k (0 .. $n - 1) {
        my ($w, $h, $c) = jpeg_size($imgs->[$k]) or next; my ($pw, $ph) = map { sprintf '%.2f', $_ * 72 / $dpi } $w, $h; my ($po, $co, $io) = (3 + 3 * $k, 4 + 3 * $k, 5 + 3 * $k);
        push @kids, "$po 0 R";
        $o[$po] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pw $ph] /Resources << /XObject << /Im$k $io 0 R >> >> /Contents $co 0 R >>";
        my $cs = "q $pw 0 0 $ph 0 0 cm /Im$k Do Q"; $o[$co] = "<< /Length " . length($cs) . " >>\nstream\n$cs\nendstream";
        $o[$io] = "<< /Type /XObject /Subtype /Image /Width $w /Height $h /ColorSpace /" . ($c == 1 ? 'DeviceGray' : $c == 4 ? 'DeviceCMYK' : 'DeviceRGB') .
                  " /BitsPerComponent 8 /Filter /DCTDecode /Length " . length($imgs->[$k]) . " >>\nstream\n" . $imgs->[$k] . "\nendstream";
    }
    $o[1] = '<< /Type /Catalog /Pages 2 0 R >>'; $o[2] = '<< /Type /Pages /Kids [' . join(' ', @kids) . '] /Count ' . scalar(@kids) . ' >>';
    my $pdf = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"; my @off;
    for my $i (1 .. $#o) { next unless defined $o[$i]; $off[$i] = length $pdf; $pdf .= "$i 0 obj\n$o[$i]\nendobj\n" }
    my $x = length $pdf; $pdf .= "xref\n0 " . @o . "\n0000000000 65535 f \n";
    $pdf .= defined $off[$_] ? sprintf("%010d 00000 n \n", $off[$_]) : "0000000000 65535 f \n" for 1 .. $#o;
    $pdf . "trailer\n<< /Size " . @o . " /Root 1 0 R >>\nstartxref\n$x\n%%EOF\n";
}
sub scan_local {    # (in a worker process) make the scan; -> Sync/scans/<sid>.<ext>
    my ($sid, $q) = @_; alarm 0;
    my ($dev) = grep { $_->{id} eq $q->{device} } @{ scanner_list() };
    return scan_set($sid, state => 'failed', err => 'NO_SCANNER') unless $dev && $SCANIMAGE;
    open(my $lk, '>>', "$SYNC/scan-" . unpack('H*', substr(Digest::SHA::sha1($dev->{id}), 0, 6)) . '.lock') or return scan_set($sid, state => 'failed', err => 'BUSY');
    scan_set($sid, state => 'waiting') unless flock($lk, LOCK_EX | LOCK_NB); flock($lk, LOCK_EX);    # one scan at a time per scanner
    scan_set($sid, state => 'scanning', pid => $$);
    my @a = ('-d', $dev->{id}, '--resolution', $q->{dpi}, '--mode', $q->{mode} eq 'gray' ? 'Gray' : 'Color');
    if ($q->{source} eq 'feeder') { my ($s) = grep { /ADF|Feeder|Automatic/i } @{ $dev->{srcnames} || [] }; push @a, '--source', $s || 'ADF' }
    elsif (@{ $dev->{srcnames} || [] }) { my ($s) = grep { /Flatbed|Normal/i } @{ $dev->{srcnames} }; push @a, '--source', $s if $s }
    my $fmt = $q->{format}; my @pages; my $tmp = "$SCANS/$sid-work"; mkdir $tmp;
    if ($fmt eq 'png' && $q->{source} ne 'feeder') { my ($st, $o) = cmd_out($SCANIMAGE, @a, '--format=png'); @pages = ($o) if $st == 0 && substr($o, 0, 4) eq "\x89PNG" }
    elsif ($q->{source} eq 'feeder') { cmd($SCANIMAGE, @a, '--format=jpeg', "--batch=$tmp/p%03d.jpg"); @pages = map { slurp($_) } sort glob("$tmp/p*.jpg") }
    else { my ($st, $o) = cmd_out($SCANIMAGE, @a, '--format=jpeg'); @pages = ($o) if $st == 0 && substr($o, 0, 2) eq "\xFF\xD8" }
    unlink glob("$tmp/*"); rmdir $tmp; close $lk;
    return scan_set($sid, state => 'failed', err => $q->{source} eq 'feeder' ? 'FEEDER_EMPTY' : 'SCAN_FAILED') unless @pages;
    my ($ext, $data) = $fmt eq 'png' ? ('png', $pages[0]) : $fmt eq 'jpg' ? ('jpg', $pages[0]) : ('pdf', jpegs_pdf(\@pages, $q->{dpi}));
    spit("$SCANS/$sid.$ext", $data);
    scan_set($sid, state => 'ready', ext => $ext, size => length $data, pages => scalar @pages);
}
sub scan_norm {    # request -> clean scan settings for a known scanner, or an error code
    my ($g, $list) = @_; my %q = map { $_ => $g->($_) // '' } qw(station device dpi mode source format);
    my ($dev) = grep { $_->{id} eq $q{device} } @$list; return (undef, 'NO_SCANNER') unless $dev;
    my @d = map { 0 + $_ } @{ $dev->{dpis} }; $q{dpi} = 300 unless $q{dpi} =~ /^\d+$/;
    my ($near) = sort { abs($a - $q{dpi}) <=> abs($b - $q{dpi}) } @d; $q{dpi} = $near || 300;
    $q{mode} = 'color' unless grep { $_ eq $q{mode} } @{ $dev->{modes} }; $q{mode} = $dev->{modes}[0] unless grep { $_ eq $q{mode} } @{ $dev->{modes} };
    $q{source} = 'flatbed' unless grep { $_ eq $q{source} } @{ $dev->{sources} };
    $q{format} = 'pdf' unless $q{format} =~ /^(pdf|jpg|png)$/; $q{format} = 'pdf' if $q{source} eq 'feeder';
    (\%q, '');
}
sub scan_remote {    # (in a worker process) ask the scanner's station to scan, then fetch the file here
    my ($sid, $x, $q) = @_; alarm 0;
    my ($c, $b) = peer($x, 'POST', '/sync/scan', { map { $_ => $q->{$_} } qw(device dpi mode source format) }, '', 10);
    my $r = $c == 200 ? jdec($b) : undef;
    return scan_set($sid, state => 'failed', err => $c == 0 ? 'STATION_OFFLINE' : (ref $r eq 'HASH' && $r->{error}) || 'SCAN_FAILED') unless ref $r eq 'HASH' && ($r->{sid} || '') =~ /^[0-9a-f]{16}$/;
    my $end = time + 900; my $lost = 0; scan_set($sid, pid => $$);
    while (time < $end) {
        Time::HiRes::sleep(1);
        my ($c2, $b2) = peer($x, 'GET', "/sync/scan/$r->{sid}", {}, '', 5);
        if ($c2 != 200) { my ($y) = grep { $_->{id} eq $x->{id} } stations(); $lost ||= time if $c2 == 0 || ($y && !$y->{online});    # station went quiet mid-scan
                          return scan_set($sid, state => 'failed', err => 'STATION_LOST') if $lost && time - $lost >= 20; next }
        $lost = 0;
        my $s = jdec($b2); next unless ref $s eq 'HASH';
        if ($s->{state} eq 'ready') {
            my ($c3, $d) = peer($x, 'GET', "/sync/scan/$r->{sid}/file", {}, '', 120);
            return scan_set($sid, state => 'failed', err => 'SCAN_FAILED') unless $c3 == 200 && length $d;
            spit("$SCANS/$sid.$s->{ext}", $d); return scan_set($sid, state => 'ready', ext => $s->{ext}, size => length $d, pages => $s->{pages} || 1);
        }
        return scan_set($sid, state => 'failed', err => $s->{err} || 'SCAN_FAILED') if $s->{state} eq 'failed';
        scan_set($sid, state => $s->{state}) if $s->{state} =~ /^(waiting|scanning)$/;
    }
    scan_set($sid, state => 'failed', err => 'SCAN_FAILED');
}
sub scanners_all {    # every scanner in the network, for the print page
    my %cf = get_cfg(); my @l = map { { station => node_id(), stationName => station_of(%cf), here => B(1), online => B(1), %$_ } } @{ scanner_list() };
    if (group()) { for my $x (grep { $_->{online} } stations()) { push @l, map { { station => $x->{id}, stationName => $x->{station}, here => B(0), online => B(1), %$_ } } @{ $x->{s}{scanners} || [] } } }
    delete $_->{srcnames} for @l;
    \@l;
}

# ---------------------------------------------------------------- IPP printer ("Add to this device")
# Devices add ipp://<this computer>:8631/ipp/print with their own driverless driver (macOS/Linux IPP Everywhere,
# Windows IPP Class Driver) and print PDF/JPEG/PNG from any app; jobs go through do_print like the web page's.
my $IPP_JOB = time % 100000;    # per request process: the job id is made unique below
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
        if (ia($r, 'job-name', '') =~ /^School Printer - /) {    # our own job coming back: the printer is a School Printer queue
            my $stamp = "$SYNC/loop.log"; if (time - ((stat $stamp)[9] || 0) > 60) { spit($stamp, ''); logline('print-loop  copies=0  exit=loop: a School Printer queue is set as the printer - choose the real printer on the admin page') }
            return ipp_reply($c, $r, 0x0404, ia_attr(0x41, 'status-message', 'Print loop: this job came from School Printer itself.'));
        }
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
        spit("$UP/job-$label", $d); my $jid = ((time % 100000) * 100 + $$ % 100) % 2147483647;
        my ($pp) = grep { $_->{n} eq $s{paper} } @{ $cp->{papers} }; @s{qw(pw ph sheets from)} = ($pp ? ${ $pp->{w} } : '', $pp ? ${ $pp->{h} } : '', $copies, $from);
        $s{orientation} = $s{orient_auto} ? 'auto' : $s{land} ? 'landscape' : 'portrait';
        my ($tgt) = pick_station('auto', { color => $s{color} eq 'color', duplex => $s{duplex} ne 'off', pw => $s{pw}, ph => $s{ph} });
        my $tj = rnd_hex(8); job_set($tj, state => $tgt ? 'sending' : 'queued', sid => $tgt ? $tgt->{id} : node_id(), sheets => $copies);
        ipp_reply($c, $r, 0, chr(0x02) . ia_attr(0x21, 'job-id', $jid) . ia_attr(0x45, 'job-uri', "$uri/$jid") . ia_attr(0x23, 'job-state', 9) . ia_attr(0x44, 'job-state-reasons', 'job-completed-successfully'));
        close $c; hold($tj, "$UP/job-$label", \%s, $label); if ($tgt) { forward_job($tgt, "$UP/job-$label", \%s, $label, $tj, 0) } else { do_print("$UP/job-$label", \%s, $label, $tj) } return;
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
my %REASON = (200 => 'OK', 202 => 'Accepted', 401 => 'Unauthorized', 409 => 'Conflict', 400 => 'Bad Request', 403 => 'Forbidden', 404 => 'Not Found', 410 => 'Gone', 413 => 'Payload Too Large',
              415 => 'Unsupported Media Type', 500 => 'Internal Server Error', 503 => 'Service Unavailable');
sub reply {
    my ($c, $code, $type, $body, $cache) = @_;
    print $c "HTTP/1.1 $code $REASON{$code}\r\nContent-Type: $type\r\nContent-Length: " . length($body) .
        "\r\nCache-Control: " . ($cache ? 'max-age=86400' : 'no-store') . "\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n$body";
}
sub jreply { my ($c, $code, $obj) = @_; reply($c, $code, 'application/json; charset=utf-8', json($obj)) }
# ---------------------------------------------------------------- encryption between stations (protocol 2)
# Every station has a permanent identity: a Diffie-Hellman key pair (RFC 3526 group 14, 2048 bit). Two stations derive
# their own pair key from it and from the network key; every /sync/* request and answer is encrypted (AES-256-CTR, via
# the system's openssl) and sealed (HMAC-SHA256 over the encrypted bytes, the method, path, time and a one-use nonce),
# so nobody in the middle can read, change or replay it. In a private network a station's identity is vouched for by
# the network key; in the public one it is remembered on first contact and a change is refused (and shown on the admin
# page). Same protocol as sync.ps1 on Windows.
use Math::BigInt;
my $DH_P = Math::BigInt->from_hex('FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF');
my $OPENSSL = which('openssl');
sub hex512 { my $h = shift->as_hex; $h =~ s/^0x//; ('0' x (512 - length $h)) . $h }
sub identity {    # -> (secret hex, public key hex); made once, kept in Sync/identity.json
    my $i = jdec(slurp("$SYNC/identity.json"));
    return ($i->{x}, $i->{pk}) if ref $i eq 'HASH' && ($i->{x} || '') =~ /^[0-9a-f]{64}$/ && ($i->{pk} || '') =~ /^[0-9a-f]{512}$/;
    my $x = rnd_hex(32); my $pk = hex512(Math::BigInt->new(2)->bmodpow(Math::BigInt->from_hex($x), $DH_P));
    spit("$SYNC/identity.json", json({ x => $x, pk => $pk })); chmod 0600, "$SYNC/identity.json"; ($x, $pk);
}
sub pk_mac { my ($g, $id, $pk) = @_; Digest::SHA::hmac_sha256_hex("pk\n$id\n$pk", $g->{key}) }
sub pin_ok {    # is $pk really station $id? (private: the network key vouches for it; public: the first key seen is kept)
    my ($g, $id, $pk, $mac) = @_; return 0 unless $id =~ /^[0-9a-f]{32}$/ && ($pk || '') =~ /^[0-9a-f]{512}$/;
    my $pins = jdec(slurp("$SYNC/pins.json")); $pins = {} unless ref $pins eq 'HASH';
    my $vouched = $g->{mode} eq 'private' && same_text(pk_mac($g, $id, $pk), $mac || '');
    return 0 if $g->{mode} eq 'private' && !$vouched;
    if (($pins->{$id} || '') eq $pk) { return 1 }
    if (!$pins->{$id} || $vouched) { $pins->{$id} = $pk; spit("$SYNC/pins.json", json($pins)); return 1 }
    my $a = jdec(slurp("$SYNC/alerts.json")); $a = {} unless ref $a eq 'HASH';    # public network, key changed: refuse and tell
    $a->{$id} = { at => N(time), pk => $pk }; spit("$SYNC/alerts.json", json($a)); 0;
}
sub pair_keys {    # -> (enc key, mac key) shared with station $id
    my ($g, $id, $pk) = @_; my $f = "$SYNC/pairs/$id.json"; my $p = jdec(slurp($f));
    return (pack('H*', $p->{e}), pack('H*', $p->{m})) if ref $p eq 'HASH' && ($p->{pk} || '') eq $pk && ($p->{gid} || '') eq $g->{gid};
    my ($x) = identity(); my $z = Math::BigInt->from_hex($pk)->bmodpow(Math::BigInt->from_hex($x), $DH_P);    # ~1 s, once per station
    my ($a, $b) = sort (node_id(), $id);
    my $m = Digest::SHA::hmac_sha256("pair\n$a\n$b\n" . Digest::SHA::sha256(pack('H*', hex512($z))), $g->{key});
    my ($e, $mk) = (Digest::SHA::hmac_sha256('enc', $m), Digest::SHA::hmac_sha256('mac', $m));
    mkdir "$SYNC/pairs"; spit($f, json({ pk => $pk, gid => $g->{gid}, e => unpack('H*', $e), m => unpack('H*', $mk) })); chmod 0600, $f;
    ($e, $mk);
}
sub ctr {    # AES-256-CTR with the system's openssl (the same bytes encrypt and decrypt)
    my ($k, $iv, $d) = @_; return '' unless length $d; die "openssl missing\n" unless $OPENSSL;
    my $t = "$SYNC/tmp-$$-" . rnd_hex(4); spit("$t.in", $d);
    my ($st) = cmd($OPENSSL, 'enc', '-aes-256-ctr', '-nosalt', '-K', unpack('H*', $k), '-iv', unpack('H*', $iv), '-in', "$t.in", '-out', "$t.out");
    my $o = slurp("$t.out"); unlink "$t.in", "$t.out"; die "openssl failed\n" if $st || length $o != length $d; $o;
}
sub ivof { my ($mk, $dir, $n) = @_; substr(Digest::SHA::hmac_sha256("iv\n$dir\n$n", $mk), 0, 16) }
sub envelope { my ($meta, $payload) = @_; my $j = json($meta || {}); pack('N', length $j) . $j . ($payload // '') }
sub unenvelope { my $p = shift; return ({}, '') if length $p < 4; my $n = unpack('N', $p); (jdec(substr($p, 4, $n)) || {}, substr($p, 4 + $n)) }
sub peer {    # encrypted, signed request to station $x -> (status, decrypted answer); status 0 = no (trustworthy) answer
    my ($x, undef, $p, $meta, $payload, $to) = @_; my $m = 'POST'; my $g = group() or return (0, 'no network');    # always POST (Windows sends these in parallel)
    return (0, 'unknown station') unless ($x->{pk} || '') =~ /^[0-9a-f]{512}$/;
    my ($e, $mk) = eval { pair_keys($g, $x->{id}, $x->{pk}) } or return (0, 'keys');
    my ($xs, $mypk) = identity(); my $id = node_id(); my $t = time; my $n = rnd_hex(16);
    my $ct = eval { ctr($e, ivof($mk, 'req', $n), envelope($meta, $payload)) }; return (0, 'crypto') unless defined $ct;
    my %h = ('X-Sync-Node' => $id, 'X-Sync-Time' => $t, 'X-Sync-Nonce' => $n, 'X-Sync-Pk' => $mypk, 'X-Sync-Pkmac' => pk_mac($g, $id, $mypk),
             'X-Sync-Sig' => Digest::SHA::hmac_sha256_hex("req\n$t\n$m\n$p\n$id\n$n\n" . Digest::SHA::sha256_hex($ct), $mk));
    my ($c, $b, $hd) = http($x->{url}, $m, $p, \%h, $ct, $to);
    return ($c, $b) if $c == 0 || $c == 401;    # not sealed: no trust in the body
    my $mac = ($hd =~ /^X-Sync-Mac:\s*([0-9a-f]{64})/mi)[0] || '';
    return (0, 'bad seal') unless same_text(Digest::SHA::hmac_sha256_hex("res\n$n\n$c\n" . Digest::SHA::sha256_hex($b), $mk), $mac);
    my $pl = eval { ctr($e, ivof($mk, 'res', $n), $b) }; defined $pl ? ($c, $pl) : (0, 'crypto');
}
sub sync_open {    # (server) check and open a station's request -> context {from, e, mk, n, meta, payload} or undef
    my ($H, $m, $p, $body) = @_; my $g = group() or return undef;
    my ($id, $t, $n, $s, $pk, $pm) = map { $H->{$_} || '' } qw(x-sync-node x-sync-time x-sync-nonce x-sync-sig x-sync-pk x-sync-pkmac);
    return undef unless $id =~ /^[0-9a-f]{32}$/ && $t =~ /^\d{9,11}$/ && $n =~ /^[0-9a-f]{32}$/ && $s =~ /^[0-9a-f]{64}$/ && abs(time - $t) <= 300;
    return undef unless pin_ok($g, $id, $pk, $pm);
    my ($e, $mk) = eval { pair_keys($g, $id, $pk) } or return undef;
    return undef unless same_text(Digest::SHA::hmac_sha256_hex("req\n$t\n$m\n$p\n$id\n$n\n" . Digest::SHA::sha256_hex($body), $mk), $s);
    mkdir "$SYNC/nonces"; return undef if -e "$SYNC/nonces/$n"; spit("$SYNC/nonces/$n", '');    # each request counts once
    my $pl = eval { ctr($e, ivof($mk, 'req', $n), $body) }; return undef unless defined $pl;
    my ($meta, $payload) = unenvelope($pl);
    { from => $id, e => $e, mk => $mk, n => $n, meta => $meta, payload => $payload };
}
sub sreply {    # (server) encrypted, sealed answer to a station
    my ($c, $x, $code, $data) = @_; my $ct = ctr($x->{e}, ivof($x->{mk}, 'res', $x->{n}), $data // '');
    print $c "HTTP/1.1 $code $REASON{$code}\r\nContent-Type: application/octet-stream\r\nContent-Length: " . length($ct) .
             "\r\nX-Sync-Mac: " . Digest::SHA::hmac_sha256_hex("res\n$x->{n}\n$code\n" . Digest::SHA::sha256_hex($ct), $x->{mk}) . "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n$ct";
}
sub sjreply { my ($c, $x, $code, $obj) = @_; sreply($c, $x, $code, json($obj)) }


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

    # ---- printing network
    if ($m eq 'GET' && $path eq '/sync/hello') {    # public: lets other stations find this one (gid says which network)
        my %cf = get_cfg(); my $g = group(); my (undef, $pk) = identity(); my $id = node_id();
        return jreply($c, 200, { app => 'school-printer', proto => N($PROTO), id => $id, station => station_of(%cf), gid => $g ? $g->{gid} : '', net => $g ? $g->{mode} : 'alone',
                                 pk => $pk, pkmac => $g ? pk_mac($g, $id, $pk) : '' });
    }
    if ($m eq 'POST' && $path eq '/sync/join') {
        return jreply($c, 400, { error => 'BAD' }) if $len > 4096 || !$HAS_SHA; my $b = read_body($c, $len, $rest); return unless defined $b;
        my ($st, $r) = join_answer(jdec($b) || {}, $peer); return jreply($c, $st, $r);
    }
    if ($path =~ m{^/sync/}) {    # another station: encrypted and sealed both ways
        return jreply($c, 413, { error => 'File is bigger than 50 MB.' }) if $len > $MAX + 65536;
        my $body = read_body($c, $len, $rest); return unless defined $body;
        my $x = sync_open(\%H, $m, $path, $body) or return jreply($c, 401, { error => 'SIGNATURE', time => N(time) });
        my ($from, $mt, $pl) = ($x->{from}, $x->{meta}, $x->{payload});
        # a station that knows us but we do not know it (its announce got lost): look again now, not in a minute
        spit("$SYNC/scan-now", '') unless -e "$SYNC/scan-now" || grep { $_->{id} eq $from } @{ peers_list() };
        if ($path eq '/sync/announce') { return sjreply($c, $x, 200, { ok => B(1) }) }
        if ($path eq '/sync/probe') { return sreply($c, $x, 200, $PROBE) }
        if ($path eq '/sync/status') { return sreply($c, $x, 200, json(self_cached())) }
        if ($path eq '/sync/scan') {
            my ($q, $err) = scan_norm(sub { $mt->{$_[0]} }, scanner_list()); return sjreply($c, $x, 404, { error => $err }) unless $q;
            my $sid = rnd_hex(8); scan_set($sid, state => 'waiting'); sjreply($c, $x, 200, { sid => $sid }); close $c; scan_local($sid, $q); return;
        }
        if ($path =~ m{^/sync/scan/([0-9a-f]{16})(/file)?$}) {
            my ($sid, $file) = ($1, $2); my $j = scan_get($sid) or return sjreply($c, $x, 404, { error => 'GONE' });
            return sjreply($c, $x, 200, { state => $j->{state}, err => $j->{err} || '', ext => $j->{ext} || '', pages => N($j->{pages} || 0) }) unless $file;
            my $d = slurp("$SCANS/$sid.$j->{ext}"); unlink "$SCANS/$sid.$j->{ext}", "$SCANS/$sid.json"; return sreply($c, $x, 200, $d);
        }
        if ($path eq '/sync/job') {
            my %cf = get_cfg();
            return sjreply($c, $x, 403, { error => 'NOT_ACCEPTING' }) if $cf{accept} eq '0' || $cf{open} eq '0';
            my $ext = $mt->{ext} || ''; return sjreply($c, $x, 415, { error => "This type of file can't be printed." }) unless $ext =~ /^(pdf|png|jpg|gif)$/;
            my $cp = caps($cf{printer}); my $s = norm_settings(sub { $mt->{$_[0]} }, $cp) or return sjreply($c, $x, 400, { error => 'Bad settings.' });
            (my $src = $mt->{from} || 'x') =~ s/[^0-9A-Fa-f.]/_/g; my ($sx) = grep { $_->{id} eq $from } stations(); (my $via = ($sx ? $sx->{station} : '') || 'station') =~ s/[^A-Za-z0-9_]+/_/g;
            my $label = strftime('%Y%m%d-%H%M%S', localtime) . '-' . int(rand(99999)) . "-from$src-via" . substr($via, 0, 24) . "-c$s->{copies}.$ext";
            spit("$UP/job-$label", $pl);
            unless (magic_ok("$UP/job-$label", $ext)) { unlink "$UP/job-$label"; return sjreply($c, $x, 415, { error => "This type of file can't be printed." }) }
            my $jid = rnd_hex(8); my ($jobs) = cups_queue($cf{printer});
            job_set($jid, state => 'queued', station => station_of(%cf), sid => node_id(), sheets => ($mt->{sheets} || 1) =~ /^(\d+)$/ ? $1 : 1);
            sjreply($c, $x, 200, { ok => B(1), jid => $jid, ahead => N($jobs) }); close $c;
            do_print("$UP/job-$label", $s, $label, $jid); return;
        }
        if ($path =~ m{^/sync/job/([0-9a-f]{16})$}) {
            my $j = job_get($1) or return sjreply($c, $x, 404, { error => 'GONE' });
            return sjreply($c, $x, 200, { state => $j->{state}, ahead => N($j->{ahead} || 0), err => $j->{err} || '' });
        }
        if ($path eq '/sync/convert') {
            my %cf = get_cfg(); my $ext = lc($mt->{ext} || '');
            return sjreply($c, $x, 503, { error => 'NO_CONVERTER' }) unless $SOFFICE && $cf{conv} ne '0';
            return sjreply($c, $x, 415, { error => "This type of file can't be printed." }) unless grep { $_ eq $ext } @OFFICE, 'txt';
            my $rid = rnd_hex(16); spit("$UP/$rid.$ext", $pl);
            unless (magic_ok("$UP/$rid.$ext", $ext)) { unlink "$UP/$rid.$ext"; return sjreply($c, $x, 415, { error => "This type of file can't be printed." }) }
            sjreply($c, $x, 200, { rid => $rid }); close $c; alarm 170; convert($rid, $ext); return;
        }
        if ($path =~ m{^/sync/converted/([0-9a-f]{32})$}) {
            my $rid = $1;
            if (-e "$UP/$rid.pdf") { my $d = slurp("$UP/$rid.pdf"); unlink glob("$UP/$rid.*"); return sreply($c, $x, 200, $d) }
            if (-e "$UP/$rid.fail") { unlink glob("$UP/$rid.*"); return sjreply($c, $x, 410, { error => 'FAILED' }) }
            return glob("$UP/$rid.*") ? sjreply($c, $x, 202, { state => 'converting' }) : sjreply($c, $x, 404, { error => 'GONE' });
        }
        return sjreply($c, $x, 404, { error => 'Not found' });
    }
    if ($m eq 'GET' && $path eq '/stations') {    # public: the stations a person can pick on the print page
        my %cf = get_cfg(); my $me = self_cached();
        my @l = ({ id => node_id(), station => station_of(%cf), printer => $cf{printer}, here => B(1), online => B(1), ready => B($me->{ready}), url => my_url(),
                   queue => N($me->{queue} || 0), jobs => N($me->{jobs} || 0), color => B($me->{color}), duplex => B($me->{duplex}) });
        if (group()) {
            for my $x (sort { lc $a->{station} cmp lc $b->{station} } stations()) {
                push @l, { id => $x->{id}, station => $x->{station}, printer => $x->{s}{printer} || '', here => B(0), online => B($x->{online}), url => $x->{url},
                           ready => B($x->{online} && $x->{s}{ready} && $x->{s}{accept}), queue => N($x->{s}{queue} || 0), jobs => N($x->{s}{jobs} || 0),
                           color => B($x->{s}{color}), duplex => B($x->{s}{duplex}) };
            }
        }
        return jreply($c, 200, { here => node_id(), auto => B(group() && $cf{share} ne '0'), list => \@l });
    }
    if ($m eq 'GET' && $path eq '/scanners') { return jreply($c, 200, { list => scanners_all() }) }
    if ($m eq 'POST' && $path eq '/scan') {
        my %cf = get_cfg();
        return jreply($c, 503, { error => 'Printing is closed right now.' }) if $cf{open} eq '0';
        return jreply($c, 403, { error => 'Wrong PIN.' }) if length $cf{pin} && ($H{'x-pin'} || '') ne $cf{pin};
        return jreply($c, 400, { error => 'Bad settings.' }) if $len > 65536; my $body = read_body($c, $len, $rest); return unless defined $body;
        my $want = jget($body, 'station') // ''; my $all = scanners_all();
        my ($q, $err) = scan_norm(sub { jget($body, $_[0]) }, [grep { $_->{station} eq $want } @$all]); return jreply($c, 404, { error => $err }) unless $q;
        my $sid = rnd_hex(8); my ($dev) = grep { $_->{station} eq $want && $_->{id} eq $q->{device} } @$all;
        scan_set($sid, state => 'waiting', station => $dev->{stationName}, name => $dev->{name}, dpi => $q->{dpi});
        jreply($c, 200, { sid => $sid, station => $dev->{stationName} }); close $c;
        if ($want eq node_id()) { scan_local($sid, $q) } else { my ($x) = grep { $_->{id} eq $want } stations(); $x ? scan_remote($sid, $x, $q) : scan_set($sid, state => 'failed', err => 'STATION_OFFLINE') }
        return;
    }
    if ($m eq 'GET' && $path =~ m{^/scan/([0-9a-f]{16})(/file)?$}) {
        my ($sid, $file) = ($1, $2); my $j = scan_get($sid) or return jreply($c, 200, { state => 'gone' });
        return jreply($c, 200, { state => $j->{state}, err => $j->{err} || '', ext => $j->{ext} || '', size => N($j->{size} || 0), pages => N($j->{pages} || 0), station => $j->{station} || '' }) unless $file;
        return jreply($c, 404, { error => 'GONE' }) unless $j->{state} eq 'ready' && -e "$SCANS/$sid.$j->{ext}";
        my $name = 'scan-' . strftime('%Y%m%d-%H%M%S', localtime($j->{at} || time)) . ".$j->{ext}"; my $d = slurp("$SCANS/$sid.$j->{ext}");
        print $c "HTTP/1.1 200 OK\r\nContent-Type: " . ($MIME{$j->{ext}} || 'application/octet-stream') . "\r\nContent-Length: " . length($d) .
                 "\r\nContent-Disposition: attachment; filename=\"$name\"\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n$d";
        return;
    }
    if ($m eq 'GET' && $path =~ m{^/job/([0-9a-f]{16})$}) {    # public: the print page follows its job
        my $j = job_get($1) or return jreply($c, 200, { state => 'gone' });
        return jreply($c, 200, { state => $j->{state}, station => $j->{station} || '', ahead => N($j->{ahead} || 0), moved => B($j->{moved}), why => $j->{why} || '', err => $j->{err} || '' });
    }

    if ($path =~ m{^/admin}) {    # admin: this computer only; X-Admin stops other web pages posting here
        return jreply($c, 403, { error => 'The admin page only works on the printer computer.' }) unless $local;
        return reply($c, 200, $MIME{html}, $PAGE{admin}) if $m eq 'GET' && $path eq '/admin';
        return jreply($c, 403, { error => 'Forbidden' }) unless ($H{'x-admin'} || '') eq '1';
        my %cf = get_cfg(); my $pr = $cf{printer};
        if ($m eq 'GET' && $path eq '/admin/info') {
            my $lu = group() ? leader()->{url} : ''; my @u = map {"http://$_:$PORT"} ipv4s(); @u = ($lu) if $lu && $lu ne my_url();
            unshift @u, "http://$ALIAS:$PORT" if group(); unshift @u, "http://$cf{domain}" if group() && length $cf{domain};
            return jreply($c, 200, { urls => \@u, name => "http://$HOSTNAME:$PORT", open => B($cf{open} ne '0'),
                pin => $cf{pin}, lang => $cf{lang}, printer => $pr, printers => [printers()], pstatus => pstatus($pr), waiting => N(jobs($pr)),
                jobs => N(jobs($pr)), log => recent(), office => office_state(), net => net_info(%cf) });
        }
        return jreply($c, 404, { error => 'Not found' }) unless $m eq 'POST' && $len <= 65536;
        my $body = read_body($c, $len, $rest); return unless defined $body;
        if ($path eq '/admin/scan') { spit("$SYNC/scan-now", ''); return jreply($c, 200, { ok => B(1) }) }
        if ($path eq '/admin/net') {    # public | private (create) | alone | join (token) | token (show one)
            return jreply($c, 400, { error => 'NO_SHA' }) unless $HAS_SHA;
            my $do = jget($body, 'do') // '';
            if ($do eq 'public' || $do eq 'alone') { set_net($do); return jreply($c, 200, { ok => B(1) }) }
            if ($do eq 'private') { set_net('private', rnd_hex(32)); return jreply($c, 200, { ok => B(1), token => token_new() }) }
            if ($do eq 'token') { my $t = token_new() or return jreply($c, 400, { error => 'NOT_PRIVATE' }); return jreply($c, 200, { token => $t, left => N(900) }) }
            if ($do eq 'trust') {    # the computer was reinstalled: accept its new identity
                my $id = jget($body, 'id') // ''; return jreply($c, 400, { error => 'Bad settings.' }) unless $id =~ /^[0-9a-f]{32}$/;
                for my $f ("$SYNC/pins.json", "$SYNC/alerts.json") { my $h = jdec(slurp($f)); next unless ref $h eq 'HASH'; delete $h->{$id}; spit($f, json($h)) }
                unlink "$SYNC/pairs/$id.json"; spit("$SYNC/scan-now", ''); return jreply($c, 200, { ok => B(1) });
            }
            if ($do eq 'join') { my $r = join_network(jget($body, 'token')); return $r eq '1' ? jreply($c, 200, { ok => B(1) }) : jreply($c, 400, { error => $r }) }
            return jreply($c, 400, { error => 'Bad settings.' });
        }
        if ($path eq '/admin/set') {
            my ($o, $lg, $pin, $p) = map { jget($body, $_) } qw(open lang pin printer);
            my $stn = jget($body, 'station'); utf8::encode($stn) if defined $stn && utf8::is_utf8($stn);
            if (defined $stn) { $stn = clean_text($stn, 40); return jreply($c, 400, { error => 'STATION_EMPTY' }) unless length $stn; $cf{station} = $stn }
            for my $k (qw(share accept conv dns)) { my $v = jget($body, $k); $cf{$k} = $v ? '1' : '0' if defined $v }
            my $dm = jget($body, 'domain');
            if (defined $dm) { $dm = lc $dm; $dm =~ s{^https?://}{}; $dm =~ s{/.*$}{}; $dm =~ s/^\s+|\s+$//g;
                return jreply($c, 400, { error => 'DOMAIN_FORMAT' }) if length $dm && $dm !~ /^(?=.{3,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$/;
                $cf{domain} = $dm; $cf{domainAt} = time }
            $cf{open} = $o ? '1' : '0' if defined $o;
            if (defined $lg) { return jreply($c, 400, { error => 'Unknown language.' }) unless $lg =~ /^(fa|en)$/; $cf{lang} = $lg }
            if (defined $pin) { return jreply($c, 400, { error => 'PIN: letters and numbers only, up to 20.' }) unless $pin =~ /^[A-Za-z0-9]{0,20}$/; $cf{pin} = $pin }
            if (defined $p) { my %own = own_queues(); return jreply($c, 400, { error => 'SELF_QUEUE' }) if $own{$p};
                              return jreply($c, 400, { error => 'That printer does not exist.' }) unless has_printer($p); $cf{printer} = $p }
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

    if ($m eq 'GET' && $path eq '/') {    # one address for everyone: other stations send people to the main station
        my $l = leader(); my ($x) = $l->{id} ne node_id() && $head !~ m{^GET /\?here}m ? grep { $_->{id} eq $l->{id} && $_->{online} } stations() : ();
        if ($x) { print $c "HTTP/1.1 302 Found\r\nLocation: $x->{url}/\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"; return }
        return reply($c, 200, $MIME{html}, $PAGE{print});
    }
    if ($m eq 'GET' && $path eq '/status') {
        my %cf = get_cfg();
        return jreply($c, 200, { waiting => N(jobs($cf{printer})), pin => B(length $cf{pin}), open => B($cf{open} ne '0'), printer => $cf{printer},
            lang => $cf{lang}, office => office_state(), types => [types()], caps => net_caps($cf{printer}), station => station_of(%cf),
            scan => B(scalar @{ scanners_all() }), hasPrinter => B(length $cf{printer} && pstatus($cf{printer}) ne 'Not found') });
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
        else {    # Word/Excel/PowerPoint/text: converted here or on the station with the most free power
            rename $tmp, "$UP/$src"; $state = 'converting';
            my $pid = fork; if (defined $pid && !$pid) { $SIG{ALRM} = 'DEFAULT'; my $x = ($ext eq 'txt' && $CUPSFILTER) ? undef : pick_converter();
                if ($x) { remote_convert($x, $id, $ext) } else { alarm 170; convert($id, $ext) } exit 0 }
        }
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
        my $cp = caps($cf{printer});
        # colour / two-sided are allowed when ANY station that could take the job has them; the chosen station decides
        my $netc = grep { $_->{online} && $_->{s}{color} } stations(); my $netd = grep { $_->{online} && $_->{s}{duplex} } stations();
        my $cpx = { %$cp, color => B(${ $cp->{color} } || $netc), duplex => B(${ $cp->{duplex} } || $netd) };
        my $sp = norm_settings(sub { jget($body, $_[0]) }, $cpx) or return jreply($c, 400, { error => 'Bad settings.' });
        my %s = %$sp; $s{name} = $mt->{name};
        my ($pp) = grep { $_->{n} eq $s{paper} } @{ $cp->{papers} }; ($s{pw}, $s{ph}) = $pp ? (${ $pp->{w} }, ${ $pp->{h} }) : ('', '');
        my $sh = jget($body, 'sheets') // ''; $s{sheets} = ($sh =~ /^\d+$/ && $sh >= 1) ? ($sh > 5000 ? 5000 : $sh) : $s{copies}; $s{from} = $mt->{from};
        my $want = jget($body, 'target') // 'auto'; $want = 'auto' unless $want =~ /^(auto|[0-9a-f]{32})$/;
        my ($tgt, $err) = pick_station($want, { color => $s{color} eq 'color', duplex => $s{duplex} ne 'off', pw => $s{pw}, ph => $s{ph} });
        return jreply($c, 409, { error => 'STATION_OFFLINE' }) if $err;
        unless ($tgt) { $s{color} = 'gray' unless ${ $cp->{color} }; $s{duplex} = 'off' unless ${ $cp->{duplex} } }    # printing here after all
        my $f = $mt->{kind} eq 'image' ? "$UP/$mt->{src}" : "$UP/$id.pdf";
        my ($e) = $f =~ /(\.\w+)$/;
        my $label = strftime('%Y%m%d-%H%M%S', localtime) . '-' . int(rand(99999)) . "-from$mt->{from}-c$s{copies}$e";
        my $job = "$UP/job-$label"; rename $f, $job;
        unlink glob("$UP/$id.*");
        my $jid = rnd_hex(8); my $here = station_of(%cf); my ($jobs) = cups_queue($cf{printer});
        job_set($jid, state => $tgt ? 'sending' : 'queued', station => $tgt ? $tgt->{station} : $here, sid => $tgt ? $tgt->{id} : node_id(),
                sheets => $s{sheets}, ahead => $tgt ? ($tgt->{s}{jobs} || 0) : $jobs);
        jreply($c, 200, { ok => B(1), jid => $jid, station => $tgt ? $tgt->{station} : $here, here => B(!$tgt), waiting => N($jobs + 1) });
        close $c;
        hold($jid, $job, \%s, $label);
        if ($tgt) { forward_job($tgt, $job, \%s, $label, $jid, $want ne 'auto') } else { do_print($job, \%s, $label, $jid) }
        return;
    }
    jreply($c, 404, { error => 'Not found' });
}

# ---------------------------------------------------------------- main
$SIG{PIPE} = 'IGNORE';
our $MAIN_PID = $$;
mkdir $DIR; mkdir $UP; mkdir $SYNC, 0700; mkdir $STD; mkdir $JOBS; mkdir $SCANS; mkdir $HELD; chmod 0700, $SYNC;
if ($HAS_SHA) { node_id(); identity() }    # made here, once, before any worker: two processes making it at once would disagree
my $srv = IO::Socket::INET->new(LocalPort => $PORT, Listen => 64, ReuseAddr => 1, Proto => 'tcp') or die "cannot listen on port $PORT: $!\n";
my $MDNS = announce(); $SIG{TERM} = $SIG{INT} = sub { exit 0 }; END { kill 'TERM', $MDNS if $MDNS && $$ == $MAIN_PID }
print STDERR "School Printer listening on :$PORT (data: $DIR, LibreOffice: " . ($SOFFICE || 'none') . ")\n";
my $WORKER = 0;
my $srv80;
sub start_worker { my $pid = fork; if (defined $pid && !$pid) { close $srv; close $srv80 if $srv80; $SIG{TERM} = $SIG{INT} = 'DEFAULT'; worker(); exit 0 } $WORKER = $pid || 0 }
$SIG{CHLD} = sub { while ((my $k = waitpid(-1, WNOHANG)) > 0) { $WORKER = 0 if $k == $WORKER } };
start_worker(); END { kill 'TERM', $WORKER if $WORKER && $$ == $MAIN_PID }
$srv80 = $ENV{SP_PORT} ? undef : IO::Socket::INET->new(LocalPort => 80, Listen => 64, ReuseAddr => 1, Proto => 'tcp');    # "http://<school address>"
my $LISTEN = IO::Select->new($srv, $srv80 ? $srv80 : ());
my $DNS = 0;
sub start_dns { my $pid = fork; if (defined $pid && !$pid) { close $srv; close $srv80 if $srv80; $SIG{TERM} = $SIG{INT} = 'DEFAULT'; dns_server(); exit 0 } $DNS = $pid || 0 }
$SIG{CHLD} = sub { while ((my $k = waitpid(-1, WNOHANG)) > 0) { $WORKER = 0 if $k == $WORKER; $DNS = 0 if $k == $DNS } };
END { kill 'TERM', $DNS if $DNS && $$ == $MAIN_PID }
while (1) {
    start_worker() unless $WORKER;
    start_dns() unless $DNS || !$HAS_SHA;
    my ($ready) = $LISTEN->can_read(10) or next;
    my $c = $ready->accept or next;
    my $pid = fork;
    if (!defined $pid) { close $c; next }
    if (!$pid) { $SIG{CHLD} = 'DEFAULT'; close $srv; close $srv80 if $srv80; eval { handle($c) }; close $c; exit 0 }
    close $c;
}
