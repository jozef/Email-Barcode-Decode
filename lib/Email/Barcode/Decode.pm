package Email::Barcode::Decode;

use warnings;
use strict;

use Carp 'croak';
use Email::MIME;
use Email::Address::XS qw(parse_email_addresses);
use File::Temp qw(tempdir);
use Path::Class qw(file dir);
use Imager;
use Barcode::ZBar;
use Capture::Tiny 'capture';
use Encode qw(encode_utf8);
use Text::Unidecode qw(unidecode);
use File::Which qw(which);

our $VERSION = '0.05';

use base 'Class::Accessor::Fast';

__PACKAGE__->mk_accessors(qw{
    email
    header_obj
    attached_files
    _tmpdir
});

our $MAX_HEIGHT    = 1500;    # image height and PDF page long side for Barcode::ZBar
our $MAX_PDF_PAGES = 237;     # pages rendered per PDF attachment

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
    my $gray = $img->to_rgb8 or die $img->errstr;
    if ($gray->getchannels >= 3) {
        $gray = $gray->convert(preset => 'gray') || die $gray->errstr;
    }
    if ($gray->getchannels == 2) {
        $gray = _flatten_on_white($gray);
    }
    if ($gray->getheight > $MAX_HEIGHT) {
        $gray = $gray->scale(ypixels => $MAX_HEIGHT) || die $gray->errstr;
    }
    return $gray;
}

# barcodes are usually dark on a transparent background, so transparent is white
sub _flatten_on_white {
    my ($gray_alpha) = @_;
    my $flat = Imager->new(
        xsize    => $gray_alpha->getwidth,
        ysize    => $gray_alpha->getheight,
        channels => 1,
    );
    $flat->box(filled => 1, color => 'white') or die $flat->errstr;
    $flat->compose(src => $gray_alpha) or die $flat->errstr;
    return $flat;
}

sub _y800 {
    my ($img) = @_;
    my $raw;
    $img->write(data => \$raw, type => 'raw') or die $img->errstr;
    return ($raw, 'Y800', $img->getwidth, $img->getheight);
}

# all non-multipart parts, depth first, so nested attachments are found too
sub _leaf_parts {
    my ($part) = @_;
    my @subparts = $part->subparts;
    return $part unless @subparts;
    return map { _leaf_parts($_) } @subparts;
}

# attachment filename without directories and control characters, never "",
# "." or "..", at most $MAX_NAME_BYTES long including the extension; file systems
# allow 255 bytes, PDF page names add "-page-NNN.pgm"
my $MAX_NAME_BYTES = 200;

sub _safe_basename {
    my ($filename) = @_;
    my $basename = (split(m{[/\\]}, $filename))[-1] // q{};
    $basename =~ s/[[:cntrl:]]//g;
    return 'attachment' if $basename =~ m{\A[.]{0,2}\z};

    my ($stem, $extension) = $basename =~ m{\A(.*?)((?:[.][^.]{1,16})?)\z}s;
    # a character is at least one byte; the cut keeps the loop below short
    $stem = substr($stem, 0, $MAX_NAME_BYTES);
    chop($stem) while ($stem ne q{}) && (length(encode_utf8($stem . $extension)) > $MAX_NAME_BYTES);
    return $stem . $extension;
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

    my $part_number = 0;
    foreach my $part (_leaf_parts($parsed)) {
        next unless $part->filename;
        my $filename = _safe_basename($part->filename);
        my $body     = $part->body;

        # one directory per part, so attachments with equal names do not collide
        my $part_dir = dir($tmpdir, ++$part_number);
        $part_dir->mkpath;

        my $is_pdf = ($part->content_type =~ m{application/pdf}) || ($filename =~ m{[.]pdf\z});
        push(
            @attached_files,
            ($is_pdf && which('pdftoppm'))
                ? _render_pdf_pages($part_dir, $filename, $body)
                : _save_attachment($part_dir, $filename, $body),
        );
    }

    my $self  = $class->SUPER::new(\%opts);
    return $self;
}

sub _save_attachment {
    my ($part_dir, $filename, $body) = @_;
    my $attached_file = $part_dir->file($filename);
    $attached_file->spew($body);
    return $attached_file;
}

# lossless 8-bit grayscale pages <name>-pdf-page-1.pgm, ..., long side scaled
# to $MAX_HEIGHT; numbers are zero-padded to the same width, so string sort
# is page order
sub _render_pdf_pages {
    my ($part_dir, $filename, $body) = @_;

    my $attached_pdf = _save_attachment($part_dir, 'attached.pdf', $body);
    (my $page_prefix = $filename . '-page') =~ s/[.]/-/g;
    my (undef, $stderr, $system_status) = capture {
        system(
            'pdftoppm', '-gray', '-scale-to', $MAX_HEIGHT, '-l', $MAX_PDF_PAGES,
            $attached_pdf->stringify, $part_dir->file($page_prefix)->stringify,
        );
    };
    if ($system_status != 0) {
        # ASCII only, so non-Latin-1 filenames cannot add "Wide character" warnings
        warn(unidecode('pdftoppm failed for ' . $filename . ' (' . _describe_system_status($system_status) . '): ' . $stderr));
    }

    my @pages =
        sort { $a->basename cmp $b->basename }
        grep { $_->basename =~ m{\A\Q$page_prefix\E-\d+[.]pgm\z} }
        $part_dir->children;
    return @pages;
}

sub _describe_system_status {
    my ($system_status) = @_;
    return 'not started'                    if $system_status == -1;
    return 'signal ' . ($system_status & 127) if $system_status & 127;
    return 'exit ' . ($system_status >> 8);
}

sub get_symbols {
    my ($self) = @_;

    my $scanner = Barcode::ZBar::ImageScanner->new();
    $scanner->parse_config("enable");

    my @symbols;
    foreach my $file (@{$self->attached_files}) {
        # attachments Imager cannot read (no image, unsupported format) are skipped
        my $img = Imager->new(file => $file->stringify) or next;
        my %unique_data;
        foreach my $enhancer (@enhancers) {
            my @new_symbols = _get_symbols_from_image($scanner, $img, $file, $enhancer);

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

sub _get_symbols_from_image {
    my ($scanner, $img, $file, $enhance_code) = @_;

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
    my $from = $self->_from // return;
    return $from->name;
}

sub email_from {
    my ($self) = @_;
    my $from = $self->_from // return;
    return $from->address;
}

sub _from {
    my ($self) = @_;
    my $from_header = $self->header_obj->header('From') // return;
    my ($from) = parse_email_addresses($from_header);
    # no boolean test on $from: its overloading warns on empty addresses
    return ((defined($from) && $from->is_valid) ? $from : undef);
}

1;


__END__

=head1 NAME

Email::Barcode::Decode - decode barcodes in email attachments

=head1 SYNOPSIS

    use Email::Barcode::Decode;

    my $ebd = Email::Barcode::Decode->new(email => $raw_email_string);
    foreach my $symbol ($ebd->get_symbols) {
        print(
            'decoded '  . $symbol->{type} .
            ' symbol "' . $symbol->{data} .'"'.
            ' file "'   . $symbol->{filename} .'"'.
            "\n"
        );
    }

=head1 DESCRIPTION

Email::Barcode::Decode finds barcodes and QR codes in the attachments of an
email and returns their decoded content.

The constructor saves every MIME part that has a filename to a temporary
directory, including parts inside nested multiparts. When C<pdftoppm> is
installed, each page of a PDF attachment is rendered into a grayscale image
instead of saving the PDF itself.

L</get_symbols> reads each saved file with L<Imager>, converts it to 8-bit
grayscale and scans it with L<Barcode::ZBar>. With the default
L</@enhancers>, each image is scanned twice: once in plain grayscale and
once converted to pure black and white. Attachments that Imager cannot
read, such as text files, are skipped.

=head1 REQUIREMENTS

=over 4

=item * L<Imager> with support for the image formats you expect. Imager
reads JPEG, PNG, GIF and TIFF only if it was built with the matching
libraries (Debian package C<libimager-perl> includes them). Run
C<< perl -MImager -e 'print join(q{ }, Imager->read_types), "\n"' >> to
see the formats your installation can read.

=item * Optional: C<pdftoppm> from Poppler (Debian package
C<poppler-utils>) to scan PDF attachments. Without it, PDF attachments are
skipped.

=back

=head1 ACCESSORS

=head2 email

The raw email string passed to L</new>.

=head2 header_obj

The L<Email::MIME::Header> object of the email.

=head2 attached_files

Array reference of L<Path::Class::File> objects, one for each saved
attachment or rendered PDF page, in the order of the MIME parts.

Each attachment is saved as C<< <tmpdir>/<part number>/<file name> >>. The
file name is the attachment filename without any directory components, so
a malicious filename such as C<../../.bashrc> cannot write outside the
temporary directory, and attachments with the same filename do not
overwrite each other. Control characters are removed, and names longer
than 200 bytes (UTF-8) are shortened, keeping the extension. A name that
is empty, C<.> or C<..> after this becomes C<attachment>.

Rendered PDF pages are named after the PDF filename, with dots replaced by
dashes: C<scan.pdf> becomes C<scan-pdf-page-1.pgm>, C<scan-pdf-page-2.pgm>
and so on. Page numbers are zero-padded to equal width, so sorting the
names gives the page order. Each page is an 8-bit grayscale image whose
long side is L</$MAX_HEIGHT> pixels, whatever the page size in the PDF.

The temporary directory is removed when the program exits.

=head1 METHODS

=head2 new

    my $ebd = Email::Barcode::Decode->new(email => $raw_email_string);

Parses the email and saves its attachments as described in
L</attached_files>. Croaks when C<email> is missing or empty.

When C<pdftoppm> fails, for example on a damaged or password-protected PDF,
C<new> warns with the exit status or signal and the C<pdftoppm> error
message, and keeps any pages that were rendered:

    pdftoppm failed for scan.pdf (exit 1): Syntax Error: Couldn't find trailer dictionary ...

The warning is plain ASCII: non-ASCII characters are transliterated with
L<Text::Unidecode>, so C<E<auml>rger.pdf> is reported as C<arger.pdf>.

=head2 get_symbols

Scans all L</attached_files> and returns a list of hash references, one per
decoded symbol:

    (
        {
            filename => 'vcard-pdf-page-2.pgm',
            type     => 'QR-Code',
            data     => 'http://search.cpan.org/perldoc?Email%3A%3ABarcode%3A%3ADecode',
        },
    )

=over 4

=item C<filename>

Base name of the scanned file in L</attached_files>.

=item C<type>

Symbol type as reported by L<Barcode::ZBar>, for example C<QR-Code>,
C<CODE-128> or C<EAN-13>.

=item C<data>

Decoded content of the symbol.

=back

Symbols are returned in the order of L</attached_files>. Within one file,
the same C<data> is returned only once, even when several enhancers find it.
The same content in different files is returned once per file.

Dies with C<raster size mismatch> when an enhancer returns a raster whose
length is not C<width * height>; see L</@enhancers>.

=head2 email_name

Returns the display name of the first C<From> address, falling back to the
local part of the address when there is no display name. Returns C<undef>,
or an empty list in list context, when the email has no C<From> header or
its first address is not a valid address, such as C<< <> >>.

=head2 email_from

Returns the first C<From> address, for example C<foo@example.com>. Returns
C<undef>, or an empty list in list context, in the same cases as
L</email_name>.

=head1 CONFIGURATION

These package variables control how attachments are converted and scanned.
Localize them around the call that reads them to limit the change to your
code:

    local $Email::Barcode::Decode::MAX_HEIGHT = 2000;

=head2 $MAX_HEIGHT

Images taller than this are scaled down to this height, keeping the aspect
ratio, before scanning. Default: C<1500> pixels, because larger images may
not decode well with L<Barcode::ZBar>. PDF pages are rendered with their
long side at this size, which also bounds the disk space a PDF can take.
Read by L</new> and L</get_symbols>.

=head2 $MAX_PDF_PAGES

Number of pages rendered per PDF attachment; later pages are ignored.
Default: C<237>. Read by L</new>.

=head2 @enhancers

List of code references. L</get_symbols> calls each of them for every
image and scans each result.

Each enhancer receives the L<Imager> object of the image and must return
C<($raw, 'Y800', $width, $height)>, where C<$raw> is an 8-bit grayscale
raster of exactly C<$width * $height> bytes. B<The enhancer must not modify
the Imager object in place>, because all enhancers receive the same object.

The default enhancers return:

=over 4

=item 1. the plain grayscale image, leaving binarization to ZBar;

=item 2. the image converted to pure black and white with a fixed
threshold of 128.

=back

Both turn transparent areas white, as barcodes are usually dark on a light
or transparent background.

=head1 SEE ALSO

L<Barcode::ZBar>, L<Imager>, L<Email::MIME>, L<pdftoppm(1)>

=head1 AUTHOR

Jozef Kutej

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
