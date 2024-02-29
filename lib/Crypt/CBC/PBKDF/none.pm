package Crypt::CBC::PBKDF::none;
use strict;
use Carp 'croak';
use base 'Crypt::CBC::PBKDF::opensslv1';

# options:
# key_len    => 32    default
# iv_len     => 16    default

sub generate_hash {
    my $self = shift;
    my ($salt,$passphrase) = @_;
    # ALERT: in this case passphrase IS the key and the salt is ignored
    # Croak unless key matches key length
    my $keylen = $self->{key_len};
    length($passphrase) == $keylen or croak "For selected cipher, the key must be exactly $keylen bytes long";
    return $passphrase;
}

1;
