package Claude::Agent::MCP::Server;

use 5.020;
use strict;
use warnings;

use Types::Common -types;
use Marlin
    'name!'    => Str,
    'tools'    => sub { [] },
    'version'  => sub { '1.0.0' },
    'type'     => sub { 'sdk' };

=head1 NAME

Claude::Agent::MCP::Server - SDK MCP server configuration

=head1 DESCRIPTION

Defines an SDK MCP server configuration.

=head2 ATTRIBUTES

=over 4

=item * name - Server name (used in tool naming: mcp__name__tool)

=item * tools - ArrayRef of L<Claude::Agent::MCP::ToolDefinition> objects

=item * version - Server version (default: '1.0.0')

=item * type - Server type (default: 'sdk')

=back

=head2 METHODS

=head3 to_hash

    my $hash = $server->to_hash();

Convert the server configuration to a hash for JSON serialization.

=cut

sub to_hash {
    my ($self) = @_;
    return {
        type    => $self->type,
        name    => $self->name,
        version => $self->version,
        tools   => [ map { $_->to_hash } @{$self->tools} ],
    };
}

=head3 get_tool

    my $tool = $server->get_tool($tool_name);

Get a tool definition by name.

=cut

sub get_tool {
    my ($self, $tool_name) = @_;

    for my $tool (@{$self->tools}) {
        return $tool if $tool->name eq $tool_name;
    }

    return undef;
}

=head3 tool_names

    my $names = $server->tool_names();

Get the full MCP tool names for all tools in this server.

=cut

sub tool_names {
    my ($self) = @_;
    return [ map { 'mcp__' . $self->name . '__' . $_->name } @{$self->tools} ];
}

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut

1;
