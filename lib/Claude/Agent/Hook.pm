package Claude::Agent::Hook;

use 5.020;
use strict;
use warnings;

use Types::Common -types;

# Load subclasses
use Claude::Agent::Hook::Matcher;
use Claude::Agent::Hook::Context;
use Claude::Agent::Hook::Result;

=head1 NAME

Claude::Agent::Hook - Hook system for Claude Agent SDK

=head1 SYNOPSIS

    use Claude::Agent::Hook;
    use Claude::Agent::Options;

    my $options = Claude::Agent::Options->new(
        hooks => {
            PreToolUse => [
                Claude::Agent::Hook::Matcher->new(
                    matcher => 'Bash',
                    hooks   => [sub {
                        my ($input, $tool_use_id, $context) = @_;
                        my $command = $input->{tool_input}{command};
                        if ($command =~ /rm -rf/) {
                            return {
                                decision => 'deny',
                                reason   => 'Dangerous command blocked',
                            };
                        }
                        return { decision => 'continue' };
                    }],
                ),
            ],
        },
    );

=head1 DESCRIPTION

This module provides the hook system for intercepting and modifying
tool calls in the Claude Agent SDK.

=head1 HOOK EVENTS

=over 4

=item * PreToolUse - Before a tool is executed

=item * PostToolUse - After a tool completes successfully

=item * PostToolUseFailure - After a tool fails

=item * UserPromptSubmit - When a user prompt is submitted

=item * Stop - When the agent stops

=item * SubagentStart - When a subagent starts

=item * SubagentStop - When a subagent stops

=item * PreCompact - Before conversation compaction

=item * PermissionRequest - When permission is needed

=item * SessionStart - When a session starts

=item * SessionEnd - When a session ends

=item * Notification - For notifications

=back

=head1 HOOK CLASSES

=over 4

=item * L<Claude::Agent::Hook::Matcher> - Match tools and run callbacks

=item * L<Claude::Agent::Hook::Context> - Context passed to callbacks

=item * L<Claude::Agent::Hook::Result> - Factory for hook results

=back

=cut

# Hook event constants
use constant {
    PRE_TOOL_USE         => 'PreToolUse',
    POST_TOOL_USE        => 'PostToolUse',
    POST_TOOL_USE_FAIL   => 'PostToolUseFailure',
    USER_PROMPT_SUBMIT   => 'UserPromptSubmit',
    STOP                 => 'Stop',
    SUBAGENT_START       => 'SubagentStart',
    SUBAGENT_STOP        => 'SubagentStop',
    PRE_COMPACT          => 'PreCompact',
    PERMISSION_REQUEST   => 'PermissionRequest',
    SESSION_START        => 'SessionStart',
    SESSION_END          => 'SessionEnd',
    NOTIFICATION         => 'Notification',
};

our @EXPORT_OK = qw(
    PRE_TOOL_USE POST_TOOL_USE POST_TOOL_USE_FAIL
    USER_PROMPT_SUBMIT STOP SUBAGENT_START SUBAGENT_STOP
    PRE_COMPACT PERMISSION_REQUEST SESSION_START SESSION_END
    NOTIFICATION
);

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut

1;
