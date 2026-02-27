package Plugins::Deezer::Custom;

use strict;
use feature 'state';

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape);
use Digest::MD5 qw(md5_hex);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::Deezer::API;
use Plugins::Deezer::LiveProtocolHandler;

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.deezer');
my $prefs = preferences('plugin.deezer');
my $sprefs = preferences('server');

# ------------------------------- Home ------------------------------

sub getHome {
	my ( $client, $cb, $args, $params ) = @_;

	my $api = Plugins::Deezer::Plugin::getAPIHandler($client);

	_home($api, sub {
		my $sections = shift;
		my $items = [];

		foreach my $section (@$sections) {
			my $sectionItems = [ grep { $_->{type} !~ /channel/ } @{$section->{items}} ];
			next unless @$sectionItems;

			push @$items, {
				title => $section->{title},
				type => 'link',
				url => \&getHomeSection,
				passthrough => [ {
					entries => $sectionItems,
					title => $section->{title},
				} ],
			};
		}

		$cb->( { items => $items } );
	} );
}

sub getHomeSection {
	my ( $client, $cb, $args, $params ) = @_;

	my $items = [];

	foreach my $entry (@{$params->{entries}}) {
		my $item = {
			id => $entry->{id},
			md5_image => $entry->{pictures}->[0]->{md5},
			picture_type => $entry->{pictures}->[0]->{type},
			artist => { name => $entry->{data}->{ART_NAME} },
		};

		if ($entry->{target} =~ /mix=true/) {
			$item = {
				%$item,
				title => $entry->{title} . ' - ' . $entry->{data}->{ART_NAME},
				image => Plugins::Deezer::API->getImageUrl($item, 'usePlaceholder', 'track'),
				type => 'playlist',
				url => \&_getTarget,
				passthrough => [ {
					id => $item->{id},
					handler => \&_mixes,
				} ],
			};
		} elsif ($entry->{type} =~ /smarttracklist/) {
			$item = {
				%$item,
				title => $entry->{title} . ' - ' . $entry->{subtitle},
				image => Plugins::Deezer::API->getImageUrl( {
					md5_image => $entry->{cover}->{md5},
					picture_type => $entry->{cover}->{type},
				}, 'usePlaceholder', 'artist'),
				type => 'playlist',
				url => \&_getTarget,
				passthrough => [ {
					id => $item->{id},
					handler => \&_smart,
				} ],
			};
		} elsif ($entry->{type} =~ /show|livestream/) {
			# this comes from radio/podcast previous streaming (for "continue streaming")
			$item = _renderItem($client, $entry);
		} elsif (Plugins::Deezer::API->typeOfItem($entry)) {
			# this is regular items supported by mainline (can come from "continue streaming")
			$item = {
				%$item,
				title => $entry->{title},
				type => $entry->{type},
			};
			$item = Plugins::Deezer::Plugin::renderItem($client, $item, { addArtistToTitle => 1 });
		} else {
			next;
		}

		push @$items, $item;
	}

	$cb->( { items => $items } );
}

sub _getTarget {
	my ( $client, $cb, $args, $params ) = @_;

	my $api = Plugins::Deezer::Plugin::getAPIHandler($client);

	$params->{handler}->( $api, sub {
		my $items = [ map { Plugins::Deezer::Plugin::renderItem($client, $_) } @{$_[0]} ];
		$cb->( { items => $items } );
	}, $params->{id} );
}

# ------------------------------ LiveRadio -----------------------------

sub getWebItems {
	my ( $client, $cb, $args, $params ) = @_;

	my $api = Plugins::Deezer::Plugin::getAPIHandler($client);

	_pageItems( $api, sub {
		my $modules = $_[0];

		my $items = [ {
			name => cstring($client, 'SEARCH'),
			type  => 'search',
			url   => \&search,
			# image => 'html/images/search.png',
		} ];

		foreach my $module (@$modules) {
			push @$items, _renderModule($client, $module) if $module->{target} =~ /channels|podcasts/;
		}

		$cb->( { items => $items || []} );
	}, "channels/radios" );
}

sub search {
	my ( $client, $cb, $args, $params ) = @_;

	$args->{search} ||= $params->{query};

	Plugins::Deezer::Plugin::getAPIHandler($client)->gwSearch(sub {
		my $results = shift;

		my $items = [];

		push @$items, {
			name => cstring($client, 'RADIO'),
			image => 'plugins/Deezer/html/radio.png',
			type => 'outline',
			items => _renderItems($client, $results->{LIVESTREAM}->{data}),
		} if $results->{LIVESTREAM}->{count};

		push @$items, {
			name => cstring($client, 'PLUGIN_DEEZER_CHANNELS'),
			image => 'plugins/Deezer/html/radio.png',
			type => 'outline',
			unfold => $results->{CHANNEL}->{count} == 1,
			items => _renderItems($client, $results->{CHANNEL}->{data}),
		} if $results->{CHANNEL}->{count};

		push @$items, {
			name => cstring($client, 'PLUGIN_PODCAST'),
			image => 'plugins/Deezer/html/podcast.png',
			type => 'outline',
			items => _renderItems($client, $results->{SHOW}->{data}),
		} if $results->{SHOW}->{count};

		# for episodes, we can cache them an re-use usual backend
		if ($results->{EPISODE}->{count}) {
			my $episodes = _cacheEpisodeMetadata($results->{EPISODE}->{data});
			push @$items, {
				name => cstring($client, 'PLUGIN_DEEZER_EPISODES'),
				image => 'plugins/Deezer/html/rss.png',
				type => 'outline',
				items => [ map { Plugins::Deezer::Plugin::renderItem($client, $_)} @$episodes ],
			};
		}

		$cb->( { items => $items } );
	}, $args);
}

sub getItems {
	my ( $client, $cb, $args, $params ) = @_;

	if ( $params->{items} ) {
		main::INFOLOG && $log->is_info && $log->info("Already got everything for $params->{target}");
		my $items = _renderItems($client, $params->{items});

		$cb->( { items => $items || []} );
	} else {
		my $api = Plugins::Deezer::Plugin::getAPIHandler($client);

		main::INFOLOG && $log->is_info && $log->info("Fetching all items for $params->{target}");
		_pageItems( $api, sub {
			my $sections = shift;

			my $items = scalar @$sections == 1 ?
						_renderItems($client, $sections->[0]->{items}) :
						[ map { _renderModule($client, $_) } @$sections ];

			$cb->( { items => $items || []} );
		}, $params->{target} );
	}
}

sub _renderModule {
	my ($client, $entry) = @_;

	my $passthrough = { target => $entry->{target} };
	$passthrough->{items} = $entry->{items} unless $entry->{hasMoreItems};

	# make single livestream entry directly accessible
	if ( @{$passthrough->{items} || []} == 1 && $passthrough->{items}->[0]->{type} eq 'livestream' ) {
		my $item = _renderItem($client, $passthrough->{items}->[0]);
		$item->{favorites_icon} = delete $item->{image};
		$item->{name} = $entry->{title};
		return $item;
	}

	return {
		title => $entry->{title},
		type => 'link',
		url => \&getItems,
		passthrough => [ $passthrough ],
	};
}

sub _renderItems {
	my ($client, $results) = @_;

	return [ map {
		_renderItem($client, $_)
	} @$results ];
}

sub _renderItem {
	my ($client, $entry) = @_;

	if ( $entry->{type} eq 'livestream' ) {

		my $image = Plugins::Deezer::API->getImageUrl( {
						md5_image => $entry->{pictures}->[0]->{md5},
						picture_type => $entry->{pictures}->[0]->{type},
		}, 'usePlaceholder', 'live');
		$cache->set("deezer_live_image_$entry->{id}", $image, '30 days');

		return {
			name => $entry->{title},
			favorites_title => $entry->{title} . ' - ' . cstring($client, 'PLUGIN_DEEZER_ON_DEEZER'),
			type => 'audio',
			url => "deezerlive://$entry->{id}",
			image => $image,
		};

	} elsif ( $entry->{__TYPE__} eq 'livestream' ) {

		my $image = Plugins::Deezer::API->getImageUrl( {
						md5_image => $entry->{LIVESTREAM_IMAGE_MD5},
		}, 'usePlaceholder', 'live');
		$cache->set("deezer_live_image_$entry->{LIVESTREAM_ID}", $image, '30 days');

		return {
			name => $entry->{LIVESTREAM_TITLE},
			favorites_title => $entry->{LIVESTREAM_TITLE} . ' - ' . cstring($client, 'PLUGIN_DEEZER_ON_DEEZER'),
			type => 'audio',
			url => "deezerlive://$entry->{LIVESTREAM_ID}",
			image => $image,
		};

	} elsif ( $entry->{type} eq 'show' ) {

		# fabricate an expected podcast entry to fit existing model
		my $item = {
			title => $entry->{title},
			description => $entry->{description},
			id => $entry->{id},
			type => 'podcast',
			md5_image => $entry->{pictures}->[0]->{md5},
			picture_type => $entry->{pictures}->[0]->{type},
		};

		return Plugins::Deezer::Plugin::renderItem($client, $item);

	} elsif ( $entry->{__TYPE__} eq 'show' ) {

		# fabricate an expected podcast entry to fit existing model
		my $item = {
			title => $entry->{SHOW_NAME},
			description => $entry->{SHOW_DESCRIPTION},
			id => $entry->{SHOW_ID},
			type => 'podcast',
			md5_image => $entry->{SHOW_ART_MD5},
			picture_type => $entry->{SHOW_TYPE} || 'talk',
		};

		return Plugins::Deezer::Plugin::renderItem($client, $item);

	} elsif ( $entry->{type} eq 'channel' ) {

		my $image = $entry->{logo_image} || $entry->{pictures}->[0];
		my $passthrough = { target => $entry->{target} };
		$passthrough->{items} = $entry->{items} unless $entry->{hasMoreItems};

		main::INFOLOG && $log->is_info && $log->info("unknown item type", Data::Dump::dump($entry));

		return  {
			title => $entry->{title},
			type => 'link',
			url => \&getItems,
			favorites_title => $entry->{title} . ' - ' . cstring($client, 'PLUGIN_DEEZER_ON_DEEZER'),
			favorites_url => 'deezerlive://channel:' . $entry->{target},
			image => Plugins::Deezer::API->getImageUrl( {
						md5_image => $image->{md5},
						picture_type => $image->{type},
			}, 'usePlaceholder', 'channel'),
			passthrough => [ $passthrough ]
		}

	} elsif ( $entry->{type} eq 'playlist' ) {

		# fabricate an expected playlist entry to fit existing model
		$entry->{md5_image} = $entry->{pictures}->[0]->{md5};
		$entry->{picture_type} = $entry->{pictures}->[0]->{type};
		$entry->{creator}->{id} = $entry->{data}->{PARENT_USER_ID};
		$entry->{user}->{name} = 'n/a';

		return Plugins::Deezer::Plugin::renderItem($client, $entry);
	}

	main::INFOLOG && $log->is_info && $log->info("unknown item type", Data::Dump::dump($entry));
	return { };
}

#
# ========================= ASYNC package ==========================
#

# ------------------------------- Home ----------------------------

sub _home {
	my ($self, $cb) = @_;

	my $params = {
		_cacheKey => 'home:' . $sprefs->get('language') . '_' . $self->userId,
		method => 'page.get',
		gateway_input => encode_json( {
			PAGE => 'home',
			VERSION => '2.5',
			LANG => lc $sprefs->get('language'),
			SUPPORT => {
				'horizontal-grid' => ['album','artist','artistLineUp','channel','livestream','flow','playlist','radio','show','smarttracklist','track'],
				'horizontal-list' => ['track','song'],
				'long-card-horizontal-grid' => ['album','artist','artistLineUp','channel','livestream','flow','playlist','radio','show','smarttracklist','track'],
				'slideshow' => ['channel','livestream','playlist','show','smarttracklist','user'],
			}
		} )
	};

	_userQuery( $self, sub {
		my $results = $_[0]->{sections} if $_[0];
		$cb->($results || []);
	}, $params );
}

sub _mixes {
	my ($self, $cb, $id) = @_;

	my $params = {
		method => 'song.getSearchTrackMix',
	};

	my $content = {
		start_with_input_track => 'True',
		sng_id => $id,
	};

	_userQuery( $self, sub {
		my $mix = shift;
		my $tracks = _cacheTrackMetadata($mix->{data}) if $mix;
		$cb->($tracks || []);
	}, $params, $content );
}

sub _smart {
	my ($self, $cb, $id) = @_;

	my $params = {
		method => 'smartTracklist.getSongs',
	};

	my $content = {
		smartTracklist_id => $id,
	};

	_userQuery( $self, sub {
		my $smart = shift;
		my $tracks = _cacheTrackMetadata($smart->{data}) if $smart;
		$cb->($tracks || []);
	}, $params, $content );
}

# ------------------------------ WebRadio -----------------------------

sub _pageItems {
	my ( $self, $cb, $page ) = @_;

	my $params = {
		_cacheKey => 'web:' . $sprefs->get('language') . "_$page",
		method => 'page.get',
		gateway_input => encode_json( {
			PAGE => $page,
			VERSION => '2.5',
			LANG => lc $sprefs->get('language'),
			SUPPORT => {
				'grid' => ['channel','livestream','playlist','radio','show'],
				'horizontal-grid' => ['channel','livestream','flow','playlist','radio','show'],
				'long-card-horizontal-grid' => ['channel','livestream','flow','playlist','radio','show','smarttracklist','track'],
				'slideshow' => ['channel','livestream','playlist','show','smarttracklist','user'],
			}
		} )
	};

	_userQuery( $self, sub {
		my $results = $_[0]->{sections};
		$cb->($results || []);
	}, $params );
}

sub liveStream {
	my ( $self, $cb, $id ) = @_;

	$self->gwCall( sub {
		my $result = shift;
		my $urls = $result->{results}->{LIVESTREAM_URLS}->{data} if $result->{results}->{LIVESTREAM_URLS};
		$cb->($urls);
	}, {
		method => method => 'livestream.getData',
	}, {
		livestream_id => $id,
		supported_codecs => ['mp3', 'aac'],
	} );
}

# ------------------------------ Tools -----------------------------

sub _userQuery {
	my ($self, $cb, $params, $content) = @_;

	my $ttl = delete $params->{_ttl} || 15 * 60;
	my $cacheKey = delete $params->{_cacheKey};

	if (!$cacheKey) {
		# serialize query parameters and content but hash them as they can be
		# very lenghty (Perl hash key order is undetermined).
		$cacheKey = join(':', map {	$_ . $params->{$_} } sort grep { $_ !~ /^_/ } keys %$params );
		$cacheKey .= join(':', map { $_ . $content->{$_} } sort keys %$content) if $content && %$content;
		$cacheKey .= ':' . $self->userId if $self->userId;
		$cacheKey = md5_hex($cacheKey);
	}

	$cacheKey = 'deezer_custom_' . $cacheKey;
	main::INFOLOG && $log->is_info && $log->info("Getting 'custom' data with cachekey $cacheKey");

	if (my $cached = $cache->get($cacheKey)) {
		main::INFOLOG && $log->is_info && $log->info("Returning 'custom' data cached data for $cacheKey");
		$cb->($cached);
		return;
	}

	$self->gwCall( sub {
		my $results = $_[0]->{results} if $_[0];

		$cache->set($cacheKey, $results, $ttl) if $results;
		$cb->($results);
	}, $params, $content );
}

#
# ========================= API package ==========================
#

sub _cacheTrackMetadata {
	my ($tracks) = @_;
	return [] unless $tracks;

	return [ map {
		my $entry = $_;
		my $oldMeta = $cache->get('deezer_meta_' . $entry->{SNG_ID}) || {};
		my $icon = Plugins::Deezer::API->getImageUrl( {
			md5_image => $entry->{ALB_PICTURE},
			type => 'track',
			picture_type => 'cover',
		} );

		my $meta = {
			%$oldMeta,
			id => $entry->{SNG_ID},
			title => $entry->{SNG_TITLE},
			artist => { name => $entry->{ARTISTS}->[0]->{ART_NAME} },
			album => $entry->{ALB_TITLE},
			duration => $entry->{DURATION},
			icon => $icon,
			cover => $icon,
			# these are only available for some requests (usually individual tracks or /tracks endpoints)
			replay_gain => $entry->{GAIN} || 0,
			disc => $entry->{DISK_NUMBER},
			tracknum => $entry->{TRACK_NUMBER},
		};

		# make sure we won't come back
		$meta->{_complete} = 1 if $meta->{tracknum};

		# cache track metadata aggressively
		$cache->set( 'deezer_meta_' . $meta->{id}, $meta, '90days');

		$meta;
	} @$tracks ];
}

sub _cacheEpisodeMetadata {
	my ($episodes) = @_;
	return [] unless $episodes;

	return [ map {
		my $entry = $_;
		my $oldMeta = $cache->get( 'deezer_episode_meta_' . $entry->{EPISODE_ID}) || {};
		my $icon = Plugins::Deezer::API->getImageUrl( {
			md5_image => $entry->{EPISODE_IMAGE_MD5},
			type => 'episode',
			picture_type => 'talk',
		} );
		my $podcast = {
			id => $entry->{SHOW_ID},
			title => $entry->{SHOW_NAME},
			descrption => $entry->{SHOW_DESCRIPTION},
		};

		# consolidate metadata in case parsing of stream came first (huh?)
		my $meta = {
			%$oldMeta,
			id => $entry->{EPISODE_ID},
			title => $entry->{EPISODE_TITLE},
			podcast => $podcast,
			duration => $entry->{DURATION},
			icon => $icon,
			cover => $icon,
			# we don't have link
			# link => $entry->{EPISODE_DIRECT_STREAM},
			comment => $entry->{SHOW_DESCRIPTION},
			date => substr($entry->{EPISODE_PUBLISHED_TIMESTAMP}, 0, 10),
		};

		# make sure we won't come back
		$meta->{_complete} = 1 if $meta->{podcast}->{id} && $meta->{link};

		# cache track metadata aggressively
		$cache->set( 'deezer_episode_meta_' . $meta->{id}, $meta, '90days');

		$meta;
	} @$episodes ];
}


1;