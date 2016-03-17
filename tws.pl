#!/usr/bin/perl

# tws.pl: simple throwaway web server for quick data transfers.
# Based on previous ideas and work by Vidar Holen
# Vidar Holen (http://www.vidarholen.net/contents/blog/?p=17)
# and pgas (http://pgas.freeshell.org/shell/wwwshare).

# Copyright Davide Brini, 07/09/2013
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.

use warnings;
use strict;

use Time::HiRes qw ( gettimeofday );
use Getopt::Std;
use Socket qw ( :DEFAULT IN6ADDR_ANY IPPROTO_IPV6 IPV6_V6ONLY inet_pton inet_ntop );
use File::Basename;
use IO::Handle;

# how often we (try to) redraw the progress bar
my $PBREFRESH = 0.3;

# how much to (try to) read/write at once. This value seems
# to work well to saturate a gigabit link. Larger values give
# slightly worse performance. YMMV.
my $BUFSIZE = 16384;

# default content-type
my $DEFMIME = 'application/octet-stream';

sub helpanddie {

  my ($msg) = @_;

  my $progname = basename($0);

  local *STDOUT = *STDERR;

  print "$msg\n\n" if ($msg);

  print "Usage:\n";
  print "$progname [ -a ] [ -u ] [ -n ] [ -b bufsize ] [ -p port ] [ -m mimetype ] [ -U url ] [ -f filename ] [ -v ] name\n";
  print "\n";
  print "-a          : consider all addresses for URLs (including loopback and link-local addresses)\n";
  print "-u          : flush output buffer as soon as it's written\n";
  print "-n          : do not resolve IPs to names\n";
  print "-b bufsize  : read/write up to bufsize bytes for cycle (default: $BUFSIZE)\n";
  print "-p port     : listen on this port (default: random)\n";
  print "-m mimetype : force MIME type (default: autodetect if possible, otherwise $DEFMIME)\n";
  print "-U url      : include this URL among the listed alternative URLs\n";
  print "-f filename : use 'filename' to build the request part of the URL (default: dynamically computed)\n";
  print "-v          : print client request headers\n";
  print "\n";
  print "'name' (mandatory argument) must exist in normal mode; in streaming mode it's only used to build the URL\n";
  print "\n";

  if (not $msg) {

    print "Examples:\n";
    print "\$ $progname -p 1025 /path/to/file.zip\n";
    print "Listen for connections on port 1025; send file.zip upon client connection. The specified path must exist.\n";
    print "\n";
    print "\$ $progname -p 4444 -U 'publicname.example.com:5555' -f archive.zip '/path/to/funny file.zip'\n";
    print "Listen on port 4444, suggest http://publicname.example.com:5555/archive.zip as download URL (presumably a port forwarding exists)\n";
    print "\n";
    print "\$ tar -cjf - file1 file2 file3 | $progname -m application/x-bzip2 result.tbz2\n";
    print "Listen on random port; upon connection, send the data coming from the pipe with the specified MIME type.\n";
    print "result.tbz2 need not exist; it's only used to build the URL\n";
  } else {
    print "Use -h for full help\n";
  }

  exit 1;
}

sub isinpath {
  my ($command) = @_;
  for my $path (split /:/, $ENV{PATH}) {
    my $lookfor = "$path/$command";
    return "$lookfor" if (-x "$lookfor");
  }
  return;
}


sub getaddresses {

  my ($alladdresses, $resolveip) = @_;

  my %ip4addrs = ();
  my %ip6addrs = ();
  my %names = ();

  my $ip = isinpath('ip') or return ();
  open (IPA, '-|', "$ip address show") or return ();

  my ($curif, $curstate);

  while (<IPA>){

    if (/^\d+: ([^:]+):/) {
      $curif = $1;
      $curstate = /[<,]UP[,>]/ ? 1 : 0;
      next;
    }

    $curstate == 0 and next;

    my ($type, $addr) = /^\s+(inet6?) (\S+)/ or next;
    $addr =~ s|/\d+||;

    my $sname;
    if ($type eq 'inet6') {

      if ($alladdresses == 1 or $addr !~ m/^(?:^::1$|^fe80)/) {
        if ($resolveip == 1) { $sname = gethostbyaddr(inet_pton(AF_INET6, $addr), AF_INET6); }
        $addr = "[$addr]";
        $ip6addrs{$addr} = 1;
      }

    } else {

      if ($alladdresses == 1 or $addr !~ m/^127\./) {
        if ($resolveip == 1) { $sname = gethostbyaddr(inet_pton(AF_INET, $addr), AF_INET); }
        $ip4addrs{$addr} = 1;
      }
    }

    if ($sname) {
      $names{$sname} = 1;
    }

  }
  close(IPA);

  return (keys %names, keys %ip4addrs, keys %ip6addrs);
}

# this is all highly Linux-specific. If anything fails,
# bail out and return 80.
sub getwidth {
  my $cols;
  my $defaultcols = 80;

  my $term = readlink('/dev/fd/1') or return $defaultcols;

  my $stty = isinpath('stty');
  open(STTY, '-|', "$stty size -F $term") or return $defaultcols;
  $cols = <STTY>;
  close(STTY);
  $cols =~ s/\d+ //;
  return $cols;
}

# find the order of magnitude of the given number
# of bytes and express it in that unit (roughly)
sub humanbytes {

  my ($bytes) = @_;

  my @units = ( { 'v' =>          1, 'm' => 'B' },
                { 'v' =>       1024, 'm' => 'K' },
                { 'v' =>    1048576, 'm' => 'M' },
                { 'v' => 1073741824, 'm' => 'G' } );

  my ($result, $divisor, $sym);

  # check the order of magnitude
  for (reverse @units) {
    if ($bytes >= ${$_}{v} or ${$_}{m} eq 'B') {
      ($divisor, $sym) = (${$_}{v}, ${$_}{m});
      last;
    }
  }

  $result = sprintf("%.1f", $bytes / $divisor);
  $result =~ s/\.0+$//;

  $result = int($result) if $divisor == 1;

  return ($result . $sym);
}


# given a number of seconds, converts it in d/h/m/s
sub humantime {

  my ($seconds) = @_;

  my @dhms = ( { 'v' => int($seconds / 86400),  'm' => 'd' },
               { 'v' => ($seconds / 3600) % 24, 'm' => 'h' },
               { 'v' => ($seconds / 60) % 60,   'm' => 'm' },
               { 'v' => $seconds % 60,          'm' => 's' } );

  if ($dhms[0]{v} >= 100) {
    return $dhms[0]{v} . "d+";
  }

  return join(" ", map { sprintf("%.2s%s", ${$_}{v}, ${$_}{m}) } grep { ${$_}{v} > 0 or ${$_}{m} eq 's' } @dhms);
}

sub progressbar {

  my ($streaming, $sentbytes, $intervals, $totbytes, $barlen, $termwidth, $time, $speed) = @_;

  my $mainbar;

  if ($streaming == 0) {

    # non-streaming mode, include percentage 

    my ($perc, $barl) = (0, 1);

    if ($totbytes > 0) {
      $perc = int(($sentbytes * 100) / $totbytes);
      $barl = int(($sentbytes * $barlen) / $totbytes);
      $barl = 1 if ($barl == 0);
    }

    my $bar = ('=' x ($barl - 1)) . ">" . (' ' x ($barlen - $barl));

    $mainbar = sprintf(" %3d%% [%s]", $perc, $bar);

  } else {

    my $s = ($intervals % (($barlen - 2) * 2)) + 1;             # this is between 1 and (barlen - 2) * 2, inclusive
    my ($prespaces, $postspaces) = ($s <= $barlen - 2) ? ($s - 1, $barlen - $s - 2) : ($barlen * 2 - $s - 4, $s - $barlen + 1);

    my $bar = (' ' x $prespaces) . '<=>' . (' ' x $postspaces);
    $mainbar = sprintf("  --  [%s]", $bar);
  }

  # complete the bar with more data
  $mainbar .= sprintf(" %15s (%s) %s", commify($sentbytes), humantime($time), humanbytes($speed) . "/s");

  # pad with blanks
  $mainbar .= (' ' x ($termwidth - length($mainbar)));

  printf "%s\r", $mainbar;

}

# taken directly from the perl FAQ
sub commify {
  local $_ = shift;
  1 while s/^([-+]?\d+)(\d{3})/$1,$2/;
  return $_;
}

sub getmime {

  my ($filename) = @_;

  my $file = isinpath('file') or return;

  # escape single quotes in filename (if any)
  $filename =~ s/'/'\\''/g;

  open(MIME, '-|', "$file --mime-type '$filename'") or return;
  my $mime = <MIME>;
  close(MIME);

  chomp($mime);
  if ($mime =~ m|.*: ([^/]+/[^/]+)$|) {
    return $1;
  }

  return;
}

########## BEGIN

# Handle the remote party shutting down in our face
$SIG{'PIPE'} = sub { print STDERR "Broken pipe, terminating\n"; exit 1; };


# set stdout autoflush (for progress bar)
$| = 1;

# determine whether we're running in streaming mode
my $streaming = (-p STDIN) ? 1 : 0;

# parse options
my %opts;
getopts('auvnb:p:m:U:f:h', \%opts);

if (exists($opts{h})) {
  helpanddie();
  exit 1;
}

# there must be exactly one argument left
helpanddie("Must specify a filename") if not $ARGV[0];
helpanddie("Unexpected extra arguments: " . join(" ", @ARGV[1..$#ARGV])) if ($ARGV[1]);

my $filename = $ARGV[0];
my $totbytes = -1;
my ($fileurl, $userurl);

my $unbuffered = 0;
if (exists($opts{u})) {
  $unbuffered = 1;
}

my $alladdresses = 0;
my $resolveip = 1;

if (exists($opts{n})) {
  $resolveip = 0;
}

my $bufsize = $BUFSIZE;
if (exists($opts{b})) {
  $bufsize = $opts{b};
  helpanddie("Invalid buffer size: $bufsize") if not $bufsize =~ /^\d+$/;
}

my $verbose = 0;
if (exists($opts{v})) {
  $verbose = 1;
}

my $inh;
my $mime = $DEFMIME;

# if in regular mode, check that file exists, get size and MIME
if ($streaming == 0) {

  if (! -r $filename or -d $filename) {
    helpanddie("Invalid file specified: $filename");
  }

  $totbytes = -s $filename;
  open($inh, "<", $filename) or helpanddie("Cannot open $filename: $!");

  if (my $trymime = getmime($filename)) {
    $mime = $trymime;
  }
} else {
  $inh = *STDIN;
}

# if a MIME type was specified on command line,
# override whatever we have so far
if (exists($opts{m})) {
  $mime = $opts{m};
}

# if the user specified a URL, save it
if (exists($opts{U})) {
  $userurl = $opts{U};
}

# If not overridden, build the filename part of the URL based on the
# supplied string (it's dummy anyway, but it can help the browser or
# client)

if (exists($opts{f})) {
  $fileurl = $opts{f};
} else {
  $fileurl = basename($filename);
  eval('require URI::Escape');
  if ($@) {
    print STDERR "Warning, cannot find URI::Escape, skipping URL encoding of the filename\n";
  } else {
    $fileurl = URI::Escape::uri_escape($fileurl);
  }
}

if (exists($opts{a})) {
  $alladdresses = 1;
}

my $port;
if (exists($opts{p})) {
  $port = $opts{p};
  if ($port !~ /^\d+$/ or $port < 1 or $port > 65535) {
    helpanddie("Invalid port specified: $port");
  }
} else {
  # generate random port number
  my $fromport = 8000;
  my $toport = 9000;
  $port = $fromport + int(rand($toport - $fromport));
}


my $proto = getprotobyname("tcp");
socket(SERVER, AF_INET6, SOCK_STREAM, $proto) or helpanddie("socket: $!");
setsockopt(SERVER, SOL_SOCKET, SO_REUSEADDR, 1) or helpanddie("setsockopt: $!");

# allow v4 clients as well
setsockopt(SERVER, IPPROTO_IPV6, IPV6_V6ONLY, 0) or helpanddie("setsockopt: $!");

bind(SERVER, sockaddr_in6($port, IN6ADDR_ANY)) or helpanddie("bind: $!");
listen(SERVER, 1) or helpanddie("listen: $!");

print "Listening on port $port" . ($streaming == 1 ? " (streaming mode)":"") . ", MIME type is $mime\n\n";

print "Possible URLs that should work to retrieve the file:\n\n";

if ($userurl) {
  print "*** http://$userurl/$fileurl\n";
}

my @addrs = getaddresses($alladdresses, $resolveip);

if (@addrs) {
  for (@addrs) {
    print "http://$_:$port/$fileurl\n";
  }
} else {
  print "Cannot determine more URLs.\n";
  print "Use an URL like http://some.address.or.name:$port/$fileurl,\n";
  print "where 'some.address.or.name' is an address or a name that eventually gets traffic to a local IP address\n";
}

print "\n";

my $client = accept(CLIENT, SERVER);

my($clport, $claddr) = sockaddr_in6($client);
my $clname = (gethostbyaddr($claddr, AF_INET6) or "unknown");
my $clpaddr = inet_ntop(AF_INET6, $claddr);

# if ipv4-mapped, remove the extra stuff
$clpaddr =~ s/^::ffff:(\d+\.\d+\.\d+\.\d+)$/$1/;

print "Client connected: $clpaddr ($clname) from port $clport\n";

# get terminal width to later show progress bar
my $termwidth = getwidth();
my $barlen = $termwidth - 50;

# if unbuffered mode, turn on autoflush so client should see updates immediately
if ($unbuffered == 1) {
  CLIENT->autoflush(1);
}

my $req = <CLIENT>;

# just check that it's an HTTP GET. Minimal check, we could even skip this.
if (not ($req =~ m|^GET |)) {
  print STDERR "Invalid request received, terminating\n";
  exit 1;
}

print "\n$req" if $verbose;

# read the rest of the request and throw it away. Yes this is bad, but
# we won't handle anything anyway.
while ((my $reqline = <CLIENT>) ne "\r\n") {
  print $reqline if ($verbose);
}

print "\n" if $verbose;

# Send headers

printf CLIENT "HTTP/1.1 200 Ok\r\n";
printf CLIENT "Content-Type: %s\r\n", $mime;
printf CLIENT "Server: tws (not a real server)\r\n";

if ($streaming == 0) {
  printf CLIENT "Content-Length: %d\r\n", $totbytes;
} else {
  printf CLIENT "Transfer-Encoding: chunked\r\n";
}

printf CLIENT "\r\n";


my ($chunklen, $chunk);

my $post = ($streaming == 1 ? "\r\n" : '');
my $pre;

my $starttime = gettimeofday();
my $lastpbtime = $starttime;
my $curtime = $starttime;

my ($elapsedtot, $elapsedpb, $speed, $intervals, $sentbytes) = (0, 0, 0, 0, 0);

# ETA or elapsed time
my $time;

my $result;

progressbar($streaming, $sentbytes, $intervals, $totbytes, $barlen, $termwidth, 0, 0);

# main loop
while (1) {

  # This potentially uses select() on a normal disk file descriptor.
  # I haven't read that it should not be done; seems to work ok.

  my $rin = ''; vec($rin, fileno($inh), 1) = 1;
  $result = select($rin, undef, undef, $PBREFRESH);

  if ($result > 0) {
    $chunklen = sysread($inh, $chunk, $bufsize);
    if ($chunklen == 0) {
      last;
    } elsif ($chunklen < 0) {
      die "Error reading input: $!";
    }
  } elsif ($result == 0) {
    # timeout
    $chunklen = 0;
  } else {
    die "Error during select: $!";
  }

  if ($chunklen > 0) {
    # write it to client
    $pre = ($streaming == 1 ? sprintf("%x\r\n", $chunklen) : '');
    printf CLIENT "%s%s%s", $pre, $chunk, $post or die "Error writing to client: $!";

    # update total bytes sent
    $sentbytes += $chunklen;
  }

  $curtime = gettimeofday();

  # time passed overall
  $elapsedtot = $curtime - $starttime;

  # speed from the beginning (bytes/sec)
  $speed = $sentbytes / $elapsedtot;

  # see whether we need to redraw the progress bar
  $elapsedpb = $curtime - $lastpbtime;

  if ($elapsedpb > $PBREFRESH) {

    # this is ETA in normal mode, otherwise elapsed time
    $time = ($streaming == 0 ? (($totbytes * $elapsedtot / $sentbytes) - $elapsedtot) : $elapsedtot );

    progressbar($streaming, $sentbytes, ++$intervals, $totbytes, $barlen, $termwidth, $time, $speed);
   
    $lastpbtime = $curtime;
  }

}

if ($streaming == 1) {
  printf CLIENT "0\r\n\r\n";
}

# final progressbar, always print elapsed time
progressbar($streaming, $sentbytes, $intervals, $totbytes, $barlen, $termwidth, $elapsedtot, $speed);

printf "\n";

close(CLIENT);
close(SERVER);
close($inh) if ($streaming == 0);

exit;

