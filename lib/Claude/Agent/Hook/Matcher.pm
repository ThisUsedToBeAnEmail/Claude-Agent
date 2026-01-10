package Claude::Agent::Hook::Matcher;

use 5.020;
use strict;
use warnings;

use Types::Common -types;
use Marlin
    'matcher',                    # Regex pattern for tool names (optional)
    'hooks'   => sub { [] },      # ArrayRef of coderefs
    'timeout' => sub { 60 };      # Timeout in seconds

=head1 NAME

Claude::Agent::Hook::Matcher - Hook matcher for Claude Agent SDK

=head1 DESCRIPTION

Defines a hook matcher that triggers callbacks for specific tools.

=head2 ATTRIBUTES

=over 4

=item * matcher - Optional regex pattern to match tool names

=item * hooks - ArrayRef of callback coderefs

=item * timeout - Timeout in seconds (default: 60)

=back

=head2 CALLBACK SIGNATURE

    sub callback {
        my ($input_data, $tool_use_id, $context) = @_;

        # $input_data contains:
        # - tool_name: Name of the tool
        # - tool_input: Input parameters for the tool

        # $context contains:
        # - session_id: Current session ID
        # - cwd: Current working directory

        # Return hashref with decision:
        return {
            decision => 'continue',  # or 'allow', 'deny'
            reason   => 'Optional reason',
            # For 'allow', can include:
            updated_input => { ... },
        };
    }

=head2 METHODS

=head3 matches

    my $bool = $matcher->matches($tool_name);

Check if this matcher matches the given tool name.

=cut

sub matches {
    my ($self, $tool_name) = @_;

    # No matcher means match all
    return 1 unless defined $self->matcher;

    my $pattern = $self->matcher;

    # If it's a simple string, do exact match
    if ($pattern !~ /[.*+?\[\]{}|\\^$()]/) {
        return $tool_name eq $pattern;
    }

    # Otherwise treat as regex
    return $tool_name =~ /$pattern/;
}

=head3 run_hooks

    my $results = $matcher->run_hooks($input_data, $tool_use_id, $context);

Run all hooks and return their results.

=cut

sub run_hooks {
    my ($self, $input_data, $tool_use_id, $context) = @_;

    my @results;

    for my $hook (@{$self->hooks}) {
        my $result = eval { $hook->($input_data, $tool_use_id, $context) };
        if ($@) {
            push @results, {
                decision => 'error',
                error    => $@,
            };
        }
        else {
            push @results, $result // { decision => 'continue' };
        }

        # Stop if we got a definitive decision
        last if $result && $result->{decision}
            && $result->{decision} =~ /^(allow|deny)$/;
    }

    return \@results;
}

=head1 AUTHOR

LNATION, C<< <email at lnation.org> >>

=head1 LICENSE

This software is Copyright (c) 2026 by LNATION.

This is free software, licensed under The Artistic License 2.0 (GPL Compatible).

=cut

1;
