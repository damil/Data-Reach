#!perl
use strict;
use warnings;
no warnings 'uninitialized';
use Test::More tests => 9;
use Test::NoWarnings;
use Data::Reach 'map_paths';

# test data
my $data = {
  foo => [ undef,
           'abc',
           {bar => {buz => 987}},
           1234,
          ],
  empty_array => [],
  empty_hash  => {},
  empty_slot  => undef,
  qux         => 'qux',
  stringref   => \"ref",
  refref      => \\"ref",
};


{
  my @all_paths    = map_paths {join ",", @_} $data;
  my @sorted_paths = sort @all_paths;
  is_deeply([@sorted_paths[0..5]],
            ['empty_slot,',
             'foo,0,',
             'foo,1,abc',
             'foo,2,bar,buz,987',
             'foo,3,1234',
             'qux,qux'],
            "initial paths");
  like $sorted_paths[6], qr/^refref,REF\(/,       'refref';
  like $sorted_paths[7], qr/^stringref,SCALAR\(/, 'stringref';
}


{
  use Data::Reach qw/keep_empty_subtrees/;
  my @all_paths = map_paths {join ",", @_} $data;
  my @sorted_paths = sort @all_paths;
  like $sorted_paths[0], qr/^empty_array,ARRAY\(/, "empty_array";
  like $sorted_paths[1], qr/^empty_hash,HASH\(/,   "empty_hash";
  is_deeply([@sorted_paths[2..7]],
            ['empty_slot,',
             'foo,0,',
             'foo,1,abc',
             'foo,2,bar,buz,987',
             'foo,3,1234',
             'qux,qux'],
            "initial paths");
  like $sorted_paths[8], qr/^refref,REF\(/,       'refref';
  like $sorted_paths[9], qr/^stringref,SCALAR\(/, 'stringref';
}


