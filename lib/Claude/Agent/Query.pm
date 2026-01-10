package Claude::Agent::Query;

use 5.020;
use strict;
use warnings;

use Time::HiRes ();
use Types::Common -types;
use Marlin
    'prompt!',                                     # Required prompt (string or async generator)
    'options' => sub { Claude::Agent::Options->new() },
    'loop?',                                       # Optional external IO::Async loop
    '_loop==.',                                    # Internal loop reference (rw, no init_arg)
    '_process==.',                                 # IO::Async::Process handle
    '_stdin==.',                                   # stdin pipe for sending messages
    '_messages==.' => sub { [] },                  # Message queue
    '_pending_futures==.' => sub { [] },           # Futures waiting for messages
    '_session_id==.',                              # Session ID from init message
    '_finished==.' => sub { 0 },                   # Process finished flag
    '_error==.',                                   # Error message if process failed
    '_sdk_servers==.' => sub { {} },               # SDK server wrappers (name => SDKServer)
    '_jsonl==.' => sub {
        JSON::Lines->new(
            utf8     => 1,
            error_cb => sub {
                my ($action, $error, $data) = @_;
                # Only warn at debug level 2+ since parse errors are common
                # with streaming JSON and partial data
                warn "JSON::Lines $action error: $error"
                    if $ENV{CLAUDE_AGENT_DEBUG} && $ENV{CLAUDE_AGENT_DEBUG} > 1;
                return;
            },
        )
    };

use IO::Async::Loop;
use IO::Async::Process;
use Future;
use Future::AsyncAwait;
use JSON::Lines;
use Try::Tiny;
use File::Which qw(which);
use File::Spec;

use Claude::Agent::Options;
use Claude::Agent::Message;
use Claude::Agent::Error;
use Claude::Agent::MCP::SDKServer;

=head1 NAME

Claude::Agent::Query - Query iterator for Claude Agent SDK

=head1 SYNOPSIS

    use Claude::Agent::Query;
    use Claude::Agent::Options;

    my $query = Claude::Agent::Query->new(
        prompt  => "Find all TODO comments",
        options => Claude::Agent::Options->new(
            allowed_tools => ['Read', 'Glob', 'Grep'],
        ),
    );

    # Blocking iteration
    while (my $msg = $query->next) {
        if ($msg->isa('Claude::Agent::Message::Result')) {
            print $msg->result, "\n";
            last;
        }
    }

=head1 DESCRIPTION

This module handles communication with the Claude CLI process and provides
both blocking and async iteration over response messages.

=head1 CONSTRUCTOR

    my $query = Claude::Agent::Query->new(
        prompt  => "Find all TODO comments",
        options => $options,
        loop    => $loop,    # optional, for async integration
    );

=head2 Arguments

=over 4

=item * prompt - Required. The prompt to send to Claude.

=item * options - Optional. A Claude::Agent::Options object.

=item * loop - Optional. An IO::Async::Loop for async integration.
If not provided, a new loop is created internally.

=back

B<Important:> For proper async behavior, pass your application's event loop.
This allows C<next_async> to be truly event-driven instead of polling.

=cut

sub BUILD {
    my ($self) = @_;
    # Use provided loop or create a new one
    # For proper async, callers should pass their own loop
    $self->_loop($self->loop // IO::Async::Loop->new);

    # Create SDKServer wrappers for SDK MCP servers
    # These spawn socket listeners that the MCP runner connects to
    if ($self->options->has_mcp_servers && $self->options->mcp_servers) {
        for my $name (keys %{$self->options->mcp_servers}) {
            my $server = $self->options->mcp_servers->{$name};
            # Only wrap SDK-type servers
            if ($server->can('type') && $server->type eq 'sdk') {
                my $sdk_server = Claude::Agent::MCP::SDKServer->new(
                    server => $server,
                    loop   => $self->_loop,
                );
                $sdk_server->start();
                $self->_sdk_servers->{$name} = $sdk_server;
                warn "DEBUG: Started SDK server '$name' on socket: " . $sdk_server->socket_path . "\n"
                    if $ENV{CLAUDE_AGENT_DEBUG};
            }
        }
    }

    $self->_start_process();
    return;
}

sub _find_claude_cli {
    my ($self) = @_;

    # Check for claude in PATH
    my $claude = which('claude');
    return $claude if $claude;

    # Check common locations
    my @paths = (
        '/usr/local/bin/claude',
        '/opt/homebrew/bin/claude',
    );
    # Add HOME-based paths only if HOME is a valid absolute path without traversal
    if ($ENV{HOME} && $ENV{HOME} =~ m{^/}) {
        require Cwd;
        my $home = Cwd::abs_path($ENV{HOME});
        # Only use if resolved path is valid and absolute
        if ($home && $home =~ m{^/} && -d $home) {
            push @paths, File::Spec->catfile($home, '.local', 'bin', 'claude');
            push @paths, File::Spec->catfile($home, '.npm-global', 'bin', 'claude');
        }
    }

    for my $path (@paths) {
        return $path if -x $path;
    }

    Claude::Agent::Error::CLINotFound->throw(
        message => "Could not find 'claude' CLI in PATH or common locations"
    );
    return;  # Never reached, but satisfies perlcritic
}

sub _build_command {
    my ($self) = @_;

    my $claude = $self->_find_claude_cli();

    # Base command: --output-format stream-json --verbose (always required together)
    my @cmd = ($claude, '--output-format', 'stream-json', '--verbose');

    my $opts = $self->options;

    # Add model if specified
    if ($opts->has_model && $opts->model) {
        push @cmd, '--model', $opts->model;
    }

    # Add max turns if specified (ensure integer)
    if ($opts->has_max_turns && $opts->max_turns) {
        push @cmd, '--max-turns', int($opts->max_turns);
    }

    # Add permission mode
    if ($opts->permission_mode && $opts->permission_mode ne 'default') {
        push @cmd, '--permission-mode', $opts->permission_mode;
    }

    # Add allowed tools (as comma-separated list)
    if ($opts->has_allowed_tools && $opts->allowed_tools && @{$opts->allowed_tools}) {
        push @cmd, '--allowedTools', join(',', @{$opts->allowed_tools});
    }

    # Add disallowed tools (as comma-separated list)
    if ($opts->has_disallowed_tools && $opts->disallowed_tools && @{$opts->disallowed_tools}) {
        push @cmd, '--disallowedTools', join(',', @{$opts->disallowed_tools});
    }

    # Add resume session
    if ($opts->has_resume && $opts->resume) {
        push @cmd, '--resume', $opts->resume;
    }

    # Add fork session flag
    if ($opts->has_fork_session && $opts->fork_session) {
        push @cmd, '--fork-session';
    }

    # Add system prompt
    if ($opts->has_system_prompt && $opts->system_prompt) {
        my $sp = $opts->system_prompt;
        if (ref $sp eq 'HASH' && $sp->{preset}) {
            # Sanitize control characters from preset name
            my $sanitized = $sp->{preset};
            $sanitized =~ s/[[:cntrl:]]/ /g;
            push @cmd, '--system-prompt', $sanitized;
        }
        elsif (!ref $sp) {
            # Sanitize control characters from system prompt
            my $sanitized = $sp;
            $sanitized =~ s/[[:cntrl:]]/ /g;
            push @cmd, '--system-prompt', $sanitized;
        }
    }

    # Add MCP servers config
    # SDK servers are converted to stdio servers pointing to our SDKRunner
    if (($opts->has_mcp_servers && $opts->mcp_servers && keys %{$opts->mcp_servers}) || keys %{$self->_sdk_servers}) {
        my %servers;

        # Add non-SDK servers directly
        if ($opts->has_mcp_servers && $opts->mcp_servers) {
            for my $name (keys %{$opts->mcp_servers}) {
                my $server = $opts->mcp_servers->{$name};
                # Skip SDK servers - they're handled via SDKServer wrappers below
                next if $server->can('type') && $server->type eq 'sdk';
                $servers{$name} = $server->can('to_hash') ? $server->to_hash : $server;
            }
        }

        # Add SDK servers as stdio servers pointing to our runner
        for my $name (keys %{$self->_sdk_servers}) {
            my $sdk_server = $self->_sdk_servers->{$name};
            $servers{$name} = $sdk_server->to_stdio_config();
        }

        if (%servers) {
            my $json = $self->_jsonl->encode([{ mcpServers => \%servers }]);
            chomp $json;
            push @cmd, '--mcp-config', $json;
        }
    }

    # Add agents config
    if ($opts->has_agents && $opts->agents) {
        my %agents;
        for my $name (keys %{$opts->agents}) {
            my $agent = $opts->agents->{$name};
            $agents{$name} = $agent->can('to_hash') ? $agent->to_hash : $agent;
        }
        if (%agents) {
            my $json = $self->_jsonl->encode([\%agents]);
            chomp $json;
            push @cmd, '--agents', $json;
        }
    }

    # Add setting sources
    if ($opts->has_setting_sources && $opts->setting_sources && @{$opts->setting_sources}) {
        push @cmd, '--setting-sources', join(',', @{$opts->setting_sources});
    }

    # Add JSON schema for structured outputs
    if ($opts->has_output_format && $opts->output_format) {
        my $format = $opts->output_format;
        if (ref $format eq 'HASH' && $format->{schema}) {
            my $json = $self->_jsonl->encode([$format->{schema}]);
            chomp $json;
            push @cmd, '--json-schema', $json;
        }
    }

    # For string prompts, use --print mode with -- separator
    # For async generators, use stream-json input format
    if (!ref($self->prompt)) {
        # Sanitize control characters from prompt to prevent injection
        # Preserve tabs (\t), newlines (\n, \r) which are common in code snippets
        my $sanitized_prompt = $self->prompt;
        $sanitized_prompt =~ s/\x1b\[[0-9;]*[a-zA-Z]//g;  # Strip ANSI escape codes
        $sanitized_prompt =~ s/\x1b\][^\x07]*\x07//g;     # Strip OSC sequences (title changes, etc.)
        $sanitized_prompt =~ s/\x1b[PX^_].*?\x1b\\//g;    # Strip DCS/SOS/PM/APC sequences
        # Remove dangerous control chars but preserve tab (\x09), newline (\x0a), carriage return (\x0d)
        $sanitized_prompt =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/ /g;
        push @cmd, '--print', '--', $sanitized_prompt;
    }
    else {
        # For streaming input (async generator), use stream-json input format
        push @cmd, '--input-format', 'stream-json';
    }

    return @cmd;
}

sub _start_process {
    my ($self) = @_;

    my @cmd = $self->_build_command();

    if ($ENV{CLAUDE_AGENT_DEBUG}) {
        my @safe_cmd = map { $_ =~ /^--/ ? $_ : '[REDACTED]' } @cmd[0..2];
        push @safe_cmd, '...' if @cmd > 3;
        warn "DEBUG: Running command: @safe_cmd (full args redacted)\n";
    }

    my $process = IO::Async::Process->new(
        command => \@cmd,
        stdin  => { via => 'pipe_write' },
        stdout => {
            on_read => sub {
                my ($stream, $buffref) = @_;
                while ($$buffref =~ s/^([^\n]+)\n//) {
                    my $line = $1;
                    $self->_handle_line($line);
                }
                return 0;
            },
        },
        stderr => {
            on_read => sub {
                my ($stream, $buffref) = @_;
                # Log stderr but don't treat as fatal
                while ($$buffref =~ s/^([^\n]+)\n//) {
                    warn "Claude CLI stderr: $1\n" if $ENV{CLAUDE_AGENT_DEBUG};
                }
                return 0;
            },
        },
        on_finish => sub {
            my ($proc, $exitcode) = @_;
            $self->_finished(1);
            # Extract actual exit status (WEXITSTATUS equivalent)
            my $exit_status = $exitcode >> 8;
            if ($exit_status != 0) {
                $self->_error("Claude CLI exited with code $exit_status");
            }
            # Resolve any pending async futures
            $self->_resolve_pending_futures_on_finish();
        },
        on_exception => sub {
            my ($proc, $exception, $errno, $exitcode) = @_;
            $self->_finished(1);
            $self->_error("Claude CLI exception: $exception");
            # Resolve any pending async futures
            $self->_resolve_pending_futures_on_finish();
        },
    );

    # Store references before adding to loop to avoid race conditions
    $self->_process($process);
    $self->_stdin($process->stdin);
    $self->_loop->add($process);

    # For --print mode, prompt is in argv, stdin can be closed
    if (!ref($self->prompt)) {
        # Schedule close after a brief delay to allow process startup
        $self->_loop->later(sub { $self->_stdin->close_when_empty if $self->_stdin });
    }
    # For ref prompts (streaming input), caller will send messages via send_user_message
    return;
}

sub _handle_line {
    my ($self, $line) = @_;

    return unless defined $line && length $line;

    # Use JSON::Lines decode method for single line
    my @decoded = $self->_jsonl->decode($line);
    if ($ENV{CLAUDE_AGENT_DEBUG} && $ENV{CLAUDE_AGENT_DEBUG} > 1) {
        warn "DEBUG: Raw line length: " . length($line) . "\n";
        warn "DEBUG: Raw line: $line\n";
        warn "DEBUG: Decoded " . scalar(@decoded) . " objects\n";
        warn "DEBUG: JSON::Lines buffer remaining: " . length($self->_jsonl->remaining) . " chars\n";
        if ($self->_jsonl->remaining) {
            warn "DEBUG: Buffer content (first 200): " . substr($self->_jsonl->remaining, 0, 200) . "\n";
        }
    }

    # Guard against buffer overflow from accumulated malformed data
    # Configurable threshold via environment variable, default 100KB, max 10MB
    my $buffer_threshold = $ENV{CLAUDE_AGENT_JSONL_BUFFER_MAX} // 100_000;
    my $min_threshold = 1000;  # Minimum 1KB to prevent excessive reinitializations
    if (!defined $buffer_threshold || $buffer_threshold !~ /^\d+$/ || $buffer_threshold < $min_threshold) {
        warn "Invalid CLAUDE_AGENT_JSONL_BUFFER_MAX value, using default 100000\n"
            if defined $ENV{CLAUDE_AGENT_JSONL_BUFFER_MAX};
        $buffer_threshold = 100_000;
    }
    $buffer_threshold = 10_000_000 if $buffer_threshold > 10_000_000;  # Hard cap at 10MB

    # Check buffer size regardless of decode success to prevent unbounded growth
    if ($self->_jsonl->remaining && length($self->_jsonl->remaining) > $buffer_threshold) {
        warn "JSON::Lines buffer overflow detected (size: " . length($self->_jsonl->remaining) .
             ", threshold: $buffer_threshold), reinitializing\n" if $ENV{CLAUDE_AGENT_DEBUG};
        $self->_jsonl(JSON::Lines->new(
            utf8     => 1,
            error_cb => sub {
                my ($action, $error, $data) = @_;
                warn "JSON::Lines $action error: $error"
                    if $ENV{CLAUDE_AGENT_DEBUG} && $ENV{CLAUDE_AGENT_DEBUG} > 1;
                return;
            },
        ));
    }

    return unless @decoded;

    for my $data (@decoded) {
        if ($ENV{CLAUDE_AGENT_DEBUG} && $ENV{CLAUDE_AGENT_DEBUG} > 1) {
            warn "DEBUG: Decoded item ref type: " . (ref($data) // "not a ref") . "\n";
            if (ref $data eq 'HASH') {
                warn "DEBUG: Hash keys: " . join(", ", keys %$data) . "\n";
            }
        }
        next unless defined $data && ref $data eq 'HASH';
        if ($ENV{CLAUDE_AGENT_DEBUG} && $ENV{CLAUDE_AGENT_DEBUG} > 1) {
            warn "DEBUG: Message type in data: " . ($data->{type} // "undef") . "\n";
        }
        next unless exists $data->{type};  # Skip malformed/partial JSON data

        my $msg = Claude::Agent::Message->from_json($data);

        # Capture session_id from init message
        if ($msg->isa('Claude::Agent::Message::System')
            && $msg->subtype eq 'init') {
            $self->_session_id($msg->get_session_id);
        }

        # If there's a pending future waiting for a message, resolve it directly
        if (@{$self->_pending_futures}) {
            my $future = shift @{$self->_pending_futures};
            $future->done($msg);
        }
        else {
            # Otherwise queue it for next() or next_async()
            push @{$self->_messages}, $msg;
        }
    }
    return;
}

sub _resolve_pending_futures_on_finish {
    my ($self) = @_;
    # Resolve any pending futures with undef when process finishes
    while (my $future = shift @{$self->_pending_futures}) {
        $future->done(undef);
    }

    # Stop SDK servers
    for my $sdk_server (values %{$self->_sdk_servers}) {
        try {
            $sdk_server->stop();
        } catch {
            warn "Failed to stop SDK server: $_" if $ENV{CLAUDE_AGENT_DEBUG};
        };
    }
    return;
}

=head2 next

    my $msg = $query->next;

Blocking call to get the next message. Returns undef when no more messages.

=cut

## no critic (ProhibitBuiltinHomonyms)
sub next {
    my ($self) = @_;

    # Return queued messages first
    return shift @{$self->_messages} if @{$self->_messages};

    # Wait for more messages or process to finish
    # Configurable timeout with 10 minute default, max 1 hour
    my $has_timeout = $self->options->has_query_timeout;
    my $timeout = $self->options->query_timeout // 600;
    my $max_timeout = 3600;  # 1 hour maximum
    if (!defined $timeout || $timeout <= 0 || $timeout > $max_timeout) {
        warn "Invalid query_timeout value ($timeout), using default 600 seconds\n"
            if $has_timeout && defined $timeout && $timeout != 600 && $ENV{CLAUDE_AGENT_DEBUG};
        $timeout = 600;
    }
    my $start_time = Time::HiRes::time();
    # Use epsilon tolerance (0.001s) to handle floating-point boundary conditions
    my $epsilon = 0.001;
    while (!@{$self->_messages} && !$self->_finished && !$self->_error
           && (Time::HiRes::time() - $start_time) < ($timeout - $epsilon)) {
        $self->_loop->loop_once(0.1);  # Longer interval to reduce CPU busy-waiting
    }

    # Check if we timed out waiting for messages
    # Use consistent comparison with epsilon tolerance to avoid boundary race
    if ((Time::HiRes::time() - $start_time) >= ($timeout - $epsilon)
        && !$self->_finished) {
        # Final check for messages that may have arrived at timeout boundary
        $self->_loop->loop_once(0) if !@{$self->_messages};
        return shift @{$self->_messages} if @{$self->_messages};
        $self->_finished(1);
        $self->_error("Query timed out after $timeout seconds");
        return;  # Return immediately on timeout
    }

    return shift @{$self->_messages};
}

=head2 next_async

    my $msg = await $query->next_async;

Async call to get the next message. Returns a Future that resolves when
a message is available. This is truly event-driven - no polling.

=cut

sub next_async {
    my ($self) = @_;

    # Return queued messages first (as an immediately-resolved Future)
    if (@{$self->_messages}) {
        return Future->done(shift @{$self->_messages});
    }

    # If already finished, return undef
    if ($self->_finished) {
        return Future->done(undef);
    }

    # Create a Future that will be resolved when next message arrives
    my $future = $self->_loop->new_future;
    push @{$self->_pending_futures}, $future;
    return $future;
}

=head2 session_id

    my $id = $query->session_id;

Returns the session ID once available (after init message).

=cut

sub session_id {
    my ($self) = @_;
    return $self->_session_id;
}

=head2 is_finished

    if ($query->is_finished) { ... }

Returns true if the query has finished (process exited).

=cut

sub is_finished {
    my ($self) = @_;
    return $self->_finished;
}

=head2 error

    if (my $err = $query->error) { ... }

Returns error message if the process failed.

=cut

sub error {
    my ($self) = @_;
    return $self->_error;
}

=head2 interrupt

    $query->interrupt;

Send interrupt signal to abort current operation.

=cut

sub interrupt {
    my ($self) = @_;

    return unless $self->_stdin && !$self->_finished;

    my $msg = $self->_jsonl->encode([{ type => 'interrupt' }]);
    return unless defined $msg && length $msg;
    $self->_stdin->write($msg);
    return;
}

=head2 send_user_message

    $query->send_user_message("Continue with the next step");

Send a follow-up user message during streaming.

=cut

sub send_user_message {
    my ($self, $content) = @_;

    return unless $self->_stdin && !$self->_finished;

    my $msg = $self->_jsonl->encode([{
        type    => 'user',
        message => {
            role    => 'user',
            content => $content,
        },
    }]);
    my $result;
    try {
        $result = $self->_stdin->write($msg);
    } catch {
        warn "send_user_message write error: $_" if $ENV{CLAUDE_AGENT_DEBUG};
    };
    return $result;
}

=head2 set_permission_mode

    $query->set_permission_mode('acceptEdits');

Change permission mode during streaming.

=cut

sub set_permission_mode {
    my ($self, $mode) = @_;

    return unless $self->_stdin && !$self->_finished;

    my $msg = $self->_jsonl->encode([{
        type            => 'set_permission_mode',
        permission_mode => $mode,
    }]);
    $self->_stdin->write($msg);
    return;
}

=head2 respond_to_permission

    $query->respond_to_permission($tool_use_id, {
        behavior      => 'allow',
        updated_input => $input,
    });

Respond to a permission request.

=cut

sub respond_to_permission {
    my ($self, $tool_use_id, $response) = @_;

    return unless $self->_stdin && !$self->_finished;

    my $msg = $self->_jsonl->encode([{
        type        => 'permission_response',
        tool_use_id => $tool_use_id,
        response    => $response,
    }]);
    $self->_stdin->write($msg);
    return;
}

=head2 rewind_files

    $query->rewind_files;

Revert file changes to the checkpoint state.

=cut

sub rewind_files {
    my ($self) = @_;

    return unless $self->_stdin && !$self->_finished;

    my $msg = $self->_jsonl->encode([{ type => 'rewind_files' }]);
    $self->_stdin->write($msg);
    return;
}

1;

__END__

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut
