BEGIN {
    $^W = 1;
    $| = 1;
    $SIG{INT} = sub { die };
    print "1..9\n";
}

use strict;
use IPC::Shareable;
use IPC::SysV qw(IPC_PRIVATE SEM_UNDO IPC_RMID);
my $loaded = 1;
print "ok 1\n";

END {
    print "not ok 1\n" unless $loaded;
}

my $t  = 2;
my $ok = 1;

my $id = shmget(IPC_PRIVATE, 1024, 0666);
$ok = defined $id;
$ok or warn "shmget: $!";
print $ok ? "ok $t\n" : "not ok $t\n";

++$t;
my $var  = 'foobar';
my $copy = '';
$ok = shmwrite($id, $var, 0, length('foobar'));
$ok or warn "shmwrite: $!";
print $ok ? "ok $t\n" : "not ok $t\n";

++$t;
shmread($id, $copy, 0, length('foobar'));
$ok or warn "shmread: $!";
print $ok ? "ok $t\n" : "not ok $t\n";

++$t;
$ok = ($var eq $copy);
print $ok ? "ok $t\n" : "not ok $t\n";

++$t;
$ok = shmctl($id, IPC_RMID, 0);
$ok or warn "shmctl: $!";
print $ok ? "ok $t\n" : "not ok $t\n";

++$t;
$id = semget(IPC_PRIVATE, 1, 0666);
$ok = defined $id;
$ok or warn "semget: $!";
print $ok ? "ok $t\n" : "not ok $t\n";

++$t;
my $semop = pack('sss', 0, 1, SEM_UNDO);
$ok = semop($id, $semop);
$ok or warn "semop: $!";
print $ok ? "ok $t\n" : "not ok $t\n";

++$t;
$ok = semctl($id, 0, IPC_RMID, 0);
$ok or warn "semctl: $!";
print $ok ? "ok $t\n" : "not ok $t\n";
