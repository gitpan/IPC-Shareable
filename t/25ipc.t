BEGIN {
    $^W = 1;
    $| = 1;
    $SIG{INT} = sub { die };
    print "1..3\n";
}

use strict;
use Carp;
use IPC::Shareable;
my $t  = 1;
my $ok = 1;
my $sv;

my $pid = fork;
defined $pid or die "Cannot fork: $!";
if ($pid == 0) {
    # --- Child
    local $SIG{ALRM} = sub { 1 };
    sleep;
    tie($sv, 'IPC::Shareable', data => { destroy => 'no' })
	or undef $ok;

    $sv eq 'bar' or undef $ok;
    print $ok ? "ok $t\n" : "not ok $t\n";

    ++$t;
    $ok = 1;
    $sv = 'foo';
    $sv eq 'foo' or undef $ok;
    print $ok ? "ok $t\n" : "not ok $t\n";
    exit;
} else {
    # --- Parent
    tie($sv, 'IPC::Shareable', data => { create => 'yes', destroy => 'yes' })
	or undef $ok;
    $sv = 'bar';
    sleep 2;
    kill ALRM => $pid;
    waitpid($pid, 0);
    $sv eq 'foo' or undef $ok;
    $t += 2; # - Child performed two tests.
    print $ok ? "ok $t\n" : "not ok $t\n";
}

# --- Done!
exit;
