#!perl
use strict;
use warnings;
use Test::More;
use Test::NoWarnings;
use Data::Reach 'each_path';

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
$data->{sparse_array}[3000] = "i'm alone";


{
  my %got_path;
  my $next_path = each_path $data;
  while (my ($path, $val) = $next_path->()) {
    $got_path{join ",", @$path} = $val;
  }
  note explain \%got_path;
}


{
  use Data::Reach qw/keep_empty_subtrees/;
  my %got_path;
  my $next_path = each_path $data;
  while (my ($path, $val) = $next_path->()) {
    $got_path{join ",", @$path} = $val;
  }
  note explain \%got_path;
}




done_testing();
