package Claude::Agent::MCP::SSEServer;

use 5.020;
use strict;
use warnings;

use Types::Common -types;
use Marlin
    'url!'     => Str,
    'headers'  => sub { {} },
    'type'     => sub { 'sse' };

=head1 NAME

Claude::Agent::MCP::SSEServer - SSE MCP server configuration

=head1 DESCRIPTION

Configuration for a remote MCP server using Server-Sent Events.

=head2 ATTRIBUTES

=over 4

=item * url - Server URL

=item * headers - HashRef of HTTP headers

=item * type - Always 'sse'

=back

=head2 METHODS

=head3 to_hash

    my $hash = $server->to_hash();

Convert the server configuration to a hash for JSON serialization.

=cut

sub to_hash {
    my ($self) = @_;
    return {
        type    => 'sse',
        url     => $self->url,
        headers => $self->headers,
    };
}

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut

1;
