package Claude::Agent::Message;

use 5.020;
use strict;
use warnings;

use Types::Common -types;

# Load subclasses
use Claude::Agent::Message::Base;
use Claude::Agent::Message::User;
use Claude::Agent::Message::Assistant;
use Claude::Agent::Message::System;
use Claude::Agent::Message::Result;

=head1 NAME

Claude::Agent::Message - Message types for Claude Agent SDK

=head1 SYNOPSIS

    use Claude::Agent::Message;

    # Messages are returned from query iteration
    while (my $msg = $iter->next) {
        if ($msg->isa('Claude::Agent::Message::Result')) {
            print $msg->result, "\n";
        }
    }

=head1 DESCRIPTION

This module contains all message types returned by the Claude Agent SDK.

=head1 MESSAGE TYPES

=over 4

=item * L<Claude::Agent::Message::User> - User messages

=item * L<Claude::Agent::Message::Assistant> - Claude's responses

=item * L<Claude::Agent::Message::System> - System messages (init, status)

=item * L<Claude::Agent::Message::Result> - Final result

=back

=head1 METHODS

=head2 from_json

    my $msg = Claude::Agent::Message->from_json($data);

Factory method to create the appropriate message type from JSON data.

=cut

# Map camelCase JSON keys to snake_case Perl attributes
sub _normalize_data {
    my ($data) = @_;

    my %normalized = %$data;

    # Map common camelCase keys to snake_case
    $normalized{session_id} = delete $normalized{sessionId} if exists $normalized{sessionId};
    $normalized{parent_tool_use_id} = delete $normalized{parentToolUseId} if exists $normalized{parentToolUseId};
    $normalized{duration_ms} = delete $normalized{durationMs} if exists $normalized{durationMs};
    $normalized{num_turns} = delete $normalized{numTurns} if exists $normalized{numTurns};
    $normalized{total_cost_usd} = delete $normalized{totalCostUsd} if exists $normalized{totalCostUsd};
    $normalized{is_error} = delete $normalized{isError} if exists $normalized{isError};

    # System message specific fields
    $normalized{slash_commands} = delete $normalized{slashCommands} if exists $normalized{slashCommands};
    $normalized{claude_code_version} = delete $normalized{claudeCodeVersion} if exists $normalized{claudeCodeVersion};
    $normalized{output_style} = delete $normalized{outputStyle} if exists $normalized{outputStyle};
    $normalized{api_key_source} = delete $normalized{apiKeySource} if exists $normalized{apiKeySource};
    $normalized{permission_mode} = delete $normalized{permissionMode} if exists $normalized{permissionMode};
    $normalized{mcp_servers} = delete $normalized{mcpServers} if exists $normalized{mcpServers};

    # Result message specific fields
    $normalized{duration_api_ms} = delete $normalized{durationApiMs} if exists $normalized{durationApiMs};
    $normalized{model_usage} = delete $normalized{modelUsage} if exists $normalized{modelUsage};
    $normalized{permission_denials} = delete $normalized{permissionDenials} if exists $normalized{permissionDenials};
    $normalized{tool_use_result} = delete $normalized{toolUseResult} if exists $normalized{toolUseResult};
    $normalized{structured_output} = delete $normalized{structuredOutput} if exists $normalized{structuredOutput};

    return \%normalized;
}

sub from_json {
    my ($class, $data) = @_;

    my $normalized = _normalize_data($data);
    my $type = $normalized->{type} // '';

    if ($type eq 'user') {
        return Claude::Agent::Message::User->new(%$normalized);
    }
    elsif ($type eq 'assistant') {
        return Claude::Agent::Message::Assistant->new(%$normalized);
    }
    elsif ($type eq 'system') {
        return Claude::Agent::Message::System->new(%$normalized);
    }
    elsif ($type eq 'result') {
        return Claude::Agent::Message::Result->new(%$normalized);
    }
    else {
        # Return generic message for unknown types
        return Claude::Agent::Message::Base->new(%$normalized);
    }
}

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut

1;
