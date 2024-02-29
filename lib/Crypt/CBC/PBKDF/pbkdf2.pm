package Crypt::CBC::PBKDF::pbkdf2;
use strict;

use base 'Crypt::CBC::PBKDF';
use Crypt::PBKDF2;

# options:
# key_len    => 32    default
# iv_len     => 16    default
# iterations => 10000  default
# hash_class => 'HMACSHA2' default

sub create {
    my $class = shift;
    my %options = @_;
    $options{key_len}      ||= 32;
    $options{iv_len}       ||= 16;
    $options{iterations}   ||= 10_000;
    $options{hash_class}   ||= 'HMACSHA2';
    return bless \%options,$class;
}

sub generate_hash {
    my $self = shift;
    my ($salt,$passphrase) = @_;
    my $pbkdf2 = Crypt::PBKDF2->new(%$self,
				    output_len => $self->{key_len} + $self->{iv_len});
    return $pbkdf2->PBKDF2($salt,$passphrase);
}

1;
