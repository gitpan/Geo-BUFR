use warnings;
use strict;

use Test::More tests => 4;
use File::Slurp qw(read_file);
use Config;

my $perl = $Config{perlpath};

my $output = `$perl ./bufrencode.pl --data t/307080.data_2 --metadata t/metadata.txt_ed4 -t t/bt`;
my $expected = read_file( 't/encoded_ed4', binmode => ':raw' ) ;
is($output, $expected, 'testing bufrencode.pl on 2 synop bufr edition 4');

$output = `$perl ./bufrencode.pl --data t/307080.data_2 --metadata t/metadata.txt_ed3 -t t/bt`;
$expected = read_file( 't/encoded_ed3', binmode => ':raw' ) ;
is($output, $expected, 'testing bufrencode.pl -t on 2 synop bufr edition 3');

$output = `$perl ./bufrencode.pl --data t/substituted_data --metadata t/substituted_metadata -t t/bt`;
$expected = read_file( 't/substituted.bufr' ) ;
is($output, $expected, 'testing bufrencode.pl -t on message with unnumbered descriptors');



# Testing of join_subsets and encode_nil_message

use Geo::BUFR;
Geo::BUFR->set_tablepath('t/bt');
my $bufr3 = Geo::BUFR->new();
$bufr3->fopen('t/bufr3subset.dat');
# Enforce decoding of metadata
$bufr3->next_observation();

# Create NIL BUFR message based on the same metadata
my $stationid_ref = {
                     '001001' => 1,
                     '001002' => 492,
                     '001015' => 'BLINDERN',
                 };
my $new_bufr = Geo::BUFR->new();
$new_bufr->copy($bufr3,'metadata');
$new_bufr->set_number_of_subsets(1);
$new_bufr->set_compressed_data(0);
my $nil_msg = $new_bufr->encode_nil_message($stationid_ref,[2,3]);
my $nil_bufr = Geo::BUFR->new($nil_msg);

# Then join the nil message with subset 1 and 3 from $bufr3
Geo::BUFR->set_verbose(3);
my ($data_refs,$desc_refs,$N) =
    Geo::BUFR->join_subsets($bufr3,[1,3],$nil_bufr);
my $join_bufr = Geo::BUFR->new();
$join_bufr->copy($bufr3,'metadata');
$join_bufr->set_number_of_subsets($N);
$join_bufr->set_compressed_data(0);
my $new_message = $join_bufr->encode_message($data_refs,$desc_refs);

$expected = read_file('t/join.bufr');
is($new_message, $expected, 'testing joining subsets and encoding nil message');
