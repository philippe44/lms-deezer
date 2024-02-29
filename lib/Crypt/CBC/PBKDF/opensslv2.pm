package Crypt::CBC::PBKDF::opensslv2;
use strict;
use base 'Crypt::CBC::PBKDF::opensslv1';
use Digest::SHA 'sha256';

# options:
# key_len    => 32    default
# iv_len     => 16    default

sub generate_hash {
    my $self = shift;
    my ($salt,$passphrase) = @_;
    my $desired_len = $self->{key_len} + $self->{iv_len};
    my $data  = '';
    my $d = '';
    while (length $data < $desired_len) {
	$d     = sha256($d . $passphrase . $salt);
	$data .= $d;
    }
    return $data;
}

1;
