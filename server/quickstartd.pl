#!/usr/bin/perl

use strict;
use warnings;

use HTTP::Daemon;
use HTTP::Status;
use Cwd 'abs_path';

my %conf = (
	port => 8899,
	bind_address => "0.0.0.0",
	debug => 1,
	profile_dir => "/var/lib/quickstart"
);

sub usage {
	print STDERR "Usage: quickstart.pl <profile_dir>\n";
	exit( 1 );
}

sub error {
	my $msg = shift; 
	print STDERR "ERROR: " . $msg . "\n";
}

sub debug {
	my $msg = shift;
	if($conf{debug}) {
		print "DEBUG: " . $msg . "\n";
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

	debug("Sending response: " . $response);
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

	my $request = $conn->get_request;
	my ($path, $args) = parse_request_url($request->url);

	my $debugargs = "";
	foreach(keys %{$args}) {
		$debugargs .= ($debugargs ? ", " : "") . $_ . "->" . $args->{$_};
	}
	debug("path=" . $path . ", args=" . $debugargs);

	if($request->method ne "GET") {
		$conn->send_error(RC_FORBIDDEN);
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
		debug("Sending 404");
		$conn->send_basic_header(404);
		$conn->send_crlf;
		print $conn "Unknown command";
	}
}

sub main {
	
	my $daemon = create_daemon();
	if(!defined $daemon) {
		error("Could not create daemon.");
		exit(1);
	}
	
	if ($#ARGV > 0) {
		usage();
	}

	$conf{profile_dir} = abs_path($ARGV[0]) if defined $ARGV[0];

	unless( -d $conf{profile_dir} ) {
		error("Profile directory doesn't exist [" . $conf{profile_dir} . "]");
		exit(1);
	}
		
	debug('Profile directory specified is: '. $conf{profile_dir});

	# Wait for connection
	while(my $conn = $daemon->accept) {
		debug("Accepted connection from " . $conn->peerhost() . ":" . $conn->peerport());
		handle_request($conn);
		$conn->close;
		debug("Connection closed");
	}
}

main();
