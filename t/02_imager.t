#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use FindBin qw($Bin);
use Path::Class qw(file);
use Email::MIME;
use Imager;

use Email::Barcode::Decode;

my $QR_DATA = 'eusa:mpsexp:9';
my $barcode = barcode_image();

subtest 'short raster dies instead of crashing' => sub {
    # an enhancer returning less data than width*height must not reach ZBar,
    # which would read past the buffer and segfault
    local @Email::Barcode::Decode::enhancers = (sub { return ('', 'Y800', 10, 10) });
    my $ebd = Email::Barcode::Decode->new(email => scalar file($Bin, 'tdata', 'msg01.eml')->slurp);
    eval { $ebd->get_symbols };
    like($@, qr/raster size mismatch/, 'dies with raster size mismatch');
};

subtest '16-bit PNG' => sub {
    my $deep = Imager->new(
        xsize    => $barcode->getwidth,
        ysize    => $barcode->getheight,
        channels => $barcode->getchannels,
        bits     => 16,
    );
    $deep->paste(src => $barcode);
    is_deeply([decoded_data(png_of($deep))], [$QR_DATA]);
};

subtest 'black code on transparent background' => sub {
    # transparent pixels are black with alpha 0; dropping alpha would give an all-black image
    my $inverted = $barcode->convert(preset => 'gray');
    $inverted->filter(type => 'hardinvert') or die $inverted->errstr;
    my $transparent = $inverted->convert(matrix => [[0], [0], [0], [1]]);
    is_deeply([decoded_data(png_of($transparent))], [$QR_DATA]);
};

done_testing();

# barcode image from msg01.eml as Imager object
sub barcode_image {
    my $ebd = Email::Barcode::Decode->new(email => scalar file($Bin, 'tdata', 'msg01.eml')->slurp);
    my $img = Imager->new(file => $ebd->attached_files->[0]->stringify) or die Imager->errstr;
    return $img;
}

sub png_of {
    my ($img) = @_;
    my $png;
    $img->write(data => \$png, type => 'png') or die $img->errstr;
    return $png;
}

# decoded symbol data of an email with $image_data attached as a PNG
sub decoded_data {
    my ($image_data) = @_;
    my $email = Email::MIME->create(
        header_str => [From => 'test@example.com', Subject => 'png'],
        parts      => [
            Email::MIME->create(
                attributes => {content_type => 'text/plain'},
                body       => 'scan',
            ),
            Email::MIME->create(
                attributes => {
                    content_type => 'image/png',
                    filename     => 'code.png',
                    encoding     => 'base64',
                },
                body => $image_data,
            ),
        ],
    );
    my $ebd = Email::Barcode::Decode->new(email => $email->as_string);
    my @data = eval { map { $_->{data} } $ebd->get_symbols };
    return $@ ? ('died: ' . $@) : @data;
}
