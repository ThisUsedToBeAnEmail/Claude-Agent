#!/usr/bin/env perl
#
# Custom Tools Example
#
# This example demonstrates how to define custom MCP tools
# that can be passed to Claude. Note: SDK MCP servers require
# CLI support for in-process tool execution.
#
# For now, this example shows the tool definition pattern
# and uses standard built-in tools.
#

use 5.020;
use strict;
use warnings;

use lib 'lib';
use Claude::Agent qw(query tool create_sdk_mcp_server);
use Claude::Agent::Options;

# Demonstrate tool definition pattern (for future MCP SDK server support)
say "Tool Definition Examples:";
say "-" x 50;

# Create a calculator tool definition
my $calculator = tool(
    'calculate',
    'Perform mathematical calculations. Supports basic arithmetic.',
    {
        type       => 'object',
        properties => {
            expression => {
                type        => 'string',
                description => 'Mathematical expression to evaluate',
            },
        },
        required => ['expression'],
    },
    sub {
        my ($args) = @_;
        my $expr = $args->{expression};

        # Simple safe evaluation
        if ($expr =~ /^[\d\s\+\-\*\/\.\(\)]+$/) {
            my $result = eval $expr;
            return {
                content => [{ type => 'text', text => "Result: $result" }],
            };
        }
        return {
            content  => [{ type => 'text', text => "Invalid expression" }],
            is_error => 1,
        };
    }
);

say "Created tool: " . $calculator->name;
say "  Description: " . $calculator->description;

# Create an SDK MCP server (demonstrates the pattern)
my $server = create_sdk_mcp_server(
    name    => 'utilities',
    tools   => [$calculator],
    version => '1.0.0',
);

say "\nCreated MCP Server: " . $server->name;
say "  Tools: " . join(', ', @{$server->tool_names});
say "  Version: " . $server->version;

# For actual use, send a query with built-in tools
say "\n" . "-" x 50;
say "Running query with built-in tools...";
say "-" x 50;

my $options = Claude::Agent::Options->new(
    allowed_tools   => ['Glob', 'Grep'],
    permission_mode => 'bypassPermissions',
    max_turns       => 3,
);

my $iter = query(
    prompt  => 'Use Glob to find all .pm files in lib/Claude/Agent/Message/ directory.',
    options => $options,
);

while (my $msg = $iter->next) {
    if ($msg->isa('Claude::Agent::Message::Assistant')) {
        for my $block (@{$msg->content_blocks}) {
            if ($block->isa('Claude::Agent::Content::Text')) {
                print $block->text;
            }
            elsif ($block->isa('Claude::Agent::Content::ToolUse')) {
                say "\n[Using: " . $block->name . "]";
            }
        }
    }
    elsif ($msg->isa('Claude::Agent::Message::Result')) {
        say "\n", "-" x 50;
        say "Completed!";
        last;
    }
}
