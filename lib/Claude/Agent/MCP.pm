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
use Claude::Agent::MCP::SDKServer;
use Claude::Agent::MCP::SDKRunner;

=head1 NAME

Claude::Agent::MCP - MCP (Model Context Protocol) server integration

=head1 SYNOPSIS

    use Claude::Agent qw(query tool create_sdk_mcp_server);
    use Claude::Agent::Options;

    # Create custom tools that execute locally
    my $calculator = tool(
        'calculate',
        'Perform basic arithmetic calculations',
        {
            type       => 'object',
            properties => {
                a => {
                    type        => 'number',
                    description => 'First operand',
                },
                b => {
                    type        => 'number',
                    description => 'Second operand',
                },
                operation => {
                    type        => 'string',
                    enum        => ['add', 'subtract', 'multiply', 'divide'],
                    description => 'The arithmetic operation to perform',
                },
            },
            required => ['a', 'b', 'operation'],
        },
        sub {
            my ($args) = @_;
            my ($a, $b, $op) = @{$args}{qw(a b operation)};

            my $result = $op eq 'add'      ? $a + $b
                       : $op eq 'subtract' ? $a - $b
                       : $op eq 'multiply' ? $a * $b
                       : $op eq 'divide'   ? ($b != 0 ? $a / $b : 'Error: division by zero')
                       :                     'Error: unknown operation';

            return {
                content => [{ type => 'text', text => "Result: $result" }]
            };
        }
    );

    my $lookup = tool(
        'lookup_user',
        'Look up user information by ID',
        {
            type       => 'object',
            properties => {
                user_id => {
                    type        => 'integer',
                    description => 'User ID to look up',
                },
            },
            required => ['user_id'],
        },
        sub {
            my ($args) = @_;
            # In real code, this would query a database
            my %users = (1 => 'Alice', 2 => 'Bob', 3 => 'Charlie');
            my $name = $users{$args->{user_id}} // 'Unknown';
            return {
                content => [{ type => 'text', text => "User: $name" }]
            };
        }
    );

    # Create an SDK MCP server with the tools
    my $server = create_sdk_mcp_server(
        name    => 'math',
        tools   => [$calculator, $lookup],
        version => '1.0.0',
    );

    # Use the tools in a query
    my $options = Claude::Agent::Options->new(
        mcp_servers     => { math => $server },
        allowed_tools   => ['mcp__math__calculate', 'mcp__math__lookup_user'],
        permission_mode => 'bypassPermissions',
    );

    my $iter = query(
        prompt  => 'Calculate 15 multiplied by 7, then look up user 1',
        options => $options,
    );

    while (my $msg = $iter->next) {
        # Tool handlers execute locally when Claude calls them
        if ($msg->isa('Claude::Agent::Message::Result')) {
            print $msg->result, "\n";
            last;
        }
    }

=head1 DESCRIPTION

This module provides MCP (Model Context Protocol) server integration for the
Claude Agent SDK, allowing you to create custom tools that Claude can use.

SDK MCP tools execute locally in your Perl process. When Claude calls a tool,
the SDK intercepts the request, runs your handler, and returns the result.
This allows your tools to access databases, APIs, application state, and
other resources available to your Perl application.

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

=item * L<Claude::Agent::MCP::SDKServer> - Socket-based server wrapper for SDK tools

=item * L<Claude::Agent::MCP::SDKRunner> - MCP protocol runner for SDK tools

=back

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut

1;
