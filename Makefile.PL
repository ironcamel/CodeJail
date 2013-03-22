use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME      => 'CodeJail',
    AUTHOR    => 'Naveed Massjouni <naveedm9@gmail.com>',
    PREREQ_PM => {
        'Dancer'                => '1.3111',
        'Dancer::Plugin::Stomp' => '1.0302',
        'Data::Dump'            => '0',
        'File::Copy::Recursive' => '0',
        'FindBin'               => '0',
        'IO::File'              => '0',
        'IPC::Run'              => '0',
        'JSON'                  => '0',
        'LWP::UserAgent'        => '0',
        # Need this and libssl-dev for https support
        #'LWP::Protocol::https'  => '0',
        'Net::Stomp'            => '0',
        'POSIX'                 => '0',
        'Try::Tiny'             => '0',
        'YAML'                  => '0',
    },
);
