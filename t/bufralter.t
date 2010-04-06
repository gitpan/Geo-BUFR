#!/bin/perl
use warnings;
use strict;

use Test::More tests => 2;
use File::Slurp qw(read_file);

my $cmnd = 'perl ./bufralter.pl t/1xBUFRSYNOP-ed4.bufr'
    . ' --data 4005=10 --data 010004=missing --bufr_edition 3 --centre=88'
    . ' --subcentre 9 --update_number -1 --category 9 --subcategory 8'
    . ' --master_table_version=11 --local_table_version 0 --year 9'
    . ' --month 8 --day 7 --hour 6 --minute 5'
    . ' --outfile t/out -t t/bt';

`$cmnd`;
my $output = read_file('t/out');
my $expected = read_file('t/1xBUFRSYNOP-ed4.bufr_altered');
unlink 't/out';
is($output, $expected, 'testing bufralter.pl on BUFR SYNOP edition 4');

$cmnd = 'perl ./bufralter.pl t/3xBUFRSYNOP-com.bufr'
    . ' --data 4005=10 --data 010004=missing --bufr_edition 4 --centre=88'
    . ' --subcentre 9 --update_number 99 --category 9 --subcategory 8'
    . ' --master_table_version=11 --local_table_version 0 --year 9'
    . ' --month 8 --day 7 --hour 6 --minute 5 --observed 0 --compress 0'
    . ' --outfile t/out -t t/bt';
`$cmnd`;
$output = read_file('t/out');
$expected = read_file('t/3xBUFRSYNOP-com.bufr_altered');
unlink 't/out';
is($output, $expected, 'testing bufralter.pl on BUFR SYNOP edition 3');

