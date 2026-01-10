package Claude::Agent::Query;

use 5.020;
use strict;
use warnings;

use Types::Common -types;
use Marlin
    'prompt!',                                     # Required prompt (string or async generator)
    'options' => sub { Claude::Agent::Options->new() },
    '_loop==.',                                    # IO::Async loop (rw, no init_arg)
    '_process==.',                                 # IO::Async::Process handle
    '_stdin==.',                                   # stdin pipe for sending messages
    '_messages==.' => sub { [] },                  # Message queue
    '_session_id==.',                              # Session ID from init message
    '_finished==.' => sub { 0 },                    # Process finished flag
    '_error==.',                                   # Error message if process failed
    '_jsonl==.' => sub {
        JSON::Lines->new(
            utf8     => 1,
            error_cb => sub {
                my ($action, $error, $data) = @_;
                warn "JSON::Lines $action error: $error" if $ENV{CLAUDE_AGENT_DEBUG};
                return undef;
            },
        )
    };

use IO::Async::Loop;
use IO::Async::Process;
use Future::AsyncAwait;
use JSON::Lines;
use Try::Tiny;
use File::Which qw(which);

use Claude::Agent::Options;
use Claude::Agent::Message;
use Claude::Agent::Error;

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

=cut

sub BUILD {
    my ($self) = @_;
    $self->_loop(IO::Async::Loop->new);
    $self->_start_process();
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
        "$ENV{HOME}/.local/bin/claude",
        "$ENV{HOME}/.npm-global/bin/claude",
    );

    for my $path (@paths) {
        return $path if -x $path;
    }

    Claude::Agent::Error::CLINotFound->throw(
        message => "Could not find 'claude' CLI in PATH or common locations"
    );
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

    # Add max turns if specified
    if ($opts->has_max_turns && $opts->max_turns) {
        push @cmd, '--max-turns', $opts->max_turns;
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
            push @cmd, '--system-prompt', $sp->{preset};
        }
        elsif (!ref $sp) {
            push @cmd, '--system-prompt', $sp;
        }
    }

    # Add MCP servers config
    if ($opts->has_mcp_servers && $opts->mcp_servers) {
        my %servers;
        for my $name (keys %{$opts->mcp_servers}) {
            my $server = $opts->mcp_servers->{$name};
            $servers{$name} = $server->can('to_hash') ? $server->to_hash : $server;
        }
        if (%servers) {
            require Cpanel::JSON::XS;
            push @cmd, '--mcp-config', Cpanel::JSON::XS::encode_json({ mcpServers => \%servers });
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
            require Cpanel::JSON::XS;
            push @cmd, '--agents', Cpanel::JSON::XS::encode_json(\%agents);
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
            require Cpanel::JSON::XS;
            push @cmd, '--json-schema', Cpanel::JSON::XS::encode_json($format->{schema});
        }
    }

    # For string prompts, use --print mode with -- separator
    if (!ref($self->prompt)) {
        push @cmd, '--print', '--', $self->prompt;
    }
    else {
        # For streaming input, use stream-json input format
        push @cmd, '--input-format', 'stream-json';
    }

    return @cmd;
}

sub _start_process {
    my ($self) = @_;

    my @cmd = $self->_build_command();

    warn "DEBUG: Running command: @cmd\n" if $ENV{CLAUDE_AGENT_DEBUG};

    my $process = IO::Async::Process->new(
        command => \@cmd,
        stdin  => { via => 'pipe_write' },
        stdout => {
            on_read => sub {
                my ($stream, $buffref) = @_;
                while ($$buffref =~ s/^(.+)\n//) {
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
                while ($$buffref =~ s/^(.+)\n//) {
                    warn "Claude CLI stderr: $1\n" if $ENV{CLAUDE_AGENT_DEBUG};
                }
                return 0;
            },
        },
        on_finish => sub {
            my ($proc, $exitcode) = @_;
            $self->_finished(1);
            if ($exitcode != 0) {
                $self->_error("Claude CLI exited with code $exitcode");
            }
        },
        on_exception => sub {
            my ($proc, $exception, $errno, $exitcode) = @_;
            $self->_finished(1);
            $self->_error("Claude CLI exception: $exception");
        },
    );

    $self->_loop->add($process);
    $self->_process($process);
    $self->_stdin($process->stdin);

    # For non-streaming (--print) mode, close stdin to signal we're done
    # This allows the CLI to start processing immediately
    if (!ref($self->prompt)) {
        $self->_stdin->close_when_empty;
    }
}

sub _handle_line {
    my ($self, $line) = @_;

    return unless defined $line && length $line;

    # Use JSON::Lines decode method for single line
    my @decoded = $self->_jsonl->decode($line);
    return unless @decoded;

    for my $data (@decoded) {
        next unless defined $data && ref $data eq 'HASH';

        my $msg = Claude::Agent::Message->from_json($data);

        # Capture session_id from init message
        if ($msg->isa('Claude::Agent::Message::System')
            && $msg->subtype eq 'init') {
            $self->_session_id($msg->get_session_id);
        }

        push @{$self->_messages}, $msg;
    }
}

=head2 next

    my $msg = $query->next;

Blocking call to get the next message. Returns undef when no more messages.

=cut

sub next {
    my ($self) = @_;

    # Return queued messages first
    return shift @{$self->_messages} if @{$self->_messages};

    # Wait for more messages or process to finish
    while (!@{$self->_messages} && !$self->_finished) {
        $self->_loop->loop_once(0.01);
    }

    return shift @{$self->_messages};
}

=head2 next_async

    my $msg = await $query->next_async;

Async call to get the next message. Returns a Future.

=cut

async sub next_async {
    my ($self) = @_;

    # Return queued messages first
    return shift @{$self->_messages} if @{$self->_messages};

    # Wait for more messages or process to finish
    while (!@{$self->_messages} && !$self->_finished) {
        await $self->_loop->delay_future(after => 0.01);
    }

    return shift @{$self->_messages};
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

    return unless $self->_stdin;

    my $msg = $self->_jsonl->encode([{ type => 'interrupt' }]);
    $self->_stdin->write($msg);
}

=head2 send_user_message

    $query->send_user_message("Continue with the next step");

Send a follow-up user message during streaming.

=cut

sub send_user_message {
    my ($self, $content) = @_;

    return unless $self->_stdin;

    my $msg = $self->_jsonl->encode([{
        type    => 'user',
        message => {
            role    => 'user',
            content => $content,
        },
    }]);
    $self->_stdin->write($msg);
}

=head2 set_permission_mode

    $query->set_permission_mode('acceptEdits');

Change permission mode during streaming.

=cut

sub set_permission_mode {
    my ($self, $mode) = @_;

    return unless $self->_stdin;

    my $msg = $self->_jsonl->encode([{
        type            => 'set_permission_mode',
        permission_mode => $mode,
    }]);
    $self->_stdin->write($msg);
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

    return unless $self->_stdin;

    my $msg = $self->_jsonl->encode([{
        type        => 'permission_response',
        tool_use_id => $tool_use_id,
        response    => $response,
    }]);
    $self->_stdin->write($msg);
}

=head2 rewind_files

    $query->rewind_files;

Revert file changes to the checkpoint state.

=cut

sub rewind_files {
    my ($self) = @_;

    return unless $self->_stdin;

    my $msg = $self->_jsonl->encode([{ type => 'rewind_files' }]);
    $self->_stdin->write($msg);
}

1;

__END__

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut
