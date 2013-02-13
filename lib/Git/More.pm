package Git::More;
# ABSTRACT: A Git extension with some goodies for hook developers.

use strict;
use warnings;

BEGIN {
    # See http://git.661346.n2.nabble.com/better-way-to-find-Git-pm-officially-td7416362.html
    local @INC = @INC;
    unshift @INC, split(/:/, $ENV{GITPERLLIB}) if exists $ENV{GITPERLLIB};
    require Git;
}

use parent -norequire, 'Git';

use Error qw(:try);
use Carp;
use Git::Hooks qw/:utils/;

sub _compatibilize_config {
    my ($config) = @_;

    # Up to version 0.022 the plugins used flat names, such as
    # "check-acls.pl". These names were used as values for the
    # githooks.HOOK configuration variables and also as the name of
    # configuration sections specific of the plugins. In version 0.023
    # the three existing plugins (check-acls.pl, check-jira.pl, and
    # check-structure.pl) were converted to proper modules and renamed
    # to the usual CamelCase form of the names (i.e., CheckAcls.pm,
    # CheckJira.pm, and CheckStructure.pm). To preserve compatibility
    # with already configured hooks here we inject the old names in
    # the new names.

    foreach my $hook (qw/commit-msg pre-commit pre-receive post-receive update/) {
        if (exists $config->{githooks}{$hook}) {
            foreach (@{$config->{githooks}{$hook}}) {
                $_ = "Check\u$1" if /^check-(acls|jira|structure)(?:\.pl)?$/;
            }
        }
    }

    foreach my $name (
        ['check-acls'      => 'checkacls'],
        ['check-jira'      => 'checkjira'],
        ['check-structure' => 'checkstructure'],
    ) {
        if (exists $config->{$name->[0]}) {
            if (exists $config->{$name->[1]}) {
                die  __PACKAGE__, ": you have incompatible configuration sections: '$name->[0]' and '$name->[1]'.\n",
                    "Please, rename all variables from section '$name->[0]' to section '$name->[1]'.\n";
            } else {
                $config->{$name->[1]} = delete $config->{$name->[0]};
            }
        }
    }

    # Up to version 0.020 the configuration variables 'admin' and
    # 'userenv' were defined for the CheckAcls and CheckJira
    # plugins. In version 0.021 they were both "promoted" to the
    # Git::Hooks module, so that they can be used by any access
    # control plugin. In order to maintain compatibility with their
    # previous usage, here we virtually "inject" the variables in the
    # "githooks" configuration section if they are undefined there and
    # are defined in the plugin sections.

    foreach my $var (qw/admin userenv/) {
        next if exists $config->{githooks}{$var};
        foreach my $plugin (qw/checkacls checkjira/) {
            if (exists $config->{$plugin}{$var}) {
                $config->{githooks}{$var} = $config->{$plugin}{$var};
                next;
            }
        }
    }

    # Up to version 0.030 each plugin had its own configuration
    # section. From v0.031 on each plugin uses a subsection of the
    # "githooks" section for its configuration options. In order to
    # maintain compatibility we move the plugin's section variables to
    # its newer subsection location. But only for the plugins that
    # existed up to v0.030.

    foreach my $section (qw/checkacls checkjira checklog checkstructure gerritchangeid/) {
        next unless exists $config->{$section};
        if (exists $config->{"githooks.$section"}) {
            # If there already exists a subsection we consider this a
            # conflict and tell the user to fix it.
            die  __PACKAGE__, ": you have incompatible configuration sections: '$section' and 'githooks.$section'.\n",
                "Please, rename all variables from section '$section' to the subsection 'githooks.$section'.\n";
        } else {
            # Otherwise, we can simply turn the section into a subsection
            $config->{"githooks.$section"} = delete $config->{$section};
        }
    }

    # Up to v0.031 the plugins had to be hooked explicitly to the
    # hooks they implement by configuring the githooks.HOOK
    # options. From v0.032 on the plugins can hook themselves to any
    # hooks they want. The users have simply to tell which plugins
    # they are interested in by adding them to the githooks.plugin
    # option. Here we construct this option from the HOOK options if
    # it's not configured yet.

    unless (exists $config->{'githooks.plugin'}) {
        foreach my $hook (grep {exists $config->{githooks}{$_}} qw/commit-msg pre-commit pre-receive post-receive update/) {
            push @{$config->{githooks}{plugin}}, @{$config->{githooks}{$hook}};
        }
    }

    return;
}

sub get_config {
    my ($git, $section, $var) = @_;

    unless (exists $git->{more}{config}) {
        my %config;

        my $config = do {
           local $/ = "\c@";
           $git->command(config => '--null', '--list');
        };

        if (defined $config) {
            while ($config =~ /([^\cJ]+)\cJ([^\c@]*)\c@/sg) {
                my ($option, $value) = ($1, $2);
                if ($option =~ /(.+)\.(.+)/) {
                    push @{$config{lc $1}{lc $2}}, $value;
                } else {
                    die __PACKAGE__, ": Cannot grok config variable name '$option'.\n";
                }
            }
        }

        # Set default values for undefined ones.
        $config{githooks}{externals} //= [1];
        $config{githooksgerrit}{enabled} //= [1];

        _compatibilize_config(\%config);

        $git->{more}{config} = \%config;
    }

    my $config = $git->{more}{config};

    $section = lc $section if defined $section;

    if (! defined $section) {
        return $config;
    } elsif (! defined $var) {
        $config->{$section} = {} unless exists $config->{$section};
        return $config->{$section};
    } elsif (exists $config->{$section}{$var}) {
        return wantarray ? @{$config->{$section}{$var}} : $config->{$section}{$var}[-1];
    } else {
        return wantarray ? () : undef;
    }
}

sub cache {
    my ($git, $section) = @_;

    unless (exists $git->{more}{cache}{$section}) {
        $git->{more}{cache}{$section} = {};
    }

    return $git->{more}{cache}{$section};
}

sub clean_cache {
    my ($git, $section) = @_;
    delete $git->{more}{cache}{$section};
    return;
}

sub get_commits {
    my ($git, $old_commit, $new_commit) = @_;

    my @commits;

    local $/ = "\c@\cJ";
    my ($pipe, $ctx) = $git->command_output_pipe(
        'rev-list',
        # See 'git help rev-list' to understand the --pretty argument
        '--pretty=format:%H%n%T%n%P%n%aN%n%aE%n%ai%n%cN%n%cE%n%ci%n%s%n%n%b%x00',
        "$old_commit..$new_commit");

    while (<$pipe>) {
            my %commit;
            @commit{qw/header commit tree parent
                       author_name author_email author_date
                       commmitter_name committer_email committer_date
                       body/} = split "\cJ", $_, 11;
            push @commits, \%commit;
    }

    $git->command_close_pipe($pipe, $ctx);

    return @commits;
}

sub get_commit_msg {
    my ($git, $commit) = @_;

    # We want to use the %B format to grok the commit message, but it
    # was implemented only in Git v1.7.2. If we try to use it with
    # rev-list in previous Gits we get back the same format
    # unexpanded. In this case, we try the second best option which is
    # to use the format %s%n%n%b. The difference is that this format
    # unfolds the first sequence of non-empty lines in a single line
    # which is considered the message's subject (or title).
    foreach my $format (qw/%B %s%n%n%b/) {
        my $body = $git->command('rev-list' => "--format=$format", '--max-count=1', $commit);
        $body =~ s/^[^\n]*\n//; # strip first line, which contains the commit id
        chomp $body;            # strip last newline
        next if $body eq $format;
        return $body;
    }
    die __PACKAGE__, "::get_commit_msg: cannot get commit msg.\n";
}

sub get_diff_files {
    my ($git, @args) = @_;
    my %affected;
    foreach ($git->command(diff => '--name-status', @args)) {
        my ($status, $name) = split ' ', $_, 2;
        $affected{$name} = $status;
    }
    return \%affected;
}

sub set_affected_ref {
    my ($git, $ref, $old_commit, $new_commit) = @_;
    $git->{more}{affected_refs}{$ref}{range} = [$old_commit, $new_commit];
    return;
}

# internal method
sub _get_affected_refs_hash {
    my ($git) = @_;

    return $git->{more}{affected_refs}
        or die __PACKAGE__, ": get_affected_refs(): no affected refs set\n";
}

sub get_affected_refs {
    my ($git) = @_;

    return keys %{$git->_get_affected_refs_hash()};
}

sub get_affected_ref_range {
    my ($git, $ref) = @_;

    my $affected = $git->_get_affected_refs_hash();

    exists $affected->{$ref}{range}
        or die __PACKAGE__, ": get_affected_ref_range($ref): no such affected ref\n";

    return @{$affected->{$ref}{range}};
}

sub get_affected_ref_commit_ids {
    my ($git, $ref) = @_;

    my $affected = $git->_get_affected_refs_hash();

    exists $affected->{$ref}
        or die __PACKAGE__, ": get_affected_ref_commit_ids($ref): no such affected ref\n";

    unless (exists $affected->{$ref}{ids}) {
        my @range = $git->get_affected_ref_range($ref);
        $affected->{$ref}{ids} = [$git->command('rev-list' => join('..', @range))];
    }

    return @{$affected->{$ref}{ids}};
}

sub get_affected_ref_commits {
    my ($git, $ref) = @_;

    my $affected = $git->_get_affected_refs_hash();

    exists $affected->{$ref}
        or die __PACKAGE__, ": get_affected_ref_commits($ref): no such affected ref\n";

    unless (exists $affected->{$ref}{commits}) {
        $affected->{$ref}{commits} = [$git->get_commits($git->get_affected_ref_range($ref))];
    }

    return @{$affected->{$ref}{commits}};
}

sub set_authenticated_user {
    my ($git, $user) = @_;
    return $git->{more}{authenticated_user} = $user;
}

sub authenticated_user {
    my ($git) = @_;

    unless (exists $git->{more}{authenticated_user}) {
        if (my $userenv = $git->get_config(githooks => 'userenv')) {
            if ($userenv =~ /^eval:(.*)/) {
                $git->{more}{authenticated_user} = eval $1; ## no critic (BuiltinFunctions::ProhibitStringyEval)
                die __PACKAGE__, ": error evaluating userenv value ($userenv): $@\n"
                    if $@;
            } elsif (exists $ENV{$userenv}) {
                $git->{more}{authenticated_user} = $ENV{$userenv};
            } else {
                die __PACKAGE__, ": option userenv environment variable ($userenv) is not defined.\n";
            }
        } elsif (my $user = $ENV{USER}) {
            $git->{more}{authenticated_user} = $user;
        } else {
            $git->{more}{authenticated_user} = undef;
        }
    }

    return $git->{more}{authenticated_user};
}

sub get_current_branch {
    my ($git) = @_;
    foreach ($git->command(branch => '--no-color')) {
        return $1 if /^\* (.*)/;
    }
    return;
}

sub error {
    my ($git, $prefix, $message) = @_;
    my $fmtmsg = "\n[$prefix] $message";
    push @{$git->{more}{errors}}, "$fmtmsg\n";
    warn "$fmtmsg\n";
    return 1;
}

sub get_errors {
    my ($git) = @_;
    if (exists $git->{more}{errors}) {
        return @{$git->{more}{errors}};
    } else {
        return ();
    }
}


1; # End of Git::More
__END__

=head1 SYNOPSIS

    use Git::More;

    my $git = Git::More->repository();

    my $config  = $git->get_config();
    my $branch  = $git->get_current_branch();
    my $commits = $git->get_commits($oldcommit, $newcommit);
    my $message = $git->get_commit_msg('HEAD');

    my $files_modified_by_commit = $git->get_diff_files('--diff-filter=AM', '--cached');
    my $files_modified_by_push   = $git->get_diff_files('--diff-filter=AM', $oldcommit, $newcommit);

=head1 DESCRIPTION

This is an extension of the C<Git> class. It's meant to implement a
few extra methods commonly needed by Git hook developers.

In particular, it's used by the standard hooks implemented by the
C<Git::Hooks> framework.

Note that the Git module is distributed along with git and it's not on
CPAN yet. So, it's possible that C<Git::More> can't find it in the
default directories in @INC. You have to find it and make it available
to your Perl in order to install Git::Hooks and to use it. Here are a
few options to do that:

=over

=item * Move it to one of the directories already in @INC.

=item * Add the directory where you found it to the C<PERL5LIB>
environment variable.

=item * Add the directory where you found it to the C<GITPERLLIB>
environment variable. This method is arguably better than the previous
one because C<GITPERLLIB> is used specifically to find C<Git.pm>
whereas C<PERL5LIB> directories are used to find any required/used
module in your program.

=back

(If you have trouble finding Git.pm, here is a tip. There are some
Perl scripts distributed along with git that use C<Git.pm>. Take a
look at the C<git-svn> script which should be installed in the
directory returned by the C<git --exec-path> command. In it's second
line there is a mention to a directory where it looks for C<Git.pm>.)

=head1 METHODS

=head2 get_config [SECTION [VARIABLE]]

This method groks the configuration options for the repository by
invoking C<git config --list>. The configuration is cached during the
first invokation in the object C<Git::More> object. So, if the
configuration is changed afterwards, the method won't notice it. This
is usually ok for hooks, though.

With no arguments, the options are returned as a hash-ref pointing to
a two-level hash. For example, if the config options are these:

    section1.a=1
    section1.b=2
    section1.b=3
    section2.x.a=A
    section2.x.b=B
    section2.x.b=C

Then, it'll return this hash:

    {
        'section1' => {
            'a' => [1],
            'b' => [2, 3],
        },
        'section2.x' => {
            'a' => ['A'],
            'b' => ['B', 'C'],
        },
    }

The first level keys are the part of the option names before the last
dot. The second level keys are everything after the last dot in the
option names. You won't get more levels than two. In the example
above, you can see that the option "section2.x.a" is split in two:
"section2.x" in the first level and "a" in the second.

The values are always array-refs, even it there is only one value to a
specific option. For some options, it makes sense to have a list of
values attached to them. But even if you expect a single value to an
option you may have it defined in the global scope and redefined in
the local scope. In this case, it will appear as a two-element array,
the last one being the local value.

So, if you want to treat an option as single-valued, you should fetch
it like this:

    $h->{section1}{a}[-1]
    $h->{'section2.x'}{a}[-1]

If the SECTION argument is passed, the method returns the second-level
hash for it. So, following the example above, this call:

    $git->get_config('section1');

This call would return this hash:

    {
        'a' => [1],
        'b' => [2, 3],
    }

If the section don't exist an empty hash is returned. Any key/value
added to the returned hash will be available in subsequent invokations
of C<get_config>.

If the VARIABLE argument is also passed, the method returns the
value(s) of the configuration option C<SECTION.VARIABLE>. In list
context the method returns the list of all values or the empty list,
if the variable isn't defined. In scalar context, the method returns
the variable's last value or C<undef>, if it's not defined.

=head2 cache SECTION

This method may be used by plugin developers to cache information in
the context of a Git::More object. SECTION is a string (usually a
plugin name) that is associated with a hash-ref. The method simply
returns the hash-ref, which can be used by the caller to store any
kind of information.

=head2 clean_cache SECTION

This method deletes the cache entry for SECTION. It may be used by
hooks just before returning to B<Git::Hooks::run_hooks> in order to
get rid of any value kept in the SECTION's cache.

=head2 get_commits OLDCOMMIT NEWCOMMIT

This method returns a list of hashes representing every commit
reachable from NEWCOMMIT but not from OLDCOMMIT. It obtains this
information by invoking C<git rev-list OLDCOMIT..NEWCOMMIT>.

Each commit is represented by a hash with the following structure (the
codes are explained in the C<git help rev-list> document):

    {
        commit          => %H:  commit hash
        tree            => %T:  tree hash
        parent          => %P:  parent hashes (space separated)
        author_name     => %aN: author name
        author_email    => %aE: author email
        author_date     => %ai: author date in ISO8601 format
        commmitter_name => %cN: committer name
        committer_email => %cE: committer email
        committer_date  => %ci: committer date in ISO8601 format
        body            => %B:  raw body (aka commit message)
    }

=head2 get_commit_msg COMMIT_ID

This method returns the commit message (a.k.a. body) of the commit
identified by COMMIT_ID. The result is a string.

=head2 get_diff_files DIFFARGS...

This method invokes the command C<git diff --name-status> with extra
options and arguments as passed to it. It returns a reference to a
hash mapping every affected files to their affecting status. Its
purpose is to make it easy to grok the names of files affected by a
commit or a sequence of commits. Please, read C<git help diff> to know
everything about its options.

A common usage is to grok every file added or modified in a pre-commit
hook:

    my $hash_ref = $git->get_diff_files('--diff-filter=AM', '--cached');

Another one is to grok every file added or modified in a pre-receive
hook:

    my $hash_ref = $git->get_diff_files('--diff-filter=AM', $old_commit, $new_commit);

=head2 set_affected_ref REF OLDCOMMIT NEWCOMMIT

This method should be used in the beginning of an C<update>,
C<pre-receive>, or C<post-receive> hook in order to record the
references that were affected by the push command. The information
recorded will be later used by the following C<get_affected_ref*>
methods.

=head2 get_affected_refs

This method returns the list of names of references that were affected
by the current push command, as they were set by calls to the
C<set_affected_ref> method.

=head2 get_affected_ref_range(REF)

This method returns the two-element list of commit ids representing
the OLDCOMMIT and the NEWCOMMIT of the affected REF.

=head2 get_affected_ref_commit_ids(REF)

This method returns the list of commit ids leading from the affected
REF's NEWCOMMIT to OLDCOMMIT.

=head2 get_affected_ref_commits(REF)

This routine returns the list of commits leading from the affected
REF's NEWCOMMIT to OLDCOMMIT. The commits are represented by hashes,
as returned by the C<get_commits> method.

=head2 authenticated_user

This method returns the username of the authenticated user performing
the Git action. It groks it from the C<githooks.userenv> configuration
variable specification, which is described in the C<Git::Hooks>
documentation. It's useful for most access control check plugins.

=head2 set_authenticated_user USERNAME

This method can be used to set the username of the authenticated user
when the default heristics defined above aren't enough. The name will
be cached so that subsequent invokations of B<authenticated_user> will
return this.

=head2 get_current_branch

This method returns the repository's current branch name, as indicated
by the C<git branch> command. Note that it's a ref short name, i.e.,
it's usually sub-intended to reside under the 'refs/heads/' ref scope.

=head2 error PREFIX MESSAGE

This method should be used by plugins to produce consistent error or
warning messages. It gets two arguments: a PREFIX and the error
MESSAGE. The PREFIX is usually the plugin's package name.

The method simply produces the error message and returns. It doesn't
die.

=head1 SEE ALSO

C<Git>
