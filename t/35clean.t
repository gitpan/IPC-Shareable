BEGIN {
    $^W = 1;
    $| = 1;
    $SIG{INT} = sub { die };
    print "1..11\n";
}

use strict;
use Carp;
use IPC::Shareable;
use IPC::Shareable::SharedMem;
my $t  = 1;
my $ok = 1;

sub gonzo {
    # --- shmread should barf if the segment has really been cleaned
    my $id = shift;
    my $data = '';
    eval { shmread($id, $data, 0, 6) or die "$!" };
    return scalar($@ =~ /Invalid/ or $@ =~ /removed/);
}

# --- remove()
my $sv;
(my $s = tie $sv, 'IPC::Shareable', { destroy => 'no' })
    or undef $ok;
print $ok ? "ok $t\n" : "not ok $t\n";
$sv = 'foobar';

++$t;
# XXX Don't do the following: it's not part of the interface!
my $id = $s->{_shm}->id;
$s->remove;
$ok = gonzo($id);
print $ok ? "ok $t\n" : "not ok $t\n";

# --- remove(), clean_up(), clean_up_all()
++$t;
$ok = 1;
my $pid = fork;
defined $pid or die "Cannot fork : $!";
if ($pid == 0) {
    # --- Child
    local $SIG{ALRM} = sub { 1 };
    sleep;
    my $s = tie($sv, 'IPC::Shareable', 'hash', { destroy => 'no' })
	or undef $ok;
    print $ok ? "ok $t\n" : "not ok $t\n";

    $sv = 'foobar';

    ++$t;
    my $data = '';
    my $id = $s->{_shm}->id;
    IPC::Shareable->clean_up();
    $ok = shmread($id, $data, 0, length('IPC::Shareable'));
    print $ok ? "ok $t\n" : "not ok $t\n";

    ++$t;
    $ok = ($data eq 'IPC::Shareable');
    print $ok ? "ok $t\n" : "not ok $t\n";

    ++$t;
    $s->remove;
    $ok = gonzo($id);
    print $ok ? "ok $t\n" : "not ok $t\n";

    ++$t;
    tie($sv, 'IPC::Shareable', 'kids', { create => 'yes', destroy => 'no' })
      or undef $ok;
    print $ok ? "ok $t\n" : "not ok $t\n";
    $sv = 'the kid was here';

    exit;
} else {
    # --- Parent
    my $s = tie($sv, 'IPC::Shareable', 'hash', { create => 'yes', destroy => 'no' })
	or undef $ok;
    sleep 2;
    kill ALRM => $pid;
    my $id = $s->{_shm}->id;
    waitpid($pid, 0);

    +$t += 5; # - Child performed 4 tests
    $ok = gonzo($id);
    print $ok ? "ok $t\n" : "not ok $t\n";

}

++$t;
$s = tie($sv, 'IPC::Shareable', 'kids', { destroy => 'no' })
  or undef $ok;
print $ok ? "ok $t\n" : "not ok $t\n";
$id = $s->{_shm}->id;

++$t;
$ok = ($sv eq 'the kid was here');
print $ok ? "ok $t\n" : "not ok $t\n";

++$t;
IPC::Shareable->clean_up_all;
$ok = gonzo($id);
print $ok ? "ok $t\n" : "not ok $t\n";

# --- Done!
exit;
