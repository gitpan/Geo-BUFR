#!/usr/bin/perl -w

# (C) Copyright 2010, met.no
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA.

# pod included at end of file

use strict;
use Carp;
use Getopt::Long;
use Pod::Usage qw(pod2usage);
use File::Slurp qw(read_file write_file);
use Geo::BUFR;

# Will be used if neither --tablepath nor $ENV{BUFR_TABLES} is set
use constant DEFAULT_TABLE_PATH => '/usr/local/lib/bufrtables';

# Parse command line options
my %option = ();

GetOptions(
           \%option,
           'help',
           'outfile=s',
           'strict_checking=i',
           'tablepath=s',
           'verbose=i',
           'width=i',
       ) or pod2usage(-verbose => 0);

# User asked for help
pod2usage(-verbose => 1) if $option{help};

my $width = $option{width} ? $option{width} : 15;

my $infile = shift;
pod2usage(-verbose => 0) unless $infile and -f $infile;

# Default is croak if (recoverable) error found in encoded BUFR format
my $strict_checking = defined $option{strict_checking}
    ? $option{strict_checking} : 2;
Geo::BUFR->set_strict_checking($strict_checking);

# Set verbosity level for the BUFR module. Must be set also for each
# BUFR object generated
my $verbose = $option{verbose} ? $option{verbose} : 0;
Geo::BUFR->set_verbose($verbose);

# Set BUFR table path
if ($option{tablepath}) {
    # Command line option --tablepath overrides all
    Geo::BUFR->set_tablepath($option{tablepath});
} elsif ($ENV{BUFR_TABLES}) {
    # If no --tablepath option, use the BUFR_TABLES environment variable
    Geo::BUFR->set_tablepath($ENV{BUFR_TABLES});
} else {
    # If all else fails, use the default bufrtables
    Geo::BUFR->set_tablepath(DEFAULT_TABLE_PATH);
}

my $dumped_message = read_file($infile);
my $bufr = Geo::BUFR->new();

# This sets object verbose level equal to class verbose level
$bufr->set_verbose($verbose);

if ($option{outfile}) {
    my $buffer = $bufr->reencode_message($dumped_message, $width);
    write_file($option{outfile}, {binmode => ':raw'}, $buffer);
} else {
    print $bufr->reencode_message($dumped_message, $width);
}

=pod

=head1 SYNOPSIS

  bufr_reencode.pl <file containing decoded BUFR message(s)>
       [--outfile <file to print encoded BUFR message(s) to>]
       [--width n]
       [--strict_checking n]
       [--tablepath <path to BUFR tables>]
       [--verbose n]
       [--help]

=head1 DESCRIPTION

Encode BUFR messages from a file containing decoded BUFR messages
from bufrread.pl (possibly edited). Prints to STDOUT unless option
C<--outfile> is used.

Execute without arguments for Usage, with option --help for some
additional info.

See L</OPTIONS> for normal use.

=head1 OPTIONS

Bufr_reencode.pl will create BUFR message(s) printed to STDOUT from
content of input file, which should match exactly what you would get
by running bufrread.pl on the final BUFR message(s).

Normal use:

     bufr_reencode.pl bufr.decoded > reencoded.bufr

after first having done

     bufrread.pl 'BUFR file' > bufr.decoded
     Edit file bufr.decoded as desired

Options (may be abbreviated, e.g. C<--h> or C<-h> for C<--help>):

   --outfile <filename>  Will print encoded BUFR messages to <filename>
                         instead of STDOUT
   --width n             The decoded message(s) was created by using
                         bufrread.pl with option --width n
   --strict_checking n   n=0 Disable strict checking of BUFR format
                         n=1 Issue warning if (recoverable) error in
                             BUFR format
                         n=2 (default) Croak if (recoverable) error in BUFR format.
                             Nothing more in this message will be encoded.
   --verbose n           Set verbose level to n, 0<=n<=3 (default 0).
                         Verbose output is sent to STDOUT, so ought to
                         be combined with option --outfile
   --tablepath <path to BUFR tables>
                         If used, will set path to BUFR tables. If not set,
                         will fetch tables from the environment variable
                         BUFR_TABLES, or if this is not set: will use
                         DEFAULT_TABLE_PATH hard coded in source code.
   --help                Display Usage and explain the options used. Almost
                         the same as consulting perldoc bufrencode.pl

=head1 CAVEAT

'Optional section present' in section 1 of BUFR message will always be
set to 0, as reencode_message in Geo::BUFR currently does not provide
encoding of section 2. A warning will be printed to STDERR if
'Optional section present' originally was 1.

=head1 AUTHOR

P�l Sannes E<lt>pal.sannes@met.noE<gt>

=head1 COPYRIGHT

Copyright (C) 2010 met.no

=cut
