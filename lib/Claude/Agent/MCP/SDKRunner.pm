package Claude::Agent::MCP::SDKRunner;

use 5.020;
use strict;
use warnings;

use IO::Socket::UNIX;
use JSON::Lines;

=head1 NAME

Claude::Agent::MCP::SDKRunner - MCP server runner for SDK tools

=head1 DESCRIPTION

This module implements the MCP server protocol and forwards tool calls
to the parent Perl process via a Unix socket. It is spawned as a child
process by the Claude CLI.

=head1 SYNOPSIS

    # Called internally by the SDK - not for direct use
    perl -MClaude::Agent::MCP::SDKRunner -e 'Claude::Agent::MCP::SDKRunner::run()' \
        -- /path/to/socket server_name 1.0.0 '[{"name":"tool1",...}]'

=cut

my $socket;
my $request_id = 0;
my %pending_requests;
my $jsonl = JSON::Lines->new;

sub run {
    binmode(STDIN,  ':raw');
    binmode(STDOUT, ':raw');
    binmode(STDERR, ':utf8');

    # Parse arguments
    my ($socket_path, $server_name, $version, $tools_json) = @ARGV;

    unless ($socket_path && $server_name && $tools_json) {
        die "Usage: SDKRunner <socket_path> <server_name> <version> <tools_json>\n";
    }

    my ($tools) = $jsonl->decode($tools_json);

    # Build tool lookup
    my %tool_by_name = map { $_->{name} => $_ } @$tools;

    # Connect to parent socket
    $socket = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $socket_path,
    ) or die "Cannot connect to socket $socket_path: $!\n";

    $socket->autoflush(1);

    warn "SDKRunner: Connected to $socket_path\n" if $ENV{CLAUDE_AGENT_DEBUG};

    # MCP server loop - read JSON-RPC messages from stdin
    while (my $line = <STDIN>) {
        chomp $line;
        next unless length $line;

        warn "SDKRunner: Received: $line\n" if $ENV{CLAUDE_AGENT_DEBUG};

        my @requests = eval { $jsonl->decode($line) };
        if ($@) {
            warn "SDKRunner: Failed to parse JSON: $@\n";
            next;
        }

        for my $request (@requests) {
            my $response = handle_mcp_request($request, \%tool_by_name, $server_name, $version, $tools);

            if ($response) {
                my $json = $jsonl->encode([$response]);
                warn "SDKRunner: Sending: $json\n" if $ENV{CLAUDE_AGENT_DEBUG};
                print $json;
                STDOUT->flush();
            }
        }
    }

    $socket->close() if $socket;
}

sub handle_mcp_request {
    my ($request, $tool_by_name, $server_name, $version, $tools) = @_;

    my $method = $request->{method} // '';
    my $id     = $request->{id};
    my $params = $request->{params} // {};

    # Handle MCP protocol methods
    if ($method eq 'initialize') {
        return {
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                protocolVersion => '2024-11-05',
                capabilities    => {
                    tools => {},
                },
                serverInfo => {
                    name    => $server_name,
                    version => $version,
                },
            },
        };
    }
    elsif ($method eq 'notifications/initialized') {
        # No response needed for notification
        return undef;
    }
    elsif ($method eq 'tools/list') {
        my @tool_list;
        for my $tool (@$tools) {
            push @tool_list, {
                name        => $tool->{name},
                description => $tool->{description},
                inputSchema => $tool->{input_schema},
            };
        }
        return {
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                tools => \@tool_list,
            },
        };
    }
    elsif ($method eq 'tools/call') {
        my $tool_name = $params->{name};
        my $arguments = $params->{arguments} // {};

        my $tool = $tool_by_name->{$tool_name};
        unless ($tool) {
            return {
                jsonrpc => '2.0',
                id      => $id,
                error   => {
                    code    => -32601,
                    message => "Unknown tool: $tool_name",
                },
            };
        }

        # Forward tool call to parent via socket
        my $result = call_parent_handler($tool_name, $arguments);

        return {
            jsonrpc => '2.0',
            id      => $id,
            result  => {
                content => $result->{content} // [],
                isError => $result->{isError} // \0,
            },
        };
    }
    elsif ($method eq 'ping') {
        return {
            jsonrpc => '2.0',
            id      => $id,
            result  => {},
        };
    }

    # Unknown method
    return {
        jsonrpc => '2.0',
        id      => $id,
        error   => {
            code    => -32601,
            message => "Method not found: $method",
        },
    };
}

sub call_parent_handler {
    my ($tool_name, $args) = @_;

    $request_id++;

    # Send request to parent
    my $request = $jsonl->encode([{
        id   => $request_id,
        tool => $tool_name,
        args => $args,
    }]);

    warn "SDKRunner: Sending to parent: $request\n" if $ENV{CLAUDE_AGENT_DEBUG};

    $socket->print($request);
    $socket->flush();

    # Read response from parent
    my $response_line = $socket->getline();
    chomp $response_line if defined $response_line;

    warn "SDKRunner: Received from parent: $response_line\n" if $ENV{CLAUDE_AGENT_DEBUG};

    unless ($response_line) {
        return {
            content => [{ type => 'text', text => 'No response from handler' }],
            isError => \1,
        };
    }

    my ($response) = eval { $jsonl->decode($response_line) };
    if ($@) {
        return {
            content => [{ type => 'text', text => "Failed to parse handler response: $@" }],
            isError => \1,
        };
    }

    return $response;
}

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut

1;
