package Claude::Agent;

use 5.020;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(query tool create_sdk_mcp_server);

use Claude::Agent::Query;
use Claude::Agent::Options;
use Claude::Agent::Message;
use Claude::Agent::Content;
use Claude::Agent::Error;

=head1 NAME

Claude::Agent - Perl SDK for the Claude Agent SDK

=head1 VERSION

Version 0.02

=cut

our $VERSION = '0.02';

=head1 SYNOPSIS

    use Claude::Agent qw(query tool create_sdk_mcp_server);
    use Claude::Agent::Options;

    # Simple query
    my $options = Claude::Agent::Options->new(
        allowed_tools   => ['Read', 'Glob', 'Grep'],
        permission_mode => 'bypassPermissions',
    );

    my $iter = query(
        prompt  => "Find all TODO comments in the codebase",
        options => $options,
    );

    while (my $msg = $iter->next) {
        if ($msg->isa('Claude::Agent::Message::Result')) {
            print $msg->result, "\n";
            last;
        }
    }

    # Async iteration with IO::Async
    use IO::Async::Loop;
    use Future::AsyncAwait;

    my $loop = IO::Async::Loop->new;

    async sub run_agent {
        my ($loop) = @_;

        # Pass the loop for proper async integration
        my $iter = query(
            prompt  => "Analyze this codebase",
            options => Claude::Agent::Options->new(
                allowed_tools => ['Read', 'Glob', 'Grep'],
            ),
            loop => $loop,
        );

        while (my $msg = await $iter->next_async) {
            if ($msg->isa('Claude::Agent::Message::Result')) {
                print $msg->result, "\n";
                last;
            }
        }
    }

    run_agent($loop)->get;

=head1 DESCRIPTION

Claude::Agent is a Perl SDK for the Claude Agent SDK, providing programmatic
access to Claude's agentic capabilities. It allows you to build AI agents
that can read files, run commands, search the web, edit code, and more.

The SDK communicates with the Claude CLI and provides:

=over 4

=item * Streaming message iteration (blocking and async)

=item * Tool permission management

=item * Hook system for intercepting tool calls

=item * MCP (Model Context Protocol) server integration

=item * Subagent support for parallel task execution

=item * Session management (resume, fork)

=item * Structured output support

=back

=head1 EXPORTED FUNCTIONS

=head2 query

    my $iter = query(
        prompt  => $prompt,
        options => $options,
        loop    => $loop,      # optional, for async integration
    );

Creates a new query and returns an iterator for streaming messages.

=head3 Arguments

=over 4

=item * prompt - The prompt string to send to Claude

=item * options - A L<Claude::Agent::Options> object (optional)

=item * loop - An L<IO::Async::Loop> object (optional, for async integration)

=back

=head3 Returns

A L<Claude::Agent::Query> object that can be iterated to receive messages.

B<Note:> For proper async behavior, pass your application's IO::Async::Loop.
This allows multiple queries to share the same event loop.

=cut

sub query {
    my (%args) = @_;

    my $prompt = $args{prompt}
        or die "query() requires a 'prompt' argument";

    my $options = $args{options} // Claude::Agent::Options->new();

    return Claude::Agent::Query->new(
        prompt  => $prompt,
        options => $options,
        ($args{loop} ? (loop => $args{loop}) : ()),
    );
}

=head2 tool

    my $calc = tool(
        'calculate',
        'Perform mathematical calculations',
        { expression => { type => 'string' } },
        sub {
            my ($args) = @_;
            my $result = eval $args->{expression};
            return {
                content => [{ type => 'text', text => "Result: $result" }]
            };
        }
    );

Creates an MCP tool definition.

=head3 Arguments

=over 4

=item * name - Tool name

=item * description - Tool description

=item * input_schema - JSON Schema for tool input

=item * handler - Coderef that handles tool execution

=back

=head3 Returns

A L<Claude::Agent::MCP::ToolDefinition> object.

=cut

sub tool {
    my ($name, $description, $input_schema, $handler) = @_;

    require Claude::Agent::MCP;
    return Claude::Agent::MCP::ToolDefinition->new(
        name         => $name,
        description  => $description,
        input_schema => $input_schema,
        handler      => $handler,
    );
}

=head2 create_sdk_mcp_server

    my $server = create_sdk_mcp_server(
        name  => 'my-tools',
        tools => [$calc, $other_tool],
    );

Creates an SDK MCP server configuration.

=head3 Arguments

=over 4

=item * name - Server name

=item * tools - ArrayRef of tool definitions

=item * version - Server version (default: '1.0.0')

=back

=head3 Returns

A L<Claude::Agent::MCP::Server> object.

=cut

sub create_sdk_mcp_server {
    my (%args) = @_;

    require Claude::Agent::MCP;
    return Claude::Agent::MCP::Server->new(%args);
}

=head1 MESSAGE TYPES

Messages returned from query iteration are instances of:

=over 4

=item * L<Claude::Agent::Message::User> - User messages

=item * L<Claude::Agent::Message::Assistant> - Claude's responses

=item * L<Claude::Agent::Message::System> - System messages (init, status)

=item * L<Claude::Agent::Message::Result> - Final result

=back

See L<Claude::Agent::Message> for details.

=head1 CONTENT BLOCKS

Assistant messages contain content blocks:

=over 4

=item * L<Claude::Agent::Content::Text> - Text content

=item * L<Claude::Agent::Content::Thinking> - Thinking/reasoning

=item * L<Claude::Agent::Content::ToolUse> - Tool invocation

=item * L<Claude::Agent::Content::ToolResult> - Tool result

=back

See L<Claude::Agent::Content> for details.

=head1 SEE ALSO

=over 4

=item * L<Claude::Agent::Options> - Configuration options

=item * L<Claude::Agent::Query> - Query iterator

=item * L<Claude::Agent::Hook> - Hook system

=item * L<Claude::Agent::Permission> - Permission handling

=item * L<Claude::Agent::MCP> - MCP server integration

=item * L<Claude::Agent::Subagent> - Subagent definitions

=item * L<Claude::Agent::Client> - Persistent session client

=back

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 BUGS

Please report any bugs or feature requests to the GitHub issue tracker at
L<https://github.com/lnation/Claude-Agent/issues>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Claude::Agent

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut

1; # End of Claude::Agent
