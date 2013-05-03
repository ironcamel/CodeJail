#!/usr/bin/env perl
use v5.12;
use warnings;
use File::Copy::Recursive qw(rcopy);
use File::Slurp qw(read_file write_file);
use FindBin qw($RealBin);
use IPC::Run qw(run timeout);
use JSON qw(decode_json encode_json);
use Try::Tiny;

chdir $RealBin;
my $results_dir = 'results';
mkdir $results_dir;

my $data = decode_json read_file 'data.json';
my $code        = $data->{code};
my $file_name   = $data->{file_name} // 'foo';
my $compile_cmd = $data->{compile_cmd};
my $run_cmd     = $data->{run_cmd};
my $run_id      = $data->{run_id} // 'unknown';
my $problem     = $data->{problem} || {};
my $timeout     = $data->{timeout} || 3;
my $input       = $problem->{input};
my $copy_results_path = $data->{copy_results_path};
my ($out, $err, $compile_success);

write_file $file_name, $code;
run [qw(tar xf env_bundle.tar)], \'', \$out, \$err;
run [qw(tar xf lib_bundle.tar -C /usr/local/lib/codejail)], \'', \$out, \$err;

if ($compile_cmd) {
    $compile_success = try {
        run $compile_cmd, \'', \$out, \$err, timeout($timeout);
    } catch {
        $err = "Compile command took too long $_";
    };
    write_file "$results_dir/compile_out.log", $out // '';
    write_file "$results_dir/compile_err.log", $err // '';
}

exit unless $compile_success;

try {
    run $run_cmd, \$input, \$out, \$err, timeout($timeout);
} catch {
    $err = "Run command took too long $_";
};
write_file "$results_dir/run_out.log", $out // '';
write_file "$results_dir/run_err.log", $err // '';

# Copy out a custom dir, such as junit results for example
if ($copy_results_path) {
    my $dir = "$results_dir/extra";
    mkdir $dir;
    rcopy $copy_results_path => $dir;
}

