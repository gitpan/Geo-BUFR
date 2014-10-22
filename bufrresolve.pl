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
# Ought to be your most up-to-date B table
use constant DEFAULT_TABLE => 'B0000000000098013001';

# Parse command line options
my %option = ();

GetOptions(
           \%option,
           'tablepath=s',# Set BUFR table path
           'code=s',     # Print the content of code table
           'flag=i',     # Resolve the flag value given
           'help',       # Print help information and exit
           'noexpand',   # Don't expand D descriptors
           'partial',    # Expand D descriptors only once, ignoring
                         # replication
           'simple',     # Like 'partial', but displaying the resulting
                         # descriptors on one line
           'bufrtable=s',# Set BUFR tables
           'verbose',    # Display path and tables used
       ) or pod2usage(-verbose => 0);


# User asked for help
pod2usage(-verbose => 1) if $option{help};

# No arguments if --code or --flag, else there should be at least one argument
if (defined $option{code} or defined $option{flag}) {
    pod2usage(-verbose => 0) if @ARGV;
} else {
    pod2usage(-verbose => 0) if not @ARGV;
}

# If --flag is set, user must also provide code table
pod2usage(-verbose => 0) if defined $option{flag} and !defined $option{code};

# All arguments must be integers
foreach (@ARGV) {
    pod2usage("All arguments must be integers!") unless /^\d+$/;
}

# Set verbosity level for the BUFR module
my $verbose = $option{verbose} ? 1 : 0;
Geo::BUFR->set_verbose($verbose);

# The other BUFR utility programs expect an argument to verbose
if ($verbose && ($ARGV[0] eq '1' || $ARGV[0] eq '2' || $ARGV[0] eq '3')) {
    die "\nWARNING: Option --verbose takes no argument,"
        . " but your '$ARGV[0]' looks suspiciously like one.\n"
            . "Please try again (use '00000$ARGV[0]'"
                . " if you really meant to provide that descriptor)\n";
}

# Set BUFR table path
if ($option{tablepath}) {
    # Command line option --tablepath overrides all
    Geo::BUFR->set_tablepath($option{tablepath});
} elsif ($ENV{BUFR_TABLES}) {
    # If no --tablepath option, use the BUFR_TABLES environment variable
    Geo::BUFR->set_tablepath($ENV{BUFR_TABLES});
} else {
    # If all else fails, use the libemos bufrtables
    Geo::BUFR->set_tablepath(DEFAULT_TABLE_PATH);
}

# BUFR table file to use
my $table = $option{bufrtable} || DEFAULT_TABLE;

my $bufr = Geo::BUFR->new();

if (defined $option{code}) {
    # Resolve flag value or dump code table
    my $code_table = $option{code};
    if (defined $option{flag}) {
        print $bufr->resolve_flagvalue($option{flag}, $code_table, $table);
    } else {
        print $bufr->dump_codetable($code_table, $table);
    }
} else {
    # Resolve descriptor(s)
    $bufr->load_BDtables($table);
    if ($option{simple}) {
        print $bufr->resolve_descriptor('simply', @ARGV);
    } elsif ($option{partial}) {
        print $bufr->resolve_descriptor('partially', @ARGV);
    } elsif ($option{noexpand}) {
        print $bufr->resolve_descriptor('noexpand', @ARGV);
    } else {
        print $bufr->resolve_descriptor('fully', @ARGV);
    }
}

=pod

=head1 SYNOPSIS

  1) bufrresolve.pl <descriptor(s)>
     [--partial]
     [--simple]
     [--noexpand]
     [--bufrtable <name of BUFR B or D table]
     [--tablepath <path to BUFR tables>]
     [--verbose]
     [--help]

  2) bufrresolve.pl --code <code_table>
     [--bufrtable <name of BUFR B or D table>]
     [--tablepath <path to BUFR tables>]
     [--verbose]

  3) bufrresolve.pl --flag <value> --code <flag_table>
     [--bufrtable <name of BUFR B or D table]
     [--tablepath <path to BUFR tables>]
     [--verbose]

=head1 DESCRIPTION

Utility program for fetching info from BUFR tables.

Execute without arguments for Usage, with option C<--help> for some
additional info. See also L</https://wiki.met.no/bufr.pm/start> for
examples of use.

It is supposed that the code and flag tables are contained in a file
with same name as corresponding B and D tables except for having
prefix C instead of B or D. The tables used can be chosen by the user
with options C<--bufrtable> and C<--tablepath>. Default is the hard
coded DEFAULT_TABLE in directory DEFAULT_TABLE_PATH, but this last one
will be overriden if the environment variable BUFR_TABLES is set. You
should consider edit the source code if you are not satisfied with the
defaults chosen.

=head1 OPTIONS

   --partial    Expand D descriptors only once, ignoring replication
   --simple     Like --partial, but displaying the resulting
                descriptors on one line
   --noexpand   Don't expand D descriptors at all

   --bufrtable <name of BUFR B or D table>  Set BUFR tables
   --tablepath <path to BUFR tables>  Set BUFR table path
   --verbose    Display path and tables used

   --help       Display Usage and explain the options used. Almost
                the same as consulting perldoc bufrresolve.pl

Usage 1): Resolves the given descriptor(s) fully into table B
descriptors, with name, unit, scale, reference value and width (in
bits) written on each line (except for --simple). --partial, --simple
and --noexpand are mutually exclusive (full expansion is default).

Usage 2): Prints the content of code or flag table <code_table>.

Usage 3): Displays the bits set for flag value <value> in flag table
<flag_table>.

Options may be abbreviated, e.g. C<--h> or C<-h> for C<--help>

=head1 AUTHOR

P�l Sannes E<lt>pal.sannes@met.noE<gt>

=head1 COPYRIGHT

Copyright (C) 2010 met.no

=cut
