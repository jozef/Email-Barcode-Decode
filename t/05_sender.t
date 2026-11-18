#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 7;

use Email::Barcode::Decode;

my $ebd = Email::Barcode::Decode->new(
    email => "From: \"Foo Bar\" <foo\@example.com>\nSubject: hi\n\nbody\n",
);
is(eval { $ebd->email_name } // $@, 'Foo Bar', 'email_name');
is(eval { $ebd->email_from } // $@, 'foo@example.com', 'email_from');

my @warnings;
local $SIG{__WARN__} = sub { push(@warnings, @_) };
my $anonymous = Email::Barcode::Decode->new(email => "Subject: hi\n\nbody\n");
is_deeply([scalar(eval { $anonymous->email_name }), $@], [undef, ''], 'no From: email_name is undef');
is_deeply([scalar(eval { $anonymous->email_from }), $@], [undef, ''], 'no From: email_from is undef');
my $empty = Email::Barcode::Decode->new(email => "From: <>\nSubject: hi\n\nbody\n");
is(scalar($empty->email_name), undef, 'From: <>: email_name is undef');
is(scalar($empty->email_from), undef, 'From: <>: email_from is undef');
is_deeply(\@warnings, [], 'no From or From: <>: no warnings');
