#!/usr/bin/env perl
use strict;
use warnings;
use v5.10;
use Data::Dump qw(dump);
use File::Slurp qw(write_file);
use FindBin qw($RealBin);
use IO::File;
use IPC::Run qw(run);
use JSON qw(decode_json encode_json);
use LWP::UserAgent;
use Net::Stomp;
use Try::Tiny;
use YAML qw(LoadFile);

my $AGENT = LWP::UserAgent->new;
my $config = LoadFile("$RealBin/../config.yml");
my $log_file = $config->{log_file} || "/tmp/codejail.log";
open my $LOG, '>>', $log_file or die "Could not open $log_file : $!\n";
$LOG->autoflush(1);
STDOUT->autoflush(1);
my $queue = $config->{queue} || '/queue/codejail';
my $docker_bin = "/opt/go/bin/docker";

my $stomp = Net::Stomp->new({
    hostname => $config->{plugins}{Stomp}{default}{hostname},
    port     => $config->{plugins}{Stomp}{default}{port},
    reconnect_on_fork => 0,
});
$stomp->connect();
$stomp->subscribe({ destination => $queue, ack => 'client' });

say "worker is starting";

# main loop --------------------------------------------------------------------

while (1) {
    my $frame = $stomp->receive_frame;
    my $msg = $frame->body;
    say "processing msg ...";
    try {
        process_msg($msg);
    } catch {
        debug("failed to process job: $_");
    } finally {
        $stomp->ack({ frame => $frame });
    };
}

# functions -------------------------------------------------------------------

sub process_msg {
    my ($msg) = @_;

    my $data = decode_json $msg;
    debug($data);
    my $dir = "/tmp/content";
    run "rm -rf $dir";
    run "mkdir $dir";
    run "cp $RealBin/docker-agent.pl $dir";
    write_file "$dir/data.json", $msg;
    get_bundle($data->{env_bundle_url}, "$dir/env_bundle.tar")
        if $data->{env_bundle_url};
    get_bundle($data->{lib_bundle_url}, "$dir/env_bundle.tar")
        if $data->{lib_bundle_url};

    my $cmd = join ' ',
        'tar -C /tmp -c content |',
        "$docker_bin run -u sandbox -i -a stdin ironcamel/test1 /bin/bash -c",
        qw("
            cd /tmp;
            tar -x;
            perl ./content/docker-agent.pl;
            tar -C ./content -c results;
        ");
    my $docker_run_id = `$cmd`;
    chomp $docker_run_id;
    debug("docker_run_id: $docker_run_id");
    sleep 3;
    run "$docker_bin logs $docker_run_id > results.tar";
    debug("Results are ready!");
}

sub get_bundle {
    my ($url, $bundle_path) = @_;
    debug("getting bundle from $url");
    my $res = $AGENT->mirror($url, $bundle_path);
    debug($res->status_line);
    if (!$res->is_success and $res->code != 304) {
        die "Could not download bundle: " . $res->status_line;
    }
}

sub debug {
    my $msg = '[' . localtime . '] (DEBUG) ' . dump(@_);
    say $LOG $msg;
    say $msg;
}
