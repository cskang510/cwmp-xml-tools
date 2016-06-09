#!/usr/bin/perl -w
#
# Copyright (C) 2011, 2012  Pace Plc
# Copyright (C) 2012, 2013, 2014  Cisco Systems
# Copyright (C) 2016  Honu Ltd
# All Rights Reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# - Redistributions of source code must retain the above copyright notice,
#   this list of conditions and the following disclaimer.
# - Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
# - Neither the names of the copyright holders nor the names of their
#   contributors may be used to endorse or promote products derived from this
#   software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# Parses MIB XML, conformant to http://www.ibr.cs.tu-bs.de/projects/nmrg/
# smi.xsd and generates XML output compliant with the CWMP data model XML
# Schema.  Each object is a component.

# XXX can this be a lot simpler? don't need to build a node tree; can just do
#     xpath expressions to extract what we are interested in

# XXX need to have a proper way of handling versions for the main and included
#     MIBs

# XXX need to include references, history etc; in general, check that all
#     relevant information is copied, and consider cwmp-datamodel extensions,
#     e.g. more textual conventions or direct representation of references

# XXX also (can't really do anything about it) there can be SNMP-specific
#     language in the descriptions...

# XXX need to think about further operations to perform, e.g. prefix removal
#     and more sophisticated name mapping (have only really tried to do this
#     for enumerated values)

# XXX ranges in typedefs aren't handled as multi-valued; mins and maxes are
#     concatenated, e.g. for DateAndTime

# XXX check for appropriateness of all ucfirst calls

# Begin documentation
=head1 NAME

mib2dm.pl - convert MIB XML to BBF DM Instances

=head1 SYNOPSIS

B<mib2dm.pl>
[--components]
[--noobjects]
[--noparameters]
[--pedantic[=i(1)]]
[--verbose]
[--help]
MIB-XML-file...

=over

=item * MIB XML must conform to
        http://www.ibr.cs.tu-bs.de/projects/nmrg/smi.xsd; the B<smidump> tool
        can be used to convert ASN.1 MIBs to such XML

=item * the most common option is --components

=back

=item B<--components>

causes components to be created (a) for top-level parameters (scalars) and (b) for each table; the generated data model then references these components

the component containing the top-level parameters has the same name as the MIB's first node, and the components containing table definitions are names the same as their tables

=item B<--noobjects>

suppresses generation of all objects, so the generated data model is flat and consists only of parameter definitions

=item B<--noparameters>

suppresses generation of all parameters (apart from NumberOfEntries parameters), so the generated data model is flat and consists only of object definitions

=item B<--pedantic[=i(1)]>

enables output of warnings to I<stderr> when logical inconsistencies in the XML are detected; if the option is specified without a value, the value defaults to 1

=item B<--verbose>

enables verbose output

=item B<--help>

requests output of usage information

=cut
# End documentation

use strict;
no strict "refs";

use Data::Dumper;
use File::Basename;
use Getopt::Long;
use Pod::Usage;
use XML::LibXML;

# cwmp-datamodel schema version
my $schema_version = "1-5";

# command-line options
my $components = 0;
my $help = 0;
my $namemangle = 0;
my $noobjects = 0;
my $nooutput = 0;
my $noparameters = 0;
my $pedantic;
my $verbose = 0;
GetOptions('components' => \$components,
	   'help' => \$help,
	   'namemangle' => \$namemangle,
	   'noobjects' => \$noobjects,
	   'nooutput' => \$nooutput,
	   'noparameters' => \$noparameters,
	   'pedantic:i' => \$pedantic,
	   'verbose' => \$verbose) or pod2usage(2);
pod2usage(1) if $help;

$pedantic = 1 if defined($pedantic) and !$pedantic;
$pedantic = 0 unless defined($pedantic);

# globals
my $root = {};

# pattern that matches TR-069 primitive types
my $primitive_patt = '(^base64|boolean|byte|dateTime|hexBinary|int|long|string|unsignedByte|unsignedInt|unsignedLong)$';

# well-known primitive type names will be mapped to TR-069 types
# XXX need to be careful to keep this list short and uncontroversial;
#     these are the four RFC 1155 primitive types plus Enumeration, plus...
# XXX Integer64, Unsigned32 and Unsigned64
# XXX OctetString should sometimes be string, as a function of format?
my $primitive_map = {
    Bits => 'string',
    Enumeration => 'string',
    Integer => 'int',
    Integer32 => 'int',
    Integer64 => 'long',
    MacAddress => 'MACAddress',
    Null => 'int',
    ObjectIdentifier => 'string',
    OctetString => 'hexBinary',
    TruthValue => 'boolean',
    Unsigned32 => 'unsignedInt',
    Unsigned64 => 'unsignedLong',
};

# XXX these additional entries need to be controlled by config and tied to
#     the import of TR-069 data types
$primitive_map->{MacAddress} = 'MACAddress';
$primitive_map->{Counter32} = 'StatsCounter32';
$primitive_map->{Counter64} = 'StatsCounter64';

# this works with the above and indicates which SMI types should be lists
my $list_map = {
    Bits => 1
};

# this maps SNMP object names to the corresponding object in the parse tree
my $tree_node = {};

# this maps SNMP object names to the corresponding TR-069 DM object info
# XXX ideally wouldn't need to pre-populate; this saves parsing other files
# XXX it's populated very inefficiently...
my $dm_object_info = {
    ifIndex => {model => 'Interfaces_Model:1.0',
                path => 'ifTable.{i}.',
                access => 'readOnly',
                minEntries => '0',
                maxEntries => 'unbounded',
    }
};

# parse files specified on the command line
# XXX various things don't work if there is more than one file, so should 
#     forbid this
foreach my $file (@ARGV) {
    parse_file($file);
}

# transform names
transform_names();

# output XML
output_xml();

# that's the end of the main program; all the rest is subroutines

# parse a MIB XML file
sub parse_file
{
    my ($file)= @_;

    print STDERR "processing file: $file\n" if $verbose;

    # parse file
    my $parser = XML::LibXML->new();
    my $tree = $parser->parse_file($file);
    my $toplevel = $tree->getDocumentElement;

    foreach my $thing ($toplevel->findnodes('*')) {
	my $element = findvalue($thing, 'local-name()');
	"expand_$element"->($thing);
    }

    # XXX this assumes that the output file will be named based on the input
    #     file; should add an --outfile option
    # XXX it also assumes that only one command line argument is supplied
    (my $vol, my $dir, $file) = File::Spec->splitpath($file);
    ($file, my $dirs, my $suff) = fileparse($file, '.xsm');
    $root->{file} = qq{$file.xml} unless $root->{file};
}

# expand module
sub expand_module
{
    my ($module) = @_;

    my $name = findvalue($module, '@name');
    my $language = findvalue($module, '@language');
    my $organization = findvalue($module, 'organization');
    my $contact = findvalue($module, 'contact');
    my $description = findvalue($module, 'description', {descr => 1});
    my $reference = findvalue($module, 'reference', {descr => 1});
    my $identity_node = findvalue($module, 'identity/@node');

    print STDERR "expand_module name=$name organization=$organization\n"
	if $verbose;

    # XXX root is all rather ad hoc...
    $root->{module} = $name;

    my $revisions = [];
    foreach my $revision ($module->findnodes('revision')) {
	push @$revisions, expand_revision($revision);
    }

    # try to derive meaningful spec from name, organization and latest
    # (lexically first) revision date
    # XXX there are various heuristics...

    # these are gen-delims and sub-delims from RFC 3986 (plus double quote,
    # which is omitted, maybe because single and double quote are elsewhere
    # stated to be equivalent)
    my $delims = qr{[\:\/\?\#\[\]\@\$\&\'\"\(\)\*\+\,\;\=]+};

    $name = lc $name;
    $name =~ s/_/-/g;
    $name =~ s/\s+/-/g;
    $name =~ s/\.//g;
    $name =~ s/$delims//g;

    $organization = lc $organization;
    $organization =~ s/.*\bcable television laboratories\b.*/cablelabs-org/;
    $organization =~ s/.*\bcablelabs\b.*/cablelabs-org/;
    $organization =~ s/.*\bieee\b.*/ieee-org/;
    $organization =~ s/.*\bietf\b.*/ietf-org/;
    $organization =~ s/.*\bmultimedia over coax\b.*/mocalliance-org/;
    $organization =~ s/_/-/g;
    $organization =~ s/\s+/-/g;
    $organization =~ s/\.//g;
    $organization =~ s/$delims//g;

    my $date = $revisions->[0]->{date};
    $date = '' unless $date;
    $date =~ s/\s.*// if $date;
    $date = qq{-$date} if $date;

    $root->{spec} = "urn:$organization:$name$date";
}

# expand revision
sub expand_revision
{
   my ($revision) = @_;

   my $date = findvalue($revision, '@date');
   my $description = findvalue($revision, 'description', {descr => 1});

   print STDERR "expand_revision date=$date\n" if $verbose;

   return {date => $date, description => $description};
}

# expand imports
sub expand_imports
{
    my ($imports) = @_;

    print STDERR "expand_imports\n" if $verbose;

    foreach my $import ($imports->findnodes('import')) {
	push @{$root->{imports}}, expand_import($import);
    }
}

# expand import
sub expand_import
{
    my ($import) = @_;

    my ($module, $name) = get_module_and_name($import);

    print STDERR "expand_import module=$module name=$name\n" if $verbose;

    return {module => $module, name => $name};
}

# expand typedefs
sub expand_typedefs
{
    my ($typedefs) = @_;

    print STDERR "expand_typedefs\n" if $verbose;

    foreach my $typedef ($typedefs->findnodes('typedef')) {
        push @{$root->{typedefs}}, expand_typedef($typedef);
    }
}

# expand typedef
sub expand_typedef
{
    my ($typedef) = @_;

    my $name = findvalue($typedef, '@name');
    my $basetype = findvalue($typedef, '@basetype');
    my $status = findvalue($typedef, '@status');
    my $default = findvalue($typedef, 'default');
    my $format = findvalue($typedef, 'format');
    my $units = findvalue($typedef, 'units');
    my $description = findvalue($typedef, 'description', {descr => 1});
    my $reference = findvalue($typedef, 'reference', {descr => 1});

    $status = 'current' unless $status;

    print STDERR "expand_typedef name=$name basetype=$basetype " .
	"status=$status format=$format\n" if $verbose;

    my $hash = {};
    $hash->{name} = $name if $name;
    $hash->{basetype} = $basetype if $basetype;
    $hash->{status} = $status if $status;
    $hash->{default} = $default if $default;
    $hash->{format} = $format if $format;
    $hash->{units} = $units if $units;
    $hash->{description} = $description if $description;
    $hash->{reference} = $reference if $reference;

    foreach my $thing ($typedef->findnodes('parent|range|namednumber')) {
	my $element = findvalue($thing, 'local-name()');
	push @{$hash->{$element}}, "expand_$element"->($thing);
    }

    # this avoids a special case in the above loop
    $hash->{parent} = $hash->{parent}->[0] if $hash->{parent};
 
    return $hash;
}

# expand parent
sub expand_parent
{
    my ($parent) = @_;

    my ($module, $name) = get_module_and_name($parent);

    print STDERR "expand_parent module=$module name=$name\n" if $verbose;

    return {module => $module, name => $name};
}

# expand range
sub expand_range
{
    my ($range) = @_;

    my $min = findvalue($range, '@min');
    my $max = findvalue($range, '@max');

    print STDERR "expand_range min=$min max=$max\n" if $verbose;

    return {min => $min, max => $max};
}

# expand namednumber
sub expand_namednumber
{
    my ($namednumber) = @_;

    my $name = findvalue($namednumber, '@name');
    my $number = findvalue($namednumber, '@number');

    print STDERR "expand_namednumber name=$name number=$number\n" if $verbose;

    return {name => $name, number => $number};
}

# expand nodes
sub expand_nodes
{
    my ($nodes) = @_;

    print STDERR "expand_nodes\n" if $verbose;

    foreach my $thing ($nodes->findnodes('node|scalar|table')) {
	my $element = findvalue($thing, 'local-name()');
	"expand_$element"->($thing);
    }
}

# expand node
sub expand_node
{
    my ($node) = @_;

    my ($name, $oid, $status) = get_name_oid_and_status($node);
    my $description = findvalue($node, 'description', {descr => 1});

    print STDERR "expand_node name=$name status=$status\n" if $verbose;

    # XXX currently ignore nodes except that note the name of the first one
    #     for use as the the component name for the scalars
    $root->{name} = $name unless $root->{name};
}

# expand scalar
sub expand_scalar
{
    my ($scalar) = @_;

    my ($name, $oid, $status) = get_name_oid_and_status($scalar);
    my $syntax = expand_syntax($scalar->findnodes('syntax'));
    my $access = findvalue($scalar, 'access');
    my $default = findvalue($scalar, 'default');
    my $format = findvalue($scalar, 'format');
    my $units = findvalue($scalar, 'units');
    my $description = findvalue($scalar, 'description',
				{descr => 1, values => $syntax->{values}});
    my $reference = findvalue($scalar, 'reference', {descr => 1});

    print STDERR "expand_scalar name=$name status=$status\n" if $verbose;

    my $snode = {
	name => $name,
        oid => $oid,
	syntax => $syntax,
	status => $status,
	access => $access,
	default => $default,
	units => $units,
	description => $description,
        reference => $reference,
    };
    push @{$root->{scalars}}, $snode;
    $tree_node->{$name} = $snode;
}

# expand syntax
sub expand_syntax
{
    my ($syntax) = @_;

    print STDERR "expand_syntax\n" if $verbose;

    foreach my $thing ($syntax->findnodes('type|typedef')) {
	my $element = findvalue($thing, 'local-name()');
	return convert_syntax("expand_$element"->($thing));
    }
}

# expand type
sub expand_type
{
    my ($type) = @_;

    my ($module, $name) = get_module_and_name($type);

    print STDERR "expand_type module=$module name=$name\n" if $verbose;

    return {module => $module, name => $name};
}

# expand table
sub expand_table
{
    my ($table) = @_;

    my ($name, $oid, $status) = get_name_oid_and_status($table);
    my $description = findvalue($table, 'description', {descr => 1});
    my $reference = findvalue($table, 'reference', {descr => 1});

    print STDERR "expand_table name=$name status=$status\n" if $verbose;

    my $tnode = {
	name => $name,
        oid => $oid,
	status => $status,
	description => $description,
        reference => $reference,
	row => {},
    };
    push @{$root->{tables}}, $tnode;
    $tree_node->{$name} = $tnode;

    expand_row($tnode, $table->findnodes('row'));
}

# expand row
sub expand_row
{
    my ($tnode, $row) = @_;

    my ($name, $oid, $status) = get_name_oid_and_status($row);
    my $create = findvalue($row, '@create', {boolean => 1});
    my $linkage = expand_linkage($row->findnodes('linkage'));
    my $description = findvalue($row, 'description', {descr => 1});
    my $reference = findvalue($row, 'reference', {descr => 1});

    print STDERR "expand_row name=$name create=$create status=$status\n"
	if $verbose;

    my $rnode = $tnode->{row} = {
	name => $name,
        oid => $oid,
	status => $status,
	create => $create,
	linkage => $linkage,
	description => $description,
        reference => $reference,
	columns => [],
    };
    $tree_node->{$name} = $rnode;

    foreach my $column ($row->findnodes('column')) {
	expand_column($rnode, $column);
    }
}

# expand linkage
sub expand_linkage
{
    my ($linkage) = @_;

    my $implied = findvalue($linkage, '@implied', {boolean => 1});

    print STDERR "expand_linkage implied=$implied\n" if $verbose;

    my $hash = {};
    $hash->{implied} = $implied if $implied;

    # XXX ignoring reorders, sparse and expands
    foreach my $thing ($linkage->findnodes('index|augments')) {
	my $element = findvalue($thing, 'local-name()');
	push @{$hash->{$element}}, "expand_$element"->($thing);
    }

    # this avoids a special case in the above loop
    $hash->{augments} = $hash->{augments}->[0] if $hash->{augments};

    return $hash;
}

# expand index
sub expand_index
{
    my ($index) = @_;

    my ($module, $name) = get_module_and_name($index);

    print STDERR "expand_index module=$module name=$name\n" if $verbose;

    return {module => $module, name => $name};
}

# expand augments
sub expand_augments
{
    my ($augments) = @_;

    my ($module, $name) = get_module_and_name($augments);

    print STDERR "expand_augments module=$module name=$name\n" if $verbose;

    return {module => $module, name => $name};
}

# expand column
sub expand_column
{
    my ($rnode, $column) = @_;

    my ($name, $oid, $status) = get_name_oid_and_status($column);
    my $syntax = expand_syntax($column->findnodes('syntax'));
    my $access = findvalue($column, 'access');
    my $default = findvalue($column, 'default');
    my $format = findvalue($column, 'format');
    my $units = findvalue($column, 'units');
    my $description = findvalue($column, 'description',
				{descr => 1, values => $syntax->{values}});
    my $reference = findvalue($column, 'reference', {descr => 1});

    print STDERR "expand_column name=$name status=$status access=$access\n"
	if $verbose;

    my $cnode = {
	name => $name,
        oid => $oid,
	syntax => $syntax,
	status => $status,
	access => $access,
	default => $default,
	units => $units,
	description => $description,
        reference => $reference,
    };
    push @{$rnode->{columns}}, $cnode;
    $tree_node->{$name} = $cnode;
}

# expand notifications
sub expand_notifications
{
    my ($notifications) = @_;

    print STDERR "expand_notifications\n" if $verbose;

    foreach my $notification ($notifications->findnodes('notification')) {
	push @{$root->{notifications}}, expand_notification($notification);
    }
}

# expand notification
sub expand_notification
{
    my ($notification) = @_;

    my ($name, $oid, $status) = get_name_oid_and_status($notification);
    my $description = findvalue($notification, 'description', { descr => 1});
    my $reference = findvalue($notification, 'reference', {descr => 1});

    print STDERR "expand_notification name=$name status=$status\n" if $verbose;

    my $hash = {};
    $hash->{name} = $name if $name;
    $hash->{oid} = $oid if $oid;
    $hash->{status} = $status if $status;
    $hash->{description} = $description if $description;
    $hash->{reference} = $reference if $reference;

    $hash->{objects} = expand_objects($notification->findnodes('objects'));
    $tree_node->{$name} = $hash;

    return $hash;
}

# expand objects
sub expand_objects
{
    my ($objects) = @_;

    print STDERR "expand_objects\n" if $verbose;

    my $array = [];
    foreach my $object ($objects->findnodes('object')) {
	push @$array, expand_object($object);
    }

    return $array;
}

# expand object
sub expand_object
{
    my ($object) = @_;

    my ($module, $name) = get_module_and_name($object);

    print STDERR "expand_object module=$module name=$name\n" if $verbose;

    return {module => $module, name => $name};
}

# expand groups
sub expand_groups
{
    my ($groups) = @_;

    print STDERR "expand_groups\n" if $verbose;

    foreach my $group ($groups->findnodes('group')) {
	push @{$root->{groups}}, expand_group($group);
    }
}

# expand group
sub expand_group
{
    my ($group) = @_;

    my ($name, $oid, $status) = get_name_oid_and_status($group);
    my $description = findvalue($group, 'description', {descr => 1});
    my $reference = findvalue($group, 'reference', {descr => 1});

    print STDERR "expand_group name=$name status=$status\n" if $verbose;

    my $hash = {};
    $hash->{name} = $name if $name;
    $hash->{oid} = $oid if $oid;
    $hash->{status} = $status if $status;
    $hash->{description} = $description if $description;
    $hash->{reference} = $reference if $reference;

    $hash->{members} = expand_members($group->findnodes('members'));
    $tree_node->{$name} = $hash;

    return $hash;
}

# expand members
sub expand_members
{
    my ($members) = @_;

    print STDERR "expand_members\n" if $verbose;

    my $array = [];
    foreach my $member ($members->findnodes('member')) {
	push @$array, expand_member($member);
    }

    return $array;
}

# expand member
sub expand_member
{
    my ($member) = @_;

    my ($module, $name) = get_module_and_name($member);

    print STDERR "expand_member module=$module name=$name\n" if $verbose;
    
    return {module => $module, name => $name};
}

# expand compliances
sub expand_compliances
{
    my ($compliances) = @_;

    print STDERR "expand_compliances\n" if $verbose;

    foreach my $compliance ($compliances->findnodes('compliance')) {
	push @{$root->{compliances}}, expand_compliance($compliance);
    }
}

# expand compliance
sub expand_compliance
{
    my ($compliance) = @_;

    my ($name, $oid, $status) = get_name_oid_and_status($compliance);
    my $description = findvalue($compliance, 'description', {descr => 1});

    print STDERR "expand_compliance name=$name status=$status\n" if $verbose;

    my $hash = {};
    $hash->{name} = $name if $name;
    $hash->{oid} = $oid if $oid;
    $hash->{status} = $status if $status;    
    $hash->{description} = $description if $description;    
    
    foreach my $thing ($compliance->findnodes('requires|refinements')) {
	my $element = findvalue($thing, 'local-name()');
	push @{$hash->{$element}}, "expand_$element"->($thing);
    }

    # this avoids a special case in the above loop
    $hash->{refinements} = $hash->{refinements}->[0] if $hash->{refinements};
    $tree_node->{$name} = $hash;

    return $hash;
}

# expand requires
sub expand_requires
{
    my ($requires) = @_;

    print STDERR "expand_requires\n" if $verbose;

    my $hash = {};
    foreach my $thing ($requires->findnodes('mandatory|option')) {
	my $element = findvalue($thing, 'local-name()');
	push @{$hash->{$element}}, "expand_$element"->($thing);
    }

    return $hash;
}

# expand mandatory
sub expand_mandatory
{
    my ($mandatory) = @_;

    my ($module, $name) = get_module_and_name($mandatory);

    print STDERR "expand_mandatory module=$module name=$name\n" if $verbose;

    return {module => $module, name => $name};
}

# expand option
sub expand_option
{
    my ($option) = @_;

    my ($module, $name) = get_module_and_name($option);
    my $description = findvalue($option, 'description', {descr => 1});

    print STDERR "expand_option module=$module name=$name\n" if $verbose;
    
    return {module => $module, name => $name};
}

# expand refinements
sub expand_refinements
{
    my ($refinements) = @_;

    print STDERR "expand_refinements\n" if $verbose;

    my $array = [];
    foreach my $refinement ($refinements->findnodes('refinement')) {
	push @$array, expand_refinement($refinement);
    }

    return $array;
}

# expand refinement
# XXX need to look up name so can get its values to pass to findvalue
sub expand_refinement
{
    my ($refinement) = @_;

    my ($module, $name) = get_module_and_name($refinement);
    my $access = findvalue($refinement, 'access');
    my $description = findvalue($refinement, 'description', {descr => 1});

    my $hash = {};
    $hash->{module} = $module if $module;
    $hash->{name} = $name if $name;
    $hash->{access} = $access if $access;
    $hash->{description} = $description if $description;
    
    print STDERR "expand_refinement module=$module name=$name access=$access\n"
	if $verbose;

    my $syntax = ($refinement->findnodes('syntax'))[0];
    $hash->{syntax} = expand_syntax($syntax) if $syntax;

    return $hash;
}

# convert syntax from one of the following forms:
#  type:    {module => m, name => n}
#  typedef: {name => n, basetype => b, status => s,
#            parent => {module => n, name => n},
#            range => [{min => m, max => m}, ...],
#            namednumber => [{number => n, name => n}, ...],
#            default => d, format => f, units => u,
#            description => d, reference => r}
#
# to the following more convenient form:
# XXX need to fix list in the same way that have done in tr2dm.pl
#  {type => t, base => b, ref => r, description => d,
#   values => {list => l,
#              [{optional => o, description => d, value => v}, ...]},
#   sizes  => [{min => m, max => m}, ...],
#   ranges => [{min => m, max => m}, ...]}
#
# 'type' is always a reference to a type defined in another module
# 'typedef' defines a new type, either named or anonymous, and always has a
#           basetype
#
# 'basetype' is the primitive base type (I think)
# 'parent' is the type from which this one is derived
# 'range' indicates the length range (for octet/string types) or the
#         value range (for numeric types)
# 'format' distinguishes between binary and string types (do any binary types
#          have formats... presumably not?)
#
# the ASN.1 primitive types (RFC 1155) are Integer, OctetString,
# ObjectIdentifier and Null; all other types are derived from them
# (actually some other types seem to be treated as primitive, e.g.
# Integer32 and Enumeration)
sub convert_syntax
{
    my ($in) = @_;

    # XXX should be able to leave name blank; should call it "name"?
    # XXX need to be more rigorous wrt name, base and ref
    my $name = $in->{name} ? $in->{name} : '';
    my $ref = $in->{parent}->{name} ? $in->{parent}->{name} : '';
    $ref = $in->{basetype} if !$ref && $in->{basetype};
    $name = $ref unless $name;
    my $is_list = $list_map->{$name};
    $name = $primitive_map->{$name} if $primitive_map->{$name};
    my $out = {type => $name, base => $ref, ref => $ref};

    $out->{values}->{list} = $is_list if $in->{namednumber};
    foreach my $item (@{$in->{namednumber}}) {
	my $value = ucfirst $item->{name};
        my $code = $item->{number};
	push @{$out->{values}->{values}}, {value => $value, code => $code};
    }

    # range refers to string length for strings and to numeric range otherwise
    # XXX this is problematic, since can't necessarily tell this, so have to
    #     apply heuristics
    # XXX including DisplayString and SnmpAdminString here is a hack, because I
    #     don't really understand the ASN.1/SMI logic
    foreach my $item (@{$in->{range}}) {
        if ($out->{values} || $out->{type}
            =~ /^(base64|hexBinary|string|DisplayString|SnmpAdminString)$/) {
            push @{$out->{sizes}}, $item;
        } else {
            push @{$out->{ranges}}, $item;
        }
    }

    $out->{description} = $in->{description};
    $out->{reference} = $in->{reference};
    $out->{units} = $in->{units};

    return $out;
}

# get module and name attributes
sub get_module_and_name
{
    my ($node) = @_;

    my $module = findvalue($node, '@module');
    my $name = findvalue($node, '@name');

    return ($module, $name);
}

# get name, oid and status
sub get_name_oid_and_status
{
    my ($node) = @_;

    my $name = findvalue($node, '@name');
    my $oid = findvalue($node, '@oid');
    my $status = findvalue($node, '@status');

    $status = 'current' unless $status;

    return ($name, $oid, $status);
}

# find a value and tidy the resulting string
#
# white space options are passed to white_strip; other options processed
# here are:
#  - boolean: convert to boolean 0/1
#  - descr: special processing for descriptions
sub findvalue
{
    my ($node, $xpath, $opts) = @_;

    $opts->{ignoremultiblank} = $opts->{descr};
    my $string = white_strip($node->findvalue($xpath), $opts);

    # optionally convert to boolean 0/1
    if ($opts->{boolean}) {
	$string = boolean($string);
    }

    # optionally remove single newlines, change leading "-" to "*",
    # change 'value(n)' strings to 'Value' where "value" is one of the
    # possible enumerated values, and other sundry edits
    if ($opts->{descr}) {
	# XXX need to be a bit cleverer, e.g. retaining the list nature where
	#     indentation is used to set off items (including use of leading
	#     "--" characters)
	# XXX also doesn't catch cases where an enumerated value is referenced
	#     in another parameter's description
        # XXX also newline handling needs to be cleverer; need heuristic to
        #     determine when it's the end of a paragraph
	$string =~ s/([^\n])\n/$1 /g;
	$string =~ s/\n-/\n*/g;
	foreach my $tvalue (@{$opts->{values}->{values}}) {
	    my $value = $tvalue->{value};
	    $string =~ s/(\s+)$value\(\d+\)/$1\"$value\"/ig;
	    $string =~ s/[\'\"]$value[\'\"]/\"$value\"/ig;
	}
        # change `word' and 'word' to "word"
        # XXX doesn't catch 'on top of' (for example)
        $string =~ s/(\W)[\`\'](\S+)\'(\W)/$1\"$2\"$3/g;

	$string =~ s/(false|true)\(\d+\)/$1/g;
	$string =~ s/\bdeprecated\b/DEPRECATED/g;
    }

    return $string;
}

# strip leading and trailing white space and, optionally, other space
sub white_strip
{
    my ($string, $opts) = @_;

    # always remove leading and trailing white space
    $string =~ s/^\s*//g;
    $string =~ s/\s*$//g;

    # also any spaces or tabs after newlines
    $string =~ s/\n[ \t]*/\n/g;

    # optionally ignore multiple blank lines (usually a formatting error)
    $string =~ s/\n([ \t]*\n){2,}/ /gs if $opts->{ignoremultiblank};

    # optionally collapse multiple spaces
    $string =~ s/\s+/ /g if $opts->{collapse};

    # optionally remove all white space
    if ($opts->{black}) {
	my $orig = $string;
	$string =~ s/\s+//g;
	print STDERR "white_strip: had to remove extra spaces in $orig\n" if
	    $pedantic && $opts->{blackwarn} && $string ne $orig;
    }

    return $string;
}

# return 0/1 given string representation of boolean
sub boolean
{
    my ($value) = @_;
    return ($value =~ /1|t|true/i) ? 1 : 0;
}

# output multi-line string to stdout, handling indentation
sub output
{
    my ($indent, $lines) = @_;

    return if $nooutput;

    foreach my $line (split /\n/, $lines) {
        print '  ' x $indent, $line, "\n";
	$indent = 0;
    }
}

# transform names
sub transform_names
{
    foreach my $scalar (@{$root->{scalars}}) {
        $scalar->{name} = transform_name($scalar->{name}, $root);
    }
    
    foreach my $table (@{$root->{tables}}) {
        $table->{name} =~ s/Table$// if $namemangle;
        foreach my $index (@{$table->{row}->{linkage}->{index}}) {
            $index->{name} = transform_name($index->{name}, $table);
        }
        foreach my $column (@{$table->{row}->{columns}}) {
            $column->{name} = transform_name($column->{name}, $table);
        }
    }
}

# transform name (name mangling)
sub transform_name
{
    my ($name, $parent) = @_;
    
    # if the parent object and the parameter name share a common prefix,
    # remove it from the parameter name
    if ($namemangle) {
        my $prefix = common_prefix($parent->{name}, $name);
        $name =~ s/^\Q$prefix\E//;
    }

    return $name;
}

# output XML
sub output_xml
{
    my $i = 0;

    my $root_name = $root->{name} ? $root->{name} : "root";
    my $Root_name = ucfirst $root_name;
    my $mname = qq{${Root_name}_Model:1.0};
    my $bmodel = '';

    # start of XML
    my $spec = $root->{spec};
    my $file = $root->{file};
    output $i, qq{<?xml version="1.0" encoding="UTF-8"?>};
    output $i, qq{<dm:document xmlns:dm="urn:broadband-forum-org:cwmp:datamodel-$schema_version"};
    output $i, qq{             xmlns:dmr="urn:broadband-forum-org:cwmp:datamodel-report-0-1"};
    output $i, qq{             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"};
    output $i, qq{             xsi:schemaLocation="urn:broadband-forum-org:cwmp:datamodel-$schema_version http://www.broadband-forum.org/cwmp/cwmp-datamodel-$schema_version.xsd urn:broadband-forum-org:cwmp:datamodel-report-0-1 http://www.broadband-forum.org/cwmp/cwmp-datamodel-report.xsd"};
    output $i, qq{             spec="$spec" file="$file">};

    # XXX this should be configurable; it introduces a TR-069 dependence and
    #     is tied back to the earlier reference to TR-069 data types
    $i++;
    output $i, qq{<import file="tr-106-1-1-types.xml" spec="urn:broadband-forum-org:tr-106-1-1">};
    output $i+1, qq{<dataType name="MACAddress"/>};
    output $i+1, qq{<dataType name="StatsCounter32"/>};
    output $i+1, qq{<dataType name="StatsCounter64"/>};
    output $i, qq{</import>};
    $i--;

    # output imports (need to be grouped by module)
    my $modules = {};
    my $index = 0;
    foreach my $import (@{$root->{imports}}) {
        my $module = $import->{module};
        my $name = $import->{name};
        # XXX this is rather heuristic
        next if $name =~ /MODULE-COMPLIANCE|MODULE-IDENTITY|NOTIFICATION-GROUP|NOTIFICATION-TYPE|OBJECT-GROUP|OBJECT-IDENTITY|OBJECT-TYPE|TEXTUAL-CONVENTION|mib-2/;
        push @{$modules->{$module}}, {module => $module, name => $name,
                                      index => $index++};
    }
    foreach my $module (sort {$modules->{$a}->[0]->{index} <=> $modules->{$b}->[0]->{index}} keys %$modules) {
        $i++;
        output $i, qq{<import file="$module.xml">};
        foreach my $import (@{$modules->{$module}}) {
            my $module = $import->{module};
            my $name = $import->{name};
            next if $module eq 'SNMPv2-TC' && $name eq 'DisplayString';
            
            # XXX assume that names that begin with upper-case letters are data
            #     types to be imported, and others are nodes etc that will
            #     be imported via components
            if ($name =~ /^[A-Z]/) {
                output $i+1, qq{<dataType name="$name"/>};
            } elsif ($dm_object_info->{$name}) {
                my $mname = $dm_object_info->{$name}->{model};
                output $i+1, qq{<model name="$mname"/>};
                # XXX this would be bad news if there was more than one of
                #     these
                $bmodel = qq{ base="$mname"};
            } else {
                output $i+1, qq{<!-- <node name="$name"/> -->};
            }
        }
        output $i, qq{</import>};
        $i--;
    }

    # output typedefs
    # XXX need to add status to the DM schema
    # XXX ignoring default, format and parent
    # XXX shouldn't ignore default, here or on parameters
    # XXX overlapping logic with convert_syntax (do without convert_syntax?)
    foreach my $typedef (@{$root->{typedefs}}) {
        my $name = $typedef->{name};
        next if $name eq 'DisplayString';
        
        my $basetype = $typedef->{basetype};
        my $status = $typedef->{status};
        my $description = $typedef->{description};
        my $reference = $typedef->{reference};
        my $range = $typedef->{range};
        my $namednumber = $typedef->{namednumber};
        my $units = $typedef->{units};

        $description = xml_escape($description);

        $reference = $reference ? qq{ {{bibref|$reference}}} : qq{};

        # XXX minimal list support (only for Bits)
        my $is_list = $list_map->{$basetype};

        $basetype = $primitive_map->{$basetype} if $primitive_map->{$basetype};

        my $base = ($basetype !~ /$primitive_patt/) ?
            qq{ base="$basetype"} : qq{};
        
        $status =~ s/obsolete/obsoleted/;
	$status = ($status ne 'current') ? qq{ status="$status"} : qq{};

        my $end_element = ($range || $namednumber || $units) ? '' : '/';

        $i++;
        output $i, qq{<dataType name="$name"$base$status>};
        output $i+1, qq{<description>$description$reference</description>} if $description;
        output $i+1, qq{<list/>} if $is_list;
        unless ($base) {
            $i++;
            output $i, qq{<$basetype$end_element>};
        }
        foreach my $range (@$range) {
            if ($basetype =~ /^(base64|hexBinary|string)$/) {
                output $i+1, qq{<size minLength="$range->{min}" maxLength="$range->{max}"/>};
            } else {
                output $i+1, qq{<range minInclusive="$range->{min}" maxInclusive="$range->{max}"/>};
            }
        }
        foreach my $item (@$namednumber) {
            # XXX duplicate code; not handling optional
            my $value = ucfirst $item->{name};
            my $code = $item->{number};
            output $i+1, qq{<enumeration value="$value" code="$code"/>};
        }
        if ($units) {
            output $i+1, qq{<units value="$units"/>};
        }
        unless ($base) {
            output $i, qq{</$basetype>} unless $end_element;
            $i--;
        }
        output $i, qq{</dataType>};
        $i--;
    }

    # output modified DisplayString definition
    # XXX should be controlled via command-line? should be a standard type?
    $i++;
    output $i, qq{<dataType name="DisplayString">};
    output $i+1, qq{<description>TR-069 version of DisplayString...</description>};
    output $i+1, qq{<string>};
    output $i+2, qq{<size maxLength="255"/>};
    output $i+2, qq{<pattern value="[ -~]*">};
    output $i+3, qq{<description>Printable ASCII characters.</description>};
    output $i+2, qq{</pattern>};
    output $i+1, qq{</string>};
    output $i, qq{</dataType>};
    $i--;

    # determine whether will create top-level component and model
    my $scalars = defined $root->{scalars};
    my $model = $scalars || defined $root->{tables};

    # output top-level component or model
    $i++;
    if ($components) {
	output($i, qq{<component name="$Root_name">}) if $scalars;
    } else {
	output($i, qq{<model name="$mname"$bmodel>}) if $model;
    }

    # output scalars (top-level parameters)
    if ($scalars && @{$root->{scalars}} && !$noparameters) {
        my $oname = $root_name . '.';
        unless ($noobjects) {
            output($i+1, qq{<object name="$oname" access="readOnly" } .
                   qq{minEntries="1" maxEntries="1">});
            output($i+2, qq{<description>});
            output($i+3, qq{$Root_name scalars.});
            output($i+2, qq{</description>});
        }
        foreach my $scalar (@{$root->{scalars}}) {
            output_parameter($scalar, $i + !$noobjects, {parent => $root});
            $dm_object_info->{$scalar->{name}} = {
                path => $oname, access => 'readOnly', minEntries => 1,
                maxEntries => 1};
        }
        unless ($noobjects) {
            output($i+1, qq{</object>});
        }
    }

    # terminate top-level component or output #entries parameters
    if ($components) {
	output($i, qq{</component>}) if $scalars;
        $i--;
    } else {
        unless ($noobjects) {
            foreach my $table (@{$root->{tables}}) {
                my $name = $table->{name};
                $i++;
                output $i, qq{<parameter name="${name}NumberOfEntries" access="readOnly">};
                output $i+1, qq{<description>{{numentries}}</description>};
                output $i+1, qq{<syntax>};
                output $i+2, qq{<unsignedInt/>};
                output $i+1, qq{</syntax>};
                output $i, qq{</parameter>};
                $i--;
            }
        }
    }

    # output tables (note we use the row OID, not the table OID)
    my $comps = [];
    foreach my $table (@{$root->{tables}}) {
	my $name = $table->{name};
	my $oid = $table->{row}->{oid};
	my $status = $table->{status};
	my $description = $table->{description};
        my $reference = $table->{reference};

        $description = xml_escape($description);

	my $access = $table->{row}->{create} ? 'readWrite' : 'readOnly';
        $status =~ s/obsolete/obsoleted/;
	$status = ($status ne 'current') ? qq{ status="$status"} : qq{};

        $reference = $reference ? qq{ {{bibref|$reference}}} : qq{};

        my $cname = ucfirst $name;
        
        # analyse linkage
        # XXX should check module?
        my $namebase = 'name';
        my $oname = $name . '.{i}';
        my $descact = qq{};
        my $minEntries = qq{0};
        my $maxEntries = qq{unbounded};
        my $numEntries = qq{ numEntriesParameter="${name}NumberOfEntries"};
        my $linkage = $table->{row}->{linkage};

        if ($linkage->{augments}) {
            my $name = $linkage->{augments}->{name};
            $name =~ s/Entry/Table/;
            $namebase = 'base';
            $oname = $name . '.{i}';
            $descact = qq{ action="append"};
            $numEntries = qq{};
        }
                
        my @unique = ();
        my @shared = ();
        if (defined $linkage->{index} && @{$linkage->{index}}) {
            foreach my $index (@{$linkage->{index}}) {
                if (grep {$_->{name} eq $index->{name}}
                    @{$table->{row}->{columns}}) {
                    push @unique, $index->{name};
                } else {
                    push @shared, $index->{name};
                }
            }
        }
        
        # if not augmenting and no unique key this will be a single-instance
        # object
        if (!$linkage->{augments} && !@unique) {
            $name =~ s/Table$//;
            $oname = $name;
            $minEntries = qq{1};
            $maxEntries = qq{1};
            $numEntries = qq{};
        }
        
        # if single shared key this will be a child of the table that defines
        # the shared key
        # XXX this behavior should be configurable; might want to create
        #     a new table that references entries in the table with the
        #     shared key
        # XXX can't handle cases where there is more than one shared key;
        #     in this case there are several options...
        my $ppath = '';
        my $paccess = undef;
        my $pminEntries = undef;
        my $pmaxEntries = undef;
        if (@shared) {
            my $list = join ', ', @shared;
            print STDERR "$name: ignoring second and subsequent shared " .
                "key $list\n" if @shared > 1;
            my $key = $shared[0];
            my $info = $dm_object_info->{$key};
            $ppath = $info->{path};
            $paccess = $info->{access};
            $pminEntries = $info->{minEntries};
            $pmaxEntries = $info->{maxEntries};
        }

	if ($components) {
	    $i++;
	    output $i, qq{<component name="$cname">};
            unless ($noobjects || $linkage->{augments} || !@unique) {
                $i++;
                output $i, qq{<object base="$ppath" access="$paccess" minEntries="$pminEntries" maxEntries="$pmaxEntries">} if $ppath;
                $i++;
                output $i, qq{<parameter name="${name}NumberOfEntries" access="readOnly">};
                output $i+1, qq{<description>{{numentries}}</description>};
                output $i+1, qq{<syntax>};
                output $i+2, qq{<unsignedInt/>};
                output $i+1, qq{</syntax>};
                output $i, qq{</parameter>};
                $i--;
                output $i, qq{</object>} if $ppath;
                $i--;
            }
	}

	unless ($noobjects) {
	    my $rowdesc = $table->{row}->{description};
	    my $rowref = $table->{row}->{reference};
            $rowref = $rowref ? qq{{{bibref|$rowref}}} : qq{};
	    $i++;
	    output $i, qq{<object $namebase="$ppath$oname." id="$oid" access="$access" minEntries="$minEntries" maxEntries="$maxEntries"$status$numEntries>};
	    output $i+1, qq{<description$descact>{{section|table}}$description${reference}\n{{section|row}}$rowdesc$rowref</description>};

            if (@unique) {
                my $any = 0;
                foreach my $name (@unique) {
                    output $i+1, qq{<uniqueKey>} unless $any++;
                    output $i+2, qq{<parameter ref="$name"/>};
		}
		output $i+1, qq{</uniqueKey>} if $any;
	    }
	}

	unless ($noparameters) {
	    foreach my $column (@{$table->{row}->{columns}}) {
                output_parameter($column, $i, {parent => $table->{row}});
                $dm_object_info->{$column->{name}} = {
                    path => $ppath . $oname . '.', access => $access,
                    minEntries => $minEntries, maxEntries => $maxEntries};
	    }
	}

	unless ($noobjects) {
	    output $i, qq{</object>};
	    $i--;
	}

	if ($components) {
	    output $i, qq{</component>};
	    $i--;
	}

        push @$comps, $cname;
    }

    # process notifications
    # XXX not using status
    $i++;
    output $i, qq{<component name="${Root_name}_Notifications">};
    my $notlist = {};
    my $index2 = 0;
    foreach my $notification (@{$root->{notifications}}) {
        my $nname = $notification->{name};

        my $path = undef;
        my $access = undef;
        my $minEntries = undef;
        my $maxEntries = undef;
        my $previousParameter = undef;
        foreach my $object (@{$notification->{objects}}) {
            my $module = $object->{module};
            my $name = $object->{name};

            my $tpath = undef;
            my $taccess = undef;
            my $tminEntries = undef;
            my $tmaxEntries = undef;
            if ($dm_object_info->{$name}) {
                my $info = $dm_object_info->{$name};
                $tpath = $info->{path};
                $taccess = $info->{access};
                $tminEntries = $info->{minEntries};
                $tmaxEntries = $info->{maxEntries};
            } elsif ($module ne $root->{module}) {
                print STDERR "$nname: $name is in different module ($module)".
                    " and cannot be mapped to an object\n";
            } else {
                print STDERR "$nname: object $name cannot be mapped to an " .
                    "object\n";
            }
            if ($tpath) {
                if ($path && $tpath ne $path) {
                    print STDERR "$nname: object $name maps to different " .
                        "object $tpath (previously mapped to $path)\n";
                }
                $path = $tpath;
                $access = $taccess;
                $minEntries = $tminEntries;
                $maxEntries = $tmaxEntries;
                $previousParameter = $name;
            }
        }
        if (!$path) {
            $path = $root->{name} . '.';
            $access = 'readOnly';
            $minEntries = 1;
            $maxEntries = 1;
        }
        $notlist->{$path}->{index} = $index2++ unless $notlist->{$path};
        $notlist->{$path}->{access} = $access;
        $notlist->{$path}->{minEntries} = $minEntries;
        $notlist->{$path}->{maxEntries} = $maxEntries;
        $notlist->{$path}->{previousParameter} = $previousParameter;
        push @{$notlist->{$path}->{notifications}}, $notification;
    }
    foreach my $path (sort {$notlist->{$a}->{index} <=>
                                $notlist->{$b}->{index}} keys %$notlist) {
        my $access = $notlist->{$path}->{access};
        my $minEntries = $notlist->{$path}->{minEntries};
        my $maxEntries = $notlist->{$path}->{maxEntries};
        my $previousParameter = $notlist->{$path}->{previousParameter};
        $i++;
        output $i, qq{<object base="$path" access="$access" minEntries="$minEntries" maxEntries="$maxEntries">};
        my $first = 1;
        foreach my $notification (@{$notlist->{$path}->{notifications}}) {
            my $nname = $notification->{name};
            my $oid = $notification->{oid};
            my $status = $notification->{status};
            my $description = xml_escape($notification->{description});
            my $cnode = {
                name => $nname,
                oid => $oid,
                syntax => {type => 'unsignedInt'},
                status => 'current',
                access => 'readonly',
                description => $description, # XXX might be double escaped?
            };
            my $opts = $first ? {previousParameter =>
                                     $previousParameter} : undef;
            output_parameter($cnode, $i, $opts);
            $dm_object_info->{$nname} = {
                path => $path, access => $access, minEntries => $minEntries,
                maxEntries => $maxEntries};
            $tree_node->{$nname} = $cnode;
            $first = 0;
        }
        output $i, qq{</object>};
        $i--;
    }
    output $i, qq{</component>};
    $i--;

    # process compliances
    # XXX not using module (should always be this module?) or status
    $i++;
    output $i, qq{<component name="${Root_name}_Compliances">};
    foreach my $compliance (@{$root->{compliances}}) {
        my $cname = $compliance->{name};
        my $Cname = ucfirst $cname;
        my $oid = $compliance->{oid};
        my $status = $compliance->{status};
        my $description = xml_escape($compliance->{description});
        my $overrides = {};
        foreach my $refinement (@{$compliance->{refinements}}) {
            my $rname = $refinement->{name};
            my $access = $refinement->{access};
            my $description = $refinement->{description};
            $overrides->{$rname} = {access => $access,
                                    description => $description};
        }
        foreach my $require (@{$compliance->{requires}}) {
            foreach my $category (('mandatory', 'option')) {
                my $profiles = [];
                foreach my $group_spec (@{$require->{$category}}) {
                    my $gname = $group_spec->{name};
                    my $Gname = ucfirst $gname;
                    my $group = (grep {$_->{name} eq $gname}
                                 @{$root->{groups}})[0];
                    my $pname = qq{${Cname}_${Gname}:1};
                    my $complist = {};
                    my $index3 = 0;
                    foreach my $member (@{$group->{members}}) {
                        my $name = $member->{name} || 'unknown';
                        my $path = $dm_object_info->{$name}->{path} ||
                            'unknown.';
                        $complist->{$path}->{index} = $index3++
                            unless $complist->{$path};
                        push @{$complist->{$path}->{names}}, $name;
                    }
                    $i++;
                    output $i, qq{<profile name="$pname">};
                    foreach my $path (sort {$complist->{$a}->{index} <=>
                                                $complist->{$b}->{index}}
                                      keys %$complist) {
                        output $i+1, qq{<object ref="$path" requirement="present">};
                        foreach my $name (@{$complist->{$path}->{names}}) {
                            my $access = $tree_node->{$name}->{access};
                            my $description = qq{};
                            my $override = $overrides->{$name};
                            if ($override) {
                                $access = $override->{access};
                                $description =
                                    xml_escape($override->{description});
                            }
                            $access = !$access ? 'unknown' :
                                ($access eq 'readwrite') ? 'readWrite' :
                                ($access eq 'noaccess') ? 'unknown' :
                                'readOnly';
                            my $end_element = $description ? '' : '/';
                            output $i+2, qq{<parameter ref="$name" requirement="$access"$end_element>};
                            if ($description) {
                                output $i+3, qq{<description>$description</description>};
                                output $i+2, qq{</parameter>};
                            }
                        }
                        output $i+1, qq{</object>};
                    }
                    output $i, qq{</profile>};
                    push @$profiles, $pname;
                    $i--;
                }
                my $Category = ucfirst $category;
                $Category =~ s/Option/Optional/;
                my $pname = ucfirst qq{${Cname}_${Category}:1};
                $i++;
                output $i, qq{<profile name="$pname" extends="};
                foreach my $profile (@$profiles) {
                    output $i+1, qq{$profile}; 
                }
                output $i, qq{"/>};
                $i--;
            }
        }
    }
    output $i, qq{</component>};
    $i--;

    # if collected components, create super-component and output model now
    if ($components) {
        $i++;
	output($i, qq{<component name="${Root_name}_All">});
        output($i+1, qq{<component ref="${Root_name}"/>}) if $scalars;
        foreach my $comp (@$comps) {
	    output($i+1, qq{<component ref="$comp"/>});
	}
	output($i+1, qq{<component ref="${Root_name}_Notifications"/>});
	output($i+1, qq{<component ref="${Root_name}_Compliances"/>});
	output($i, qq{</component>});
        if ($model) {
            output($i, qq{<model name="$mname"$bmodel>});
            output($i+1, qq{<component ref="${Root_name}_All"/>});
        }
    }

    # end of XML
    output($i, qq{</model>}) if $model;
    $i--;
    output $i, qq{</dm:document>};
}

# output parameter (either scalar or table column)
sub output_parameter
{
    my ($parameter, $i, $opts) = @_;

    my $name = $parameter->{name};
    my $oid = $parameter->{oid};
    my $status = $parameter->{status};
    my $syntax = $parameter->{syntax};
    my $access = $parameter->{access};
    my $units = $parameter->{units};
    my $description = xml_escape($parameter->{description});
    my $reference = $parameter->{reference};

    my $parent = $opts->{parent};
    my $previousParameter = $opts->{previousParameter};

    $description = xml_escape($description);
    
    # treat 'noaccess' as 'readWrite' for writeable tables and 'readOnly'
    # for read-only tables
    my $parent_access = !$parent ? 'unknown' : $parent->{create} ?
        'readWrite' : 'readOnly';
    $access = ($access eq 'readwrite') ? 'readWrite' :
        ($access eq 'noaccess') ? $parent_access : 'readOnly';
    $status =~ s/obsolete/obsoleted/;
    $status = ($status ne 'current') ? qq{ status="$status"} : qq{};
    $previousParameter = $previousParameter ? qq{ dmr:previousParameter="$previousParameter"} : qq{};
    
    $reference = $reference ? qq{ {{bibref|$reference}}} : qq{};

    my $type = $syntax->{type};
    my $sizes = $syntax->{sizes};
    my $ranges = $syntax->{ranges};
    my $values = $syntax->{values};

    my $list = ($values && defined $values->{list} &&
                boolean($values->{list}));
                
    my $end_element = ($sizes || $ranges || $values || $units) ? '' : '/';

    my $baseref = $end_element ? 'ref' : 'base';
    my $dataType = ($type =~ /$primitive_patt/) ? $type : 'dataType';
    $baseref = ($dataType eq 'dataType') ? qq{ $baseref="$type"} : qq{}; 

    output $i+1, qq{<parameter name="$name" id="$oid" access="$access"$status$previousParameter>};
    output $i+2, qq{<description>$description$reference</description>};
    output $i+2, qq{<syntax>};
    output $i+3, qq{<list/>} if $list;
    output $i+3, qq{<$dataType$baseref$end_element>};
    if ($sizes) {
        foreach my $size (@$sizes) {
            output $i+4, qq{<size minLength="$size->{min}" maxLength="$size->{max}"/>};
        }
    }
    if ($ranges) {
        foreach my $range (@$ranges) {
            output $i+4, qq{<range minInclusive="$range->{min}" maxInclusive="$range->{max}"/>};
        }
    }
    if ($values) {
        foreach my $value (@{$values->{values}}) {
            my $optional = $value->{optional};
            $optional = (defined($optional) && boolean($optional)) ?
                qq{ optional="true"} : qq{};
            if ($value->{description}) {
                output $i+4, qq{<enumeration value="$value->{value}" code="$value->{code}"$optional>};
                output $i+5, qq{<description>$description</description>};
                output $i+4, qq{</enumeration>};
            } else {
                output $i+4, qq{<enumeration value="$value->{value}" code="$value->{code}"$optional/>};
            }
        }
    }
    output $i+4, qq{<units value="$units"/>} if $units;
    output $i+3, qq{</$dataType>} unless $end_element;
    output $i+2, qq{</syntax>};
    output $i+1, qq{</parameter>};
}

# escape characters that are special to XML
sub xml_escape
{
    my ($value, $opts) = @_;

    # XXX probably needing to do this implies a bug elsewhere?
    $value = '' unless $value;

    $value =~ s/\&/\&amp;/g;
    $value =~ s/\</\&lt;/g;
    $value =~ s/\>/\&gt;/g;

    # only quote quotes in attribute values
    $value =~ s/\"/\&quot;/g if $opts->{attr};

    return $value;
}

# determine longest common prefix of two strings
#
# prefix is determined word by word, where words are separated by a change of
# case from lower to upper, e.g. "thisIsWords" is treated as "this Is Words"
sub common_prefix
{
    my ($a, $b) = @_;

    # inspired by http://www.perlmonks.org/bare/?node_id=543407, insert
    # spaces between lower-case and upper-case letters, then split on white
    # space
    my ($am, $bm) = ($a, $b);
    $am =~ s/(?<=[a-z])(?=[A-Z])/ /g; 
    $bm =~ s/(?<=[a-z])(?=[A-Z])/ /g; 
    my @a = split " ", $am; 
    my @b = split " ", $bm;

    # build the prefix; never use the last component of either name
    my $p = "";
    for (my $i = 0; $i+1 < @a && $i+1 < @b; $i++) {
        if ($a[$i] eq $b[$i]) {
            $p .= $a[$i];
        } else {
            last;
        }
    }

    return $p;
}
