#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use File::Which qw(which);
use Email::MIME;
use Imager;
use List::Util qw(max);
use File::Temp qw(tempdir);
use Path::Class qw(file);

use Email::Barcode::Decode;

plan skip_all => '- no `pdftoppm` found. Is poppler-utils installed?'
    unless which('pdftoppm');
plan tests => 7;

PAGES_IN_PAGE_ORDER: {
    my $ebd = Email::Barcode::Decode->new(email => pdf_email('many.pdf', blank_pdf(11)));
    is_deeply(
        [map { $_->basename } @{$ebd->attached_files}],
        [map { sprintf('many-pdf-page-%02d.pgm', $_) } 1 .. 11],
        'pages in page order, not string order',
    );
}

PAGE_SIZE_IS_BOUNDED: {
    # a tiny PDF with a huge page must not render into a huge raster
    my $ebd = Email::Barcode::Decode->new(email => pdf_email('huge.pdf', blank_pdf(1, 4000, 4000)));
    my $page = Imager->new(file => $ebd->attached_files->[0]->stringify) or die Imager->errstr;
    my $max  = $Email::Barcode::Decode::MAX_HEIGHT;
    is(max($page->getwidth, $page->getheight), $max, 'long side is $MAX_HEIGHT');
}

PAGE_LIMIT: {
    local $Email::Barcode::Decode::MAX_PDF_PAGES = 2;
    my $ebd = Email::Barcode::Decode->new(email => pdf_email('three.pdf', blank_pdf(3)));
    is(scalar(@{$ebd->attached_files}), 2, 'only $MAX_PDF_PAGES pages rendered');
}

BROKEN_PDF_WARNS: {
    my @warnings;
    local $SIG{__WARN__} = sub { push(@warnings, @_) };
    Email::Barcode::Decode->new(email => pdf_email('broken.pdf', '%PDF-1.4 truncated'));
    like(join(q{}, @warnings), qr/pdftoppm failed for broken[.]pdf/, 'pdftoppm failure is reported');
}

NON_ASCII_PDF_NAME_WARNS_IN_ASCII: {
    my @warnings;
    local $SIG{__WARN__} = sub { push(@warnings, @_) };
    Email::Barcode::Decode->new(email => pdf_email("\x{e4}\x{263a}.pdf", '%PDF-1.4 truncated'));
    is(scalar(@warnings), 1, 'one warning');
    like($warnings[0] // q{}, qr/\Apdftoppm failed for a[.]pdf [[:ascii:]]+\z/, 'in ASCII');
}

KILLED_PDFTOPPM_REPORTS_SIGNAL: {
    my $bin = tempdir(CLEANUP => 1);
    my $fake_pdftoppm = file($bin, 'pdftoppm');
    $fake_pdftoppm->spew("#!/bin/sh\nkill -KILL \$\$\n");
    chmod(0755, $fake_pdftoppm) or die $!;
    local $ENV{PATH} = $bin;
    my @warnings;
    local $SIG{__WARN__} = sub { push(@warnings, @_) };
    Email::Barcode::Decode->new(email => pdf_email('killed.pdf', blank_pdf(1)));
    like(join(q{}, @warnings), qr/pdftoppm failed for killed[.]pdf \(signal 9\)/, 'signal is reported');
}

sub pdf_email {
    my ($filename, $pdf) = @_;
    return Email::MIME->create(
        header_str => [From => 'test@example.com', Subject => 'pdf'],
        parts      => [
            # a single part would collapse into a non-multipart email without filename
            Email::MIME->create(
                attributes => {content_type => 'text/plain'},
                body       => 'scan',
            ),
            Email::MIME->create(
                attributes => {
                    content_type => 'application/pdf',
                    filename     => $filename,
                    encoding     => 'base64',
                },
                body => $pdf,
            ),
        ],
    )->as_string;
}

# minimal valid PDF with $count blank pages, A6 unless ($width, $height) in points
sub blank_pdf {
    my ($count, $width, $height) = @_;
    my $media_box = '[0 0 ' . ($width // 298) . ' ' . ($height // 420) . ']';
    my @objects = (
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Count ' . $count . ' /Kids ['
            . join(' ', map { ($_ + 3) . ' 0 R' } 0 .. $count - 1) . '] >>',
        map { '<< /Type /Page /Parent 2 0 R /MediaBox ' . $media_box . ' >>' } 1 .. $count,
    );
    my $pdf = "%PDF-1.4\n";
    my @offsets;
    foreach my $i (0 .. $#objects) {
        push(@offsets, length($pdf));
        $pdf .= ($i + 1) . " 0 obj\n" . $objects[$i] . "\nendobj\n";
    }
    my $xref = length($pdf);
    $pdf .= 'xref' . "\n" . '0 ' . (@objects + 1) . "\n" . "0000000000 65535 f \n";
    $pdf .= sprintf("%010d 00000 n \n", $_) for @offsets;
    $pdf .= 'trailer << /Size ' . (@objects + 1) . ' /Root 1 0 R >>' . "\n";
    $pdf .= 'startxref' . "\n" . $xref . "\n" . '%%EOF' . "\n";
    return $pdf;
}
