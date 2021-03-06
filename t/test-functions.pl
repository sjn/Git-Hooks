# Copyright (C) 2012 by CPqD

use 5.010;
use strict;
use warnings;
use Config;
use File::Remove 'remove';
use File::Slurp;
use File::Spec::Functions qw/catdir catfile/;
use File::Temp 'tempdir';
use File::pushd;
use URI::file;

# The distribution's Makefile.PL might have created a GITPERLLIB file
# inside the test directory if it detected that we can't find Git with
# the default @INC.

BEGIN {
    if (my $gitperllib = read_file(catfile(qw/t GITPERLLIB/), err_mode => 'quiet')) {
        chomp($ENV{GITPERLLIB} = $gitperllib);
    }
    eval { require Git::More }
      or BAIL_OUT("Can't require Git::More: $@");
};

# use Error after Git::More to use the same module distributed along with Git
use Error qw':try';

# Make sure the git messages come in English.
$ENV{LC_MESSAGES} = 'C';

# It's better to perform all tests in a temporary directory because
# otherwise the author runs the risk of messing with its local
# Git::Hooks git repository.

our $T = tempdir('githooks.XXXXX', TMPDIR => 1, CLEANUP => $ENV{REPO_CLEANUP} || 1);
use Cwd; our $cwd = cwd;
chdir $T or die "Can't chdir $T: $!";
END { chdir '/' }

our $git_version;
try {
    $git_version = Git::command_oneline('version');
} otherwise {
    $git_version = 'unknown';
};

sub newdir {
    my $num = 1 + Test::Builder->new()->current_test();
    my $dir = catdir($T, $num);
    mkdir $dir;
    $dir;
}

sub install_hooks {
    my ($git, $extra_perl, @hooks) = @_;
    my $hooks_dir = catfile($git->repo_path(), 'hooks');
    my $hook_pl   = catfile($hooks_dir, 'hook.pl');
    {
	open my $fh, '>', $hook_pl or BAIL_OUT("Can't create $hook_pl: $!");
	state $debug = $ENV{DBG} ? '-d' : '';
	state $bliblib = catdir($cwd, 'blib', 'lib');
	print $fh <<EOF;
#!$Config{perlpath} $debug
use strict;
use warnings;
use lib '$bliblib';
EOF

	state $pathsep = $^O eq 'MSWin32' ? ';' : ':';
	if (defined $ENV{PERL5LIB} and length $ENV{PERL5LIB}) {
	    foreach my $path (reverse split "$pathsep", $ENV{PERL5LIB}) {
		say $fh "use lib '$path';" if $path;
	    }
	}

        if (my $gitperllib = $ENV{GITPERLLIB}) {
            say $fh "BEGIN { \$ENV{GITPERLLIB} = '$ENV{GITPERLLIB}' };";
        }

	print $fh <<EOF;
use Git::Hooks;
EOF

	print $fh $extra_perl if defined $extra_perl;

        # Not all hooks defined the GIT_DIR environment variable
        # (e.g., pre-rebase doesn't).
	print $fh <<"EOF";
\$ENV{GIT_DIR}    = '.git' unless exists \$ENV{GIT_DIR};
\$ENV{GIT_CONFIG} = "\$ENV{GIT_DIR}/config";
EOF

        # Hooks on Windows are invoked indirectly.
        if ($^O eq 'MSWin32') {
            print $fh <<"EOF";
my \$hook = shift;
run_hook(\$hook, \@ARGV);
EOF
        } else {
            print $fh <<"EOF";
run_hook(\$0, \@ARGV);
EOF
        }
    }
	    chmod 0755 => $hook_pl;

    @hooks = qw/ applypatch-msg pre-applypatch post-applypatch
		 pre-commit prepare-commit-msg commit-msg
		 post-commit pre-rebase post-checkout post-merge
		 pre-receive update post-receive post-update
		 pre-auto-gc post-rewrite /
                     unless @hooks;

    foreach my $hook (@hooks) {
	my $hookfile = catfile($hooks_dir, $hook);
	if ($^O eq 'MSWin32') {
            (my $perl = $^X) =~ tr:\\:/:;
            $hook_pl =~ tr:\\:/:;
            my $d = $ENV{DBG} ? '-d' : '';
            my $script = <<"EOF";
#!/bin/sh
$perl $d $hook_pl $hook \"\$@\"
EOF
            write_file($hookfile, {err_mode => 'carp'}, $script)
                or BAIL_OUT("can't write_file('$hookfile', '$script')\n");
	    chmod 0755 => $hookfile;
	} else {
            symlink 'hook.pl', $hookfile
                or BAIL_OUT("can't symlink '$hooks_dir', '$hook': $!");
        }
    }
}

sub new_repos {
    my $repodir  = catfile($T, 'repo');
    my $filename = catfile($repodir, 'file.txt');
    my $clonedir = catfile($T, 'clone');

    # Remove the directories recursively to create new ones.
    remove(\1, $repodir, $clonedir);

    mkdir $repodir, 0777 or BAIL_OUT("can't mkdir $repodir: $!");
    {
	open my $fh, '>', $filename or die BAIL_OUT("can't open $filename: $!");
	say $fh "first line";
    }

    try {
	my ($repo, $clone);

        {
	    # It would be easier to pass a directory argument to
	    # git-init but it started to accept it only on v1.6.5. To
	    # support previous gits we chdir to $repodir to avoid the
	    # need to pass the argument. Then we have to go back to
	    # where we were.
            my $dir = pushd($repodir);
            Git::command(qw/init -q/);

	    $repo = Git::More->repository(Directory => '.');

	    $repo->command(config => 'user.mail', 'myself@example.com');
	    $repo->command(config => 'user.name', 'My Self');
	    $repo->command(add    => $filename);
	    $repo->command(commit => '-mx');
	}

        Git::command(qw/clone -q --bare --no-hardlinks/, $repodir, $clonedir);

	$clone = Git::More->repository(Repository => $clonedir);

        $repo->command(qw/remote add clone/, $clonedir);

	return ($repo, $filename, $clone, $T);
    } otherwise {
        my $E = shift;
        # The BAIL_OUT function can't show a message with newlines
        # inside. So, we have to make sure to get rid of any.
        $E =~ s/\n//g;          # 
        local $, = ':';
	BAIL_OUT("Error setting up repos for test: Exception='$_[0]'; CWD=$T; git-version=$git_version; \@INC=(@INC).\n");
    };
}

sub new_commit {
    my ($git, $file, $msg) = @_;

    append_file($file, $msg || 'new commit');

    $git->command(add => $file);
    $git->command(commit => '-q', '-m', $msg || 'commit');
}


# Executes a git command with arguments and return a four-elements
# list containing: (a) a boolean indication of success, (b) the exit
# code, (c) the command's STDOUT, and (d) the command's STDERR.
sub test_command {
    my ($git, $cmd, @args) = @_;

    # Redirect STDERR to a temporary file
    open my $oldstderr, '>&', \*STDERR
        or die "Can't dup STDERR: $!";
    open STDERR, '>', 'stderr'
        or die "Can't redirect STDERR to temporary directory: $!";

    my ($stdout, $exception);

    try {
	$stdout = $git->command($cmd, @args);
	$stdout = '' unless defined $stdout;
    } otherwise {
	$exception = "$_[0]";	# stringify the exception
    };

    # Redirect STDERR back to its original value
    open STDERR, '>&', $oldstderr
        or die "Can't redirect STDERR back to its original value: $!";

    # Grok the subcomand's STDERR
    my $stderr = read_file('stderr');

    if (defined $exception) {
	return (0, $?, $exception, $stderr);
    } else {
	return (1, 0, $stdout, $stderr);
    }
}

sub test_ok {
    my ($testname, @args) = @_;
    my ($ok, $exit, $stdout, $stderr) = test_command(@args);
    if ($ok) {
	pass($testname);
    } else {
	fail($testname);
	diag(" exit=$exit\n stdout=$stdout\n stderr=$stderr\n git-version=$git_version\n");
    }
    return $ok;
}

sub test_ok_match {
    my ($testname, $regex, @args) = @_;
    my ($ok, $exit, $stdout, $stderr) = test_command(@args);
    if ($ok) {
        if ($stdout =~ $regex || $stderr =~ $regex) {
            pass($testname);
        } else {
            fail($testname);
            diag(" did not match regex ($regex)\n stdout=$stdout\n stderr=$stderr\n git-version=$git_version\n");
        }
    } else {
	fail($testname);
	diag(" exit=$exit\n stdout=$stdout\n stderr=$stderr\n git-version=$git_version\n");
    }
    return $ok;
}

sub test_nok {
    my ($testname, @args) = @_;
    my ($ok, $exit, $stdout, $stderr) = test_command(@args);
    if ($ok) {
	fail($testname);
	diag(" succeeded without intention\n stdout=$stdout\n stderr=$stderr\n git-version=$git_version\n");
    } else {
	pass($testname);
    }
    return !$ok;
}

sub test_nok_match {
    my ($testname, $regex, @args) = @_;
    my ($ok, $exit, $stdout, $stderr) = test_command(@args);
    if ($ok) {
	fail($testname);
	diag(" succeeded without intention\n exit=$exit\n stdout=$stdout\n stderr=$stderr\n git-version=$git_version\n");
	return 0;
    } elsif ($stdout =~ $regex || $stderr =~ $regex) {
	pass($testname);
	return 1;
    } else {
	fail($testname);
	diag(" did not match regex ($regex)\n exit=$exit\n stdout=$stdout\n stderr=$stderr\n git-version=$git_version\n");
	return 0;
    }
}

1;
