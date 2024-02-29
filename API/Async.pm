package Plugins::Deezer::API::Async;

use strict;
use base qw(Slim::Utils::Accessor);

use Async::Util;
use Data::URIEncode qw(complex_to_query);
use Date::Parse qw(str2time);
use MIME::Base64 qw(encode_base64);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min maxstr reduce);
use Digest::MD5 qw(md5_hex);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::Deezer::API qw(BURL GURL UURL DEFAULT_LIMIT MAX_LIMIT DEFAULT_TTL USER_CONTENT_TTL);

{
	__PACKAGE__->mk_accessor( rw => qw(
		client
		userId
	) );
}

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.deezer');
my $prefs = preferences('plugin.deezer');

my %apiClients;

sub new {
	my ($class, $args) = @_;

	if (!$args->{client} && !$args->{userId}) {
		return;
	}

	my $client = $args->{client};
	my $userId = $args->{userId} || $prefs->client($client)->get('userId') || return;

	if (my $apiClient = $apiClients{$userId}) {
		return $apiClient;
	}

	my $self = $apiClients{$userId} = $class->SUPER::new();
	$self->client($client);
	$self->userId($userId);

	return $self;
}

sub search {
	my ($self, $cb, $args) = @_;

	my $type = $args->{type} || '';
	$type = "/$type" if $type && $type !~ m{^/};

	# https://api.deezer.com/search/artist?q=toto&limit=50
	$self->_get('/search' . $type, sub {
		my $items = $_[0]->{data};
		$items = Plugins::Deezer::API->cacheTrackMetadata($items) if !$args->{type} || $args->{type} =~ /track/ ;
		
		# filter out empty responses
		$items = [ grep { $_->{nb_album} } @$items ] if $args->{type} =~ /artist/ ;
		$items = [ grep { $_->{nb_tracks} } @$items ] if $args->{type} =~ /album/ ;

		$cb->($items || []);
	}, {
		limit => $args->{limit},
		q => $args->{search},
		strict => $args->{strict} || 'off',
	});
}

sub track {
	my ($self, $cb, $id) = @_;

	$self->_get("/track/$id", sub {
		my $track = shift;

		($track) = @{ Plugins::Deezer::API->cacheTrackMetadata([$track]) } if $track;
		$cb->($track);
	});
}

sub artist {
	my ($self, $cb, $id) = @_;

	$self->_get("/artist/$id", sub {
		my $artist = $_[0] unless $_[0]->{error};
		$cb->($artist);
	});
}

sub artistAlbums {
	my ($self, $cb, $id) = @_;

	$self->_get("/artist/$id/albums", sub {
		my $albums = shift->{data};
		$cb->($albums || []);
	},{
		limit => MAX_LIMIT,
	});
}

sub artistTopTracks {
	my ($self, $cb, $id) = @_;

	$self->_get("/artist/$id/top", sub {
		my $artist = shift;
		my $tracks = Plugins::Deezer::API->cacheTrackMetadata($artist->{data}) if $artist;
		$cb->($tracks || []);
	},{
		limit => MAX_LIMIT,
	});
}

sub artistRelated {
	my ($self, $cb, $id) = @_;

	$self->_get("/artist/$id/related", sub {
		$cb->($_[0]->{data} || []);
	});
}

# try to remove duplicates 
# TODO review for Deezer
sub _filterAlbums {
	my ($albums) = shift || return;
	return $albums;

	my %seen;
	return [ grep {
		scalar (grep /^LOSSLESS$/, @{$_->{mediaMetadata}->{tags} || []}) && !$seen{$_->{fingerprint}}++
	} map { {
			%$_,
			fingerprint => join(':', $_->{artist}->{id}, $_->{title}, $_->{tracklist}),
	} } @$albums ];
}

sub radioTracks {
	my ($self, $cb, $path, $count) = @_;

	$self->_get("/$path", sub {
		my $radio = shift;		
		my $tracks = Plugins::Deezer::API->cacheTrackMetadata($radio->{data}) if $radio;
		$cb->($tracks || []);
	},{
		_nocache => 1,
		limit => $count || 1,
	});
}

sub compound {
	my ($self, $cb, $path) = @_;
	$self->_get("/$path", sub {
		my $compound = shift;
		my $items = {};
	
		foreach (keys %$compound) {
			$items->{$_} = $_ ne 'tracks' ? $compound->{$_}->{data} : Plugins::Deezer::API->cacheTrackMetadata($compound->{$_}->{data});
		}
		
		$cb->($items);
	});
}

sub albumTracks {
	my ($self, $cb, $id, $title) = @_;

	$self->_get("/album/$id/tracks", sub {
		my $album = shift;
		my $tracks = $album->{data} if $album;
		$tracks = Plugins::Deezer::API->cacheTrackMetadata($tracks, { album => $title }) if $tracks;

		$cb->($tracks || []);
	});
}

sub radios {
	my ($self, $cb) = @_;
	$self->_get('/radio', sub {
		$cb->($_[0]->{data} || []);
	});
}

sub genres {
	my ($self, $cb) = @_;
	$self->_get('/genre', sub {
		$cb->($_[0]->{data} || []);
	});
}

sub genreByType {
	my ($self, $cb, $id, $type) = @_;

	$self->_get("/genre/$id/$type", sub {
		$cb->($_[0]->{data} || []);
	});
}

sub moods {
	my ($self, $cb) = @_;
	$self->_get('/moods', $cb);
}

sub moodPlaylists {
	my ($self, $cb, $mood) = @_;

	$self->_get("/moods/$mood/playlists", sub {
		$cb->(@_);
	},{
		limit => MAX_LIMIT,
	});
}

sub playlist {
	my ($self, $cb, $id) = @_;

	$self->_get("/playlist/$id/tracks", sub {
		my $result = shift;

		my $items = Plugins::Deezer::API->cacheTrackMetadata([ grep {
			$_->{type} && $_->{type} eq 'track'
		} @{$result->{data} || []} ]) if $result;

		$cb->($items || []);
	},{
		limit => MAX_LIMIT,
	});
}

# User collections can be large - but have a known last updated timestamp.
# Instead of statically caching data, then re-fetch everything, do a quick
# lookup to get the latest timestamp first, then return from cache directly
# if the list hasn't changed, or look up afresh if needed.
sub getFavorites {
	my ($self, $cb, $type, $drill) = @_;

	return $cb->() unless $type;

	my $userId = $self->userId || return $cb->();
	my $cacheKey = "deezer_favs_$type:$userId";

	my $lookupSub = sub {
		my $checksum = shift;
		$self->_get("/user/me/$type", sub {
			my $result = shift;

			my $items = [ map { $_ } @{$result->{data} || []} ] if $result;
			$items = Plugins::Deezer::API->cacheTrackMetadata($items) if $items && $type eq 'tracks';

			$cache->set($cacheKey, {
				items => $items,
				checksum => $result->{checksum},
				timestamp => time(),
				total => $result->{total},
			}, '1M') if $items;

			$cb->($items);
		},{
			_ttl => USER_CONTENT_TTL,
			_nocache => 1,			
			limit => MAX_LIMIT,
		});
	};

	# use cached data unless the collection has changed
	my $cached = $cache->get($cacheKey);
	if ($cached && ref $cached->{items}) {
		# don't bother verifying checksum when drilling down
		return $cb->($cached->{items}) if $drill;
		
		$self->getCollectionChecksum(sub {
			my $fingerprint = shift;

			if ( (defined $fingerprint->{checksum} && $fingerprint->{checksum} eq $cached->{checksum}) || 
				 ($fingerprint->{time} < $cached->{timestamp} && $fingerprint->{total} == $cached->{total}) ) {
				main::INFOLOG && $log->is_info && $log->info("Collection of type '$type' has not changed - using cached results");
				$cb->($cached->{items});
			} 
			else {
				main::INFOLOG && $log->is_info && $log->info("Collection of type '$type' has changed - updating");
				$lookupSub->();				
			}
		}, $type);
	}
	else {
		$lookupSub->();
	}
}

sub getCollectionChecksum {
	my ($self, $cb, $type) = @_;

	my $userId = $self->userId || return $cb->();

	$self->_get("/user/me/$type", sub {
		my $result = shift;
		my $fingerprint = {
			checksum => $result->{checksum},
			time => $result->{data}->[0]->{time_add},
			total => $result->{total},
		};
		$cb->($fingerprint);
	},{
		limit => 1,
		order => 'ADD',
		_nocache => 1,
	});
}

sub getTrackUrl {
	my ($self, $cb, $id, $params) = @_;

	my $userId = $self->userId;

	_getUserContext( sub {
		my ($user, $license, $csrf, $mode) = @_;
#$log->error("THAT WHAT WE HAVE $user, $license, $csrf");		
		my $args = { 
			method => 'song.getListData',
			apiToken => $csrf,
			contentType => 'application/json',
			cookies => $mode,
		};

		my $content = encode_json( { sng_ids => [$id] } );

		_ajax( sub {
			my $result = shift;
			my @trackTokens = map { $_->{TRACK_TOKEN} } @{ $result->{results}->{data} };
			my @trackIds = map { $_->{SNG_ID} } @{ $result->{results}->{data} };
#$log->error(Data::Dump::dump(\@trackTokens), Data::Dump::dump(\@trackIds));
			
			return $cb->() unless @trackTokens && $trackIds[0] == $id;
			
			_getProviders($cb, $license, $params->{quality}, \@trackTokens) 
		}, $args, $content);
	}, $userId );
}

sub _getProviders {
	my ($cb, $license, $quality, $tracks) = @_;
	
	# Deezer does not send all formats but only one so 
	# you must be sure what you want. It will send the 
	# best it can according to your subscription
	
	my $formats = [ {
		cipher => 'BF_CBC_STRIPE', 
		format => 'MP3_128',
	} ];
	
	unshift @$formats, {
		cipher => 'BF_CBC_STRIPE', 
		format => 'MP3_320',
	} if ($quality ne 'LOW');
	
	unshift @$formats, {
		cipher => 'BF_CBC_STRIPE', 
		format => 'FLAC',
	} if ($quality eq 'LOSSLESS');
		
	my $content = encode_json( { 
		track_tokens => $tracks,
		license_token => $license,
		media => [{ 
			type => 'FULL', 
			formats => $formats,
		}],
	} );	
		
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $result = eval { from_json(shift->content) };
			
			$@ && $log->error($@);
			$log->debug(Data::Dump::dump($result)) if $@ || (main::DEBUGLOG && $log->is_debug);
			my $media = $result->{data}->[0]->{media};
#$log->error(Data::Dump::dump($media));			
			my $tracks = [ { 
				format => $media->[0]->{format},
				urls => [ map { $_->{url} } @{$media->[0]->{sources}} ],
			} ];
				
#$log->error(Data::Dump::dump($tracks));			
			$cb->($tracks);
		},
		sub {
			my ($http, $error) = @_;
			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));
			$cb->();
		},
	)->post(UURL, ContentType => 'application/json', $content);
}	

sub _getUserContext {
	my ($cb, $userId) = @_;
	
	_getArl( sub {
		my $arl = shift;
		_getTokens( $cb, $userId, { arl => $arl } );
	}, $userId );
}

sub _getArl {
	my ($cb, $userId) = @_;
	my $accounts = $prefs->get('accounts') || {};
	my $profile  = $accounts->{$userId};
	$cb->($profile->{status} == 2 ? $profile->{arl}: '');
}

sub _getTokens {
	my ($cb, $userId, $mode) = @_;
		
	my $params = { 
		method => 'deezer.getUserData',
		cookies => $mode,
	};
	
	_ajax( sub {
		my $result = shift;
		my $userToken = $result->{results}->{USER_TOKEN};
		my $licenseToken = $result->{results}->{USER}->{OPTIONS}->{license_token};
		my $csrfToken = $result->{results}->{checkForm};
		my $expiry = $result->{results}->{USER}->{OPTIONS}->{expiration_timestamp};			
						
		$cb->($userToken, $licenseToken, $csrfToken, $mode);
	}, $params );
}

sub _getSession {
	my ($cb) = @_;
	
	my $session = $cache->get('deezer_session');
	
	if ($session) {
		main::INFOLOG && $log->is_info && $log->info("Got session from cache");
		$cb->($session);
		return;
	}
	
	main::INFOLOG && $log->is_info && $log->info("Need a new session");
	
	_ajax( sub {
			$session = shift->{results}->{SESSION};
			$cb->($session);
	}, { method => 'deezer.ping' } );
}	

sub _ajax {
	my ($cb, $params, $content) = @_;
	
	my %headers = ( ContentType => $params->{contentType} || 'application/x-www-form-urlencoded' );		
	my $cookies = $params->{cookies};
	$headers{Cookie} = join ' ', map { "$_=$cookies->{$_}" } keys %$cookies if $cookies;
		
	my $query = complex_to_query( {
		method => $params->{method},
		input => '3',
		api_version => '1.0',
		api_token => $params->{apiToken} || 'null',
	} );
	
#$log->error("MY QUERY IS", $query, "\nheaders: ", Data::Dump::dump(%headers), "\ncontent: $content");
	
	my $method = $content ? 'post' : 'get';
		
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $result = eval { from_json(shift->content) };
			
			$@ && $log->error($@);
			$log->debug(Data::Dump::dump($result)) if $@ || (main::DEBUGLOG && $log->is_debug);
			
			$cb->($result);
		},
		sub {
			my ($http, $error) = @_;
			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));
			$cb->();
		},
	)->$method(GURL . "?$query", %headers, $content);
}

=comment
sub getAPIToken {
	my ( $self, $cb ) = @_;

	my $userId = $self->userId;
	my $token = $cache->get("deezer_at_$userId");

	return $cb->($token) if $token;

	Plugins::Deezer::API::Auth->refreshAPIToken($cb, $self->userId);
}
=cut

sub _get {
	my ( $self, $url, $cb, $params ) = @_;

	my %headers = (
	);

	my $ttl = delete $params->{_ttl} || DEFAULT_TTL;
	my $noCache = delete $params->{_nocache};
	
	my $accounts = $prefs->get('accounts') || {};
	my $profile  = $accounts->{$self->userId};
	
	$params->{access_token} = $profile->{token};
	$params->{limit} ||= DEFAULT_LIMIT;

	my $cacheKey = "deezer_resp:$url:" . join(':', map {
		$_ . $params->{$_}
	} sort grep {
		$_ !~ /^_/
	} keys %$params);

	main::INFOLOG && $log->is_info && $log->info("Using cache key '$cacheKey'") unless $noCache;

	my $maxLimit = 0;
	if ($params->{limit} > DEFAULT_LIMIT) {
		$maxLimit = $params->{limit};
		$params->{limit} = DEFAULT_LIMIT;
	}

	my $query = complex_to_query($params);

	if (!$noCache && (my $cached = $cache->get($cacheKey))) {
		main::INFOLOG && $log->is_info && $log->info("Returning cached data for $url?$query");
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));

		return $cb->($cached);
	}

	main::INFOLOG && $log->is_info && $log->info("Getting $url?$query");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

			# note that when querying compound types like 'chart', there is no 'total' as the result is
			# a hash with keys for tracks, artists, albums and podcasts *and* the {data] key is a sub-key
			# of theser. This means that _get only works because of lack of total so we do not do the amap
			# request which otherwise would try to take {data} key and push it into results. This also means
			# that for compound, we get what we get, no paging (seems that it's limited to 100 anyway
			
			if ($maxLimit && ref $result eq 'HASH' && $maxLimit > $result->{total} && $result->{total} - DEFAULT_LIMIT > 0) {
				my $remaining = $result->{total} - DEFAULT_LIMIT;
				main::INFOLOG && $log->is_info && $log->info("We need to page to get $remaining more results (total: $result->{total})");

				my @offsets;
				my $offset = DEFAULT_LIMIT;
				my $maxOffset = min($maxLimit, MAX_LIMIT, $result->{total});
				do {
					push @offsets, $offset;
					$offset += DEFAULT_LIMIT;
				} while ($offset < $maxOffset);

				if (scalar @offsets) {
					Async::Util::amap(
						inputs => \@offsets,
						action => sub {
							my ($input, $acb) = @_;
							$self->_get($url, $acb, {
								%$params,
								index => $input,
							});
						},
						at_a_time => 4,
						cb => sub {
							my ($results, $error) = @_;

							foreach (@$results) {
								next unless ref $_ && $_->{data};
								push @{$result->{data}}, @{$_->{data}};
							}

							$cache->set($cacheKey, $result, $ttl) unless $noCache;

							$cb->($result);
						}
					);

					return;
				}
			}

			$cache->set($cacheKey, $result, $ttl) unless $noCache;

			$cb->($result);
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));

			$cb->();
		},
		{
			cache => 1,
		}
	)->get(BURL . "$url?$query", %headers);
}


1;