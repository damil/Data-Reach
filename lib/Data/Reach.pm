package Data::Reach;
use strict;
use warnings;
use Carp         qw/carp croak/;
use Scalar::Util qw/blessed reftype/;
use overload;

our $VERSION    = '1.00';


=begin TODO

  - API for import() : include each_path() and map_paths()
  - each_path() should respect :peek_blessed
  - implement map_paths()
  - change API for hint hash : which syntax ? ex use .. qw/:use_overloads/;
                                                ? or qw/!use_overloads/ ... confusing with no ...

=end TODO

=cut

#======================================================================
# reach() and utility functions
#======================================================================
# main entry point
sub reach ($@) {
  my ($root, @path) = @_;

  # loop until either @path or the datastructure under $root is exhausted
  while (1) {

    # exit conditions
    return undef             if !defined $root;
    return $root             if !@path;
    my $path0 = shift @path;
    return undef             if !defined $path0;

    # otherwise, walk down one step into the datastructure and loop again
    $root = blessed $root ? _step_down_obj($root, $path0)
                          : _step_down_raw($root, $path0);
  }
}

# get inner data within a raw datastructure
sub _step_down_raw {
  my ($data, $key) = @_;

  my $reftype = reftype $data || '';

  if ($reftype eq 'HASH') {
    return $data->{$key};
  }
  elsif ($reftype eq 'ARRAY') {
    if ($key =~ /^-?\d+$/) {
      return $data->[$key];
    }
    else {
      croak "cannot reach index '$key' within an array";
    }
  }
  else {
    my $kind = $reftype          ? "${reftype}REF"
             : defined ref $data ? "SCALAR"
             :                     "undef";
    my $article = $kind =~ /^[aeiou]/i ? "an" : "a";
    croak "cannot reach '$key' within $article $kind";
  }
}


# get inner data within an object
sub _step_down_obj {
  my ($obj, $key) = @_;

  # pragmata that may modify our algorithm -- see L<perlpragma>
  my $hint_hash = (caller(1))[10];
  my $use_overloads = $hint_hash->{'Data::Reach::use_overloads'} // 1; # default
  my $peek_blessed  = $hint_hash->{'Data::Reach::peek_blessed'}  // 1; # default

  # choice 1 : call named method in object
  my @call_method = split $;, $hint_hash->{'Data::Reach::call_method'} || '';
 METH_NAME:
  foreach my $meth_name (@call_method) {
    my $meth =$obj->can($meth_name)
      or next METH_NAME;
    return $obj->$meth($key);
  }

  # choice 2 : use overloaded methods -- active by default
  if ($use_overloads) {
    return $obj->[$key] if overload::Method($obj, '@{}')
                        && $key =~ /^-?\d+$/;
    return $obj->{$key} if overload::Method($obj, '%{}');$hint_hash->{'Data::Reach::use_overloads'} // 1; # defaulto
  }

  # choice 3 : use the object's internal representation -- active by default
  if ($peek_blessed) {
    return _step_down_raw($obj, $key);
  }
  else {
    croak "cannot reach '$key' within an object of class " . ref $obj;
  }
}


#======================================================================
# map_paths()
#======================================================================

sub map_paths (&+;$$); # must declare before the sub definition below, because of recursive call
sub map_paths (&+;$$) {
  my ($coderef, $tree, $max_depth, $path)= @_;
  $max_depth  //= -1;
  $path       //= [];
  my $hint_hash = (caller(1))[10];
  my $reftype   = reftype $tree;


  if (!$reftype || !$max_depth || $reftype !~ /^(?:HASH|ARRAY)$/) {
    return $coderef->(@$path, $tree);
  }
  elsif ($reftype eq 'HASH') {
    my @k = keys %$tree;
    return $coderef->(@$path, {}) if !@k  && $hint_hash->{'Data::Reach::keep_empty_subtrees'};
    return map {map_paths(\&$coderef, $tree->{$_}, $max_depth-1, [@$path, $_])} @k;
  }
  elsif ($reftype eq 'ARRAY') {
    return $coderef->(@$path, []) if !@$tree  && $hint_hash->{'Data::Reach::keep_empty_subtrees'};
    return map {map_paths(\&$coderef, $tree->[$_], $max_depth-1, [@$path, $_])} 0 .. $#$tree;
  }
}


#======================================================================
# each_path()
#======================================================================

sub each_path (+;$) {
  my ($tree, $max_depth) = @_;
  $max_depth //= -1;
  my $hint_hash = (caller(1))[10];

  # local boolean variable to avoid returning the same result multiple times
  my $is_consumed;

  # closure to be used at tree leaves
  my $leaf = sub {return $is_consumed++ ? () : ([], $tree)};

  # either this tree is a leaf, or we must recurse into subtrees
  my $reftype     = reftype $tree;
  my $has_subtree = $reftype && ($reftype eq 'HASH' || $reftype eq 'ARRAY');
  if (!$has_subtree || !$max_depth) {
    return $leaf;
  }
  else {
    my $i = 0;                                         # index into subtrees
    my @k = sort keys %$tree if $reftype eq 'HASH';    # keys -- if the subtree is a hash
    my $n_subtrees = $reftype eq 'HASH' ? @k : @$tree; # number of subtrees
    my $next_subpath;                                  # iterator into next subtree

    if (!$n_subtrees && $hint_hash->{'Data::Reach::keep_empty_subtrees'}) {
      return $leaf;
    }
    else {
      return sub {
        while (1) {
          if (!$next_subpath) {
            if (!$is_consumed && $i < $n_subtrees) {
              my $subtree   = $reftype eq 'HASH' ? $tree->{$k[$i]} : $tree->[$i];
              $next_subpath = each_path($subtree, $max_depth-1);
            }
            else {
              $is_consumed++;
              return;
            }
          }
          if (my ($subpath, $subval) = $next_subpath->()) {
            my $path_item = $reftype eq 'HASH' ? $k[$i] : $i;
            return ([$path_item, @$subpath], $subval);
          }
          else {
            $next_subpath = undef;
            $i++;
          }
        }
      }
    }
  }
}




#======================================================================
# import and unimport
#======================================================================

# the 'import' method does 2 things : a) export the required functions,
# like the regular Exporter, but possibly with a change of name;
# b) implement optional changes to the algorithm, lexically scoped
# through the %^H hint hash (see L<perlpragma>).

my $exported_functions = qr/^(:?reach|each_path|map_paths)$/) {
my $hint_options       = qr/^(?:peek_blessed|use_overloads|keep_empty_subtrees)$/;

sub import {
  my $class = shift;
  my $pkg = caller;

  my %export_as 
    = map {($_ => $_)} qw/reach each_path map_paths/ if !@_;  # default
  my $last_func  = 'reach';                                   # default

  # loop for cheap parsing of import parameters
  while (my $option = shift) {
    if ($option =~ $exported_functions) {
      $export_as{$option} = $option;
      $last_func          = $option;
    }
    elsif ($option eq 'as') {
      my $alias = shift
        or croak "use Data::Reach : no export name after 'as'";
      $export_as{$last_func} = $alias;
    }
    elsif ($option eq 'call_method') {
      my $methods = shift
        or croak "use Data::Reach : no method name after 'call_method'";
      $methods = join $;, @$methods if (ref $methods || '') eq 'ARRAY';
      $^H{"Data::Reach::call_method"} = $methods;
    }
    elsif ($option =~ $hint_options) {
      $^H{"Data::Reach::$option"} = 1;
    }
    else {
      croak "use Data::Reach : unknown option : $option";
    }
  }

  # export into caller's package, under the required alias names
  while (my ($func, $alias) = each %export_as) {
    no strict 'refs';
    *{$pkg . "::" . $alias} = \&$func if $alias;
  }
}


sub unimport {
  my $class = shift;
  while (my $option = shift) {
    $^H{"Data::Reach::$option"} = '' if $option =~ $hint_options;
    # NOTE : mark with a false value, instead of deleting from the
    # hint hash, in order to distinguish options explicitly turned off
    # from default options
  }
}


1;


__END__

=head1 NAME

Data::Reach - Walk down or iterate through a nested datastructure

=head1 SYNOPSIS

    # reach a subtree or a leaf under a nested datastructure
    use Data::Reach;
    my $node = reach $data_tree, @path; # @path may contain a mix of hash keys and array indices

    # do something with all paths through the datastructure ..
    my @result = map_paths { my $val = pop; do_something_with(\@_, $val)} $data_tree;

    # .. or loop through all paths
    my $next_path = each_path $data_tree;
    while (my ($path, $val) = $next_path->()) {
      do_something_with($path, $val);
    }

    # import under a different name
    use Data::Reach qw/reach as walk_down/;
    my $node = walk_down $data_tree, @path;

    # optional changes of algorithm, lexically scoped
    { no Data::Reach  qw/peek_blessed use_overloads/;
      use Data::Reach call_method => [qw/foo bar/];
      my $node = reach $object_tree, @path;
    }
    # after end of scope, back to the regular algorithm

=head1 DESCRIPTION

Perl supports nested datastructures : a hash may contain references to
other hashes or to arrays, which in turn may contain further references
to deeper structures -- see L<perldsc>. Walking down through such
structures usually involves nested loops, and possibly some tests on
C<ref $subtree> for finding out if the next level is an arrayref or a hashref.

The present module offers some utilities for easier handling of nested
datastructures :

=over

=item *

the C<reach> function finds a subtree or a leaf according to a given
C<@path> -- a list of hash keys or array indices. If there is no data
corresponding to that path, C<undef> is returned, without any autovivification
within the tree.

=item *

the C<map_paths> function applies a given code reference to all paths within the nested
datastructure.


=item *

the C<each_path> function returns an iterator over the nested datastructure; it can be
used in the same spirit as an C<each> statement over a simple hash, except that it will
walk through all different paths within the nested datastructure

=back





The L</"SEE ALSO"> section
below discusses some alternative implementations.


=head1 FUNCTIONS

=head2 reach

  my $node = reach $data_tree, @path;

Tries to find a node under root C<$data_tree>, walking down
the tree and choosing subnodes according to values given in
C<@path> (which should be a list of scalar values). At each step :

=over

=item *

if the root is C<undef>, then C<undef> is returned (even if
there are remaining items in C<@path>)

=item *

if C<@path> is empty, then the root C<$data_tree> is returned

=item *

if the first item in C<@path> is C<undef>, then 
C<undef> is returned (even if there are remaining items in C<@path>).

=item *

if C<$data_tree> is a hashref or can behave as a hashref, then
C<< $data_tree->{$path[0]} >> becomes the new root,
and the first item from C<@path> is removed.
No distinction is made between a missing or an undefined
C<< $data_tree->{$path[0]} >> : in both cases the result
will be C<undef>.

=item *

if C<$data_tree> is an arrayref or can behave as an arrayref, then
C<< $data_tree->[$path[0]] >> becomes the new root,
and the first item from C<@path> is removed.
The value in C<< $path[0] >> must be an integer; otherwise
it is improper as an array index and an error is generated.
No distinction is made between a missing or an undefined
C<< $data_tree->[$path[0]] >> : in both cases the result
will be C<undef>.

=item *

if C<$data_tree> is any other kind of data (scalar, reference
to a scalar, reference to a reference, etc.), an error is generated.

=back

No autovivification nor any writing
into the datastructure is ever performed. Missing data merely returns
C<undef>, while wrong use of data (for example looking into an
arrayref with a non-numerical index) generates an exception.

By default, blessed objects are treated just like raw, unblessed
datastructures; however that behaviour can be changed through
pragma options, as described below.


=head2 map_paths

  my @result = map_paths { ... } $data_tree [, $max_depth];

Applies the given block to each path within C<$data_tree>, returning the list
of collected results. The value of C<@_> within the block corresponds to the
sequence of hash keys or array indices that were traversed, followed by the value
of the leaf node. Hence, for a C<$data_tree> of shape :

  { foo => [ undef,
             'abc',
             {bar => {buz => 987}},
             1234,
            ],
    empty_slot  => undef,
    qux         => 'qux',  }

the block will be called six times, with the following lists in C<@_>

   ('empty_slot,', undef)
   ('foo', 0, undef)
   ('foo', 1, 'abc')
   ('foo', 2, 'bar', 'buz', 987)
   ('foo', 3, 1234')
   ('qux', 'qux')

[CONTINUE HERE]








=head1 IMPORT INTERFACE

=head2 Exporting the 'reach' function

The 'reach' function is exported by default when C<use>ing this module,
as in :

  use Data::Reach;
  use Data::Reach qw/reach/; # equivalent to the line above

However the exported name can be changed through the C<as> option :

  use Data::Reach as => 'walk_down';
  my $node = walk_down $data, @path;

The same can be done with an empty string in order to prevent any export.
In that case, the fully qualified name must be used to call the
C<reach> function :

  use Data::Reach as => '';      # equivalent to "use Data::Reach ();"
  my $node = Data::Reach::reach $data, @path;


=head2 Pragma options for reaching within objects

Arguments to the import method may also change the algorithm used to
C<reach> within objects. These options can be turned on or off as
lexical pragmata; this means that the effect of change of algorithm
is valid until the end of the current scope (see L<perlfunc/use>,
L<perlfunc/no> and L<perlpragma>).

=over

=item C<call_method>

  use Data::Reach call_method => 'foo';         # just one method
  use Data::Reach call_method => [qw/foo bar/]; # an ordered list of methods

If the target object possesses a method corresponding to the
name(s) specified, that method will be called, with a single
argument corresponding to the current value in path.
The method is supposed to reach down one step into the
datastructure and return the next data subtree or leaf.

The presence of one of the required methods is the first
choice for reaching within an object. If this cannot be applied,
either because there was no required method, or because the
target object has none of them, then the second choice
is to use overloads, as described below.

=item C<use_overloads>

  use Data::Reach qw/use_overloads/; # turn the option on
  no  Data::Reach qw/use_overloads/; # turn the option off

This option is true by default; it means that if the object
has an overloaded hash or array dereferencing function,
that function will be called (see L<overload>). This feature
distinguishes C<Data::Reach> from other similar modules
listed in the L</"SEE ALSO"> section.

=item C<peek_blessed>

  use Data::Reach qw/peek_blessed/; # turn the option on
  no  Data::Reach qw/peek_blessed/; # turn the option off

This option is true by default; it means that the C<reach> functions
will go down into object implementations (i.e. reach internal attributes
within the object's hashref). Turn it off if you want objects to
stay opaque, with public methods as the only way to reach
internal information.

=back

Note that several options can be tuned in one single statement :

  no  Data::Reach qw/use_overloads peek_blessed/; # turn both options off


=head1 SEE ALSO

There are many similar modules on CPAN, each of them having some
variations in the set of features. Here are a few pointers, and the
reasons why I didn't use them :

=over 

=item L<Data::Diver>

Does quite a similar job, with a richer API (can also write into
the datastructure or use it as a lvalue). Return values may be 
complex to decode (distinctions between an empty list, an C<undef>,
or a singleton containing an C<undef>). It uses C<eval> internally,
without taking care of eval pitfalls (see L<Try::Tiny/BACKGROUND>
for explanations).


=item L<Data::DRef>

An old module (last update was in 1999), still relevant for
modern Perl, except that it does not handle overloads, which
were not available at that time. The API is a bit too rich to my
taste (many different ways to get or set data).

=item L<Data::DPath> or L<Data::Path>

Two competing modules for accessing nested data through expressions
similar to XPath. Very interesting, but a bit overkill for the needs
I wanted to cover here.

=item L<Data::Focus>

Creates a "focus" object that walks through the data using
various "lenses". An interesting approach, inspired by Haskell,
but also a bit overkill.

=item L<Data::PathSimple>

Very concise. The path is expressed as a '/'-separated string
instead of an array of values. Does not handle overloads.


=back



=head1 AUTHOR

Laurent Dami, C<< <dami at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-data-reach at
rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Data-Reach>.  I will
be notified, and then you'll automatically be notified of progress on
your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Data::Reach


You can also look for information at:

=over 4

=item RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Data-Reach>

=item AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Data-Reach>

=item CPAN Ratings

L<http://cpanratings.perl.org/d/Data-Reach>

=item METACPAN

L<https://metacpan.org/pod/Data::Reach>

=back

The source code is at
L<https://github.com/damil/Data-Reach>.


=head1 LICENSE AND COPYRIGHT

Copyright 2015 Laurent Dami.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

