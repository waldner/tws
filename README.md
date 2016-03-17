# tws

## Simple and quick one-off file sharing over HTTP

*Note that a recent version of Perl is required (definitely works with 5.18)*

This is (hopefully) an evolution (perhaps suffering from [creeping featurism](http://catb.org/jargon/html/C/creeping-featurism.html)) of the excellent [wwwshare](http://pgas.freeshell.org/shell/wwwshare) (thanks pgas), which itself is based on [Vidar's one](http://www.vidarholen.net/contents/blog/?p=17) (which gets the credit for the original idea). This is a simple throwaway web server (tws) - or better said, something that pretends to be one to a client -, which can be useful when we need to quickly transfer some file or data to a friend or remote party. The program prints a list of URLs, and the remote end can then download the file by pointing a normal HTTP client (browser, curl, whatever) to one of these URLs. As the original author says, "when the file is downloaded, it exits. No setup or cleanup required".

The new features are:

* Written in Perl
* MIME support (to help the client know the file type)
* Progress bar!
* Streaming mode, using chunked transfer encoding (introduced by HTTP 1.1)

### Usage

Run the program with -h to see a summary:

$ tws.pl -h

```
Usage:
tws.pl [ -a ] [ -u ] [ -n ] [ -b bufsize ] [ -p port ] [ -m mimetype ] [ -U url ] [ -f filename ] name

-a          : consider all addresses for URLs (including loopback and link-local addresses)
-u          : flush output buffer as soon as it's written
-n          : do not resolve IPs to names
-b bufsize  : read/write up to bufsize bytes for cycle (default: 16384)
-p port     : listen on this port (default: random)
-m mimetype : force MIME type (default: autodetect if possible, otherwise application/octet-stream)
-U url      : include this URL among the listed alternative URLs
-f filename : use 'filename' to build the request part of the URL (default: dynamically computed)

'name' (mandatory argument) must exist in normal mode; in streaming mode it's only used to build the URL

Examples:
$ tws.pl -p 1025 /path/to/file.zip
Listen for connections on port 1025; send file.zip upon client connection. The specified path must exist.

$ tws.pl -p 4444 -U 'publicname.example.com:5555' -f archive.zip '/path/to/funny file.zip'
Listen on port 4444, suggest http://publicname.example.com:5555/archive.zip as download URL (presumably a port forwarding exists)

$ tar -cjf - file1 file2 file3 | tws.pl -m application/x-bzip2 result.tbz2
Listen on random port; upon connection, send the data coming from the pipe with the specified MIME type.
result.tbz2 need not exist; it's only used to build the URL
```

In the simplest case, one just does

```
$ tws.pl /path/to/some/file.iso
Listening on port 8052, MIME type is application/x-iso9660-image

Possible URLs that should work to retrieve the file:

http://scooter.example.com:8052/file.iso
http://10.4.133.1:8052/file.iso
http://[2001:db8:1::2]:8052/file.iso
```

Hopefully at least one of the printed URLs is valid and can be communicated to the other party, which then connects to download the file:

```
Client connected: 10.112.1.18 (colleague.example.com) from port 51066
 100% [=======================================================>]   3,224,686,592 (29s) 104.8M/s
```

The listening port is random; it is possible to force a specific value if needed (see the help). The part after the / in the URL is determined based on the supplied filename, to give some hint to the client or browser that downloads the file. Here too it is possible to force a specific string.

If the program detects that its standard input is connected to a pipe, it automatically operates in streaming mode, which is a fancy name to mean that it reads from standard input rather than a given file. A filename should still be specified, though, so the download URL can be "correctly" built (to be more helpful to the client). Streaming mode means that one can do something like this, for instance:

```
$ tar -cjf - file1 file2 file3 | tws.pl -m application/x-bzip2 result.tbz2
Listening on port 8787 (streaming mode), MIME type is application/x-bzip2

Possible URLs that should work to retrieve the file:

http://scooter.example.com:8787/result.tbz2
http://10.4.133.1:8787/result.tbz2
http://[2001:db8:1::2]:8787/result.tbz2
```

In streaming mode, the content length is of course not known, so the program sends the data using chunked transfer encoding; since this is an HTTP 1.1 feature, HTTP 1.0-only clients will not understand it (notably [wget versions prior to 1.13](http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=407526) have this limitation, so don't use it to download when in streaming mode). Another issue with streaming mode is that the MIME type is also not known; it's possible to give hints on the command line (see the above example and the help); in any case, the program defaults to application/octet-stream which should always work (though not extremely helpful to the client).

The program can also operate in unbuffered mode (-u), which means that data sent to the client is flushed as it is written, so the client receives it immediately. This feature, coupled with streaming mode, can be used as a rudimentary tool to send live streaming data to an HTTP client, for example like this:

```
$ tail -f /var/log/messages | tws.pl -u -m text/plain log.txt
```

or actual output from a pipeline, eg

```
$ bigprocessing.sh hugefile.csv | tee results.txt | tws.pl -u -m text/plain results.txt
```

Connecting with a browser or another HTTP client should show the data in (near) real time. This doesn't seem terribly useful, but perhaps someone can come up with a valid use case. Keep in mind that for this to work you need to make sure that whatever program is writing to the pipe is not buffering the output (many programs do buffering if they detect that stdout is not a terminal). Tools like [stdbuf](https://www.gnu.org/software/coreutils/manual/html_node/stdbuf-invocation.html) or [unbuffer](http://expect.sourceforge.net/example/unbuffer.man.html) help in this case. On the client side, curl has a *--no-buffer/-N* option that tells it to show data as it arrives without buffering. Also, it seems some browsers do a bit of initial buffering of the data they receive, after which they start showing new data in realtime (more info welcome).

### Notes

If the address or name in the URL that the other party should use to download is not local, the program cannot know it. In principle, it could be done (somewhat unreliably) by querying some external IP address check service like dyndns and friends, but in practice it's easier to leave this to the user, who surely knows better. Thus, it's possible to supply an URL that the user knows is leading to the local machine (see help for an example). And of course, this is only so it can be copied/pasted; it doesn't really change what the program does.

The way the program works is: once a connection is received, it reads the client's HTTP request and discards it (the only check that is performed is that it is a GET method, but even that could probably be avoided); after that, a minimal set of HTTP reply headers are sent, followed by the actual data. This means the code is simple, but it also means that picky clients that only accept certain encodings, expect specific headers or other special features will probably not work. If more sophisticated behavior is desired, use a real web server (of which there are many).

The code makes a number of assumptions and uses some tools that practically make it very Linux-specific; it has not been tested under other platforms. Also it relies on some external programs to get some information (local IPs, terminal size, MIME types etc); none of these external programs is critical, so the absence of some or all of them will not cause failure.

URL encoding is done using the URI::Escape module, if available; otherwise, no URL encoding is performed at all. With "normal" filenames this is not a problem, however in cases where weird URLs would result, it is possible to explicitly supply a name (see help).

To handle IPv4 and IPv6 clients with a single IPv6 socket, IPv4-mapped addresses are used. The program disables the socket option IPV6_V6ONLY, so both IPv4 and IPv6 clients can be accepted regardless of the setting in `/proc/sys/net/ipv6/bindv6only`. However, people should be using IPv6 already!

If the terminal is resized while the program is sending data, the progress bar will NOT be resized accordingly. However, since the terminal width is not checked until after a client has connected, it is possible to resize the terminal while the program is still waiting for a client to connect.

And btw, only one client is handled. As said, for anything more complex use a real webserver.
