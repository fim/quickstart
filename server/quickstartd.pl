#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Std;
use Proc::Daemon;
use HTTP::Daemon;
use HTTP::Status;
use Cwd 'abs_path';
use sigtrap 'handler', \&exit_handler, "INT", "TERM", "QUIT", "ABRT";

my $LOG = "/var/log/quickstart.log";
my $PID = "/var/run/quickstart.pid";

my %conf = (
	port => 8899,
	bind_address => "0.0.0.0",
	debug => 1,
	profile_dir => "/var/lib/quickstart"
);

sub usage {
	print STDERR << "EOF";
Usage: $0 [-hvdf] [-D dir]
-h        : this (help) message
-v        : verbose output
-f        : file containing usersnames, one per line
-o file   : log file (applicable only when running as daemon)
-D dir    : directory with quickstart profiles 
EOF

	exit(1);
}

sub now {
	my $now = localtime time;
	return $now;
}

sub exit_handler { 
	my $sgn = shift;
	qlog("Received $sgn signal. Exiting...");
	if ( -e $PID) { unlink($PID) or qerror("Could not delete pid file: $PID"); }
	exit(0);
}

sub qerror {
	my $msg = shift; 
	print STDERR "[".now()."] ERROR: " . $msg . "\n";
}

sub qlog {
	my $msg = shift;
	print "[".now()."] LOG: " . $msg . "\n"; 
}

sub qdebug {
	my $msg = shift;
	if($conf{debug}) {
		print "[".now()."] DEBUG: " . $msg . "\n";
	}
}

sub create_daemon {
	return HTTP::Daemon->new(
		LocalAddr => $conf{bind_address},
		LocalPort => $conf{port},
		Reuse => 1
	);
}

sub parse_request_url {
	my $url = shift;

	$url =~ /^([^?]+)(?:\?(.*))?$/;
	my $path = $1;
	my $args = {};
	if(defined $2) {
		foreach my $pair (split /&/, $2) {
			my @parts = split /=/, $pair;
			$parts[1] =~ s/\+/ /g;
			$args->{$parts[0]} = $parts[1];
		}
	}
	return ($path, $args);
}

sub send_response {
	my ($conn, $response) = @_;

	qdebug("Sending response: " . $response);
	$conn->send_basic_header(200);
	$conn->send_crlf;
	print $conn $response;
}

sub get_profile_path {
	my $mac = shift;

	my $profile_path;

	if ( -e "$conf{profile_dir}/$mac" ) {
		$profile_path = "$conf{profile_dir}/$mac";
	} else { 
		$profile_path = "$conf{profile_dir}/default";
	}

	return $profile_path;
}

sub handle_request {
	my $conn = shift;
	my ($path, $args);

	my $request = $conn->get_request;
	if ( defined $request ) { 
		($path, $args) = parse_request_url($request->url);
	} else {
		qdebug("Got invalid request from " . $conn->peerhost() . ":" . $conn->peerport());
		return;
	}

	my $debugargs = "";
	foreach(keys %{$args}) {
		$debugargs .= ($debugargs ? ", " : "") . $_ . "->" . $args->{$_};
	}
	qdebug("path=" . $path . ", args=" . $debugargs);

	if($request->method ne "GET") {
		$conn->send_qerror(RC_FORBIDDEN);
		return;
	}

	if($path eq "/get_profile_path") {
		my $profile_path = get_profile_path($args->{mac});
		if($profile_path =~ /^\//) {
			$profile_path = "quickstart:///get_profile?mac=" . $args->{mac};
		}
		send_response($conn, $profile_path);
	} elsif($path eq "/get_profile") {
		$conn->send_file_response(get_profile_path($args->{mac}));
	} else {
		qdebug("Sending 404");
		$conn->send_basic_header(404);
		$conn->send_crlf;
		print $conn "Unknown command";
	}
}

sub main {
	my %opt;
	my $opt_string = 'hvfD:o:';
	getopts( "$opt_string", \%opt ) or usage();
	usage() if $opt{h};


	$conf{debug} = 0 unless $opt{v};
	$LOG = abs_path($opt{o}) if defined $opt{o};

	if ( -e $PID ) {
		qerror("It seems like an instance of quickstartd is already
	running.  Make sure no other instance is running and
	then delete file $PID.");
		exit(1);
	}


	# Daemonize
	unless ( defined $opt{f} ) {
		open(my $flog, ">>$LOG") or die "Cannot open file $LOG: $!\n";	
		Proc::Daemon::Init;
		open(STDOUT, ">>$LOG"); 
		open(STDERR, ">&STDOUT");
		
	}
	
	# Start http daemon
	my $daemon = create_daemon();
	if(!defined $daemon) {
		qerror("Could not create daemon.");
		exit(1);
	}
	
	$conf{profile_dir} = abs_path($opt{D}) if defined $opt{D};

	unless( -d $conf{profile_dir} ) {
		qerror("Profile directory doesn't exist [" . $conf{profile_dir} . "]");
		exit(1);
	}

	unless ( defined $opt{f} ) {
		open(FPID,">$PID") or die "Cannot open file $PID: $!\n";
		print FPID $$;
		close FPID;
	}
	
	qlog("Starting quickstart server. Listening port is ". $conf{port});
	qlog("Profile directory located at $conf{profile_dir}");

	# Wait for connection
	while(my $conn = $daemon->accept) {
		qdebug("Accepted connection from " . $conn->peerhost() . ":" . $conn->peerport());
		handle_request($conn);
		$conn->close;
		qdebug("Connection closed");
	}
}

$SIG{'HUP'} = 'IGNORE';

main();

# Autoflush buffers
BEGIN { $| = 1 }
