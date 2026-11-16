#!/usr/bin/perl
use strict;
use warnings;

# Count words.
my %count;
my @words = split /\s+/, "a b a";
$count{$_}++ for @words;
print "a: $count{a}\n";

=pod

Documentation.

=cut
