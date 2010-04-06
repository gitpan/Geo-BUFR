#!/bin/perl
use warnings;
use strict;

use Test::More tests => 3;
use File::Slurp qw(read_file);

my $output = `perl ./bufrencode.pl --data t/307080.data_2 --metadata t/metadata.txt_ed4 -t t/bt`;
my $expected = read_file( 't/encoded_ed4', binmode => ':raw' ) ;
is($output, $expected, 'testing bufrencode.pl on 2 synop bufr edition 4');

$output = `perl ./bufrencode.pl --data t/307080.data_2 --metadata t/metadata.txt_ed3 -t t/bt`;
$expected = read_file( 't/encoded_ed3', binmode => ':raw' ) ;
is($output, $expected, 'testing bufrencode.pl -t on 2 synop bufr edition 3');

$output = `perl ./bufrencode.pl --data t/substituted_data --metadata t/substituted_metadata -t t/bt`;
$expected = read_file( 't/substituted.bufr' ) ;
is($output, $expected, 'testing bufrencode.pl -t on message with unnumbered descriptors');

