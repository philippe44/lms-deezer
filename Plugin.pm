package Plugins::Deezer::Plugin;

use strict;
use Async::Util;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::Deezer::API::Auth;
use Plugins::Deezer::API::Async;
use Plugins::Deezer::ProtocolHandler;

my $log = Slim::Utils::Log->addLogCategory({
	'category'    => 'plugin.deezer',
	'description' => 'PLUGIN_DEEZER_NAME',
});

my $prefs = preferences('plugin.deezer');

sub initPlugin {
	my $class = shift;

	$prefs->init({
		quality => 'HIGH',
		serial => '29436f4b2c5b2b552e4c221b2d7c7a4e7a336c002d7278512e486f1f2c677d432b1c224e29522c0b280e7f42750f7b43794a271c7d652b06744c5454795f6c4e781f51197d742e077b5b344e7b0e694d7e4c271e2c1c7c032c4f794e786060062b4260432f306b40',
	});

	Plugins::Deezer::API::Auth->init();
	Plugins::Deezer::ProtocolHandler->init();
	Plugins::Deezer::API::Async->init();

	if (main::WEBUI) {
		require Plugins::Deezer::Settings;
		Plugins::Deezer::Settings->new();
	}

	Slim::Player::ProtocolHandlers->registerHandler('deezer', 'Plugins::Deezer::ProtocolHandler');
	Slim::Music::Import->addImporter('Plugins::Deezer::Importer', { use => 1 });

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'deezer',
		menu   => 'apps',
		is_app => 1,
	);

	Slim::Menu::TrackInfo->registerInfoProvider( deezer => (
		after => 'bottom',
		func  => \&trackInfoMenu,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( deezer => (
		after => 'bottom',
		func  => \&artistInfoMenu,
	) );

	Slim::Menu::AlbumInfo->registerInfoProvider( deezer => (
		after => 'bottom',
		func  => \&albumInfoMenu,
	) );

#  |requires Client
#  |  |is a Query
#  |  |  |has Tags
#  |  |  |  |Function to call
	Slim::Control::Request::addDispatch( [ 'deezer_favs', 'items', '_index', '_quantity' ],	[ 1, 1, 1, \&menuInfo ]	);

=comment
	Slim::Menu::GlobalSearch->registerInfoProvider( deezer => (
		func => sub {
			my ( $client, $tags ) = @_;

			return {
				name  => cstring($client, Plugins::Spotty::Deezer::getDisplayName()),
				items => [ map { delete $_->{image}; $_ } @{_searchItems($client, $tags->{search})} ],
			};
		},
	) );
=cut
}

sub menuInfo {
	my $request = shift;
	my $client = $request->client;
	
	# be careful that type must be artistS|albumS|playlistS|trackS
	my $type = $request->getParam('type');
	my $id = $request->getParam('id');
	my $handler = getAPIHandler($client);
	
	$request->addParam('_index', 0);
	$request->addParam('_quantity', 10);
	
	$handler->getFavorites( sub {
		my $favorites = shift;
		
		my $action = (grep { $type =~ /$_->{type}/ && $_->{id} == $id } @$favorites) ? 'remove' : 'add'; 
		my $title = $action eq 'remove' ? cstring($client, 'PLUGIN_FAVORITES_REMOVE') : cstring($client, 'PLUGIN_FAVORITES_SAVE');
					
		my $item;
	
		if ($request->getParam('menu')) {
			$item = {
				type => 'link',
				name => $title,
				isContextMenu => 1,
				refresh => 1,
				jive => {
					actions => {
						go => {
							player => 0,
							#cmd    => [ 'deezer_favs', $menuAction ],
						}
					},
					nextWindow => 'parent'
				},
			};
		} else {
			$item = {
				type => 'link',
				name => $title,
				url => sub {
					my ($client, $cb) = @_;
					$handler->updateFavorite( sub {
						$cb->({
							items => [{
								type => 'text',
								name => cstring($client, 'COMPLETE'),
							}],
						});
					}, $action, $type, $id );				
				},
			};
		}
		
		my $items = [ $item ];

=comment	
		# add some other stuff here
		push @$items, {
			type => 'text',
			name => '',
		};
=cut	
		Slim::Control::XMLBrowser::cliQuery('deezer_favs', {
			name => $request->getParam('title'),
			items => $items,
		}, $request);
	
	}, $type, 1 );
}

sub postinitPlugin {
	my $class = shift;

	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::OnlineLibrary::Plugin') ) {
		Slim::Plugin::OnlineLibrary::Plugin->addLibraryIconProvider('deezer', '/plugins/Deezer/html/logo.png');

		Slim::Plugin::OnlineLibrary::BrowseArtist->registerBrowseArtistItem( deezer => sub {
			my ( $client ) = @_;

			return {
				name => cstring($client, 'BROWSE_ON_SERVICE', 'Deezer'),
				type => 'link',
				icon => $class->_pluginDataFor('icon'),
				url  => \&browseArtistMenu,
			};
		} );
	}

	if ( Slim::Utils::PluginManager->isEnabled('Plugins::LastMix::Plugin') ) {
		eval {
			require Plugins::LastMix::Services;
		};

		if (!$@) {
			main::INFOLOG && $log->info("LastMix plugin is available - let's use it!");
			require Plugins::Deezer::LastMix;
			Plugins::LastMix::Services->registerHandler('Plugins::Deezer::LastMix', 'lossless');
		}
	}
}

sub onlineLibraryNeedsUpdate {
	my $class = shift;
	require Plugins::Deezer::Importer;
	return Plugins::Deezer::Importer->needsUpdate(@_);
}

sub getLibraryStats {
	require Plugins::Deezer::Importer;
	my $totals = Plugins::Deezer::Importer->getLibraryStats();
	return wantarray ? ('PLUGIN_DEEZER_NAME', $totals) : $totals;
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	if ( !Plugins::Deezer::API->getSomeUserId() ) {
		return $cb->({
			items => [{
				name => cstring($client, 'PLUGIN_DEEZER_REQUIRES_CREDENTIALS'),
				type => 'textarea',
			}]
		});
	}

=comment
	{
		name => cstring($client, 'PLUGIN_PODCAST'),
		type  => 'link',
		url   => \&getGenreItems,
		passthrough => [ { id => $item->{id}, type => 'podcasts' } ],
	}
=cut


	my $items = [ {
		name => cstring($client, 'PLUGIN_DEEZER_FLOW'),
		image => 'plugins/Deezer/html/flow.png',
		play => 'deezer://user/me/flow.dzr',
		type => 'outline',
		items => [{
			name => cstring($client, 'PLUGIN_DEEZER_FLOW'),
			image => 'plugins/Deezer/html/flow.png',
			on_select => 'play',			
			url => 'deezer://user/me/flow.dzr',	
			play => 'deezer://user/me/flow.dzr',
		},{
			name => cstring($client, 'GENRES'),
			image => 'html/images/genres.png',
			type => 'link',
			url => \&getFlow,
			passthrough => [{ mode => 'genres' }],
		},{
			name => cstring($client, 'PLUGIN_DEEZER_MOODS'),
			image => 'plugins/Deezer/html/moods_MTL_icon_celebration.png',
			type => 'link',
			url => \&getFlow,
			passthrough => [{ mode => 'moods' }],
		}],
	},{
		name => cstring($client, 'PLAYLISTS'),
		image => 'html/images/playlists.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'playlists' }],
	},{
		name => cstring($client, 'ALBUMS'),
		image => 'html/images/albums.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'albums' }],
	},{
		name => cstring($client, 'SONGS'),
		image => 'html/images/playall.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'tracks' }],
	},{
		name => cstring($client, 'ARTISTS'),
		image => 'html/images/artists.png',
		type => 'link',
		url => \&getFavorites,
		passthrough => [{ type => 'artists' }],
	},{
		name => cstring($client, 'GENRES'),
		image => 'html/images/genres.png',
		type => 'link',
		url => \&getGenres,
	},{
		name => cstring($client, 'PLUGIN_DEEZER_SMART_RADIO'),
		image => 'plugins/Deezer/html/smart_radio.png',
		type => 'link',
		url => \&getRadios,
	},{
		name => cstring($client, 'PLUGIN_DEEZER_CHART'),
		image => 'plugins/Deezer/html/charts.png',
		type => 'link',
		url => \&getCompound,
		passthrough => [ { path => 'chart' } ],
	},{
		name  => cstring($client, 'SEARCH'),
		image => 'html/images/search.png',
		type => 'outline',
		items => [{
			name => cstring($client, 'PLAYLISTS'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/playlists.png',
			passthrough => [ { type => 'playlist'	} ],
		},{
			name => cstring($client, 'ARTISTS'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/artists.png',
			passthrough => [ { type => 'artist' } ],
		},{
			name => cstring($client, 'ALBUMS'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/albums.png',
			passthrough => [ { type => 'album' } ],
		},{
			name => cstring($client, 'SONGS'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/playall.png',
			passthrough => [ { type => 'track' } ],
		}]
	} ];

	if ($client && keys %{$prefs->get('accounts') || {}} > 1) {
		push @$items, {
			name => cstring($client, 'PLUGIN_DEEZER_SELECT_ACCOUNT'),
			image => __PACKAGE__->_pluginDataFor('icon'),
			url => \&selectAccount,
		};
	}

	$cb->({ items => $items });
}

sub selectAccount {
	my ($client, $cb) = @_;
	my $userId = getAPIHandler($client)->userId;

	my $items = [ map {
		my $name = $_->{name} || $_->{email};
		$name = '[' . $name . ']' if $_->{id} == $userId;
		{
			name => $name,
			url => sub {
				my ($client, $cb2, $params, $args) = @_;

				$client->pluginData(api => 0);
				$prefs->client($client)->set('userId', $args->{id});

				$cb2->({ items => [{
					nextWindow => 'grandparent',
				}] });
			},
			passthrough => [{
				id => $_->{id}
			}],
			nextWindow => 'parent'
		}
	} sort values %{ $prefs->get('accounts') || {} } ];

	$cb->({ items => $items });
}

sub getFavorites {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->getFavorites(sub {
		my $items = shift;

		$items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 }) } @$items ] if $items;

		$cb->( {
			items => $items
		} );
	}, $params->{type}, $args->{quantity} == 1 );
}

sub getArtistAlbums {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->artistAlbums(sub {
		my $items = _renderAlbums(@_);

		$cb->( {
			items => $items,
			# the action can be there or in the sub-item as an itemActions
		} );
	}, $params->{id});
}

sub getArtistTopTracks {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->artistTopTracks(sub {
		my $items = _renderTracks(@_);
		$cb->( {
			items => $items
		} );
	}, $params->{id});
}

sub getArtistRelated {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->artistRelated(sub {
		my $items = _renderArtists($client, @_);
		$cb->( {
			items => $items
		} );
	}, $params->{id});
}

sub getAlbum {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->albumTracks(sub {
		my $items = _renderTracks(shift);
		$cb->( {
			items => $items
		} );
	}, $params->{id}, $params->{title} );
}

sub getGenres {
	my ( $client, $callback ) = @_;

	getAPIHandler($client)->genres(sub {
		my $items = [ map { _renderItem($client, $_) } @{$_[0]} ];

		$callback->( { items => $items } );
	});
}

sub getFlow {
	my ( $client, $callback, $args, $params ) = @_;

	my $mode = $params->{mode} =~ /genre/ ? 'genre' : 'mood';
	my @categories = $mode eq 'genre' ?
					( 'pop', 'rap', 'rock', 'alternative', 'kpop', 'jazz', 'classical', 
					  'chanson', 'reggae', 'latin', 'soul', 'variete', 'lofi', 'rnb',
					  'danceedm' ) :
					( 'motivation', 'party', 'chill', 'melancholy', 'you_and_me', 'focus');

	my $items = [ map {
		{
			name => cstring($client, 'PLUGIN_DEEZER_' . uc($_)),
			play => "deezer://$mode:" . $_ . '.flow',
			url => "deezer://$mode:" . $_ . '.flow',
			#favorites_url => "deezer://$mode:' . $_ . '.flow',
			image => 'plugins/Deezer/html/' . $_ . '.png',
		}
	} @categories ];

	$callback->( { items => $items } );
}

sub getRadios {
	my ( $client, $callback ) = @_;

	getAPIHandler($client)->radios(sub {
		my $items = [ map { _renderItem($client, $_) } @{$_[0]} ];

		$callback->( { items => $items } );
	});
}

sub getGenreItems {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->genreByType(sub {

		my $items = [ map { _renderItem($client, $_, { addArtistToTitle => 1 } ) } @{$_[0]} ];

		$cb->( {
			items => $items
		} );
	}, $params->{id}, $params->{type} );
}

sub getCompound {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->compound(sub {
		my $items = _renderCompound($client, $_[0]);

		$cb->( {
			items => $items
		} );
	}, $params->{path} );
}

=comment
sub getMoods {
	my ( $client, $callback, $args, $params ) = @_;
	getAPIHandler($client)->moods(sub {
		my $items = [ map {
			{
				name => $_->{name},
				type => 'link',
				url => \&getMoodPlaylists,
				image => Plugins::Deezer::API->getImageUrl($_, 'usePlaceholder', 'mood'),
				passthrough => [ { mood => $_->{path} } ],
			};
		} @{$_[0]} ];

		$callback->( { items => $items } );
	} );
}

sub getMoodPlaylists {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->moodPlaylists(sub {
		my $items = [ map { _renderPlaylist($_) } @{$_[0]->{items}} ];

		$cb->( {
			items => $items
		} );
	}, $params->{mood} );
}
=cut

sub getPlaylist {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->playlist(sub {
		my $items = _renderTracks($_[0], 1);
		$cb->( {
			items => $items
		} );
	}, $params->{id} );
}

sub search {
	my ($client, $cb, $args, $params) = @_;

	$args->{search} ||= $params->{query};
	$args->{type} = $params->{type};
	$args->{strict} = $params->{strict} || 'off';

	getAPIHandler($client)->search(sub {
		my $items = shift;
		$items = [ map { _renderItem($client, $_) } @$items ] if $items;

		$cb->( {
			items => $items || []
		} );
	}, $args);

}

sub _renderItem {
	my ($client, $item, $args) = @_;

	my $type = Plugins::Deezer::API->typeOfItem($item);

	if ($type eq 'track') {
		return _renderTrack($item, $args->{addArtistToTitle});
	}
	elsif ($type eq 'album') {
		return _renderAlbum($item, $args->{addArtistToTitle});
	}
	elsif ($type eq 'artist') {
		return _renderArtist($client, $item);
	}
	elsif ($type eq 'playlist') {
		return _renderPlaylist($item);
	}
	elsif ($type eq 'radio') {
		return _renderRadio($item);
	}
	elsif ($type eq 'genre') {
		return _renderGenre($client, $item, $args->{handler});
	}
	elsif ($type eq 'mix') {
		return _renderMix($client, $item);
	}
}

sub _renderPlaylists {
	my $results = shift;

	return [ map {
		_renderPlaylist($_)
	} @$results ];
}

sub _renderPlaylist {
	my $item = shift;

	return {
		name => $item->{title},
		line1 => $item->{title},
		line2 => $item->{user}->{name},
		favorites_url => 'deezer://playlist:' . $item->{id},
		type => 'playlist',
		# don't set 'play' for now as it might be dangerous to let user delete playlists here
		itemActions => {
			info => {
				command   => ['deezer_favs', 'items'],
				fixedParams => { type => 'playlists', id => $item->{id}, title => $item->{title} },
			},
		},
		url => \&getPlaylist,
		image => Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder'),
		passthrough => [ { id => $item->{id} } ],
	};
}

sub _renderAlbums {
	my ($results, $addArtistToTitle) = @_;

	return [ map {
		_renderAlbum($_, $addArtistToTitle);
	} @$results ];
}

sub _renderAlbum {
	my ($item, $addArtistToTitle) = @_;

	my $title = $item->{title};
	$title .= ' - ' . $item->{artist}->{name} if $addArtistToTitle;

	return {
		name => $title,
		line1 => $item->{title},
		line2 => $item->{artist}->{name},
		type => 'playlist',
		# we need the 'play' item for the actions to be visible...
		#favorites_url => 'deezer://album:' . $item->{id},
		play => 'deezer://album:' . $item->{id},
		itemActions => {
			info => {
				command   => ['deezer_favs', 'items'],
				fixedParams => { type => 'albums', id => $item->{id}, title => $title },
				#variables => [ 'url', 'url', 'name', 'name' ],
			},
		},
		url => \&getAlbum,
		image => Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder'),
		passthrough => [{
			id => $item->{id},
			title => $title,
		}],
	};
}

sub _renderRadio {
	my $item = shift;

	return {
		name => $item->{title},
		line1 => $item->{description},
		#favorites_url => 'deezer://radio:' . $item->{id},
		play => "deezer://radio/$item->{id}/tracks.dzr",
		url => "deezer://radio/$item->{id}/tracks.dzr",
		image => Plugins::Deezer::API->getImageUrl($item),
	};
}

sub _renderTracks {
	my ($tracks, $addArtistToTitle) = @_;

	return [ map {
		_renderTrack($_, $addArtistToTitle);
	} @$tracks ];
}

sub _renderTrack {
	my ($item, $addArtistToTitle) = @_;

	my $title = $item->{title};
	$title .= ' - ' . $item->{artist}->{name} if $addArtistToTitle;
	my $url = "deezer://$item->{id}." . Plugins::Deezer::API::getFormat();

	return {
		name => $title,
		line1 => $item->{title},
		line2 => $item->{artist}->{name},
		on_select => 'play',
		url => $url,
		play => $url,
		playall => 1,
		image => $item->{cover},
	};
}

sub _renderArtists {
	my ($client, $results) = @_;

	return [ map {
		_renderArtist($client, $_);
	} @$results ];
}

sub _renderArtist {
	my ($client, $item) = @_;

	my $items = [ {
		name => cstring($client, 'PLUGIN_DEEZER_TOP_TRACKS'),
		favorites_url => 'deezer://artist:' . $item->{id},
		favorites_title => "$item->{name} - " . cstring($client, 'PLUGIN_DEEZER_TOP_TRACKS'),
		type => 'playlist',	
		url => \&getArtistTopTracks,
		image => 'plugins/Deezer/html/charts.png',
		passthrough => [{ id => $item->{id} }],
	}, {
		name => cstring($client, 'ALBUMS'),
		url => \&getArtistAlbums,
		image => 'html/images/albums.png',
		passthrough => [{ id => $item->{id} }],
	}, {
		name => cstring($client, 'RADIO'),
		on_select => 'play',
		#favorites_url => 'deezer://artist-radio:' . $item->{id},
		favorites_title => "$item->{name} - " . cstring($client, 'RADIO'),
		play => "deezer://artist/$item->{id}/radio.dzr",
		url => "deezer://artist/$item->{id}/radio.dzr",
		image => 'plugins/Deezer/html/smart_radio.png',
	}, {
		name => cstring($client, 'PLUGIN_DEEZER_RELATED'),
		url => \&getArtistRelated,
		image => 'html/images/artists.png',
		passthrough => [{ id => $item->{id} }],
	} ];

	return {
		name => $item->{name},
		type => 'outline',
		items => $items,
		itemActions => {
			info => {
				command   => ['deezer_favs', 'items'],
				fixedParams => { type => 'artists', id => $item->{id}, title => $item->{name} },
			},
		},
		image => Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder'),
	};
}

sub _renderCompound {
	my ($client, $item) = @_;

	my $items = [];

	push @$items, {
		name => cstring($client, 'PLAYLISTS'),
		items => _renderPlaylists($item->{playlists}),
		type  => 'outline',
		image => 'html/images/playlists.png',
	} if $item->{playlists};

	push @$items, {
		name => cstring($client, 'ARTISTS'),
		items => _renderArtists($client, $item->{artists}),
		type  => 'outline',
		image => 'html/images/artists.png',
	} if $item->{artists};

	push @$items, {
		name => cstring($client, 'ALBUMS'),
		items => _renderAlbums($item->{albums}),
		type  => 'outline',
		image => 'html/images/albums.png',
	} if $item->{albums};

	push @$items, {
		name => cstring($client, 'SONGS'),
		items => _renderTracks($item->{tracks}),
		type  => 'outline',
		image => 'html/images/playall.png',
	} if $item->{tracks};

	return $items;
}

sub _renderGenre {
	my ($client, $item, $renderer) = @_;

	my $items = [ {
		name => cstring($client, 'ARTISTS'),
		type  => 'link',
		url   => \&getGenreItems,
		image => 'html/images/artists.png',
		passthrough => [ { id => $item->{id}, type => 'artists' } ],
	}, {
		name => cstring($client, 'RADIO'),
		type  => 'link',
		url   => \&getGenreItems,
		image => 'plugins/Deezer/html/smart_radio.png',
		passthrough => [ { id => $item->{id}, type => 'radios' } ],
	} ];

	return {
		name => $item->{name},
		type => 'outline',
		items => $items,
		image => Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder', 'genre'),
		passthrough => [ { id => $item->{id} } ],
	};
}

sub getAPIHandler {
	my ($client) = @_;

	my $api;

	if (ref $client) {
		$api = $client->pluginData('api');

		if ( !$api ) {
			# if there's no account assigned to the player, just pick one
			if ( !$prefs->client($client)->get('userId') ) {
				my $userId = Plugins::Deezer::API->getSomeUserId();
				$prefs->client($client)->set('userId', $userId) if $userId;
			}

			$api = $client->pluginData( api => Plugins::Deezer::API::Async->new({
				client => $client
			}) );
		}
	}
	else {
		$api = Plugins::Deezer::API::Async->new({
			userId => Plugins::Deezer::API->getSomeUserId()
		});
	}

	logBacktrace("Failed to get a Deezer API instance: $client") unless $api;

	return $api;
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
		url => \&search,
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
		url => \&search,
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
		url => \&search,
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
		url       => \&search,
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
	$log->error(Data::Dump::dump($artist, $remoteMeta));

	my $query = 'artist:' . "\"$artist\" ";
	main::INFOLOG && $log->is_info && $log->info("Getting info with query $query");

	return {
		type      => 'link',
		name      => cstring($client, 'PLUGIN_DEEZER_ON_DEEZER'),
		url       => \&search,
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

			getAPIHandler($client)->artist(sub {
				my $items = _renderArtist( $client, $_[0] ) if $_[0];
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


1;