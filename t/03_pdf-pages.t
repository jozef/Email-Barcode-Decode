#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use File::Which qw(which);
use Email::MIME;

plan skip_all => '- no `pdftoppm` found. Is poppler-utils installed?'
    unless which('pdftoppm');
plan tests => 2;

use_ok('Email::Barcode::Decode') or exit;

PAGES_IN_PAGE_ORDER: {
    my $email = Email::MIME->create(
        header_str => [From => 'test@example.com', Subject => 'many pages'],
        parts      => [
            # a single part would collapse into a non-multipart email without filename
            Email::MIME->create(
                attributes => {content_type => 'text/plain'},
                body       => 'scan',
            ),
            Email::MIME->create(
                attributes => {
                    content_type => 'application/pdf',
                    filename     => 'many.pdf',
                    encoding     => 'base64',
                },
                body => blank_pdf(11),
            ),
        ],
    );

    my $ebd = Email::Barcode::Decode->new(email => $email->as_string);
    is_deeply(
        [map { $_->basename } @{$ebd->attached_files}],
        [map { sprintf('many-pdf-page-%02d.pgm', $_) } 1 .. 11],
        'pages in page order, not string order',
    );
}

# minimal valid PDF with $count blank A6 pages
sub blank_pdf {
    my ($count) = @_;
    my @objects = (
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Count ' . $count . ' /Kids ['
            . join(' ', map { ($_ + 3) . ' 0 R' } 0 .. $count - 1) . '] >>',
        map {'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 298 420] >>'} 1 .. $count,
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
