use warnings;
use strict;

use Test::More tests => 8;
use File::Slurp qw(read_file);
use Config;

my $perl = $Config{perlpath};

`$perl ./bufr_reencode.pl t/1xBUFRSYNOP-ed4.txt -t t/bt > t/out`;
my $output = read_file('t/out');
my $expected = read_file('t/1xBUFRSYNOP-ed4.bufr');
unlink 't/out';
is($output, $expected, 'testing bufr_reencode.pl on BUFR SYNOP edition 4');

`$perl ./bufr_reencode.pl t/3xBUFRSYNOP-com.txt -t t/bt > t/out`;
$output = read_file('t/out');
$expected = read_file('t/3xBUFRSYNOP-com.bufr');
unlink 't/out';
is($output, $expected, 'testing bufr_reencode.pl on 3 compressed BUFR SYNOP edition 4');

`$perl ./bufr_reencode.pl t/substituted.txt -o t/out -t t/bt`;
$output = read_file('t/out');
$expected = read_file('t/substituted.bufr');
unlink 't/out';
is($output, $expected, 'testing bufr_reencode.pl -o on BUFR file with bitmaps');

`$perl ./bufr_reencode.pl t/change_refval.txt -o t/out -t t/bt`;
$output = read_file('t/out');
$expected = read_file('t/change_refval.bufr');
unlink 't/out';
is($output, $expected, 'testing bufr_reencode.pl -o on BUFR file with 203Y');

`$perl ./bufr_reencode.pl t/change_refval_compressed.txt -o t/out -t t/bt`;
$output = read_file('t/out');
$expected = read_file('t/change_refval_compressed.bufr');
unlink 't/out';
is($output, $expected, 'testing bufr_reencode.pl -o on BUFR file with 203Y (compressed)');

`$perl ./bufr_reencode.pl t/208035.txt -w 35 -o t/out -t t/bt`;
$output = read_file('t/out');
$expected = read_file('t/208035.bufr');
unlink 't/out';
is($output, $expected, 'testing bufr_reencode.pl -o on BUFR file with 208Y');

`$perl ./bufr_reencode.pl t/delayed_repetition.txt -o t/out -t t/bt`;
$output = read_file('t/out');
$expected = read_file('t/delayed_repetition.bufr');
unlink 't/out';
is($output, $expected, 'testing bufr_reencode.pl -o on BUFR file with 030011');

`$perl ./bufr_reencode.pl t/delayed_repetition_compressed.txt -o t/out -t t/bt`;
$output = read_file('t/out');
$expected = read_file('t/delayed_repetition_compressed.bufr');
unlink 't/out';
is($output, $expected, 'testing bufr_reencode.pl -o on BUFR file with 030011 (compressed)');

