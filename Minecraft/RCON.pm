# Minecraft::RCON - RCON remote console for Minecraft
#
# 1.x and above by Ryan Thompson <rjt@cpan.org>
#
# Original (0.1.x) by Fredrik Vold, no copyrights, no rights reserved.
# This is absolutely free software, and you can do with it as you please.
# If you do derive your own work from it, however, it'd be nice with some
# credits to me somewhere in the comments of that work.
#
# Based on http:://wiki.vg/RCON documentation

package Minecraft::RCON;

our $VERSION = '1.03';

use 5.010;
use strict;
use warnings;
no warnings 'uninitialized';

use Term::ANSIColor  3.01;
use IO::Socket       1.18;  # autoflush
use Carp;

use constant {
    # Packet types
    AUTH            =>  3,  # Minecraft RCON login packet type
    AUTH_RESPONSE   =>  2,  # Server auth response
    AUTH_FAIL       => -1,  # Auth failure (password invalid)
    COMMAND         =>  2,  # Command packet type
    RESPONSE_VALUE  =>  0,  # Server response
};

# Minecraft -> ANSI color map
my %COLOR = map { $_->[1] => color($_->[0]) } (
    [black        => '0'], [blue           => '1'], [green        => '2'],
    [cyan         => '3'], [red            => '4'], [magenta      => '5'],
    [yellow       => '6'], [white          => '7'], [bright_black => '8'],
    [bright_blue  => '9'], [bright_green   => 'a'], [bright_cyan  => 'b'],
    [bright_red   => 'c'], [bright_magenta => 'd'], [yellow       => 'e'],
    [bright_white => 'f'],
    [bold         => 'l'], [concealed      => 'm'], [underline    => 'n'],
    [reverse      => 'o'], [reset          => 'r'],
);

# Defaults for new objects. Override in constructor or with accessors.
sub _DEFAULTS(%) {
    (
        address       => '127.0.0.1',
        port          => 25575,
        password      => '',
        color_mode    => 'strip',
        request_id    => 0,

        # DEPRECATED options
        strip_color   => undef,
        convert_color => undef,

        @_, # Subclasses may override
    );
}

# DEPRECATED warning text for convenience/consistency
my $DEP = 'deprecated and will be removed in a future release.';

sub new {
    my $class = shift;
    my %opts = 'HASH' eq ref $_[0] ? %{$_[0]} : @_;
    my %DEFAULTS = _DEFAULTS();

    # DEPRECATED -- Warn and transition to new option
    if ($opts{convert_color}) {
        carp "convert_color $DEP\nConverted to color_mode => 'convert'.";
        $opts{color_mode} = 'convert';
    }
    if ($opts{strip_color}) {
        carp "strip_color $DEP\nConverted to color_mode => 'strip'.";
        $opts{color_mode} = 'strip';
    }

    my @unknowns = grep { not exists $DEFAULTS{$_} } sort keys %opts;
    carp "Ignoring unknown option(s): " . join(', ', @unknowns) if @unknowns;

    bless { %DEFAULTS, %opts }, $class;
}

sub connect {
    my ($s) = @_;

    return 1 if $s->connected;

    croak 'Password required' unless length $s->{password};

    $s->{socket} = IO::Socket::INET->new(
        PeerAddr => $s->{address},
        PeerPort => $s->{port},
        Proto    => 'tcp',
    ) or croak "Connection to $s->{address}:$s->{port} failed: .$!";

    my $id = $s->_next_id;
    $s->_send_encode(AUTH, $id, $s->{password});
    my ($size,$res_id,$type,$payload) = $s->_recv_decode;

    # Force a reconnect if we're about to error out
    $s->disconnect unless $type == AUTH_RESPONSE and $id == $res_id;

    croak 'RCON authentication failed'           if $res_id == AUTH_FAIL;
    croak "Expected AUTH_RESPONSE(2), got $type" if   $type != AUTH_RESPONSE;
    croak "Expected ID $id, got $res_id"         if     $id != $res_id;
    croak "Non-blank payload <$payload>"         if  length $payload;

    return 1;
}

sub connected { $_[0]->{socket} and $_[0]->{socket}->connected }

sub disconnect {
    $_[0]->{socket}->shutdown(2) if $_[0]->connected;
    delete $_[0]->{socket} if exists $_[0]->{socket};
    1;
}

sub command {
    my ($s, $command, $mode) = @_;

    croak 'Command required' unless length $command;
    croak 'Not connected'    unless $s->connected;

    my $id = $s->_next_id;
    my $nonce = 16 + int rand(2 ** 15 - 16); # Avoid 0..15
    $s->_send_encode(COMMAND, $id, $command);
    $s->_send_encode($nonce,  $id, 'nonce');

    my $res = '';
    while (1) {
        my ($size,$res_id,$type,$payload) = $s->_recv_decode;
        if ($id != $res_id) {
            $s->disconnect;
            croak sprintf(
                "Desync. Expected %d (0x%4x), got %d (0x%4x). Disconnected.",
                $id, $id, $res_id, $res_id
            );
        }
        croak "size:$size id:$id got type $type, not RESPONSE_VALUE(0)"
            if $type != RESPONSE_VALUE;
        last if $payload eq sprintf 'Unknown request %x', $nonce;
        $res .= $payload;
    }

    $s->color_convert($res, defined $mode ? $mode : $s->{color_mode});
}

sub color_mode {
    my ($s, $mode, $code) = @_;
    return $s->{color_mode} if not defined $mode;
    croak 'Invalid color mode.'
        unless $mode =~ /^(strip|convert|ignore)$/;

    if ($code) {
        my $was = $s->{color_mode};
        $s->{color_mode} = $mode;
        $code->();
        $s->{color_mode} = $was;
    } else {
        $s->{color_mode} = $mode;
    }
}

sub color_convert {
    my ($s, $text, $mode) = @_;
    $mode = $s->{color_mode} if not defined $mode;
    my $re = qr/\x{00A7}(.)/o;

    $text =~ s/$re//g           if $mode eq 'strip';
    $text =~ s/$re/$COLOR{$1}/g if $mode eq 'convert';
    $text .= $COLOR{r}          if $mode eq 'convert' and $text =~ /\e\[/;

    $text;
}

sub DESTROY { $_[0]->disconnect }

#
# DEPRECATED methods
#

sub convert_color {
    my ($s, $val) = @_;
    carp "convert_color() is $DEP\nUse color_mode('convert') instead";
    $s->color_mode('convert') if $val;

    $s->color_mode eq 'convert';
}

sub strip_color {
    my ($s, $val) = @_;
    carp "strip_color() is $DEP\nUse color_mode('strip') instead";
    $s->color_mode('strip') if $val;

    $s->color_mode eq 'strip';
}

sub address {
    carp "address() is $DEP";
    $_[0]->{address} = $_[1] if defined $_[1];
    $_[0]->{address};
}

sub port {
    carp "port() is $DEP";
    $_[0]->{port} = $_[1] if defined $_[1];
    $_[0]->{port};
}

sub password {
    carp "password() is $DEP";
    $_[0]->{password} = $_[1] if defined $_[1];
    $_[0]->{password};
}

#
# Private helpers
#

# Increment and return the next request ID, wrapping at 2**31-1
sub _next_id { $_[0]->{request_id} = ($_[0]->{request_id} + 1) % 2**31 }

# Form and send a packet of the specified type, request_id and payload
sub _send_encode {
    my ($s, $type, $id, $payload) = @_;
    confess "Request ID `$id' is not an integer" unless $id =~ /^\d+$/;
    $payload = "" unless defined $payload;
    my $data = pack('V!V' => $id, $type) . $payload . "\0\0";
    $s->{socket}->send(pack(V => length $data) . $data);

}

# Grab a single packet.
sub _recv_decode {
    my ($s) = @_;
    confess "_recv_decode when not connected" unless $s->connected;

    local $_; $s->{socket}->recv($_, 4);
    my $size = unpack 'V';
    $_ = '';
    my $frags = 0;

    croak "Zero length packet" unless $size;

    while ($size > length) {
        my $buf;
        $s->{socket}->recv($buf, $size);
        $_ .= $buf;
        $frags++;
    }

    croak 'Packet too short. ' . length($_) . ' < 10' if 10 > length($_);
    croak "Received packet missing terminator" unless s/\0\0$//;

    $size, unpack 'V!V(A*)';
}

1;

__END__

=head1 NAME

Minecraft::RCON - RCON remote console communication with Minecraft servers

=head1 VERSION

Version 1.03

=head1 SYNOPSIS

    use Minecraft::RCON;

    my $rcon = Minecraft::RCON->new( { password => 'secret' } );

    eval { $rcon->connect };
    die "Connection failed: $@" if $@;

    my $response;
    eval { $response = $rcon->command('help') };
    say $@ ? "Error: $@" : "Response: $response";

    $rcon->disconnect;

=head1 DESCRIPTION

C<Minecraft::RCON> provides a nice object interface for talking to Mojang AB's
game Minecraft. Intended for use with their multiplayer servers, specifically
I<your> multiplayer server, as you will need the correct RCON password, and
RCON must be enabled on said server.

=head1 CONSTRUCTOR

=head2 new( %options )

Create a new RCON object. Note we do not connect automatically; see
C<connect()> for that. The properties and their defaults are shown below:

    my $rcon = Minecraft::RCON->new({
        address         => '127.0.0.1',
        port            => 25575,
        password        => '',
        color_mode      => 'strip',
        error_mode      => 'error',
    });

We will C<carp()> but not die in the event that any unknown options are
provided.

=over 4

=item address

The hostname or IP address to connect to.

=item port

The TCP port number to connect to.

=item password

The plaintext password used to authenticate. This password must match the
C<rcon.password=> line in the F<server.properties> file for your server.

=item color_mode

The color mode controls how C<Minecraft::RCON> handles color codes sent back
by the Minecraft server. It must be one of C<strip>, C<convert>, or C<ignore>.
constants. See C<color_mode()> for more information.

=back

=head1 METHODS

=head2 connect

    eval { $rcon->connect }; # $@ will be set on error

Attempt to connect to the configured address and port, and issue the
configured password for authentication.

If already connected, returns C<undef> (nothing to be done).

This method will C<croak> if the connection fails for any reason.
Otherwise, returns a true value.

=head2 connected

    say "We are connected!" if $rcon->connected;

Returns true if we have a connected socket, false otherwise. Note that we have
no way to tell if there is a misbehaving Minecraft server on the other
side of that socket, so it is entirely possible for this command (or
C<connect()>) to succeed, but C<command()> calls to fail.

=head2 disconnect

    $rcon->disconnect;

Disconnects from the server by closing the socket. Always succeeds.

=head2 command( $command, [ $color_mode ] )

    my $response = $rcon->command("data get block $x $y $z");
    my $ansi = $rcon->command('list', 'convert');

Sends the C<$command> to the Minecraft server, and synchronously waits for the
response. This method is capable of handling fragmented responses (spread over
several response packets), and will concatenate them all before returning the
result.

The resulting server response will have its color codes stripped, converted,
or ignored, according to the current C<color_mode()> setting, unless a
C<$color_mode> is given, which will override the current setting for this
command only.

=head2 color_mode( $color_mode, [ $code ] )

    $rcon->color_mode('strip');

When a command response is received, the color codes it contains can be
stripped, converted to ANSI, or left alone, depending on this setting.

C<$color_mode> is optional, unless C<$code> is also specified.
The valid modes are as follows:

=over 10

=item strip

Strip any color codes, returning the plaintext.

=item convert

Convert any color codes to the equivalent ANSI escape sequences, suitable for
display in a terminal.

=item ignore

Ignore color codes, returning the full command response verbatim.

=back

The current mode will be returned.

If C<$code> is specified and is a C<CODE> ref, C<color_mode()> will apply the
new color mode, run C<$code-E<gt>()>, and then restore the original color
mode. This is useful when you use one color mode most of the time, but have
sections of code requiring a different mode:

Example usage:

    # Color mode is 'convert'
    $rcon->color_mode(strip => sub {
        my $plaintext = $rcon->command('...');
    });

But see also C<command($cmd, $mode)> for running single commands with
another color mode.


=head2 color_convert( $string, [ $color_mode ] )

    my $response = $rcon->command('list');
    my ($strip, $ansi) = map { $rcon->color_convert($response, $_) }
        qw<strip convert>;

This method is used internally by C<command()> to convert command responses as
configured in the object. However, C<color_convert()> itself may be useful in
some applications where a stripped version of the response may be needed for
parsing, while an ANSI version may be desired for display to a terminal, for
example, without having to run the command itself (with possible side-effects)
a second time. For C<color_convert()> to do anything meaningful, your object's
C<color_mode> should be set to C<ignore>.

=head1 ERROR HANDLING

This module C<croak>s (see L<Carp>) for almost all errors.
When an error does not affect control flow, we will C<carp> instead.

Thus, C<command()> and C<connect()>, at minimum, should be wrapped in block
C<eval>:

    eval { $result = $rcon->command('list'); };
    warn "I don't know who is online because: $@" if $@;

If a little extra syntactic sugar is desired, you can use an exception handler
like L<Try::Tiny> instead:

    use Try::Tiny;

    try {
        $result = $rcon->command('list');
    } catch {
        warn "I don't know who is online because: $_";
    }

=head1 DEPRECATED METHODS

The following methods have been deprecated. They will issue a warning to
STDOUT when called, and will be removed in a future release.

=head2 convert_color ( $enable )

If C<$enable> is a true value, change the color mode to C<convert>.
Returns 1 if the current color mode is C<convert>, undef otherwise.

B<Deprecated.> Use C<color_mode('convert')> instead.

=head2 strip_color

If C<$enable> is a true value, change the color mode to C<strip>.
Returns 1 if the current color mode is C<strip>, undef otherwise.

B<Deprecated.> Use C<color_mode('strip')> instead.

=head1 SUPPORT

=over 4

=item L<https://github.com/rjt-pl/Minecraft-RCON.git>: Source code repository

=item L<https://github.com/rjt-pl/Minecraft-RCON/issues>: Bug reports and feature requests

=back

=head1 SEE ALSO

=over 4

=item L<Net::RCON::Minecraft> for an alternative API

=item L<Terminal::ANSIColor>, L<IO::Socket::INET>

=item L<https://developer.valvesoftware.com/wiki/Source_RCON_Protocol>

=item L<https://wiki.vg/RCON>

=back

=head1 AFFILIATION WITH MOJANG

I<Note from original author, Fredrik Vold:>

I am in no way affiliated with Mojang or the development of Minecraft.
I'm simply a fan of their work, and a server admin myself.  I needed
some RCON magic for my servers website, and there was no perl module.

It is important that everyone using this module understands that if
Mojang changes the way RCON works, I won't be notified any sooner than
anyone else, and I have no special avenue of connection with them.

=head1 AUTHORS

=over 4

=item B<Ryan Thompson> C<E<lt>rjt@cpan.orgE<gt>>

Addition of unit test suite, fragmentation support, and other improvements.

This program is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

L<http://dev.perl.org/licenses/artistic.html>

=item B<Fredrik Vold> C<E<lt>fredrik@webkonsept.comE<gt>>

Original (0.1.x) author.

No copyright claimed, no rights reserved.

You are absolutely free to do as you wish with this code, but mentioning me in
your comments or whatever would be nice.

Minecraft is a trademark of Mojang AB. Name used in accordance with my
interpretation of L<http://www.minecraft.net/terms>, to the best of my
knowledge.

=back
