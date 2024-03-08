package Plugins::Deezer::Custom;

use strict;
use feature 'state';

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape);
use Digest::MD5 qw(md5_hex);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Deezer::API qw();

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.deezer');
my $prefs = preferences('plugin.deezer');

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
				url => \&_getSection,
				passthrough => [ {
					entries => $sectionItems,
					title => $section->{title},
				} ],
			};
		}

		$cb->( { items => $items } );
	} );
}

sub _getSection {
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
		} else {
			$item = {
				%$item,
				title => $entry->{title},
				type => $entry->{type},
			};
			$item = Plugins::Deezer::Plugin::_renderItem($client, $item, { addArtistToTitle => 1 });
		}

		push @$items, $item;
	}

	$cb->( { items => $items } );
}

sub _getTarget {
	my ( $client, $cb, $args, $params ) = @_;

	my $api = Plugins::Deezer::Plugin::getAPIHandler($client);

	$params->{handler}->( $api, sub {
		my $items = Plugins::Deezer::Plugin::_renderTracks(shift);
		$cb->( { items => $items } );
	}, $params->{id} );
}

#----------------------------- ASYNC domain -------------------------------

my $home = {
		PAGE => 'home',
		VERSION => '2.5',
		SUPPORT => {
			'horizontal-grid' => ['album','artist','artistLineUp','channel','livestream','flow','playlist','radio','show','smarttracklist','track'],
			'horizontal-list' => ['track','song'],
			'long-card-horizontal-grid' => ['album','artist','artistLineUp','channel','livestream','flow','playlist','radio','show','smarttracklist','track'],
		},
		LANG => 'en',
};

sub _home {
	my ($self, $cb) = @_;

	# we need the order of that query to be always the same so that cache key 
	# works, but encode_json does not guaranty that
	state $home = encode_json( {
		PAGE => 'home',
		VERSION => '2.5',
		SUPPORT => {
			'horizontal-grid' => ['album','artist','artistLineUp','channel','livestream','flow','playlist','radio','show','smarttracklist','track'],
			'horizontal-list' => ['track','song'],
			'long-card-horizontal-grid' => ['album','artist','artistLineUp','channel','livestream','flow','playlist','radio','show','smarttracklist','track'],
		},
		LANG => 'en',
	} );

	my $params = {
		method => 'page.get',
		gateway_input => $home,
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

sub _userQuery {
	my ($self, $cb, $params, $content) = @_;

	my $ttl = delete $params->{_ttl} || 15*60;

	# serialize query parameters and content but hash them as they can be 
	# very lenghty (Perl has key order is undetermined).
	my $cacheKey = 	join(':', map {	$_ . $params->{$_} } sort grep { $_ !~ /^_/ } keys %$params );
	$cacheKey .= join(':', map { $_ . $content->{$_} } sort keys %$content) if $content && %$content;
	$cacheKey = 'deezer_custom_' . $self->userId . "_" . md5_hex($cacheKey);
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

		$self->_ajax( sub {
			my $results = $_[0]->{results} if $_[0];

			$cache->set($cacheKey, $results, $ttl) if $results;
			$cb->($results);
		}, $args, encode_json($content) );
	} );
}

#----------------------------- API domain -------------------------------

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