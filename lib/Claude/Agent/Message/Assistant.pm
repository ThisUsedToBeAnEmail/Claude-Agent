package Claude::Agent::Message::Assistant;

use 5.020;
use strict;
use warnings;

use Types::Common -types;
use Claude::Agent::Content;
use Marlin
    -base => 'Claude::Agent::Message::Base',
    'message!' => HashRef,   # Contains role, content (with blocks)
    'model?'   => Str,       # Model that generated this response
    '_content_blocks_cache==.';  # Cached content block objects

=head1 NAME

Claude::Agent::Message::Assistant - Assistant message type

=head1 DESCRIPTION

Represents an assistant (Claude) message in the conversation.

=head2 ATTRIBUTES

=over 4

=item * type - Always 'assistant'

=item * uuid - Unique message identifier

=item * session_id - Session identifier

=item * message - HashRef with 'role' and 'content' (array of content blocks)

=item * model - The model that generated this response

=item * parent_tool_use_id - Optional, set if message is within a subagent

=back

=head2 METHODS

=head3 content_blocks

    my $blocks = $msg->content_blocks;

Returns arrayref of content blocks from the message.

=head3 text

    my $text = $msg->text;

Returns concatenated text content from all text blocks.

=head3 tool_uses

    my $uses = $msg->tool_uses;

Returns arrayref of tool_use blocks.

=cut

sub content_blocks {
    my ($self) = @_;

    # Return cached if available
    return $self->_content_blocks_cache if $self->_content_blocks_cache;

    my $raw = $self->message->{content} // [];

    # Convert hashrefs to Content objects
    my @blocks = map {
        ref($_) eq 'HASH'
            ? Claude::Agent::Content->from_json($_)
            : $_
    } @$raw;

    $self->_content_blocks_cache(\@blocks);
    return \@blocks;
}

sub text {
    my ($self) = @_;
    my @texts;
    for my $block (@{$self->content_blocks}) {
        if (ref($block) && $block->can('text') && $block->type eq 'text') {
            push @texts, $block->text;
        }
        elsif (ref($block) eq 'HASH' && $block->{type} eq 'text') {
            push @texts, $block->{text};
        }
    }
    return join("\n", @texts);
}

sub tool_uses {
    my ($self) = @_;
    return [
        grep {
            (ref($_) && $_->can('type') && $_->type eq 'tool_use')
            || (ref($_) eq 'HASH' && $_->{type} eq 'tool_use')
        } @{$self->content_blocks}
    ];
}

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut

1;
