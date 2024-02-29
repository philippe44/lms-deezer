package Crypt::CBC::PBKDF;

# just a virtual base class for passphrase=>key derivation functions
use strict;
use File::Basename 'dirname','basename';
use Carp 'croak';

sub new {
    my $class    = shift;
    my $subclass = shift;
    my $options  = shift;

    my $package = __PACKAGE__."::$subclass";
    eval "use $package; 1" or
	croak "Could not load $subclass: $@";

    return $package->create(%$options);
}

# returns a series of subclasses
sub list {
    my $self = shift;
    my $dir      = dirname(__FILE__);
    my @pm_files = <$dir/PBKDF/*.pm>;
    my @subclasses;
    foreach (@pm_files) {
	my $base =  basename($_);
	$base    =~ s/\.pm$//;
	push @subclasses,$base;
    }
    return @subclasses;
}

sub generate_hash {
    my $self = shift;
    my ($salt,$passphrase) = @_;
    croak "generate() method not implemented in this class. Use one of the subclasses",join(',',$self->list);
}

sub key_and_iv {
    my $self = shift;
    croak 'usage $obj->salt_key_iv($salt,$passphrase)' unless @_ == 2;

    my $hash = $self->generate_hash(@_);

    my $key  = substr($hash,0,$self->{key_len});
    my $iv   = substr($hash,$self->{key_len},$self->{iv_len});
    return ($key,$iv);
}

1;
