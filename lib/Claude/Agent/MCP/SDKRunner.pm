package Claude::Agent::MCP::SDKRunner;

use 5.020;
use strict;
use warnings;

use IO::Socket::UNIX;
use IO::Async::Loop;
use IO::Async::Stream;
use JSON::Lines;
use Try::Tiny;

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

# Module-level state - encapsulated in a state object for cleaner isolation
# All state is reset atomically at the start of run() to handle persistent interpreters
sub _make_state_class {
    my $class = 'Claude::Agent::MCP::SDKRunner::State';
    no strict 'refs';  ## no critic (ProhibitNoStrict)
    *{"${class}::new"} = sub {
        my ($cls) = @_;
        return bless {
            socket          => undef,
            socket_stream   => undef,
            request_id      => 0,
            pending_requests => {},
            jsonl           => undef,
            loop            => undef,
            response_buffer => '',
            got_response    => 0,
        }, $cls;
    };
    *{"${class}::reset_state"} = sub {
        my ($self) = @_;
        $self->{socket} = undef;
        $self->{socket_stream} = undef;
        $self->{request_id} = 0;
        $self->{pending_requests} = {};
        $self->{jsonl} = JSON::Lines->new;
        $self->{loop} = undef;
        $self->{response_buffer} = '';
        $self->{got_response} = 0;
        return $self;
    };
    return $class;
}
BEGIN { _make_state_class() }

# Single state object - reset atomically at start of run()
my $state = Claude::Agent::MCP::SDKRunner::State->new;

# Accessors for backward compatibility with existing code
sub _socket        { return $state->{socket}; }
sub _socket_stream { return $state->{socket_stream}; }
sub _request_id    { return $state->{request_id}; }
sub _jsonl         { return $state->{jsonl}; }
sub _loop          { return $state->{loop}; }
sub _response_buffer { return $state->{response_buffer}; }
sub _got_response  { return $state->{got_response}; }

sub run {
    # Reset all state atomically - no gap between declaration and initialization
    $state->reset_state();

    binmode(STDIN,  ':raw');
    binmode(STDOUT, ':raw');
    binmode(STDERR, ':encoding(UTF-8)');

    # Parse arguments
    my ($socket_path, $server_name, $version, $tools_json) = @ARGV;

    unless ($socket_path && $server_name && $tools_json) {
        die "Usage: SDKRunner <socket_path> <server_name> <version> <tools_json>\n";
    }

    # Validate socket path - must be absolute
    die "Invalid socket path: must be absolute\n" unless $socket_path =~ m{^/};

    # Validate server_name - alphanumeric with hyphens/underscores only
    die "Invalid server name: must be alphanumeric with hyphens/underscores\n"
        unless $server_name =~ /^[a-zA-Z0-9_-]{1,100}$/;

    # Validate version if provided - semver-like format
    die "Invalid version format\n"
        if defined($version) && length($version) && $version !~ /^[a-zA-Z0-9._-]{1,50}$/;

    # Limit tools_json size to prevent memory exhaustion (1MB limit)
    die "tools_json too large (max 1MB)\n" if length($tools_json) > 1_000_000;

    my ($tools) = $state->{jsonl}->decode($tools_json);

    # Validate decoded structure: must be an array of tool definitions
    die "Invalid tools_json: expected array\n" unless ref $tools eq 'ARRAY';
    for my $tool (@$tools) {
        die "Invalid tool definition: expected hash with 'name' key\n"
            unless ref $tool eq 'HASH' && defined $tool->{name};
    }

    # Build tool lookup
    my %tool_by_name = map { $_->{name} => $_ } @$tools;

    # Connect to parent socket
    $state->{socket} = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Peer => $socket_path,
    ) or die "Cannot connect to socket $socket_path: $!\n";

    $state->{socket}->autoflush(1);

    warn "SDKRunner: Connected to $socket_path\n" if $ENV{CLAUDE_AGENT_DEBUG};

    # Create IO::Async event loop
    $state->{loop} = IO::Async::Loop->new;

    # Track running state
    my $running = 1;

    # Shutdown helper
    my $shutdown = sub {
        return unless $running;
        $running = 0;
        $state->{loop}->stop;
    };

    # Handle signals for graceful shutdown
    local $SIG{TERM} = $shutdown;
    local $SIG{PIPE} = $shutdown;

    # Create async stream for STDIN (from Claude CLI)
    my $stdin_stream = IO::Async::Stream->new(
        read_handle => \*STDIN,
        on_read => sub {
            my ($stream, $buffref) = @_;

            while ($$buffref =~ s/^([^\n]+)\n//) {
                my $line = $1;
                next unless length $line;

                warn "SDKRunner: Received: $line\n" if $ENV{CLAUDE_AGENT_DEBUG};

                my @requests;
                my $parse_error;
                try {
                    @requests = $state->{jsonl}->decode($line);
                } catch {
                    $parse_error = $_;
                };
                if ($parse_error) {
                    warn "SDKRunner: Failed to parse JSON: $parse_error\n";
                    next;
                }

                for my $request (@requests) {
                    my $response = handle_mcp_request(
                        $request, \%tool_by_name, $server_name, $version, $tools
                    );

                    if ($response) {
                        my $json = $state->{jsonl}->encode([$response]);
                        warn "SDKRunner: Sending: $json\n" if $ENV{CLAUDE_AGENT_DEBUG};
                        print $json;
                        STDOUT->flush();
                    }
                }
            }
            return 0;
        },
        on_read_eof => sub {
            warn "SDKRunner: STDIN closed (EOF)\n" if $ENV{CLAUDE_AGENT_DEBUG};
            $shutdown->();
        },
        on_read_error => sub {
            my ($stream, $errno) = @_;
            warn "SDKRunner: STDIN read error: $errno\n" if $ENV{CLAUDE_AGENT_DEBUG};
            $shutdown->();
        },
    );

    # Create async stream for socket (to parent SDKServer)
    # Used for async writes and monitoring disconnection
    # Response reads are handled via $state->{response_buffer}/$state->{got_response}
    # which call_parent_handler uses with loop_once() polling
    $state->{socket_stream} = IO::Async::Stream->new(
        handle => $state->{socket},
        on_read => sub {
            my ($stream, $buffref) = @_;
            # Buffer incoming data for call_parent_handler to consume
            $state->{response_buffer} .= $$buffref;
            $$buffref = '';
            # Check if we have a complete line
            if ($state->{response_buffer} =~ /\n/) {
                $state->{got_response} = 1;
            }
            return 0;
        },
        on_read_eof => sub {
            warn "SDKRunner: Socket closed by parent\n" if $ENV{CLAUDE_AGENT_DEBUG};
            $shutdown->();
        },
        on_read_error => sub {
            my ($stream, $errno) = @_;
            warn "SDKRunner: Socket error: $errno\n" if $ENV{CLAUDE_AGENT_DEBUG};
            $shutdown->();
        },
    );

    $state->{loop}->add($stdin_stream);
    $state->{loop}->add($state->{socket_stream});

    # Run the event loop
    $state->{loop}->run;

    # Cleanup
    $state->{loop}->remove($stdin_stream) if $stdin_stream;
    $state->{loop}->remove($state->{socket_stream}) if $state->{socket_stream};
    $state->{socket}->close() if $state->{socket};
    return;
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
        return;
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
            # Sanitize tool name in error message (truncate, remove control chars)
            my $safe_name = defined $tool_name ? substr($tool_name, 0, 100) : '<undefined>';
            $safe_name =~ s/[[:cntrl:]]//g;
            return {
                jsonrpc => '2.0',
                id      => $id,
                error   => {
                    code    => -32601,
                    message => "Unknown tool: $safe_name",
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
    my $safe_method = defined $method ? substr($method, 0, 100) : '<undefined>';
    $safe_method =~ s/[[:cntrl:]]//g;
    return {
        jsonrpc => '2.0',
        id      => $id,
        error   => {
            code    => -32601,
            message => "Method not found: $safe_method",
        },
    };
}

sub _generate_uuid {
    # Generate a UUID v4-like string to avoid request ID collisions
    # Uses cryptographically secure random bytes for robust uniqueness
    require Crypt::URandom;
    my $random_bytes = Crypt::URandom::urandom(16);
    my $uuid = unpack('H*', $random_bytes);
    $uuid =~ s/(.{8})(.{4})(.{4})(.{4})(.{12})/$1-$2-$3-$4-$5/;
    return $uuid;
}

sub call_parent_handler {
    my ($tool_name, $args) = @_;

    # Use UUID-based request IDs to eliminate any possibility of ID collision
    # even if async/threaded handling is added in the future
    my $request_id = _generate_uuid();

    # Send request to parent via async stream
    my $request = $state->{jsonl}->encode([{
        id   => $request_id,
        tool => $tool_name,
        args => $args,
    }]);

    warn "SDKRunner: Sending to parent: $request\n" if $ENV{CLAUDE_AGENT_DEBUG};

    $state->{socket_stream}->write($request);

    # Reset response flag before waiting
    $state->{got_response} = 0;

    # Wait for response with configurable timeout using actual elapsed time
    require Time::HiRes;
    my $timeout = $ENV{CLAUDE_AGENT_TOOL_TIMEOUT} // 60;
    # Ensure numeric value between 1-3600 seconds (1 sec to 1 hour)
    # Non-numeric, empty, zero, or out-of-range values fall back to 60s default
    # Security note: High timeout values (e.g., 3600) can tie up system resources
    # for extended periods. Consider using conservative values in production.
    if (!defined $timeout || $timeout !~ /^\d+$/ || $timeout < 1 || $timeout > 3600) {
        $timeout = 60;
    }
    my $start_time = Time::HiRes::time();
    my $backoff = 0.1;

    while (!$state->{got_response}) {
        # Check elapsed time before loop_once to ensure accurate timeout enforcement
        my $elapsed = Time::HiRes::time() - $start_time;
        last if $elapsed >= $timeout;

        $state->{loop}->loop_once($backoff);
        $backoff = $backoff * 1.5 if $backoff < 1.0;  # Exponential backoff up to 1 second

        # Re-check elapsed time after loop_once in case it took longer than expected
        last if (Time::HiRes::time() - $start_time) >= $timeout;
    }

    # Extract the response line from buffer
    my $response_line;
    if ($state->{response_buffer} =~ s/^(.+)\n//) {
        $response_line = $1;
        # Reset flag if no more complete lines
        $state->{got_response} = 0 unless $state->{response_buffer} =~ /\n/;
    }

    unless ($response_line) {
        warn "SDKRunner: No response from parent (timeout)\n" if $ENV{CLAUDE_AGENT_DEBUG};
        return {
            content => [{ type => 'text', text => 'No response from handler (timeout)' }],
            isError => \1,
        };
    }

    warn "SDKRunner: Received from parent: $response_line\n" if $ENV{CLAUDE_AGENT_DEBUG};

    my ($response, $parse_error);
    try {
        ($response) = $state->{jsonl}->decode($response_line);
    } catch {
        $parse_error = $_;
    };
    if ($parse_error) {
        warn "SDKRunner: Failed to parse response: $parse_error" if $ENV{CLAUDE_AGENT_DEBUG};
        return {
            content => [{ type => 'text', text => 'Failed to parse handler response' }],
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
