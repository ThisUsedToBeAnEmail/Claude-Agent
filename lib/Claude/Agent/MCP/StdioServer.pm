package Claude::Agent::MCP::StdioServer;

use 5.020;
use strict;
use warnings;

use Types::Common -types;
use Marlin
    'command!' => Str,
    'args'     => sub { [] },
    'env'      => sub { {} },
    'type'     => sub { 'stdio' };

=head1 NAME

Claude::Agent::MCP::StdioServer - Stdio MCP server configuration

=head1 DESCRIPTION

Configuration for an external MCP server process.

=head2 ATTRIBUTES

=over 4

=item * command - Command to run

=item * args - ArrayRef of command arguments

=item * env - HashRef of environment variables

=item * type - Always 'stdio'

=back

=head2 METHODS

=head3 to_hash

    my $hash = $server->to_hash();

Convert the server configuration to a hash for JSON serialization.

=cut

sub to_hash {
    my ($self) = @_;
    return {
        type    => 'stdio',
        command => $self->command,
        args    => $self->args,
        env     => $self->env,
    };
}

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut

1;
