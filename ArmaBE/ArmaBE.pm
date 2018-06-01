# ArmaBE - Perl extension BattlEye ARMA Rcon interface
# Original Source for BattlEye source - https://github.com/Jaegerhaus/BE-RCon-Tools
#
# $Id:$
#

package ArmaBE;

use strict;
use warnings;
use IO::Socket::INET;

# release version
our $VERSION = "0.01";

# create class
sub new {
	my $class = shift;

	# create object with defaults
	my $self = {
		hostname	=> undef,
		port		=> 27015,
		password	=> undef,
		timeout		=> 5,
		connected	=> 0,
		authenticated	=> 0,
		socket		=> undef,
		sequence	=> 0,
	};

	# create object
	bless($self, $class);

	# initialize class instances
	$self->init();

	# parse constructor args
	while (my ($key, $val) = splice(@_, 0, 2)) {
		$key = lc($key);
		if    ($key eq "hostname") { $self->hostname($val) }
		elsif ($key eq "port")     { $self->port($val)     }
		elsif ($key eq "password") { $self->password($val) }
		elsif ($key eq "timeout")  { $self->timeout($val)  }
		else { print STDERR "Unknown attribute: $key\n" }
	}

	return $self;
}

# initialize class instances
sub init {
	my $self = shift;
	my $class = ref($self);

	# manipulate symbol table.. gotta love perl
	no strict "refs";
	no warnings;
	foreach my $instance (keys %$self) {
		*{"${class}::${instance}"} = sub {
			my $self = shift;
			my $value = shift;
			my $ref = \$self->{$instance};
			if (defined $value) {
				$$ref = $value;
				return $self;
			} else {
				return $$ref;
			}
		};
	}
}

# run a command and return its response
sub run {
	my $self = shift;
	my $command = shift;

	if (!$self->connected()) {
		$self->connect();
	}

	if (!$self->authenticated()) {
		$self->authenticate();
	}

	if ($self->authenticated()) {
		my $socket = $self->socket();
		print $socket $self->packet("\1\0".$command);
		return 1;
	} else {
		return 0;
	}
}

# create tcp socket
sub connect {
	my $self = shift;

	my $socket = IO::Socket::INET->new(
		PeerAddr        => $self->hostname(),
		PeerPort        => $self->port(),
		Timeout		=> $self->timeout(),
		Proto           => "udp",
	) || die "Failed to connect: $!\n";

	$self->socket($socket);
	$self->connected(1);
}

# authenticate rcon session
sub authenticate {
	my $self = shift;

	# send authentication packet to server
	my $socket = $self->socket();
	print $socket $self->packet("\0".$self->password());

	my $response = $self->response();
	my $authenticated = int(substr($response, -1));

	$self->authenticated($authenticated);
}

######################
# PROTOCOL FUNCTIONS #
######################

# rcon command protocol:
# https://www.battleye.com/downloads/BERConProtocol.txt

sub crc32 {
	my ($self,$input,$init_value,$polynomial) = @_;

	$init_value = 0 unless (defined $init_value);
	$polynomial = 0xedb88320 unless (defined $polynomial);

	my @lookup_table;

	for (my $i=0; $i<256; $i++) {
		my $x = $i;
		for (my $j=0; $j<8; $j++) {
			if ($x & 1) {
				$x = ($x >> 1) ^ $polynomial;
			} else {
				$x = $x >> 1;
			}
		}
		push @lookup_table, $x;
	}

	my $crc = $init_value ^ 0xffffffff;

	foreach my $x (unpack ('C*', $input)) {
		$crc = (($crc >> 8) & 0xffffff) ^ $lookup_table[ ($crc ^ $x) & 0xff ];
	}

	$crc = $crc ^ 0xffffffff;

	return $crc;
}

# create a packet of type (AUTH or CMD)
sub packet {
	my $self = shift;
	my $payload = shift;

	my $break = pack('C', 0xff);
	my $packet = "BE"
		. pack('V', $self->crc32($break . $payload))
		. $break
		. $payload;

	return $packet;
}

# receive packet
sub response {
	my $self = shift;
	my $payload = $self->read();

	return $payload;
}

# read length of bytes from socket with timeout
sub read {
	my $self = shift;
	my $received;
	my $socket = $self->socket();
	
	$socket->recv($received, 9);

	return unpack('H*', $received);
}

1;

__END__
