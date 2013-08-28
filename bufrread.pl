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
use Getopt::Long;
use Pod::Usage qw(pod2usage);
use Geo::BUFR;

# Will be used if neither --tablepath nor $ENV{BUFR_TABLES} is set
use constant DEFAULT_TABLE_PATH => '/usr/local/lib/bufrtables';
# Ought to be your most up-to-date C table
use constant DEFAULT_CTABLE => 'C0000000000000019000';

# Parse command line options
my %option = ();
GetOptions(
           \%option,
           'all_operators',# Show all operator descriptors when printing section 4
           'bitmap',       # Display bit mapped values on same line
           'codetables',   # Use code and flag tables to resolve values
           'data_only',    # Print section 4 (data section) only
           'filter=s',     # Decode observations meeting criteria in <filter file> only
           'help',         # Print help information and exit
           'noqc',         # Do not decode quality control
           'on_error_stop', # Stop processing if an error occurs
           'optional_section',  # Display a hex dump of optional section if present
           'outfile=s',    # Print to file instead of STDOUT
           'param=s',      # Decode parameters with descriptors in <descriptor file> only
           'strict_checking=i', # Enable/disable strict checking of BUFR format
           'tablepath=s',  # Set BUFR table path
           'verbose=i',    # Set verbose level to n, 0<=n<=3 (default 0)
           'width=i',      # Set width of values field (default is 15 characters)
       ) or pod2usage(-verbose => 0);

# User asked for help
pod2usage(-verbose => 1) if $option{help};

# Make sure there is at least one input file
pod2usage(-verbose => 0) unless @ARGV;

# Set verbosity level
Geo::BUFR->set_verbose($option{verbose}) if $option{verbose};

# Set whether quality information should be decoded for the BUFR module
Geo::BUFR->set_noqc() if ($option{noqc});

Geo::BUFR->set_strict_checking($option{strict_checking}) if defined $option{strict_checking};

Geo::BUFR->set_show_all_operators($option{all_operators}) if defined $option{all_operators};

# Set BUFR table path
if ($option{tablepath}) {
    # Command line option --tablepath overrides all
    Geo::BUFR->set_tablepath($option{tablepath});
} elsif ($ENV{BUFR_TABLES}) {
    # If no --tablepath option, use the BUFR_TABLES environment variable
    Geo::BUFR->set_tablepath($ENV{BUFR_TABLES});
} else {
    # If all else fails, use the libbufr bufrtables
    Geo::BUFR->set_tablepath(DEFAULT_TABLE_PATH);
}

# Where to direct output (including verbose output, but not output to STDERR)
my $OUT;
if ($option{outfile}) {
    open($OUT, '>', $option{outfile})
        or die "Cannot open $option{outfile} for writing: $!";
} else {
    $OUT = *STDOUT;
}

my @requested_desc;
if ($option{param}) {
    @requested_desc = read_descriptor_file($option{param});
}

# Arrays over filter criteria, used if option --filter is set
my @fid;      # Filter descriptors, .e.g. $fid[1] = [ 001001, 001002 ]
my @fiv;      # Filter values, e.g. $fiv[1] = [ [ 3, 895 ], [ 6 252 ] ]
my @num_desc; # Number of filter descriptors for each criterion, e.g. $num_desc[1] = 2
my @num_val;  # Number of filter value lines for each criterion, e.g. $num_val[1] = 2
my @required; # 1 for required criteria (D!: in filter file), 0 for others
my $num_criteria = 0;
my $num_required_criteria = 0;
if ($option{filter}) {
    read_filter_file($option{filter});
}

my $width = $option{width} ? $option{width} : 15;

# Used to display section 2 if --optional_section is set
my $sec2_code_ref = sub {return '    Hex dump:'.' 'x26 . unpack('H*',substr(shift,4))};

# Loop for processing of BUFR input files
foreach my $inputfname ( @ARGV ) {
    my $bufr = Geo::BUFR->new();

    # Open BUFR file
    $bufr->fopen($inputfname);

    # Process input file
    decode($bufr);
    $bufr->fclose();
}


# Extract data from BUFR file. Print WMO ahl for first message in
# each WMO bulletin, print message number for each new message, print
# subset number for each subset.
sub decode {
    my $bufr = shift;          # BUFR object

    my ($message_header, $current_message_number, $current_ahl);
    my $section013_dumped = 0; # Used to keep track of whether sections
                               # 0-3 have been printed when --filter
                               # option has been used
  READLOOP:
    while (not $bufr->eof()) {

        # Read next observation. If an error is encountered during
        # decoding, skip this observation while printing the error
        # message to STDERR, also displaying ahl of bulletin if found.
        my ($data, $descriptors);
        eval {
            ($data, $descriptors) = $bufr->next_observation();
        };
        if ($@) {
            warn $@;
            # Try to extract message number and ahl of the bulletin
            # where the error occurred
	    $current_message_number = $bufr->get_current_message_number();
	    if ($current_message_number) {
		my $error_msg = "In message $current_message_number";
		$current_ahl = $bufr->get_current_ahl();
		$error_msg .= " contained in bulletin with ahl $current_ahl\n"
		    if $current_ahl;
		warn $error_msg if $error_msg;
	    }
            exit(1) if $option{on_error_stop};
            next READLOOP;
        }

        if ($option{codetables}) {
            # Load C table, trying first to use same table version as
            # the B and D tables loaded in next_observation, or if
            # this C table file does not exist, loads DEFAULT_CTABLE
            # instead.
            my $table_version = $bufr->get_table_version();
            $bufr->load_Ctable("C$table_version", DEFAULT_CTABLE);
        }

        my $current_subset_number = $bufr->get_current_subset_number();
        my $nsubsets = $bufr->get_number_of_subsets();

        if ($current_subset_number == 1) {
            $current_message_number = $bufr->get_current_message_number();
            $current_ahl = $bufr->get_current_ahl() || '';
            $message_header = sprintf "\nMessage %d", $current_message_number;
            $message_header .= (defined $current_ahl)
                ? "  $current_ahl\n" : "\n";

            $section013_dumped = 0;
            next READLOOP if ($option{filter}
                && filter_observation($bufr, $data, $descriptors));

            print $OUT $message_header;

            if (not $option{data_only}) {
                print $OUT $bufr->dumpsection0();
                print $OUT $bufr->dumpsection1();
                print $OUT $bufr->dumpsection2($sec2_code_ref)
                    if $option{optional_section};
                print $OUT $bufr->dumpsection3();
                $section013_dumped = 1;
            }
        } else { # subset number > 1
            next READLOOP if ($option{filter}
                && filter_observation($bufr, $data, $descriptors));

            # If subset 1 was filtered away, section 0-3 might not
            # have been printed yet
            if ($option{filter} and not $option{data_only}
                 and not $section013_dumped)  {
                print $OUT $bufr->dumpsection0();
                print $OUT $bufr->dumpsection1();
                print $OUT $bufr->dumpsection2($sec2_code_ref)
                    if $option{optional_section};
                print $OUT $bufr->dumpsection3();
                $section013_dumped = 1;
            }
        }

        if ($option{param}) {
            # Reduce data and descriptors to those requested only
            ($data, $descriptors)
                = param($data, $descriptors, @requested_desc);
        }

        # If this is last message and there is a BUFR formatting
        # error, we might end up here with current subset number 0
        last READLOOP if $current_subset_number == 0;

	printf $OUT "\nSubset %d\n", $current_subset_number;

	# If an error is encountered during dumping of section 4, skip
	# this subset while printing the error message to STDERR, also
	# displaying ahl of bulletin if found.
	my $dump;
	eval {
	    $dump = ( $option{bitmap} )
		? $bufr->dumpsection4_with_bitmaps($data, $descriptors,
						   $current_subset_number, $width)
		: $bufr->dumpsection4($data, $descriptors, $width);
	};
	if ($@) {
	    warn $@;
	    my $error_msg = "In message $current_message_number"
		. " and subset $current_subset_number";
	    $error_msg .= " contained in bulletin with ahl $current_ahl\n"
		if $current_ahl;
	    warn $error_msg;
	    exit(1) if $option{on_error_stop};
	    next READLOOP;
	} else {
	    print $OUT $dump;
	}
    }
}

sub read_descriptor_file {
    my $descriptor_file = shift;

    open my $fh, '<', $descriptor_file
        or die "Cannot open $descriptor_file: $!";
    my @requested_desc;
    while (<$fh>) {
        next unless /^\s*(\d{6})/;
        push @requested_desc, $1;
    }
    close $fh or die "Cannot close $descriptor_file: $!";
    return @requested_desc;
}

# Reduce the data to those corresponding to the requested descriptors
# only.
sub param {
    my ($data, $descriptors, @requested_desc) = @_;

    my (@req_data, @req_desc);
    my $i = 0;
    foreach my $id ( @{$descriptors} ) {
        if (grep { $id == $_ } @requested_desc) {
            push @req_data, $data->[$i];
            push @req_desc, $id;
        }
        $i++;
    }
    return (\@req_data, \@req_desc);
}


###################################################################################

# Filter routines

# Read in content of $filter_file into variables @fid, @fiv,
# @num_desc, @num_val and $num_criteria, which are defined above.
sub read_filter_file {
    my $filter_file = shift;

    open my $fh, '<', $filter_file
        or die "Cannot open $filter_file: $!";
    while (<$fh>) {
        # Remove comments and skip blank lines
        s/#.*//;
        next if /^\s*$/;

        if (s/^\s*D(!)?://) {
            my @desc = split;
            # Check that all descriptors are numbers
            foreach my $desc (@desc) {
                die "'$desc' cannot be a descriptor in line $. in filter file '$filter_file'"
                    if $desc !~/^\d+$/;
            }
            # Save the criterium
            $num_desc[++$num_criteria] = @desc;
            $num_val[$num_criteria] = 0;
            $fid[$num_criteria] = \@desc;
            $required[$num_criteria] = $1 ? 1 : 0;
            $num_required_criteria++ if $1;
        } else {
            my @values = split;
            # Remove leading 0's in numerical values (to prepare for string comparison)
            for $_ (@values) { s/^0+(\d+)$/$1/ };
            $fiv[$num_criteria]->[++$num_val[$num_criteria]] = \@values;
        }
    }
    close $fh or die "Cannot close $filter_file: $!";
    return;
}

# Return true (observations should be filtered) if the observation
# does not meet all of the D! criteria (if exists) and does not meet
# any one of the other criteria (if exists) in filter file.
sub filter_observation {
    my $bufr = shift;
    die "Error in filter_observation: argument not a BUFR object"
        unless ref($bufr) eq 'Geo::BUFR';
    my ($data, $descriptors) = @_;

    my $num_ordinary_criteria = @fid - $num_required_criteria;
    my $num_success_req_criteria = 0; # Number of required criteria successfully fulfilled
    my $num_success_ord_criteria = 0; # Number of ordinary criteria successfully fulfilled

    # loop through all different criteria:
  CRITERIA: foreach my $filter_criterion (1 .. $num_criteria) {
        if ($num_val[$filter_criterion] == 0) {
            # Enough to check that the descriptor(s) are present in observation
            my $nmatch = 0;
            # loop through all descriptors in criterion:
            foreach my $idesc (0 .. $num_desc[$filter_criterion] - 1) {
                my $filter_desc = $fid[$filter_criterion]->[$idesc];
                for (my $j = 0; $j < @{$descriptors}; $j++) {
                    if ($descriptors->[$j] == $filter_desc) {
                        $nmatch++; # Matched!
                        if ($nmatch == $num_desc[$filter_criterion]) {
                            # All descriptors for this line in this criterion matched.
                            # Do we need to check more criteria?
                            if ($required[$filter_criterion]) {
                                $num_success_req_criteria++;
                                if ($num_success_req_criteria == $num_required_criteria
                                    and ($num_ordinary_criteria == 0
                                         or $num_success_ord_criteria > 0)) {
                                    return 0; # Don't filter this observation
                                }
                            } else {
                                $num_success_ord_criteria++;
                                if ($num_success_req_criteria == $num_required_criteria) {
                                    return 0; # Don't filter this observation
                                }
                            }
                        }
                    }
                }
            }
        } else {
            # loop through all filter values lines (for given) criterion:
          LINE: foreach my $line (1 .. $num_val[$filter_criterion]) {
                my $nmatch = 0;
                # loop through all descriptors in criterion:
              DESC: foreach my $idesc (0 .. $num_desc[$filter_criterion] - 1) {
                    my $filter_desc = $fid[$filter_criterion]->[$idesc];
                    # loop through all data in subset:
                    for (my $j = 0; $j < @{$descriptors}; $j++) {
                        if ($descriptors->[$j] == $filter_desc) {
                            next DESC if !defined $data->[$j];
                            (my $val = $data->[$j]) =~ s/^\s*(.*?)\s*$/$1/;
                            if ($val eq $fiv[$filter_criterion]->[$line]->[$idesc]) {
                                $nmatch++; # Matched!
                                if ($nmatch == $num_desc[$filter_criterion]) {
                                    # All descriptors for this line in this criterion matched.
                                    # Do we need to check more criteria?
                                    if ($required[$filter_criterion]) {
                                        $num_success_req_criteria++;
                                        if ($num_success_req_criteria == $num_required_criteria
                                            and ($num_ordinary_criteria == 0
                                                 or $num_success_ord_criteria > 0)) {
                                            return 0; # Don't filter this observation
                                        }
                                    } else {
                                        $num_success_ord_criteria++;
                                        if ($num_success_req_criteria == $num_required_criteria) {
                                            return 0; # Don't filter this observation
                                        }
                                    }
                                } else {
                                    next DESC;
                                }
                            } else {
                                # Found the descriptor, but wrong value
                                next LINE;
                            }
                        }
                    }
                } # End of filter descriptor loop
            } # End of value line loop
        }
    } # End of criteria loop

    # One required criterion not fulfilled, or if there are no
    # required criteria: none of the non-required criteria fulfilled
    # (so the observation should be filtered away)
    return 1;
}

=pod

=head1 SYNOPSIS

  bufrread.pl <bufr file(s)>
      [--codetables]
      [--data_only]
      [--param <descriptor file>]
      [--filter <filter file>]
      [--bitmap]
      [--noqc]
      [--outfile <filename>]
      [--optional_section]
      [--width n]
      [--strict_checking n]
      [--on_error_stop]
      [--all_operators]
      [--tablepath <path to BUFR tables>]
      [--verbose n]
      [--help]

=head1 DESCRIPTION

Extract BUFR messages from BUFR file(s) and print the decoded content
to screen. Will include WMO ahl if the BUFR message is part of a WMO
bulletin.

Execute without arguments for Usage, with option C<--help> for some
additional info. See also L</https://wiki.met.no/bufr.pm/start> for
examples of use.


=head1 OPTIONS

   --codetables    Use code and flag tables to resolve values when unit
                   is [CODE TABLE] or [FLAG TABLE]
   --data_only     Print section 4 (data section) only
   --param <descriptor file>
                   Display parameters with descriptors in <descriptor file> only
   --filter <filter file>
                   Decode observations meeting criteria in <filter file> only
   --bitmap        Display bit mapped values on same line
   --noqc          Do not decode quality control
                   (or any descriptors following 222000)
   --outfile <filename>
                   Will print to <filename> instead of STDOUT
   --optional_section
                   Display a hex dump of optional section if present
   --width n       Set width of field used for data values to n characters
                   (default is 15)
   --strict_checking n n=0 (default) Disable strict checking of BUFR format
                       n=1 Issue warning if (recoverable) error in
                           BUFR format
                       n=2 Croak if (recoverable) error in BUFR format.
                           Nothing more in this message/subset will be decoded.
   --on_error_stop Stop processing as soon as an error occurs during decoding
   --all_operators Show all operator descriptors when printing section 4
   --tablepath <path to BUFR tables>
                   Set path to BUFR tables (overrides ENV{BUFR_TABLES})
   --verbose n     Set verbose level to n, 0<=n<=5 (default 0). n=1 will
                   show the tables loaded.
   --help          Display Usage and explain the options used. For even
                   more info you might prefer to consult perldoc bufrread.pl

Options may be abbreviated, e.g. C<--h> or C<-h> for C<--help>.

To avoid having to use the C<--tablepath> option, you are adviced to
set the invironment variable BUFR_TABLES to the directory where your
BUFR tables are located (unless the default path provided by
bufrread.pl works for you).

Each line in <descriptor file> should start with a BUFR descriptor (6
digits).  Rest of line will be ignored. bufrread.pl will display values
for these descriptors only.

Using C<--filter> will decode only those observations that meet one of
the criteria in <filter file> (and all of those criteria marked
D!). Comments (starting with #) are ignored. An example of a filter
file is

  D: 001001
  1
  D: 001001 001002
  3 895
  6 252
  D: 001011
  LF5U       # Ekofisk
  D!: 004004
  6
  7

which decodes all observations with block number 01, two other
specific WMO stations and one specific ship, all of which having hour
(004004) equal to 6 or 7.  If there is no value line after a
descriptor line, it is enough that the observation contains the
descriptor(s), whatever the values are. So to extract all ship
messages from a BUFR SYNOP file, the filter file should contain this
single line only:

  D: 001011

If an error occurs during decoding (typically because the required
BUFR table is missing or message is corrupt) the message is skipped,
and the number of errors is reported at end of output. You can change
this default behaviour, however, by setting C<--on_error_stop>.

=head1 AUTHOR

P�l Sannes E<lt>pal.sannes@met.noE<gt>

=head1 COPYRIGHT

Copyright (C) 2010 met.no

=cut
