#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use FindBin qw($Bin);
use Email::MIME;
use Path::Class qw(file dir);
use Encode qw(encode_utf8);

use Email::Barcode::Decode;

subtest 'attachment filenames cannot escape the temporary directory' => sub {
    foreach my $filename ('../escape.png', '..\\escape.png', '/abs/escape.png') {
        my $ebd = eval { Email::Barcode::Decode->new(email => email_with([$filename => 'x'])) };
        if (!ok($ebd, $filename . ' accepted')) {
            diag($@);
            next;
        }
        my $tmpdir = dir($ebd->_tmpdir);
        my ($file) = @{$ebd->attached_files};
        ok($tmpdir->resolve->subsumes($file->resolve), $filename . ' stays inside');
        is($file->basename, 'escape.png', $filename . ' keeps its base name');
    }
};

subtest 'control characters and overlong filenames do not break new' => sub {
    foreach my $filename ("a\0b\n.png", ('x' x 300) . '.png') {
        my $ebd = eval { Email::Barcode::Decode->new(email => email_with([$filename => 'x'])) };
        my $label = substr($filename, 0, 10) =~ s/[^[:print:]]/?/gr;
        if (!ok($ebd, $label . ' accepted')) {
            diag($@);
            next;
        }
        my ($file) = @{$ebd->attached_files};
        like($file->basename, qr/\A[[:print:]]{1,200}[.]png\z/, $label . ' printable, short, keeps extension');
    }
};

subtest 'shortening a huge filename takes linear time' => sub {
    # Email::MIME itself is slow on names this long, so call the helper directly
    # with a character string, as Email::MIME returns them
    my $huge     = ("\x{e4}" x 1_000_000) . '.png';
    my $basename = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        my $short = Email::Barcode::Decode::_safe_basename($huge);
        alarm(0);
        $short;
    };
    is($@, q{}, 'finished within 5 seconds');
    is(length(encode_utf8($basename // q{})), 200, 'cut to 200 bytes');
};

subtest 'attachments with the same name are kept apart' => sub {
    my $ebd = Email::Barcode::Decode->new(email => email_with(['same.png' => 'one'], ['same.png' => 'two']));
    is_deeply(
        [map { scalar $_->slurp } @{$ebd->attached_files}],
        ['one', 'two'],
        'both contents preserved',
    );
};

subtest 'attachments that are no images are skipped' => sub {
    my $ebd = Email::Barcode::Decode->new(
        email => email_with(
            ['notes.txt'   => 'no image'],
            ['barcode.jpg' => barcode_jpeg()],
        ),
    );
    my @symbols = eval { $ebd->get_symbols };
    is($@, q{}, 'no exception');
    is_deeply([map { $_->{filename} } @symbols], ['barcode.jpg'], 'barcode of the image found');
};

subtest 'attachments in nested multiparts are found' => sub {
    my $email = Email::MIME->create(
        header_str => [From => 'test@example.com', Subject => 'nested'],
        parts      => [
            Email::MIME->create(
                attributes => {content_type => 'multipart/related'},
                parts      => [
                    Email::MIME->create(
                        attributes => {content_type => 'text/html'},
                        body       => '<img src="cid:barcode">',
                    ),
                    Email::MIME->create(
                        attributes => {
                            content_type => 'image/jpeg',
                            filename     => 'barcode.jpg',
                            encoding     => 'base64',
                        },
                        body => barcode_jpeg(),
                    ),
                ],
            ),
            Email::MIME->create(
                attributes => {content_type => 'text/plain'},
                body       => 'scan',
            ),
        ],
    );
    my $ebd = Email::Barcode::Decode->new(email => $email->as_string);
    is_deeply([map { $_->basename } @{$ebd->attached_files}], ['barcode.jpg']);
};

done_testing();

sub barcode_jpeg {
    my $msg01 = Email::MIME->new(scalar file($Bin, 'tdata', 'msg01.eml')->slurp);
    my ($jpeg) = grep { ($_->filename // q{}) eq 'barcode01.jpg' } $msg01->parts;
    return $jpeg->body;
}

# email with a text part and one attachment per [$filename => $body]
sub email_with {
    my (@attachments) = @_;
    return Email::MIME->create(
        header_str => [From => 'Foo Bar <foo@example.com>', Subject => 'attachments'],
        parts      => [
            Email::MIME->create(
                attributes => {content_type => 'text/plain'},
                body       => 'scan',
            ),
            map {
                Email::MIME->create(
                    attributes => {
                        content_type => 'application/octet-stream',
                        filename     => $_->[0],
                        encoding     => 'base64',
                    },
                    body => $_->[1],
                )
            } @attachments,
        ],
    )->as_string;
}
