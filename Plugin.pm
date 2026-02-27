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
use Plugins::Deezer::PodcastProtocolHandler;
use Plugins::Deezer::Custom;
use Plugins::Deezer::InfoMenu;

my $log = Slim::Utils::Log->addLogCategory({
	'category'    => 'plugin.deezer',
	'description' => 'PLUGIN_DEEZER_NAME',
});

my $prefs = preferences('plugin.deezer');

# Notes for the forgetful on feeds

# We need a 'play' with a URL, not a CODE in items for actions to be visible. It is because
# xmlbrowser.html only insert a M(ore) link if there is a playlink (or nothing at all).
# Unfortunately, then LMS forces favorite's type to be 'audio' and that prevents proper 
# explodePlayList when browsing (not playing) favorite later (because 'audio' type don't 
# need to be 'exploded' except for playing. This is fixed in https://github.com/LMS-Community/slimserver/pull/1008

# Now, if we set a 'play', then when drilling down from JSON/Jive, S::C::XMLBrowser does not 
# expand to last level and does a play one level too high (it thinks it has a play). So we
# need to either change xmlbrowser.html to adde M(ore) in all cases or we set manually all
# the actions (play, add, insert and delete)

# Also, don't use a URL for 'url' instead of a CODE otherwise explodePlaylist is used when
# browsing and then the passthrough is ignored and obviously anything important there is lost
# or it would need to be in the URL as well.

# Similiarly, if type is 'audio' then the OPML manager does not need to call explodePlaylist
# and if we also add an 'info' action this can be called when clicking on the item (classic)
# or on the (M)ore icon. If there is no 'info' action, clicking on an 'audio' item displays
# little about it, except bitrate and duration if set in the item (only for classic)

# Also, when type is not 'audio', we can set an 'items' action that is executed in classic
# when clicking on item and won't make M(ore) context menu visible and it is ignored in material
# so that's a bit useless.

# Actions can be directly in the feed in which case they are global on they can be in each item
# named 'itemActions'. They use cliQuery and require a AddDispatch with a matching command. See
# comment on finding a root/anchor when using JSONRPC interface
# The 'fixedParams' are hashes on strings that will be retrieved by getParams or using 'variables'
# they can be extracted from items themselves. It's an array of pairs of key in the item and key
# in the query variables => [ 'url', 'url' ]

# We can't re-use Slim::Menu::TrackInfo to create actions using the 'menu' method as it can only
# create track objects for items that are in the database, unless the ObjectForUrl has some way
# to have PH overload a method to create the object, but I've not found that anywhere in Schema
# Now, the PH can overload trackInfoUrl which shortcuts the whole Slim::Menu::TrackInfo and returns
# a feed but I'm not sure I see the real benefit in doing that, especially because this does not
# exist for albumInfo/artistInfo and also you still need to manually create the action in items.

# TODO
# - add some notes on creating usable links on trackInfo/albuminfo/artistsinfo

sub initPlugin {
	my $class = shift;

	$prefs->init({
		liverate => 128,
		liveformat => 'mp3',
		quality => 'HIGH',
		serial => '29436f4b2c5b2b552e4c221b2d7c7a4e7a336c002d7278512e486f1f2c677d432b1c224e29522c0b280e7f42750f7b43794a271c7d652b06744c5454795f6c4e781f51197d742e077b5b344e7b0e694d7e4c271e2c1c7c032c4f794e786060062b4260432f306b40',
		unfold_collection => 1,
	});

	# reset the API ref when a player changes user
	$prefs->setChange( sub {
		my ($pref, $userId, $client) = @_;
		$client->pluginData(api => 0);
	}, 'userId');

	Plugins::Deezer::API::Auth->init();
	Plugins::Deezer::ProtocolHandler->init();
	Plugins::Deezer::API::Async->init();
	Plugins::Deezer::InfoMenu->init();

	if (main::WEBUI) {
		require Plugins::Deezer::Settings;
		Plugins::Deezer::Settings->new();
	}

	Slim::Player::ProtocolHandlers->registerHandler('deezer', 'Plugins::Deezer::ProtocolHandler');
	Slim::Player::ProtocolHandlers->registerHandler('deezerpodcast', 'Plugins::Deezer::PodcastProtocolHandler');
	Slim::Music::Import->addImporter('Plugins::Deezer::Importer', { use => 1 });

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'deezer',
		menu   => 'apps',
		is_app => 1,
	);

	Slim::Menu::TrackInfo->registerInfoProvider( deezer => (
		after => 'bottom',
		func  => \&Plugins::Deezer::InfoMenu::trackInfoMenu,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( deezer => (
		after => 'bottom',
		func  => \&Plugins::Deezer::InfoMenu::artistInfoMenu,
	) );

	Slim::Menu::AlbumInfo->registerInfoProvider( deezer => (
		after => 'bottom',
		func  => \&Plugins::Deezer::InfoMenu::albumInfoMenu,
	) );

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

sub postinitPlugin {
	my $class = shift;

	# if user has the Don't Stop The Music plugin enabled, register ourselves
	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_DEEZER_DSTM_SMART_RADIO', sub {
			my ($client, $cb) = @_;

			my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, 50);

			# don't seed from radio stations - only do if we're playing from some track based source
			if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
				main::INFOLOG && $log->info("Creating Deezer Smart Radio from random items in current playlist");

				# get the most frequent artist in our list
				my %artists;

				foreach (@$seedTracks) {
					$artists{$_->{artist}}++;
				}

				# split "feat." etc. artists
				my @artists;
				foreach (keys %artists) {
					if ( my ($a1, $a2) = split(/\s*(?:\&|and|feat\S*)\s*/i, $_) ) {
						push @artists, $a1, $a2;
					}
				}

				unshift @artists, sort { $artists{$b} <=> $artists{$a} } keys %artists;

				dontStopTheMusic($client, $cb, @artists);
			}
			else {
				$cb->($client);
			}
		});

		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_DEEZER_DSTM_FLOW', sub {
			$_[1]->($_[0], ['deezer://user/me/flow.dzr']);
		});
	}

	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::OnlineLibrary::Plugin') ) {
		Slim::Plugin::OnlineLibrary::Plugin->addLibraryIconProvider('deezer', '/plugins/Deezer/html/logo.png');

		Slim::Plugin::OnlineLibrary::BrowseArtist->registerBrowseArtistItem( deezer => sub {
			my ( $client ) = @_;

			return {
				name => cstring($client, 'BROWSE_ON_SERVICE', 'Deezer'),
				type => 'link',
				icon => $class->_pluginDataFor('icon'),
				url  => \&Plugins::Deezer::InfoMenu::browseArtistMenu,
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

	# if user has the Don't Stop The Music plugin enabled, register ourselves
	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_DEEZER_DSTM_SMART_RADIO', sub {
			my ($client, $cb) = @_;

			my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, 50);

			# don't seed from radio stations - only do if we're playing from some track based source
			if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
				main::INFOLOG && $log->info("Creating Deezer Smart Radio from random items in current playlist");

				# get the most frequent artist in our list
				my %artists;

				foreach (@$seedTracks) {
					$artists{$_->{artist}}++;
				}

				# split "feat." etc. artists
				my @artists;
				foreach (keys %artists) {
					if ( my ($a1, $a2) = split(/\s*(?:\&|and|feat\S*)\s*/i, $_) ) {
						push @artists, $a1, $a2;
					}
				}

				unshift @artists, sort { $artists{$b} <=> $artists{$a} } keys %artists;

				dontStopTheMusic($client, $cb, @artists);
			}
			else {
				$cb->($client);
			}
		});

		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_DEEZER_DSTM_FLOW', sub {
			$_[1]->($_[0], ['deezer://user/me/flow.dzr']);
		});
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
	
	my $userId = getAPIHandler($client)->userId;

	my $items = [ {
		name => cstring($client, 'HOME'),
		image => 'plugins/Deezer/html/home.png',
		type => 'link',
		url => \&Plugins::Deezer::Custom::getHome,
	},{
		name => cstring($client, 'PLUGIN_DEEZER_EXPLORE'),
		image => 'plugins/Deezer/html/radio.png',
		type  => 'link',
		url => \&Plugins::Deezer::Custom::getWebItems,
	},{
		name => cstring($client, 'PLUGIN_DEEZER_FLOW'),
		image => 'plugins/Deezer/html/flow.png',
		play => 'deezer://user.flow',
		type => 'outline',
		items => [{
			name => cstring($client, 'PLUGIN_DEEZER_FLOW'),
			image => 'plugins/Deezer/html/flow.png',
			on_select => 'play',
			type => 'audio',
			url => 'deezer://user.flow',
			play => 'deezer://user.flow',
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
		},{
			name => cstring($client, $prefs->get($userId . ':flow') ? 'PLUGIN_DEEZER_FLOW_DISCOVERY' : 'PLUGIN_DEEZER_FLOW_DEFAULT'),
			image => 'plugins/Deezer/html/settings.png',
			type => 'link',
			url => sub {
				my ($client, $cb) = @_;
				my $currentUserId = getAPIHandler($client)->userId;
				my $flow = !$prefs->get($currentUserId . ':flow');
				$prefs->set($currentUserId . ':flow', $flow);
				$cb->({ items => [{
					type => 'text',
					name => cstring($client, $flow ? 'PLUGIN_DEEZER_FLOW_DISCOVERY' : 'PLUGIN_DEEZER_FLOW_DEFAULT'),
				}] });
			},
		},
		],
	},{
		name  => cstring($client, 'PLUGIN_DEEZER_COLLECTION'),
		image => 'html/images/musicfolder.png',
		type => 'outline',
		unfold => $prefs->get('unfold_collection'),
		items => [ {
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
		# },{
			# name => cstring($client, 'PODCASTS'),
			# image => 'plugins/Deezer/html/podcast.png',
			# type => 'link',
			# url => \&getFavorites,
			# passthrough => [{ type => 'podcasts' }],
		},{
			name => cstring($client, 'PLUGIN_DEEZER_PERSONAL'),
			image => 'plugins/Deezer/html/personal.png',
			type  => 'link',
			url   => \&getPersonal,
		} ]		
	}, {
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
		passthrough => [{ path => 'chart' }],
	},{
		name => cstring($client, 'PLUGIN_PODCAST'),
		image => 'plugins/Deezer/html/rss.png',
		type  => 'link',
		url   => \&getPodcasts,
	},{
		name  => cstring($client, 'SEARCH'),
		image => 'html/images/search.png',
		type => 'outline',
		items => [ {
			name => cstring($client, 'PLAYLISTS'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/playlists.png',
			passthrough => [{ type => 'playlist' }],
		},{
			name => cstring($client, 'ARTISTS'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/artists.png',
			passthrough => [{ type => 'artist' }],
		},{
			name => cstring($client, 'ALBUMS'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/albums.png',
			passthrough => [{ type => 'album' }],
		},{
			name => cstring($client, 'SONGS'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/playall.png',
			passthrough => [{ type => 'track' }],
		},{
			name => cstring($client, 'PLUGIN_DEEZER_SMART_RADIO'),
			type  => 'search',
			url   => \&search,
			# image => 'plugins/Deezer/html/smart_radio.png',
			passthrough => [{ type => 'radio' }],
		},{
			name => cstring($client, 'PLUGIN_PODCAST'),
			type  => 'search',
			url   => \&search,
			passthrough => [{ type => 'podcast' }],
		} ],
	}, {
		name => cstring($client, 'PLUGIN_DEEZER_HISTORY'),
		image => 'plugins/Deezer/html/history.png',
		type  => 'link',
		url   => \&getHistory,
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

		$items = [ map { renderItem($client, $_, { addArtistToTitle => 1 }) } @$items ] if $items;

		$cb->( { items => $items } );
	}, $params->{type}, $args->{quantity} != 1 );
}

sub getArtistAlbums {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->artistAlbums(sub {
		my $items = _renderAlbums(@_, { artist => $params->{name} });

		# the action can be there or in the sub-item as an itemActions
		$cb->( { items => $items } );
	}, $params->{id});
}

sub getArtistTopTracks {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->artistTopTracks(sub {
		my $items = _renderTracks(@_);
		$cb->( { items => $items } );
	}, $params->{id});
}

sub getArtistRelated {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->artistRelated(sub {
		my $items = _renderArtists($client, @_);
		$cb->( { items => $items } );
	}, $params->{id});
}

sub getAlbum {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->albumTracks(sub {
		my $items = _renderTracks(shift);
		$cb->( { items => $items } );
	}, $params->{id} );
}

sub getGenres {
	my ( $client, $callback ) = @_;

	getAPIHandler($client)->genres(sub {
		my $items = [ map { _renderGenreMusic($client, $_) } @{$_[0]} ];

		$callback->( { items => $items } );
	});
}

sub getFlow {
	my ( $client, $callback, $args, $params ) = @_;

	my $mode = $params->{mode} =~ /genre/ ? 'genre' : 'mood';
	my @categories = $mode eq 'genre' ?
					( 'pop', 'rap', 'rock', 'alternative', 'kpop', 'jazz', 'classical',
					  'chanson', 'reggae', 'latin', 'soul', 'variete', 'lofi', 'rnb',
					  'danceedm', 'empowerment' ) :
					( 'motivation', 'party', 'chill', 'melancholy', 'you_and_me', 'focus');

	my $items = [ map {
		{
			name => cstring($client, 'PLUGIN_DEEZER_' . uc($_)),
			on_select => 'play',
			play => "deezer://$mode:" . $_ . '.flow',
			url => "deezer://$mode:" . $_ . '.flow',
			image => 'plugins/Deezer/html/' . $_ . '.png',
		}
	} @categories ];

	$callback->( { items => $items } );
}

sub getRadios {
	my ( $client, $callback ) = @_;

	getAPIHandler($client)->radios(sub {
		my $items = [ map { renderItem($client, $_) } @{$_[0]} ];

		$callback->( { items => $items } );
	});
}

sub getHistory {
	my ( $client, $callback ) = @_;

	getAPIHandler($client)->history(sub {
		my $items = _renderTracks( $_[0], { addArtistToTitle => 1 } );

		$callback->( { items => $items } );
	});
}

sub getPersonal {
	my ( $client, $callback ) = @_;

	getAPIHandler($client)->personal(sub {
		my $items = _renderTracks( $_[0], { addArtistToTitle => 1 } );

		$callback->( { items => $items } );
	});
}

sub getGenreItems {
	my ( $client, $cb, $args, $params ) = @_;
	getAPIHandler($client)->genreByType(sub {

		my $items = [ map { renderItem($client, $_, { addArtistToTitle => 1 } ) } @{$_[0]} ];

		$cb->( { items => $items } );
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

sub getPlaylist {
	my ( $client, $cb, $args, $params ) = @_;

	my $api = getAPIHandler($client);

	# we'll only set playlist id we own it so that we can remove track later
	my $renderArgs = {
		playlistId => $params->{id}
	} if $api->userId eq $params->{creatorId};

	$api->playlistTracks(sub {
		my $items = _renderTracks($_[0], $renderArgs);
		$cb->( { items => $items } );
	}, $params->{id} );
}

sub getPodcasts {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->podcasts(sub {
		my $items = [ map { _renderGenrePodcast($_) } @{$_[0]} ];

		unshift @$items, {
			name => cstring($client, 'FAVORITES'),
			url => \&getFavorites,
			passthrough => [{ type => 'podcasts' }],
		};

		$cb->( { items => $items } );
	});
}

sub getPodcastEpisodes {
	my ( $client, $cb, $args, $params ) = @_;

	getAPIHandler($client)->podcastEpisodes(sub {
		my $items = _renderEpisodes($_[0]);

		$cb->( { items => $items } );
	}, $params->{id}, $params->{podcast} );

}

sub search {
	my ($client, $cb, $args, $params) = @_;

	$args->{search} ||= $params->{query};
	$args->{type} = $params->{type};
	$args->{strict} = $params->{strict} || 'off';

	getAPIHandler($client)->search(sub {
		my $items = shift;
		$items = [ map { renderItem($client, $_) } @$items ] if $items;

		$cb->( { items => $items || [] } );
	}, $args);

}

sub renderItem {
	my ($client, $item, $args) = @_;

	my $type = Plugins::Deezer::API->typeOfItem($item);
	$args ||= {};

	if ($type eq 'track') {
		return _renderTrack($item, $args->{addArtistToTitle}, $args->{playlistId});
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
=comment
	elsif ($type eq 'genre') {
		return _renderGenre($client, $item, $args->{handler});
	}
=cut
	elsif ($type eq 'podcast') {
		return _renderPodcast($item);
	}
	elsif ($type eq 'episode') {
		return _renderEpisode($item);
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
		favorites_type => 'playlist',
		# see note above
		# play => 'deezer://playlist:' . $item->{id},
		type => 'playlist',
		itemActions => {
			info => {
				command   => ['deezer_info', 'items'],
				fixedParams => {
					type => 'playlist',
					id => $item->{id},
				},
			},
			play => _makeAction('play', 'playlist', $item->{id}),
			add => _makeAction('add', 'playlist', $item->{id}),
			insert => _makeAction('insert', 'playlist', $item->{id}),
		},
		url => \&getPlaylist,
		image => Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder'),
		passthrough => [ { id => $item->{id}, creatorId => $item->{creator}->{id} } ],
	};
}

sub _renderAlbums {
	my ($results, $args) = @_;

	return [ map {
		_renderAlbum($_, $args->{addArtistToTitle}, $args->{artist});
	} @$results ];
}

sub _renderAlbum {
	my ($item, $addArtistToTitle, $artist) = @_;

	my $title = $item->{title};
	$title .= ' - ' . ($item->{artist}->{name} || $artist) if $addArtistToTitle;

	return {
		name => $title,
		line1 => $item->{title},
		line2 => $item->{artist}->{name},
		type => 'playlist',
		favorites_title => $item->{title} . ' - ' . ($item->{artist}->{name} || $artist),
		favorites_type => 'playlist',
		favorites_url => 'deezer://album:' . $item->{id},
		# see note above
		# play => 'deezer://album:' . $item->{id},
		itemActions => {
			info => {
				command   => ['deezer_info', 'items'],
				fixedParams => {
					type => 'album',
					id => $item->{id},
				},
			},
			play => _makeAction('play', 'album', $item->{id}),
			add => _makeAction('add', 'album', $item->{id}),
			insert => _makeAction('insert', 'album', $item->{id}),
		},
		image => Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder'),
		url => \&getAlbum,
		passthrough => [ { id => $item->{id} } ],
	};
}

sub _renderRadio {
	my $item = shift;

	return {
		name => $item->{title},
		line1 => $item->{description},
		on_select => 'play',
		play => "deezer://radio/$item->{id}/tracks.dzr",
		url => "deezer://radio/$item->{id}/tracks.dzr",
		image => Plugins::Deezer::API->getImageUrl($item),
	};
}

sub _renderTracks {
	my ($tracks, $args) = @_;

	return [ map {
		_renderTrack($_, $args->{addArtistToTitle}, $args->{playlistId});
	} @$tracks ];
}

sub _renderTrack {
	my ($item, $addArtistToTitle, $playlistId) = @_;

	my $title = $item->{title};
	$title .= ' - ' . $item->{artist}->{name} if $addArtistToTitle;
	my $url = "deezer://$item->{id}." . Plugins::Deezer::API::getFormat();

	return {
		name => $title,
		favorites_title => $item->{title} . ' - ' . $item->{artist}->{name},
		line1 => $item->{title},
		line2 => $item->{artist}->{name},
		on_select => 'play',
		url => $url,
		play => $url,
		playall => 1,
		image => $item->{cover},
		type => 'audio',
		itemActions => {
			info => {
				command   => ['deezer_info', 'items'],
				fixedParams => {
					type => 'track',
					id => $item->{id},
					playlistId => $playlistId,
				},
			},
		},
	};
}

sub _renderPodcasts {
	my ($podcasts) = @_;

	return [ map {
		_renderPodcast($_);
	} @$podcasts ];
}

sub _renderPodcast {
	my ($item) = @_;

	return {
		name => $item->{title},
		line1 => $item->{title},
		line2 => $item->{description},
		favorites_url => 'deezer://podcast:' . $item->{id},
		# see note above
		# play => 'deezer://podcast:' . $item->{id},
		type => 'playlist',
		itemActions => {
			info => {
				command   => ['deezer_info', 'items'],
				fixedParams => {
					type => 'podcast',
					id => $item->{id},
				},
			},
			play => _makeAction('play', 'podcast', $item->{id}),
			add => _makeAction('add', 'podcast', $item->{id}),
			insert => _makeAction('insert', 'podcast', $item->{id}),
		},
		url => \&getPodcastEpisodes,
		image => Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder'),
		passthrough => [ {
			id => $item->{id},
			podcast => $item,
		} ],
	};
}

sub _renderEpisodes {
	my ($episodes) = @_;

	return [ map {
		_renderEpisode($_);
	} @$episodes ];
}

sub _renderEpisode {
	my ($item) = @_;

	my $url = "deezerpodcast://$item->{id}";

	return {
		name => $item->{title},
		type => 'audio',
		on_select => 'play',
		playall => 1,
		play => $url,
		url => $url,
		image => $item->{cover},
		itemActions => {
			info => {
				command   => ['deezer_info', 'items'],
				fixedParams => {
					type => 'episode',
					id => $item->{id},
				},
			},
		},
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

	my $image = Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder');

	my $items = [ {
		name => cstring($client, 'PLUGIN_DEEZER_TOP_TRACKS'),
		favorites_url => 'deezer://artist:' . $item->{id},
		favorites_title => "$item->{name} - " . cstring($client, 'PLUGIN_DEEZER_TOP_TRACKS'),
		favorites_icon => $image,
		type => 'playlist',
		url => \&getArtistTopTracks,
		image => 'plugins/Deezer/html/charts.png',
		passthrough => [{ id => $item->{id} }],
	}, {
		type => 'link',
		name => cstring($client, 'ALBUMS'),
		url => \&getArtistAlbums,
		image => 'html/images/albums.png',
		passthrough => [ {
			id => $item->{id},
			name => $item->{name},
		} ],
	}, {
		name => cstring($client, 'PLUGIN_DEEZER_SMART_RADIO'),
		on_select => 'play',
		favorites_title => "$item->{name} - " . cstring($client, 'PLUGIN_DEEZER_SMART_RADIO'),
		favorites_icon => $image,
		type => 'audio',
		play => "deezer://artist/$item->{id}/radio.dzr",
		url => "deezer://artist/$item->{id}/radio.dzr",
		image => 'plugins/Deezer/html/smart_radio.png',
	}, {
		type => 'link',
		name => cstring($client, 'PLUGIN_DEEZER_RELATED'),
		url => \&getArtistRelated,
		image => 'html/images/artists.png',
		passthrough => [{ id => $item->{id} }],
	} ];

	return {
		name => $item->{name} || $item->{title},
		type => 'outline',
		items => $items,
		itemActions => {
			info => {
				command   => ['deezer_info', 'items'],
				fixedParams => {
					type => 'artist',
					id => $item->{id},
				},
			},
		},
		image => $image,
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
		items => _renderAlbums($item->{albums}, { addArtistToTitle => 1 }),
		type  => 'outline',
		image => 'html/images/albums.png',
	} if $item->{albums};

	push @$items, {
		name => cstring($client, 'SONGS'),
		items => _renderTracks($item->{tracks}, { addArtistToTitle => 1 }),
		type  => 'outline',
		image => 'html/images/playall.png',
	} if $item->{tracks};

	push @$items, {
		name => cstring($client, 'PLUGIN_PODCAST'),
		items => _renderPodcasts($item->{podcasts}),
		type  => 'outline',
		image => 'plugins/Deezer/html/rss.png',
	} if $item->{podcasts};

	return $items;
}

sub _renderGenreMusic {
	my ($client, $item, $renderer) = @_;

	my $items = [ {
		name => cstring($client, 'ARTISTS'),
		type  => 'link',
		url   => \&getGenreItems,
		image => 'html/images/artists.png',
		passthrough => [ { id => $item->{id}, type => 'artists' } ],
	}, {
		name => cstring($client, 'PLUGIN_DEEZER_SMART_RADIO'),
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

sub _renderGenrePodcast {
	my ($item) = @_;

	return {
		name => $item->{name},
		url => \&getGenreItems,
		# there is no usable icon/image
		passthrough => [ {
			id => $item->{id},
			type => 'podcasts',
		} ],
	};
}

sub _makeAction {
	my ($action, $type, $id) = @_;
	return {
		command => ['deezer_browse', 'playlist', $action],
		fixedParams => {
			type => $type, 
			id => $id,
		},
	};
}

sub getAPIHandler {
	my ($client) = @_;

	my $api;

	if (ref $client) {
		$api = $client->pluginData('api');

		if ( !$api ) {
			my $userdata = Plugins::Deezer::API->getUserdata($prefs->client($client)->get('userId'));

			# if there's no account assigned to the player, just pick one
			if ( !$userdata ) {
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

sub dontStopTheMusic {
	my $client  = shift;
	my $cb      = shift;
	my $nextArtist = shift;
	my @artists = @_;

	if ($nextArtist) {
		getAPIHandler($client)->search(sub {
			my $artists = shift || [];

			my ($track) = map {
				"deezer://artist/$_->{id}/radio.dzr"
			} grep {
				$_->{radio}
			} @$artists;

			if ($track) {
				$cb->($client, [$track]);
			}
			else {
				dontStopTheMusic($client, $cb, @artists);
			}
		},{
			search => $nextArtist,
			type => 'artist',
			# strict => 'off'
		});
	}
	else {
		main::INFOLOG && $log->is_info && $log->info("No matching Smart Radio found for current playlist!");
		$cb->($client);
	}
}


1;