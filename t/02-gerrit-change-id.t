install_hooks($repo, undef, qw/commit-msg/);
$repo->command(config => "githooks.commit-msg", 'GerritChangeId');