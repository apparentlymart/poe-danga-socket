
=head1 NAME

POE::Loop::Danga_Socket - POE Loop implementation for Danga::Socket

=head1 SYNOPSIS

   use POE qw(Loop::Danga_Socket);

=cut

package POE::Loop::Danga_Socket;

use Danga::Socket;
use POE::Loop::PerlSignals;

use vars qw($VERSION);
$VERSION = "0.01";

package POE::Kernel;

use strict;
use warnings;
use Carp;

BEGIN {
    die("POE can't use both Danga_Socket and " . &POE_LOOP_NAME) if defined &POE_LOOP;
}

sub POE_LOOP () { LOOP_DANGA_SOCKET }

$POE::Loop::Danga_Socket::exit_loop = 0;
$POE::Loop::Danga_Socket::timer = undef;
%POE::Loop::Danga_Socket::fd_watches = ();

sub loop_initialize {
    print STDERR "initialize()\n";

    # TEMP: Trick Danga::Socket into using the Poll event loop.
    $Danga::Socket::DoneInit = 1;
    $Danga::Socket::HaveEpoll = 0;
    $Danga::Socket::HaveKQueue = 0;
    *Danga::Socket::EventLoop = *Danga::Socket::PollEventLoop;

    # Probably shouldn't just clobber someone else's
    # post-loop callback here, but whatever.
    Danga::Socket->SetPostLoopCallback(sub {
        return $POE::Loop::Danga_Socket::exit_loop ? 0 : 1;
    });
}

### Loop Lifecycle Functions

sub loop_finalize {
    print STDERR "finalize()\n";

    # Nothing to do here.
}

sub loop_do_timeslice {
    print STDERR "do_timeslice()\n";

    die "doing timeslices currently not supported in the Danga::Socket loop";
}

sub loop_run {
    print STDERR "run()\n";
    Danga::Socket->EventLoop();
}

sub loop_halt {
    print STDERR "halt()\n";

    $POE::Loop::Danga_Socket::exit_loop = 1;
}

sub loop_attach_uidestroy {
    print STDERR "attach_uidestroy()\n";

    # Nothing to do here
}

### Alarm and timer functions

sub loop_reset_time_watcher {
    my ($self, $next_time) = @_;

    unless ($next_time) {
        # Older versions of POE pass undef in here when
        # they mean to call pause_time_watcher,
        # so let's do the right thing for them.
        return $self->loop_pause_time_watcher();
    }

    print STDERR "reset_time_watcher($next_time)\n";

    $self->loop_pause_time_watcher();
    $self->loop_resume_time_watcher($next_time);
}

sub loop_pause_time_watcher {
    my ($self) = @_;

    print STDERR "pause_time_watcher()\n";

    print STDERR "Cancelling our timer\n";
    $POE::Loop::Danga_Socket::timer->cancel if $POE::Loop::Danga_Socket::timer;
    $POE::Loop::Danga_Socket::timer = undef;
}

sub loop_resume_time_watcher {
    my ($self, $next_time) = @_;

    print STDERR "resume_time_watcher($next_time)\n";

    my $wait_time = $next_time - time();
    $wait_time = 0 if $wait_time < 0;
    print STDERR "Setting a timer for $wait_time seconds\n";

    $POE::Loop::Danga_Socket::timer = Danga::Socket->AddTimer($wait_time, sub {
        $self->_data_ev_dispatch_due();
        $self->_test_if_kernel_is_idle();
    });
}

### File Activity Management Methods

sub loop_watch_filehandle {
    my ($self, $handle, $mode) = @_;
    my $fileno = fileno($handle);

    print STDERR "watch_filehandle($fileno, $mode)\n";

    return if $POE::Loop::Danga_Socket::fd_watches{$fileno}[$mode];

    print STDERR "Adding a watch for fd $fileno and mode $mode\n";
    $POE::Loop::Danga_Socket::fd_watches{$fileno}[$mode] = 1;

    Danga::Socket->AddOtherFds($fileno => sub {
        my ($state) = @_;

        if ($state & Danga::Socket::POLLNVAL) {
            # Socket is closed?
            $POE::Loop::Danga_Socket::fd_watches{$fileno}[$mode] = 0;
            return;
        }

        my $watches = $POE::Loop::Danga_Socket::fd_watches{$fileno};
        return unless $watches;

        my %poll_state_mask = (
            MODE_RD() => Danga::Socket::POLLIN,
            MODE_WR() => Danga::Socket::POLLOUT,
            MODE_EX() => Danga::Socket::POLLERR | Danga::Socket::POLLHUP,
        );

        foreach my $mode (MODE_RD, MODE_WR, MODE_EX) {
            if ($state & $poll_state_mask{$mode}) {
                print STDERR "Fd $fileno is ready for $mode\n";
                if ($watches->[$mode]) {
                    print STDERR "Watching for $mode\n";
                    $self->_data_handle_enqueue_ready($mode, $fileno);
                }
            }
        }

        $self->_test_if_kernel_is_idle();
    });
}

sub loop_ignore_filehandle {
    my ($self, $handle, $mode) = @_;
    my $fileno = fileno($handle);

    print STDERR "ignore_filehandle($fileno, $mode)\n";

    $POE::Loop::Danga_Socket::fd_watches[$mode]{$fileno} = 0;
}

sub loop_pause_filehandle {
    my ($self, $handle, $mode) = @_;

    $self->loop_ignore_filehandle($handle, $mode);
}

sub loop_resume_filehandle {
    my ($self, $handle, $mode) = @_;

    $self->loop_watch_filehandle($handle, $mode);
}

1;

=head1 DESCRIPTION

This is a POE loop implementation that uses L<Danga::Socket>.
This allows POE-based things to be used in applications
that are based on Danga::Socket, such as L<DJabberd>
and L<Perlbal>.

