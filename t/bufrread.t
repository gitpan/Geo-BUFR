use warnings;
use strict;

use Test::More tests => 20;
use File::Slurp qw(read_file);
use Config;

my $perl = $Config{perlpath};

my $output = `$perl ./bufrread.pl --codetables t/tempLow_200707271955.bufr -t t/bt`;
my $expected = read_file( 't/tempLow_200707271955.txt' );
is($output, $expected, 'testing bufrread.pl -c on temp edition 4 message');

$output = `$perl ./bufrread.pl --filter t/filter --param t/param t/3xBUFRSYNOP-com.bufr -t t/bt`;
$expected = read_file( 't/3xBUFRSYNOP-com_filtered.txt' );
is($output, $expected, 'testing bufrread.pl -f -p on compressed synop message');

$output = `$perl ./bufrread.pl --bitmap t/substituted.bufr -t t/bt`;
$expected = read_file( 't/substituted.txt_bitmap' );
is($output, $expected, 'testing bufrread.pl -b on temp message with qc and substituted values');

$output = `$perl ./bufrread.pl --data_only --noqc --width 10 --tablepath ~/bufr/bufrtables t/substituted.bufr -t t/bt`;
$expected = read_file( 't/substituted.txt_noqc' );
is($output, $expected, 'testing bufrread.pl -d -n -w -t on temp message with qc');

$output = `$perl ./bufrread.pl --all_operators t/associated.bufr -t t/bt`;
$expected = read_file( 't/associated.txt' );
is($output, $expected, 'testing bufrread.pl -a on message with associated values and 201-2 operators');

`$perl ./bufrread.pl --strict_checking 1 t/IOZX11_LFVW_060300.bufr -t t/bt > t/out 2> t/warn`;

$output = read_file( 't/out' );
unlink 't/out';
$expected = read_file( 't/IOZX11_LFVW_060300.txt_1' );
is($output, $expected, 'testing bufrread.pl -s 1 on buoy message for output');

$output = read_file( 't/warn' );
unlink 't/warn';
$expected = read_file( 't/IOZX11_LFVW_060300.warn' );
# Newer versions of perl might add '.' to end of warning/error message.
# Remove that as well as actual line number (to ease future changes in bufrread.pl)
$output =~ s/line \d+[.]?/line/g;
$expected =~ s/line \d+[.]?/line/g;
	  is($output, $expected, 'testing bufrread.pl -s 1 on buoy message for warnings');

`$perl ./bufrread.pl --strict_checking 2 t/IOZX11_LFVW_060300.bufr -t t/bt > t/out 2> t/err`;

$output = read_file( 't/out' );
unlink 't/out';
$expected = read_file( 't/IOZX11_LFVW_060300.txt_2' );
is($output, $expected, 'testing bufrread.pl -s 1 on buoy message for output');

$output = read_file( 't/err' );
unlink 't/err';
$expected = read_file( 't/IOZX11_LFVW_060300.err' );
# Newer versions of perl might add '.' to end of warning/error message.
# Remove that as well as actual line number (to ease future changes in bufrread.pl)
$output =~ s/line \d+[.]?/line/g;
$expected =~ s/line \d+[.]?/line/g;
is($output, $expected, 'testing bufrread.pl -s 2 on buoy message for error messages');

`$perl ./bufrread.pl t/change_refval.bufr -t t/bt > t/out`;
$output = read_file( 't/out' );
unlink 't/out';
$expected = read_file( 't/change_refval.txt' );
is($output, $expected, 'testing bufrread.pl on message containing 203Y');

`$perl ./bufrread.pl t/change_refval_compressed.bufr -t t/bt > t/out`;
$output = read_file( 't/out' );
unlink 't/out';
$expected = read_file( 't/change_refval_compressed.txt' );
is($output, $expected, 'testing bufrread.pl on compressed message containing 203Y');

`$perl ./bufrread.pl t/208035.bufr -w 35 -t t/bt > t/out`;
$output = read_file( 't/out' );
unlink 't/out';
$expected = read_file( 't/208035.txt' );
is($output, $expected, 'testing bufrread.pl on message containing 208Y');

$output = `$perl ./bufrread.pl --tablepath ~/bufr/bufrtables t/multiple_qc.bufr -t t/bt`;
$expected = read_file( 't/multiple_qc.txt' );
is($output, $expected, 'testing bufrread.pl on satellite data with triple 222000');

$output = `$perl ./bufrread.pl --tablepath ~/bufr/bufrtables t/multiple_qc_compressed.bufr -t t/bt`;
$expected = read_file( 't/multiple_qc_compressed.txt' );
is($output, $expected, 'testing bufrread.pl on compressed satellite data with triple 222000');

$output = `$perl ./bufrread.pl --tablepath ~/bufr/bufrtables t/multiple_qc.bufr -t t/bt --bitmap`;
$expected = read_file( 't/multiple_qc.txt_bitmap' );
is($output, $expected, 'testing bufrread.pl -b on satellite data with triple 222000');

$output = `$perl ./bufrread.pl --tablepath ~/bufr/bufrtables t/multiple_qc_vary.bufr -t t/bt --bitmap`;
$expected = read_file( 't/multiple_qc_vary.txt_bitmap' );
is($output, $expected, 'testing bufrread.pl -b on satellite data with triple 222000 and variable bitmaps');

$output = `$perl ./bufrread.pl t/firstorderstat.bufr -t t/bt`;
$expected = read_file( 't/firstorderstat.txt' );
is($output, $expected, 'testing bufrread.pl on compressed satellite data with 224000 and 224255');

$output = `$perl ./bufrread.pl --bitmap t/firstorderstat.bufr -t t/bt`;
$expected = read_file( 't/firstorderstat.txt_bitmap' );
is($output, $expected, 'testing bufrread.pl -b on satellite data with 224000 and large 224255 values');

$output = `$perl ./bufrread.pl --codetables --all_operators t/firstorderstat.bufr -t t/bt`;
$expected = read_file( 't/firstorderstat.txt_all' );
is($output, $expected, 'testing bufrread.pl -c -a on data with operators mingled in bitmap and duplicated code table (001032)');

$output = `$perl ./bufrread.pl t/retained.bufr -t t/bt`;
$expected = read_file( 't/retained.txt' );
is($output, $expected, 'testing bufrread.pl on message with 232000 and 204YYY operators');
