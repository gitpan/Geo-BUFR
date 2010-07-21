package Geo::BUFR;

# Copyright (C) 2010 met.no
#
# This module is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

=begin General_remarks

Some general remarks on variables
---------------------------------

@data = data array
@desc = descriptor array

These 2 arrays are in one to one correspondence, but note that some C
descriptors (2.....) are included in @desc even though there is no
associated data value in message (the corresponding element in @data
is set to ''). These descriptors without value are printed in
dumpsection4 without line number, to distinguish them from 'real' data
descriptors.

$idesc = index of descriptor in @desc (and @data)
$bm_idesc = index of bit mapped descriptor in @data (and @desc, see below)

Variables related to bit maps:

$self->{BUILD_BITMAP}
$self->{BITMAP_INDEX}
$self->{NUM_BITMAPS}

These are explained in sub new

$self->{CURRENT_BITMAP}

Reference to an array which contains the indexes of data values for
which data is marked as present in 031031 in the current used bit map.

$self->{LAST_BITMAP}

Contains a copy of last $self->{CURRENT_BITMAP}. While
$self->{CURRENT_BITMAP} is shifted every time a new bit mapped value
is extracted, $self->{LAST_BITMAP} is kept intact, and can therefore
be used to recreate $self->{CURRENT_BITMAP} when 237000 'Use defined
data present bit-map' is encountered.

$self->{BITMAP_OPERATORS}

Reference to an array containing operators in BUFR table C which are
associated with bit maps, i.e. one of 22[2-5]000 and 232000; the
operator being added when it is met in section 3 in message. Note that
an operator may occur multiple times, which is why we have to use an
array, not a hash.

$self->{BITMAPS}

Reference to an array, one element added for each bit map operator in
$self->{BITMAP_OPERATORS}, the element being a reference to an array
containing consecutive pairs of indexes ($idesc, $bm_idesc), used to
look up in @data and @desc arrays for the value/descriptor and
corresponding bit mapped value/descriptor.

For operator 222000 ('Quality information follows') the bit mapped
descriptor should be a 033-descriptor. For 22[3-5] the bit mapped
value should be the data value of the 22[3-5]255 descriptors following
the operator in BUFR section 3, with bit mapped descriptor
$desc[bm_idesc] equal to $desc[$idesc] (with data width and reference
value changed for 225255)

=end General_remarks

=cut

require 5.006;
use strict;
use warnings;
use Carp;
use FileHandle;
use File::Spec::Functions qw(catfile);
use Scalar::Util qw(looks_like_number);
use Time::Local qw(timegm);
# Also requires Storable if sub copy_from() is called

require DynaLoader;
our @ISA = qw(DynaLoader);
our $VERSION = '1.16';

# This loads BUFR.so, the compiled version of BUFR.xs, which
# contains bitstream2dec, bitstream2ascii, dec2bitstream,
# ascii2bitstream and null2bitstream
bootstrap Geo::BUFR $VERSION;


# Some package globals
our $Verbose = 0;
our $Noqc = 0; # If set to true will prevent decoding (or encoding) of
               # any descriptors after 222000 is met
our $Strict_checking = 0; # Ignore recoverable errors in BUFR format
                          # met during decoding. User might set
                          # $Strict_checking to 1: Issue warning
                          # (carp) but continue decoding, or to 2:
                          # Croak instead of carp
our $Show_all_operators = 0; # = 0: show just the most informative C operators in dumpsection4
                             # = 1: show all operators (as far as possible)

our %BUFR_table;
# Keys: PATH      -> full path to the chosen directory of BUFR tables
#       B$version -> hash containing the B table $BUFR_table/B$version
#                    key: element descriptor (6 digits)
#                    value: a \0 separated string containing the B table fields
#                            $name, $unit, $scale, $refval, $bits
#       C$version -> hash containing the C table $BUFR_table/C$version
#                    key: table B descriptor (6 digits) of the code/flag table
#                    value: a new hash, with keys the possible values listed in
#                           the code table, the value the corresponding text
#       D$version -> hash containing the D table $BUFR_table/D$version
#                    key: sequence descriptor
#                    value: a space separated string containing the element
#                    descriptors (6 digits) the sequence descriptor expands to

our %Descriptors_already_expanded;
# Keys: Text string "$table_version $unexpanded_descriptors"
# Values: Space separated string of expanded descriptors

sub _croak {
    my $msg = shift;
    croak "BUFR.pm ERROR: $msg";
}

## Carp or croak (or ignore) according to value of $Strict_checking
sub _complain {
    my $msg = shift;
    if ($Strict_checking == 1) {
        carp "BUFR.pm WARNING: $msg";
    } elsif ($Strict_checking > 1) {
        croak "BUFR.pm ERROR: $msg";
    }
    return;
}

sub _spew {
    my $self = shift;
    my $level = shift;
    return unless $level <= (ref($self) ? $self->{VERBOSE} : $Verbose);
    my $format = shift;
    if (@_) {
        printf "BUFR.pm: $format\n", @_;
    } else {
        print "BUFR.pm: $format\n";
    }
    return;
}

## Object constructor
sub new {
    my $class = shift;
    my $self = {};
    $self->{VERBOSE} = 0;
    $self->{CURRENT_MESSAGE} = 0;
    $self->{CURRENT_SUBSET} = 0;
    $self->{ALREADY_EXPANDED} = {};
    $self->{BUILD_BITMAP} = 0; # Will be set to 1 if a bit map needs to
                               # be built
    $self->{BITMAP_INDEX} = 0; # Used for building up bit maps; will
                               # be incremented for each 031031
                               # encountered, then reset to 0 when bit
                               # map is finished built
    $self->{NUM_BITMAPS} = 0;  # Will be incremented each time an
                               # operator descriptor which uses a bit
                               # map is encountered in section 3

    # If number of arguments is odd, first argument is expected to be
    # a string containing the BUFR message(s)
    if (@_ % 2) {
        $self->{IN_BUFFER} = shift;
    }

    # This part is not documented in the POD. Better to remove it?
    while (@_) {
        my $parameter = shift;
        my $value = shift;
        $self->{$parameter} = $value;
    }
    bless $self, ref($class) || $class;
    return $self;
}

## Copy content of the bufr object in first argument. With no extra
## arguments, will copy (clone) everything. With 'metadata' as second
## argument, will copy just the metadata in section 0, 1 and 3
sub copy_from {
    my $self = shift;
    my $bufr = shift;
    _croak("First argument to copy_from must be a Geo::BUFR object")
        unless ref($bufr) eq 'Geo::BUFR';
    my $what = shift || 'all';
    if ($what eq 'metadata') {
        for (qw(
            BUFR_EDITION
            MASTER_TABLE CENTRE SUBCENTRE UPDATE_NUMBER OPTIONAL_SECTION
            DATA_CATEGORY INT_DATA_SUBCATEGORY LOC_DATA_SUBCATEGORY
            MASTER_TABLE_VERSION LOCAL_TABLE_VERSION YEAR MONTH DAY
            HOUR MINUTE SECOND LOCAL_USE DATA_SUBCATEGORY YEAR_OF_CENTURY
            NUM_SUBSETS OBSERVED_DATA COMPRESSED_DATA DESCRIPTORS_UNEXPANDED
            )) {
            if (exists $bufr->{$_}) {
                $self->{$_} = $bufr->{$_};
            } else {
                # This cleanup might be necessary if BUFR edition changes
                delete $self->{$_} if exists $self->{$_};
            }
        }
    } elsif ($what eq 'all') {
        $self = {};
        while (my ($key, $value) = each %{$bufr}) {
            if ($key eq 'FILEHANDLE') {
                # If a file has been associated with the copied
                # object, make a new filehandle rather than just
                # copying the reference
                $self->fopen($bufr->{FILENAME});
            } elsif (ref($value) and $key !~ /[BCD]_TABLE/) {
                # Copy the whole structure, not merely the reference.
                # Using Clone would be cheaper, but unfortunately
                # Clone is not a core module, while Storable is
                require Storable;
                import Storable qw(dclone);
                $self->{$key} = dclone($value);
            } else {
                $self->{$key} = $value;
            }
        }
    } else {
        _croak("Don't recognize second argument '$what' to copy_from()");
    }
    return 1;
}


##  Set debug level
sub set_verbose {
    my $self = shift;
    if (ref($self)) {
        # Just myself
        $self->{VERBOSE} = shift;
        $self->_spew(2, "Verbosity level set to $self->{VERBOSE}");
    } else {
        # Whole class
        $Verbose = shift;
        Geo::BUFR->_spew(2, "Verbosity level for class set to $Verbose");
    }
    return 1;
}

##  Turn off (or on) decoding of quality information
sub set_noqc {
    my $self = shift;
    my $n = shift;
    $Noqc = defined $n ? $n : 1; # Default is 1
    Geo::BUFR->_spew(2, "Noqc set to $Noqc for class");
    return 1;
}

##  Require strict checking of BUFR format
sub set_strict_checking {
    my $self = shift;
    my $n = shift;
    _croak "Value for strict checking not provided"
        unless defined $n;
    $Strict_checking = $n;
    Geo::BUFR->_spew(2, "Strict_checking set to $Strict_checking for class");
    return 1;
}

## Show all (or only the really important) operators when calling dumpsection4
sub set_show_all_operators {
    my $self = shift;
    my $n = shift;
    $Show_all_operators = defined $n ? $n : 1; # Default in BUFR.pm is 0
    Geo::BUFR->_spew(2, "Show_all_operators set to $Show_all_operators for class");
    return 1;
}

## Accessor methods for BUFR sec0-3 ##
sub set_bufr_edition {
    my ($self, $bufr_edition) = @_;
    _croak "BUFR edition number not provided in set_bufr_edition"
        unless defined $bufr_edition;
    _croak "BUFR edition number must be an integer, is '$bufr_edition'"
        unless $bufr_edition =~ /^\d+$/;
    _croak "Not an allowed value for BUFR edition number: $bufr_edition"
        unless $bufr_edition > 1 and $bufr_edition < 5;
    $self->{BUFR_EDITION} = $bufr_edition;
    return 1;
}
sub get_bufr_edition {
    my $self = shift;
    return defined $self->{BUFR_EDITION} ? $self->{BUFR_EDITION}: undef;
}
sub set_master_table {
    my ($self, $master_table) = @_;
    _croak "BUFR master table not provided in set_master_table"
        unless defined $master_table;
    _croak "BUFR master table must be an integer, is '$master_table'"
        unless $master_table =~ /^\d+$/;
    # Max value that can be stored in 1 byte is 255
    _croak "BUFR master table exceeds limit 255, is '$master_table'"
        if $master_table > 255;
    $self->{MASTER_TABLE} = $master_table;
    return 1;
}
sub get_master_table {
    my $self = shift;
    return defined $self->{MASTER_TABLE} ? $self->{MASTER_TABLE} : undef;
}
sub set_centre {
    my ($self, $centre) = @_;
    _croak "Originating/generating centre not provided in set_centre"
        unless defined $centre;
    _croak "Originating/generating centre must be an integer, is '$centre'"
        unless $centre =~ /^\d+$/;
    # Max value that can be stored in 2 bytes is 65535
    _croak "Originating/generating centre exceeds limit 65535, is '$centre'"
        if $centre > 65535;
    $self->{CENTRE} = $centre;
    return 1;
}
sub get_centre {
    my $self = shift;
    return defined $self->{CENTRE} ? $self->{CENTRE} : undef;
}
sub set_subcentre {
    my ($self, $subcentre) = @_;
    _croak "Originating/generating subcentre not provided in set_subcentre"
        unless defined $subcentre;
    _croak "Originating/generating subcentre must be an integer, is '$subcentre'"
        unless $subcentre =~ /^\d+$/;
    _croak "Originating/generating subcentre exceeds limit 65535, is '$subcentre'"
        if $subcentre > 65535;
    $self->{SUBCENTRE} = $subcentre;
    return 1;
}
sub get_subcentre {
    my $self = shift;
    return defined $self->{SUBCENTRE} ? $self->{SUBCENTRE} : undef;
}
sub set_update_sequence_number {
    my ($self, $update_number) = @_;
    _croak "Update sequence number not provided in set_update_sequence_number"
        unless defined $update_number;
    _croak "Update sequence number must be a non negative integer, is '$update_number'"
        unless $update_number =~ /^\d+$/;
    _croak "Update sequence number exceeds limit 255, is '$update_number'"
        if $update_number > 255;
    $self->{UPDATE_NUMBER} = $update_number;
    return 1;
}
sub get_update_sequence_number {
    my $self = shift;
    return defined $self->{UPDATE_NUMBER} ? $self->{UPDATE_NUMBER} : undef;
}
sub set_optional_section {
    my ($self, $optional_section) = @_;
    _croak "Optional section (0 or 1) not provided in set_optional_section"
        unless defined $optional_section;
    _croak "Optional section must be 0 or 1, is '$optional_section'"
        unless $optional_section eq '0' or $optional_section eq '1';
    $self->{OPTIONAL_SECTION} = $optional_section;
    return 1;
}
sub get_optional_section {
    my $self = shift;
    return defined $self->{OPTIONAL_SECTION} ? $self->{OPTIONAL_SECTION} : undef;
}
sub set_data_category {
    my ($self, $data_category) = @_;
    _croak "Data category not provided in set_data_category"
        unless defined $data_category;
    _croak "Data category must be an integer, is '$data_category'"
        unless $data_category =~ /^\d+$/;
    _croak "Data category exceeds limit 255, is '$data_category'"
        if $data_category > 255;
    $self->{DATA_CATEGORY} = $data_category;
    return 1;
}
sub get_data_category {
    my $self = shift;
    return defined $self->{DATA_CATEGORY} ? $self->{DATA_CATEGORY} : undef;
}
sub set_int_data_subcategory {
    my ($self, $int_data_subcategory) = @_;
    _croak "International data subcategory not provided in set_int_data_subcategory"
        unless defined $int_data_subcategory;
    _croak "International data subcategory must be an integer, is '$int_data_subcategory'"
        unless $int_data_subcategory =~ /^\d+$/;
    _croak "International data subcategory exceeds limit 255, is '$int_data_subcategory'"
        if $int_data_subcategory > 255;
    $self->{INT_DATA_SUBCATEGORY} = $int_data_subcategory;
    return 1;
}
sub get_int_data_subcategory {
    my $self = shift;
    return defined $self->{INT_DATA_SUBCATEGORY}
        ? $self->{INT_DATA_SUBCATEGORY}
            : undef;
}
sub set_loc_data_subcategory {
    my ($self, $loc_data_subcategory) = @_;
    _croak "Local subcategory not provided in set_loc_data_subcategory"
        unless defined $loc_data_subcategory;
    _croak "Local data subcategory must be an integer, is '$loc_data_subcategory'"
        unless $loc_data_subcategory =~ /^\d+$/;
    _croak "Local data subcategory exceeds limit 255, is '$loc_data_subcategory'"
        if $loc_data_subcategory > 255;
    $self->{LOC_DATA_SUBCATEGORY} = $loc_data_subcategory;
    return 1;
}
sub get_loc_data_subcategory {
    my $self = shift;
    return defined $self->{LOC_DATA_SUBCATEGORY} ? $self->{LOC_DATA_SUBCATEGORY} : undef;
}
sub set_data_subcategory {
    my ($self, $data_subcategory) = @_;
    _croak "Data subcategory not provided in set_data_subcategory"
        unless defined $data_subcategory;
    _croak "Data subcategory must be an integer, is '$data_subcategory'"
        unless $data_subcategory =~ /^\d+$/;
    _croak "Data subcategory exceeds limit 255, is '$data_subcategory'"
        if $data_subcategory > 255;
    $self->{DATA_SUBCATEGORY} = $data_subcategory;
    return 1;
}
sub get_data_subcategory {
    my $self = shift;
    return defined $self->{DATA_SUBCATEGORY} ? $self->{DATA_SUBCATEGORY} : undef;
}
sub set_master_table_version {
    my ($self, $master_table_version) = @_;
    _croak "Master table version not provided in set_master_table_version"
        unless defined $master_table_version;
    _croak "BUFR master table version must be an integer, is '$master_table_version'"
        unless $master_table_version =~ /^\d+$/;
    _croak "BUFR master table version exceeds limit 255, is '$master_table_version'"
        if $master_table_version > 255;
    $self->{MASTER_TABLE_VERSION} = $master_table_version;
    return 1;
}
sub get_master_table_version {
    my $self = shift;
    return defined $self->{MASTER_TABLE_VERSION}
        ? $self->{MASTER_TABLE_VERSION}
            : undef;
}
sub set_local_table_version {
    my ($self, $local_table_version) = @_;
    _croak "Local table version not provided in set_local_table_version"
        unless defined $local_table_version;
    _croak "Local table version must be an integer, is '$local_table_version'"
        unless $local_table_version =~ /^\d+$/;
    _croak "Local table version exceeds limit 255, is '$local_table_version'"
        if $local_table_version > 255;
    $self->{LOCAL_TABLE_VERSION} = $local_table_version;
    return 1;
}
sub get_local_table_version {
    my $self = shift;
    return defined $self->{LOCAL_TABLE_VERSION}
        ? $self->{LOCAL_TABLE_VERSION}
            : undef;
}
sub set_year_of_century {
    my ($self, $year_of_century) = @_;
    _croak "Year of century not provided in set_year_of_century"
        unless defined $year_of_century;
    _croak "Year of century must be an integer, is '$year_of_century'"
        unless $year_of_century =~ /^\d+$/;
    _complain "year_of_century > 100 in set_year_of_century: $year_of_century"
        if $year_of_century > 100;
    # A common mistake is to set year_of_century for year 2000 to 0, should be 100
    $self->{YEAR_OF_CENTURY} = ($year_of_century == 0) ? 100 : $year_of_century;
    return 1;
}
sub get_year_of_century {
    my $self = shift;
    if (defined $self->{YEAR_OF_CENTURY}) {
        return $self->{YEAR_OF_CENTURY};
    } elsif (defined $self->{YEAR}) {
        my $yy = $self->{YEAR} % 100;
        return ($yy == 0) ? 100 : $yy;
    } else {
        return undef;
    }
}
sub set_year {
    my ($self, $year) = @_;
    _croak "Year not provided in set_year"
        unless defined $year;
    _croak "Year must be an integer, is '$year'"
        unless $year =~ /^\d+$/;
    _croak "Year exceeds limit 65535, is '$year'"
        if $year > 65535;
    $self->{YEAR} = $year;
    return 1;
}
sub get_year {
    my $self = shift;
    return defined $self->{YEAR} ? $self->{YEAR} : undef;
}
sub set_month {
    my ($self, $month) = @_;
    _croak "Month not provided in set_month"
        unless defined $month;
    _croak "Month must be an integer, is '$month'"
        unless $month =~ /^\d+$/;
    _complain "Month must be 1-12 in set_month, is '$month'"
        if $month == 0 || $month > 12;
    $self->{MONTH} = $month;
    return 1;
}
sub get_month {
    my $self = shift;
    return defined $self->{MONTH} ? $self->{MONTH} : undef;
}
sub set_day {
    my ($self, $day) = @_;
    _croak "Day not provided in set_day"
        unless defined $day;
    _croak "Day must be an integer, is '$day'"
        unless $day =~ /^\d+$/;
    _complain "Day must be 1-31 in set_day, is '$day'"
        if $day == 0 || $day > 31;
    $self->{DAY} = $day;
    return 1;
}
sub get_day {
    my $self = shift;
    return defined $self->{DAY} ? $self->{DAY} : undef;
}
sub set_hour {
    my ($self, $hour) = @_;
    _croak "Hour not provided in set_hour"
        unless defined $hour;
    _croak "Hour must be an integer, is '$hour'"
        unless $hour =~ /^\d+$/;
    _complain "Hour must be 0-23 in set_hour, is '$hour'"
        if $hour > 23;
    $self->{HOUR} = $hour;
    return 1;
}
sub get_hour {
    my $self = shift;
    return defined $self->{HOUR} ? $self->{HOUR} : undef;
}
sub set_minute {
    my ($self, $minute) = @_;
    _croak "Minute not provided in set_minute"
        unless defined $minute;
    _croak "Minute must be an integer, is '$minute'"
        unless $minute =~ /^\d+$/;
    _complain "Minute must be 0-59 in set_minute, is '$minute'"
        if $minute > 59;
    $self->{MINUTE} = $minute;
    return 1;
}
sub get_minute {
    my $self = shift;
    return defined $self->{MINUTE} ? $self->{MINUTE} : undef;
}
sub set_second {
    my ($self, $second) = @_;
    _croak "Second not provided in set_second"
        unless defined $second;
    _croak "Second must be an integer, is '$second'"
        unless $second =~ /^\d+$/;
    _complain "Second must be 0-59 in set_second, is '$second'"
        if $second > 59;
    $self->{SECOND} = $second;
    return 1;
}
sub get_second {
    my $self = shift;
    return defined $self->{SECOND} ? $self->{SECOND} : undef;
}
sub set_local_use {
    my ($self, $local_use) = @_;
    _croak "Local use not provided in set_local use"
        unless defined $local_use;
    $self->{LOCAL_USE} = $local_use;
    return 1;
}
sub get_local_use {
    my $self = shift;
    return defined $self->{LOCAL_USE} ? $self->{LOCAL_USE} : undef;
}
sub set_number_of_subsets {
    my ($self, $number_of_subsets) = @_;
    _croak "Number of subsets not provided in set_number_of_subsets"
        unless defined $number_of_subsets;
    _croak "Number of subsets must be an integer, is '$number_of_subsets'"
        unless $number_of_subsets =~ /^\d+$/;
    _croak "Number of subsets exceeds limit 65535, is '$number_of_subsets'"
        if $number_of_subsets > 65535;
    $self->{NUM_SUBSETS} = $number_of_subsets;
    return 1;
}
sub get_number_of_subsets {
    my $self = shift;
    return defined $self->{NUM_SUBSETS} ? $self->{NUM_SUBSETS} : undef;
}
sub set_observed_data {
    my ($self, $observed_data) = @_;
    _croak "Observed data (0 or 1) not provided in set_observed_data"
        unless defined $observed_data;
    _croak "Observed data must be 0 or 1, is '$observed_data'"
        unless $observed_data eq '0' or $observed_data eq '1';
    $self->{OBSERVED_DATA} = $observed_data ? 128 : 0; # 128 = 2**8
    return 1;
}
sub get_observed_data {
    my $self = shift;
    return defined $self->{OBSERVED_DATA}
        ? vec( $self->{OBSERVED_DATA},0,1 )
            : undef;
}
sub set_compressed_data {
    my ($self, $compressed_data) = @_;
    _croak "Compressed data (0 or 1) not provided in set_compressed_data"
        unless defined $compressed_data;
    _croak "Compressed data must be 0 or 1, is '$compressed_data'"
        unless $compressed_data eq '0' or $compressed_data eq '1';
    _complain "Not allowed to use compression for one subset messages!"
        if $compressed_data
            and defined $self->{NUM_SUBSETS} and $self->{NUM_SUBSETS} == 1;
    $self->{COMPRESSED_DATA} = $compressed_data ? 64 : 0; # 64 = 2**7
    return 1;
}
sub get_compressed_data {
    my $self = shift;
    return defined $self->{COMPRESSED_DATA}
        ? vec($self->{COMPRESSED_DATA},1,1)
            : undef;
}
sub set_descriptors_unexpanded {
    my ($self, $descriptors_unexpanded) = @_;
    _croak "Unexpanded descriptors not provided in set_descriptors_unexpanded"
        unless defined $descriptors_unexpanded;
    $self->{DESCRIPTORS_UNEXPANDED} = $descriptors_unexpanded;
    return 1;
}
sub get_descriptors_unexpanded {
    my $self = shift;
    return defined $self->{DESCRIPTORS_UNEXPANDED}
        ? $self->{DESCRIPTORS_UNEXPANDED}
            : undef;
}
#############################################
## End of accessor methods for BUFR sec0-3 ##
#############################################

sub get_current_subset_number {
    my $self = shift;
    return defined $self->{CURRENT_SUBSET} ? $self->{CURRENT_SUBSET}: undef;
}

sub get_current_message_number {
    my $self = shift;
    return defined $self->{CURRENT_MESSAGE} ? $self->{CURRENT_MESSAGE}: undef;
}

sub get_current_ahl {
    my $self = shift;
    return defined $self->{CURRENT_AHL} ? $self->{CURRENT_AHL}: undef;
}

##  Set the path for BUFR table files
##  Usage: Geo::BUFR->set_tablepath(directory_list)
##         where directory_list is a list of colon-separated strings.
##  Example: Geo::BUFR->set_tablepath("/foo/bar:/foo/baz", "/some/where/else")
sub set_tablepath {
    my $self = shift;

    $BUFR_table{PATH} = join ":", map {split /:/} @_;
    Geo::BUFR->_spew(2, "BUFR table path set to $BUFR_table{PATH}");
    return 1;
}

sub get_tablepath {
    my $self = shift;

    if (exists $BUFR_table{PATH}) {
        return wantarray() ? split(/:/, $BUFR_table{PATH}) : $BUFR_table{PATH};
    } else {
        return '';
    }
}

## Return table version from table if provided, or else from section 1
## information in BUFR message. Returns undef if impossible to
## determine table version.
sub get_table_version {
    my $self = shift;
    my $table = shift;

    if ($table) {
        (my $version = $table) =~ s/^(?:[BCD]?)(.*?)(?:\.TXT)?$/$1/;
        return $version;
    }

    # No table provided. Decide version from section 1 information.
    # First check that the necessary metadata exist
    foreach my $metadata (qw(BUFR_EDITION MASTER_TABLE
                             LOCAL_TABLE_VERSION CENTRE SUBCENTRE)) {
        return undef if ! defined $self->{$metadata};
    }

    # If master table version, use centre 0 and subcentre 0 (in ECMWF
    # libbufr this is the convention from version 320 onwards)
    my $centre = $self->{CENTRE};
    my $subcentre = $self->{SUBCENTRE};
    my $local_table_version = $self->{LOCAL_TABLE_VERSION};
    if ($local_table_version == 0 || $local_table_version == 255) {
        $centre = 0;
        $subcentre = 0;
    }

    # Use ECMWF table naming convention (used in version >= 000270 of libbufr)
    return sprintf "%03d%05d%05d%03d%03d",
        $self->{MASTER_TABLE}, $subcentre, $centre,
            $self->{MASTER_TABLE_VERSION}, $local_table_version;
}

# Search through $BUFR_table{PATH} and return first path for which
# $fname exists, undef if file $fname is not contained in any paths.
sub _locate_table {
    my $fname = shift;

    _croak "BUFR table path not set, did you forget to call set_tablepath()?"
        unless $BUFR_table{PATH};

    my $path;
    foreach (split /:/, $BUFR_table{PATH}) {
        if (-e catfile($_, $fname)) {
            $path = $_;
            last;
        }
    }
    return undef if not $path;

    $path =~ s|/$||;
    return $path;
}

## Read in a B table file into a hash, e.g.
##  $B_table{'001001'} = "WMO BLOCK NUMBER\0NUMERIC\0  0\0           0\0  7"
## where the B table values for 001001 are \0 (NUL) separated
sub _read_B_table {
    my $version = shift;
    my $fname = "B$version.TXT";
    my $path = _locate_table($fname)
        or _croak "Couldn't find BUFR table $fname in $BUFR_table{PATH}."
            . "Wrong tablepath?";

    my %B_table;

    my $tablefile = catfile($path, $fname);
    open(my $TABLE, '<', $tablefile)
        or _croak "Couldn't open BUFR table B $tablefile: $!";
    Geo::BUFR->_spew(1, "Reading table $tablefile");

    while (<$TABLE>) {
        my ($s1,$fxy,$s2,$name,$s3,$unit,$s4,$scale,$s5,$refval,$s6,$bits)
            = unpack('AA6AA64AA24AA3AA12AA3', $_);
        next unless defined $bits;
        $name =~ s/\s+$//;
        $refval =~ s/-\s+(\d+)/-$1/; # Remove blanks between minus sign and value
        $B_table{$fxy} = join "\0", $name, $unit, $scale, $refval, $bits;
    }
    # When installing Geo::BUFR on Windows Vista with Strawberry Perl,
    # close sometimes returned an empty string. Therefore removed
    # check on return value for close.
    close $TABLE; # or _croak "Closing $tablefile failed: $!";

    $BUFR_table{"B$version"} = \%B_table;
    return \%B_table;
}

## Read the flag and code tables, which in ECMWF libbufr tables are
## put in tables C$version.TXT (not to be confused with BUFR C tables,
## which contain the operator descriptors). Note that even though
## number of code values and number of lines are included in the
## tables, we choose to ignore them, because these values are often
## found to be in error. Instead we trust that the text starts at
## fixed positions in file. Returns reference to the C table, or undef
## if failing to open table file.
sub _read_C_table {
    my $version = shift;

    my $fname = "C$version.TXT";
    my $path = _locate_table($fname) || return undef;

    my $tablefile = catfile($path, $fname);
    open(my $TABLE, '<', $tablefile)
        or _croak "Couldn't open BUFR table C $tablefile: $!";
    Geo::BUFR->_spew(1, "Reading table $tablefile");

    my (%C_table, $table, $value);
    while (my $line = <$TABLE>) {
        $line =~ s/\s+$//;
        next if $line =~ /^\s*$/; # Blank line

        if (substr($line,0,15) eq ' ' x 15) {
            $line =~ s/^\s+//;
            next if $line eq 'NOT DEFINED' || $line eq 'RESERVED';
            $C_table{$table}{$value} .= $line . "\n";
        } elsif (substr($line,0,10) eq ' ' x 10) {
            $line =~ s/^\s+//;
            my ($val, $nlines, $txt) = split /\s+/, $line, 3;
            $value = $val+0;
            next if !defined $txt || $txt eq 'NOT DEFINED' || $txt eq 'RESERVED';
            $C_table{$table}{$value} .= $txt . "\n";
        } else {
            my ($tbl, $nval, $val, $nlines, $txt) = split /\s+/, $line, 5;
            $table = sprintf "%06d", $tbl;
            $value = $val+0;
            next if !defined $txt || $txt eq 'NOT DEFINED' || $txt eq 'RESERVED';
            $C_table{$table}{$value} = $txt . "\n";
        }
    }
    close $TABLE; # or _croak "Closing $tablefile failed: $!";

    $BUFR_table{"C$version"} = \%C_table;
    return \%C_table;
}

## Reads a D table file into a hash, e.g.
##  $D_table{307080} = '301090 302031 ...'
## There are two different types of lines in D*.TXT, e.g.
##  307080 13 301090 BUFR template for synoptic reports
##            302031
## We choose to ignore the number of lines in expansion (here 13)
## because this number is sometimes in error. Instead we consider a
## line starting with 5 spaces to be of the second type above, else of
## the first type
sub _read_D_table {
    my $version = shift;
    my $fname = "D$version.TXT";
    my $path = _locate_table($fname)
        or _croak "Couldn't find BUFR table $fname in $BUFR_table{PATH}."
            . "Wrong tablepath?";

    my $tablefile = catfile($path, $fname);
    open(my $TABLE, '<', $tablefile)
        or _croak "Couldn't open BUFR table D $tablefile: $!";
    Geo::BUFR->_spew(1, "Reading table $tablefile");

    my (%D_table, $alias);
    while (my $line = <$TABLE>) {
        $line =~ s/\s+$//;
        next if $line =~ /^\s*$/; # Blank line

        if (substr($line,0,5) eq ' ' x 5) {
            $line =~ s/^\s+//;
            $D_table{$alias} .= " $line";
        } else {
            $line =~ s/^\s+//;
            my ($ali, $n, $desc) = split /\s+/, $line;
            $alias = $ali;
            $D_table{$alias} = $desc;
        }
    }
    close $TABLE; # or _croak "Closing $tablefile failed: $!";

    $BUFR_table{"D$version"} = \%D_table;
    return \%D_table;
}

sub load_BDtables {
    my $self = shift;
    my $table = shift || '';

    my $version = $self->get_table_version($table)
        or _croak "Not enough info to decide which tables to load";

    $self->{B_TABLE} = $BUFR_table{"B$version"} || _read_B_table($version);
    $self->{D_TABLE} = $BUFR_table{"D$version"} || _read_D_table($version);
    return $version;
}


sub load_Ctable {
    my $self = shift;
    my $table = shift || '';
    my $default_table = shift || '';

    my $version = $self->get_table_version($table) || '';
    _croak "Not enough info to decide which C table to load"
        if not $version and not $default_table;

    $self->{C_TABLE} = $BUFR_table{"C$version"} || _read_C_table($version);
    if ($default_table and not $self->{C_TABLE}) {
        # Was not able to load $table. Try $default_table instead.
        $version = $self->get_table_version($default_table);
        _croak "Not enough info to decide which C table to load"
            if not $version;
        $self->{C_TABLE} = $BUFR_table{"C$version"} || _read_C_table($version);
    }
    _croak "Unable to load C table" if not $self->{C_TABLE};
    return $version;
}


##  Specify BUFR file to read
sub fopen {
    my $self = shift;
    my $filename = shift
        or _croak "fopen() called without an argument";
    _croak "File $filename doesn't exist!" unless -e $filename;

    # Open file for reading
    $self->{FILEHANDLE} = new FileHandle;
    open $self->{FILEHANDLE}, '<', $filename
        or _croak "Couldn't open file $filename for reading";

    $self->_spew(2, "File '$filename' opened for reading");

    # For some OS this is necessary
    binmode $self->{FILEHANDLE};

    $self->{FILENAME} = $filename;
    return 1;
}

sub fclose {
    my $self = shift;
    if ($self->{FILEHANDLE}) {
        close $self->{FILEHANDLE}
            or _croak "Couldn't close BUFR file opened by fopen()";
        $self->_spew(2, "Closed file '$self->{FILENAME}'");
    }
    delete $self->{FILEHANDLE};
    delete $self->{FILENAME};
    # Much more might be considered deleted here, but usually the bufr
    # object goes out of scope immediately after a fclose anyway
    return 1;
}

sub eof {
    my $self = shift;
    return ($self->{EOF} || 0);
}

# Go to start of input buffer or start of file associated with the object
sub rewind {
    my $self = shift;
    if (exists $self->{FILEHANDLE}) {
        seek $self->{FILEHANDLE}, 0, 0 or _croak "Cannot seek: $!";
    } elsif (! $self->{IN_BUFFER}) {
        _croak "Cannot rewind: no file or input buffer associated with this object";
    }
    $self->{CURRENT_MESSAGE} = 0;
    $self->{CURRENT_SUBSET} = 0;
    delete $self->{POS};
    delete $self->{EOF};
    return 1;
}

## Read in next BUFR message from file if $self->{FILEHANDLE} is set,
## else from $self->{IN_BUFFER} (string argument to constructor). Also
## decodes section 0 and updates $self->{CURRENT_AHL} if a WMO ahl is
## found (implemented for file reading only). Sets $self->{POS} to end
## of BUFR message. Sets $self->{LAST_MESSAGE} if no more 'BUFR' in
## file or input buffer. Croaks if there are no BUFR messages at all in
## file/buffer or error in reading BUFR message

## Returns BUFR message from section 1 on, BUFR edition, total length
## of message, and $sec0 (section 0 except 'BUFR' part).
sub _read_message {
    my $self = shift;

    my $filehandle = $self->{FILEHANDLE} ? $self->{FILEHANDLE} : undef;
    my $in_buffer = $self->{IN_BUFFER} ? $self->{IN_BUFFER} : undef;
    _croak "_read_message: Neither BUFR file nor BUFR text is given"
        unless $filehandle or $in_buffer;

    # According to 2.3.1.1 in Manual On The GTS there are two
    # possibilities for the starting line of a WMO bulletin
    my $ahl_regexp = qr{(?:ZCZC|\001\r\r\n) ?\d*\r\r\n(.+)\r\r};
    $self->{CURRENT_AHL} = undef;

    # Locate next 'BUFR' and set $pos to this position in file/string,
    # also finding last WMO ahl before this (for file only)
    my $pos = (defined $self->{POS}) ? $self->{POS} : 0;
    if ($filehandle) {
        my $oldeol = $/;
        $/ = 'BUFR';
        my $slurp = <$filehandle> || '    ';
        $/ = $oldeol;
        # If this is first read, check that we really did find 'BUFR'
        if ($pos == 0 and substr($slurp,-4) ne 'BUFR') {
            $pos = -1;
        } else {
            $pos = tell($filehandle) - 4;
        }

        # Get last WMO ahl (TTAAii CCCC DTG [BBB]) before 'BUFR', if present
        while ( $slurp =~ /$ahl_regexp/go ) {
            $self->{CURRENT_AHL} = $1;
        }
    } elsif ($in_buffer) {
        # Locate next 'BUFR' in string argument to constructor
        $pos = index($in_buffer, 'BUFR', $pos);
    }

    if ($pos < 0) {
        # This should only happen if there is no 'BUFR' in file/buffer
        $self->{EOF} = 1;
        if ($filehandle) {
            _croak "No BUFR message in file '$self->{FILENAME}'"
        } else {
            _croak "No BUFR message found";
        }
    }

    # Report (if verbose setting) where we found the BUFR message
    $self->_spew(2, "BUFR message at position %d", $pos);

    # Read (rest) of Section 0 (length of BUFR message and edition number)
    my $sec0;                   # Section 0 is BUFR$sec0
    if ($filehandle) {
        if ((read $filehandle, $sec0, 4) != 4) {
            $self->{EOF} = 1;
            _croak "Error reading section 0 in file '$self->{FILENAME}', position "
                . tell($filehandle);
        }
    } else {
        if (length($in_buffer) < $pos + 8) {
            $self->{EOF} = 1;
            _croak "Error reading section 0: this is not a BUFR message?"
        }
        $sec0 = substr $in_buffer, $pos + 4, 4;
    }

    # Extract length and edition number
    my ($length, $edition) = unpack 'NC', "\0$sec0";
    $self->_spew(2, "Message length: %d, Edition: %d", $length, $edition);

    # Read rest of BUFR message (section 1-5)
    my $msg;
    if ($filehandle) {
        if ((read $filehandle, $msg, $length-8) != $length-8) {
            $self->{EOF} = 1;
            _croak "BUFR message truncated or 'BUFR' is not start of "
                . "a real BUFR message in file '$self->{FILENAME}'";
        }
        $pos = tell($filehandle);
    } else {
        if (length($in_buffer) < $pos + $length) {
            $self->{EOF} = 1;
            _croak "BUFR message truncated or 'BUFR' is not start of "
                . " a real BUFR message";
        }
        $msg = substr $in_buffer, $pos + 8, $length - 8;
        $pos += $length;
    }
    $self->_spew(2, "Successfully read BUFR message; position now %d", $pos);

    # Reset $self->{POS} to end of BUFR message
    $self->{POS} = $pos;

    # Is this last BUFR message?
    if (not $self->_find_next_BUFR($filehandle, $in_buffer, $pos)) {
        $self->_spew(2, "Last BUFR message (reached end of file)");
        $self->{LAST_MESSAGE} = 1;
    }

    return ($msg, $edition, $length, $sec0);
}

## See if there is another BUFR message, for easy EOF handling
## (actually, we only search for another 'BUFR'), returning 1 if there
## is, else returning 0
sub _find_next_BUFR {
    my $self = shift;
    my ($filehandle, $in_buffer, $pos) = @_;

    if ($filehandle) {
        my $oldeol = $/;
        $/ = "BUFR";
        <$filehandle>;
        $/ = $oldeol;
        if (CORE::eof($filehandle)) {
            return 0;
        } else {
            # Reset position of filehandle
            seek $filehandle, $pos, 0;
        }
    } else {
        my $new_pos = index($in_buffer, 'BUFR', $pos);
        if ($new_pos < 0) {
            return 0;
        }
    }
    return 1;
}

sub _decode_sections {
    my $self = shift;
    my ($msg, $edition, $length, $sec0) = @_;

    _croak "Cannot handle BUFR edition $edition"
        if $edition < 2 || $edition > 4;

    $self->{BUFR_STREAM}  = $msg;
    $self->{SEC0_STREAM}  = "BUFR$sec0";
    $self->{SEC1_STREAM}  = undef;
    $self->{SEC2_STREAM}  = undef;
    $self->{SEC3_STREAM}  = undef;
    $self->{SEC4_STREAM}  = undef;
    $self->{SEC5_STREAM}  = undef;
    $self->{BUFR_LENGTH}  = $length;
    $self->{BUFR_EDITION} = $edition;

    ##  Decode Section 1 (Identification Section)  ##

    $self->_spew(2, "Decoding section 1");

    # Extract Section 1 information
    if ($self->{BUFR_EDITION} < 4) {
        # N means 4 byte integer, so put an extra null byte ('\0') in
        # front of string to get first 3 bytes as integer
        my @sec1 =  unpack 'NC14', "\0" . $self->{BUFR_STREAM};

        # Check that stated length of section 1 makes sense
        _croak "Length of section 1 too small (< 17): $sec1[0]"
            if $sec1[0] < 17;
        _croak "Rest of BUFR message shorter (" . length($self->{BUFR_STREAM})
            . " bytes) than stated length of section 1 ($sec1[0] bytes)"
                if $sec1[0] > length($self->{BUFR_STREAM});

        push @sec1, (unpack 'a*', substr $self->{BUFR_STREAM},17,$sec1[0]-17);
        $self->{SEC1_STREAM} = substr $self->{BUFR_STREAM}, 0, $sec1[0];
        $self->{BUFR_STREAM} = substr $self->{BUFR_STREAM}, $sec1[0];
        $self->{SEC1}                 = \@sec1;
        $self->{MASTER_TABLE}         = $sec1[1];
        $self->{SUBCENTRE}            = $sec1[2];
        $self->{CENTRE}               = $sec1[3];
        $self->{UPDATE_NUMBER}        = $sec1[4];
        $self->{OPTIONAL_SECTION}     = $sec1[5] & 0x80;
        $self->{DATA_CATEGORY}        = $sec1[6];
        $self->{DATA_SUBCATEGORY}     = $sec1[7];
        $self->{MASTER_TABLE_VERSION} = $sec1[8];
        $self->{LOCAL_TABLE_VERSION}  = $sec1[9];
        $self->{YEAR_OF_CENTURY}      = $sec1[10];
        $self->{MONTH}                = $sec1[11];
        $self->{DAY}                  = $sec1[12];
        $self->{HOUR}                 = $sec1[13];
        $self->{MINUTE}               = $sec1[14];
        $self->{LOCAL_USE}            = $sec1[15];
    } elsif ($self->{BUFR_EDITION} == 4) {
        my @sec1 =  unpack 'NCnnC7nC5', "\0" . $self->{BUFR_STREAM};

        # Check that stated length of section 1 makes sense
        _croak "Length of section 1 too small (< 22): $sec1[0]"
            if $sec1[0] < 22;
        _croak "Rest of BUFR message shorter (" . length($self->{BUFR_STREAM})
            . " bytes) than stated length of section 1 ($sec1[0] bytes)"
                if $sec1[0] > length($self->{BUFR_STREAM});

        push @sec1, (unpack 'a*', substr $self->{BUFR_STREAM},22,$sec1[0]-22);
        $self->{SEC1_STREAM} = substr $self->{BUFR_STREAM}, 0, $sec1[0];
        $self->{BUFR_STREAM} = substr $self->{BUFR_STREAM}, $sec1[0];
        $self->{SEC1}                 = \@sec1;
        $self->{MASTER_TABLE}         = $sec1[1];
        $self->{CENTRE}               = $sec1[2];
        $self->{SUBCENTRE}            = $sec1[3];
        $self->{UPDATE_NUMBER}        = $sec1[4];
        $self->{OPTIONAL_SECTION}     = $sec1[5] & 0x80;
        $self->{DATA_CATEGORY}        = $sec1[6];
        $self->{INT_DATA_SUBCATEGORY} = $sec1[7];
        $self->{LOC_DATA_SUBCATEGORY} = $sec1[8];
        $self->{MASTER_TABLE_VERSION} = $sec1[9];
        $self->{LOCAL_TABLE_VERSION}  = $sec1[10];
        $self->{YEAR}                 = $sec1[11];
        $self->{MONTH}                = $sec1[12];
        $self->{DAY}                  = $sec1[13];
        $self->{HOUR}                 = $sec1[14];
        $self->{MINUTE}               = $sec1[15];
        $self->{SECOND}               = $sec1[16];
        $self->{LOCAL_USE}            = $sec1[17] if $sec1[0] > 22;
    }

    $self->_validate_datetime() if ($Strict_checking);

    ##  Decode Section 2 (Optional Section) if present  ##

    $self->_spew(2, "Decoding section 2");

    if ($self->{OPTIONAL_SECTION}) {
        my @sec2 = unpack 'N', "\0" . $self->{BUFR_STREAM};

        # Check that stated length of section 2 makes sense
        _croak "Length of section 2 too small (< 4): $sec2[0]"
            if $sec2[0] < 4;
        _croak "Rest of BUFR message shorter (" . length($self->{BUFR_STREAM})
            . " bytes) than stated length of section 2 ($sec2[0] bytes)"
                if $sec2[0] > length($self->{BUFR_STREAM});

        push @sec2, substr $self->{BUFR_STREAM}, 4, $sec2[0]-4;
        $self->{SEC2_STREAM} = substr $self->{BUFR_STREAM}, 0, $sec2[0];
        $self->{BUFR_STREAM} = substr $self->{BUFR_STREAM}, $sec2[0];
        $self->{SEC2} = \@sec2;
    } else {
        $self->{SEC2} = undef;
        $self->{SEC2_STREAM} = undef;
    }

    ##  Decode Section 3 (Data Description Section)  ##

    $self->_spew(2, "Decoding section 3");

    my @sec3 = unpack 'NCnC', "\0".$self->{BUFR_STREAM};

    # Check that stated length of section 3 makes sense
    _croak "Length of section 3 too small (< 8): $sec3[0]"
        if $sec3[0] < 8;
    _croak "Rest of BUFR message shorter (" . length($self->{BUFR_STREAM})
        . " bytes) than stated length of section 3 ($sec3[0] bytes)"
            if $sec3[0] > length($self->{BUFR_STREAM});

    push @sec3, substr $self->{BUFR_STREAM},7,($sec3[0]-7)&0x0ffe; # $sec3[0]-7 will be reduced by one if odd integer,
                                                                   # so will not push last byte if length of sec3 is even,
                                                                   # which might happen for BUFR edition < 4 (padding byte)
    $self->{SEC3_STREAM} = substr $self->{BUFR_STREAM}, 0, $sec3[0];
    $self->{BUFR_STREAM} = substr $self->{BUFR_STREAM}, $sec3[0];

    $self->{SEC3}             = \@sec3;
    $self->{NUM_SUBSETS}      = $sec3[2];
    $self->{OBSERVED_DATA}    = $sec3[3] & 0x80; # extraxt 1. bit in the 2 byte sec3[3]
    $self->{COMPRESSED_DATA}  = $sec3[3] & 0x40; # extract 2. bit

    ##  Decode Section 4 (Data Section)  ##

    $self->_spew(2, "Decoding section 4");

    my $sec4_len = unpack 'N', "\0$self->{BUFR_STREAM}";

    # Check that stated length of section 4 makes sense
    _croak "Length of section 4 too small (< 4): $sec4_len"
        if $sec4_len < 4;
    _croak "Rest of BUFR message shorter (" . length($self->{BUFR_STREAM})
        . " bytes) than stated length of section 4 ($sec4_len bytes)"
            if $sec4_len > length($self->{BUFR_STREAM});

    $self->{SEC4_STREAM}  = substr $self->{BUFR_STREAM}, 0, $sec4_len;
    $self->{SEC4_RAWDATA} = substr $self->{BUFR_STREAM}, 4, $sec4_len-4;
    $self->{BUFR_STREAM}  = substr $self->{BUFR_STREAM}, $sec4_len;

    ##  Decode Section 5 (End Section)  ##

    $self->_spew(2, "Decoding section 5");

    _croak "Section 5 is not '7777' but: 0x"
        . (map {sprintf "%02X", $_} unpack('C*', $self->{BUFR_STREAM}))
            unless $self->{BUFR_STREAM} eq '7777';

    return $self;
}


##  Read next BUFR message and decode. Set $self->{ERROR_IN_MESSAGE} if
##  anything goes seriously wrong, so that sub next_observation can use
##  this to skip to next message if user choose to trap the call to
##  next_observation in an eval and then calling next_observation again.
sub _next_message {
    my $self = shift;

    $self->_spew(2, "Reading next BUFR message");

    $self->{ERROR_IN_MESSAGE} = 0;

    # Read message (note that sub _read_message also detects if this is
    # last message in file, for which it needs to decode section 0 to
    # get length of message)
    my ($msg, $edition, $length, $sec0) = $self->_read_message();

    # Unpack sections
    eval { $self->_decode_sections($msg, $edition, $length, $sec0) };
    if ($@) {
        $self->{ERROR_IN_MESSAGE} = 1;
        die $@, "\n";  # Could use croak, but then 2 "at ... line ..."
                       # will be printed to STDERR
    }

    $self->{CURRENT_MESSAGE}++;

    # Load the relevant code tables
    my $table_version;
    eval { $table_version = $self->load_BDtables() };
    if ($@) {
        $self->{ERROR_IN_MESSAGE} = 1;
        die $@, "\n";
    }
    $self->_spew(2, "BUFR table version is $table_version");

    # Get the data descriptors and expand them
    my @unexpanded = _int2fxy(unpack 'n*', $self->{SEC3}[4]);
    $self->{DESCRIPTORS_UNEXPANDED} = join ' ', @unexpanded;

    $self->_spew(2, "Expanding data descriptors");
    my $alias = "$table_version " . $self->{DESCRIPTORS_UNEXPANDED};
    if (exists $Descriptors_already_expanded{$alias}) {
        $self->{DESCRIPTORS_EXPANDED}
            = $Descriptors_already_expanded{$alias};
    } else {
        $Descriptors_already_expanded{$alias}
            = $self->{DESCRIPTORS_EXPANDED}
                = join " ", _expand_descriptors($self->{D_TABLE}, @unexpanded);
    }

    # Unpack data from bitstream
    $self->_spew(2, "Unpacking data");
    eval {
        if ($self->{COMPRESSED_DATA}) {
            $self->_decompress_bitstream();
        } else {
            $self->_decode_bitstream();
        }
    };
    if ($@) {
        $self->{ERROR_IN_MESSAGE} = 1;
        die $@, "\n";
    }

    return;
}

##  Get next observation, i.e. next subset in current BUFR message or
##  first subset in next message
sub next_observation {
    my $self = shift;

    $self->_spew(2, "Fetching next observation");
    # Read next BUFR message, if necessary
    if ($self->{ERROR_IN_MESSAGE} && $self->{LAST_MESSAGE}) {
        $self->{EOF} = 1;
        return;
    }
    if ($self->{CURRENT_MESSAGE} == 0
        or $self->{CURRENT_SUBSET} >= $self->{NUM_SUBSETS}
        or $self->{ERROR_IN_MESSAGE}) {

        $self->{CURRENT_SUBSET} = 0;
        # The bit maps must be rebuilt for each message
        undef $self->{BITMAPS};
        undef $self->{BITMAP_OPERATORS};
        $self->{NUM_BITMAPS} = 0;
        # Some more tidying after decoding of previous message might
        # be necessary
        undef $self->{CHANGE_WIDTH};
        undef $self->{CHANGE_SCALE};
        undef $self->{CHANGE_REFERENCE};
        undef $self->{NEW_REFVAL_OF};
        undef $self->{ADD_ASSOCIATED_FIELD};

        $self->_next_message();
    }

    $self->{CURRENT_SUBSET}++;

    # Raise a flag if this is the last observation in the last message
    $self->{EOF} = $self->{LAST_MESSAGE}
                   && ($self->{CURRENT_SUBSET} >= $self->{NUM_SUBSETS});

    # Return references to data and descriptor arrays
    if ($self->{COMPRESSED_DATA}) {
        return ($self->{DATA}[$self->{CURRENT_SUBSET}],
                $self->{DESC});
    } else {
        return ($self->{DATA}[$self->{CURRENT_SUBSET}],
                $self->{DESC}[$self->{CURRENT_SUBSET}]);
    }
}

# Dumping content of a subset (including section 0, 1 and 3 if this is
# first subset) in a BUFR message, also displaying message number and
# ahl (if found) and subset number
sub dumpsections {
    my $self = shift;
    my $data = shift;
    my $descriptors = shift;
    my $options = shift || {};

    my $width = $options->{width} || 15;
    my $bitmap = exists $options->{bitmap} ? $options->{bitmap} : 1;

    my $current_subset_number = $self->get_current_subset_number();
    my $current_message_number = $self->get_current_message_number();
    my $current_ahl = $self->get_current_ahl() || '';

    my $txt;
    if ($current_subset_number == 1) {
        $txt = "\nMessage $current_message_number";
        $txt .= (defined $current_ahl)
            ? "  $current_ahl\n" : "\n";
        $txt .= $self->dumpsection0() . $self->dumpsection1() . $self->dumpsection3();
    }

    # If this is last message and there is a BUFR formatting error
    # caught by user with eval, we might end up here with current
    # subset number 0 (and no section 4 to dump)
    if ($current_subset_number > 0) {
        $txt .= "\nSubset $current_subset_number\n";
        $txt .= $bitmap ? $self->dumpsection4_with_bitmaps($data,$descriptors,$width)
                        : $self->dumpsection4($data,$descriptors,$width);
    }

    return $txt;
}

sub dumpsection0 {
    my $self = shift;
    _croak "BUFR object not properly initialized to call dumpsection0. "
        . "Did you forget to call next_observation()?" unless $self->{BUFR_LENGTH};

    my $txt = <<"EOF";

Section 0:
    Length of BUFR message:            $self->{BUFR_LENGTH}
    BUFR edition:                      $self->{BUFR_EDITION}
EOF
    return $txt;
}

sub dumpsection1 {
    my $self = shift;
    _croak "BUFR object not properly initialized to call dumpsection1. "
        . "Did you forget to call next_observation()?" unless $self->{SEC1_STREAM};

    my $txt;
    if ($self->{BUFR_EDITION} < 4) {
        $txt = <<"EOF";

Section 1:
    Length of section:                 @{[ length $self->{SEC1_STREAM} ]}
    BUFR master table:                 $self->{MASTER_TABLE}
    Originating subcentre:             $self->{SUBCENTRE}
    Originating centre:                $self->{CENTRE}
    Update sequence number:            $self->{UPDATE_NUMBER}
    Optional section present:          @{[vec ($self->{OPTIONAL_SECTION},0,1)]}
    Data category (table A):           $self->{DATA_CATEGORY}
    Data subcategory:                  $self->{DATA_SUBCATEGORY}
    Master table version number:       $self->{MASTER_TABLE_VERSION}
    Local table version number:        $self->{LOCAL_TABLE_VERSION}
    Year of century:                   $self->{YEAR_OF_CENTURY}
    Month:                             $self->{MONTH}
    Day:                               $self->{DAY}
    Hour:                              $self->{HOUR}
    Minute:                            $self->{MINUTE}
EOF
    } else {
        $txt = <<"EOF";

Section 1:
    Length of section:                 @{[ length $self->{SEC1_STREAM} ]}
    BUFR master table:                 $self->{MASTER_TABLE}
    Originating centre:                $self->{CENTRE}
    Originating subcentre:             $self->{SUBCENTRE}
    Update sequence number:            $self->{UPDATE_NUMBER}
    Optional section present:          @{[vec ($self->{OPTIONAL_SECTION},0,1)]}
    Data category (table A):           $self->{DATA_CATEGORY}
    International data subcategory:    $self->{INT_DATA_SUBCATEGORY}
    Local data subcategory:            $self->{LOC_DATA_SUBCATEGORY}
    Master table version number:       $self->{MASTER_TABLE_VERSION}
    Local table version number:        $self->{LOCAL_TABLE_VERSION}
    Year:                              $self->{YEAR}
    Month:                             $self->{MONTH}
    Day:                               $self->{DAY}
    Hour:                              $self->{HOUR}
    Minute:                            $self->{MINUTE}
    Second:                            $self->{SECOND}
EOF
    }
    # Last part of section 1: "Reserved for local use by ADP centres"
    # is considered so uninteresting (and rare), that it is displayed
    # only if verbose >= 2, in a _spew statement. Note that for BUFR
    # edition < 4 there is always one byte here (to make an even
    # number of bytes in section 1).
    $self->_spew(2, "Reserved for local use:             0x@{[unpack('H*', $self->{LOCAL_USE})]}")
        if $self->{LOCAL_USE} and length $self->{LOCAL_USE} > 1;

    return $txt;
}

sub dumpsection2 {
    my $self = shift;
    return '' if not defined $self->{SEC2};

    my $sec2_code_ref = shift;
    _croak "dumpsection2: no code ref provided"
        unless defined $sec2_code_ref && ref($sec2_code_ref) eq 'CODE';

    my $txt = <<"EOF";

Section 2:
    Length of section:                 @{[ length $self->{SEC2_STREAM} ]}
EOF

    return $txt . $sec2_code_ref->($self->{SEC2_STREAM}) . "\n";
}

sub dumpsection3 {
    my $self = shift;
    _croak "BUFR object not properly initialized to call dumpsection3. "
        . "Did you forget to call next_observation()?" unless $self->{SEC3_STREAM};

    my $txt = <<"EOF";

Section 3:
    Length of section:                 @{[ length $self->{SEC3_STREAM} ]}
    Number of data subsets:            $self->{NUM_SUBSETS}
    Observed data:                     @{[vec ($self->{OBSERVED_DATA},0,1)]}
    Compressed data:                   @{[vec ($self->{COMPRESSED_DATA},1,1)]}
    Data descriptors unexpanded:       $self->{DESCRIPTORS_UNEXPANDED}
EOF
    return $txt;
}

sub dumpsection4 {
    my $self = shift;
    my $data = shift;
    my $descriptors = shift;
    my $width = shift || 15;    # Optional argument

    my $txt = "\n";
    my $B_table = $self->{B_TABLE};
    # Add the artificial descriptor for associated field
    $B_table->{999999} = "ASSOCIATED FIELD\0NUMERIC";
    my $C_table = $self->{C_TABLE} || '';
    my $idx = 0;
    my $line_no = 0;    # Precede each line with a line number, except
                        # for operator descriptors with no data value in
                        # section 4
  ID:
    foreach my $id ( @{ $descriptors } ) {
        my $value = defined $data->[$idx] ? $data->[$idx] : 'missing';
        $idx++;
        if ($id =~ /^205/) {    # Character information operator
            $txt .= sprintf "%6d  %06d  %${width}.${width}s  %s\n",
                ++$line_no, $id, $value, "CHARACTER INFORMATION";
            next ID;
        } elsif ($id =~ /^2/) {
            my $operator_name = _get_operator_name($id);
            if ($operator_name) {
                $txt .= sprintf "        %06d  %${width}.${width}s  %s\n",
                    $id, "", $operator_name;
            }
            next ID;
        } elsif ($id =~ /^9/ && $id != 999999) {
            $txt .= sprintf "%6d  %06d  %${width}.${width}s  %s %06d\n",
                ++$line_no, $id, $value, 'NEW REFERENCE VALUE FOR', $id - 900000;
            next ID;
        } elsif ($id == 31031) { # This is the only data descriptor
                                 # where all bits set to one should
                                 # not be rendered as missing value
            $value = 1 if $value eq 'missing';
        }
        _croak "Data descriptor $id is not present in BUFR table B"
            unless exists $B_table->{$id};
        my ($name, $unit, $bits) = (split /\0/, $B_table->{$id})[0,1,4];
        # Code or flag table number equals $id, so no need to display this in [unit]
        my $short_unit = $unit;
        $short_unit = 'CODE TABLE' if $unit =~ /^CODE TABLE/;
        $short_unit = 'FLAG TABLE' if $unit =~ /^FLAG TABLE/;
        $txt .= sprintf "%6d  %06d  %${width}.${width}s  %s\n",
            ++$line_no, $id, $value, "$name [$short_unit]";

        # Check for illegal flag value
        if ($Strict_checking and $unit =~ /^FLAG TABLE/ and $bits > 1) {
            if ($value ne 'missing' and $value % 2) {
                $bits += 0; # get rid of spaces
                my $max_value = 2**$bits - 1;
                _complain("$id - $value: rightmost bit $bits is set indicating missing value"
                          . " but then value should be $max_value");
            }
        }

        # Resolve flag and code table values if code table is loaded
        # (but don't bother about 031031 - too much uninformative output)
        if ($id != 31031 and $value ne 'missing' and $C_table) {
            my $num_spaces = $width + 18;
            $txt .= _get_code_table_txt($id,$value,$unit,$B_table,$C_table,$num_spaces)
        }
    }
    return $txt;
}

# Operators which should always be displayed in dumpsection4
my %OPERATOR_NAME_A =
    ( 222000 => 'QUALITY INFORMATION FOLLOW',
      223000 => 'SUBSTITUTED VALUES FOLLOW',
      224000 => 'FIRST ORDER STATISTICS FOLLOW',
      225000 => 'DIFFERENCE STATISTICAL VALUES FOLLOW',
      232000 => 'REPLACE/RETAINED VALUES FOLLOW',
      235000 => 'CANCEL BACKWARD DATA REFERENCE',
      236000 => 'DEFINE DATA PRESENT BIT MAP',
      237000 => 'USE PREVIOUSLY DEFINED BIT MAP',
 );
# Operators which should normally not be displayed in dumpsection4
my %OPERATOR_NAME_B =
    ( 201000 => 'CANCEL CHANGE DATA WIDTH',
      202000 => 'CANCEL CHANGE SCALE',
      203000 => 'CANCEL CHANGE REFERENCE VALUES',
      203255 => 'STOP CHANGING REFERENCE VALUES',
      223255 => 'SUBSTITUTED VALUES MARKER OPERATOR',
      224255 => 'FIRST ORDER STATISTICAL VALUES MARKER OPERATOR',
      225255 => 'DIFFERENCE STATISTICAL STATISTICAL VALUES MARKER OPERATOR',
      232255 => 'REPLACE/RETAINED VALUES MARKER OPERATOR',
      237255 => 'CANCEL DEFINED DATA PRESENT BIT MAP',
 );
# Operator classes which should normally not be displayed in dumpsection4
my %OPERATOR_NAME_C =
    ( 201 => 'CHANGE DATA WIDTH',
      202 => 'CHANGE SCALE',
      203 => 'CHANGE REFERENCE VALUES',
      204 => 'ADD ASSOCIATED FIELD',
      # This one is displayed, treated specially (and named CHARACTER INFORMATION)
##      205 => 'SIGNIFY CHARACTER',
      206 => 'SIGNIFY DATAWIDTH FOR THE IMMEDIATELY FOLLOWING LOCAL DESCRIPTOR',
      221 => 'DATA NOT PRESENT',
 );
sub _get_operator_name {
    my $id = shift;
    my $operator_name = '';
    if ($OPERATOR_NAME_A{$id}) {
        $operator_name = $OPERATOR_NAME_A{$id}
    } elsif ($Show_all_operators) {
        if ($OPERATOR_NAME_B{$id}) {
            $operator_name = $OPERATOR_NAME_B{$id}
        } else {
            my $fx = substr $id, 0, 3;
            if ($OPERATOR_NAME_C{$fx}) {
                $operator_name = $OPERATOR_NAME_C{$fx};
            }
        }
    }
    return $operator_name;
}

## Display bit mapped values on same line as the original value. This
## offer a much shorter and easier to read dump of section 4 when
## bit maps has been used (i.e. for 222000 quality information, 223000
## substituted values, 224000 first order statistics, 225000 difference
## statistics). '******' is displayed if data is not present in bit map
## (bit set to 1 in 031031), 'missing' is displayed if value is missing.
## But note that we miss other descriptors like 001031 and 001032 if
## these comes after 222000 etc with the current implementation.
sub dumpsection4_with_bitmaps {
    my $self = shift;
    my $data = shift;
    my $descriptors = shift;
    my $width = shift || 15;    # Optional argument

    # If no bit maps call the ordinary dumpsection4
    if (not defined $self->{BITMAPS}) {
        return $self->dumpsection4($data, $descriptors, $width);
    }

    # $Show_all_operators must be turned off for this sub to work correctly
    _croak "Cannot dump section 4 properly with bitmaps"
        . " when Show_all_operators is set" if $Show_all_operators;

    # The kind of bit maps (i.e. the operator descriptors) used in BUFR message
    my @bitmap_desc = @{ $self->{BITMAP_OPERATORS} };

    my @bitmap_array; # Will contain for each bit map a reference to a hash with
                      # key: index (in data and descriptor arrays) for data value
                      # value: index for bit mapped value
    my $txt = "\n";
    my $space = ' ';
    my $line = $space x (17 + $width);
    foreach my $bitmap_num (0..$#bitmap_desc) {
        $line .= " $bitmap_desc[$bitmap_num]";
        # Convert the sequence of ($data_idesc,$bitmapped_idesc) pairs into a hash
        my %hash = @{ $self->{BITMAPS}->[$bitmap_num + 1] };
        $bitmap_array[$bitmap_num] = \%hash;
    }
    # First make a line showing the operator descriptors using bit maps
    $txt .= "$line\n";

    my $B_table = $self->{B_TABLE};
    # Add the artificial descriptor for associated field
    $B_table->{999999} = "ASSOCIATED FIELD\0Numeric";
    my $C_table = $self->{C_TABLE} || '';

    my $idx = 0;
    # Loop over data descriptors
  ID:
    foreach my $id ( @{ $descriptors } ) {
        _croak "Bitmapped supplied character information 205Y not implemented"
            if $id =~ /^205/;
        # Stop printing when the bit map part starts
        last ID if $id =~ /^2/;

        # Get the data value
        my $value = defined $data->[$idx] ? $data->[$idx] : 'missing';
        _croak "Data descriptor $id is not present in BUFR table B"
            unless exists $B_table->{$id};
        my ($name, $unit, $bits) = (split /\0/, $B_table->{$id})[0,1,4];
        $line = sprintf "%6d  %06d  %${width}.${width}s ",
            $idx+1, $id, $value;

        # Then get the corresponding bit mapped values, using '******'
        # if 'data not present' in bit map
        foreach my $bitmap_num (0..$#bitmap_desc) {
            my $val;
            if ($bitmap_array[$bitmap_num]->{$idx}) {
                # data marked as 'data present' in bitmap
                my $bitmapped_idesc = $bitmap_array[$bitmap_num]->{$idx};
                $val = defined $data->[$bitmapped_idesc]
                    ? $data->[$bitmapped_idesc] : 'missing';
            } else {
                $val = '******';
            }
            $line .= sprintf " %6.6s", $val;
        }
        # Code or flag table number equals $id, so no need to display this in [unit]
        my $short_unit = $unit;
        $short_unit = 'CODE TABLE' if $unit =~ /^CODE TABLE/;
        $short_unit = 'FLAG TABLE' if $unit =~ /^FLAG TABLE/;
        $line .=  sprintf "  %s\n", "$name [$short_unit]";
        $txt .= $line;

        # Check for illegal flag value
        if ($Strict_checking and $unit =~ /^FLAG TABLE/ and $bits > 1) {
            if ($value ne 'missing' and $value % 2) {
                my $max_value = 2**$bits - 1;
                $bits += 0; # get rid of spaces
                _complain("$id - $value: rightmost bit $bits is set indicating missing value"
                          . " but then value should be $max_value");
            }
        }

        # Resolve flag and code table values if code table is loaded
        if ($value ne 'missing' and $C_table) {
            my $num_spaces = $width + 19 + 7*@bitmap_desc;
            $txt .= _get_code_table_txt($id,$value,$unit,$B_table,$C_table,$num_spaces)
        }
        $idx++;
    }
    return $txt;
}

## Return the text found in flag or code tables for value $value of
## descriptor $id. The empty string is returned if $unit is neither
## CODE TABLE nor FLAG TABLE, or if $unit is CODE TABLE but for this
## $value there is no text in C table. Returns a "... does not exist!"
## message if flag/code table is not found. If $check_illegal is
## defined, an 'Illegal value' message is returned if $value is bigger
## than allowed or has highest bit set without having all other bits
## set.
sub _get_code_table_txt {
    my ($id,$value,$unit,$B_table,$C_table,$num_spaces,$check_illegal) = @_;

    my $txt = '';
    if ($unit =~ m/^CODE TABLE/) {
        my $code_table = sprintf "%06d", $id;
        return "Code table $code_table does not exist!\n"
            if ! exists $C_table->{$code_table};
        if ($C_table->{$code_table}{$value}) {
            my @lines = split "\n", $C_table->{$code_table}{$value};
            foreach (@lines) {
                $txt .= sprintf "%s   %s\n", ' ' x ($num_spaces), lc $_;
            }
        }
    } elsif ($unit =~ m/^FLAG TABLE/) {
        my $flag_table = sprintf "%06d", $id;
        return "Flag table $flag_table does not exist!\n"
            if ! exists $C_table->{$flag_table};

        my $width = (split /\0/, $B_table->{$flag_table})[4];
        $width += 0;            # Get rid of spaces
        # Cannot handle more than 32 bits flags with current method
        _croak "Unable to handle > 32 bits flag; $id has width $width"
            if $width > 32;

        my $max_value = 2**$width - 1;

        if (defined $check_illegal and $value > $max_value) {
            $txt = "Illegal value: $value is bigger than maximum allowed ($max_value)\n";
        } elsif ($value == $max_value) {
            $txt = sprintf "%s=> %s", ' ' x ($num_spaces), "bit $width set:"
                . sprintf "%s   %s\n", ' ' x ($num_spaces), "missing value\n";
        } else {
            # Convert to bitstring and localize the 1 bits
            my $binary = pack "N", $value; # Packed as 32 bits in big-endian order
            my $bitstring = substr unpack('B*',$binary), 32-$width;
            for my $i (1..$width) {
                if (substr($bitstring, $i-1, 1) == 1) {
                    $txt .= sprintf "%s=> %s", ' ' x ($num_spaces),
                        "bit $i set";
                    if ($C_table->{$flag_table}{$i}) {
                        my @lines = split "\n", $C_table->{$flag_table}{$i};
                        $txt .= ': ' . lc (shift @lines) . "\n";
                        foreach (@lines) {
                            $txt .= sprintf "%s   %s\n", ' ' x ($num_spaces), lc $_;
                        }
                    } else {
                        $txt .= "\n";
                    }
                }
            }
            if (defined $check_illegal and $txt =~ /bit $width set/) {
                $txt = "Illegal value ($value): bit $width is set indicating missing value,"
                    . " but then value should be $max_value\n";
            }
        }
    }
    return $txt;
}

##  Convert from integer to descriptor
sub _int2fxy {
    my @fxy = map {sprintf("%1d%02d%03d", ($_>>14)&0x3, ($_>>8)&0x3f, $_&0xff)} @_;
    return @_ > 1 ? @fxy : $fxy[0];
}

##  Expand a list of descriptors using BUFR table D, also expanding
##  simple replication but not delayed replication
sub _expand_descriptors {
    my $D_table = shift;
    my @expanded = ();

    for (my $di = 0; $di < @_; $di++) {
        my $descriptor = $_[$di];
        _croak "$descriptor is not a BUFR descriptor"
            if $descriptor !~ /\d{6}$/;
        my $f = int substr($descriptor, 0, 1);
        if ($f == 1) {
            # Simple Replication
            my $x = substr $descriptor, 1, 2; # Replicate next $x descriptors
            my $y = substr $descriptor, 3;    # Number of replications
            if ($y > 0) {
                # Simple replication (replicate next x descriptors y times)
                _croak "Not enough descriptors following replication "
                    . "descriptor $descriptor" if $di + $x + 1 > @_;
                my @r = ();
                push @r, @_[($di+1)..($di+$x)] while --$y;
                # Recursively expand replicated descriptors $y-1 times
                # (last replication will be taken care of by main loop)
                push @expanded, _expand_descriptors($D_table, @r) if @r;
            } else {
                # Delayed replication. Next descriptor ought to be the
                # delayed descriptor replication factor, i.e. one of
                # 0310(00|01|02|11|12), followed by the x descriptors
                # to be replicated
                _croak "Not enough descriptors following delayed replication"
                    . " descriptor $descriptor" if $di + $x + 1 > @_;
                _croak "Delayed replication descriptor $descriptor is "
                    . "not followed by one of 0310(00|01|02|11|12) but by $_[$di+1]"
                        if $_[$di+1] !~ /^0310(00|01|02|11|12)$/;
                my @r = @_[($di+2)..($di+$x+1)];
                # Here we just expand the D descriptors in the
                # descriptors to be replicated. The final expansion
                # using delayed replication factor has to wait until
                # data part is decoded
                my @s = ();
                @s = _expand_descriptors($D_table, @r) if @r;
                # Must adjust x since replicated descriptors might have been expanded
                substr($_[$di], 1, 2) = sprintf "%02d", scalar @s;
                push @expanded, @_[$di, $di+1], @s;
                $di += 1 + $x; # NOTE: 1 is added to $di on next iteration
            }
            next;
        }
        if ($f == 3) {
            _croak "No data descriptor $descriptor in BUFR table D"
                if not exists $D_table->{$descriptor};
            # Expand recursively, if necessary
            push @expanded,
                _expand_descriptors($D_table, split /\s/, $D_table->{$descriptor});
        } else {
            push @expanded, $descriptor;
        }
    }

    return @expanded;
}

## Return a text string suitable for printing information about the given
## BUFR table descriptors
##
## $how = 'fully': Expand all D descriptors fully into B descriptors,
## with name, unit, scale, reference value and width (each on a
## numbered line, except for replication operators which are not
## numbered).
##
## $how = 'partially': Like 'fully, but expand D descriptors only once
## and ignore replication.
##
## $how = 'noexpand': Like 'partially', but do not expand D
## descriptors at all.
##
## $how = 'simply': Like 'partially', but list the descriptors on one
## single line with no extra information provided.
sub resolve_descriptor {
    my $self = shift;
    my $how = shift;
    foreach (@_) {
        _croak("'$_' is not an integer argument to resolve_descriptor!")
            unless /^\d+$/;
    }
    my @desc = map { sprintf "%06d", $_ } @_;

    my @allowed_hows = qw( simply fully partially noexpand );
    _croak "First argument in resolve_descriptor must be one of"
        . " '@allowed_hows', is: '$how'"
            unless grep { $how eq $_ } @allowed_hows;

    my $B_table = $self->{B_TABLE}
        or _croak "No B table is loaded - did you forget to call load_BDtables?";
    my $D_table = $self->{D_TABLE}
        or _croak "No D table is loaded - did you forget to call load_BDtables?";
    my $txt = '';

    if ($how eq 'simply' or $how eq 'partially') {
        my @expanded;
        foreach my $id ( @desc ) {
            my $f = substr $id, 0, 1;
            if ($f == 3) {
                _croak "$id is not in table D, unable to expand"
                    unless $D_table->{$id};
                push @expanded, split /\s/, $D_table->{$id};
            } else {
                push @expanded, $id;
            }
        }
        if ($how eq 'simply') {
            return $txt = "@expanded\n";
        } else {
            @desc = @expanded;
        }
    }
    if ($how eq 'fully') {
        if (@desc == 1 and $desc[0] =~ /^1/) {
            # This is simply a replication descriptor; do not try to expand
        } else {
            @desc = _expand_descriptors( $D_table, @desc );
        }
    }

    my $count = 0;
    foreach my $id ( @desc ) {
        if ($id =~ /^[123]/) {
            $txt .= sprintf "    %06d\n", $id;
        } elsif ($B_table->{$id}) {
            my ($name,$unit,$scale,$refval,$width) = split /\0/, $B_table->{$id};
            $txt .= sprintf "%3d %06d  %s [%s] %d %d %d\n",
                ++$count,$id,$name,$unit,$scale,$refval,$width;
        } else {
            $txt .= sprintf "%3d %06d  Not in table B\n",
                ++$count,$id;
        }
    }
    return $txt;
}

## Return BUFR table B information for an element descriptor for the
## last table loaded, as an array of name, unit, scale, reference
## value and data width in bits. Returns false if the descriptor is
## not found or no data width is defined, or croaks if no table B has
## been loaded.
sub element_descriptor {
    my $self = shift;
    my $desc = shift;
    _croak "Argument to element_descriptor must be an integer\n"
        unless $desc =~ /^\d+$/;
    $desc = sprintf "%06d", $desc;
    _croak "No BUFR B table loaded\n" unless defined $self->{B_TABLE};
    return unless defined $self->{B_TABLE}->{$desc};
    my ($name, $unit, $scale, $refval, $width)
        = split /\0/, $self->{B_TABLE}->{$desc};
    return unless defined $width && $width =~ /\d+$/;
    return ($name, $unit, $scale+0, $refval+0, $width+0);
}

## Return BUFR table D information for a sequence descriptor for the
## last table loaded, as a space separated string of the descriptors
## in the direct (nonrecursive) lookup in table D. Returns false if
## the sequence descriptor is not found, or croaks if no table D has
## been loaded.
sub sequence_descriptor {
    my $self = shift;
    my $desc = shift;
    _croak "Argument to element_descriptor must be an integer\n"
        unless $desc =~ /^\d+$/;
    _croak "No BUFR D table loaded\n" unless defined $self->{D_TABLE};
    return unless defined $self->{D_TABLE}->{$desc};
    if (wantarray) {
        return split / /, $self->{D_TABLE}->{$desc};
    } else {
        return $self->{D_TABLE}->{$desc};
    }
}

## Return a text string telling which bits are set and the meaning of
## the bits set when $value is interpreted as a flag value, also
## checking for illegal values. The empty string is returned if $value=0.
sub resolve_flagvalue {
    my $self = shift;
    my ($value,$flag_table,$table,$default_table,$num_leading_spaces) = @_;
    _croak "Flag value can't be negative!\n" if $value < 0;
    $num_leading_spaces ||= 0;  # Default value

    $self->load_Ctable($table,$default_table);
    my $C_table = $self->{C_TABLE};

    # Number of bits used for the flag is hard to extract from C
    # table; it is much easier to obtain from B table
    $self->load_BDtables($table);
    my $B_table = $self->{B_TABLE};

    my $unit = 'FLAG TABLE';
    return _get_code_table_txt($flag_table,$value,$unit,
                               $B_table,$C_table,$num_leading_spaces,'check_illegal');
}

## Return the content of code table $code_table, or empty string if
## code table is not in found
sub dump_codetable {
    my $self = shift;
    my ($code_table,$table,$default_table) = @_;
    _croak("code_table '$code_table' is not a (positive) integer in dump_codetable()")
        unless $code_table =~ /^\d+$/;
    $code_table = sprintf "%06d", $code_table;

    $self->load_Ctable($table,$default_table);
    my $C_table = $self->{C_TABLE};

    return '' unless $C_table->{$code_table};

    my $dump;
    foreach my $value (sort {$a <=> $b} keys %{ $C_table->{$code_table} }) {
        my $txt = $C_table->{$code_table}{$value};
        chomp $txt;
        $txt =~ s/\n/\n       /g;
        $dump .= sprintf "%3d -> %s\n", $value, $txt;
    }
    return $dump;
}

my @powers_of_ten = (
   1,    10,   100,  1e03, 1e04, 1e05, 1e06, 1e07, 1e08, 1e09,
   1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19,
   1e20, 1e21, 1e22, 1e23, 1e24, 1e25, 1e26, 1e27, 1e28, 1e29,
   1e30, 1e31, 1e32, 1e33, 1e34, 1e35, 1e36, 1e37, 1e38, 1e39,
   1e40, 1e41, 1e42, 1e43, 1e44, 1e45, 1e46, 1e47, 1e48, 1e49,
   1e50, 1e51, 1e52, 1e53, 1e54, 1e55, 1e56, 1e57, 1e58, 1e59,
   1e60, 1e61, 1e62, 1e63, 1e64, 1e65, 1e66, 1e67, 1e68, 1e69,
   1e70, 1e71, 1e72, 1e73, 1e74, 1e75, 1e76, 1e77, 1e78, 1e79,
   1e80, 1e81, 1e82, 1e83, 1e84, 1e85, 1e86, 1e87, 1e88, 1e89,
   1e90, 1e91, 1e92, 1e93, 1e94, 1e95, 1e96, 1e97, 1e98, 1e99,
   undef, undef, undef, undef, undef, undef, undef, undef, undef, undef,
   undef, undef, undef, undef, undef, undef, undef, undef, undef, undef,
   undef, undef, undef, undef, undef, undef, undef, undef, undef, undef,
   undef, undef, undef, undef, undef, undef, undef, undef, undef, undef,
   1e-99, 1e-98, 1e-97, 1e-96, 1e-95, 1e-94, 1e-93, 1e-92, 1e-91, 1e-90,
   1e-89, 1e-88, 1e-87, 1e-86, 1e-85, 1e-84, 1e-83, 1e-82, 1e-81, 1e-80,
   1e-79, 1e-78, 1e-77, 1e-76, 1e-75, 1e-74, 1e-73, 1e-72, 1e-71, 1e-70,
   1e-69, 1e-68, 1e-67, 1e-66, 1e-65, 1e-64, 1e-63, 1e-62, 1e-61, 1e-60,
   1e-59, 1e-58, 1e-57, 1e-56, 1e-55, 1e-54, 1e-53, 1e-52, 1e-51, 1e-50,
   1e-49, 1e-48, 1e-47, 1e-46, 1e-45, 1e-44, 1e-43, 1e-42, 1e-41, 1e-40,
   1e-39, 1e-38, 1e-37, 1e-36, 1e-35, 1e-34, 1e-33, 1e-32, 1e-31, 1e-30,
   1e-29, 1e-28, 1e-27, 1e-26, 1e-25, 1e-24, 1e-23, 1e-22, 1e-21, 1e-20,
   1e-19, 1e-18, 1e-17, 1e-16, 1e-15, 1e-14, 1e-13, 1e-12, 1e-11, 1e-10,
   1e-09, 1e-08, 1e-07, 1e-06, 1e-05, 1e-04, 1e-03, 1e-02, 1e-01
);

## Decode bitstream (data part of section 4) while working through the
## (expanded) descriptors in section 3. The final data and
## corresponding descriptors are put in $self->{DATA} and
## $self->{DESC} (indexed by subset number)
sub _decode_bitstream {
    my $self = shift;
    my $bitstream = $self->{SEC4_RAWDATA} . "\0\0\0\0";
    my $maxpos = 8*length($self->{SEC4_RAWDATA});
    my $pos = 0;
    my @operators;
    my $ref_values_ref; # Hash ref to reference values with descriptors as keys;
                        # to be implemented later (not used yet)
    my @subset_data; # Will contain data values for subset 1,2...
    my @subset_desc; # Will contain the set of descriptors for subset 1,2...
                     # expanded to be in one to one correspondance with the data
    my $B_table = $self->{B_TABLE};

    # Has to fully expand @desc for each subset in turn, as delayed
    # replication factors might be different for each subset,
    # resulting in different full expansions. During the expansion the
    # effect of operator descriptors are taken into account, causing
    # most of them to be eliminated (unless $Show_all_operators is
    # set), so that @desc and the equivalent $subset_desc[$isub] ends
    # up being in one to one correspondence with the data values in
    # $subset_data[$isub] (the operators included having data value
    # '')
  S_LOOP: foreach my $isub (1..$self->{NUM_SUBSETS}) {
        $self->_spew(2, "Decoding subset number %d", $isub);
        my @desc = split /\s/, $self->{DESCRIPTORS_EXPANDED};

        # Note: @desc as well as $idesc may be changed during this loop,
        # so we cannot use a foreach loop instead
      D_LOOP: for (my $idesc = 0; $idesc < @desc; $idesc++) {
            my $id = $desc[$idesc];
            my ($f, $x, $y) = unpack 'AA2A3', $id;

            if ($f == 1) {
                # Delayed replication
                if ($x == 0) {
                    _complain("Nonsensical replication of zero descriptors ($id)");
                    $idesc++;
                    next D_LOOP;
                }
                _croak "$id _expand_descriptors() did not do its job"
                    if $y > 0;

                $_ = $desc[$idesc+1];
                _croak "$id Erroneous replication factor"
                    unless /0310(00|01|02|11|12)/ && exists $B_table->{$_};

                my $width = (split /\0/, $B_table->{$_})[-1];
                my $factor = bitstream2dec($bitstream, $pos, $width);
                # Delayed descriptor replication factors (and
                # associated fields) are the only values in section 4
                # where all bits being 1 is not to be interpreted as a
                # missing value
                if (not defined $factor) {
                    $factor = 2**$width - 1;
                }
                $self->_spew(4, "$_  Delayed replication factor: $factor");
                # Include the delayed replication in descriptor and data list
                splice @desc, $idesc++, 0, $_;
                push @{$subset_desc[$isub]}, $_;
                push @{$subset_data[$isub]}, $factor;

                $pos += $width;
                my @r = ();
                push @r, @desc[($idesc+2)..($idesc+$x+1)] while $factor--;
                $self->_spew(4, "Delayed replication ($id $_ -> @r)");
                splice @desc, $idesc, 2+$x, @r;

                if ($idesc < @desc) {
                    redo D_LOOP;
                } else {
                    last D_LOOP;
                }

            } elsif ($f == 2) {
                my $flow;
                my $new_idesc;
                ($pos, $flow, $new_idesc, @operators)
                    = $self->_apply_operator_descriptor($id, $x, $y, $pos,
                                                        $desc[$idesc + 1], @operators);
                if ($flow eq 'redo_bitmap') {
                    # Data value is associated with the descriptor
                    # defined by bit map. Remember original and new
                    # index in descriptor array for the bit mapped
                    # values
                    push @{ $self->{BITMAPS}->[$self->{NUM_BITMAPS}] },
                        $new_idesc, $idesc;
                    if ($Show_all_operators) {
                        push @{$subset_desc[$isub]}, $id;
                        push @{$subset_data[$isub]}, '';
                    }
                    $desc[$idesc] = $desc[$new_idesc];
                    redo D_LOOP;
                } elsif ($flow eq 'signify_character') {
                    push @{$subset_desc[$isub]}, $id;
                    # Extract ASCII string
                    my $value = bitstream2ascii($bitstream, $pos, $y);
                    $pos += 8*$y;
                    push @{$subset_data[$isub]}, $value;
                    next D_LOOP;
                } elsif ($flow eq 'no_value') {
                    # Some operator descriptors ought to be included
                    # in expanded descriptors even though they have no
                    # corresponding data value, because they contain
                    # valuable information to be displayed in
                    # dumpsection4 (e.g. 222000 'Quality information follows')
                    push @{$subset_desc[$isub]}, $id;
                    push @{$subset_data[$isub]}, '';
                    next D_LOOP;
                }

                if ($Show_all_operators) {
                    push @{$subset_desc[$isub]}, $id;
                    push @{$subset_data[$isub]}, '';
                } else {
                    # Remove operator descriptor from @desc
                    splice @desc, $idesc--, 1;
                }

                next D_LOOP if $flow eq 'next';
                last D_LOOP if $flow eq 'last';
                if ($flow eq 'skip') {
                    $idesc++;
                    next D_LOOP;
                }
            }

            if ($self->{CHANGE_REFERENCE_VALUE}) {
                # The data descriptor is to be associated with a new
                # reference value, which is fetched from data stream
                _croak "Change reference operator 203Y is not followed by element"
                    . " descriptor, but $id" if $f > 0;
                my $num_bits = $self->{CHANGE_REFERENCE_VALUE};
                my $new_refval = bitstream2dec($bitstream, $pos, $num_bits);
                $pos += $num_bits;
                # Negative value if most significant bit is set (one's complement)
                $new_refval = $new_refval & (1<<$num_bits-1)
                    ? -($new_refval & ((1<<$num_bits-1)-1))
                        : $new_refval;
                $self->_spew(4, "$id * Change reference value: ".
                             ($new_refval > 0 ? "+" : "")."$new_refval");
                $self->{NEW_REFVAL_OF}{$id}{$isub} = $new_refval;
                # Identify new reference values by setting f=9
                push @{$subset_desc[$isub]}, $id + 900000;
                push @{$subset_data[$isub]}, $new_refval;
                next D_LOOP;
            }

            # If operator 204$y 'Add associated field is in effect',
            # each data value is preceded by $y bits which should be
            # decoded separately. We choose to provide a descriptor
            # 999999 in this case (like the ECMWF libbufr software)
            if ($self->{ADD_ASSOCIATED_FIELD} and $id ne '031021') {
                # First extract associated field
                my $width = $self->{ADD_ASSOCIATED_FIELD};
                my $value = bitstream2dec($bitstream, $pos, $width);
                $pos += $width;
                push @{$subset_desc[$isub]}, 999999;
                push @{$subset_data[$isub]}, $value;
                $self->_spew(4, "Added associated field: %s", $value);
            }

            # We now have a "real" data descriptor
            push @{$subset_desc[$isub]}, $id;

            # For quality information, if this relates to a bit map we
            # need to store index of the data ($data_idesc) for which
            # the quality information applies, as well as the new
            # index ($idesc) in the descriptor array for the bit
            # mapped values
            if ($id =~ /^033/
                and defined $self->{BITMAP_OPERATORS}
                and $self->{BITMAP_OPERATORS}->[-1] eq '222000') {
                my $data_idesc = shift @{ $self->{CURRENT_BITMAP} };
                _croak "$id: Not enough quality values provided"
                    if not defined $data_idesc;
                push @{ $self->{BITMAPS}->[$self->{NUM_BITMAPS}] },
                    $data_idesc, $idesc;
            }

            # Find the relevant entry in BUFR table B
            _croak "Data descriptor $id is not present in BUFR table B"
                unless exists $B_table->{$id};
            my ($name,$unit,$scale,$refval,$width) = split /\0/, $B_table->{$id};
            $self->_spew(3, "%6s  %-20s  %s", $id, $unit, $name);

            # Override Table B values if Data Description Operators are in effect
            $width += $self->{CHANGE_WIDTH} if defined $self->{CHANGE_WIDTH};
            $scale += $self->{CHANGE_SCALE} if defined $self->{CHANGE_SCALE};
            # To prevent autovivification (see perlodc -f exists) we
            # need this laborious test for defined
            $refval = $self->{NEW_REFVAL_OF}{$id}{$isub} if defined $self->{NEW_REFVAL_OF}{$id}
                && defined $self->{NEW_REFVAL_OF}{$id}{$isub};
            # Difference statistical values use different width and reference value
            if ($self->{DIFFERENCE_STATISTICAL_VALUE}) {
                $width += 1;
                $refval = -2**$width;
                undef $self->{DIFFERENCE_STATISTICAL_VALUE};
            }
            _croak "$id Data width <= 0" if $width <= 0;
            my $scale_factor = $powers_of_ten[-$scale]; #10**(-$scale);

            my $value;
            if ($unit eq 'CCITTIA5') {
                # Extract ASCII string
                _croak "Width for unit CCITTIA5 must be integer bytes\n"
                    . "is $width bits for descriptor $id" if $width % 8;
                $value = bitstream2ascii($bitstream, $pos, $width/8);
                $self->_spew(3, "  %s", defined $value ? $value : 'missing');
                # Trim string, also for trailing nulls
                $value = _trim($value);
            } else {
                $value = bitstream2dec($bitstream, $pos, $width);
                $value = ($value + $refval) * $scale_factor if defined $value;
                $self->_spew(3, "  %s", defined $value ? $value : 'missing');
            }
            $pos += $width;
            push @{$subset_data[$isub]}, $value;
            # $value = undef if missing value

            if ($id eq '031031' and $self->{BUILD_BITMAP}) {
                # Store the index of expanded descriptors if data is
                # marked as present in data present indicator: 0 is
                # 'present', 1 (undef value) is 'not present'. E.g.
                # bitmap = 1100110 => (2,3,6) is stored in $self->{CURRENT_BITMAP}
                if (defined $value) {
                    push @{$self->{CURRENT_BITMAP}}, $self->{BITMAP_INDEX};
                    push @{$self->{LAST_BITMAP}}, $self->{BITMAP_INDEX};
                }
                $self->{BITMAP_INDEX}++;

            } elsif ($self->{BUILD_BITMAP} and $self->{BITMAP_INDEX} > 0) {
                # We have finished building the bit map
                $self->{BUILD_BITMAP} = 0;
                $self->{BITMAP_INDEX} = 0;
            }
        } # End D_LOOP
    } # END S_LOOP

    # Check that length of section 4 corresponds to what expected from section 3
    $self->_check_section4_length($pos,$maxpos);

    $self->{DATA} = \@subset_data;
    $self->{DESC} = \@subset_desc;

    return $self->{DATA};
}

## Decode bitstream (data part of section 4 encoded using BUFR
## compression) while working through the (expanded) descriptors in
## section 3. The final data and corresponding descriptors are put in
## $self->{DATA} and $self->{DESC} (the data indexed by subset number)
sub _decompress_bitstream {
    my $self = shift;
    my $bitstream = $self->{SEC4_RAWDATA}."\0\0\0\0";
    my $nsubsets = $self->{NUM_SUBSETS};
    my $B_table = $self->{B_TABLE};
    my $maxpos = 8*length($self->{SEC4_RAWDATA});
    my $pos = 0;
    my @operators;
    my @subset_data;     # Will contain data values for subset 1,2...,
                         # i.e. $subset[$i] is a reference to an array
                         # containing the data values for subset $i
    my @desc_exp;        # Will contain the set of descriptors for one
                         # subset, expanded to be in one to one
                         # correspondance with the data, i.e. element
                         # descriptors only

    _complain("Compression set in section 1 for one subset message")
        if $Strict_checking && $nsubsets == 1;

    $#subset_data = $nsubsets;

    my @desc = split /\s/, $self->{DESCRIPTORS_EXPANDED};
    # This will be further expanded to be in one to one correspondance
    # with the data, taking replication and table C operators into account

    # All subsets in a compressed BUFR message must have exactly the same
    # fully expanded section 3, i.e. all replications factors must be the same
    # in all subsets. So, as opposed to noncompressed messages, it is enough
    # to run through the set of descriptors once.
  D_LOOP: for (my $idesc = 0; $idesc < @desc; $idesc++) {
        my $id = $desc[$idesc];
        my ($f, $x, $y) = unpack 'AA2A3', $id;

        if ($f == 1) {
            # Delayed replication
            if ($x == 0) {
                _complain("Nonsensical replication of zero descriptors ($id)");
                $idesc++;
                next D_LOOP;
            }
            _croak "$id _expand_descriptors() did not do its job"
                if $y > 0;

            $_ = $desc[$idesc+1];
            _croak "$id Erroneous replication factor"
                unless /0310(00|01|02|11|12)/ && exists $B_table->{$_};

            my $width = (split /\0/, $B_table->{$_})[-1];
            my $factor = bitstream2dec($bitstream, $pos, $width);
            # Delayed descriptor replication factors (and associated
            # fields) are the only values in section 4 where all bits
            # being 1 is not interpreted as a missing value
            if (not defined $factor) {
                $factor = 2**$width - 1;
            }
            $self->_spew(4, "$_  Delayed replication factor: $factor");
            # Include the delayed replication in descriptor and data list
            push @desc_exp, $_;
            foreach my $isub (1..$nsubsets) {
                push @{$subset_data[$isub]}, $factor;
            }

            $pos += $width + 6; # 6 bits for the bit count (which we
                                # skip because we know it has to be 0
                                # for delayed replication)
            my @r = ();
            push @r, @desc[($idesc+2)..($idesc+$x+1)] while $factor--;
            $self->_spew(4, "$_  Delayed replication ($id $_ -> @r)");
            splice @desc, $idesc, 2+$x, @r;

            redo D_LOOP;

        } elsif ($f == 2) {
            my $flow;
            my $bm_idesc;
            ($pos, $flow, $bm_idesc, @operators)
                = $self->_apply_operator_descriptor($id, $x, $y, $pos,
                                                    $desc[$idesc + 1], @operators);
            if ($flow eq 'redo_bitmap') {
                # Data value is associated with the descriptor
                # defined by bit map. Remember original and new
                # index in descriptor array for the bit mapped
                # values
                push @{ $self->{BITMAPS}->[$self->{NUM_BITMAPS}] },
                    $bm_idesc, $idesc;
                if ($Show_all_operators) {
                    push @desc_exp, $id;
                    foreach my $isub (1..$nsubsets) {
                        push @{$subset_data[$isub]}, '';
                    }
                }
                $desc[$idesc] = $desc[$bm_idesc];
                redo D_LOOP;
            } elsif ($flow eq 'signify_character') {
                push @desc_exp, $id;
                $pos = $self->_extract_compressed_value($id, $idesc, $pos, $bitstream,
                                                $nsubsets, \@subset_data);
                next D_LOOP;
            } elsif ($flow eq 'no_value') {
                # Some operator descriptors ought to be included
                # in expanded descriptors even though they have no
                # corresponding data value, because they contain
                # valuable information to be displayed in
                # dumpsection4 (e.g. 222000 'Quality information follows')
                push @desc_exp, $id;
                foreach my $isub (1..$nsubsets) {
                    push @{$subset_data[$isub]}, '';
                }
                next D_LOOP;
            }

            if ($Show_all_operators) {
                push @desc_exp, $id;
                foreach my $isub (1..$nsubsets) {
                    push @{$subset_data[$isub]}, '';
                }
            } else {
                # Remove operator descriptor from @desc
                splice @desc, $idesc--, 1;
            }

            next D_LOOP if $flow eq 'next';
            last D_LOOP if $flow eq 'last';
            if ($flow eq 'skip') {
                $idesc++;
                next D_LOOP;
            }
        }

        if ($self->{CHANGE_REFERENCE_VALUE}) {
            # The data descriptor is to be associated with a new
            # reference value, which is fetched from data stream
            _croak "Change reference operator 203Y is not followed by element"
                . " descriptor, but $id" if $f > 0;
            my $num_bits = $self->{CHANGE_REFERENCE_VALUE};
            my $new_refval = bitstream2dec($bitstream, $pos, $num_bits);
            $pos += $num_bits + 6;
            # Negative value if most significant bit is set (one's complement)
            $new_refval = $new_refval & (1<<$num_bits-1)
                ? -($new_refval & ((1<<$num_bits-1)-1))
                    : $new_refval;
            $self->_spew(4, "$id * Change reference value: ".
                         ($new_refval > 0 ? "+" : "")."$new_refval");
            $self->{NEW_REFVAL_OF}{$id} = $new_refval;
            # Identify new reference values by setting f=9
            push @desc_exp, $id + 900000;
            foreach my $isub (1..$nsubsets) {
                push @{$subset_data[$isub]}, $new_refval;
            }
            next D_LOOP;
        }

        # If operator 204$y 'Add associated field is in effect',
        # each data value is preceded by $y bits which should be
        # decoded separately. We choose to provide a descriptor
        # 999999 in this case (like the ECMWF libbufr software)
        if ($self->{ADD_ASSOCIATED_FIELD} and $id ne '031021') {
            # First extract associated field
            push @desc_exp, 999999;
            $pos = $self->_extract_compressed_value(999999, $idesc, $pos, $bitstream,
                                                    $nsubsets, \@subset_data);
        }

        # We now have a "real" data descriptor, so add it to the descriptor list
        push @desc_exp, $id;

        $pos = $self->_extract_compressed_value($id, $idesc, $pos, $bitstream,
                                                $nsubsets, \@subset_data);
    }

    # Check that length of section 4 corresponds to what expected from section 3
    $self->_check_section4_length($pos,$maxpos);

    $self->{DATA} = \@subset_data;
    $self->{DESC} = \@desc_exp;

    return $self->{DATA};
}

## Extract the data values for descriptor $id (with index $idesc in
## the final expanded descriptor array) for each subset, into
## $subset_data_ref->[$isub], $isub = 1...$nsubsets (number of
## subsets). Extraction starts at position $pos in $bitstream.
sub _extract_compressed_value {
    my $self = shift;
    my ($id, $idesc, $pos, $bitstream, $nsubsets, $subset_data_ref) = @_;
    my $B_table = $self->{B_TABLE};

    # For quality information, if this relates to a bit map we
    # need to store index of the data ($data_idesc) for which
    # the quality information applies, as well as the new
    # index ($idesc) in the descriptor array for the bit
    # mapped values
    if ($id =~ /^033/
        and defined $self->{BITMAP_OPERATORS}
        and $self->{BITMAP_OPERATORS}->[-1] eq '222000') {
        my $data_idesc = shift @{ $self->{CURRENT_BITMAP} };
        _croak "$id: Not enough quality values provided"
            if not defined $data_idesc;
        push @{ $self->{BITMAPS}->[$self->{NUM_BITMAPS}] },
            $data_idesc, $idesc;
    }

    # Find the relevant entry in BUFR table B
    my ($name,$unit,$scale,$refval,$width);
    if ($id == 999999) {
        $name = 'ASSOCIATED FIELD';
        $unit = 'NUMERIC';
        $scale = 0;
        $refval = 0;
        $width = $self->{ADD_ASSOCIATED_FIELD};
    } elsif ($id =~ /^205(\d\d\d)/) { # Signify character
        $name = 'CHARACTER INFORMATION';
        $unit = 'CCITTIA5';
        $scale = 0;
        $refval = 0;
        $width = 8*$1;
    } else {
        _croak "Data descriptor $id is not present in BUFR table B"
            if not exists $B_table->{$id};
        ($name,$unit,$scale,$refval,$width) = split /\0/, $B_table->{$id};

        # Override Table B values if Data Description Operators are in effect
        $width += $self->{CHANGE_WIDTH} if defined $self->{CHANGE_WIDTH};
        $scale += $self->{CHANGE_SCALE} if defined $self->{CHANGE_SCALE};
        $refval = $self->{NEW_REFVAL_OF}{$id} if defined $self->{NEW_REFVAL_OF}{$id};
        # Difference statistical values use different width and reference value
        if ($self->{DIFFERENCE_STATISTICAL_VALUE}) {
            $width += 1;
            $refval = -2**$width;
            undef $self->{DIFFERENCE_STATISTICAL_VALUE};
        }
    }
    $self->_spew(3, "%6s  %-20s   %s", $id, $unit, $name);
    _croak "$id Data width <= 0" if $width <= 0;
    my $scale_factor = $powers_of_ten[-$scale]; #10**(-$scale);

    if ($unit eq 'CCITTIA5') {
        # Extract ASCII string ('minimum value')
        _croak "Width for unit CCITTIA5 must be integer bytes\n"
            . "is $width bits for descriptor $id" if $width % 8;
        my $minval = bitstream2ascii($bitstream, $pos, $width/8);
        if ($self->{VERBOSE} >= 5) {
            if ($minval eq "\0" x ($width/8)) {
                $self->_spew(5, " Local reference value has all bits zero");
            } else {
                $self->_spew(5, " Local reference value: %s", $minval);
            }
        }
        $pos += $width;
        # Extract number of bytes for next subsets
        my $deltabytes = bitstream2dec($bitstream, $pos, 6);
        $self->_spew(5, " Increment width (bytes): %d", $deltabytes);
        $pos += 6;
        if ($deltabytes && defined $minval) {
            # Extract compressed data for all subsets. According
            # to 94.6.3 (2) (i) in FM 94 BUFR, the first value for
            # character data shall be set to all bits zero
            my $nbytes = $width/8;
            _complain("CCITTIA5 minval not all bits set to zero but '$minval'")
                if $Strict_checking and $minval ne "\0" x $nbytes;
            my $incr_values;
            foreach my $isub (1..$nsubsets) {
                my $string = bitstream2ascii($bitstream, $pos, $deltabytes);
                if ($self->{VERBOSE} >= 5) {
                    $incr_values .= defined $string ? "$string," : ',';
                }
                # Trim string, also for trailing nulls
                $string = _trim($string);
                push @{$subset_data_ref->[$isub]}, $string;
                $pos += 8*$deltabytes;
            }
            if ($self->{VERBOSE} >= 5) {
                chop $incr_values;
                $self->_spew(5, " Increment values: $incr_values");
            }
        } else {
            # If min value is defined => All subsets set to min value
            # If min value is undefined => Data in all subsets are undefined
            my $value = (defined $minval) ? $minval : undef;
            # Trim string, also for trailing nulls
            $value = _trim($value);
            foreach my $isub (1..$nsubsets) {
                push @{$subset_data_ref->[$isub]}, $value;
            }
            $pos += $nsubsets*8*$deltabytes;
        }
        $self->_spew(3, "  %s", join ',',
                     map { defined($subset_data_ref->[$_][-1]) ?
                     $subset_data_ref->[$_][-1] : 'missing'} 1..$nsubsets )
                     if $self->{VERBOSE} >= 3;
    } else {
        # Extract minimum value
        my $minval = bitstream2dec($bitstream, $pos, $width);
        $minval += $refval if defined $minval;
        $pos += $width;
        $self->_spew(5, " Local reference value: %d", $minval) if defined $minval;

        # Extract number of bits for next subsets
        my $deltabits = bitstream2dec($bitstream, $pos, 6);
        $pos += 6;
        $self->_spew(5, " Increment width (bits): %d", $deltabits);

        if ($deltabits && defined $minval) {
            # Extract compressed data for all subsets
            my $incr_values;
            foreach my $isub (1..$nsubsets) {
                my $value = bitstream2dec($bitstream, $pos, $deltabits);
                if ($self->{VERBOSE} >= 5) {
                    $incr_values .= defined $value ? "$value," : ',';
                }
                $value = ($value + $minval) * $scale_factor if defined $value;
                # All bits set to 1 for associated field is NOT
                # interpreted as missing value
                if ($id == 999999 and ! defined $value) {
                    $value = 2**$width - 1;
                }
                push @{$subset_data_ref->[$isub]}, $value;
                $pos += $deltabits;
            }
            if ($self->{VERBOSE} >= 5) {
                chop $incr_values;
                $self->_spew(5, " Increment values: %s", $incr_values);
            }
        } else {
            # If minimum value is defined => All subsets set to minimum value
            # If minimum value is undefined => Data in all subsets are undefined
            my $value = (defined $minval) ? $minval*$scale_factor : undef;
            # Exception: all bits set to 1 for associated field is NOT
            # interpreted as missing value
            if ($id == 999999 and ! defined $value) {
                $value = 2**$width - 1;
            }
            foreach my $isub (1..$nsubsets) {
                push @{$subset_data_ref->[$isub]}, $value;
            }
            $pos += $nsubsets*$deltabits if defined $deltabits;
        }

        # Bit maps need special treatment. We are only able to
        # handle those where all subsets have exactly the same
        # bit map with the present method.
        if ($id eq '031031' and $self->{BUILD_BITMAP}) {
            _croak "$id: Unable to handle bit maps which differ between subsets"
                . " in compressed data" if $deltabits;
            # Store the index of expanded descriptors if data is
            # marked as present in data present indicator: 0 is
            # 'present', 1 (undef value) is 'not present'
            if (defined $minval) {
                push @{$self->{CURRENT_BITMAP}}, $self->{BITMAP_INDEX};
                push @{$self->{LAST_BITMAP}}, $self->{BITMAP_INDEX};
            }
            $self->{BITMAP_INDEX}++;

        } elsif ($self->{BUILD_BITMAP} and $self->{BITMAP_INDEX} > 0) {
            # We have finished building the bit map
            $self->{BUILD_BITMAP} = 0;
            $self->{BITMAP_INDEX} = 0;
        }
        $self->_spew(3, "  %s", join ' ',
                     map { defined($subset_data_ref->[$_][-1]) ?
                     $subset_data_ref->[$_][-1] : 'missing'} 1..$nsubsets )
                     if $self->{VERBOSE} >= 3;
    }
    return $pos;
}

## Takes a text $decoded_message as argument and returns BUFR messages
## which would give the same output as $decoded_message when running
## dumpsection0(), dumpsection1(), dumpsection3() and dumpsection4() in
## turn on each of the reencoded BUFR messages
sub reencode_message {
    my $self = shift;
    my $decoded_message = shift;
    my $width = shift || 15;    # Optional argument
    # Data values usually start at column 31, but if a $width
    # different from 15 was used in dumpsection4 you should use the
    # same value here

    my @lines = split /\n/, $decoded_message;
    my $bufr_messages = '';
    my $i = 0;

  MESSAGE: while ($i < @lines) {
        # Some tidying after decoding of previous message might be
        # necessary
        undef $self->{CHANGE_WIDTH};
        undef $self->{CHANGE_SCALE};
        undef $self->{CHANGE_REFERENCE};
        undef $self->{NEW_REFVAL_OF};
        undef $self->{ADD_ASSOCIATED_FIELD};
        undef $self->{BITMAPS};
        undef $self->{BITMAP_OPERATORS};
        $self->{NUM_BITMAPS} = 0;
        # $self->{LOCAL_USE} is always set for BUFR edition < 4 in _encode_sec1
        delete $self->{LOCAL_USE};

        # Extract section 0 info
        $i++ while $lines[$i] !~ /^Section 0/ and $i < @lines - 1;
        last MESSAGE if $i >= @lines - 1; # Not containing any decoded BUFR message
        $i++; # Skip length of BUFR message
        ($self->{BUFR_EDITION}) = $lines[++$i]
            =~ /BUFR edition:\s+(\d+)/;
        _croak "BUFR edition number not provided or is not a number"
            unless defined $self->{BUFR_EDITION};

        # Extract section 1 info
        $i++ while $lines[$i] !~ /^Section 1/;
        _croak "reencode_message: Don't find decoded section 1" if $i >= @lines;
        $i++; # Skip length of section 1
        if ($self->{BUFR_EDITION} < 4 ) {
            ($self->{MASTER_TABLE}) = $lines[++$i]
                =~ /BUFR master table:\s+(\d+)/;
            ($self->{SUBCENTRE}) = $lines[++$i]
                =~ /Originating subcentre:\s+(\d+)/;
            ($self->{CENTRE}) = $lines[++$i]
                =~ /Originating centre:\s+(\d+)/;
            ($self->{UPDATE_NUMBER}) = $lines[++$i]
                =~ /Update sequence number:\s+(\d+)/;
            ($self->{OPTIONAL_SECTION}) = $lines[++$i]
                =~ /Optional section present:\s+(\d+)/;
            ($self->{DATA_CATEGORY}) = $lines[++$i]
                =~ /Data category \(table A\):\s+(\d+)/;
            ($self->{DATA_SUBCATEGORY}) = $lines[++$i]
                =~ /Data subcategory:\s+(\d+)/;
            ($self->{MASTER_TABLE_VERSION}) = $lines[++$i]
                =~ /Master table version number:\s+(\d+)/;
            ($self->{LOCAL_TABLE_VERSION}) = $lines[++$i]
                =~ /Local table version number:\s+(\d+)/;
            ($self->{YEAR_OF_CENTURY}) = $lines[++$i]
                =~ /Year of century:\s+(\d+)/;
            ($self->{MONTH}) = $lines[++$i]
                =~ /Month:\s+(\d+)/;
            ($self->{DAY}) = $lines[++$i]
                =~ /Day:\s+(\d+)/;
            ($self->{HOUR}) = $lines[++$i]
                =~ /Hour:\s+(\d+)/;
            ($self->{MINUTE}) = $lines[++$i]
                =~ /Minute:\s+(\d+)/;
            _croak "reencode_message: Something seriously wrong in decoded section 1"
                unless defined $self->{MINUTE};
        } elsif ($self->{BUFR_EDITION} == 4) {
            ($self->{MASTER_TABLE}) = $lines[++$i]
                =~ /BUFR master table:\s+(\d+)/;
            ($self->{CENTRE}) = $lines[++$i]
                =~ /Originating centre:\s+(\d+)/;
            ($self->{SUBCENTRE}) = $lines[++$i]
                =~ /Originating subcentre:\s+(\d+)/;
            ($self->{UPDATE_NUMBER}) = $lines[++$i]
                =~ /Update sequence number:\s+(\d+)/;
            ($self->{OPTIONAL_SECTION}) = $lines[++$i]
                =~ /Optional section present:\s+(\d+)/;
            ($self->{DATA_CATEGORY}) = $lines[++$i]
                =~ /Data category \(table A\):\s+(\d+)/;
            ($self->{INT_DATA_SUBCATEGORY}) = $lines[++$i]
                =~ /International data subcategory:\s+(\d+)/;
            ($self->{LOC_DATA_SUBCATEGORY}) = $lines[++$i]
                =~ /Local data subcategory:\s+(\d+)/;
            ($self->{MASTER_TABLE_VERSION}) = $lines[++$i]
                =~ /Master table version number:\s+(\d+)/;
            ($self->{LOCAL_TABLE_VERSION}) = $lines[++$i]
                =~ /Local table version number:\s+(\d+)/;
            ($self->{YEAR}) = $lines[++$i]
                =~ /Year:\s+(\d+)/;
            ($self->{MONTH}) = $lines[++$i]
                =~ /Month:\s+(\d+)/;
            ($self->{DAY}) = $lines[++$i]
                =~ /Day:\s+(\d+)/;
            ($self->{HOUR}) = $lines[++$i]
                =~ /Hour:\s+(\d+)/;
            ($self->{MINUTE}) = $lines[++$i]
                =~ /Minute:\s+(\d+)/;
            ($self->{SECOND}) = $lines[++$i]
                =~ /Second:\s+(\d+)/;
            _croak "reencode_message: Something seriously wrong in decoded section 1"
                unless defined $self->{SECOND};
        }

        # Extract section 3 info
        $i++ while $lines[$i] !~ /^Section 3/;
        _croak "reencode_message: Don't find decoded section 3" if $i >= @lines;
        $i++; # Skip length of section 3

        ($self->{NUM_SUBSETS}) = $lines[++$i]
            =~ /Number of data subsets:\s+(\d+)/;
        ($self->{OBSERVED_DATA}) = $lines[++$i]
            =~ /Observed data:\s+(\d+)/;
        ($self->{COMPRESSED_DATA}) = $lines[++$i]
            =~ /Compressed data:\s+(\d+)/;
        ($self->{DESCRIPTORS_UNEXPANDED}) = $lines[++$i]
            =~ /Data descriptors unexpanded:\s+(\d+.*)/;
        _croak "reencode_message: Something seriously wrong in decoded section 3"
            unless defined $self->{DESCRIPTORS_UNEXPANDED};

        # Extract data values to use in section 4
        my ($data_refs, $desc_refs);
        my $subset = 0;
      SUBSET: while ($i < @lines - 1) {
            $_ = $lines[++$i];
            next SUBSET if /^$/ or /^Subset/;
            last SUBSET if /^Message/;
            $_ = substr $_, 0, $width + 16;
            s/^\s+//;
            next SUBSET if not /^\d/;
            my ($n, $desc, $value) = split /\s+/, $_, 3;
            $subset++ if $n == 1;
            if (defined $value) {
                $value =~ s/\s+$//;
                $value = undef if $value eq '' or $value eq 'missing';
            } else {
                # Some descriptors are not numbered (like 222000)
                $desc = $n;
                $value = '';
            }
            push @{$data_refs->[$subset]}, $value;
            push @{$desc_refs->[$subset]}, $desc;
        }

        # If optional section is present, pretend it is not, because we
        # are not able to encode this section
        if ($self->{OPTIONAL_SECTION}) {
            $self->{OPTIONAL_SECTION} = 0;
            carp "Warning: 'Optional section present' changed from 1 to 0'\n";
        }

        $bufr_messages .= $self->encode_message($data_refs, $desc_refs);
    }

    return $bufr_messages;
}


## Encode a new BUFR message. All relevant metadata
## ($self->{BUFR_EDITION} etc) must have been initialized already or
## else the _encode_sec routines will croak.
sub encode_message {
    my $self = shift;
    my ($data_refs, $desc_refs) = @_;

    _croak "encode_message: No data/descriptors provided" unless $desc_refs;

    $self->{MESSAGE_NUMBER}++;
    $self->_spew(2, "Encoding message number %d", $self->{MESSAGE_NUMBER});

    $self->load_BDtables();

    $self->_spew(2, "Encoding section 1-3");
    my $sec1_stream = $self->_encode_sec1();
    my $sec2_stream = $self->_encode_sec2();
    my $sec3_stream = $self->_encode_sec3();
    $self->_spew(2, "Encoding section 4");
    my $sec4_stream = $self->_encode_sec4($data_refs, $desc_refs);

    # Compute length of whole message and encode section 0
    my $msg_len = 8 + length($sec1_stream) + length($sec2_stream)
        + length($sec3_stream) + length($sec4_stream) + 4;
    my $msg_len_binary = pack("N", $msg_len);
    my $bufr_edition_binary = pack('n', $self->{BUFR_EDITION});
    my $sec0_stream = 'BUFR' . substr($msg_len_binary,1,3)
                             . substr($bufr_edition_binary,1,1);

    my $new_message = $sec0_stream . $sec1_stream . $sec2_stream
        . $sec3_stream  . $sec4_stream  . '7777';
    return $new_message;
}

## Encode and return section 1
sub _encode_sec1 {
    my $self = shift;

    my $bufr_edition = $self->{BUFR_EDITION} or
        _croak "_encode_sec1: BUFR edition not defined";

    my @keys = qw( MASTER_TABLE  CENTRE  SUBCENTRE  UPDATE_NUMBER
                   OPTIONAL_SECTION  DATA_CATEGORY  MASTER_TABLE_VERSION
                   LOCAL_TABLE_VERSION  MONTH  DAY  HOUR  MINUTE );
    if ($bufr_edition < 4) {
        push @keys, qw( DATA_SUBCATEGORY  YEAR_OF_CENTURY );
    } elsif ($bufr_edition == 4) {
        push @keys, qw( INT_DATA_SUBCATEGORY  LOC_DATA_SUBCATEGORY  YEAR  SECOND );
    }

    # Check that the required variables for section 1 are provided
    foreach my $key (@keys) {
        _croak "_encode_sec1: $key not given"
            unless defined $self->{$key};
    }

    $self->_validate_datetime() if ($Strict_checking);

    my $sec1_stream;
    # Byte 4-
    if ($bufr_edition < 4) {
        $self->{LOCAL_USE} = "\0" if not exists $self->{LOCAL_USE};
        $sec1_stream = pack 'C14a*',
            $self->{MASTER_TABLE},
            $self->{SUBCENTRE},
            $self->{CENTRE},
            $self->{UPDATE_NUMBER},
            $self->{OPTIONAL_SECTION},
            $self->{DATA_CATEGORY},
            $self->{DATA_SUBCATEGORY},
            $self->{MASTER_TABLE_VERSION},
            $self->{LOCAL_TABLE_VERSION},
            $self->{YEAR_OF_CENTURY},
            $self->{MONTH},
            $self->{DAY},
            $self->{HOUR},
            $self->{MINUTE},
            $self->{LOCAL_USE};
    } elsif ($bufr_edition == 4) {
        $sec1_stream = pack 'CnnC7nC5',
            $self->{MASTER_TABLE},
            $self->{CENTRE},
            $self->{SUBCENTRE},
            $self->{UPDATE_NUMBER},
            $self->{OPTIONAL_SECTION},
            $self->{DATA_CATEGORY},
            $self->{INT_DATA_SUBCATEGORY},
            $self->{LOC_DATA_SUBCATEGORY},
            $self->{MASTER_TABLE_VERSION},
            $self->{LOCAL_TABLE_VERSION},
            $self->{YEAR},
            $self->{MONTH},
            $self->{DAY},
            $self->{HOUR},
            $self->{MINUTE},
            $self->{SECOND},
            $self->{LOCAL_USE};
        $sec1_stream .= pack 'a*', $self->{LOCAL_USE}
            if exists $self->{LOCAL_USE};
    }

    my $sec1_len = 3 + length $sec1_stream;
    if ($bufr_edition < 4) {
        # Each section should be an even number of octets
        if ($sec1_len % 2) {
            $sec1_stream .= "\0";
            $sec1_len++;
        }
    }

    # Byte 1-3
    my $sec1_len_binary = substr pack("N", $sec1_len), 1, 3;

    return $sec1_len_binary . $sec1_stream;
}

## Encode and return section 2 (empty string if no optional section)
sub _encode_sec2 {
    my $self = shift;
    if ($self->{OPTIONAL_SECTION}) {
        _croak "_encode_sec2: No optional section provided"
            unless defined  $self->{SEC2_STREAM};
        return $self->{SEC2_STREAM};
    } else {
        return '';
    }
}

## Encode and return section 3
sub _encode_sec3 {
    my $self = shift;

    # Check that the required variables for section 3 are provided
    foreach my $key qw( NUM_SUBSETS OBSERVED_DATA COMPRESSED_DATA
                        DESCRIPTORS_UNEXPANDED ) {
        _croak "_encode_sec3: $key not given"
            unless defined $self->{$key};
    }

    my $nsubsets = $self->{NUM_SUBSETS};
    my $observed_data = $self->{OBSERVED_DATA};
    my $compressed_data = $self->{COMPRESSED_DATA};
    my @desc = split / /, $self->{DESCRIPTORS_UNEXPANDED};

    # Byte 5-6
    my $nsubsets_binary = pack "n", $nsubsets;

    # Byte 7
    my $flag = "\0";
    vec($flag, 7, 1) = $observed_data ? 1 : 0;
    vec($flag, 6, 1) = $compressed_data ? 1 : 0;

    # Byte 8-
    my $desc_binary = "\0\0" x @desc;
    my $pos = 0;
    foreach my $desc (@desc) {
        my ($f, $x, $y) = unpack 'AA2A3', $desc;
        dec2bitstream($f, $desc_binary, $pos, 2);
        $pos += 2;
        dec2bitstream($x, $desc_binary, $pos, 6);
        $pos += 6;
        dec2bitstream($y, $desc_binary, $pos, 8);
        $pos += 8;
    }

    my $sec3_len = 7 + length $desc_binary;
    if ($self->{BUFR_EDITION} < 4) {
        # Each section should be an even number of octets
        if ($sec3_len % 2) {
            $desc_binary .= "\0";
            $sec3_len++;
        }
    }

    # Byte 1-4
    my $sec3_len_binary = pack("N", $sec3_len);
    my $sec3_start = substr($sec3_len_binary, 1, 3) . "\0";

    return $sec3_start . $nsubsets_binary . $flag . $desc_binary;
}

## Encode and return section 4
sub _encode_sec4 {
    my $self = shift;
    my ($data_refs, $desc_refs) = @_;

    # Check that dimension of argument arrays agrees with number of
    # subsets in section 3
    my $nsubsets = $self->{NUM_SUBSETS};
    _croak "Wrong number of subsets ($nsubsets) in section 3?\n"
        . "Disagrees with dimension of descriptor array used as argument "
            . "to encode_message()"
                unless @$desc_refs == $nsubsets + 1;

    my ($bitstream, $byte_len) = ( $self->{COMPRESSED_DATA} )
        ? $self->_encode_compressed_bitstream($data_refs, $desc_refs)
            : $self->_encode_bitstream($data_refs, $desc_refs);

    my $sec4_len = $byte_len + 4;
    my $sec4_len_binary = pack("N", $sec4_len);
    my $sec4_stream = substr($sec4_len_binary, 1, 3) . "\0" . $bitstream;

    return $sec4_stream;
}

## Encode a nil message, i.e. all values set to missing except delayed
## replication factors and the (descriptor, value) pairs in the hash
## ref $stationid_ref. Delayed replication factors will all be set to
## 1 unless $delayed_repl_ref is provided, in which case the
## descriptors 031001 and 031002 will get the values contained in
## @$delayed_repl_ref. Note that data in section 1 and 3 must have
## been set before calling this method.
sub encode_nil_message {
    my $self = shift;
    my ($stationid_ref, $delayed_repl_ref) = @_;

    _croak "encode_nil_message: No station descriptors provided"
        unless $stationid_ref;

    my $bufr_edition = $self->{BUFR_EDITION} or
        _croak "encode_nil_message: BUFR edition not defined";

    $self->load_BDtables();

    $self->_spew(2, "Encoding NIL message");
    my $sec1_stream = $self->_encode_sec1();
    my $sec3_stream = $self->_encode_sec3();
    my $sec4_stream = $self->_encode_nil_sec4($stationid_ref,
                                              $delayed_repl_ref);

    # Compute length of whole message and encode section 0
    my $msg_len = 8 + length($sec1_stream) + length($sec3_stream)
        + length($sec4_stream) + 4;
    my $msg_len_binary = pack("N", $msg_len);
    my $bufr_edition_binary = pack('n', $bufr_edition);
    my $sec0_stream = 'BUFR' . substr($msg_len_binary,1,3)
                             . substr($bufr_edition_binary,1,1);

    my $new_message = $sec0_stream . $sec1_stream . $sec3_stream . $sec4_stream
        . '7777';
    return $new_message;
}

## Encode and return section 4 with all values set to missing except
## delayed replication factors and the (descriptor, value) pairs in
## the hash ref $stationid_ref. Delayed replication factors will all
## be set to 1 unless $delayed_repl_ref is provided, in which case the
## descriptors 031001 and 031002 will get the values contained in
## @$delayed_repl_ref (in that order).
sub _encode_nil_sec4 {
    my $self = shift;
    my ($stationid_ref, $delayed_repl_ref) = @_;
    my @delayed_repl = (defined $delayed_repl_ref) ? @$delayed_repl_ref : ();

    # Get the expanded list of descriptors (i.e. expanded with table D)
    if (not $self->{DESCRIPTORS_EXPANDED}) {
        _croak "_encode_nil_sec4: DESCRIPTORS_UNEXPANDED not given"
            unless $self->{DESCRIPTORS_UNEXPANDED};
        my @unexpanded = split / /, $self->{DESCRIPTORS_UNEXPANDED};
        _croak "_encode_nil_sec4: D_TABLE not given"
            unless $self->{D_TABLE};
        $self->{DESCRIPTORS_EXPANDED} =
            join " ", _expand_descriptors($self->{D_TABLE}, @unexpanded);
    }

    # The rest is very similar to sub _decode_bitstream, except that we
    # now are encoding, not decoding a bitstream, with most values set
    # to missing value, and we do not need to fully expand the
    # descriptors.
    my $B_table = $self->{B_TABLE};
    my @operators;
    my $bitstream = chr(255) x 65536; # one bits only
    my $pos = 0;

    my @desc = split /\s/, $self->{DESCRIPTORS_EXPANDED};
  D_LOOP: for (my $idesc = 0; $idesc < @desc; $idesc++) {

        my $id = $desc[$idesc];
        my ($f, $x, $y) = unpack 'AA2A3', $id;

        if ($f == 1) {
            # Delayed replication
            if ($x == 0) {
                _complain("Nonsensical replication of zero descriptors ($id)");
                $idesc++;
                next D_LOOP;
            }
            _croak "$id _expand_descriptors() did not do its job"
                if $y > 0;

            $_ = $desc[$idesc+1];
            _croak "$id Erroneous replication factor"
                unless /0310(00|01|02|11|12)/ && exists $B_table->{$_};
            my $factor = 1;
            if (@delayed_repl && /031001|2/) {
                $factor = shift @delayed_repl;
                croak "Delayed replication factor must be positive integer in "
                    . "encode_nil_message, is '$factor'"
                        if $factor !~ /^\d+$/ && $factor < 1;
            }
            my ($name,$unit,$scale,$refval,$width) = split /\0/, $B_table->{$_};
            $self->_spew(3, "%6s  %-20s   %s", $id, $unit, $name);
            $self->_spew(3, "  %s", $factor);
            dec2bitstream($factor, $bitstream, $pos, $width);
            $pos += $width;
            # Include the delayed replication in descriptor list
            splice @desc, $idesc++, 0, $_;

            my @r = ();
            push @r, @desc[($idesc+2)..($idesc+$x+1)] while $factor--;
            $self->_spew(4, "Delayed replication ($id $_ -> @r)");
            splice @desc, $idesc, 2+$x, @r;

            if ($idesc < @desc) {
                redo D_LOOP;
            } else {
                last D_LOOP;
            }

        } elsif ($f == 2) {
            my $next_id = $desc[$idesc + 1];
            my $flow;
            my $bm_idesc;
            ($pos, $flow, $bm_idesc, @operators)
                = $self->_apply_operator_descriptor($id, $x, $y, $pos,
                                                    $next_id, @operators);
            next D_LOOP if $flow eq 'next';
        }

        # We now have a "real" data descriptor

        # Find the relevant entry in BUFR table B
        _croak "Data descriptor $id is not present in BUFR table B"
            unless exists $B_table->{$id};
        my ($name,$unit,$scale,$refval,$width) = split /\0/, $B_table->{$id};
        $self->_spew(3, "%6s  %-20s   %s", $id, $unit, $name);

        # Override Table B values if Data Description Operators are in effect
        $width += $self->{CHANGE_WIDTH} if defined $self->{CHANGE_WIDTH};
        _croak "$id Data width <= 0" if $width <= 0;
        $scale += $self->{CHANGE_SCALE} if defined $self->{CHANGE_SCALE};
        my $scale_factor = $powers_of_ten[-$scale]; #10**(-$scale);
        $refval = $self->{NEW_REFVAL_OF}{$id} if defined $self->{NEW_REFVAL_OF}{$id};

        if ($stationid_ref->{$id}) {
            my $value = $stationid_ref->{$id};
            $self->_spew(3, "  %s", $value);
            if ($unit eq 'CCITTIA5') {
                # Encode ASCII string in $width bits (left justified,
                # padded with spaces)
                my $num_bytes = int ($width/8);
                _croak "Ascii string too long to fit in $width bits: $value"
                    if length($value) > $num_bytes;
                $value .= ' ' x ($num_bytes - length($value));
                ascii2bitstream($value, $bitstream, $pos, $num_bytes);
            } else {
                # Encode value as integer in $width bits
                $value = int( $value * $scale_factor - $refval + 0.5 );
                _croak "Data value no $id is negative: $value"
                    if $value < 0;
                dec2bitstream($value, $bitstream, $pos, $width);
            }
        } else {
            # Missing value is encoded as 1 bits
        }
        $pos += $width;
    }

    # Pad with 0 bits if necessary to get an even or integer number of
    # octets, depending on bufr edition
    my $padnum = ($self->{BUFR_EDITION} < 4) ? (16-($pos%16)) % 16 : (8-($pos%8)) % 8;
    if ($padnum > 0) {
        null2bitstream($bitstream, $pos, $padnum);
    }
    my $len = ($pos + $padnum)/8;
    $bitstream = substr $bitstream, 0, $len;

    # Encode section 4
    my $sec4_len_binary = pack("N", $len + 4);
    my $sec4_stream = substr($sec4_len_binary, 1, 3) . "\0" . $bitstream;

    return $sec4_stream;
}

## Encode bitstream using the data values in $data_refs, first
## expanding section 3 fully (and comparing with $desc_refs to check
## for consistency). This sub is very similar to sub _decode_bitstream
sub _encode_bitstream {
    my $self = shift;
    my ($data_refs, $desc_refs) = @_;

    # Expand section 3 except for delayed replication and operator descriptors
    my @unexpanded = split / /, $self->{DESCRIPTORS_UNEXPANDED};
    $self->{DESCRIPTORS_EXPANDED}
        = join " ", _expand_descriptors($self->{D_TABLE}, @unexpanded);

    my $nsubsets = $self->{NUM_SUBSETS};
    my $B_table = $self->{B_TABLE};
    my $maxlen = 1024;
    my $bitstream = chr(255) x $maxlen; # one bits only
    my $pos = 0;
    my @operators;

  S_LOOP: foreach my $isub (1..$nsubsets) {
        $self->_spew(2, "Encoding subset number %d", $isub);
        # The data values to use for this subset
        my $data_ref = $data_refs->[$isub];
        # The descriptors from expanding section 3
        my @desc = split /\s/, $self->{DESCRIPTORS_EXPANDED};
        # The descriptors to compare with for this subset
        my $desc_ref = $desc_refs->[$isub];

        # Note: @desc as well as $idesc may be changed during this loop,
        # so we cannot use a foreach loop instead
      D_LOOP: for (my $idesc = 0; $idesc < @desc; $idesc++) {
            my $id = $desc[$idesc];
            my ($f, $x, $y) = unpack 'AA2A3', $id;

            if ($f == 1) {
                # Delayed replication
                if ($x == 0) {
                    _complain("Nonsensical replication of zero descriptors ($id)");
                    $idesc++;
                    next D_LOOP;
                }
                _croak "$id _expand_descriptors() did not do its job"
                    if $y > 0;

                my $next_id = $desc[$idesc+1];
                _croak "$id Erroneous replication factor"
                    unless $next_id =~ /0310(00|01|02|11|12)/ && exists $B_table->{$next_id};
                _croak "Descriptor no $idesc is $desc_ref->[$idesc], expected $next_id"
                    if $desc_ref->[$idesc] != $next_id;
                my $factor = $data_ref->[$idesc];
                my ($name,$unit,$scale,$refval,$width) = split /\0/, $B_table->{$next_id};
                $self->_spew(3, "%6s  %-20s  %s", $next_id, $unit, $name);
                $self->_spew(3, "  %s", $factor);
                ($bitstream, $pos, $maxlen)
                    = $self->_encode_value($factor,$isub,$unit,$scale,$refval,
                                           $width,$next_id,$bitstream,$pos,$maxlen);
                # Include the delayed replication in descriptor list
                splice @desc, $idesc++, 0, $next_id;

                my @r = ();
                push @r, @desc[($idesc+2)..($idesc+$x+1)] while $factor--;
                $self->_spew(4, "Delayed replication ($id $next_id -> @r)");
                splice @desc, $idesc, 2+$x, @r;

                if ($idesc < @desc) {
                    redo D_LOOP;
                } else {
                    last D_LOOP;
                }

            } elsif ($f == 2) {
                my $flow;
                my $new_idesc;
                ($pos, $flow, $new_idesc, @operators)
                    = $self->_apply_operator_descriptor($id, $x, $y, $pos,
                                                        $desc[$idesc + 1], @operators);
                if ($flow eq 'redo_bitmap') {
                    # Data value is associated with the descriptor
                    # defined by bit map. Remember original and new
                    # index in descriptor array for the bit mapped
                    # values
                    push @{ $self->{BITMAPS}->[$self->{NUM_BITMAPS}] },
                        $new_idesc, $idesc;
                    $desc[$idesc] = $desc[$new_idesc];
                    redo D_LOOP;
                } elsif ($flow eq 'signify_character') {
                    _croak "Descriptor no $idesc is $desc_ref->[$idesc], expected $id"
                        if $desc_ref->[$idesc] != $id;
                    # Get ASCII string
                    my $value = $data_ref->[$idesc];
                    my $name = 'SIGNIFY CHARACTER';
                    my $unit = 'CCITTIA5';
                    my ($scale, $refval, $width) = (0, 0, 8*$y);
                    ($bitstream, $pos, $maxlen)
                        = $self->_encode_value($value,$isub,$unit,$scale,$refval,$width,"205$y",$bitstream,$pos,$maxlen);
                    next D_LOOP;
                } elsif ($flow eq 'no_value') {
                    next D_LOOP;
                }

                # Remove operator descriptor from @desc
                splice @desc, $idesc--, 1;

                next D_LOOP if $flow eq 'next';
                last D_LOOP if $flow eq 'last';
                if ($flow eq 'skip') {
                    # Remove next descriptor from @desc
                    splice @desc, $idesc+1, 1;
                    next D_LOOP;
                }
            }

            if ($self->{CHANGE_REFERENCE_VALUE}) {
                # The data descriptor is to be associated with a new
                # reference value, which is fetched from data stream,
                # possibly with f=9 instead of f=0 for descriptor
                $id -= 900000 if $id =~ /^9/;
                _croak "Change reference operator 203Y is not followed by element"
                    . " descriptor, but $id" if $f > 0;
                my $new_refval = $data_ref->[$idesc];
                $self->{NEW_REFVAL_OF}{$id}{$isub} = $new_refval;
                ($bitstream, $pos, $maxlen)
                    = $self->_encode_reference_value($new_refval,$id,$bitstream,$pos,$maxlen);
                next D_LOOP;
            }

            # If operator 204$y 'Add associated field' is in effect,
            # each data value is preceded by $y bits which should be
            # encoded separately. We choose to provide a descriptor
            # 999999 in this case (like the ECMWF libbufr software)
            if ($self->{ADD_ASSOCIATED_FIELD} and $id ne '031021') {
                # First encode associated field
                _croak "Descriptor no $idesc is $desc_ref->[$idesc], expected 999999"
                    if $desc_ref->[$idesc] != 999999;
                my $value = $data_ref->[$idesc];
                my $name = 'ASSOCIATED FIELD';
                my $unit = 'NUMERIC';
                my ($scale, $refval) = (0, 0);
                my $width = $self->{ADD_ASSOCIATED_FIELD};
                $self->_spew(4, "Added associated field: %s", $value);
                ($bitstream, $pos, $maxlen)
                    = $self->_encode_value($value,$isub,$unit,$scale,$refval,$width,999999,$bitstream,$pos,$maxlen);
                # Insert the artificial 999999 descriptor for the
                # associated value and increment $idesc to prepare for
                # handling the 'real' value below
                splice @desc, $idesc++, 0, 999999;
            }



            # For quality information, if this relates to a bit map we
            # need to store index of the data ($data_idesc) for which
            # the quality information applies, as well as the new
            # index ($idesc) in the descriptor array for the bit
            # mapped values
            if ($id =~ /^033/
                and defined $self->{BITMAP_OPERATORS}
                and $self->{BITMAP_OPERATORS}->[-1] eq '222000') {
                my $data_idesc = shift @{ $self->{CURRENT_BITMAP} };
                _croak "$id: Not enough quality values provided"
                    unless defined $data_idesc;
                push @{ $self->{BITMAPS}->[$self->{NUM_BITMAPS}] },
                    $data_idesc, $idesc;
            }

            my $value = $data_ref->[$idesc];

            if ($id eq '031031' and $self->{BUILD_BITMAP}) {
                # Store the index of expanded descriptors if data is
                # marked as present in data present indicator: 0 is
                # 'present', 1 (undef value) is 'not present'. E.g.
                # bitmap = 1100110 => (2,3,6) is stored in $self->{CURRENT_BITMAP}
                if (defined $value and $value == 0) {
                    push @{$self->{CURRENT_BITMAP}}, $self->{BITMAP_INDEX};
                    push @{$self->{LAST_BITMAP}}, $self->{BITMAP_INDEX};
                }
                $self->{BITMAP_INDEX}++;

            } elsif ($self->{BUILD_BITMAP} and $self->{BITMAP_INDEX} > 0) {
                # We have finished building the bit map
                $self->{BUILD_BITMAP} = 0;
                $self->{BITMAP_INDEX} = 0;
            }

            _croak "Not enough descriptors provided (expected no $idesc to be $id)"
                unless exists $desc_ref->[$idesc];
            _croak "Descriptor no $idesc is $desc_ref->[$idesc], expected $id"
                    if $desc_ref->[$idesc] != $id;

            # Find the relevant entry in BUFR table B
            _croak "Error: Data descriptor $id is not present in BUFR table B"
                unless exists $B_table->{$id};
            my ($name,$unit,$scale,$refval,$width) = split /\0/, $B_table->{$id};
            $refval = $self->{NEW_REFVAL_OF}{$id}{$isub} if defined $self->{NEW_REFVAL_OF}{$id}
                && defined $self->{NEW_REFVAL_OF}{$id}{$isub};
            $self->_spew(3, "%6s  %-20s  %s", $id, $unit, $name);
            $self->_spew(3, "  %s", defined $value ? $value : 'missing');
            ($bitstream, $pos, $maxlen)
                = $self->_encode_value($value,$isub,$unit,$scale,$refval,$width,$id,$bitstream,$pos,$maxlen);
        } # End D_LOOP
    } # END S_LOOP




    # Pad with 0 bits if necessary to get an even or integer number of
    # octets, depending on bufr edition
    my $padnum = ($self->{BUFR_EDITION} < 4) ? (16-($pos%16)) % 16 : (8-($pos%8)) % 8;
    if ($padnum > 0) {
        null2bitstream($bitstream, $pos, $padnum);
    }
    my $len = ($pos + $padnum)/8;
    $bitstream = substr $bitstream, 0, $len;

    return ($bitstream, $len);
}

sub _encode_reference_value {
    my $self = shift;
    my ($refval,$id,$bitstream,$pos,$maxlen) = @_;

    my $width = $self->{CHANGE_REFERENCE_VALUE};

    # Ensure that bitstream is big enough to encode $value
    while ($pos + $width > $maxlen*8) {
        $bitstream .= chr(255) x $maxlen;
        $maxlen *= 2;
    }

    $self->_spew(4, "Encoding new reference value %d for %6s in %d bits",
                 $refval, $id, $width);
    if ($refval >= 0) {
        _croak "Encoded reference value for $id is too big to fit "
            . "in $width bits: $refval"
                if $refval > 2**$width - 1;
        dec2bitstream($refval, $bitstream, $pos, $width);
    } else {
        # Negative reference values should be encoded by setting first
        # bit to 1 and then encoding absolute value
        _croak "Encoded reference value for $id is too big to fit "
            . "in $width bits: $refval"
                if -$refval > 2**($width-1) - 1;
        dec2bitstream(-$refval, $bitstream, $pos+1, $width-1);
    }
    $pos += $width;

    return ($bitstream, $pos, $maxlen);
}

sub _encode_value {
    my $self = shift;
    my ($value,$isub,$unit,$scale,$refval,$width,$id,$bitstream,$pos,$maxlen) = @_;

    # Override Table B values if Data Description Operators are in
    # effect (except for associated fields)
    if ($id != 999999) {
        $width += $self->{CHANGE_WIDTH} if defined $self->{CHANGE_WIDTH};
        _croak "$id Data width is $width which is <= 0" if $width <= 0;
        $scale += $self->{CHANGE_SCALE} if defined $self->{CHANGE_SCALE};
            $refval = $self->{NEW_REFVAL_OF}{$id}{$isub} if defined $self->{NEW_REFVAL_OF}{$id}
                && defined $self->{NEW_REFVAL_OF}{$id}{$isub};
        # Difference statistical values use different width and reference value
        if ($self->{DIFFERENCE_STATISTICAL_VALUE}) {
            $width += 1;
            $refval = -2**$width;
            undef $self->{DIFFERENCE_STATISTICAL_VALUE};
        }
    }

    # Ensure that bitstream is big enough to encode $value
    while ($pos + $width > $maxlen*8) {
        $bitstream .= chr(255) x $maxlen;
        $maxlen *= 2;
    }

    if (not defined($value)) {
        # Missing value is encoded as 1 bits
        $pos += $width;
    } elsif ($unit eq 'CCITTIA5') {
        # Encode ASCII string in $width bits (left justified,
        # padded with spaces)
        my $num_bytes = int ($width/8);
        _croak "Ascii string too long to fit in $width bits: $value"
            if length($value) > $num_bytes;
        $value .= ' ' x ($num_bytes - length($value));
        ascii2bitstream($value, $bitstream, $pos, $num_bytes);
        $pos += $width;
    } else {
        # Encode value as integer in $width bits
        _croak "Value '$value' is not a number for descriptor $id"
            unless looks_like_number($value);
        $value = int( $value * $powers_of_ten[$scale] - $refval + 0.5 );
        _croak "Encoded data value for $id is negative: $value" if $value < 0;
        _croak "Encoded data value for $id is too big to fit in $width bits: $value"
            if $value > 2**$width - 1;
        # Check for illegal flag value
        if ($Strict_checking and $unit =~ /^FLAG TABLE/ and $width > 1) {
            if ($value % 2) {
                my $max_value = 2**$width - 1;
                _complain("$id - $value: rightmost bit $width is set indicating missing value"
                          . " but then value should be $max_value");
            }
        }
        dec2bitstream($value, $bitstream, $pos, $width);
        $pos += $width;
    }

    return ($bitstream, $pos, $maxlen);
}

# Encode reference value using BUFR compression, assuming all subsets
# have same reference value
sub _encode_compressed_reference_value {
    my $self = shift;
    my ($refval,$id,$nsubsets,$bitstream,$pos,$maxlen) = @_;

    my $width = $self->{CHANGE_REFERENCE_VALUE};

    # Ensure that bitstream is big enough to encode $value
    while ($pos + ($nsubsets+1)*$width + 6 > $maxlen*8) {
        $bitstream .= chr(255) x $maxlen;
        $maxlen *= 2;
    }

    $self->_spew(4, "Encoding new reference value %d for %6s in %d bits",
                 $refval, $id, $width);
    # Encode value as integer in $width bits
    if ($refval >= 0) {
        _croak "Encoded reference value for $id is too big to fit "
            . "in $width bits: $refval" if $refval > 2**$width - 1;
        dec2bitstream($refval, $bitstream, $pos, $width);
    } else {
        # Negative reference values should be encoded by setting first
        # bit to 1 and then encoding absolute value
        _croak "Encoded reference value for $id is too big to fit "
            . "in $width bits: $refval" if -$refval > 2**($width-1) - 1;
        dec2bitstream(-$refval, $bitstream, $pos+1, $width-1);
    }
    $pos += $width;

    # Increment width set to 0
    dec2bitstream(0, $bitstream, $pos, 6);
    $pos += 6;

    return ($bitstream, $pos, $maxlen);
}

sub _encode_compressed_value {
    my $self = shift;
    my ($bitstream,$pos,$maxlen,$unit,$scale,$refval,$width,$id,$data_refs,$idesc,$nsubsets) = @_;

    # Override Table B values if Data Description Operators are in
    # effect (except for associated fields)
    if ($id != 999999) {
        $width += $self->{CHANGE_WIDTH} if defined $self->{CHANGE_WIDTH};
        _croak "$id Data width <= 0" if $width <= 0;
        $scale += $self->{CHANGE_SCALE} if defined $self->{CHANGE_SCALE};
        $refval = $self->{NEW_REFVAL_OF}{$id} if defined $self->{NEW_REFVAL_OF}{$id};
        # Difference statistical values use different width and reference value
        if ($self->{DIFFERENCE_STATISTICAL_VALUE}) {
            $width += 1;
            $refval = -2**$width;
            undef $self->{DIFFERENCE_STATISTICAL_VALUE};
        }
    }

    # Ensure that bitstream is big enough to encode $value
    while ($pos + ($nsubsets+1)*$width + 6 > $maxlen*8) {
        $bitstream .= chr(255) x $maxlen;
        $maxlen *= 2;
    }

    # Get all values for this descriptor
    my @values;
    my $first_value = $data_refs->[1][$idesc];
    my $all_equal = 1;        # Set to 0 if at least 2 elements differ
    foreach my $value ( map { $data_refs->[$_][$idesc] } 2..$nsubsets ) {
        if (defined($value) && $unit ne 'CCITTIA5' && !looks_like_number($value)) {
            _croak "Value '$value' is not a number for descriptor $id"
        }
        $all_equal = _check_equality($first_value, $value, $unit)
            if $all_equal;
        if (not defined $value) {
            push @values, undef;
        } elsif ($unit eq 'CCITTIA5') {
            push @values, $value;
        } else {
            push @values, int( $value * $powers_of_ten[$scale] - $refval + 0.5 );
        }
        # Check for illegal flag value
        if ($Strict_checking and $unit =~ /^FLAG TABLE/ and $width > 1) {
            if (defined $value and $value ne 'missing' and $value % 2) {
                my $max_value = 2**$width - 1;
                _complain("$id - value $value in subset $_:\n"
                          . "rightmost bit $width is set indicating missing value"
                          . " but then value should be $max_value");
            }
        }
    }

    if ($all_equal) {
        # Same value in all subsets. No need to calculate or store increments
        if (defined $first_value) {
            if ($unit eq 'CCITTIA5') {
                # Encode ASCII string in $width bits (left justified,
                # padded with spaces)
                my $num_bytes = int ($width/8);
                _croak "Ascii string too long to fit in $width bits: $first_value"
                    if length($first_value) > $num_bytes;
                $first_value .= ' ' x ($num_bytes - length($first_value));
                ascii2bitstream($first_value, $bitstream, $pos, $num_bytes);
            } else {
                # Encode value as integer in $width bits
                _croak "First value '$first_value' is not a number for descriptor $id"
                    unless looks_like_number($first_value);
                $first_value = int( $first_value * $powers_of_ten[$scale] - $refval + 0.5 );
                _croak "Encoded data value for $id is negative: $first_value"
                    if $first_value < 0;
                _croak "Encoded data value for $id is too big to fit "
                    . "in $width bits: $first_value"
                        if $first_value > 2**$width - 1;
                dec2bitstream($first_value, $bitstream, $pos, $width);
            }
        } else {
            # Missing value is encoded as 1 bits, but bitstream is
            # padded with 1 bits already
        }
        $pos += $width;
        # Increment width set to 0
        dec2bitstream(0, $bitstream, $pos, 6);
        $pos += 6;
    } else {
        if ($unit eq 'CCITTIA5') {
            unshift @values, $first_value;
            # Local reference value set to 0 bits
            null2bitstream($bitstream, $pos, $width);
            $pos += $width;
            # Do not store more characters than needed: remove leading
            # and trailing spaces, then right pad with spaces so that
            # all strings has same length as largest string
            my $largest_length = _trimpad(\@values);
            dec2bitstream($largest_length, $bitstream, $pos, 6);
            $pos += 6;
            # Store the character values
            foreach my $value (@values) {
                if (defined $value) {
                    # Encode ASCII string in $largest_length bytes
                    ascii2bitstream($value, $bitstream, $pos, $largest_length);
                } else {
                    # Missing value is encoded as 1 bits, but
                    # bitstream is padded with 1 bits already
                }
                $pos += $largest_length * 8;
            }
        } else {
            _croak "First value '$first_value' is not a number for descriptor $id"
                if defined($first_value) && !looks_like_number($first_value);
            unshift @values, (defined $first_value)
                ? int( $first_value * $powers_of_ten[$scale] - $refval + 0.5 )
                    : undef;
            # Numeric data. First find minimum value
            my $min_value = _minimum(\@values);
            my @inc_values =
                map { defined $_ ? $_ - $min_value : undef } @values;
            # Find how many bits are required to hold the increment
            # values (or rather: the highest increment value pluss one
            # (except for associated values), to be able to store
            # missing values also)
            my $max_inc = _maximum(\@inc_values);
            my $deltabits = ($id eq '999999')
                ?_get_number_of_bits_to_store($max_inc)
                    : _get_number_of_bits_to_store($max_inc + 1);
            # Store local reference value
            $self->_spew(5, " Local reference value: %d", $min_value);
            dec2bitstream($min_value, $bitstream, $pos, $width);
            $pos += $width;
            # Store increment width
            $self->_spew(5, " Increment width (bits): %d", $deltabits);
            dec2bitstream($deltabits, $bitstream, $pos, 6);
            $pos += 6;
            # Store values
            $self->_spew(5, " Increment values: %s",
                         join(',', map { defined $inc_values[$_]
                         ? $inc_values[$_] : ''} 0..$#inc_values))
                         if $self->{VERBOSE} >= 5;
            foreach my $value (@inc_values) {
                if (defined $value) {
                    dec2bitstream($value, $bitstream, $pos, $deltabits);
                } else {
                    # Missing value is encoded as 1 bits, but
                    # bitstream is padded with 1 bits already
                }
                $pos += $deltabits;
            }
        }
    }

    return ($bitstream, $pos, $maxlen);
}

## Encode bitstream using the data values in $data_refs, first
## expanding section 3 fully (and comparing with $desc_refs to check
## for consistency). This sub is very similar to sub
## _decode_compressed_bitstream
sub _encode_compressed_bitstream {
    my $self = shift;
    my ($data_refs, $desc_refs) = @_;

    # Expand section 3 except for delayed replication and operator
    # descriptors. This expansion is the same for all subsets, since
    # delayed replication has to be the same (this needs to be
    # checked) for compression to be possible
    my @unexpanded = split / /, $self->{DESCRIPTORS_UNEXPANDED};
    $self->{DESCRIPTORS_EXPANDED}
        = join " ", _expand_descriptors($self->{D_TABLE}, @unexpanded);
    my @desc = split /\s/, $self->{DESCRIPTORS_EXPANDED};

    my $nsubsets = $self->{NUM_SUBSETS};
    my $B_table = $self->{B_TABLE};
    my $maxlen = 1024;
    my $bitstream = chr(255) x $maxlen; # one bits only
    my $pos = 0;
    my @operators;

    my $desc_ref = $desc_refs->[1];

    # All subsets should have same set of expanded descriptors. This
    # is checked later, but we also need to check that the number of
    # descriptors in each subset is the same for all subsets
    my $num_desc = @{$desc_ref};
    foreach my $isub (2..$nsubsets) {
        my $num_d = @{$desc_refs->[$isub]};
        _croak "Compression impossible: Subset 1 contains $num_desc descriptors,"
            . " while subset $isub contains $num_d descriptors"
                if $num_d != $num_desc;
    }


  D_LOOP: for (my $idesc = 0; $idesc < @desc; $idesc++) {
        my $id = $desc[$idesc];
        my ($f, $x, $y) = unpack 'AA2A3', $id;

        if ($f == 1) {
            # Delayed replication
            if ($x == 0) {
                _complain("Nonsensical replication of zero descriptors ($id)");
                $idesc++;
                next D_LOOP;
            }
            _croak "$id _expand_descriptors() did not do its job"
                if $y > 0;

            my $next_id = $desc[$idesc+1];
            _croak "$id Erroneous replication factor"
                unless $next_id =~ /0310(00|01|02|11|12)/ && exists $B_table->{$next_id};
            _croak "Descriptor no $idesc is $desc_ref->[$idesc], expected $next_id"
                if $desc_ref->[$idesc] != $next_id;
            my $factor = $data_refs->[1][$idesc];
            my ($name,$unit,$scale,$refval,$width) = split /\0/, $B_table->{$next_id};
            $self->_spew(3, "%6s  %-20s  %s", $next_id, $unit, $name);
            $self->_spew(3, "  %s", $factor);
            ($bitstream, $pos, $maxlen)
                = $self->_encode_compressed_value($bitstream,$pos,$maxlen,
                                                  $unit,$scale,$refval,$width,
                                                  $next_id,$data_refs,$idesc,$nsubsets);
            # Include the delayed replication in descriptor list
            splice @desc, $idesc++, 0, $next_id;

            my @r = ();
            push @r, @desc[($idesc+2)..($idesc+$x+1)] while $factor--;
            $self->_spew(4, "Delayed replication ($id $next_id -> @r)");
            splice @desc, $idesc, 2+$x, @r;

            if ($idesc < @desc) {
                redo D_LOOP;
            } else {
                last D_LOOP;
            }

        } elsif ($f == 2) {
            my $flow;
            my $new_idesc;
            ($pos, $flow, $new_idesc, @operators)
                = $self->_apply_operator_descriptor($id, $x, $y, $pos,
                                                    $desc[$idesc + 1], @operators);
            if ($flow eq 'redo_bitmap') {
                # Data value is associated with the descriptor
                # defined by bit map. Remember original and new
                # index in descriptor array for the bit mapped
                # values
                push @{ $self->{BITMAPS}->[$self->{NUM_BITMAPS}] },
                    $new_idesc, $idesc;
                $desc[$idesc] = $desc[$new_idesc];
                redo D_LOOP;
            } elsif ($flow eq 'signify_character') {
                _croak "Descriptor no $idesc is $desc_ref->[$idesc], expected $id"
                    if $desc_ref->[$idesc] != $id;
                # Get ASCII string
                my @values = map { $data_refs->[$_][$idesc] } 1..$nsubsets;
                my $name = 'SIGNIFY CHARACTER';
                my $unit = 'CCITTIA5';
                my ($scale, $refval, $width) = (0, 0, 8*$y);
                ($bitstream, $pos, $maxlen)
                    = $self->_encode_compressed_value($bitstream,$pos,$maxlen,
                                                      $unit,$scale,$refval,$width,
                                                      "205$y",$data_refs,$idesc,$nsubsets);
                next D_LOOP;
            } elsif ($flow eq 'no_value') {
                next D_LOOP;
            }

            # Remove operator descriptor from @desc
            splice @desc, $idesc--, 1;

            next D_LOOP if $flow eq 'next';
            last D_LOOP if $flow eq 'last';
            if ($flow eq 'skip') {
                # Remove next descriptor from @desc
                splice @desc, $idesc+1, 1;
                next D_LOOP;
            }
        }

        if ($self->{CHANGE_REFERENCE_VALUE}) {
            # The data descriptor is to be associated with a new
            # reference value, which is fetched from data stream,
            # possibly with f=9 instead of f=0 for descriptor
            $id -= 900000 if $id =~ /^9/;
            _croak "Change reference operator 203Y is not followed by element"
                . " descriptor, but $id" if $f > 0;
            my @new_ref_values = map { $data_refs->[$_][$idesc] } 1..$nsubsets;
            my $new_refval = $new_ref_values[0];
            # Check that they are all the same
            foreach my $val (@new_ref_values[1..$#new_ref_values]) {
                _croak "Change reference value differ between subsets"
                    . " which cannot be combined with BUFR compression"
                        if $val != $new_refval;
            }
            $self->{NEW_REFVAL_OF}{$id} = $new_refval;
            ($bitstream, $pos, $maxlen)
                = $self->_encode_compressed_reference_value($new_refval,$id,$nsubsets,$bitstream,$pos,$maxlen);
            next D_LOOP;
        }

        # If operator 204$y 'Add associated field' is in effect,
        # each data value is preceded by $y bits which should be
        # encoded separately. We choose to provide a descriptor
        # 999999 in this case (like the ECMWF libbufr software)
        if ($self->{ADD_ASSOCIATED_FIELD} and $id ne '031021') {
            # First encode associated field
            _croak "Descriptor no $idesc is $desc_ref->[$idesc], expected 999999"
                if $desc_ref->[$idesc] != 999999;
            my @values = map { $data_refs->[$_][$idesc] } 1..$nsubsets;
            my $name = 'ASSOCIATED FIELD';
            my $unit = 'NUMERIC';
            my ($scale, $refval) = (0, 0);
            my $width = $self->{ADD_ASSOCIATED_FIELD};
            $self->_spew(3, "%6s  %-20s  %s", $id, $unit, $name);
            $self->_spew(3, "  %s", 999999);
            ($bitstream, $pos, $maxlen)
                = $self->_encode_compressed_value($bitstream,$pos,$maxlen,
                                                  $unit,$scale,$refval,$width,
                                                  999999,$data_refs,$idesc,$nsubsets);
            # Insert the artificial 999999 descriptor for the
            # associated value and increment $idesc to prepare for
            # handling the 'real' value below
            splice @desc, $idesc++, 0, 999999;
        }



        # For quality information, if this relates to a bit map we
        # need to store index of the data ($data_idesc) for which
        # the quality information applies, as well as the new
        # index ($idesc) in the descriptor array for the bit
        # mapped values
        if ($id =~ /^033/
            and defined $self->{BITMAP_OPERATORS}
            and $self->{BITMAP_OPERATORS}->[-1] eq '222000') {
            my $data_idesc = shift @{ $self->{CURRENT_BITMAP} };
            _croak "$id: Not enough quality values provided"
                unless defined $data_idesc;
            push @{ $self->{BITMAPS}->[$self->{NUM_BITMAPS}] },
                $data_idesc, $idesc;
        }

        if ($id eq '031031' and $self->{BUILD_BITMAP}) {
            # Store the index of expanded descriptors if data is
            # marked as present in data present indicator: 0 is
            # 'present', 1 (undef value) is 'not present'. E.g.
            # bitmap = 1100110 => (2,3,6) is stored in $self->{CURRENT_BITMAP}

            # NB: bit map might vary betwen subsets!!!!????
            if (defined $data_refs->[1][$idesc]) {
                push @{$self->{CURRENT_BITMAP}}, $self->{BITMAP_INDEX};
                push @{$self->{LAST_BITMAP}}, $self->{BITMAP_INDEX};
            }
            $self->{BITMAP_INDEX}++;

        } elsif ($self->{BUILD_BITMAP} and $self->{BITMAP_INDEX} > 0) {
            # We have finished building the bit map
            $self->{BUILD_BITMAP} = 0;
            $self->{BITMAP_INDEX} = 0;
        }

        # We now have a "real" data descriptor
        _croak "Descriptor no $idesc is $desc_ref->[$idesc], expected $id"
            if $desc_ref->[$idesc] != $id;

        # Find the relevant entry in BUFR table B
        _croak "Data descriptor $id is not present in BUFR table B"
            unless exists $B_table->{$id};
        my ($name,$unit,$scale,$refval,$width) = split /\0/, $B_table->{$id};
        $self->_spew(3, "%6s  %-20s  %s", $id, $unit, $name);
        $self->_spew(3, "  %s", join ' ',
                     map { defined($data_refs->[$_][$idesc]) ?
                     $data_refs->[$_][$idesc] : 'missing'} 1..$nsubsets )
                     if $self->{VERBOSE} >= 3;
        ($bitstream, $pos, $maxlen)
            = $self->_encode_compressed_value($bitstream,$pos,$maxlen,
                                              $unit,$scale,$refval,$width,
                                              $id,$data_refs,$idesc,$nsubsets);
    } # End D_LOOP

    # Pad with 0 bits if necessary to get an even or integer number of
    # octets, depending on bufr edition
    my $padnum = ($self->{BUFR_EDITION} < 4) ? (16-($pos%16)) % 16 : (8-($pos%8)) % 8;
    if ($padnum > 0) {
        null2bitstream($bitstream, $pos, $padnum);
    }
    my $len = ($pos + $padnum)/8;
    $bitstream = substr $bitstream, 0, $len;

    return ($bitstream, $len);
}

## Check that the length of data section computed from expansion of
## section 3 ($comp_len) equals actual length of data part of section
## 4, allowing for padding one bits according to BUFR Regulation 94.1.3
## Strict checking should also check that padding actually consists of
## one bits only.
sub _check_section4_length {
    my $self = shift;
    my ($comp_len, $actual_len) = @_;

    if ($comp_len > $actual_len) {
        _croak "More descriptors in expansion of section 3"
            . " than what can fit in the given length of section 4"
                . " ($comp_len versus $actual_len bits)";
    } else {
        return if not $Strict_checking; # Excessive bytes in section 4
                                        # does not prevent further decoding
        return if $Noqc;  # No more sensible checks to do in this case

        my $bufr_edition = $self->{BUFR_EDITION};
        my $actual_bytes = $actual_len/8; # This is sure to be an integer
        if ($bufr_edition < 4 and $actual_bytes % 2) {
            _complain("Section 4 is odd number ($actual_bytes) of bytes,"
                      . " which is an error in BUFR edition $bufr_edition");
        }
        my $comp_bytes = int($comp_len/8);
        $comp_bytes++ if $comp_len % 8; # Need to pad with one bits
        $comp_bytes++ if $bufr_edition < 4 and $comp_bytes % 2; # Need to pad with an extra byte of one bits
        if ($actual_bytes > $comp_bytes) {
            _complain("Section 4 longer ($actual_bytes bytes) than expected"
                      . " from section 3 ($comp_bytes bytes)");
        }
    }
    return;
}

# Trim string, also for trailing nulls
sub _trim {
    my $str = shift;
    return unless defined $str;
    $str =~ s/\0+$//;
    $str =~ s/\s+$//;
    $str =~ s/\0+$//;
    $str =~ s/^\s+//;
    return $str;
}

## Remove leading and trailing spaces in the strings provided, then add
## spaces if necessary so that all strings have same length as largest
## trimmed string. This length (in bytes) is returned
sub _trimpad {
    my $string_ref = shift;
    my $largest_length = 0;
    foreach my $string (@{$string_ref}) {
        if (defined $string) {
            $string =~ s/^\s+//;
            $string =~ s/\s+$//;
            if (length $string > $largest_length) {
                $largest_length = length $string;
            }
        }
    }
    foreach my $string (@{$string_ref}) {
        if (defined $string) {
            $string .= ' ' x ($largest_length - length $string);
        }
    }
    return $largest_length;
}

## Use timegm in Time::Local to validate date and time in section 1
sub _validate_datetime {
    my $self = shift;
    my $bufr_edition = $self->{BUFR_EDITION};
    my $year = ($bufr_edition < 4) ? $self->{YEAR_OF_CENTURY} + 2000
                                   : $self->{YEAR};
    my $month = $self->{MONTH} - 1;
    my $second = ($bufr_edition == 4) ? $self->{SECOND} : 0;

    eval {
        my $dummy = timegm($second,$self->{MINUTE},$self->{HOUR},
                           $self->{DAY},$month,$year);
    };

    _complain("Invalid date in section 1: $@") if $@;
}

## Return number of bits necessary to store the non negative number $n
## (1 for 0,1, 2 for 2,3, 3 for 4,5,6,7 etc)
sub _get_number_of_bits_to_store {
    my $n = shift;
    return 1 if $n == 0;
    my $x = 1;
    my $i = 0;
    while ($x < $n) {
        $i++;
        $x *= 2;
    }
    return ($x == $n )? $i + 1 : $i;
}

sub _check_equality {
    my ($v, $w, $unit) = @_;
    if (defined $v and defined $w) {
        if ($unit eq 'CCITTIA5') {
            return 0 if $v ne $w;
        } else {
            return 0 if $v != $w;
        }
    } elsif (defined $v or defined $w) {
        return 0;
    }
    return 1;
}



## Find minimum value among set of non negative numbers or undefined values
sub _minimum {
    my $v_ref = shift;
    my $min = 9999999999;
    foreach my $v (@{$v_ref}) {
        next if not defined $v;
        if ($v < $min) {
            $min = $v;
        }
    }
    _croak "Internal error: Minimum value negative: $min" if $min < 0;
    return $min;
}

## Find maximum value among set of non negative numbers or undefined values
sub _maximum {
    my $v_ref = shift;
    my $max = -1;
    foreach my $v (@{$v_ref}) {
        next if not defined $v;
        if ($v > $max) {
            $max = $v;
        }
    }
    _croak "Internal error: Found no maximum value" if $max < 0;
    return $max;
}

sub _apply_operator_descriptor {
    my $self = shift;
    my ($id, $x, $y, $pos, $next_id, @operators) = @_;
    my $flow = '';
    my $bm_idesc = '';

    $_ = $id;
    if (/^20[123]000/) {
        # Cancellation of a data descriptor operator
        _complain("$id Cancelling unused operator")
            unless grep {$_ == $x} @operators;
        @operators = grep {$_ != $x} @operators;
      SWITCH: {
            $x == 1 and undef $self->{CHANGE_WIDTH}, last SWITCH;
            $x == 2 and undef $self->{CHANGE_SCALE}, last SWITCH;
            $x == 3 and undef $self->{NEW_REFVAL_OF}, last SWITCH;
        }
        $self->_spew(4, "$id * Reset ".
                     ("data width","scale","reference values")[$x-1]);
        $flow = 'next';
    } elsif (/^201/) {
        # Change data width
        $self->{CHANGE_WIDTH} = $y-128;
        $self->_spew(4, "$id * Change data width: "
                     . "$self->{CHANGE_WIDTH}");
        push @operators, $x;
        $flow = 'next';
    } elsif (/^202/) {
        # Change scale
        $self->{CHANGE_SCALE} = $y-128;
        $self->_spew(4, "$id * Change scale: "
                     . "$self->{CHANGE_SCALE}");
        push @operators, $x;
        $flow = 'next';
    } elsif (/^203255/) {
        # Stop redefining reference values
        $self->_spew(4, "$id * Terminate reference value definition %s",
                     '203' . (defined $self->{CHANGE_REFERENCE_VALUE}
                     ? sprintf("%03d", $self->{CHANGE_REFERENCE_VALUE}) : '???'));
        _complain("$id no current change reference value to terminate")
            unless defined $self->{CHANGE_REFERENCE_VALUE};
        undef $self->{CHANGE_REFERENCE_VALUE};
        $flow = 'next';
    } elsif (/^203/) {
        # Change reference value
        $self->_spew(4, "$id * Change reference value");
        # Get reference value from data stream ($y == number of bits)
        $self->{CHANGE_REFERENCE_VALUE} = $y;
        push @operators, $x;
        $flow = 'next';
    } elsif (/^204/) {
        # Add associated field
        if ($y > 0) {
            _croak "$id Nesting of Add associated field is not implemented"
                if $self->{ADD_ASSOCIATED_FIELD};
            $self->{ADD_ASSOCIATED_FIELD} = $y;
            $flow = 'next';
        } else {
            _complain "$id No previous Add associated field"
                unless defined $self->{ADD_ASSOCIATED_FIELD};
            undef $self->{ADD_ASSOCIATED_FIELD};
            $flow = 'next';
        }
    } elsif (/^205/) {
        # Signify character (i.e. the following $y bytes is character information)
        $flow = 'signify_character';
    } elsif (/^206/) {
        # Signify data width for the immediately following local
        # descriptor. If we find this local descriptor in BUFR table B
        # with data width $y bits, we assume we can use this table
        # entry to decode the value properly, and can just ignore the
        # operator descriptor. Else we choose to skip the local
        # descriptor and the corresponding value
        if (exists $self->{B_TABLE}->{$next_id}
            and (split /\0/, $self->{B_TABLE}->{$next_id})[-1] == $y) {
            $self->_spew(4, "Found $next_id with data width $y, ignoring $_");
            $flow = 'next';
        } else {
            $self->_spew(4, "$_: Did not find $next_id in table B."
                         . " Skipping $_ and $next_id.");
            $pos += $y;         # Skip next $y bits in bitstream
            $flow = 'skip';
        }

    } elsif (/^222000/) {
        # Quality information follows
        push @{ $self->{BITMAP_OPERATORS} }, '222000';
        $self->{NUM_BITMAPS}++;
        # Mark that a bit map probably needs to be built
        $self->{BUILD_BITMAP} = 1;
        $self->{BITMAP_INDEX} = 0;
        $flow = $Noqc ? 'last' : 'no_value';
    } elsif (/^223000/) {
        # Substituted values follow, each one following a descriptor 223255.
        # Which value they are a substitute for is defined by a bit map, which
        # already may have been defined (if descriptor 23700 is encountered),
        # or will shortly be defined by data present descriptors (031031)
        push @{ $self->{BITMAP_OPERATORS} }, '223000';
        $self->{NUM_BITMAPS}++;
        # Mark that a bit map probably needs to be built
        $self->{BUILD_BITMAP} = 1;
        $self->{BITMAP_INDEX} = 0;
        $flow = 'no_value';
    } elsif (/^223255/) {
        # Substituted values marker operator
        _croak "$id No bit map defined"
            unless defined $self->{BITMAPS} and $self->{BITMAP_OPERATORS}[-1] eq '223000';
        _croak "More 223255 encountered than current bit map allows"
            unless @{$self->{CURRENT_BITMAP}};
        $bm_idesc = shift @{$self->{CURRENT_BITMAP}};
        $flow = 'redo_bitmap';
    } elsif (/^224000/) {
        # First order statistical values follow
        push @{ $self->{BITMAP_OPERATORS} }, '224000';
        $self->{NUM_BITMAPS}++;
        # Mark that a bit map probably needs to be built
        $self->{BUILD_BITMAP} = 1;
        $self->{BITMAP_INDEX} = 0;
        $flow = 'no_value';
    } elsif (/^224255/) {
        # First order statistical values marker operator
        _croak "$id No bit map defined"
            unless defined $self->{BITMAPS} and $self->{BITMAP_OPERATORS}[-1] eq '224000';
        _croak "More 224255 encountered than current bit map allows"
            unless @{$self->{CURRENT_BITMAP}};
        $bm_idesc = shift @{$self->{CURRENT_BITMAP}};
        $flow = 'redo_bitmap';
    } elsif (/^225000/) {
        # Difference statistical values follow
        push @{ $self->{BITMAP_OPERATORS} }, '225000';
        $self->{NUM_BITMAPS}++;
        # Mark that a bit map probably needs to be built
        $self->{BUILD_BITMAP} = 1;
        $self->{BITMAP_INDEX} = 0;
        $flow = 'no_value';
    } elsif (/^225255/) {
        # Difference statistical values marker operator
        _croak "$id No bit map defined\n"
            unless defined $self->{CURRENT_BITMAP} and $self->{BITMAP_OPERATORS}[-1] eq '225000';
        _croak "More 225255 encountered than current bit map allows"
            unless @{$self->{CURRENT_BITMAP}};
        $bm_idesc = shift @{$self->{CURRENT_BITMAP}};
        # Must remember to change data width and reference value
        $self->{DIFFERENCE_STATISTICAL_VALUE} = 1;
        $flow = 'redo_bitmap';
    } elsif (/^232000/) {
        # Replaced/retained values follow
        _croak "$id Replaced/retained values (not implemented)";
    } elsif (/^232255/) {
        # Replaced/retained values marker operator
        _croak "$id Replaced/retained values marker (not implemented)";
    } elsif (/^235000/) {
        # Cancel backward data reference
        _croak "$id Cancel backward data reference (not implemented)";
    } elsif (/^236000/) {
        # Define data present bit map
        undef $self->{CURRENT_BITMAP};
        $self->{BUILD_BITMAP} = 1;
        $self->{BITMAP_INDEX} = 0;
        $flow = 'no_value';
    } elsif (/^237000/) {
        # Use defined data present bit map
        _croak "$id No previous bit map defined"
            unless defined $self->{LAST_BITMAP};
        @{ $self->{CURRENT_BITMAP} } = @ { $self->{LAST_BITMAP} };
        $self->{BUILD_BITMAP} = 0;
        $flow = 'no_value';
    } elsif (/^237255/) {
        # Cancel 'use defined data present bit map'
        _complain("$id No data present bit map to cancel")
            unless defined $self->{LAST_BITMAP};
        undef $self->{LAST_BITMAP};
        $flow = 'next';
    } else {
        _croak "$id Unknown data description operator";
    }

    return ($pos, $flow, $bm_idesc, @operators);
}

sub join_subsets {
    my $self = shift;
    my (@bufr, @subset_list);
    my $last_arg_was_bufr;
    my $num_objects = 0;
    while (@_) {
        my $arg = shift;
        if (ref($arg) eq 'Geo::BUFR') {
            $bufr[$num_objects++] = $arg;
            $last_arg_was_bufr = 1;
        } elsif (ref($arg) eq 'ARRAY') {
            _croak "Wrong input (multiple array refs) to join_subsets"
                unless $last_arg_was_bufr;
            $subset_list[$num_objects-1] = $arg;
            $last_arg_was_bufr = 0;
        } else {
            _croak "Input is not Geo::BUFR object or array ref in join_subsets";
        }
    }

    my ($data_refs, $desc_refs);
    my $n = 1; # Number of subsets included
    # Ought to check for common section 3 also?
    for (my $i=0; $i < $num_objects; $i++) {
        $bufr[$i]->rewind();
        my $isub = 1;
        while (not $bufr[$i]->eof()) {
            my ($data, $descriptors) = $bufr[$i]->next_observation();
            if (!exists $subset_list[$i] # grab all subsets from this object
                || grep(/^$isub$/,       # grab the subsets specified
                        @{$subset_list[$i]})) {
                $self->_spew(2, "Joining subset $isub from bufr object $i");
                $data_refs->[$n] = $data;
                $desc_refs->[$n++] = $descriptors;
            }
            $isub++;
        }
        $bufr[$i]->rewind();
    }
    $n--;
    return ($data_refs, $desc_refs, $n)
}

1;  # Make sure require or use succeeds.


__END__
# Below is documentation for the module. You'd better read it!

=head1 NAME

Geo::BUFR - Perl extension for handling of WMO BUFR files.


=head1 SYNOPSIS

  # A simple program to print decoded content of a BUFR file

  use Geo::BUFR;

  Geo::BUFR->set_tablepath('path to BUFR tables');

  my $bufr = Geo::BUFR->new();

  # If you want flag and code table values to be resolved
  $bufr->load_Ctable('your favourite C table');

  $bufr->fopen('BUFR file');

  while (not $bufr->eof()) {
      my ($data, $descriptors) = $bufr->next_observation();
      print $bufr->dumpsections($data, $descriptors);
  }

  $bufr->fclose();


=head1 DESCRIPTION

B<BUFR> = B<B>inary B<U>niversal B<F>orm for the B<R>epresentation of
meteorological data. BUFR is approved by WMO (World Meteorological
Organization) as the standard universal exchange format for
meteorological observations, gradually replacing a lot of older
alphanumeric data formats.

This module provides methods for decoding and encoding BUFR messages,
and for displaying information in BUFR B and D tables and in BUFR flag
and code tables.

Installing this module also installs some programs: C<bufrread.pl>,
C<bufrresolve.pl>, C<bufrencode.pl>, C<bufr_reencode.pl> and
C<bufralter.pl>. See L<https://wiki.met.no/bufr.pm/start> for examples
of use. For the majority of potential users of Geo::BUFR I would
expect these programs to be all that you will need Geo::BUFR for.

Note that being Perl, this module cannot compete in speed with for
example the (free) ECMWF Fortran library libbufr. Still, some effort
has been put into making the module reasonable fast in that the core
routines for encoding and decoding bitstreams are implemented in C.


=head1 METHODS

The C<get_> methods will return undef if the requested information is
not available. The C<set_> methods as well as C<fopen>, C<fclose>,
C<copy_from> and C<rewind> will always return 1, or croak if failing.

Create a new object:

  $bufr = Geo::BUFR->new();
  $bufr = Geo::BUFR->new($BUFRmessages);

The second form of C<new> is useful if you want to provide the BUFR
messages to decode directly as an input buffer (string). Note that
merely calling C<new($BUFRmessages)> will not decode anything in the
BUFR messages, for that you need to call C<next_observation()> from
the newly created object. You also have the option of providing the
BUFR messages in a file, using the no argument form of C<new()> and
then calling C<fopen>.

Associate the object with a file for reading of BUFR messages:

  $bufr->fopen($filename);

Close the associated file that was opened by fopen:

  $bufr->fclose();

Check for end-of-file (or end of the input buffer provided as argument
to C<new>):

  $bufr->eof();

Returns true if end-of-file (or end of input buffer) is reached, false
if not.

Ensure that next call to C<next_observation> will decode first subset
in first BUFR message:

  $bufr->rewind();

Copy from an existing object:

  $bufr1->copy_from($bufr2,$what);

If $what is 'all' or not provided, will copy everything in $bufr2 into
$bufr1, i.e. making a clone. If $what is 'metadata', only the metadata
in section 0, 1 and 3 will be copied.

Load B and D tables:

  $bufr->load_BDtables($table);

$table is optional, and should be (base)name of a file containing a
BUFR table B or D, using the ECMWF libbufr naming convention,
i.e. [BD]'table_version'.TXT. If no argument is provided,
C<load_BDtables()> will use BUFR section 1 information in the $bufr
object to decide which tables to load. Previously loaded tables are
kept in memory, and C<load_BDtables> will return immediately if the
tables already have been loaded. Returns table version (see
C<get_table_version>).

Load C table:

  $bufr->load_Ctable($table,$default_table);

Both $table and $default_table are optional. This will load the flag
and code tables (if not already loaded), which in ECMWF libbufr are
put in tables C'table_version'.TXT (not to be confused with WMO BUFR
table C, which contain the operator descriptors). $default_table will
be used if $table is not found. If no arguments are provided,
C<load_Ctable()> will use BUFR section 1 information in the $bufr
object to decide which table to load. Returns table version.

Get next observation (next subset in current BUFR message or first subset
in next message):

  ($data, $descriptors) = $bufr->next_observation();

where $descriptors is a reference to the array of fully expanded
descriptors for this subset, $data is a reference to the corresponding
values. This method is meant to be used to iterate through all BUFR
messages in the file or input buffer (see C<new>) associated with the
$bufr object. Whenever a new BUFR message is reached, section 0-3 will
also be decoded, whose content is then available through the access
methods listed below. This is the main BUFR decoding routine in
Geo::BUFR, and will call C<load_BDtables()> internally, but not
C<load_Ctable>. Consult L</DECODING/ENCODING> if you want more precise
info about what is returned in $data and $descriptors.


Print the content of a subset in BUFR message:

  print $bufr->dumpsections($data,$descriptors,$options);

$options is optional. If this is first subset in message, will start
by printing message number and, if this is first message in a WMO
bulletin, WMO ahl (abbreviated header line), as well as content of
sections 0, 1 and 3. For section 4, will also print subset
number. $options should be an anonymous hash with possible keys
'width' and 'bitmap', e.g. { width => 20, bitmap => 0 }. 'bitmap'
controls which of C<dumpsection4> and C<dumpsection4_with_bitmaps>
will be called internally by C<dumpsections>. Default value for
'bitmap' is 1, causing C<dumpsection4_with_bitmaps> to be
called. 'width' controls the value of $width used by the
C<dumpsection4...> methods, default is 15. If you intend to provide
the output from C<dumpsections> as input to C<reencode_message>, be
sure to set 'bitmap' to 0, and 'width' not smaller than the largest
data width in bytes among the descriptors with unit CCITTIA5 occuring
in the message.

Normally C<dumpsections> is called after C<next_observation>, with
same arguments $data,$descriptors as returned from this call. From the
examples given at L<https://wiki.met.no/bufr.pm/start#bufrreadpl> you
can get an impression of what the output might look like. If
C<dumpsections> does not give you exactly what you want, you might
prefer to instead call the individual dumpsection methods below.

Print the contents of sections 0-3 in BUFR message:

  print $bufr->dumpsection0();
  print $bufr->dumpsection1();
  print $bufr->dumpsection2($sec2_code_ref);
  print $bufr->dumpsection3();

C<dumpsection2> returns an empty string if there is no optional
section in the message. The argument should be a reference to a
subroutine which takes the optional section as (a string) argument and
returns the text you want displayed after the 'Length of section:'
line. For general BUFR messages probably the best you can do is
displaying a hex dump, in which case

  sub {return '    Hex dump:' . ' 'x26 . unpack('H*',substr(shift,4))}

might be a suitable choice for $sec2_code_ref. For most applications
there should be no real need to call C<dumpsection2>.

Print the data of a subset (descriptor, value, name and unit):

  print $bufr->dumpsection4($data,$descriptors,$width);
  print $bufr->dumpsection4_with_bitmaps($data,$descriptors,$width);

$width fixes the number of characters used for displaying the data
values, and is optional (defaults to 15). $data and $descriptors are
references to arrays of data values and BUFR descriptors respectively,
likely to have been fetched from C<next_observation>. Code and flag
values will be resolved if a C table has been loaded, i.e. if
C<load_Ctable> has been called earlier. C<dumpsection4_with_bitmaps>
will display the bit-mapped values side by side with the corresponding
data values. If there is no bit-map in the BUFR message,
C<dumpsection4_with_bitmaps> will provide same output as
C<dumpsection4>. See L</DECODING/ENCODING> for some more information
about what is printed, and
L<https://wiki.met.no/bufr.pm/start#bufrreadpl> for real life examples
of output.

Set verbose level:

  Geo::BUFR->set_verbose($level); # 0 <= $level <= 5
  $bufr->set_verbose($level);

Some info about what is going on in Geo::BUFR will be printed to
STDOUT if $level > 0. With $level set to 1, all that is printed is the
B, C and D tables used (with full path).

No decoding of quality information:

  Geo::BUFR->set_noqc($n);
 - $n=1 (or not provided): Don't decode quality information (more
   specifically: skip all descriptors after 222000)
 - $n=0: Decode quality information (default in Geo::BUFR)

Enable/disable strict checking of BUFR format for recoverable errors
(like using BUFR compression for one subset message etc):

  Geo::BUFR->set_strict_checking($n);
 - $n=0: disable checking (default in Geo::BUFR)
 - $n=1: warn (carp) if error but continue decoding
 - $n=2: die (croak) if error

Confer L</STRICT CHECKING> for details of what is being checked if
strict checking is enabled.

Show all BUFR table C operators (data description operators) when
calling dumpsection4:

  Geo::BUFR->set_show_all_operators($n);
 - $n=1 (or not provided): Show all operators
 - $n=0: Show only the really informative ones (default in Geo::BUFR)

C<set_show_all_operators(1)> cannot be combined with C<dumpsections>
with bitmap option set (which is the default).

Set or get tablepath:

  Geo::BUFR->set_tablepath($tablepath);
  $tablepath = Geo::BUFR->get_tablepath();

Get table version:

  $table_version = $bufr->get_table_version($table);

$table is optional. If for example $table =
'B0000000000088013001.TXT', will return '0000000000088013001'. In the
more interesting case where $table is not provided, will return table
version from BUFR section 1 information in the $bufr object.

Get number of subsets:

  $nsubsets = $bufr->get_number_of_subsets();

Get current subset number:

  $subset_no = $bufr->get_current_subset_number();

Get current message number:

  $message_no = $bufr->get_current_message_number();

Get last WMO abbreviated header line (ahl) before current message
(undef if not present):

  $message_ahl = $bufr->get_current_ahl();


Accessor methods for section 0-3:

  $bufr->set_<variable>($variable);
  $variable = $bufr->get_<variable>();

where <variable> is one of

  bufr_edition
  master_table
  subcentre
  centre
  update_sequence_number
  optional_section (0 or 1)
  data_category
  int_data_subcategory
  loc_data_subcategory
  data_subcategory
  master_table_version
  local_table_version
  year_of_century
  year
  month
  day
  hour
  minute
  second
  local_use
  number_of_subsets
  observed_data (0 or 1)
  compressed_data (0 or 1)
  descriptors_unexpanded

C<set_year_of_century(0)> will set year of century to 100.
C<get_year_of_century> will for BUFR edition 4 calculate year of
century from year in section 1.


Encode a new BUFR message:

  $new_message = $bufr->encode_message($data_refs,$desc_refs);

where $desc_refs->[$i] is a reference to the array of fully expanded
descriptors for subset number $i ($i=1 for first subset),
$data_refs->[$i] is a reference to the corresponding values, using
undef for missing values. The required metadata in section 0, 1 and 3
must have been set in $bufr before calling this method. See
L</DECODING/ENCODING> for meaning of 'fully expanded descriptors'.

Encode a NIL message:

  $new_message = $bufr->encode_nil_message($stationid_ref,$delayed_repl_ref);

$delayed_repl_ref is optional. In section 4 all values will be set to
missing except delayed replication factors and the (descriptor, value)
pairs in the hashref $stationid_ref. $delayed_repl_ref (if provided)
should be a reference to an array of data values for all descriptors
031001 and 031002 occuring in the message (these values must all be
nonzero), e.g. [3,1,2] if there are 3 such descriptors which should
have values 3, 1 and 2, in that succession. If $delayed_repl_ref is
omitted, all delayed replication factors will be set to 1. The
required metadata in section 0, 1 and 3 must have been set in $bufr
before calling this method.

Reencode BUFR message(s):

  $new_messages = $bufr->reencode_message($decoded_messages,$width);

$width is optional. Takes a text $decoded_messages as argument and
returns a (binary) string of BUFR messages which, when printed to file
and then processed by C<bufrread.pl> with no output modifying options set
(except possibly C<--width>), would give output equal to
$decoded_messages. If C<bufrread.pl> is to be called with C<--width
$width>, this $width must be provided to C<reencode_message> also.

Join subsets from several messages:

 ($data_refs,$desc_refs,$nsub) = Geo::BUFR->join_subsets($bufr_1,$subset_ref_1,
     ... $bufr_n,$subset_ref_n);

where each $subset_ref_i is optional. Will return the data and
descriptors needed by C<encode_message> to encode a multi subset
message, extracting the subsets from the first message of each $bufr_i
object. All subsets in (first message of) $bufr_i will be used, unless
next argument is an array reference $subset_ref_i, in which case only
the subset numbers listed will be included. On return $nsub will contain
the total number of subsets thus extracted. After a call to
C<join_subsets>, the metadata (of the first message) in each object
will be available through the C<get_>-methods, while a call to
C<next_observation> will start extracting the first subset in the
first message. Here is an example of use, fetching first subset from
bufr object 1, all subsets from bufr object 2, and subset 1 and 4 from
bufr object 3, then building up a new multi subset BUFR message (which
will succeed only if the bufr objects all have the same descriptors in
section 3):

  my ($data_refs,$desc_refs,$nsub) = Geo::BUFR->join_subsets($bufr1,
      [1],$bufr2,$bufr3,[1,4]);
  my $new_bufr = Geo::BUFR->new();
  # Get metadata from one of the objects, then reset those metadata
  # which might not be correct for the new message
  $new_bufr->copy_from($bufr1,'metadata');
  $new_bufr->set_number_of_subsets($nsub);
  $new_bufr->set_update_sequence_number(0);
  $new_bufr->set_compressed_data(0);
  my $new_message = $new_bufr->encode_message($data_refs,$desc_refs);

Extract BUFR table B information for an element descriptor:

  ($name,$unit,$scale,$refval,$width) = $bufr->element_descriptor($desc);

Will fetch name, unit, scale, reference value and data width in bits
for element descriptor $desc in the last table B loaded in the $bufr
object. Returns false if the descriptor is not found.

Extract BUFR table D information for a sequence descriptor:

  @descriptors = $bufr->sequence_descriptor($desc);
  $string = $bufr->sequence_descriptor($desc);

Will return the descriptors in a direct (nonrecursive) lookup for the
sequence descriptor $desc in the last table D loaded in the $bufr
object. In scalar context the descriptors will be returned as a space
separated string. Returns false if the descriptor is not found.

Resolve BUFR table descriptors (for printing):

  print $bufr->resolve_descriptor($how,@descriptors);

where $how is one of 'fully', 'partially', 'simply' and 'noexpand'.
Returns a text string suitable for printing information about the BUFR
table descriptors given. $how = 'fully': Expand all D descriptors
fully into B descriptors, with name, unit, scale, reference value and
width (each on a numbered line, except for replication operators which
are not numbered). $how = 'partially': Like 'fully', but expand D
descriptors only once and ignore replication. $how = 'noexpand': Like
'partially', but do not expand D descriptors at all. $how = 'simply':
Like 'partially', but list the descriptors on one single line with no
extra information provided. The relevant B/D table must have been
loaded before calling C<resolve_descriptor>.

Resolve flag table value (for printing):

  print $bufr->resolve_flagvalue($value,$flag_table,$B_table,
                                 $default_B_table,$num_leading_spaces);

Last 2 arguments are optional. $default_B_table will be used if
$B_table is not found, $num_leading_spaces defaults to 0.
Example:

  print $bufr->resolve_flagvalue(4,8006,'B0000000000098013001.TXT')

Print the content of BUFR code (or flag) table:

  print $bufr->dump_codetable($code_table,$table,$default_table);

where $table is (base)name of the C...TXT file containing the code
tables, optionally followed by a default table which will be used if
$table is not found.

C<resolve_flagvalue> and <C<dump_codetable> will return empty string if
flag value or code table is not found.


Manipulate binary data (these are implemented in C for speed and primarily
intended as module internal subroutines):

  $value = Geo::BUFR->bitstream2dec($bitstream,$bitpos,$num_bits);

Extracts $num_bits bits from $bitstream, starting at bit $bitpos. The
extracted bits are interpreted as a non negative integer.  Returns
undef if all bits extracted are 1 bits.

  $ascii = Geo::BUFR->bitstream2ascii($bitstream,$bitpos,$num_bytes);

Extracts $num_bytes bytes from bitstream, starting at $bitpos, and
interprets the extracted bytes as an ascii string. Returns undef if
the extracted bytes are all 1 bits.

  Geo::BUFR->dec2bitstream($value,$bitstream,$bitpos,$bitlen);

Encodes non-negative integer value $value in $bitlen bits in
$bitstream, starting at bit $bitpos. Last byte will be padded with 1
bits. $bitstream must have been initialized to a string long enough to
hold $value. The parts of $bitstream before $bitpos and after last
encoded byte are not altered.

  Geo::BUFR->ascii2bitstream($ascii,$bitstream,$bitpos,$width);

Encodes ASCII string $ascii in $width bytes in $bitstream, starting at
$bitpos. Last byte will be padded with 1 bits. $bitstream must have
been initialized to a string long enough to hold $ascii. The parts of
$bitstream before $bitpos and after last encoded byte are not altered.

  Geo::BUFR->null2bitstream($bitstream,$bitpos,$num_bits);

Sets $num_bits bits in bitstream starting at bit $bitpos to 0 bits.
Last byte affected will be padded with 1 bits. $bitstream must be at
least $bitpos + $num_bits bits long. The parts of $bitstream before
$bitpos and after last encoded byte are not altered.

=head1 DECODING/ENCODING

The term 'fully expanded descriptors' used in the description of
C<encode_message> (and C<next_observation>) in L</METHODS> might need
some clarification. The short version is that the list of descriptors
should be exactly those which will be written out by running
C<dumpsection4> (or C<bufrread.pl> without any modifying options set) on
the encoded message. If you don't have a similar BUFR message at hand
to use as an example when wanting to encode a new message, you might
need a more specific prescription. Which is that for every data value
which occurs in the section 4 bitstream, you should include the
corresponding BUFR descriptor, using the artificial 999999 for
associated fields following the 204Y operator, I<and> including the
data operator descriptors 22[2345]000 and 23[2567]000 with data value
set to the empty string, if these occurs among the descriptors in
section 3 (rather: in the expansion of these, use C<bufrresolve.pl> to
check!). Element descriptors defining new reference values (following
the 203Y operator) will have f=0 (first digit in descriptor) replaced
with f=9 in C<next_observation>, while in C<encode_message> both f=0
and f=9 will be accepted for new reference values.

Some words about the procedure used for decoding and encoding data in
section 4 might shed some light on this choice of design.

When decoding section 4 for a subset, first of all the BUFR
descriptors provided in section 3 are expanded as far as is possible
without looking at the actual bitstream, i.e. by eliminating
nondelayed replication descriptors (f=1) and by using BUFR table D to
expand sequence descriptors (f=3). Then, for each of the thus expanded
descriptors, the data value is fetched from the bitstream according to
the prescriptions in BUFR table B, applying the data operator
descriptors (f=2) from BUFR table C as they are encountered, and
reexpanding the remaining descriptors every time a delayed replication
factor is fetched from bitstream. The resulting set of data values is
returned in an array @data, with the corresponding B (and sometimes
also some C) BUFR table descriptors in an array
@descriptors. C<next_observation> returns references to these two
arrays. For convenience, some of the data operator descriptors without
a corresponding data value (like 222000) are included in the
@descriptors because they are considered to provide valuable
information to the user, with corresponding value in @data set to the
empty string. These descriptors without a value are written by the
dumpsection4 methods on unnumbered lines, thereby distinguishing them
from descriptors corresponding to 'real' data values in section 4,
which are numbered consecutively.

Encoding a subset is done in a very similar way, by expanding the
descriptors in section 3 as described above, but instead fetching the
data values from the @data array that the user supplies (actually
@{$data_refs->{$i}} where $i is subset number), and then finally
encoding this value to bitstream.

The input parameter $desc_ref to C<encode_message> is in fact not
strictly necessary to be able to encode a new BUFR message. But there
is a good reason for requiring it. During encoding the descriptors
from expanding section 3 will consecutively be compared with the
descriptors in the user supplied $desc_ref, and if these at some point
differs, encoding will be aborted with an error message stating the
first descriptor which deviated from the expected one. By requiring
$desc_ref as input, the risk for encoding an erronous section 4 is
thus greatly reduced, and also provides the user with highly valuable
debugging information if encoding fails.

Note that for character data (unit CCITTIA5) FM 94 BUFR does not
provide any guidelines for how to encode strings which are shorter
than the data width. In Geo::BUFR the following procedure is followed:
When encoding, the requested string is right padded with blanks. When
decoding, any trailing null characters are silently removed, as well
as leading and trailing white space.

=head1 BUFR TABLE FILES

The BUFR table files should follow the format and naming conventions
used by ECMWF libbufr software (download from
http://www.ecmwf.int/products/data/software/download/bufr.html, unpack
and you will find table files in the bufrtable directory). Other table
file formats exist and might on request be supported in future
versions of Geo::BUFR.

=head1 STRICT CHECKING

The package global $Strict_checking defaults to

  0: Ignore recoverable errors in BUFR format met during decoding or encoding

but can be changed to

  1: Issue warning (carp) but continue decoding/encoding

  2: Croak (die) instead of carp

by calling C<set_strict_checking>. The following is checked for when
$Strict_checking is set to 1 or 2:

=over

=item *

Compression set in section 1 for one subset message (BUFR reg. 94.6.3.2)

=item *

Local reference value for compressed character data not having all bits set to zero (94.6.3.2.i)

=item *

Excessive bytes in section 4 (section longer than computed from section 3)

=item *

Illegal flag values (rightmost bit set for non-missing values)

=item *

Cancellation operators (20[1-4]00, 203255 etc) when there is nothing to cancel

=item *

Invalid date and/or time in section 1

=back

Plus some few more checks not considered interesting enough to be
mentioned here.

To the above list I would have liked to add

=over

=item *

Trailing null characters in CCITTIA5 data

=back

but for the reason given at the end of the C<DECODING/ENCODING>
section, I have restrained from that. If you want to see what
character data was originally encoded (including nulls and blanks) in
a BUFR file, use C<bufrread.pl> with option C<--verbose 5>.

=begin more_on_strict_checking

These are:
- Replication of 0 descriptors (f=1, x=0)
- year_of_century > 100

=end more_on_strict_checking

=head1 BUGS OR MISSING FEATURES

Some BUFR table C operators are not implemented or are untested,
mainly because I do not have access to BUFR messages containing such
operators. If you happen to come over a BUFR message which the current
module fails to decode properly, I would therefore highly appreciate
if you could mail me this.

=head1 AUTHOR

Pål Sannes E<lt>pal.sannes@met.noE<gt>

=head1 CREDITS

I am very grateful to Alvin Brattli, who (while employed as a
researcher at met.no) wrote the first version of this module, with the
sole purpose of being able to decode some very specific BUFR satellite
data, but still provided the main framework upon which this module is
built.

=head1 SEE ALSO

Guide to WMO Table Driven Code Forms: FM 94 BUFR and FM 95 CREX; Layer 3:
Detailed Description of the Code Forms (for programmers of encoder/decoder
software)

L<https://wiki.met.no/bufr.pm/start>

=head1 COPYRIGHT

Copyright (C) 2010 met.no

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
