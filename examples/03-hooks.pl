#!/usr/bin/env perl
#
# Hooks Example
#
# This example demonstrates how to use hooks to intercept
# and control tool usage during a conversation.
#

use 5.020;
use strict;
use warnings;

use lib 'lib';
use Claude::Agent qw(query);
use Claude::Agent::Options;
use Claude::Agent::Hook;
use Claude::Agent::Hook::Matcher;
use Claude::Agent::Hook::Result;

# Create a hook that logs all tool usage
my $logging_hook = Claude::Agent::Hook::Matcher->new(
    # No matcher = matches all tools
    hooks => [sub {
        my ($input, $tool_use_id, $context) = @_;

        my $tool_name = $input->{tool_name};
        say "[LOG] Tool called: $tool_name";

        # Continue without modification
        return Claude::Agent::Hook::Result->continue();
    }],
);

# Create a hook that blocks dangerous Bash commands
my $bash_guard = Claude::Agent::Hook::Matcher->new(
    matcher => 'Bash',
    hooks   => [sub {
        my ($input, $tool_use_id, $context) = @_;

        my $command = $input->{tool_input}{command} // '';

        # Block potentially dangerous commands
        if ($command =~ /rm\s+-rf|sudo|chmod\s+777|>\s*\//) {
            say "[BLOCKED] Dangerous command: $command";
            return Claude::Agent::Hook::Result->deny(
                reason => 'This command has been blocked for safety reasons.',
            );
        }

        # Allow safe commands
        return Claude::Agent::Hook::Result->continue();
    }],
);

# Create a hook that modifies file paths
my $path_rewriter = Claude::Agent::Hook::Matcher->new(
    matcher => 'Read',
    hooks   => [sub {
        my ($input, $tool_use_id, $context) = @_;

        my $file_path = $input->{tool_input}{file_path} // '';

        # Log the file being read
        say "[READ] Accessing: $file_path";

        # Could modify the path here if needed
        # return Claude::Agent::Hook::Result->allow(
        #     updated_input => { %{$input->{tool_input}}, file_path => $new_path },
        # );

        return Claude::Agent::Hook::Result->continue();
    }],
);

# Configure options with hooks
my $options = Claude::Agent::Options->new(
    allowed_tools   => ['Read', 'Glob', 'Grep', 'Bash'],
    permission_mode => 'bypassPermissions',
    max_turns       => 5,
    hooks           => {
        PreToolUse => [$logging_hook, $bash_guard, $path_rewriter],
    },
);

# Send a query
my $iter = query(
    prompt  => 'List the files in the current directory using ls command.',
    options => $options,
);

say "Sending query with hooks enabled...";
say "-" x 50;

while (my $msg = $iter->next) {
    if ($msg->isa('Claude::Agent::Message::Assistant')) {
        for my $block (@{$msg->content_blocks}) {
            if ($block->isa('Claude::Agent::Content::Text')) {
                print $block->text;
            }
        }
    }
    elsif ($msg->isa('Claude::Agent::Message::Result')) {
        say "\n", "-" x 50;
        say "Completed!";
        last;
    }
}
