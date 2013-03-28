#!/usr/bin/env perl
use strict;
use warnings;
use v5.10;
use Data::Dump qw(dd dump);
use File::Copy::Recursive qw(rcopy);
use FindBin qw($RealBin);
use IO::File;
use IPC::Run qw(run timeout);
use JSON qw(decode_json encode_json);
use LWP::UserAgent;
use Net::Stomp;
use POSIX qw(setgid);
use Try::Tiny;
use YAML qw(LoadFile);

my $AGENT = LWP::UserAgent->new(ssl_opts => { verify_hostname => 0 });
my $config = LoadFile("$RealBin/../config.yml");
my $log_file = $config->{log_file} || "/tmp/codejail.log";
open my $LOG, '>>', $log_file or die "Could not open $log_file : $!\n";
$LOG->autoflush(1);
STDOUT->autoflush(1);
my $jail = $config->{jail_path} or die "No jail_path configured";
my $queue = $config->{queue} || '/queue/codejail';

my $stomp = Net::Stomp->new({
    hostname => $config->{plugins}{Stomp}{default}{hostname},
    port     => $config->{plugins}{Stomp}{default}{port},
    reconnect_on_fork => 0,
});
$stomp->connect();
$stomp->subscribe({ destination => $queue, ack => 'client' });

$SIG{INT} = sub {
    $stomp->disconnect;
    say 'goodbye';
    exit;
};
$SIG{PIPE} = 'IGNORE';

say "worker is starting";

# main loop --------------------------------------------------------------------

while (1) {
    my $frame = $stomp->receive_frame;
    my $msg = $frame->body;
    my $data;
    say "processing msg ...";
    try {
        $data = decode_json($msg);
        process_msg($data);
    } catch {
        debug("failed to process msg: $_");
        post_result(0, $_, $data);
    } finally {
        $stomp->ack({ frame => $frame });
    };
}

# functions -------------------------------------------------------------------

sub process_msg {
    my ($data) = @_;
    log_msg($data);
    my $out = run_code($data);
    return post_result(-1, $out, $data) if $out =~ /^ERROR:/;
    my $status = $out eq $data->{problem}{output} ? 1 : 0;
    my $reason = $status == 1 ? 'Success' : 'Wrong answer';
    post_result($status, $reason, $data);
}

sub run_code {
    my ($data) = @_;

    sys("rm -rf $jail/home/sandbox/runs/*");
    #sys("tar -xf $jail.tar -C /var") or die "Could not build chroot jail: $!";

    my $pid = open my $child_process, '-|';
    if (!$pid) { # child process starts here
        try {
            run_in_chroot($data);
        } catch {
            say "ERROR: $_";
        };
        exit;
    } # end of child process

    # Read output from the child process
    my @out = <$child_process>;
    close $child_process;
    my $result = join '', @out;
    debug('output: ' . substr $result, 0, 100);
    debug("full: $result");

    # Copy result files out of the jail
    if (my $results_path = $data->{copy_results_path}) {
        my $run_id  = $data->{run_id} || 'unknown';
        my $target_dir = "$RealBin/../results/$run_id";
        rcopy "$jail/$results_path", $target_dir;
    }

    # Lets clean up after ourselves.
    #sys("rm -rf $jail/home/sandbox/runs/*");

    return $result;
}

sub run_in_chroot {
    my ($data) = @_;
    my $lang        = $data->{language};
    my $code        = $data->{code};
    my $file_name   = $data->{file_name} // 'foo';
    my $problem     = $data->{problem};
    my $compile_cmd = $data->{compile_cmd};
    my $run_cmd     = $data->{run_cmd};
    my $input       = $problem->{input};

    chdir $jail or die "Failed to chdir into $jail: $!";

    if (not glob "$jail/proc/*") {
        sys("mount -t proc proc proc/") or die "Could not mount /proc: $!";
    }

    my $run_dir = "/home/sandbox/runs";
    my $chroot_run_dir = $jail . $run_dir;
    if (not -d $chroot_run_dir) {
        mkdir $chroot_run_dir or die "Could not mkdir $chroot_run_dir: $!";
        chmod 0777, $chroot_run_dir or die "Could not chmod $chroot_run_dir";
    }
    if (my $url = $data->{env_bundle_url}) {
        debug("getting bundle from $url");
        my $bundle_path = "$chroot_run_dir/bundle.tar";
        # For https: LWP::Protocol::https, libssl-dev, libnet-ssleay-perl 
        my $res = $AGENT->mirror($url, $bundle_path);
        debug($res->status_line);
        if (!$res->is_success and $res->code != 304) {
            die "Could not download bundle: " . $res->status_line;
        }
        sys("tar xf $bundle_path -C $chroot_run_dir")
            or die "Could not expand bundle $bundle_path $!";
    }
    if (my $url = $data->{lib_bundle_url}) {
        debug("getting bundle from $url");
        my $lib_dir = "$jail/usr/local/lib/codejail";
        my $bundle_path = "$lib_dir/bundle.tar";
        my $res = $AGENT->mirror($url, $bundle_path);
        debug($res->status_line);
        if (!$res->is_success and $res->code != 304) {
            die "Could not download bundle: " . $res->status_line;
        }
        sys("tar xf $bundle_path -C $lib_dir")
            or die "Could not expand bundle $bundle_path $!";
    }

    debug("chroot $jail");
    chroot $jail or die "Could not chroot: $!";

    # Drop root privileges immediately after successful chroot
    my $new_uid = getpwnam('sandbox');
    die "Can't find uid for sandbox user" unless defined $new_uid;
    $< = $> = $new_uid; # Update the real and effective user id
    setgid($new_uid);   # Update the group id

    debug("chdir $run_dir");
    chdir $run_dir or die "Could not chdir to $run_dir: $!";

    my ($out, $err, @cmd) = ('', '');
    given ($lang) {
        when ('java') {
            my $class_name = (split /\./, $file_name)[0];
            my $path = $file_name;
            open my $java_file, '>', $path;
            print $java_file $code;
            my $compile_cmd = $data->{compile_cmd} || "javac $path";
            sys($compile_cmd) or die "Failed to compile java code: $!";
            @cmd = ($lang, $class_name);
        }
        when ('c++') {
            my $path = 'foo.cpp';
            open my $c_file, '>', $path or die "Could not create c file: $!";
            print $c_file $code;
            sys("g++ -o foo $path") or die "Failed to compile c code: $!";
            @cmd = ('./foo');
        }
        when ([qw(perl python ruby)]) {
            my $path = 'foo';
            open my $p_file, '>', $path;
            print $p_file $code;
            @cmd =($lang, $path);
        }
        default {
            open my $f, '>', $file_name;
            print $f $code;
            if ($compile_cmd) {
                debug("compiling: ", $compile_cmd);
                run $compile_cmd;
            }
            @cmd = @$run_cmd;
        }
    }

    debug("going to run: @cmd");
    try {
        run \@cmd, \$input, \$out, \$err, timeout(3);
    } catch {
        print "Took too long $_\n";
    };
    print $out;
}

sub post_result {
    my ($status, $reason, $data) = @_;
    print "posting result:";
    return unless ref $data eq 'HASH' and $data->{cb_url};
    my $result = {
        status  => $status,
        reason  => $reason,
        run_id  => $data->{run_id},
        user_id => $data->{user_id},
        problem => $data->{problem}{title},
    };
    dd $result;
    debug($result);
    debug("going to post result to callback url: $data->{cb_url}");
    my $res = $AGENT->post($data->{cb_url}, content_type => 'application/json',
        content => encode_json($result));
    debug($res->status_line);
}

sub debug { say $LOG '[' . localtime . '] (DEBUG) ' . dump(@_) }

sub log_msg {
    my $data = shift;
    my %copy = %$data;
    $copy{problem} = $copy{problem}{title};
    debug(\%copy)
}

sub sys {
    my ($cmd) = @_;
    debug($cmd);
    return system($cmd) == 0;
}
