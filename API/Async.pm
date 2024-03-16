package Plugins::Deezer::API::Async;

use strict;
use base qw(Slim::Utils::Accessor);

use Async::Util;
use Data::URIEncode qw(complex_to_query);
use Date::Parse qw(str2time);
use Time::Zone;
use MIME::Base64 qw(encode_base64);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min);
use Digest::MD5 qw(md5_hex);
use URI::Escape qw(uri_escape);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Networking::Async::HTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::Deezer::API qw(BURL GURL UURL DEFAULT_LIMIT MAX_LIMIT DEFAULT_TTL USER_CONTENT_TTL);

# for the forgetful, API that can return tracks have a {id}/tracks endpoint that only return the
# tracks in a 'data' array. When using {id} endpoint only, there are details about the requested
# item then a 'track' hash that contains the 'data' array

{
	__PACKAGE__->mk_accessor( rw => qw(
		client
		userId
		updated
	) );
}

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.deezer');
my $prefs = preferences('plugin.deezer');

my %apiClients;
my $tzOffset = tz_local_offset();

sub init {
	my $accounts = $prefs->get("accounts");
	refreshArl($_) foreach (keys %$accounts);
}

sub refreshArl {
	my ($userId) = @_;

	my $accounts = $prefs->get("accounts");
	my $profile = $accounts->{$userId};

	# stop refreshing if we don't have profile anymore
	return unless $profile && $profile->{arl};

	main::INFOLOG && $log->is_info && $log->info("Refreshing Arl for user $userId");
	Slim::Utils::Timers::killTimers($userId, \&refreshArl);

	__PACKAGE__->_getTokens( sub {
		my ($tokens, $mode) = @_;

		my $args = {
			method => 'user.getArl',
			api_token => $tokens->{csrf},
			_cookies => $mode,
		};

		__PACKAGE__->_ajax( sub {
			my $result = shift;

			# stop refreshing if profile has been destroyed meanwhile
			return unless $profile->{arl};

			if ( $result && $result->{results} ) {
				$profile->{arl} = $result->{results};
				$prefs->set('accounts', $accounts);
			}

			# (re)starting refresh timer
			main::INFOLOG && $log->is_info && $log->info("Refreshed Arl for user $userId");
			Slim::Utils::Timers::setTimer($userId, time() + 24 * 3600, \&refreshArl, $userId);
		}, $args );
	}, { arl => $profile->{arl} } );
}

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

		# even if cachable data are missing, we *want* to cache
		($track) = @{Plugins::Deezer::API->cacheTrackMetadata( [$track], { cache => 1 } )} if $track;
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

sub flowTracks {
	my ($self, $cb, $params) = @_;

	$self->_getUserContext( sub {
		my ($tokens, $mode) = @_;
		return $cb->() unless $tokens;

		my $args = {
			method => 'radio.getUserRadio',
			api_token => $tokens->{csrf},
			_contentType => 'application/json',
		};

		my $content = encode_json( {
			config_id => ($params->{mode} eq 'genre' ?  'genre-' : '') . $params->{type},
			user_id => $self->userId,
		} );

		$self->_ajax( sub {
			my $result = shift;
			my @trackTokens = map { $_->{TRACK_TOKEN} } @{ $result->{results}->{data} };
			my @trackIds = map { $_->{SNG_ID} } @{ $result->{results}->{data} };
#$log->error(Data::Dump::dump(\@trackTokens), Data::Dump::dump(\@trackIds));
			return $cb->() unless @trackTokens;

			$self->_getProviders( $cb, $tokens->{license}, $params->{quality}, \@trackTokens, \@trackIds );
		}, $args, $content );
	} );
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

sub album {
	my ($self, $cb, $id) = @_;

	$self->_get("/album/$id", sub {
		my $album = $_[0] unless $_[0]->{error};
		$cb->($album);
	});
}

sub albumTracks {
	my ($self, $cb, $id, $title) = @_;

	# don't ask directly for tracks or album data will be missing
	#$self->_get("/album/$id/tracks", sub {
	$self->_get("/album/$id", sub {
		my $album = shift;
		my $tracks = $album->{tracks}->{data} if $album;
		# only missing data in album/tracks is the album itself...
		$tracks = Plugins::Deezer::API->cacheTrackMetadata( $tracks ) if $tracks;

		$cb->($tracks || []);
	});
}

sub podcasts {
	my ($self, $cb) = @_;
	$self->_get('/podcast', sub {
		$cb->($_[0]->{data} || []);
	});
}

sub podcast {
	my ($self, $cb, $id) = @_;
	$self->_get("/podcast/$id", sub {
		$cb->($_[0]);
	});
}

sub episode {
	my ($self, $cb, $id) = @_;

	$self->_get("/episode/$id", sub {
		my $episode = shift;

		# even if cachable data are missing, we *want* to cache
		($episode) = @{Plugins::Deezer::API->cacheEpisodeMetadata( [$episode], { cache => 1 } )} if $episode;
		$cb->($episode);
	});
}

sub podcastEpisodes {
	my ($self, $cb, $id, $title) = @_;

	$self->_get("/podcast/$id/episodes", sub {
		my $podcast = shift;
		my $episodes = Plugins::Deezer::API->cacheEpisodeMetadata($podcast->{data}, { podcast => $title } ) if $podcast;

		$cb->($episodes || []);
	}, { _ttl => USER_CONTENT_TTL } );
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
	}, { _ttl => $type =~ /podcast/ ? USER_CONTENT_TTL : DEFAULT_TTL });
}


sub playlist {
	my ($self, $cb, $id) = @_;
	$self->_get("/playlist/$id", sub {
		$cb->($_[0]);
	});
}

sub playlistTracks {
	my ($self, $cb, $id) = @_;

	my $cacheKey = 'deezer_playlist_' . $id;

	# we must do our own cache of playlist's tracks because we can't remove
	# the cache made by _get selectively when we know a playlist has changed
	# as we don't know exactly how the request was made/cached by _get

	if ( my $cached = $cache->get($cacheKey) ) {
		main::INFOLOG && $log->is_info && $log->info("Returning cached data for playlist $id");
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));
		return $cb->($cached);
	}

	$self->_get("/playlist/$id/tracks", sub {
		my $result = shift;
		my $items = [];

		if ($result) {
			$items = Plugins::Deezer::API->cacheTrackMetadata([ grep {
				$_->{type} && $_->{type} eq 'track'
			} @{$result->{data} || []} ]);

			# with change verification, that, we can cache aggressively
			$cache->set($cacheKey, $items, DEFAULT_TTL);
		}

		$cb->($items);
	},{
		_nocache => 1,
		limit => MAX_LIMIT,
	});
}

# User collections can be large - but have a known last updated timestamp.
# Instead of statically caching data, then re-fetch everything, do a quick
# lookup to get the latest timestamp first, then return from cache directly
# if the list hasn't changed, or look up afresh if needed. Playlists need
# multi-stage handling as we first see that something has changed then we
# must re-acquire the user's playlist *list*, then invalidate from cache the
# playlists that are actually newer. Otherwise, we'd just update the playlist
# list but _get would return the old track's list during DEFAULT_TTL (one day)
# For albums, artists and tracks it's less of a problem b/c it's very unlikely
# that their content itself has changed within DEFAULT_TTL

sub getFavorites {
	my ($self, $cb, $type, $refresh) = @_;

	return $cb->() unless $type;

	my $userId = $self->userId || return $cb->();
	my $cacheKey = "deezer_favs_$type:$userId";

	# verify if that type has been updated and force refresh
	if ((my $updated = $self->updated) =~ /$type:/) {
		$self->updated($updated =~ s/$type://r);
		$refresh = 1;
	}

	my $lookupSub = sub {
		my $scb = shift;
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

			$scb->($items);
		},{
			_nocache => 1,
			limit => MAX_LIMIT,
		});
	};

	my $cached = $cache->get($cacheKey);

	# use cached data unless the collection has changed
	if ($cached && ref $cached->{items}) {
		# don't bother verifying checksum when not asked (e.g. drilling down)
		return $cb->($cached->{items}) unless $refresh;

		$self->getCollectionFingerprint(sub {
			my $fingerprint = shift;

			if ( (defined $fingerprint->{checksum} && $fingerprint->{checksum} eq $cached->{checksum}) ||
				 ($fingerprint->{time} < $cached->{timestamp} && $fingerprint->{total} == $cached->{total}) ) {
				main::INFOLOG && $log->is_info && $log->info("Collection of type '$type' has not changed - using cached results");
				$cb->($cached->{items});
			}
			else {
				main::INFOLOG && $log->is_info && $log->info("Collection of type '$type' has changed - updating");
				return $lookupSub->($cb) unless $type =~ /playlists/;

				# need to invalidate playlists that are actually updated (and correct TZ, see below)
				my $timestamp = $cached->{timestamp} + $tzOffset;

				$lookupSub->( sub {
					my $items = shift;
					foreach my $playlist (@$items) {
						next unless $playlist->{time_mod} > $timestamp;
						main::INFOLOG && $log->is_info && $log->info("Invalidating playlist $playlist->{id}");
						$cache->remove('deezer_playlist_' . $playlist->{id});
					}
					$cb->($items);
				} );
			}
		}, $type);
	}
	else {
		$lookupSub->($cb);
	}
}

sub getCollectionFingerprint {
	my ($self, $cb, $type) = @_;

	my $userId = $self->userId || return $cb->();
	my $sort = $type =~ /playlists/ ? 'time_mod' : 'time_add';

	$self->_get("/user/me/$type", sub {
		my $result = shift;

		my $fingerprint = {
			checksum => $result->{checksum},
			# well, believe it or not the time recorded by Deezer includes TZ for playlist ONLY...
			time => $result->{data}->[0]->{$sort} - ($type =~ /playlists/ ? $tzOffset : 0),
			total => $result->{total},
		} if $result->{data};

		$cb->($fingerprint || {});
	},{
		limit => 1,
		order => $sort,
		_nocache => 1,
	});
}

sub updateFavorite {
	my ($self, $cb, $action, $type, $id) = @_;

	my $accounts = $prefs->get('accounts') || {};
	my $profile  = $accounts->{$self->userId};
	my $access_token = $profile->{token} if $profile;

	# well... we have a trailing 's' (I know this is hacky... and bad)
	my $item = substr($type, 0, -1);

	# need everything to update the library
	return $cb() unless $action && $type && $id && $access_token;

	# make sure we'll force an update check next time
	my $updated = $self->updated;
	$self->updated($updated . "$type:") unless $updated =~ /$type/;

	my $query = complex_to_query( {
		$item . '_id' => $id,
		access_token => $access_token,
	} );

	my $method = ($action =~ /add/) ? 'POST' : 'DELETE';
	my $trace = $query =~ s/(access_token=)\w+/${1}***/r;
	main::INFOLOG && $log->is_info && $log->info(uc($method) . " /user/me/$type?$trace");

	# no DELETE method in SimpleAsync
	my $http = Slim::Networking::Async::HTTP->new;
	my $request = HTTP::Request->new( $method => BURL . "/user/me/$type?$query" );
	$request->header( 'Content-Length' => 0);
	$http->send_request( {
		request => $request,
		onBody  => $cb,
		onError => sub {
			my ($http, $error) = @_;
			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));
			$cb->();
		}
	} );
}

sub getTrackUrl {
	my ($self, $cb, $ids, $params) = @_;

	$self->_getUserContext( sub {
		my ($tokens, $mode) = @_;
		return $cb->() unless $tokens;

#$log->error("THAT WHAT WE HAVE ", Data::Dump::dump($tokens));
		my $args = {
			method => 'song.getListData',
			api_token => $tokens->{csrf},
			_contentType => 'application/json',
			_cookies => $mode,
		};

		my $content = encode_json( { sng_ids => $ids } );

		$self->_ajax( sub {
			my $result = shift;
			my @trackTokens = map { $_->{TRACK_TOKEN} } @{ $result->{results}->{data} };
			my @trackIds = map { $_->{SNG_ID} } @{ $result->{results}->{data} };
#$log->error(Data::Dump::dump(\@trackTokens), Data::Dump::dump(\@trackIds));

			return $cb->() unless @trackTokens;

			$self->_getProviders( $cb, $tokens->{license}, $params->{quality}, \@trackTokens, \@trackIds );
		}, $args, $content);
	} );
}

# getting an episode's url is a bit funny: you can't request by the episode id directly
# but you need to use the podcast id and an index+count. Caller must know that index and
# should ask a bit more around it in case something changed.

sub getEpisodesUrl {
	my ($self, $cb, $podcast, $index, $count) = @_;

	$self->_getUserContext( sub {
		my ($tokens, $mode) = @_;
		return $cb->() unless $tokens;

		my $args = {
			method => 'deezer.pageShow',
			api_token => $tokens->{csrf},
			_contentType => 'application/json',
			_cookies => $mode,
		};

		my $accounts = $prefs->get('accounts');

		my $content = encode_json( {
			show_id => $podcast,
			country => $accounts->{$self->userId}->{country},
			lang => lc(preferences('server')->get('language')),
			nb => $count || 1,
			start => $index || 0,
			user_id => $self->userId,
		} );

		$self->_ajax( sub {
			my $result = shift;

			$result = $result->{results}->{EPISODES}->{data} if $result;

			$cb->($result || []);
		}, $args, $content);
	} );
}

sub _getProviders {
	my ($self, $cb, $license, $quality, $trackTokens, $trackIds) = @_;

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
		track_tokens => $trackTokens,
		license_token => $license,
		media => [{
			type => 'FULL',
			formats => $formats,
		}],
	} );

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $result = eval { from_json(shift->content) };
			my $tracks = [];

			$@ && $log->error($@);
			$log->debug(Data::Dump::dump($result)) if $@ || (main::DEBUGLOG && $log->is_debug);

			# stitch back the track ids whch should be in same array order...
			foreach my $i (0...$#{$result->{data}} ) {
				my $media = $result->{data}->[$i]->{media};
				next unless $media;
				push @$tracks, {
					id => $trackIds->[$i],
					format => $media->[0]->{format},
					urls => [ map { $_->{url} } @{$media->[0]->{sources}} ],
				};
			}
#$log->error(Data::Dump::dump($tracks));

			$log->warn("can't get tracks: ", Data::Dump::dump($result)) unless scalar @$tracks;
			$cb->($tracks);
		},
		sub {
			my ($http, $error) = @_;
			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));
			$cb->();
		},
	)->post(UURL, 'Content-Type' => 'application/json', $content);
}

sub _getUserContext {
	my ($self, $cb) = @_;

	my $accounts = $prefs->get('accounts') || {};
	my $profile  = $accounts->{$self->userId};
	my $arl = $profile->{arl};

	return $self->_getTokens( $cb, { arl => $arl } ) if $arl && $profile->{status} == 2;

	$log->error("ARL token is required, can't play");
	$cb->();
}

sub _getTokens {
	my ($self, $cb, $mode) = @_;

	my $params = {
		method => 'deezer.getUserData',
		_cookies => $mode,
	};

	$self->_ajax( sub {
		my $result = shift;
		my $tokens = {
			user => $result->{results}->{USER_TOKEN},
			license => $result->{results}->{USER}->{OPTIONS}->{license_token},
			csrf => $result->{results}->{checkForm},
			expiration => $result->{results}->{USER}->{OPTIONS}->{expiration_timestamp},
		};

		$cb->($tokens, $mode);
	}, $params );
}

sub _getSession {
	my ($self, $cb) = @_;

	my $session = $cache->get('deezer_session');

	if ($session) {
		main::INFOLOG && $log->is_info && $log->info("Got session from cache");
		$cb->($session);
		return;
	}

	main::INFOLOG && $log->is_info && $log->info("Need a new session");

	$self->_ajax( sub {
			$session = shift->{results}->{SESSION};
			$cb->($session);
	}, { method => 'deezer.ping' } );
}

sub _ajax {
	my ($self, $cb, $params, $content) = @_;

	my $cookies = delete $params->{_cookies};
	my %headers = ( 'Content-Type' => delete $params->{_contentType} || 'application/x-www-form-urlencoded' );
	$headers{Cookie} = join ' ', map { "$_=$cookies->{$_}" } keys %$cookies if $cookies;

	$params->{api_token} ||= 'null';

	my $query = complex_to_query( {
		%$params,
		input => '3',
		api_version => '1.0',
	} );

	my $method = $content ? 'post' : 'get';
	main::INFOLOG && $log->is_info && $log->info(uc($method) . " ?$query ", $content ? Data::Dump::dump($content) : '');

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

	my $trace = $cacheKey =~ s/(:access_token)\w+/${1}***/r;
	main::INFOLOG && $log->is_info && $log->info("Using cache key '$trace'") unless $noCache;

	my $maxLimit = 0;
	if ($params->{limit} > DEFAULT_LIMIT) {
		$maxLimit = $params->{limit};
		$params->{limit} = DEFAULT_LIMIT;
	}

	my $query = complex_to_query($params);
	my $trace = $query =~ s/(access_token=)\w+/${1}***/r;

	if (!$noCache && (my $cached = $cache->get($cacheKey))) {
		main::INFOLOG && $log->is_info && $log->info("Returning cached data for $url?$trace");
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));

		return $cb->($cached);
	}

	main::INFOLOG && $log->is_info && $log->info("Getting $url?$trace");

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