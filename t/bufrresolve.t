use warnings;
use strict;

use Test::More tests => 8;
use File::Slurp qw(read_file);
use Config;

my $perl = $Config{perlpath};

my $output = `$perl ./bufrresolve.pl 307080 -t t/bt`;
my $expected = read_file( 't/307080.txt' ) ;
is($output, $expected, 'testing bufrresolve.pl on D descriptor');

$output = `$perl ./bufrresolve.pl --partial 307080 -t t/bt`;
$expected = read_file( 't/307080.partial' ) ;
is($output, $expected, 'testing bufrresolve.pl -p on D descriptor');

$output = `$perl ./bufrresolve.pl --simple 307080 -t t/bt`;
$expected = read_file( 't/307080.simple' ) ;
is($output, $expected, 'testing bufrresolve.pl -s on D descriptor');

$output = `$perl ./bufrresolve.pl --noexpand 301001 301011 301012 301022 002003 106000 031001 007007 011001 011002 033002 011006 033002 -t t/bt`;
$expected = read_file( 't/noexpand.txt' ) ;
is($output, $expected, 'testing bufrresolve.pl -n on descriptor sequence');

$output = `$perl ./bufrresolve.pl --bufrtable B0000000000098013001 307080 -t t/bt`;
$expected = read_file( 't/307080.table' ) ;
is($output, $expected, 'testing bufrresolve.pl -t on D descriptor');

$output = `$perl ./bufrresolve.pl --code 020022 -t t/bt`;
$expected = read_file( 't/codetable.txt' ) ;
is($output, $expected, 'testing bufrresolve.pl -c on code table');

$output = `$perl ./bufrresolve.pl --code 008042 --flag 145408 -t t/bt`;
$expected = read_file( 't/flag.txt' ) ;
is($output, $expected, 'testing bufrresolve.pl -c -f on flag table');

$output = `$perl ./bufrresolve.pl --code 008042 --flag 3 -t t/bt`;
$expected = read_file( 't/illegal_flag.txt' ) ;
is($output, $expected, 'testing bufrresolve.pl -c -f on illegal flag');
