package Crypt::CBC;

use strict;
use Carp 'croak','carp';
use Crypt::CBC::PBKDF;
use bytes;
use vars qw($VERSION);
no warnings 'uninitialized';
$VERSION = '3.04';

use constant RANDOM_DEVICE      => '/dev/urandom';
use constant DEFAULT_PBKDF      => 'opensslv1';
use constant DEFAULT_ITER       => 10_000;  # same as OpenSSL default

my @valid_options = qw(
    pass
    key
    cipher
    keysize
    chain_mode
    pbkdf
    nodeprecate
    iter
    hasher
    header
    iv
    salt
    padding
    literal_key
    pcbc
    add_header
    generate_key
    prepend_iv
    );

sub new {
    my $class = shift;

    # the _get_*() methods move a lot of the ugliness/legacy logic
    # out of new(). But the ugliness is still there!
    my $options               = $class->_get_options(@_);
    eval {$class->_validate_options($options)} or croak $@;
    
    my $cipher                = $class->_get_cipher_obj($options);
    my $header_mode           = $class->_get_header_mode($options);
    my ($ks,$bs)              = $class->_get_key_and_block_sizes($cipher,$options);
    my ($pass,$iv,$salt,$key,
	$random_salt,$random_iv) = $class->_get_key_materials($options);
    my $padding                  = $class->_get_padding_mode($bs,$options);
    my ($pbkdf,$iter,
	$hc,$nodeprecate)        = $class->_get_key_derivation_options($options,$header_mode);
    my $chain_mode               = $class->_get_chain_mode($options);

    ### CONSISTENCY CHECKS ####

    # set literal key flag if a key was passed in or the key derivation algorithm is none
    $key               ||= $pass if $pbkdf eq 'none';  # just in case
    my $literal_key      = defined $key;

    # check length of initialization vector
    croak "Initialization vector must be exactly $bs bytes long when using the $cipher cipher" 
	if defined $iv and length($iv) != $bs;

    # chaining mode check
    croak "invalid cipher block chain mode: $chain_mode"
	unless $class->can("_${chain_mode}_encrypt");

    # KEYSIZE consistency
    if (defined $key && length($key) != $ks) {
	croak "If specified by -literal_key, then the key length must be equal to the chosen cipher's key length of $ks bytes";
    }

    # HEADER consistency
    if ($header_mode eq 'salt') {
	croak "Cannot use salt-based key generation if literal key is specified"
	    if $literal_key;
    }
    elsif ($header_mode eq 'randomiv') {
	croak "Cannot encrypt using a non-8 byte blocksize cipher when using randomiv header mode"
	    unless $bs == 8
    }

    croak "If a key derivation function (-pbkdf) of 'none' is provided, a literal key and iv must be provided"
	if $pbkdf eq 'none' && (!defined $key || !defined $iv);

    croak "If a -header mode of 'randomiv' is provided, then the -pbkdf key derivation function must be 'randomiv' or undefined"
	if $header_mode eq 'randomiv' and $pbkdf ne 'randomiv';

    return bless {
	'cipher'      => $cipher,
	    'passphrase'  => $pass,
	    'key'         => $key,
	    'iv'          => $iv,
	    'salt'        => $salt,
	    'padding'     => $padding,
	    'blocksize'   => $bs,
	    'keysize'     => $ks,
	    'header_mode' => $header_mode,
	    'literal_key' => $literal_key,
	    'literal_iv'  => defined $iv,
	    'chain_mode'  => $chain_mode,    
	    'make_random_salt' => $random_salt,
	    'make_random_iv'   => $random_iv,
	    'pbkdf'        => $pbkdf,
	    'iter'         => $iter,
	    'hasher'       => $hc,
	    'nodeprecate'  => $nodeprecate,
    },$class;
}

sub filehandle {
    my $self = shift;
    $self->_load_module('Crypt::FileHandle')
	or croak "Optional Crypt::FileHandle module must be installed to use the filehandle() method";

    if (ref $self) { # already initialized
	return Crypt::FileHandle->new($self);
    }
    else { # create object
	return Crypt::FileHandle->new($self->new(@_));
    }
}

sub encrypt (\$$) {
    my ($self,$data) = @_;
    $self->start('encrypting');
    my $result = $self->crypt($data);
    $result .= $self->finish;
    $result;
}

sub decrypt (\$$){
    my ($self,$data) = @_;
    $self->start('decrypting');
    my $result = $self->crypt($data);
    $result .= $self->finish;
    $result;
}

sub encrypt_hex (\$$) {
    my ($self,$data) = @_;
    return join('',unpack 'H*',$self->encrypt($data));
}

sub decrypt_hex (\$$) {
    my ($self,$data) = @_;
    return $self->decrypt(pack 'H*',$data);
}

# call to start a series of encryption/decryption operations
sub start (\$$) {
    my $self = shift;
    my $operation = shift;
    croak "Specify <e>ncryption or <d>ecryption" unless $operation=~/^[ed]/i;

    delete $self->{'civ'};
    $self->{'buffer'} = '';
    $self->{'decrypt'} = $operation=~/^d/i;
    $self->_deprecation_warning;
}

sub chain_mode { shift->{chain_mode} || 'cbc' }

sub chaining_method {
    my $self    = shift;
    my $decrypt = shift;

    # memoize this result
    return $self->{chaining_method}{$decrypt} 
           if exists $self->{chaining_method}{$decrypt};
    
    my $cm   = $self->chain_mode;
    my $code = $self->can($decrypt ? "_${cm}_decrypt" : "_${cm}_encrypt");
    croak "Chain mode $cm not supported" unless $code;
    return $self->{chaining_method}{$decrypt} = $code;
}

# call to encrypt/decrypt a bit of data
sub crypt (\$$){
    my $self = shift;
    my $data = shift;

    my $result;

    croak "crypt() called without a preceding start()"
      unless exists $self->{'buffer'};

    my $d = $self->{'decrypt'};

    unless ($self->{civ}) { # block cipher has not yet been initialized
      $result = $self->_generate_iv_and_cipher_from_datastream(\$data)      if $d;
      $result = $self->_generate_iv_and_cipher_from_options()           unless $d;
    }

    my $iv = $self->{'civ'};
    $self->{'buffer'} .= $data;

    my $bs = $self->{'blocksize'};

    croak "When using no padding, plaintext size must be a multiple of $bs"
	if $self->_needs_padding
	and $self->{'padding'} eq \&_no_padding
	and length($data) % $bs;

    croak "When using rijndael_compat padding, plaintext size must be a multiple of $bs"
	if $self->_needs_padding
	and $self->{'padding'} eq \&_rijndael_compat
	and length($data) % $bs;

    return $result unless (length($self->{'buffer'}) >= $bs);

    my @blocks     = unpack("(a$bs)*",$self->{buffer});
    $self->{buffer} = '';
    
    # if decrypting, leave the last block in the buffer for padding
    if ($d) {
	$self->{buffer} = pop @blocks;
    } else {
	$self->{buffer} = pop @blocks if length $blocks[-1] < $bs;
    }

    my $code = $self->chaining_method($d);
    #    $self->$code($self->{crypt},\$iv,\$result,\@blocks);
    # calling the code sub directly is slightly faster for some reason
    $code->($self,$self->{crypt},\$iv,\$result,\@blocks);

    $self->{'civ'} = $iv;	        # remember the iv
    return $result;
}

# this is called at the end to flush whatever's left
sub finish (\$) {
    my $self = shift;
    my $bs    = $self->{'blocksize'};

    my $block    = $self->{buffer};  # what's left

    # Special case hack for backward compatibility with Crypt::Rijndael's CBC_MODE.
    if (length $block == 0 && $self->{padding} eq \&_rijndael_compat) {
	delete $self->{'civ'};
	delete $self->{'buffer'};
	return '';
    }
	
    $self->{civ} ||= '';
    my $iv    = $self->{civ};
    my $code = $self->chaining_method($self->{decrypt});
    
    my $result = '';
    if ($self->{decrypt}) {
	$self->$code($self->{crypt},\$iv,\$result,[$block]);
	$result = $self->{padding}->($result,$bs,'d')        if $self->_needs_padding;
    } else {
	$block = $self->{padding}->($block,$bs,'e')          if $self->_needs_padding;
	$self->$code($self->{crypt},\$iv,\$result,[$block])  unless length $block==0 && !$self->_needs_padding
    }
        
    delete $self->{'civ'};
    delete $self->{'buffer'};
    return $result;
}

############# Move the boring new() argument processing here #######
sub _get_options {
    my $class    = shift;
    
    my $options = {};
    
    # hashref arguments
    if (ref $_[0] eq 'HASH') {
      $options = shift;
    }

    # CGI style arguments
    elsif ($_[0] =~ /^-[a-zA-Z_]{1,20}$/) {
      my %tmp = @_;
      while ( my($key,$value) = each %tmp) {
	$key =~ s/^-//;
	$options->{lc $key} = $value;
      }
    }

    else {
	$options->{key}    = shift;
	$options->{cipher} = shift;
    }
    return $options;
}

sub _get_cipher_obj {
    my $class = shift;
    my $options = shift;

    my $cipher = $options->{cipher};
    $cipher = 'Crypt::Cipher::AES' unless $cipher;

    unless (ref $cipher) {  # munge the class name if no object passed
      $cipher = $cipher=~/^Crypt::/ ? $cipher : "Crypt::$cipher";
      $cipher->can('encrypt') or eval "require $cipher; 1" or croak "Couldn't load $cipher: $@";
      # some crypt modules use the class Crypt::, and others don't
      $cipher =~ s/^Crypt::// unless $cipher->can('keysize');
    }

    return $cipher;
}

sub _validate_options {
    my $self    = shift;
    my $options = shift;
    my %valid_options = map {$_=>1} @valid_options;
    for my $o (keys %$options) {
	die "'$o' is not a recognized argument" unless $valid_options{$o};
    }
    return 1;
}

sub _get_header_mode {
    my $class = shift;
    my $options = shift;

    # header mode checking
    my %valid_modes = map {$_=>1} qw(none salt randomiv);
    my $header_mode     = $options->{header};
    $header_mode      ||= 'none'     if exists $options->{prepend_iv}  && !$options->{prepend_iv};
    $header_mode      ||= 'none'     if exists $options->{add_header}  && !$options->{add_header};
    $header_mode      ||= 'none'     if $options->{literal_key}        || (exists $options->{pbkdf} && $options->{pbkdf} eq 'none');
    $header_mode      ||= 'salt';    # default
    croak "Invalid -header mode '$header_mode'" unless $valid_modes{$header_mode};

    return $header_mode;
}

sub _get_padding_mode {
    my $class = shift;
    my ($bs,$options) = @_;

    my $padding     = $options->{padding} || 'standard';

    if ($padding && ref($padding) eq 'CODE') {
	# check to see that this code does its padding correctly
	for my $i (1..$bs-1) {
	  my $rbs = length($padding->(" "x$i,$bs,'e'));
	  croak "padding method callback does not behave properly: expected $bs bytes back, got $rbs bytes back." 
	      unless ($rbs == $bs);
	}
    } else {
	$padding = $padding eq 'none'     ? \&_no_padding
	    :$padding eq 'null'           ? \&_null_padding
	    :$padding eq 'space'          ? \&_space_padding
	    :$padding eq 'oneandzeroes'   ? \&_oneandzeroes_padding
	    :$padding eq 'rijndael_compat'? \&_rijndael_compat
	    :$padding eq 'standard'       ? \&_standard_padding
	    :croak "'$padding' padding not supported.  See perldoc Crypt::CBC for instructions on creating your own.";
    }
    return $padding;
}

sub _get_key_and_block_sizes {
    my $class = shift;
    my $cipher  = shift;
    my $options = shift;
    
    # allow user to override the keysize value
    my $ks = $options->{keysize} || eval {$cipher->keysize} || eval {$cipher->max_keysize}
             or croak "Cannot derive keysize from $cipher";

    my $bs = eval {$cipher->blocksize}
             or croak "$cipher did not provide a blocksize";

    return ($ks,$bs);
}

sub _get_key_materials {
    my $self = shift;
    my $options = shift;

    # "key" is a misnomer here, because it is actually usually a passphrase that is used
    # to derive the true key
    my $pass = $options->{pass} || $options->{key};

    my $cipher_object_provided = $options->{cipher} && ref $options->{cipher};
    if ($cipher_object_provided) {
      carp "Both a key and a pre-initialized Crypt::* object were passed. The key will be ignored"
	if defined $pass;
      $pass ||= '';
    }

    croak "Please provide an encryption/decryption passphrase using -pass or -key"
	unless defined $pass;

    # Default behavior is to treat -key as a passphrase.
    # But if the literal_key option is true, then use key as is
    croak "The options -literal_key and -regenerate_key are incompatible with each other" 
	if exists $options->{literal_key} && exists $options->{regenerate_key};

    my $key  = $pass if $options->{literal_key};
    $key     = $pass if exists $options->{regenerate_key} && !$options->{regenerate_key};

    # Get the salt.
    my $salt        = $options->{salt};
    my $random_salt = 1 unless defined $salt && $salt ne '1';
    croak "Argument to -salt must be exactly 8 bytes long" if defined $salt && length $salt != 8 && $salt ne '1';

    # note: iv will be autogenerated by start() if not specified in options
    my $iv        = $options->{iv};
    my $random_iv = 1 unless defined $iv;

    my $literal_key = $options->{literal_key} || (exists $options->{regenerate_key} && !$options->{regenerate_key});
    undef $pass     if $literal_key;

    return ($pass,$iv,$salt,$key,$random_salt,$random_iv);
}

sub _get_key_derivation_options {
    my $self    = shift;
    my ($options,$header_mode) = @_;
    
    # KEY DERIVATION PARAMETERS
    # Some special cases here
    # 1. literal key has been requested - use algorithm 'none'
    # 2. headerless mode - use algorithm 'none'
    # 3. randomiv header - use algorithm 'nosalt'
    my $pbkdf = $options->{pbkdf} || ($options->{literal_key}     ? 'none'
				      :$header_mode eq 'randomiv' ? 'randomiv'
				      :DEFAULT_PBKDF);
    # iterations
    my $iter = $options->{iter} || DEFAULT_ITER;
    $iter =~ /[\d_]+/ && $iter >= 1 or croak "-iterations argument must be greater than or equal to 1";
    $iter =~ /[\d_]+/ && $iter >= 1 or croak "-iterations argument must be greater than or equal to 1";

    # hasher
    my $hc = $options->{hasher};
    my $nodeprecate = $options->{nodeprecate};
    
    return ($pbkdf,$iter,$hc,$nodeprecate);
}

sub _get_chain_mode {
    my $self = shift;
    my $options = shift;
    return $options->{chain_mode} ? $options->{chain_mode}
          :$options->{pcbc}       ? 'pcbc'
	  :'cbc';
}

sub _load_module {
    my $self   = shift;
    my ($module,$args) = @_;
    my $result = eval "use $module $args; 1;";
    warn $@ if $@;
    return $result;
}

sub _deprecation_warning {
    my $self = shift;
    return if $self->nodeprecate;
    return if $self->{decrypt};
    my $pbkdf = $self->pbkdf;
    carp <<END if $pbkdf =~ /^(opensslv1|randomiv)$/;
WARNING: The key derivation method "$pbkdf" is deprecated. Using -pbkdf=>'pbkdf2' would be better.
Pass -nodeprecate=>1 to inhibit this message.
END


}

######################################### chaining mode methods ################################3
sub _needs_padding {
    my $self = shift;
    $self->chain_mode =~ /^p?cbc$/ && $self->padding ne \&_no_padding;
}

sub _cbc_encrypt {
    my $self = shift;
    my ($crypt,$iv,$result,$blocks) = @_;
    # the copying looks silly, but it is slightly faster than dereferencing the
    # variables each time
    my ($i,$r) = ($$iv,$$result);
    foreach (@$blocks) {
	$r .= $i = $crypt->encrypt($i ^ $_);
    }
    ($$iv,$$result) = ($i,$r);
}

sub _cbc_decrypt {
    my $self = shift;
    my ($crypt,$iv,$result,$blocks) = @_;
    # the copying looks silly, but it is slightly faster than dereferencing the
    # variables each time
    my ($i,$r) = ($$iv,$$result);
    foreach (@$blocks) {
	$r    .= $i ^ $crypt->decrypt($_);
	$i     = $_;
    }
    ($$iv,$$result) = ($i,$r);
}

sub _pcbc_encrypt {
    my $self = shift;
    my ($crypt,$iv,$result,$blocks) = @_;
    foreach my $plaintext (@$blocks) {
	$$result .= $$iv = $crypt->encrypt($$iv ^ $plaintext);
	$$iv     ^= $plaintext;
    }
}

sub _pcbc_decrypt {
    my $self = shift;
    my ($crypt,$iv,$result,$blocks) = @_;
    foreach my $ciphertext (@$blocks) {
	$$result .= $$iv = $$iv ^ $crypt->decrypt($ciphertext);
	$$iv ^= $ciphertext;
    }
}

sub _cfb_encrypt {
    my $self = shift;
    my ($crypt,$iv,$result,$blocks) = @_;
    my ($i,$r) = ($$iv,$$result);
    foreach my $plaintext (@$blocks) {
	$r .= $i = $plaintext ^ $crypt->encrypt($i) 
    }
    ($$iv,$$result) = ($i,$r);
}

sub _cfb_decrypt {
    my $self = shift;
    my ($crypt,$iv,$result,$blocks) = @_;
    my ($i,$r) = ($$iv,$$result);
    foreach my $ciphertext (@$blocks) {
	$r .= $ciphertext ^ $crypt->encrypt($i);
	$i      = $ciphertext;
    }
    ($$iv,$$result) = ($i,$r);
}

sub _ofb_encrypt {
    my $self = shift;
    my ($crypt,$iv,$result,$blocks) = @_;
    my ($i,$r) = ($$iv,$$result);
    foreach my $plaintext (@$blocks) {
	my $ciphertext = $plaintext ^ ($i = $crypt->encrypt($i));
	substr($ciphertext,length $plaintext) = '';  # truncate
	$r .= $ciphertext;
    }
    ($$iv,$$result) = ($i,$r);    
}

*_ofb_decrypt = \&_ofb_encrypt;  # same code

# According to RFC3686, the counter is 128 bits (16 bytes)
# The first 32 bits (4 bytes) is the nonce
# The next  64 bits (8 bytes) is the IV
# The final 32 bits (4 bytes) is the counter, starting at 1
# BUT, the way that openssl v1.1.1 does it is to generate a random
# IV, treat the whole thing as a blocksize-sized integer, and then
# increment.
sub _ctr_encrypt {
    my $self = shift;
    my ($crypt,$iv,$result,$blocks) = @_;
    my $bs = $self->blocksize;
	
    $self->_upgrade_iv_to_ctr($iv);
    my ($i,$r) = ($$iv,$$result);

    foreach my $plaintext (@$blocks) {
	my $bytes = int128_to_net($i++);

	# pad with leading nulls if there are insufficient bytes
	# (there's gotta be a better way to do this)
	if ($bs > length $bytes) {
	    substr($bytes,0,0) = "\000"x($bs-length $bytes) ;
	}

	my $ciphertext = $plaintext ^ ($crypt->encrypt($bytes));
	substr($ciphertext,length $plaintext) = '';  # truncate
	$r      .= $ciphertext;
    }
    ($$iv,$$result) = ($i,$r);
}

*_ctr_decrypt = \&_ctr_encrypt; # same code

# upgrades instance vector to a CTR counter
# returns 1 if upgrade performed
sub _upgrade_iv_to_ctr {
    my $self = shift;
    my $iv   = shift;  # this is a scalar reference
    return if ref $$iv; # already upgraded to an object

    $self->_load_module("Math::Int128" => "'net_to_int128','int128_to_net'")
	or croak "Optional Math::Int128 module must be installed to use the CTR chaining method";

    $$iv  = net_to_int128($$iv);
    return 1;
}

######################################### chaining mode methods ################################3

sub pbkdf { shift->{pbkdf} }

# get the initialized PBKDF object
sub pbkdf_obj {
    my $self  = shift;
    my $pbkdf = $self->pbkdf;
    my $iter  = $self->{iter};
    my $hc    = $self->{hasher};
    my @hash_args = $hc ? ref ($hc) ? (hasher => $hc) : (hash_class => $hc)
	                : ();
    return Crypt::CBC::PBKDF->new($pbkdf => 
				  {
				      key_len    => $self->{keysize},
				      iv_len     => $self->{blocksize},
				      iterations => $iter,
				      @hash_args,
				  }
	);
}

############################# generating key, iv and salt ########################
# hopefully a replacement for mess below
sub set_key_and_iv {
    my $self = shift;

    if (!$self->{literal_key}) {
	my ($key,$iv) = $self->pbkdf_obj->key_and_iv($self->{salt},$self->{passphrase});
	$self->{key} = $key;
	$self->{iv}  = $iv if $self->{make_random_iv}; 
    } else {
	$self->{iv} = $self->_get_random_bytes($self->blocksize) if $self->{make_random_iv};
    }

    length $self->{salt} == 8                  or croak "Salt must be exactly 8 bytes long";
    length $self->{iv}   == $self->{blocksize} or croak "IV must be exactly $self->{blocksize} bytes long";
}

# derive the salt, iv and key from the datastream header + passphrase
sub _read_key_and_iv {
    my $self = shift;
    my $input_stream = shift;
    my $bs           = $self->blocksize;

    # use our header mode to figure out what to do with the data stream
    my $header_mode = $self->header_mode;

    if ($header_mode eq 'none') {
	$self->{salt} ||= $self->_get_random_bytes(8);
	return $self->set_key_and_iv;
    }

    elsif ($header_mode eq 'salt') {
	($self->{salt}) = $$input_stream =~ /^Salted__(.{8})/s;
	croak "Ciphertext does not begin with a valid header for 'salt' header mode" unless defined $self->{salt};
	substr($$input_stream,0,16) = '';
	my ($k,$i) = $self->pbkdf_obj->key_and_iv($self->{salt},$self->{passphrase});
	$self->{key} = $k unless $self->{literal_key};
	$self->{iv}  = $i unless $self->{literal_iv};
    }

    elsif ($header_mode eq 'randomiv') {
	($self->{iv}) = $$input_stream =~ /^RandomIV(.{8})/s;
	croak "Ciphertext does not begin with a valid header for 'randomiv' header mode" unless defined $self->{iv};
	croak "randomiv header mode cannot be used securely when decrypting with a >8 byte block cipher.\n"
	    unless $self->blocksize == 8;
	(undef,$self->{key}) = $self->pbkdf_obj->key_and_iv(undef,$self->{passphrase});
	substr($$input_stream,0,16) = ''; # truncate
    }

    else {
	croak "Invalid header mode '$header_mode'";
    }
}

# this subroutine will generate the actual {en,de}cryption key, the iv
# and the block cipher object.  This is called when reading from a datastream
# and so it uses previous values of salt or iv if they are encoded in datastream
# header
sub _generate_iv_and_cipher_from_datastream {
  my $self         = shift;
  my $input_stream = shift;

  $self->_read_key_and_iv($input_stream);
  $self->{civ}   = $self->{iv};
  
  # we should have the key and iv now, or we are dead in the water
  croak "Could not derive key or iv from cipher stream, and you did not specify these values in new()"
    unless $self->{key} && $self->{civ};

  # now we can generate the crypt object itself
  $self->{crypt} = ref $self->{cipher} ? $self->{cipher}
                                       : $self->{cipher}->new($self->{key})
					 or croak "Could not create $self->{cipher} object: $@";
  return '';
}

sub _generate_iv_and_cipher_from_options {
    my $self   = shift;

    $self->{salt}   = $self->_get_random_bytes(8) if $self->{make_random_salt};
    $self->set_key_and_iv;
    $self->{civ}   = $self->{iv};

    my $result = '';
    my $header_mode = $self->header_mode;
    
    if ($header_mode eq 'salt') {
	$result  = "Salted__$self->{salt}";
    }

    elsif ($header_mode eq 'randomiv') {
	$result = "RandomIV$self->{iv}";
	undef $self->{salt}; # shouldn't be there!
    }

    croak "key and/or iv are missing" unless defined $self->{key} && defined $self->{civ};

    $self->_taintcheck($self->{key});
    $self->{crypt} = ref $self->{cipher} ? $self->{cipher}
                                         : $self->{cipher}->new($self->{key})
  					   or croak "Could not create $self->{cipher} object: $@";
  return $result;
}

sub _taintcheck {
    my $self = shift;
    my $key  = shift;
    return unless ${^TAINT};

    my $has_scalar_util = eval "require Scalar::Util; 1";
    my $tainted;


    if ($has_scalar_util) {
	$tainted = Scalar::Util::tainted($key);
    } else {
	local($@, $SIG{__DIE__}, $SIG{__WARN__});
	local $^W = 0;
	eval { kill 0 * $key };
	$tainted = $@ =~ /^Insecure/;
    }

    croak "Taint checks are turned on and your key is tainted. Please untaint the key and try again"
	if $tainted;
}

sub _digest_obj {
    my $self = shift;

    if ($self->{digest_obj}) {
	$self->{digest_obj}->reset();
	return $self->{digest_obj};
    }

    my $alg  = $self->{digest_alg};
    return $alg if ref $alg && $alg->can('digest');
    my $obj  = eval {Digest->new($alg)};
    croak "Unable to instantiate '$alg' digest object: $@" if $@;

    return $self->{digest_obj} = $obj;
}

sub random_bytes {
  my $self  = shift;
  my $bytes = shift or croak "usage: random_bytes(\$byte_length)";
  $self->_get_random_bytes($bytes);
}

sub _get_random_bytes {
  my $self   = shift;
  my $length = shift;
  my $result;

  if (-r RANDOM_DEVICE && open(F,RANDOM_DEVICE)) {
    read(F,$result,$length);
    close F;
  } else {
    $result = pack("C*",map {rand(256)} 1..$length);
  }
  # Clear taint and check length
  $result =~ /^(.+)$/s;
  length($1) == $length or croak "Invalid length while gathering $length random bytes";
  return $1;
}

sub _standard_padding ($$$) {
  my ($b,$bs,$decrypt) = @_;

  if ($decrypt eq 'd') {
    my $pad_length = unpack("C",substr($b,-1));
    return substr($b,0,$bs-$pad_length);
  }
  my $pad = $bs - length($b);
  return $b . pack("C*",($pad)x$pad);
}

sub _space_padding ($$$) {
    my ($b,$bs,$decrypt) = @_;

    if ($decrypt eq 'd') {
	$b=~ s/ *\z//s;
    } else {
	$b .= pack("C*", (32) x ($bs-length($b)));
    }
    return $b;
}

sub _no_padding ($$$) {
  my ($b,$bs,$decrypt) = @_;
  return $b;
}

sub _null_padding ($$$) {
  my ($b,$bs,$decrypt) = @_;
  return unless length $b;
  $b = length $b ? $b : '';
  if ($decrypt eq 'd') {
     $b=~ s/\0*\z//s;
     return $b;
  }
  return $b . pack("C*", (0) x ($bs - length($b) % $bs));
}

sub _oneandzeroes_padding ($$$) {
  my ($b,$bs,$decrypt) = @_;
  if ($decrypt eq 'd') {
     $b=~ s/\x80\0*\z//s;
     return $b;
  }
  return $b . pack("C*", 128, (0) x ($bs - length($b) - 1) );
}

sub _rijndael_compat ($$$) {
  my ($b,$bs,$decrypt) = @_;

  return unless length $b;
  if ($decrypt eq 'd') {
     $b=~ s/\x80\0*\z//s;
     return $b;
  }
  return $b . pack("C*", 128, (0) x ($bs - length($b) % $bs - 1) );
}

sub get_initialization_vector (\$) {
  my $self = shift;
  $self->iv();
}

sub set_initialization_vector (\$$) {
  my $self = shift;
  my $iv   = shift;
  my $bs   = $self->blocksize;
  croak "Initialization vector must be $bs bytes in length" unless length($iv) == $bs;
  $self->iv($iv);
}

sub salt {
  my $self = shift;
  my $d    = $self->{salt};
  $self->{salt} = shift if @_;
  $d;
}

sub iv {
  my $self = shift;
  my $d    = $self->{iv};
  $self->{iv} = shift if @_;
  $d;
}

sub key {
  my $self = shift;
  my $d    = $self->{key};
  $self->{key} = shift if @_;
  $d;
}

sub passphrase {
  my $self = shift;
  my $d    = $self->{passphrase};
  if (@_) {
    undef $self->{key};
    undef $self->{iv};
    $self->{passphrase} = shift;
  }
  $d;
}

sub keysize   {
    my $self = shift;
    $self->{keysize} = shift if @_;
    $self->{keysize};
}

sub cipher    { shift->{cipher}    }
sub padding   { shift->{padding}   }
sub blocksize { shift->{blocksize} }
sub pcbc      { shift->{pcbc}      }
sub header_mode {shift->{header_mode} }
sub literal_key {shift->{literal_key}}
sub nodeprecate {shift->{nodeprecate}}
		
1;
__END__

=head1 NAME

Crypt::CBC - Encrypt Data with Cipher Block Chaining Mode

=head1 SYNOPSIS

  use Crypt::CBC;
  $cipher = Crypt::CBC->new( -pass   => 'my secret password',
			     -cipher => 'Cipher::AES'
			    );

  # one shot mode
  $ciphertext = $cipher->encrypt("This data is hush hush");
  $plaintext  = $cipher->decrypt($ciphertext);

  # stream mode
  $cipher->start('encrypting');
  open(F,"./BIG_FILE");
  while (read(F,$buffer,1024)) {
      print $cipher->crypt($buffer);
  }
  print $cipher->finish;

  # do-it-yourself mode -- specify key && initialization vector yourself
  $key    = Crypt::CBC->random_bytes(8);  # assuming a 8-byte block cipher
  $iv     = Crypt::CBC->random_bytes(8);
  $cipher = Crypt::CBC->new(-pbkdf       => 'none',
                            -key         => $key,
                            -iv          => $iv);

  $ciphertext = $cipher->encrypt("This data is hush hush");
  $plaintext  = $cipher->decrypt($ciphertext);

  # encrypting via a filehandle (requires Crypt::FileHandle>
  $fh = Crypt::CBC->filehandle(-pass => 'secret');
  open $fh,'>','encrypted.txt" or die $!
  print $fh "This will be encrypted\n";
  close $fh;

=head1 DESCRIPTION

This module is a Perl-only implementation of the cryptographic cipher
block chaining mode (CBC).  In combination with a block cipher such as
AES or Blowfish, you can encrypt and decrypt messages of arbitrarily
long length.  The encrypted messages are compatible with the
encryption format used by the B<OpenSSL> package.

To use this module, you will first create a Crypt::CBC cipher object
with new().  At the time of cipher creation, you specify an encryption
key to use and, optionally, a block encryption algorithm.  You will
then call the start() method to initialize the encryption or
decryption process, crypt() to encrypt or decrypt one or more blocks
of data, and lastly finish(), to pad and encrypt the final block.  For
your convenience, you can call the encrypt() and decrypt() methods to
operate on a whole data value at once.

=head2 new()

  $cipher = Crypt::CBC->new( -pass   => 'my secret key',
			     -cipher => 'Cipher::AES',
			   );

  # or (for compatibility with versions prior to 2.0)
  $cipher = new Crypt::CBC('my secret key' => 'Cipher::AES');

The new() method creates a new Crypt::CBC object. It accepts a list of
-argument => value pairs selected from the following list:

  Argument        Description
  --------        -----------

  -pass,-key      The encryption/decryption passphrase. These arguments
                     are interchangeable, but -pass is preferred
                     ("key" is a misnomer, as it is not the literal 
                     encryption key).

  -cipher         The cipher algorithm (defaults to Crypt::Cipher:AES), or
                     a previously created cipher object reference. For 
                     convenience, you may omit the initial "Crypt::" part
                     of the classname and use the basename, e.g. "Blowfish"
                     instead of "Crypt::Blowfish".

  -keysize        Force the cipher keysize to the indicated number of bytes. This can be used
                     to set the keysize for variable keylength ciphers such as AES.

  -chain_mode     The block chaining mode to use. Current options are:
                     'cbc'  -- cipher-block chaining mode [default]
                     'pcbc' -- plaintext cipher-block chaining mode
                     'cfb'  -- cipher feedback mode 
                     'ofb'  -- output feedback mode
                     'ctr'  -- counter mode

  -pbkdf         The passphrase-based key derivation function used to derive
                    the encryption key and initialization vector from the
                    provided passphrase. For backward compatibility, Crypt::CBC
                    will default to "opensslv1", but it is recommended to use
                    the standard "pbkdf2"algorithm instead. If you wish to interoperate
                    with OpenSSL, be aware that different versions of the software
                    support a series of derivation functions.

                    'none'       -- The value provided in -pass/-key is used directly.
                                      This is the same as passing true to -literal_key.
                                      You must also manually specify the IV with -iv.
                                      The key and the IV must match the keylength
                                      and blocklength of the chosen cipher.
                    'randomiv'   -- Use insecure key derivation method found
                                     in prehistoric versions of OpenSSL (dangerous)
                    'opensslv1'  -- [default] Use the salted MD5 method that was default
                                     in versions of OpenSSL through v1.0.2.
                    'opensslv2'  -- [better] Use the salted SHA-256 method that was
                                     the default in versions of OpenSSL through v1.1.0.
                    'pbkdf2'     -- [best] Use the PBKDF2 method that was first
                                     introduced in OpenSSL v1.1.1.

                     More derivation functions may be added in the future. To see the
                     supported list, use the command 
                       perl -MCrypt::CBC::PBKDF -e 'print join "\n",Crypt::CBC::PBKDF->list'

  -iter           If the 'pbkdf2' key derivation algorithm is used, this specifies the number of
                     hashing cycles to be applied to the passphrase+salt (longer is more secure).
                     [default 10,000] 

  -hasher         If the 'pbkdf2' key derivation algorithm is chosen, you can use this to provide
                     an initialized Crypt::PBKDF2::Hash object. 
                     [default HMACSHA2 for OpenSSL compatability]

  -header         What type of header to prepend to the ciphertext. One of
                    'salt'     -- use OpenSSL-compatible salted header (default)
                    'randomiv' -- Randomiv-compatible "RandomIV" header
                    'none'     -- prepend no header at all 
                                  (compatible with prehistoric versions
                                   of OpenSSL)

  -iv             The initialization vector (IV). If not provided, it will be generated
                      by the key derivation function.

  -salt           The salt passed to the key derivation function. If not provided, will be
                      generated randomly (recommended).

  -padding        The padding method, one of "standard" (default),
                     "space", "oneandzeroes", "rijndael_compat",
                     "null", or "none" (default "standard").

  -literal_key    [deprected, use -pbkdf=>'none']
                      If true, the key provided by "-key" or "-pass" is used 
                      directly for encryption/decryption without salting or
                      hashing. The key must be the right length for the chosen
                      cipher. 
                      [default false)

  -pcbc           [deprecated, use -chaining_mode=>'pcbc']
                    Whether to use the PCBC chaining algorithm rather than
                    the standard CBC algorithm (default false).

  -add_header     [deprecated; use -header instead]
                   Whether to add the salt and IV to the header of the output
                    cipher text.

  -regenerate_key [deprecated; use -literal_key instead]
                  Whether to use a hash of the provided key to generate
                    the actual encryption key (default true)

  -prepend_iv     [deprecated; use -header instead]
                  Whether to prepend the IV to the beginning of the
                    encrypted stream (default true)

Crypt::CBC requires three pieces of information to do its job. First
it needs the name of the block cipher algorithm that will encrypt or
decrypt the data in blocks of fixed length known as the cipher's
"blocksize." Second, it needs an encryption/decryption key to pass to
the block cipher. Third, it needs an initialization vector (IV) that
will be used to propagate information from one encrypted block to the
next. Both the key and the IV must be exactly the same length as the
chosen cipher's blocksize.

Crypt::CBC can derive the key and the IV from a passphrase that you
provide, or can let you specify the true key and IV manually. In
addition, you have the option of embedding enough information to
regenerate the IV in a short header that is emitted at the start of
the encrypted stream, or outputting a headerless encryption stream. In
the first case, Crypt::CBC will be able to decrypt the stream given
just the original key or passphrase. In the second case, you will have
to provide the original IV as well as the key/passphrase.

The B<-cipher> option specifies which block cipher algorithm to use to
encode each section of the message.  This argument is optional and
will default to the secure Crypt::Cipher::AES algorithm. 
You may use any compatible block encryption
algorithm that you have installed. Currently, this includes
Crypt::Cipher::AES, Crypt::DES, Crypt::DES_EDE3, Crypt::IDEA, Crypt::Blowfish,
Crypt::CAST5 and Crypt::Rijndael. You may refer to them using their
full names ("Crypt::IDEA") or in abbreviated form ("IDEA").

Instead of passing the name of a cipher class, you may pass an
already-created block cipher object. This allows you to take advantage
of cipher algorithms that have parameterized new() methods, such as
Crypt::Eksblowfish:

  my $eksblowfish = Crypt::Eksblowfish->new(8,$salt,$key);
  my $cbc         = Crypt::CBC->new(-cipher=>$eksblowfish);

The B<-pass> argument provides a passphrase to use to generate the
encryption key or the literal value of the block cipher key. If used
in passphrase mode (which is the default), B<-pass> can be any number
of characters; the actual key will be derived by passing the
passphrase through a series of hashing operations. To take full
advantage of a given block cipher, the length of the passphrase should
be at least equal to the cipher's blocksize. For backward
compatibility, you may also refer to this argument using B<-key>.

To skip this hashing operation and specify the key directly, provide
the actual key as a string to B<-key> and specify a key derivation
function of "none" to the B<-pbkdf> argument. Alternatively, you may
pass a true value to the B<-literal_key> argument. When you manually
specify the key in this way, should choose a key of length exactly
equal to the cipher's key length. You will also have to specify an IV
equal in length to the cipher's blocksize. These choices imply a
header mode of "none."

If you pass an existing Crypt::* object to new(), then the
B<-pass>/B<-key> argument is ignored and the module will generate a
warning.

The B<-pbkdf> argument specifies the algorithm used to derive the true
key and IV from the provided passphrase (PBKDF stands for
"passphrase-based key derivation function"). Valid values are:

   "opensslv1" -- [default] A fast algorithm that derives the key by 
                  combining a random salt values with the passphrase via
                  a series of MD5 hashes.

   "opensslv2" -- an improved version that uses SHA-256 rather
                  than MD5, and has been OpenSSL's default since v1.1.0. 
                  However, it has been deprecated in favor of pbkdf2 
                  since OpenSSL v1.1.1.

   "pbkdf2"    -- a better algorithm implemented in OpenSSL v1.1.1,
                  described in RFC 2898 L<https://tools.ietf.org/html/rfc2898>

   "none"      -- don't use a derivation function, but treat the passphrase
                  as the literal key. This is the same as B<-literal_key> true.

   "nosalt"    -- an insecure key derivation method used by prehistoric versions
                  of OpenSSL, provided for backward compatibility. Don't use.

"opensslv1" was OpenSSL's default key derivation algorithm through
version 1.0.2, but is susceptible to dictionary attacks and is no
longer supported. It remains the default for Crypt::CBC in order to
avoid breaking compatibility with previously-encrypted messages. Using
this option will issue a deprecation warning when initiating
encryption. You can suppress the warning by passing a true value to
the B<-nodeprecate> option.

It is recommended to specify the "pbkdf2" key derivation algorithm
when compatibility with older versions of Crypt::CBC is not
needed. This algorithm is deliberately computationally expensive in
order to make dictionary-based attacks harder. As a result, it
introduces a slight delay before an encryption or decryption
operation starts.

The B<-iter> argument is used in conjunction with the "pbkdf2" key
derivation option. Its value indicates the number of hashing cycles
used to derive the key. Larger values are more secure, but impose a
longer delay before encryption/decryption starts. The default is
10,000 for compatibility with OpenSSL's default.

The B<-hasher> argument is used in conjunction with the "pbkdf2" key
derivation option to pass the reference to an initialized
Crypt::PBKDF2::Hash object. If not provided, it defaults to the
OpenSSL-compatible hash function HMACSHA2 initialized with its default
options (SHA-256 hash).

The B<-header> argument specifies what type of header, if any, to
prepend to the beginning of the encrypted data stream. The header
allows Crypt::CBC to regenerate the original IV and correctly decrypt
the data without your having to provide the same IV used to encrypt
the data. Valid values for the B<-header> are:

 "salt" -- Combine the passphrase with an 8-byte random value to
           generate both the block cipher key and the IV from the
           provided passphrase. The salt will be appended to the
           beginning of the data stream allowing decryption to
           regenerate both the key and IV given the correct passphrase.
           This method is compatible with current versions of OpenSSL.

 "randomiv" -- Generate the block cipher key from the passphrase, and
           choose a random 8-byte value to use as the IV. The IV will
           be prepended to the data stream. This method is compatible
           with ciphertext produced by versions of the library prior to
           2.17, but is incompatible with block ciphers that have non
           8-byte block sizes, such as Rijndael. Crypt::CBC will exit
           with a fatal error if you try to use this header mode with a
           non 8-byte cipher. This header type is NOT secure and NOT 
           recommended.

 "none"   -- Do not generate a header. To decrypt a stream encrypted
           in this way, you will have to provide the true key and IV
           manually.

B<The "salt" header is now the default as of Crypt::CBC version 2.17. In
all earlier versions "randomiv" was the default.>

When using a "salt" header, you may specify your own value of the
salt, by passing the desired 8-byte character string to the B<-salt>
argument. Otherwise, the module will generate a random salt for
you. Crypt::CBC will generate a fatal error if you specify a salt
value that isn't exactly 8 bytes long. For backward compatibility
reasons, passing a value of "1" will generate a random salt, the same
as if no B<-salt> argument was provided.

The B<-padding> argument controls how the last few bytes of the
encrypted stream are dealt with when they not an exact multiple of the
cipher block length. The default is "standard", the method specified
in PKCS#5.

The B<-chaining_mode> argument will select among several different
block chaining modes. Values are:

  'cbc'  -- [default] traditional Cipher-Block Chaining mode. It has
              the property that if one block in the ciphertext message
              is damaged, only that block and the next one will be
              rendered un-decryptable.

  'pcbc' -- Plaintext Cipher-Block Chaining mode. This has the property
              that one damaged ciphertext block will render the 
              remainder of the message unreadable

  'cfb'  -- Cipher Feedback Mode. In this mode, both encryption and decryption
              are performed using the block cipher's "encrypt" algorithm.
              The error propagation behaviour is similar to CBC's.

  'ofb'  -- Output Feedback Mode. Similar to CFB, the block cipher's encrypt
              algorithm is used for both encryption and decryption. If one bit
              of the plaintext or ciphertext message is damaged, the damage is
              confined to a single block of the corresponding ciphertext or 
              plaintext, and error correction algorithms can be used to reconstruct
              the damaged part.

   'ctr' -- Counter Mode. This mode uses a one-time "nonce" instead of
              an IV. The nonce is incremented by one for each block of
              plain or ciphertext, encrypted using the chosen
              algorithm, and then applied to the block of text. If one
              bit of the input text is damaged, it only affects 1 bit
              of the output text. To use CTR mode you will need to
              install the Perl Math::Int128 module. This chaining method
              is roughly half the speed of the others due to integer
              arithmetic.

Passing a B<-pcbc> argument of true will have the same effect as
-chaining_mode=>'pcbc', and is included for backward
compatibility. [deprecated].

For more information on chaining modes, see
L<http://www.crypto-it.net/eng/theory/modes-of-block-ciphers.html>.

The B<-keysize> argument can be used to force the cipher's
keysize. This is useful for several of the newer algorithms, including
AES, ARIA, Blowfish, and CAMELLIA. If -keysize is not specified, then
Crypt::CBC will use the value returned by the cipher's max_keylength()
method. Note that versions of CBC::Crypt prior to 2.36 could also
allow you to set the blocksie, but this was never supported by any
ciphers and has been removed.

For compatibility with earlier versions of this module, you can
provide new() with a hashref containing key/value pairs. The key names
are the same as the arguments described earlier, but without the
initial hyphen.  You may also call new() with one or two positional
arguments, in which case the first argument is taken to be the key and
the second to be the optional block cipher algorithm.


=head2 start()

   $cipher->start('encrypting');
   $cipher->start('decrypting');

The start() method prepares the cipher for a series of encryption or
decryption steps, resetting the internal state of the cipher if
necessary.  You must provide a string indicating whether you wish to
encrypt or decrypt.  "E" or any word that begins with an "e" indicates
encryption.  "D" or any word that begins with a "d" indicates
decryption.

=head2 crypt()

   $ciphertext = $cipher->crypt($plaintext);

After calling start(), you should call crypt() as many times as
necessary to encrypt the desired data.  

=head2  finish()

   $ciphertext = $cipher->finish();

The CBC algorithm must buffer data blocks internally until they are
even multiples of the encryption algorithm's blocksize (typically 8
bytes).  After the last call to crypt() you should call finish().
This flushes the internal buffer and returns any leftover ciphertext.

In a typical application you will read the plaintext from a file or
input stream and write the result to standard output in a loop that
might look like this:

  $cipher = new Crypt::CBC('hey jude!');
  $cipher->start('encrypting');
  print $cipher->crypt($_) while <>;
  print $cipher->finish();

=head2 encrypt()

  $ciphertext = $cipher->encrypt($plaintext)

This convenience function runs the entire sequence of start(), crypt()
and finish() for you, processing the provided plaintext and returning
the corresponding ciphertext.

=head2 decrypt()

  $plaintext = $cipher->decrypt($ciphertext)

This convenience function runs the entire sequence of start(), crypt()
and finish() for you, processing the provided ciphertext and returning
the corresponding plaintext.

=head2 encrypt_hex(), decrypt_hex()

  $ciphertext = $cipher->encrypt_hex($plaintext)
  $plaintext  = $cipher->decrypt_hex($ciphertext)

These are convenience functions that operate on ciphertext in a
hexadecimal representation.  B<encrypt_hex($plaintext)> is exactly
equivalent to B<unpack('H*',encrypt($plaintext))>.  These functions
can be useful if, for example, you wish to place the encrypted in an
email message.

=head2 filehandle()

This method returns a filehandle for transparent encryption or
decryption using Christopher Dunkle's excellent L<Crypt::FileHandle>
module. This module must be installed in order to use this method.

filehandle() can be called as a class method using the same arguments
as new():

  $fh = Crypt::CBC->filehandle(-cipher=> 'Blowfish',
                               -pass  => "You'll never guess");

or on a previously-created Crypt::CBC object:

   $cbc = Crypt::CBC->new(-cipher=> 'Blowfish',
                          -pass  => "You'll never guess");
   $fh  = $cbc->filehandle;

The filehandle can then be opened using the familiar open() syntax.
Printing to a filehandle opened for writing will encrypt the
data. Filehandles opened for input will be decrypted.

Here is an example:

  # transparent encryption
  open $fh,'>','encrypted.out' or die $!;
  print $fh "You won't be able to read me!\n";
  close $fh;

  # transparent decryption
  open $fh,'<','encrypted.out' or die $!;
  while (<$fh>) { print $_ }
  close $fh;

=head2 get_initialization_vector()

  $iv = $cipher->get_initialization_vector()

This function will return the IV used in encryption and or decryption.
The IV is not guaranteed to be set when encrypting until start() is
called, and when decrypting until crypt() is called the first
time. Unless the IV was manually specified in the new() call, the IV
will change with every complete encryption operation.

=head2 set_initialization_vector()

  $cipher->set_initialization_vector('76543210')

This function sets the IV used in encryption and/or decryption. This
function may be useful if the IV is not contained within the
ciphertext string being decrypted, or if a particular IV is desired
for encryption.  Note that the IV must match the chosen cipher's
blocksize bytes in length.

=head2 iv()

  $iv = $cipher->iv();
  $cipher->iv($new_iv);

As above, but using a single method call.

=head2 key()

  $key = $cipher->key();
  $cipher->key($new_key);

Get or set the block cipher key used for encryption/decryption.  When
encrypting, the key is not guaranteed to exist until start() is
called, and when decrypting, the key is not guaranteed to exist until
after the first call to crypt(). The key must match the length
required by the underlying block cipher.

When salted headers are used, the block cipher key will change after
each complete sequence of encryption operations.

=head2 salt()

  $salt = $cipher->salt();
  $cipher->salt($new_salt);

Get or set the salt used for deriving the encryption key and IV when
in OpenSSL compatibility mode.

=head2 passphrase()

  $passphrase = $cipher->passphrase();
  $cipher->passphrase($new_passphrase);

This gets or sets the value of the B<passphrase> passed to new() when
B<literal_key> is false.

=head2 $data = random_bytes($numbytes)

Return $numbytes worth of random data. On systems that support the
"/dev/urandom" device file, this data will be read from the
device. Otherwise, it will be generated by repeated calls to the Perl
rand() function.

=head2 cipher(), pbkdf(), padding(), keysize(), blocksize(), chain_mode() 

These read-only methods return the identity of the chosen block cipher
algorithm, the key derivation function (e.g. "opensslv1"), padding
method, key and block size of the chosen block cipher, and what
chaining mode ("cbc", "ofb" ,etc) is being used.

=head2 Padding methods

Use the 'padding' option to change the padding method.

When the last block of plaintext is shorter than the block size,
it must be padded. Padding methods include: "standard" (i.e., PKCS#5),
"oneandzeroes", "space", "rijndael_compat", "null", and "none".

   standard: (default) Binary safe
      pads with the number of bytes that should be truncated. So, if 
      blocksize is 8, then "0A0B0C" will be padded with "05", resulting
      in "0A0B0C0505050505". If the final block is a full block of 8 
      bytes, then a whole block of "0808080808080808" is appended.

   oneandzeroes: Binary safe
      pads with "80" followed by as many "00" necessary to fill the
      block. If the last block is a full block and blocksize is 8, a
      block of "8000000000000000" will be appended.

   rijndael_compat: Binary safe, with caveats
      similar to oneandzeroes, except that no padding is performed if
      the last block is a full block. This is provided for
      compatibility with Crypt::Rijndael's buit-in MODE_CBC. 
      Note that Crypt::Rijndael's implementation of CBC only
      works with messages that are even multiples of 16 bytes.

   null: text only
      pads with as many "00" necessary to fill the block. If the last 
      block is a full block and blocksize is 8, a block of
      "0000000000000000" will be appended.

   space: text only
      same as "null", but with "20".

   none:
      no padding added. Useful for special-purpose applications where
      you wish to add custom padding to the message.

Both the standard and oneandzeroes paddings are binary safe.  The
space and null paddings are recommended only for text data.  Which
type of padding you use depends on whether you wish to communicate
with an external (non Crypt::CBC library).  If this is the case, use
whatever padding method is compatible.

You can also pass in a custom padding function.  To do this, create a
function that takes the arguments:

   $padded_block = function($block,$blocksize,$direction);

where $block is the current block of data, $blocksize is the size to
pad it to, $direction is "e" for encrypting and "d" for decrypting,
and $padded_block is the result after padding or depadding.

When encrypting, the function should always return a string of
<blocksize> length, and when decrypting, can expect the string coming
in to always be that length. See _standard_padding(), _space_padding(),
_null_padding(), or _oneandzeroes_padding() in the source for examples.

Standard and oneandzeroes padding are recommended, as both space and
null padding can potentially truncate more characters than they should. 

=head1 Comparison to Crypt::Mode::CBC

The L<CryptX> modules L<Crypt::Mode::CBC>, L<Crypt::Mode::OFB>,
L<Crypt::Mode::CFB>, and L<Crypt::Mode::CTR> provide fast
implementations of the respective cipherblock chaining modes (roughly
5x the speed of Crypt::CBC). Crypt::CBC was designed to encrypt and
decrypt messages in a manner compatible with OpenSSL's "enc"
function. Hence it handles the derivation of the key and IV from a
passphrase using the same conventions as OpenSSL, and it writes out an
OpenSSL-compatible header in the encrypted message in a manner that
allows the key and IV to be regenerated during decryption.

In contrast, the CryptX modules do not automatically derive the key
and IV from a passphrase or write out an encrypted header. You will
need to derive and store the key and IV by other means (e.g. with
CryptX's Crypt::KeyDerivation module, or with Crypt::PBKDF2).

=head1 EXAMPLES

Three examples, aes.pl, des.pl and idea.pl can be found in the eg/
subdirectory of the Crypt-CBC distribution.  These implement
command-line DES and IDEA encryption algorithms using default
parameters, and should be compatible with recent versions of
OpenSSL. Note that aes.pl uses the "pbkdf2" key derivation function to
generate its keys. The other two were distributed with pre-PBKDF2
versions of Crypt::CBC, and use the older "opensslv1" algorithm.

=head1 LIMITATIONS

The encryption and decryption process is about a tenth the speed of
the equivalent OpenSSL tool and about a fifth of the Crypt::Mode::CBC
module (both which use compiled C).

=head1 BUGS

Please report them.

=head1 AUTHOR

Lincoln Stein, lstein@cshl.org

This module is distributed under the ARTISTIC LICENSE v2 using the
same terms as Perl itself.

=head1 SEE ALSO

perl(1), CryptX, Crypt::FileHandle, Crypt::Cipher::AES,
Crypt::Blowfish, Crypt::CAST5, Crypt::DES, Crypt::IDEA,
Crypt::Rijndael

=cut
