#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;

use FindBin qw($Bin);
use Path::Class qw(file);

BEGIN {
    use_ok('Email::Barcode::Decode') or exit;
}

ok(!$INC{'Image/Magick.pm'}, 'Image::Magick is not loaded');

SHORT_RASTER_DIES: {
    # an enhancer returning less data than width*height must not reach ZBar,
    # which would read past the buffer and segfault
    local @Email::Barcode::Decode::enhancers = (sub { return ('', 'Y800', 10, 10) });
    my $ebd = Email::Barcode::Decode->new(email => scalar file($Bin, 'tdata', 'msg01.eml')->slurp);
    eval { $ebd->get_symbols };
    like($@, qr/raster size mismatch/, 'short raster dies instead of crashing');
}
