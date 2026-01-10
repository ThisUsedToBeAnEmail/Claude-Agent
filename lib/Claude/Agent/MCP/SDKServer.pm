package Claude::Agent::MCP::SDKServer;

use 5.020;
use strict;
use warnings;

use IO::Socket::UNIX;
use JSON::Lines;
use File::Temp qw(tempdir);
use File::Spec;

=head1 NAME

Claude::Agent::MCP::SDKServer - Socket-based MCP server for SDK tools

=head1 DESCRIPTION

This module manages the IPC between the Perl SDK and the MCP server runner.
It creates a Unix socket, spawns the runner as a stdio MCP server, and
handles tool call requests from the runner by executing the local handlers.

=head1 SYNOPSIS

    use Claude::Agent::MCP::SDKServer;

    my $sdk_server = Claude::Agent::MCP::SDKServer->new(
        server => $mcp_server,  # Claude::Agent::MCP::Server object
        loop   => $loop,        # IO::Async::Loop
    );

    # Get the stdio config for the CLI
    my $stdio_config = $sdk_server->to_stdio_config();

    # Start listening for tool calls
    $sdk_server->start();

=cut

use Types::Common -types;
use Marlin
    'server!',           # Claude::Agent::MCP::Server object
    'loop!',             # IO::Async::Loop
    '_socket_path==.',   # Path to Unix socket
    '_listener==.',      # IO::Async listener
    '_temp_dir==.',      # Temp directory for socket
    '_jsonl==.';         # JSON::Lines instance

sub BUILD {
    my ($self) = @_;

    # Create temp directory for socket
    my $temp_dir = tempdir(CLEANUP => 1);
    $self->_temp_dir($temp_dir);

    my $socket_path = File::Spec->catfile($temp_dir, 'sdk.sock');
    $self->_socket_path($socket_path);

    $self->_jsonl(JSON::Lines->new);
}

=head2 socket_path

Returns the path to the Unix socket.

=cut

sub socket_path {
    my ($self) = @_;
    return $self->_socket_path;
}

=head2 to_stdio_config

Returns a hashref suitable for use as a stdio MCP server config.

=cut

sub to_stdio_config {
    my ($self) = @_;

    # Build tool definitions for the runner
    my @tools;
    for my $tool (@{$self->server->tools}) {
        push @tools, {
            name         => $tool->name,
            description  => $tool->description,
            input_schema => $tool->input_schema,
        };
    }

    my $tools_json = $self->_jsonl->encode(\@tools);
    chomp $tools_json;

    return {
        type    => 'stdio',
        command => $^X,  # Current Perl interpreter
        args    => [
            '-MClaude::Agent::MCP::SDKRunner',
            '-e',
            'Claude::Agent::MCP::SDKRunner::run()',
            '--',
            $self->_socket_path,
            $self->server->name,
            $self->server->version,
            $tools_json,
        ],
        env => {
            PERL5LIB => join(':', @INC),
        },
    };
}

=head2 start

Start listening on the Unix socket for tool call requests.

=cut

sub start {
    my ($self) = @_;

    require IO::Async::Listener;
    require IO::Async::Stream;

    # Remove existing socket if present
    unlink $self->_socket_path if -e $self->_socket_path;

    my $listener = IO::Async::Listener->new(
        on_stream => sub {
            my ($listener, $stream) = @_;

            $stream->configure(
                on_read => sub {
                    my ($stream, $buffref) = @_;

                    while ($$buffref =~ s/^(.+)\n//) {
                        my $line = $1;
                        $self->_handle_request($stream, $line);
                    }
                    return 0;
                },
            );

            $self->loop->add($stream);
        },
    );

    $self->loop->add($listener);

    $listener->listen(
        addr => {
            family   => 'unix',
            socktype => 'stream',
            path     => $self->_socket_path,
        },
    )->get;

    $self->_listener($listener);

    return $self;
}

sub _handle_request {
    my ($self, $stream, $line) = @_;

    my @requests = eval { $self->_jsonl->decode($line) };
    if ($@) {
        warn "SDKServer: Failed to parse request: $@\n" if $ENV{CLAUDE_AGENT_DEBUG};
        return;
    }

    for my $request (@requests) {
        my $tool_name = $request->{tool};
        my $args      = $request->{args} // {};
        my $request_id = $request->{id};

        warn "SDKServer: Executing tool '$tool_name'\n" if $ENV{CLAUDE_AGENT_DEBUG};

        # Find and execute the tool
        my $tool = $self->server->get_tool($tool_name);

        my $result;
        if ($tool) {
            $result = $tool->execute($args);
        }
        else {
            $result = {
                content  => [{ type => 'text', text => "Unknown tool: $tool_name" }],
                is_error => 1,
            };
        }

        # Send response back
        my $response = $self->_jsonl->encode([{
            id      => $request_id,
            content => $result->{content} // [],
            isError => $result->{is_error} ? \1 : \0,
        }]);

        $stream->write($response);
    }
}

=head2 stop

Stop the listener and clean up.

=cut

sub stop {
    my ($self) = @_;

    if ($self->_listener) {
        $self->loop->remove($self->_listener);
        $self->_listener(undef);
    }

    unlink $self->_socket_path if -e $self->_socket_path;
}

sub DEMOLISH {
    my ($self) = @_;
    $self->stop();
}

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut

1;
