package IPC::Shareable;

require 5.00503;
use strict;
use IPC::Semaphore;
use IPC::Shareable::SharedMem;
use IPC::SysV qw(
                 IPC_PRIVATE
                 IPC_CREAT
                 IPC_EXCL
                 SEM_UNDO
                 );
use Storable 0.6 qw(
                    freeze
                    thaw
                    );

use vars qw($VERSION);
$VERSION = do { my @r=(q$Revision 0.50 $ =~ /\d+/g); sprintf "%d."."%02d"x$#r,@r };

use constant DEBUGGING     => ($ENV{SHAREABLE_DEBUG} or 0);
use constant SHM_BUFSIZ    =>  65536;
use constant SEM_LOCKER    =>  0;
use constant SEM_MARKER    =>  1;
use constant SHM_LOCK_WAIT =>  0;
use constant SHM_LOCK_EX   =>  1;
use constant SHM_LOCK_UN   => -1;
use constant SHM_EXISTS    =>  1;

my %Def_Opts = (
                key       => '',
                create    => '',
                exclusive => '',
                destroy   => '',
                mode      => 0666,
                size      => SHM_BUFSIZ,
                );

# XXX Perl seems to garbage collect nested referents before we're done with them
# XXX This cache holds a reference to things until END() is called

my %Global_Reg;
my %Proc_Reg;

sub _trace;
sub _debug;

###############################################################################
                                                                 # Debug mark

# --- Public methods
sub shlock {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;

    return 1 if $self->{_lock};

    my $sem = $self->{_sem};
    _debug "Attempting lock on", $self->{_shm}, "via", $sem->id  if DEBUGGING;
    $sem->op(SEM_LOCKER, SHM_LOCK_WAIT, SEM_UNDO,
             SEM_LOCKER, SHM_LOCK_EX,   SEM_UNDO);
    $self->{_lock} = 'lock';
    _debug "Got lock on", $self->{_shm}, "via", $sem->id         if DEBUGGING;

    1;
}

sub shunlock {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;

    return 1 unless $self->{_lock};

    my $sem = $self->{_sem};
    _debug "Freeing lock on", $self->{_shm}, "via", $sem->id     if DEBUGGING;
    $sem->op(SEM_LOCKER, SHM_LOCK_UN, SEM_UNDO);
    $self->{_lock} = '';
    _debug "Lock on", $self->{_shm}, "via", $sem->id, "freed"    if DEBUGGING;

    1;
}

# --- "Magic" methods
sub TIESCALAR {
    _trace @_                                                    if DEBUGGING;
    return _tie(SCALAR => @_);
}

sub TIEARRAY {
    _trace @_                                                    if DEBUGGING;
    return _tie(ARRAY => @_);
}    

sub TIEHASH {
    _trace @_                                                    if DEBUGGING;
    return _tie(HASH => @_);
}

sub STORE {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;

    my $sid = $self->{_shm}->{_id};

    $Global_Reg{$self->{_shm}->id} ||= $self;

  TYPE: {
      if ($self->{_type} eq 'SCALAR') {
          my $val = shift;
          _mg_tie($self => $val) if _need_tie($val);
          $self->{_data} = \$val;
          last TYPE;
      }
      if ($self->{_type} eq 'ARRAY') {
          my $i   = shift;
          my $val = shift;
          _mg_tie($self => $val) if _need_tie($val);
          $self->{_data}->[$i] = $val;
          last TYPE;
      }   
      if ($self->{_type} eq 'HASH') {
          my $key = shift;
          my $val = shift;
          _mg_tie($self => $val) if _need_tie($val);
          $self->{_data}->{$key} = $val;
          last TYPE;
      }
      require Carp;
      Carp::croak "Variables of type $self->{_type} not supported";
  }

    defined _freeze($self->{_shm} => $self->{_data}) or do {
        require Carp;
        Carp::croak "Could not write to shared memory: $!\n";
    };

    return 1;
}

sub FETCH {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;

    $Global_Reg{$self->{_shm}->id} ||= $self;

    my $data;
    if ($self->{_iterating}) {
        $data = $self->{_data};
    } else {
        $data = _thaw($self->{_shm});
        $self->{_data} = $data;
    }

    my $val;
  TYPE: {
      if ($self->{_type} eq 'SCALAR') {
          if (defined $data) {
              $val = $$data;
              last TYPE;
          } else {
              return;
          }
      }
      if ($self->{_type} eq 'ARRAY') {
          if (defined $data) {
              my $i = shift;
              $val = $data->[$i];
              last TYPE;
          } else {
              return;
          }
      }
      if ($self->{_type} eq 'HASH') {
          if (defined $data) {
              my $key = shift;
              $val = $data->{$key};
              last TYPE;
          } else {
              return;
          }
      }
      require Carp;
      Carp::croak "Variables of type $self->{_type} not supported";
  }

    if (my $inner = _is_kid($val)) {
        my $s = $inner->{_shm};
        $inner->{_data} = _thaw($s);
    }
    return $val;

}

sub CLEAR {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;

    if ($self->{_type} eq 'ARRAY') {
        $self->{_data} = [ ];
    } elsif ($self->{_type} eq 'HASH') {
        $self->{_data} = { };
    } else {
        require Carp;
        Carp::croak "Attempt to clear non-aggegrate";
    }

    defined _freeze($self->{_shm} => $self->{_data}) or do {
        require Carp;
        Carp::croak "Could not write to shared memory: $!";
    };
}

sub DELETE {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;
    my $key  = shift;

    my $val = delete $self->{_data}->{$key};
    defined _freeze($self->{_shm} => $self->{_data}) or do {
        require Carp;
        Carp::croak "Could not write to shared memory: $!";
    };

    return $val;
}

sub EXISTS {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;
    my $key  = shift;

    $self->{_data} = _thaw($self->{_shm});
    return exists $self->{_data}->{$key};
}

sub FIRSTKEY {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;
    my $key  = shift;

    _debug "setting hash iterator on", $self->{_shm}->id         if DEBUGGING;
    $self->{_iterating} = 1;
    $self->{_data} = _thaw($self->{_shm});
    my $reset = keys %{$self->{_data}};
    my $first = each %{$self->{_data}};
    return $first;
}

sub NEXTKEY {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;

    # XXX Don't _thaw since we're iterating?
    my $next = each %{$self->{_data}};
    if (not defined $next) {
        _debug "resetting hash iterator on", $self->{_shm}->id   if DEBUGGING;
        $self->{_iterating} = '';
        defined _freeze($self->{_shm} => $self->{_data}) or do {
            require Carp;
            Carp::croak "Could not write to shared memory: $!";
        };
        return;
    } else {
        return $next;
    }
}

sub EXTEND {
    _trace @_                                                    if DEBUGGING;
    #XXX Noop
}

sub PUSH {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;

    push @{$self->{_data}} => @_;
    defined _freeze($self->{_shm} => $self->{_data}) or do {
        require Carp;
        Carp::croak "Could not write to shared memory: $!";
    };
}

sub POP {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;

    my $val = pop @{$self->{_data}};
    defined _freeze($self->{_shm} => $self->{_data}) or do {
        require Carp;
        Carp::croak "Could not write to shared memory: $!";
    };
    return $val;
}

sub SHIFT {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;

    my $val = shift @{$self->{_data}};
    defined _freeze($self->{_shm} => $self->{_data}) or do {
        require Carp;
        Carp::croak "Could not write to shared memory: $!";
    };
    return $val;
}

sub UNSHIFT {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;

    unshift @{$self->{_data}} => @_;
    defined _freeze($self->{_shm} => $self->{_data}) or do {
        require Carp;
        Carp::croak "Could not write to shared memory: $!";
    };
}

sub SPLICE {
    _trace @_                                                    if DEBUGGING;
    my($self, $off, $n, @av) = @_;

    my @val = splice @{$self->{_data}}, $off, $n => @av;
    defined _freeze($self->{_shm} => $self->{_data}) or do {
        require Carp;
        Carp::croak "Could not write to shared memory: $!";
    };
    return @val;
}

sub FETCHSIZE {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;

    my $data = _thaw($self->{_shm});
    $self->{_data} = $data;
    return scalar(@{$self->{_data}});
}

sub STORESIZE {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;
    my $n    = shift;

    $#{@{$self->{_data}}} = $n - 1;
    defined _freeze($self->{_shm} => $self->{_data}) or do {
        require Carp;
        Carp::croak "Could not write to shared memory: $!";
    };
}

sub clean_up {
    _trace @_                                                    if DEBUGGING;
    my $class = shift;

    for my $s (values %Proc_Reg) {
        next unless $s->{_opts}->{_owner} == $$;
        remove($s);
    }
}

sub clean_up_all {
    _trace @_                                                    if DEBUGGING;
    my $class = shift;

    for my $s (values %Global_Reg) {
        remove($s);
    }
}

sub remove {
    _trace @_                                                    if DEBUGGING;
    my $self = shift;

    my $s = $self->{_shm};
    my $id = $s->id;
    
    $s->remove or do {
        require Carp;
        Carp::carp "Couldn't remove shared memory segment $id: $!";
    };
    
    $s = $self->{_sem};
    $s->remove or do {
        require Carp;
        Carp::carp "Couldn't remove semaphore set $id: $!";
    };
    delete $Proc_Reg{$id};
    delete $Global_Reg{$id};
}

END {
    _trace @_                                                    if DEBUGGING;
    for my $s (values %Proc_Reg) {
        shunlock($s);
        next unless $s->{_opts}->{destroy} and
                    $s->{_opts}->{destroy} ne 'no';
        next unless $s->{_opts}->{_owner} == $$;
        remove($s);
    }
}

# --- Private methods below
sub _freeze {
    _trace @_                                                    if DEBUGGING;
    my $s  = shift;
    my $water = shift;

    my $ice = freeze $water;
    my $stuff = 'IPC::Shareable' . $ice;
    _debug "writing to shared memory", $stuff                    if DEBUGGING;
    $s->shmwrite($stuff);
}

sub _thaw {
    _trace @_                                                    if DEBUGGING;
    my $s = shift;

    my $stuff = $s->shmread;
    _debug "read from shared memory", $stuff                     if DEBUGGING;
    my($tag, $ice) = unpack 'A14 A*' => $stuff;
    if ($tag eq 'IPC::Shareable') {
        my $water = thaw $ice;
        return $water;
    } else {
        return;
    }
}

sub _tie {
    _trace @_                                                    if DEBUGGING;
    my $type  = shift;
    my $class = shift;
    my $opts  = _parse_args(@_);

    my $key      = _shm_key($opts);
    my $flags    = _shm_flags($opts);
    my $shm_size = $opts->{size};

    my $s = IPC::Shareable::SharedMem->new($key, $shm_size, $flags);
    defined $s or do {
        require Carp;
        Carp::croak "Could not create shared memory segment: $!\n";
    };
    _debug "shared memory id is", $s->id                         if DEBUGGING;

    my $sem = IPC::Semaphore->new($key, 2, $flags);
    defined $sem or do {
        require Carp;
        Carp::croak "Could not create semaphore set: $!\n";
    };
    _debug "semaphore id is", $sem->id                           if DEBUGGING;

    $sem->op(SEM_LOCKER, SHM_LOCK_WAIT, SEM_UNDO,
             SEM_LOCKER, SHM_LOCK_EX,   SEM_UNDO);

    my $sh = {
        _iterating => '',
        _key       => $key,
        _lock      => '',
        _opts      => $opts,
        _shm       => $s,
        _sem       => $sem,
        _type      => $type,
        
    };
    $sh->{_data} = _thaw($s),

    my $there = $sem->getval(SEM_MARKER);
    if ($there == SHM_EXISTS) {
        _debug "binding to existing segment on ", $s->id         if DEBUGGING;
    } else {
        _debug "brand new segment on ", $s->id                   if DEBUGGING;
        $Proc_Reg{$sh->{_shm}->id} ||= $sh;
        $sem->setval(SEM_MARKER, SHM_EXISTS) or do {
            require Carp;
            Carp::croak "Couldn't set semaphore during object creation: $!";
          };
    }

    $sem->op(SEM_LOCKER, SHM_LOCK_UN, SEM_UNDO);

    _debug "IPC::Shareable instance created:", $sh               if DEBUGGING;

    return bless $sh => $class;
}

sub _parse_args {
    _trace @_                                                    if DEBUGGING;
    my($proto, $opts) = @_;

    $proto = defined $proto ? $proto :  0;
    $opts  = defined $opts  ? $opts  : { %Def_Opts };
    if (ref $proto eq 'HASH') {
        $opts = $proto;
    } else {
        $opts->{key} = $proto;
    }
    while (my ($k, $v) = each %$opts) {
        $opts->{$k} = '' if $v eq 'no';
    }
    $opts->{_owner} = ($opts->{_owner} or $$);
    $opts->{_magic} = ($opts->{_magic} or '');
    _debug "options are", $opts                                  if DEBUGGING;
    return $opts;
}
    
sub _shm_key {
    _trace @_                                                    if DEBUGGING;
    my $hv = shift;
    my $val = ($hv->{key} or '');

    if ($val eq '') {
        return IPC_PRIVATE;
    } elsif ($val =~ /^\d+$/) {
        return $val;
    } else {
        # XXX This only uses the first four characters
        $val = pack   A4 => $val;
        $val = unpack i  => $val;
        return $val;
    }
}
    
sub _shm_flags {
    # --- Parses the anonymous hash passed to constructors; returns a list
    # --- of args suitable for passing to shmget
    _trace @_                                                    if DEBUGGING;
    my $hv = shift;
    my $flags = 0;
    
    $flags |= IPC_CREAT if $hv->{create}    and    $hv->{create} ne 'no';
    $flags |= IPC_EXCL  if $hv->{exclusive} and $hv->{exclusive} ne 'no';
    $flags |= ($hv->{mode} or 0666);

    return $flags;
}

sub _mg_tie {
    _trace @_                                                    if DEBUGGING;
    my $dad = shift;
    my $val = shift;

    # XXX How to generate a unique id ?
    my $key;
    if ($dad->{_key} == IPC_PRIVATE) {
        $key = IPC_PRIVATE;
    } else {
        $key = int(rand(1_000_000));
    }
    my %opts = (
                %{$dad->{_opts}},
                key       => $key,
                exclusive => 'yes',
                create    => 'yes',
                _magic    => 'yes'
               );

    # XXX I wish I didn't have to take a copy of data here and copy it back in
    # XXX Also, have to peek inside potential objects to see their implementation
    my $kid;
    my $type = ref($val) ? "$val" : '';
    if ($type =~ /SCALAR/) {
        my $copy = $$val;
        $kid = tie $$val => 'IPC::Shareable', $key, { %opts } or do {
            require Carp;
            Carp::croak "Could not create inner tie";
        };
        $$val = $copy;
    } elsif ($type =~ /ARRAY/) {
        my @copy = @$val;
        $kid = tie @$val => 'IPC::Shareable', $key, { %opts } or do {
            require Carp;
            Carp::croak "Could not create inner tie";
        };
        @$val = @copy;
    } elsif ($type =~ /HASH/) {
        my %copy = %$val;
        $kid = tie %$val => 'IPC::Shareable', $key, { %opts } or do {
            require Carp;
            Carp::croak "Could not create inner tie";
        };
        %$val = %copy;
    } else {
        require Carp;
        Carp::croak "Variables of type $type not implemented";
    }

    return $kid;
}

sub _is_kid {
    my $data = shift;
    $data or return;
    my $type = "$data";

    # XXX Have to peek inside potential objects to see their implementation
    my $obj;
    if ($type =~ /HASH/) {
        $obj = tied %$data;
    } elsif ($type =~ /ARRAY/) { 
        $obj = tied @$data;
    } elsif ($type =~ /SCALAR/) {
        $obj = tied $$data;
    }

    if (ref $obj eq 'IPC::Shareable') {
        return $obj;
    } else {
        return;
    }
}

sub _need_tie {
    my $val = shift;

    # XXX Have to peek inside potential objects to see their implementation
    my $type = ref $val ? "$val" : '';
    if ($type =~ /SCALAR/) {
        return !(tied $$val);
    } elsif ($type =~ /ARRAY/) {
        return !(tied @$val);
    } elsif ($type =~ /HASH/) {
        return !(tied %$val);
    } else {
        return;
    }
}

sub _trace {
    require Carp;
    require Data::Dumper;
    my $caller = '    ' . (caller(1))[3] . " called with:\n";
    my $i = -1;
    my @msg = map {
        ++$i;
        my $obj;
        if (ref eq 'IPC::Shareable') {
            '        ' . "\$_[$i] = $_: shmid: $_->{_shm}->{_id}; " .
                Data::Dumper->Dump([ $_->{_opts} ], [ 'opts' ]);
        } else {
            '        ' . Data::Dumper->Dump( [ $_ ] => [ "\_[$i]" ]);
        }
    }  @_;
    Carp::carp "IPC::Shareable ($$) debug:\n", $caller, @msg;
}

sub _debug {
    require Carp;
    require Data::Dumper;
    local $Data::Dumper::Terse = 1;
    my $caller = '    ' . (caller(1))[3] . " tells us that:\n";
    my @msg = map {
        my $obj;
        if (ref eq 'IPC::Shareable') {
            '        ' . "$_: shmid: $_->{_shm}->{_id}; " .
                Data::Dumper->Dump([ $_->{_opts} ], [ 'opts' ]);
        } else {
            '        ' . Data::Dumper::Dumper($_);
        }
    }  @_;
    Carp::carp "IPC::Shareable ($$) debug:\n", $caller, @msg;
};

1;

__END__

=head1 NAME

IPC::Shareable - share Perl variables between processes

=head1 SYNOPSIS

 use IPC::Shareable;
 tie SCALAR, 'IPC::Shareable', GLUE, OPTIONS;
 tie ARRAY,  'IPC::Shareable', GLUE, OPTIONS;
 tie HASH,   'IPC::Shareable', GLUE, OPTIONS;

 (tied VARIABLE)->shlock;
 (tied VARIABLE)->shunlock;

 (tied VARIABLE)->destroy;

 IPC::Shareable->clean_up;

=head1 CONVENTIONS

The occurrence of a number in square brackets, as in [N], in the text
of this document refers to a numbered note in the L</NOTES>.

=head1 DESCRIPTION

IPC::Shareable allows you to tie a variable to shared memory making it
easy to share the contents of that variable with other Perl processes.
Scalars, arrays, and hashes can be tied.  The variable being tied may
contain arbitrarily complex data structures - including references to
arrays, hashes of hashes, etc.

The association between variables in distinct processes is provided by
GLUE.  This is an integer number or 4 character string[1] that serves
as a common identifier for data across process space.  Hence the
statement

 tie $scalar, 'IPC::Shareable', 'data';

in program one and the statement

 tie $variable, 'IPC::Shareable', 'data';

in program two will bind $scalar in program one and $variable in
program two.

There is no pre-set limit to the number of processes that can bind to
data; nor is there a pre-set limit to the complexity of the underlying
data of the tied variables[2].  The amount of data that can be shared
within a single bound variable is limited by the system's maximum size
for a shared memory segment (the exact value is system-dependent).

The bound data structures are all linearized (using Raphael Manfredi's
Storable module) before being slurped into shared memory.  Upon
retrieval, the original format of the data structure is recovered.
Semaphore flags are used for locking data between competing processes.

=head1 OPTIONS

Options are specified by passing a reference to a hash as the fourth
argument to the tie() function that enchants a variable.
Alternatively you can pass a reference to a hash as the third
argument; IPC::Shareable will then look at the field named B<key> in
this hash for the value of GLUE.  So,

 tie $variable, 'IPC::Shareable', 'data', \%options;

is equivalent to

 tie $variable, 'IPC::Shareable', { key => 'data', ... };

Boolean option values can be specified using a value that evaluates to
either true or false in the Perl sense, or by using the word B<yes>
for true and the word B<no> for false.  (Previous versions accepted
case-insensitive forms of YES/NO; support for this has been removed.)

The following fields are recognized in the options hash.

=over 4

=item B<key>

The B<key> field is used to determine the GLUE when using the
three-argument form of the call to tie().  This argument is then, in
turn, used as the KEY argument in subsequent calls to shmget() and
semget().  If this field is not provided, a value of IPC_PRIVATE is
assumed (meaning that your variables cannot be shared with other
processes).

=item B<create>

B<create> is used to control whether calls to tie() create new shared
memory segments or not.  If B<create> is set to a true value,
IPC::Shareable will create a new binding associated with GLUE as
needed.  If B<create> is false (or equal to B<no>), IPC::Shareable
will not attempt to create a new shared memory segment associated with
GLUE.  In this case, a shared memory segment associated with GLUE must
already exist or the call to tie() will fail and return undef.

=item B<exclusive>

If B<exclusive> field is set to a true value, calls to tie() will fail
(returning undef) if a data binding associated with GLUE already
exists.  If set to a false value (or equal to B<no>), calls to tie()
will succeed even if a shared memory segment associated with GLUE
already exists.

=item B<mode>

The I<mode> argument is an octal number specifying the access
permissions when a new data binding is being created.  These access
permission are the same as file access permissions in that 0666 is
world readable, 0600 is readable only by the effective UID of the
process creating the shared variable, etc.  If not provided, a default
of 0666 (world readable and writable) will be assumed.

=item B<destroy>

If set to a true value, the shared memory segment underlying the data
binding will be removed when the process calling tie() exits
(gracefully)[3].  Use this option with care.

=item B<size>

This field may be used to specify the size of the shared memory
segment allocated.  The default is IPC::Shareable::SHM_BUFSIZ().

=back

Default values for options are

 key       => IPC_PRIVATE,
 create    => 'no',
 exclusive => 'no',
 destroy   => 'no',
 mode      => 'no',
 size      => IPC::Shareable::SHM_BUFSIZ(),

=head1 LOCKING

IPC::Shareable provides methods to implement application-level locking
of the shared data structures.  These methods are called shlock() and
shunlock().  To use them you must first get the object underlying the
tied variable, either by saving the return value of the original call
to tie() or by using the built-in tied() function.

To lock a variable, do this:

 $knot = tie $sv, 'IPC::Shareable', $glue, { %options };
 ...
 $knot->shlock;

or equivalently

 tie($scalar, 'IPC::Shareable', $glue, { %options });
 (tied $scalar)->shlock;

This will place an exclusive lock on the data of $scalar.

To unlock a variable do this:

 $knot->shunlock;

or

 (tied $scalar)->shunlock;

Note that there is no mechanism for shared locks.

There are some pitfalls regarding locking and signals that you should
make yourself aware of; these are discussed in L</NOTES>.

=head1 REFERENCES

When a reference to a non-tied scalar, hash, or array is assigned to a
tie()d variable, IPC::Shareable will attempt to tie() the thingy being
referenced[4].  This allows disparate processes to see changes to not
only the top-level variable, but also changes to nested data.  This
feature is intended to be transparent to the application, but there
are some caveats to be aware of.

First of all, IPC::Shareable does not (yet) guarantee that the ids
shared memory segments allocated automagically are unique.  The more
automagical tie()ing that happens, the greater the chance of a
collision.

Secondly, since a new shared memory segment is created for each thingy
being referenced, the liberal use of references could cause the system
to approach its limit for the total number of shared memory segments
allowed.

=head1 OBJECTS

IPC::Shareable implements tie()ing objects to shared memory too.
Since an object is just a reference, the same principles (and caveats)
apply to tie()ing objects as other reference types.

=head1 DESTRUCTION

perl(1) will destroy the object underlying a tied variable when then
tied variable goes out of scope.  Unfortunately for IPC::Shareable,
this may not be desirable: other processes may still need a handle on
the relevant shared memory segment.  IPC::Shareable therefore provides
an interface to allow the application to control the timing of removal
of shared memory segments.  The interface consists of three methods -
destroy(), clean_up(), and clean_up_all() - and the B<destroy> option
to tie().

=over 4

=item B<destroy option>

As described in L</OPTIONS>, specifying the B<destroy> option when
tie()ing a variable coerces IPC::Shareable to remove the underlying
shared memory segment when the process calling tie() exits gracefully.
Note that any related shared memory segments created automagically by
the use of references will also be removed.

=item B<remove()>

 (tied $var)->remove;

Calling remove() on the object underlying a tie()d variable removes
the associated shared memory segment.  The segment is removed
irrespective of whether it has the B<destroy> option set or not and
irrespective of whether the calling process created the segment.

=item B<clean_up()>

 IPC::Shareable->clean_up;

This is a class method that provokes IPC::Shareable to remove all
shared memory segments created by the process.  Segments not created
by the calling process are not removed.

=item B<clean_up_all()>

 IPC::Shareable->clean_up_all;

This is a class method that provokes IPC::Shareable to remove all
shared memory segments encountered by the process.  Segments are
removed even if they were not created by the calling process.

=back

=head1 EXAMPLES

In a file called B<server>:

 #!/usr/bin/perl -w
 use strict;
 use IPC::Shareable;
 my $glue = 'data';
 my %options = (
     create    => 'yes',
     exclusive => 'no',
     mode      => 0644,
     destroy   => 'yes',
 );
 my %colours;
 tie %colours, 'IPC::Shareable', $glue, { %options } or
     die "server: tie failed\n";
 %colours = (
     red => [
         'fire truck',
         'leaves in the fall',
     ],
     blue => [
         'sky',
         'police cars',
     ],
 );
 ((print "server: there are 2 colours\n"), sleep 5)
     while scalar keys %colours == 2;
 print "server: here are all my colours:\n";
 foreach my $c (keys %colours) {
     print "server: these are $c: ",
         join(', ', @{$colours{$c}}), "\n";
 }
 exit;

In a file called B<client>

 #!/usr/bin/perl -w
 use strict;
 use IPC::Shareable;
 my $glue = 'data';
 my %options = (
     create    => 'no',
     exclusive => 'no',
     mode      => 0644,
     destroy   => 'no',
     );
 my %colours;
 tie %colours, 'IPC::Shareable', $glue, { %options } or
     die "client: tie failed\n";
 foreach my $c (keys %colours) {
     print "client: these are $c: ",
         join(', ', @{$colours{$c}}), "\n";
 }
 delete $colours{'red'};
 exit;

And here is the output (the sleep commands in the command line prevent
the output from being interrupted by shell prompts):

 bash$ ( ./server & ) ; sleep 10 ; ./client ; sleep 10
 server: there are 2 colours
 server: there are 2 colours
 server: there are 2 colours
 client: these are blue: sky, police cars
 client: these are red: fire truck, leaves in the fall
 server: here are all my colours:
 server: these are blue: sky, police cars

=head1 RETURN VALUES

Calls to tie() that try to implement IPC::Shareable will return true
if successful, I<undef> otherwise.  The value returned is an instance
of the IPC::Shareable class.

=head1 AUTHOR

Benjamin Sugars <bsugars@canoe.ca>

=head1 NOTES

=head2 Footnotes from the above sections

=over 4

=item 1

If GLUE is longer than 4 characters, only the 4 most significant
characters are used.  These characters are turned into integers by
unpack()ing them.  If GLUE is less than 4 characters, it is space
padded.

=item 2

IPC::Shareable provides no pre-set limits, but the system does.
Namely, there are limits on the number of shared memory segments that
can be allocated and the total amount of memory usable by shared
memory.

=item 3

If the process has been smoked by an untrapped signal, the binding
will remain in shared memory.  If you're cautious, you might try

 $SIG{INT} = \&catch_int;
 sub catch_int {
     die;
 }
 ...
 tie $variable, IPC::Shareable, 'data', { 'destroy' => 'Yes!' };

which will at least clean up after your user hits CTRL-C because
IPC::Shareable's END method will be called.  Or, maybe you'd like to
leave the binding in shared memory, so subsequent process can recover
the data...

=item 4

This behaviour is markedly different from previous versions of
IPC::Shareable.  Older versions would sometimes tie() referenced
thingies, and sometimes not.  The new approach is more reliable (I
think) and predictable (certainly) but uses more shared memory
segments.

=back

=head2 General Notes

=over 4

=item o

When using shlock() to lock a variable, be careful to guard against
signals.  Under normal circumstances, IPC::Shareable's END method
unlocks any locked variables when the process exits.  However, if an
untrapped signal is received while a process holds an exclusive lock,
DESTROY will not be called and the lock may be maintained even though
the process has exited.  If this scares you, you might be better off
implementing your own locking methods.

=item o

There is a program called ipcs(1/8) that is available on at least
Solaris and Linux that might be useful for cleaning moribund shared
memory segments or semaphore sets produced by bugs in either
IPC::Shareable or applications using it.

=item o

This version of IPC::Shareable does not understand the format of
shared memory segments created by earlier versions.  If you try to tie
to such segments, you will get an error.  The only work around is to
clear the shared memory segments and start with a fresh set.

=back

=head1 CREDITS

Thanks to all those with comments or bug fixes, especially

 Maurice Aubrey      <maurice@hevanet.com>
 Stephane Bortzmeyer <bortzmeyer@pasteur.fr>
 Michael Stevens     <michael@malkav.imaginet.co.uk>
 Richard Neal        <richard@imaginet.co.uk>
 Jason Stevens       <jstevens@chron.com> 
 Doug MacEachern     <dougm@telebusiness.co.nz>

=head1 BUGS

Certainly; this is alpha software. When you discover an
anomaly, send me an email at bsugars@canoe.ca.

=head1 SEE ALSO

perl(1), perltie(1), Storable(3), shmget(2) and other SysV IPC man
pages.

=cut
