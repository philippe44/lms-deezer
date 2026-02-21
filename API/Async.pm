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
use Scalar::Util qw(blessed);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Networking::Async::HTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::Deezer::API qw(BURL GURL UURL DEFAULT_LIMIT MAX_LIMIT DEFAULT_TTL PODCAST_TTL DYNAMIC_TTL USER_CONTENT_TTL);

# for the forgetful, API that can return tracks have a {id}/tracks endpoint that only return the
# tracks in a 'data' array. When using {id} endpoint only, there are details about the requested
# item then a 'track' hash that contains the 'data' array

{
	__PACKAGE__->mk_accessor( rw => qw(
		client
		userId
	) );

	__PACKAGE__->mk_accessor( hash => qw(
		updatedFavorites
	) );
}

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.deezer');
my $prefs = preferences('plugin.deezer');

my %apiClients;
my %contexts;
my $tzOffset = tz_local_offset();

use constant PAGE_SIZE => 50;

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
	
	__PACKAGE__->_ajax( sub {
		my $result = shift;
		
		__PACKAGE__->_ajax( sub {
			my $result = shift;

			# stop refreshing if profile has been destroyed meanwhile
			return unless $profile->{arl};

			if ( $result && $result->{results} ) {
				$profile->{arl} = $contexts{$userId}->{arl} = $result->{results};
				$prefs->set('accounts', $accounts);
			}
			
			# (re)starting refresh timer
			main::INFOLOG && $log->is_info && $log->info("Refreshed Arl for user $userId");
			Slim::Utils::Timers::setTimer($userId, time() + 24 * 3600, \&refreshArl, $userId);
		}, {
			method => 'user.getArl',
			api_token => $result->{results}->{checkForm},
			_cookies => { sid => $result->{results}->{SESSION_ID} },
		} );	
	}, {
		method => 'deezer.getUserData',
		_cookies => { arl => $profile->{arl} },
	} );
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
		_ttl => $args->{ttl} || DYNAMIC_TTL,
		limit => $args->{limit},
		q => $args->{search},
		strict => $args->{strict} || 'off',
	});
}

sub gwSearch {
	my ($self, $cb, $args) = @_;
	
	$self->gwCall( sub {
		$cb->($_[0]->{results});
	}, {
		method => 'deezer.pageSearch',
		_cacheKey => 'pageSearch:' . $args->{search},
	}, {
		nb => $args->{limit} || DEFAULT_LIMIT,
		start => 0,
		suggest => 'false',
		top_tracks => 'false',
		artist_suggest => 'false',
		query => $args->{search}
	} );
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
	
	my $content = {
		user_id => $self->userId,
		tuner => $params->{flow} ? 'discovery' : 'default',
	};

	if ($params->{mode} =~ /genre|mood/ ) {
		$content->{config_id} = ($params->{mode} eq 'genre' ?  'genre-' : '') . $params->{type};
	}
	
	$self->gwCall( sub {
		my ($result, $context) = @_;
		# When a track has an empty RIGHTS hash it cannot be streamed (error 2002).
		# Deezer then provides a FALLBACK entry with a licensed alternative version
		# (different SNG_ID/TRACK_TOKEN) and populated RIGHTS - use that instead.
		my @trackTokens = map {
			my $t = ($_->{RIGHTS} && %{$_->{RIGHTS}}) ? $_ : ($_->{FALLBACK} || $_);
			$t->{TRACK_TOKEN};
		} @{ $result->{results}->{data} };
		my @trackIds = map {
			my $t = ($_->{RIGHTS} && %{$_->{RIGHTS}}) ? $_ : ($_->{FALLBACK} || $_);
			$t->{SNG_ID};
		} @{ $result->{results}->{data} };
		return $cb->() unless @trackTokens;

		$self->_getProviders( $cb, $context->{license}, $params->{quality}, \@trackTokens, \@trackIds );
	}, {
		method => 'radio.getUserRadio',
	}, $content );
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
	my ($self, $cb, $id) = @_;

	# don't ask directly for tracks or album data will be missing
	$self->album(sub {
		my $album = shift;
		
		$self->_get("/album/$id/tracks", sub {
			my $tracks = shift;
			$tracks = $tracks->{data} if $tracks;
			# only missing data in album/tracks is the album itself...
			$tracks = Plugins::Deezer::API->cacheTrackMetadata( $tracks, { album => $album } ) if $tracks;

			$cb->($tracks || []);
		}, {
			limit => MAX_LIMIT,
		} );
	}, $id )	;
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
	my ($self, $cb, $id, $podcast) = @_;

	$self->_get("/podcast/$id/episodes", sub {
		my $episodes = shift;
		$episodes = Plugins::Deezer::API->cacheEpisodeMetadata($episodes->{data}, { podcast => $podcast } ) if $episodes;

		$cb->($episodes || []);
	}, {
		_ttl => PODCAST_TTL,
		limit => MAX_LIMIT,
	} );
}

sub radios {
	my ($self, $cb) = @_;
	$self->_get('/radio', sub {
		$cb->($_[0]->{data} || []);
	});
}

sub history {
	my ($self, $cb) = @_;
	
	main::INFOLOG && $log->is_info && $log->info("getting history songs");	
	
	$self->gwCall( sub {
		my $history = shift->{results};
		# TODO: this is upside-down, custom becomes main now...
		my $tracks = Plugins::Deezer::Custom::_cacheTrackMetadata($history->{data}) if $history;
		$cb->($tracks);
	}, {
		method => 'user.getSongsHistory',
		_ttl => USER_CONTENT_TTL,
	}, {
		nb => MAX_LIMIT,
		start => 0,
	} );
}

=comment
sub history {
	my ($self, $cb) = @_;
	$self->_get('/user/' . $self->userId . '/history', sub {
		my $history = $_[0]->{data};

		my $tracks = [ grep { $_->{type} eq 'track' } @$history ] if $history;
		$tracks = Plugins::Deezer::API->cacheTrackMetadata($tracks);

		$cb->($tracks || []);
	}, {
		_ttl => USER_CONTENT_TTL,
		limit => MAX_LIMIT,
	} );
}
=cut

=comment
sub personal {
	my ($self, $cb) = @_;
	$self->_get('/user/' . $self->userId . '/personal_songs', sub {
		my $personal = shift;

		my $tracks = Plugins::Deezer::API->cacheTrackMetadata( $personal->{data} || [] ) if $personal;

		$cb->($tracks || []);
	}, {
		_ttl => USER_CONTENT_TTL,
		limit => MAX_LIMIT,
	} );
}
=cut

sub personal {
	my ($self, $cb) = @_;
	
	main::INFOLOG && $log->is_info && $log->info("getting personal songs");	
	
	$self->gwCall( sub {
		my $personal = shift->{results};
		# TODO: this is upside-down, custom becomes main now...
		my $tracks = Plugins::Deezer::Custom::_cacheTrackMetadata($personal->{data}) if $personal;
		$cb->($tracks);
	}, {
		method => 'personal_song.getList',
		_ttl => USER_CONTENT_TTL,		
	}, {
		nb => MAX_LIMIT,
		start => 0,
	} );
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
	}, { _ttl => $type eq 'podcasts' ? USER_CONTENT_TTL : DEFAULT_TTL });
}

sub playlist {
	my ($self, $cb, $id) = @_;
	$self->_get("/playlist/$id", sub {
		$cb->($_[0]);
	}, { _ttl => DYNAMIC_TTL } );
}

sub playlistTracks {
	my ($self, $cb, $id) = @_;

	# we need to verify that the playlist has not been invalidated
	my $cacheKey = 'deezer_playlist_refresh_' . $id;
	my $refresh = $cache->get($cacheKey);

	$self->_get("/playlist/$id/tracks", sub {
		my $result = shift;
		my $items = [];

		if ($result) {
			$items = Plugins::Deezer::API->cacheTrackMetadata([ grep {
				($_->{type} && $_->{type} eq 'track' && $_->{readable}) ||
				# allow user-uploaded tracks (identified by negative IDs)
				(defined $_->{id} && $_->{id} < 0)
			} @{$result->{data} || []} ]);

			$cache->remove($cacheKey) if $refresh;
		}

		$cb->($items);
	},{
		_ttl => DYNAMIC_TTL,
		_refresh => $refresh,
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

	# verify if that type has been updated and force refresh (don't confuse adding
	# a playlist to favorites with changing the *content* of a playlist)
	$refresh ||= $self->updatedFavorites($type);
	$self->updatedFavorites($type, 0);

	my $lookupSub = sub {
		my $timestamp = shift;

		# no cache, so we can use /me
		$self->_get("/user/$userId/$type", sub {
			my $result = shift;

			my $items = [ map { $_ } @{$result->{data} || []} ] if $result;
			$items = Plugins::Deezer::API->cacheTrackMetadata($items) if $items && $type eq 'tracks';

			# invalidate playlists whose update time is more recent than last lookup
			if (defined $timestamp && $type eq 'playlists') {
				foreach my $playlist (@$items) {
					# we should invalidate *ALL* playlists but I'm not sure about the tz issue for public ones
					next unless $self->userId == $playlist->{creator}->{id} && $playlist->{time_mod} > $timestamp;
					main::INFOLOG && $log->is_info && $log->info("Invalidating playlist $playlist->{id}");
					$cache->set('deezer_playlist_refresh_' . $playlist->{id}, DEFAULT_TTL);
				}
			}

			$cache->set($cacheKey, {
				items => $items,
				checksum => $result->{checksum},
				timestamp => time(),
				total => $result->{total},
			}, '1M') if $items;

			$cb->($items);
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
				$lookupSub->($cached->{timestamp} + $tzOffset);
			}
		}, $type);
	}
	else {
		$lookupSub->();
	}
}

sub getCollectionFingerprint {
	my ($self, $cb, $type) = @_;

	my $userId = $self->userId || return $cb->();
	my $sort = $type eq 'playlists' ? 'time_mod' : 'time_add';

	# no cache, so we can use /me
	$self->_get("/user/$userId/$type", sub {
		my $result = shift;

		my $fingerprint = {
			checksum => $result->{checksum},
			# well, believe it or not the time recorded by Deezer includes TZ for playlist ONLY...
			time => $result->{data}->[0]->{$sort} - ($type eq 'playlists' ? $tzOffset : 0),
			total => $result->{total},
		} if $result->{data};

		$cb->($fingerprint || {});
	},{
		limit => 1,
		order => $sort,
		_nocache => 1,
	});
}

=comment
sub updateFavorite {
	my ($self, $cb, $action, $type, $id) = @_;

	my $profile = Plugins::Deezer::API->getUserdata($self->userId);
	my $access_token = $profile->{token} if $profile;
	return $cb->() unless $action && $type && $id && $access_token;

	my $item = $type;
	$type .= 's';

	# make favorites as updated
	$self->updatedFavorites($type, 1);

	my $query = complex_to_query( {
		$item . '_id' => $id,
		access_token => $access_token,
	} );

	my $method = ($action eq 'add') ? 'POST' : 'DELETE';
	my $trace = $query =~ s/(access_token=)\w+/${1}***/r;
	main::INFOLOG && $log->is_info && $log->info(uc($method) . " /user/me/$type?$trace");

	# no DELETE method in SimpleAsync
	my $http = Slim::Networking::Async::HTTP->new;
	my $request = HTTP::Request->new( $method => BURL . "/user/me/$type?$query" );
	$request->header( 'Content-Length' => 0);
	$http->send_request( {
		request => $request,
		onBody  => sub { $cb->(); },
		onError => sub { $cb->($_[1]); },
	} );
}
=cut

sub updateFavorite {
	my ($self, $cb, $action, $type, $id) = @_;

	return $cb->() unless $action && $type && $id;

	# make favorites as updated
	$self->updatedFavorites("$type.s", 1);
	
	my $content;
	my $method;

	# do the necessary soup to make it accepted by the gw-light		
	if ($type =~ /album|artist/) {
		my $verb = uc(substr($type, 0, 3)) . '_ID';			
		$content->{$verb} = $id;			
		$action = 'delete' unless $action eq 'add';			
		$method = "$type.$action" . 'Favorite';			
	} elsif ($type eq 'track') {	
		$content->{IDS} = [ $id ];
		$action = 'remove' unless $action eq 'add';
		$method = "song.$action" . 'Favorites';			
	}
	
	main::INFOLOG && $log->is_info && $log->info("updating favorites ($action) with $method", Data::Dump::dump($content));	
	$self->gwCall( $cb, { 
		method => $method,
	}, $content );
}

=comment
sub updatePlaylist {
	my ($self, $cb, $action, $id, $trackId) = @_;

	# mark that playlist as need to be refreshed. After the DEFAULT_TTL
	# the _get will also have forgotten it, no need to go further
	$cache->set('deezer_playlist_refresh_' . $id, DEFAULT_TTL);

	my $profile  = Plugins::Deezer::API->getUserdata($self->userId);
	my $access_token = 	$profile->{token};

	my $query = complex_to_query( {
		songs => $trackId,
		access_token => $access_token,
	} );

	my $method = ($action eq 'add') ? 'POST' : 'DELETE';
	my $trace = $query =~ s/(access_token=)\w+/${1}***/r;
	main::INFOLOG && $log->is_info && $log->info(uc($method) . " /playlist/$id/tracks?$trace");

	# no DELETE method in SimpleAsync
	my $http = Slim::Networking::Async::HTTP->new;
	my $request = HTTP::Request->new( $method => BURL . "/playlist/$id/tracks?$query" );
	$request->header( 'Content-Length' => 0);
	$http->send_request( {
		request => $request,
		onBody  => sub { $cb->(); },
		onError => sub { $cb->($_[1]); },
	} );
}
=cut

sub updatePlaylist {
	my ($self, $cb, $action, $id, $trackId) = @_;

	# mark that playlist as need to be refreshed. After the DEFAULT_TTL
	# the _get will also have forgotten it, no need to go further
	$cache->set('deezer_playlist_refresh_' . $id, DEFAULT_TTL);
	
	main::INFOLOG && $log->is_info && $log->info("update playlist $id ($action) with $trackId");
	
	$self->gwCall( $cb, { 
		method => $action eq 'add' ? 'playlist.addSongs' : 'playlist.deleteSongs',
	}, {
		offset => -1,
		playlist_id => $id,
		songs => [ [ $trackId, 0 ] ],
	} );
}

sub dislike {
	my ($self, $cb, $type, $id) = @_;
	
	$self->gwCall( $cb, { 
		method => 'favorite_dislike.add',
	}, {	
		ID => $id,
		TYPE => $type eq 'track' ? 'song' : 'artist',
		CTX => {
			id => $self->userId,
			t => 'dynamic_page_user_radio'
		}
	} );
}

sub listened {
	my ($self, $id) = @_;
	
	$self->gwCall( sub { }, { 
		method => 'log.listen',
	}, {
		params => {
		media => {
			id => $id,
			type => 'song',
		},
		ts_listen => time(),
		type => 0,
		},
	} );
}

sub getTrackUrl {
	my ($self, $cb, $ids, $params) = @_;
	
	$self->gwCall( sub {
		my ($result, $context) = @_;
		# When a track has an empty RIGHTS hash it cannot be streamed (error 2002).
		# Deezer then provides a FALLBACK entry with a licensed alternative version
		# (different SNG_ID/TRACK_TOKEN) and populated RIGHTS - use that instead.
		my @trackTokens = map {
			my $t = ($_->{RIGHTS} && %{$_->{RIGHTS}}) ? $_ : ($_->{FALLBACK} || $_);
			$t->{TRACK_TOKEN};
		} @{ $result->{results}->{data} };
		my @trackIds = map {
			my $t = ($_->{RIGHTS} && %{$_->{RIGHTS}}) ? $_ : ($_->{FALLBACK} || $_);
			$t->{SNG_ID};
		} @{ $result->{results}->{data} };
		main::INFOLOG && $log->is_info && $log->info("Track IDs after fallback resolution: @trackIds");

		return $cb->() unless @trackTokens;

		$self->_getProviders( $cb, $context->{license}, $params->{quality}, \@trackTokens, \@trackIds );
	}, {
		method => 'song.getListData',
	}, {
		sng_ids => $ids }
	);
}

sub getEpisodesUrl {
	my ($self, $cb, $id) = @_;
	
	$self->gwCall( sub {
		my $result = shift;

		$result = $result->{results} if $result;
		$cb->($result || []);
	}, {	
		method => 'episode.getData',
	}, {
		episode_id => $id,
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
	}, {
		cipher => 'BF_CBC_STRIPE',
		format => 'MP3_MISC',
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

sub gwCall {
	my ($self, $cb, $args, $content) = @_;
	my $context = $contexts{$self->userId};
	
	# we need to acquire an SID
	return $self->_ajax( sub {
		my $result = shift;
		$context->{csrf} = $result->{results}->{checkForm};
		$context->{sid} = $result->{results}->{SESSION_ID};
		$context->{license} = $result->{results}->{USER}->{OPTIONS}->{license_token};
		# $context->{expiration} = time() + $result->{results}->{USER}->{OPTIONS}->{expiration_timestamp} - $result->{results}->{USER}->{OPTIONS}->{timestamp} - 3600*24;
		# I really don't know when these expire, but certainly not with that timestamp
		$context->{expiration} = time() + 3600*4;
				
		main::INFOLOG && $log->is_info && $log->info("got a new session for ARL $context->{arl}");
		$self->gwCall($cb, $args, $content);
	}, {
		method => 'deezer.getUserData',
		_cookies => { arl => $context->{arl} },
	} ) unless $context->{sid} && time() < $context->{expiration};

	# we have all we need, just do the gw-api call	
	main::INFOLOG && $log->is_info && $log->info("context will expire in ", $context->{expiration} - time()) if $context->{expiration};
	
	# a ttl but no cache key means we have to make one but here we hash everything
	# as some '_' might be part of caching. This means that _ttl is cached as well... 
	if ($args->{_ttl} && !$args->{_cacheKey}) {
		my $cacheKey = { %$args, %$content };
		$cacheKey = join(':', map { $_ . $cacheKey->{$_} } sort grep { $_ !~ /^_/ } keys %$cacheKey);
		$cacheKey .= $context->{csrf} . $context->{sid};
		$args->{_cacheKey} = md5_hex($cacheKey);
		main::INFOLOG && $log->is_info && $log->info("computing hashkey $args->{_cacheKey}");
	}	
	
	$args = { %$args, 
		api_token => $context->{csrf},		
		_cookies => { sid => $context->{sid} },
	};

	if ($content) {
		$args->{_contentType} = 'application/json',
		$content = encode_json($content);
	}
		
	$self->_ajax( sub {
		$cb->($_[0], $context);
	}, $args, $content );
}

sub getUserFromARL {
	my ($cb, $arl) = @_;

	my $params = {
		method => 'deezer.getUserData',
		_cookies => { arl => $arl },
	};

	__PACKAGE__->_ajax( sub {
		my $result = shift;
		my $user = {
			id => $result->{results}->{USER}->{USER_ID},
			name => $result->{results}->{USER}->{BLOG_NAME},
		};

		$cb->($user);
	}, $params );
}

sub _ajax {
	my ($self, $cb, $params, $content) = @_;

	my $cookies = delete $params->{_cookies};
	my $cacheKey = 'deezer_ajax_' . delete $params->{_cacheKey} if $params->{_cacheKey};
	my $ttl = delete $params->{_ttl} || USER_CONTENT_TTL;
	my %headers = ( 'Content-Type' => delete $params->{_contentType} || 'application/x-www-form-urlencoded' );
	$headers{Cookie} = join ' ', map { "$_=$cookies->{$_}" } keys %$cookies if $cookies;
	
	# TODO
	# LMS memorizes all cookies so it can keep SID and we don't want that...
	# but if we clean the cookie jar every time, then SID is lost and it is needed between calls. That means
	# that current logic does not work, and ARL should be given once then only SID should be used until it expires.
	# For now, we'll ignore that and this is an issue only when adding/refreshing a user if a wrong arl is given
	# or for users with multiple profiles assigned to different players
	# Slim::Networking::Async::HTTP::cookie_jar->clear('.deezer.com');

	$params->{api_token} ||= 'null';

	my $query = complex_to_query( {
		%$params,
		input => '3',
		api_version => '1.0',
	} );

	my $method = $content ? 'post' : 'get';
	main::INFOLOG && $log->is_info && $log->info(uc($method) . " ?$query ", $content ? Data::Dump::dump($content) : '');

	if ( $cacheKey && (my $cached = $cache->get($cacheKey)) ) {
		main::INFOLOG && $log->is_info && $log->info("returning from cache $cacheKey");
		return $cb->($cached);
	}

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $result = eval { from_json($_[0]->content) };

			$@ && $log->error($@);
			$log->debug(Data::Dump::dump($result)) if $@ || (main::DEBUGLOG && $log->is_debug);

			$cache->set($cacheKey, $result, $ttl) if $cacheKey;
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
sub _gwPost {
	my ($self, $cb, $params, $content) = @_;

	my $cookies = delete $params->{_cookies};
	my $cacheKey = 'deezer_gw_' . delete $params->{_cacheKey} if $params->{_cacheKey};
	my $ttl = delete $params->{_ttl} || DEFAULT_TTL;
	my %headers = (
		Cookie => join ' ', map { "$_=$cookies->{$_}" } keys %$cookies,
	);
	
	main::INFOLOG && $log->is_info && $log->info("Using cache key '$trace'") if $cacheKey;
	
	# TEMP
	$params->{_page} = 3;

	# TODO
	$params->{api_token} ||= 'null';
	
	my $pageSize = delete $params->{_page} || PAGE_SIZE;
	$params->{limit} ||= DEFAULT_LIMIT;
	my $maxLimit = 0;
	if ($params->{limit} > $pageSize) {
		$maxLimit = $params->{limit};
		$params->{limit} = $pageSize;
	}
	
	# TODO
	# LMS memorizes all cookies so it can keep SID and we don't want that...
	# but if we clean the cookie jar every time, then SID is lost and it is needed between calls. That means
	# that current logic does not work, and ARL should be given once then only SID should be used until it expires.
	# For now, we'll ignore that and this is an issue only when adding/refreshing a user if a wrong arl is given
	# or for users with multiple profiles assigned to different players
	# Slim::Networking::Async::HTTP::cookie_jar->clear('.deezer.com');

	my $query = complex_to_query( {
		%$params,
		input => '3',
		api_version => '1.0',
	} );

	main::INFOLOG && $log->is_info && $log->info("GET $query ");

	if ( $cacheKey && (my $cached = $cache->get($cacheKey)) ) {
		main::INFOLOG && $log->is_info && $log->info("returning from cache $cacheKey");
		return $cb->($cached);
	}

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $result = eval { from_json(shift->content) };

			$@ && $log->error($@);
			$log->debug(Data::Dump::dump($result)) if $@ || (main::DEBUGLOG && $log->is_debug);

			$cache->set($cacheKey, $result, $ttl) if $cacheKey;
			$cb->($result);
			
			
						my $response = shift;

			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

			# note that when querying compound types like 'chart', there is no 'total' as the result is
			# a hash with keys for tracks, artists, albums and podcasts *and* the {data] key is a sub-key
			# of these. This means that _get only works because of lack of total so we do not do the amap
			# request which otherwise would try to take {data} key and push it into results. This also means
			# that for compound, we get what we get, no paging (seems that it's limited to 100 anyway

			if ($maxLimit && ref $result eq 'HASH' && $maxLimit > $result->{total} && $result->{total} - $pageSize > 0) {
				my $remaining = $result->{total} - $pageSize;
				main::INFOLOG && $log->is_info && $log->info("We need to page to get $remaining more results (total: $result->{total})");

				my @offsets;
				my $offset = $pageSize;
				my $maxOffset = min($maxLimit, MAX_LIMIT, $result->{total});
				do {
					push @offsets, $offset;
					$offset += $pageSize;
				} while ($offset < $maxOffset);

				if (scalar @offsets) {
					Async::Util::amap(
						inputs => \@offsets,
						action => sub {
							my ($input, $acb) = @_;
							$self->_get($url, sub {
								# only return the first argument, the second would be considered an error
								$acb->($_[0]);
							}, {
								%$params,
								index => $input,
								_nocache => 1,
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
	)->post(GURL . "?$query", %headers, $content);
}
=cut

sub _get {
	my ( $self, $url, $cb, $params ) = @_;

	my %headers = (
	);

	my $ttl = delete $params->{_ttl} || DEFAULT_TTL;
	my $noCache = delete $params->{_nocache};
	my $refresh = delete $params->{_refresh};
	my $pageSize = delete $params->{_page} || PAGE_SIZE;

	my $profile  = Plugins::Deezer::API->getUserdata($self->userId);
	#$params->{access_token} = $profile->{token};
	$params->{limit} ||= DEFAULT_LIMIT;

	my $cacheKey = "deezer_resp:$url:" . join(':', map {
		$_ . $params->{$_}
	} sort grep {
		$_ !~ /^_/
	} keys %$params);

	my $trace = $cacheKey =~ s/(:access_token)\w+/${1}***/r;
	main::INFOLOG && $log->is_info && $log->info("Using cache key '$trace'") unless $noCache;

	my $maxLimit = 0;
	if ($params->{limit} > $pageSize) {
		$maxLimit = $params->{limit};
		$params->{limit} = $pageSize;
	}

	my $query = complex_to_query($params);
	my $trace = $query =~ s/(access_token=)\w+/${1}***/r;

	if (!$noCache && !$refresh && (my $cached = $cache->get($cacheKey))) {
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
			# of these. This means that _get only works because of lack of total so we do not do the amap
			# request which otherwise would try to take {data} key and push it into results. This also means
			# that for compound, we get what we get, no paging (seems that it's limited to 100 anyway

			if ($maxLimit && ref $result eq 'HASH' && $maxLimit > $result->{total} && $result->{total} - $pageSize > 0) {
				my $remaining = $result->{total} - $pageSize;
				main::INFOLOG && $log->is_info && $log->info("We need to page to get $remaining more results (total: $result->{total})");

				my @offsets;
				my $offset = $pageSize;
				my $maxOffset = min($maxLimit, MAX_LIMIT, $result->{total});
				do {
					push @offsets, $offset;
					$offset += $pageSize;
				} while ($offset < $maxOffset);

				if (scalar @offsets) {
					Async::Util::amap(
						inputs => \@offsets,
						action => sub {
							my ($input, $acb) = @_;
							$self->_get($url, sub {
								# only return the first argument, the second would be considered an error
								$acb->($_[0]);
							}, {
								%$params,
								index => $input,
								_nocache => 1,
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
