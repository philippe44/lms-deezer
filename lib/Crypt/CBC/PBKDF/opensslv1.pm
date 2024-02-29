package Crypt::CBC::PBKDF::opensslv1;
use strict;
use base 'Crypt::CBC::PBKDF';
use Digest::MD5 'md5';

# options:
# salt_len   => 8     default
# key_len    => 32    default
# iv_len     => 16    default

sub create {
    my $class = shift;
    my %options = @_;
    $options{salt_len} ||= 8;
    $options{key_len}  ||= 32;
    $options{iv_len}   ||= 16;
    return bless \%options,$class;
}

sub generate_hash {
    my $self = shift;
    my ($salt,$passphrase) = @_;
    my $desired_len = $self->{key_len} + $self->{iv_len};
    my $data  = '';
    my $d = '';
    while (length $data < $desired_len) {
	$d     = md5($d . $passphrase . $salt);
	$data .= $d;
    }
    return $data;
}

1;
