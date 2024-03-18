package Plugins::Deezer::Info;

use strict;
use Tie::Cache::LRU;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::Deezer::API::Async;
use Plugins::Deezer::Plugin;

my $log = Slim::Utils::Log->addLogCategory({
	'category'    => 'plugin.deezer',
	'description' => 'PLUGIN_DEEZER_NAME',
});

my $prefs = preferences('plugin.deezer');

# see note on memorizing feeds for different dispatches
my %rootFeeds;
tie %rootFeeds, 'Tie::Cache::LRU', 64;

sub init {
	my $class = shift;

#  |requires Client
#  |  |is a Query
#  |  |  |has Tags
#  |  |  |  |Function to call
	Slim::Control::Request::addDispatch( [ 'deezer_info', 'items', '_index', '_quantity' ],	[ 1, 1, 1, \&menuInfoWeb ]	);
	Slim::Control::Request::addDispatch( [ 'deezer_info', 'jive' ],	[ 1, 1, 1, \&menuInfoJive ]	);
	Slim::Control::Request::addDispatch( [ 'deezer_browse', 'items' ],	[ 1, 1, 1, \&menuBrowse ]	);
	Slim::Control::Request::addDispatch( [ 'deezer_browse', 'playlist', '_method' ],	[ 1, 1, 1, \&menuBrowse ]	);
}

sub trackInfoMenu {
	my ($client, $url, $track, $remoteMeta) = @_;

	my $artist = $track->remote ? $remoteMeta->{artist} : $track->artistName;
	my $album  = $track->remote ? $remoteMeta->{album} : ( $track->album ? $track->album->name : undef );
	my $title  = $track->remote ? $remoteMeta->{title} : $track->title;

=comment
	my $query .= 'artist:' . "\"$artist\" " if $artist;
	$query .= 'album:' . "\"$album\" " if $album;
	$query .= 'track:' . "\"$title\"" if $title;
	main::INFOLOG && $log->is_info && $log->info("Getting info with query $query");
=cut
	my $search = cstring($client, 'SEARCH');
	my $items = [];

	push @$items, {
		name => "$search " . cstring($client, 'ARTISTS') . " '$artist'",
		type => 'link',
		url => \&Plugins::Deezer::Plugin::search,
		image => 'html/images/artists.png',
		passthrough => [ {
			type => 'artist',
			query => $artist,
			strict => 'on',
		} ],
	} if $artist;

	push @$items, {
		name => "$search " . cstring($client, 'ALBUMS') . " '$album'",
		type => 'link',
		url => \&Plugins::Deezer::Plugin::search,
		image => 'html/images/albums.png',
		passthrough => [ {
			type => 'album',
			query => $album,
			strict => 'on',
		} ],
	} if $album;

	push @$items, {
		name => "$search " . cstring($client, 'SONGS') . " '$title'",
		type => 'link',
		url => \&Plugins::Deezer::Plugin::search,
		image => 'html/images/playall.png',
		passthrough => [ {
			type => 'track',
			query => $title,
			strict => 'on',
		} ],
	} if $title;

	return {
		type => 'outlink',
		items => $items,
		name => cstring($client, 'PLUGIN_DEEZER_ON_DEEZER'),
	};
}

sub albumInfoMenu {
	my ($client, $url, $album, $remoteMeta) = @_;

	my @artists;
	push @artists, $album->artistsForRoles('ARTIST'), $album->artistsForRoles('ALBUMARTIST');
	my $artist = $artists[0]->name;
	my $album  = ($remoteMeta && $remoteMeta->{album}) || ($album && $album->title);

	my $query = 'album:' . "\"$album\" ";
	$query .= 'artist:' . "\"$artist\" " if $artist;
	main::INFOLOG && $log->is_info && $log->info("Getting info with query $query");

	return {
		type      => 'link',
		name      => cstring($client, 'PLUGIN_DEEZER_ON_DEEZER'),
		url       => \&Plugins::Deezer::Plugin::search,
		# image 	  => __PACKAGE__->_pluginDataFor('icon'),
		passthrough => [ {
			query => $query,
			strict => 'on',
		} ],
	};
}

sub artistInfoMenu {
	my ($client, $url, $artist, $remoteMeta) = @_;

	my $artist  = ($remoteMeta && $remoteMeta->{artist}) || ($artist && $artist->name);
	my $query = 'artist:' . "\"$artist\" ";
	main::INFOLOG && $log->is_info && $log->info("Getting info with query $query");

	return {
		type      => 'link',
		name      => cstring($client, 'PLUGIN_DEEZER_ON_DEEZER'),
		url       => \&Plugins::Deezer::Plugin::search,
		# image 	  => __PACKAGE__->_pluginDataFor('icon'),
		passthrough => [ {
			query => $query,
			strict => 'on',
		} ],
	};
}

sub browseArtistMenu {
	my ($client, $cb, $args, $params) = @_;

	my $empty = [{
		type  => 'text',
		title => cstring($client, 'EMPTY'),
	}];

	my $artistId = $args->{artist_id} || $args->{artist_id};

	if ( defined($artistId) && $artistId =~ /^\d+$/ && (my $artistObj = Slim::Schema->resultset("Contributor")->find($artistId))) {

		if (my ($extId) = grep /deezer:artist:(\d+)/, @{$artistObj->extIds}) {
			my ($id) = $extId =~ /deezer:artist:(\d+)/;

			Plugins::Deezer::Plugin::getAPIHandler($client)->artist(sub {
				my $items = Plugins::Deezer::Plugin::renderItem( $client, $_[0] ) if $_[0];
				$cb->($items || $empty);
			}, $id );

		} else {

			search($client, sub {
					$cb->($_[0]->{items} || $empty);
				}, $args,
				{
					type => 'artist',
					query => $artistObj->name,
					strict => 'on',
				}
			);

		}
	} else {
		$cb->( $empty );
	}
}

sub menuInfoWeb {
	my $request = shift;

	# be careful that type must be artistS|albumS|playlistS|trackS
	my $type = $request->getParam('type');
	my $id = $request->getParam('id');

	$request->addParam('_index', 0);
	$request->addParam('_quantity', 10);

	# we can't get the response live, we must be called back by cliQuery to
	# call it back ourselves
	Slim::Control::XMLBrowser::cliQuery('deezer_info', sub {
		my ($client, $cb, $args) = @_;

		my $api = Plugins::Deezer::Plugin::getAPIHandler($client);

		$api->getFavorites( sub {
			my $favorites = shift;

			my $action = (grep { $_->{id} == $id && ($type =~ /$_->{type}/ || !$_->{type}) } @$favorites) ? 'remove' : 'add';
			my $title = $action eq 'remove' ? cstring($client, 'PLUGIN_FAVORITES_REMOVE') : cstring($client, 'PLUGIN_FAVORITES_SAVE');
			$title .= ' (' . cstring($client, 'PLUGIN_DEEZER_ON_DEEZER') . ')';

			my $items = [];

			if ($request->getParam('menu')) {
				push @$items, {
					type => 'link',
					name => $title,
					isContextMenu => 1,
					refresh => 1,
					jive => {
						actions => {
							go => {
								player => 0,
								cmd    => [ 'deezer_info', 'jive' ],
									params => {
									type => $type,
									id => $id,
									action => $action,
								},
							}
						},
						nextWindow => 'parent'
					},
				};
			} else {
				push @$items, {
					type => 'link',
					name => $title,
					url => sub {
						my ($client, $ucb) = @_;
						$api->updateFavorite( sub {
							$ucb->({
								items => [{
									type => 'text',
									name => cstring($client, 'COMPLETE'),
								}],
							});
						}, $action, $type, $id );
					},
				};
			}

			my $method;

			if ( $type =~ /tracks/ ) {
				$method = \&_menuTrackInfo;
			} elsif ( $type =~ /albums/ ) {
				$method = \&_menuAlbumInfo;
			} elsif ( $type =~ /artists/ ) {
				$method = \&_menuArtistInfo;
			} elsif ( $type =~ /playlists/ ) {
				$method = \&_menuPlaylistInfo;
			} elsif ( $type =~ /podcasts/ ) {
				$method = \&_menuPodcastInfo;
			} elsif ( $type =~ /episodes/ ) {
				$method = \&_menuEpisodeInfo;
			}

			$method->( $api, $items, sub {
				my ($icon, $entry) = @_;

				# we need to add favorites for cliQuery to add them and I know I should not use _xxx function
				$entry = Plugins::Deezer::Plugin::renderItem($client, $entry, { addArtistToTitle => 1 });
				my $favorites = Slim::Control::XMLBrowser::_favoritesParams($entry) || {};
				
				$cb->( {
					type  => 'opml',
					%$favorites, 					
					image => $icon,
					items => $items,
					# do we need this one?
					name => $entry->{name} || $entry->{title},
				} );
			}, $args->{params});

		}, $type );

	}, $request );
}

sub menuInfoJive {
	my $request = shift;

	my $type = $request->getParam('type');
	my $id = $request->getParam('id');
	my $api = Plugins::Deezer::Plugin::getAPIHandler($request->client);
	my $action = $request->getParam('action');

	$api->updateFavorite( sub { }, $action, $type, $id );
}

sub menuBrowse {
	my $request = shift;

	my $client = $request->client;
#$log->error(Data::Dump::dump($request));
	my $itemId = $request->getParam('item_id');
	my $type = $request->getParam('type');
	my $id = $request->getParam('id');

	$request->addParam('_index', 0);
	# TODO: why do we need to set that
	$request->addParam('_quantity', 200);

	main::INFOLOG && $log->is_info && $log->info("Browsing for item_id:$itemId or type:$type:$id");

	# if we are descending, no need to search, just get our root
	if ( defined $itemId ) {
		my ($key) = $itemId =~ /([^\.]+)/;
		my $cached = ${$rootFeeds{$key}};
#$log->error("usin cached feed ==========================", Data::Dump::dump($cached));
		Slim::Control::XMLBrowser::cliQuery('deezer_browse', $cached, $request);
		return;
	}

	# this key will prefix each action's hierarchy that JSON will sent us which
	# allows us to find our back our root feed. During drill-down, that prefix
	# is removed and XMLBrowser descends the feed.
	# ideally, we would like to not have to do that but that means we leave some
	# breadcrums *before* we arrive here, in the _renderXXX familiy but I don't
	# know how so we have to build our own "fake" dispatch just for that
	# we only need to do that when we have to redescend further that hierarchy,
	# not when it's one shot
	my $key = $client->id =~ s/://gr;
	$request->addParam('item_id', $key);

	Slim::Control::XMLBrowser::cliQuery('deezer_browse', sub {
		my ($client, $cb, $args) = @_;

		if ( $type =~ /album/ ) {

			Plugins::Deezer::Plugin::getAlbum($client, sub {
				my $feed = $_[0];
				$rootFeeds{$key} = \$feed;
				$cb->($feed);
			}, $args, { id => $id } );

		} elsif ( $type =~ /artist/ ) {

			Plugins::Deezer::Plugin::getAPIHandler($client)->artist(sub {
				my $feed = Plugins::Deezer::Plugin::renderItem( $client, $_[0] ) if $_[0];
				$rootFeeds{$key} = \$feed;
				# no need to add any action, the root 'deezer_browse' is memorized and cliQuery
				# will provide us with item_id hierarchy. All we need is to know where our root
				# by prefixing item_id with a min 8-digits length hexa string
				$cb->($feed);
			}, $id );

		} elsif ( $type =~ /playlist/ ) {

			# we don't need to memorize the feed as we won't redescend into it
			Plugins::Deezer::Plugin::getPlaylist($client, $cb, $args, { id => $id } );

		} elsif ( $type =~ /track/ ) {

			# track must be in cache, no memorizing
			my $cache = Slim::Utils::Cache->new;
			my $track = Plugins::Deezer::Plugin::renderItem( $client, $cache->get('deezer_meta_' . $id), { addArtistToTitle => 1 } );	
			$cb->([$track]);

		} elsif ( $type =~ /podcast/ ) {

			# we need to re-acquire the podcast itself
			Plugins::Deezer::Plugin::getAPIHandler($client)->podcast(sub {
				my $podcast = shift;
				getPodcastEpisodes($client, $cb, $args, {
					id => $id,
					podcast => $podcast,
				} );
			}, $id );

		} elsif ( $type =~ /episode/ ) {

			# episode must be in cache, no memorizing
			my $cache = Slim::Utils::Cache->new;
			my $episode = Plugins::Deezer::Plugin::renderItem( $client, $cache->get('deezer_episode_meta_' . $id) );
			$cb->([$episode]);

		}
	}, $request );
}

sub _menuBase {
	my ($client, $type, $id, $params) = @_;

	my $items = [];

	push @$items, (
		_menuAdd($client, $type, $id, 'add', 'ADD_TO_END', $params->{menu}),
		_menuAdd($client, $type, $id, 'insert', 'PLAY_NEXT', $params->{menu}),
		_menuPlay($client, $type, $id, $params->{menu}),
	) if $params->{useContextMenu} || $params->{feedMode};

	return $items;
}

sub _menuAdd {
	my ($client, $type, $id, $cmd, $title, $menuMode) = @_;

	my $actions = {
			items => {
				command     => [ 'deezer_browse', 'playlist', $cmd ],
				fixedParams => { type => $type, id => $id },
			},
		};

	$actions->{'play'} = $actions->{'items'};
	$actions->{'add'}  = $actions->{'items'};

	return {
		itemActions => $actions,
		nextWindow  => 'parent',
		type        => $menuMode ? 'text' : 'link',
		playcontrol => $cmd,
		name        => cstring($client, $title),
	};
}

sub _menuPlay {
	my ($client, $type, $id, $menuMode) = @_;

	my $actions = {
			items => {
				command     => [ 'deezer_browse', 'playlist', 'load' ],
				fixedParams => { type => $type, id => $id },
			},
		};

	$actions->{'play'} = $actions->{'items'};

	return {
		itemActions => $actions,
		nextWindow  => 'nowPlaying',
		type        => $menuMode ? 'text' : 'link',
		playcontrol => 'play',
		name        => cstring($client, 'PLAY'),
	};
}

sub _menuTrackInfo {
	my ($api, $items, $cb, $params) = @_;

	my $cache = Slim::Utils::Cache->new;
	my $id = $params->{id};

	# if we are here, the metadata of the track is cached
	my $track = $cache->get("deezer_meta_$id");
	$log->error("metadata not cached for $id") && return [] unless $track;

	# play/add/add_next options except for skins that don't want it
	my $base = _menuBase($api->client, 'track', $id, $params);
	push @$items, @$base if @$base;

	push @$items, ( {
		type => 'link',
		name =>  $track->{album}->{title},
		label => 'ALBUM',
		itemActions => {
			items => {
				command     => ['deezer_browse', 'items'],
				fixedParams => { type => 'album', id => $track->{album}->{id} },
			},
		},
	}, {
		type => 'link',
		name =>  $track->{artist}->{name},
		label => 'ARTIST',
		itemActions => {
			items => {
				command     => ['deezer_browse', 'items'],
				fixedParams => { type => 'artist', id => $track->{artist}->{id} },
			},
		},
	}, {
		type => 'text',
		name => sprintf('%s:%02s', int($track->{duration} / 60), $track->{duration} % 60),
		label => 'LENGTH',
	}, {
		type  => 'text',
		name  => $track->{link},
		label => 'URL',
		parseURLs => 1
	} );

	$cb->($track->{cover}, $track);
}

sub _menuAlbumInfo {
	my ($api, $items, $cb, $params) = @_;

	my $id = $params->{id};

	$api->album( sub {
		my $album = shift;

		# play/add/add_next options except for skins that don't want it
		my $base = _menuBase($api->client, 'album', $id, $params);
		push @$items, @$base if @$base;

		push @$items, ( {
			type => 'playlist',
			name =>  $album->{artist}->{name},
			label => 'ARTIST',
			itemActions => {
				items => {
					command     => ['deezer_browse', 'items'],
					fixedParams => { type => 'artist', id => $album->{artist}->{id} },
				},
			},
		}, {
			type => 'text',
			name => $album->{nb_tracks} || 0,
			label => 'TRACK_NUMBER',
		}, {
			type => 'text',
			name => substr($album->{release_date}, 0, 4),
			label => 'YEAR',
		}, {
			type => 'text',
			name => $album->{genres}->{data}->[0]->{name},
			label => 'GENRE',
		}, {
			type => 'text',
			name => sprintf('%s:%02s', int($album->{duration} / 60), $album->{duration} % 60),
			label => 'LENGTH',
		}, {
			type  => 'text',
			name  => $album->{link},
			label => 'URL',
			parseURLs => 1
		} );

		my $icon = Plugins::Deezer::API->getImageUrl($album, 'usePlaceholder');
		$cb->($icon, $album);

	}, $id );
}

sub _menuArtistInfo {
	my ($api, $items, $cb, $params) = @_;

	my $id = $params->{id};

	$api->artist( sub {
		my $artist = shift;

		push @$items, ( {
			type => 'link',
			name =>  $artist->{name},
			url => 'N/A',
			label => 'ARTIST',
			itemActions => {
				items => {
					command     => ['deezer_browse', 'items'],
					fixedParams => { type => 'artist', id => $artist->{id} },
				},
			},
		}, {
			type => 'text',
			name => $artist->{nb_album},
			label => 'ALBUM',
		}, {
			type  => 'text',
			name  => $artist->{link},
			label => 'URL',
			parseURLs => 1
		} );

		my $icon = Plugins::Deezer::API->getImageUrl($artist, 'usePlaceholder');
		$cb->($icon, $artist);

	}, $id );
}

sub _menuPlaylistInfo {
	my ($api, $items, $cb, $params) = @_;

	my $id = $params->{id};

	$api->playlist( sub {
		my $playlist = shift;

		# play/add/add_next options except for skins that don't want it
		my $base = _menuBase($api->client, 'playlist', $id, $params);
		push @$items, @$base if @$base;

		push @$items, ( {
			type => 'text',
			name =>  $playlist->{creator}->{name},
			label => 'ARTIST',
		}, {
			type => 'text',
			name =>  $playlist->{title},
			label => 'ALBUM',
		}, {
			type => 'text',
			name => $playlist->{nb_tracks} || 0,
			label => 'TRACK_NUMBER',
		}, {
			type => 'text',
			name => substr($playlist->{creation_date}, 0, 4),
			label => 'YEAR',
		}, {
			type => 'text',
			name => sprintf('%02s:%02s:%02s', int($playlist->{duration} / 3600), int(($playlist->{duration} % 3600)/ 60), $playlist->{duration} % 60),
			label => 'LENGTH',
		}, {
			type  => 'text',
			name  => $playlist->{link},
			label => 'URL',
			parseURLs => 1
		} );

		my $icon = Plugins::Deezer::API->getImageUrl($playlist, 'usePlaceholder');
		$cb->($icon, $playlist);

	}, $id );
}

sub _menuPodcastInfo {
	my ($api, $items, $cb, $params) = @_;

	my $id = $params->{id};

	$api->podcast( sub {
		my $podcast = shift;

		# play/add/add_next options except for skins that don't want it
		my $base = _menuBase($api->client, 'podcast', $id, $params);
		push @$items, @$base if @$base;

		push @$items, ( {
			# put that one as an "album" otherwise control icons won't appear
			type => 'text',
			name =>  $podcast->{title},
			label => 'ALBUM',
		}, {
			type  => 'text',
			name  => $podcast->{link},
			label => 'URL',
			parseURLs => 1
		}, {
			type => 'text',
			name => $podcast->{description},
			label => 'COMMENT',
			parseURLs => 1
		} );

		my $icon = Plugins::Deezer::API->getImageUrl($podcast, 'usePlaceholder');
		$cb->($icon, $podcast);

	}, $id );
}

sub _menuEpisodeInfo {
	my ($api, $items, $cb, $params) = @_;

	my $cache = Slim::Utils::Cache->new;
	my $id = $params->{id};

	# unlike tracks, we miss some information when drilling down on podcast episodes
	$api->episode( sub {
		my $episode = shift;

		# play/add/add_next options except for skins that don't want it
		my $base = _menuBase($api->client, 'episode', $id, $params);
		push @$items, @$base if @$base;

		push @$items, ( {
			# put that one as an "album" otherwise control icons won't appear
			type => 'text',
			name =>  $episode->{podcast}->{title},
			label => 'ALBUM',
		}, {
			type => 'text',
			name =>  $episode->{title},
			label => 'TITLE',
		}, {
			type => 'text',
			name => sprintf('%02s:%02s:%02s', int($episode->{duration} / 3600), int(($episode->{duration} % 3600)/ 60), $episode->{duration} % 60),
			label => 'LENGTH',
		}, {
			type => 'text',
			label => 'MODTIME',
			name => $episode->{date},
		}, {
			type  => 'text',
			name  => $episode->{link},
			label => 'URL',
			parseURLs => 1
		}, {
			type => 'text',
			name => $episode->{comment},
			label => 'COMMENT',
			parseURLs => 1
		} );

		my $icon = Plugins::Deezer::API->getImageUrl($episode, 'usePlaceholder');
		$cb->($icon, $episode);

	}, $id );
}


1;