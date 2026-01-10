package Claude::Agent::MCP;

use 5.020;
use strict;
use warnings;

use Types::Common -types;

# Load subclasses
use Claude::Agent::MCP::ToolDefinition;
use Claude::Agent::MCP::Server;
use Claude::Agent::MCP::StdioServer;
use Claude::Agent::MCP::SSEServer;
use Claude::Agent::MCP::HTTPServer;

=head1 NAME

Claude::Agent::MCP - MCP (Model Context Protocol) server integration

=head1 SYNOPSIS

    use Claude::Agent qw(tool create_sdk_mcp_server);
    use Claude::Agent::Options;

    # Create a custom tool
    my $calculator = tool(
        'calculate',
        'Perform mathematical calculations',
        {
            type => 'object',
            properties => {
                expression => { type => 'string' }
            },
            required => ['expression'],
        },
        sub {
            my ($args) = @_;
            my $result = eval $args->{expression};
            return {
                content => [{ type => 'text', text => "Result: $result" }]
            };
        }
    );

    # Create an SDK MCP server
    my $server = create_sdk_mcp_server(
        name    => 'math',
        tools   => [$calculator],
        version => '1.0.0',
    );

    # Use in options
    my $options = Claude::Agent::Options->new(
        mcp_servers   => { math => $server },
        allowed_tools => ['mcp__math__calculate'],
    );

=head1 DESCRIPTION

This module provides MCP (Model Context Protocol) server integration for the
Claude Agent SDK, allowing you to create custom tools that Claude can use.

=head1 MCP SERVER TYPES

=over 4

=item * sdk - In-process server running within your application

=item * stdio - External process communicating via stdin/stdout

=item * sse - Remote server using Server-Sent Events

=item * http - Remote server using HTTP

=back

=head1 MCP CLASSES

=over 4

=item * L<Claude::Agent::MCP::ToolDefinition> - Custom tool definition

=item * L<Claude::Agent::MCP::Server> - SDK MCP server

=item * L<Claude::Agent::MCP::StdioServer> - Stdio MCP server

=item * L<Claude::Agent::MCP::SSEServer> - SSE MCP server

=item * L<Claude::Agent::MCP::HTTPServer> - HTTP MCP server

=back

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut

1;
