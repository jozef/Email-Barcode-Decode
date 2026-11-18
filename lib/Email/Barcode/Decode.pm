package Email::Barcode::Decode;

use warnings;
use strict;

use Carp 'croak';
use Email::MIME;
use File::Temp qw(tempdir);
use File::Find::Rule;
use Path::Class qw(file);
use Imager;
use Barcode::ZBar;
use Capture::Tiny 'capture';
use File::Which qw(which);

our $VERSION = '0.05';

use base 'Class::Accessor::Fast';

__PACKAGE__->mk_accessors(qw{
    email
    header_obj
    attached_files
    _tmpdir
});

our $MAX_HEIGHT = 1500;    # bigger images may not work well with Barcode::ZBar

# enhancers get an Imager object and return ($raw, 'Y800', $width, $height)
our @enhancers = (
    # plain grayscale, Barcode::ZBar does its own binarization
    sub {
        my ($img) = @_;
        return _y800(_gray($img));
    },
    # hard black/white threshold
    sub {
        my ($img) = @_;
        $img = _gray($img);
        $img->map(all => [map { $_ < 128 ? 0 : 255 } 0 .. 255]) or die $img->errstr;
        return _y800($img);
    },
);

sub _gray {
    my ($img) = @_;
    my $channels = $img->getchannels;
    my $gray =
          $channels >= 3 ? $img->convert(preset => 'gray')
        : $channels == 2 ? $img->convert(preset => 'noalpha')
        :                  $img->copy;
    die $img->errstr unless $gray;
    if ($gray->getheight > $MAX_HEIGHT) {
        $gray = $gray->scale(ypixels => $MAX_HEIGHT) or die $gray->errstr;
    }
    return $gray;
}

sub _y800 {
    my ($img) = @_;
    my $raw;
    $img->write(data => \$raw, type => 'raw') or die $img->errstr;
    return ($raw, 'Y800', $img->getwidth, $img->getheight);
}

sub new {
    my ($class, %opts) = @_;

    my $email = $opts{email};
    croak 'need email string as argument'
        unless $email;

    my $tmpdir = tempdir( CLEANUP => 1 );
    $opts{_tmpdir} = $tmpdir;

    my @attached_files;
    my $parsed            = Email::MIME->new($email);
    $opts{header_obj}     = $parsed->header_obj;
    $opts{attached_files} = \@attached_files;

    foreach my $part ($parsed->parts) {
        my $filename = $part->filename;
        next unless $filename;
        my $body = $part->body;

        if ((
                ($part->content_type =~ m{application/pdf})
                || ($filename =~ m{\.pdf$})
            )
            && (scalar(which('pdftoppm')))
        ) {
            my $tmpdir2 = tempdir( CLEANUP => 1 );
            my $attached_pdf = file($tmpdir2, 'attached.pdf');
            $attached_pdf->spew($body);

            # lossless 8-bit grayscale pages page-1.pgm, page-2.pgm, ...;
            # numbers are zero-padded to the same width, so string sort is page order
            my ($stdout, $stderr, $exit) = capture {
                system(
                    'pdftoppm', '-gray', '-r', '150', '-l', '237',
                    "$attached_pdf", file($tmpdir2, 'page').'',
                );
            };
            my @files =
                map { file($_) }
                sort
                File::Find::Rule
                ->file()
                ->name( 'page-*.pgm' )
                ->in( $tmpdir2 );
            my $base_name = $filename;
            $base_name =~ s/[.]/-/g;
            foreach my $file (@files) {
                my $image_file = file($tmpdir, $base_name.'-'.$file->basename);
                $file->copy_to($image_file);
                push(@attached_files, $image_file);
            }
        }
        else {
            my $attached_file = file($tmpdir, $filename);
            $attached_file->spew($body);
            push(@attached_files, $attached_file);
        }
    }

    my $self  = $class->SUPER::new(\%opts);
    return $self;
}

sub get_symbols {
    my ($self) = @_;

    my $scanner = Barcode::ZBar::ImageScanner->new();
    $scanner->parse_config("enable");

    my @symbols;
    foreach my $file (@{$self->attached_files}) {
        my %unique_data;
        foreach my $enhancer (@enhancers) {
            my @new_symbols = _get_symbols_from_file($scanner, $file, $enhancer,);

            push(
                @symbols, (
                    map { +{
                        filename => $file->basename,
                        type     => $_->get_type,
                        data     => $_->get_data,
                    }}
                    grep { not($unique_data{$_->get_data}++) }   # only new/unique
                    @new_symbols,
                ),
            );
        }
    }

    return @symbols;
}

sub _get_symbols_from_file {
    my ($scanner, $file, $enhance_code) = @_;

    my $img = Imager->new(file => "$file")
        or die 'failed to read ' . $file . ': ' . Imager->errstr . "\n";

    my ($raw, $raw_format, $width, $height) = $enhance_code->($img);

    # Barcode::ZBar reads width*height bytes without checking the buffer
    my $expected = $width * $height;
    my $got      = length($raw // '');
    die "raster size mismatch for $file: expected $expected bytes, got $got\n"
        if !$expected || ($got != $expected);

    my $image = Barcode::ZBar::Image->new();
    $image->set_format($raw_format);
    $image->set_size($width, $height);
    $image->set_data($raw);

    $scanner->scan_image($image);

    return $image->get_symbols;
}

sub email_name {
    my ($self) = @_;
    my ($from) = Email::Address->parse($self->header_obj->header('From'));
    return $from->name;
}

sub email_from {
    my ($self) = @_;
    my ($from) = Email::Address->parse($self->header_obj->header('From'));
    return $from->address;
}



1;


__END__

=head1 NAME

Email::Barcode::Decode - decode barcodes out of an email

=head1 SYNOPSIS

    my $ebd = Email::Barcode::Decode->new(email => $msg);
    my @symbols = $ebd->get_symbols;
    foreach my $symbol (@symbols) {
        print(
            'decoded '  . $symbol->{type} .
            ' symbol "' . $symbol->{data} .'"'.
            ' file "'   . $symbol->{filename} .'"'.
            "\n"
        );
    }

=head1 DESCRIPTION

This module can extract barcode information out of email attachments.
It processes all email image attachments. When C<pdftoppm> (Debian package
C<poppler-utils>) is installed, it renders every page of PDF attachments
into a grayscale image. Images are read with L<Imager>,
converted to grayscale and scanned for barcodes using L<Barcode::ZBar>.
Each image is scanned twice, once in plain grayscale and once converted to
black and white.

=head1 PROPERTIES

    email
    header_obj
    attached_files

=head1 METHODS

=head2 new()

Object constructor. Requires C<email> string.

=head2 get_symbols()

Returns an array of hashed with barcode information. Ex.:

    my @symbols = ({
        filename => 'vcard-pdf-page-2.pgm',
        type     => 'QR-Code',
        data     => 'http://search.cpan.org/perldoc?Email%3A%3ABarcode%3A%3ADecode',
    });

=head1 AUTHOR

Jozef Kutej

=cut
