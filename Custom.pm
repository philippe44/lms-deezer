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

	my $api = Plugins::Deezer::Plugin::getAPIHandler($client);
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

		my $items = [];

		foreach my $module (@$modules) {
			push @$items, _renderModule($module) if $module->{target} =~ /channels|podcasts/;
		}

		$cb->( { items => $items || []} );
	}, "channels/radios" );
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
						[ map { _renderModule($_) } @$sections ];

			$cb->( { items => $items || []} );
		}, $params->{target} );
	}
}

sub _renderModule {
	my ($entry) = @_;

	my $passthrough = { target => $entry->{target} };
	$passthrough->{items} = $entry->{items} unless $entry->{hasMoreItems};

	return {
		title => $entry->{title},
		type => 'link',
		url => \&getItems,
		passthrough => [ $passthrough ]
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

	if ( $entry->{type} =~ /livestream/ ) {

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

	} elsif ( $entry->{type} =~ /show/ ) {

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

	} elsif ( $entry->{type} =~ /channel/ ) {

		my $passthrough = { target => $entry->{target} };
		$passthrough->{items} = $entry->{items} unless $entry->{hasMoreItems};

		return  {
			title => $entry->{title},
			type => 'link',
			url => \&getItems,
			image => Plugins::Deezer::API->getImageUrl( {
						md5_image => $entry->{pictures}->[0]->{md5},
						picture_type => $entry->{pictures}->[0]->{type},
			}, 'usePlaceholder', 'live'),
			passthrough => [ $passthrough ]
		}

	}

	return { };
}

#
# ========================= ASYNC package ==========================
#

# ------------------------------- Home ----------------------------

sub _home {
	my ($self, $cb) = @_;

	my $params = {
		_cacheKey => 'home_'.  $sprefs->get('language'),
		method => 'page.get',
		gateway_input => encode_json( {
			PAGE => 'home',
			VERSION => '2.5',
			LANG => lc $sprefs->get('language'),
			SUPPORT => {
				'horizontal-grid' => ['album','artist','artistLineUp','channel','livestream','flow','playlist','radio','show','smarttracklist','track'],
				'horizontal-list' => ['track','song'],
				'long-card-horizontal-grid' => ['album','artist','artistLineUp','channel','livestream','flow','playlist','radio','show','smarttracklist','track'],
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
		_cacheKey => "web_$page" . '_' . $sprefs->get('language'),
		method => 'page.get',
		gateway_input => encode_json( {
			PAGE => $page,
			VERSION => '2.5',
			LANG => lc $sprefs->get('language'),
			SUPPORT => {
				grid => ['channel','livestream','playlist','radio','show'],
				'horizontal-grid' => ['channel','livestream','flow','playlist','radio','show'],
				'long-card-horizontal-grid' => ['channel','livestream','flow','playlist','radio','show','smarttracklist','track'],
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

	$self->_getUserContext( sub {
		my ($tokens, $mode) = @_;
		return $cb->() unless $tokens;

		my $args = {
			method => 'livestream.getData',
			api_token => $tokens->{csrf},
			_contentType => 'application/json',
		};

		my $content = encode_json( {
			livestream_id => $id,
			supported_codecs => ['mp3', 'aac'],
		} );

		$self->_ajax( sub {
			my $result = shift;
			my $urls = $result->{results}->{LIVESTREAM_URLS}->{data} if $result->{results}->{LIVESTREAM_URLS};
			$cb->($urls);
		}, $args, $content );
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
		$cacheKey = md5_hex($cacheKey);
	}

	$cacheKey = 'deezer_custom_' . $self->userId . "_$cacheKey";
	main::INFOLOG && $log->is_info && $log->info("Getting 'custom' data with cachekey $cacheKey");

	if (my $cached = $cache->get($cacheKey)) {
		main::INFOLOG && $log->is_info && $log->info("Returning 'custom' data cached data for $cacheKey");
		$cb->($cached);
		return;
	}

	$self->_getUserContext( sub {
		my ($tokens, $mode) = @_;
		return $cb->() unless $tokens;

		my $args = {
			%$params,
			api_token => $tokens->{csrf},
		};

		# might be empty, so must be undef then
		my $data = encode_json($content) if $content;

		$self->_ajax( sub {
			my $results = $_[0]->{results} if $_[0];

			$cache->set($cacheKey, $results, $ttl) if $results;
			$cb->($results);
		}, $args, $data );
	} );
}

#
# ========================= API package ==========================
#

sub _cacheTrackMetadata {
	my ($tracks) = @_;
	return [] unless $tracks;

	return [ map {
		my $entry = $_;
		my $oldMeta = $cache->get('deezer_meta_' . $entry->{id}) || {};
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
		$cache->set( 'deezer_meta_' . $meta->{id}, $meta, time() + 90 * 86400);

		$meta;
	} @$tracks ];
}


1;