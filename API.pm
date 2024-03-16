package Plugins::Deezer::API;

use strict;
use Exporter::Lite;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

our @EXPORT_OK = qw(AURL BURL GURL UURL DEFAULT_LIMIT MAX_LIMIT DEFAULT_TTL USER_CONTENT_TTL);

use constant AURL => 'https://connect.deezer.com/oauth';
use constant BURL => 'https://api.deezer.com';
use constant GURL => 'https://www.deezer.com/ajax/gw-light.php';
use constant UURL => 'https://media.deezer.com/v1/get_url';
use constant IURL => 'https://e-cdns-images.dzcdn.net/images';

use constant DEFAULT_LIMIT => 100;
use constant MAX_LIMIT => 2000;

use constant DEFAULT_TTL => 86400;
use constant USER_CONTENT_TTL => 300;

use constant IMAGE_SIZES => {
	# there is 56, 250, 500, and 1000 in pre-calculated
	album  => '500x500',
	track  => '500x500',
	artist => '500x500',
	user   => '500x500',
	mood   => '500x500',
	genre  => '500x500',
	radio  => '500x500',
	playlist => '500x500',
	podcast => '500x500',
	episode => '500x500',
};

use constant SOUND_QUALITY => {
	LOW => 'mp3',
	HIGH => 'mp3',
	LOSSLESS => 'flc'
};

my $cache = Slim::Utils::Cache->new;
my $log = logger('plugin.deezer');
my $prefs = preferences('plugin.deezer');

sub getSomeUserId {
	my $accounts = $prefs->get('accounts');

	my ($account) = keys %$accounts;
	return $account;
}

sub getCountryCode {
	my ($class, $userId) = @_;
	my $accounts = $prefs->get('accounts') || {};

	return 'US' unless $accounts && $userId && $accounts->{$userId};
	return $accounts->{$userId}->{countryCode} || 'US';
}

sub getFormat {
	return SOUND_QUALITY->{$prefs->get('quality')};
}

sub getQuality {
	return $prefs->get('quality');
}

sub getImageUrl {
	my ($class, $data, $usePlaceholder, $type) = @_;

	if ( my $coverId = $data->{md5_image} || $data->{picture_big} || $data->{picture_medium} || $data->{picture} || ($data->{album} && $data->{album}->{cover}) ) {

		return $data->{cover} = $coverId if $coverId =~ /^https?:/;

		# this probably can be replaced by $data->{type}
		$type ||= $class->typeOfItem($data);
		my $iconSize = IMAGE_SIZES->{$type};
		my $path = $data->{picture_type} || 'cover';

		if ($iconSize) {
			$data->{cover} = IURL . "/$path/$coverId/$iconSize-000000-80-0-0.jpg";
		}
		else {
			delete $data->{cover};
		}
	}

	return $data->{cover} || (!main::SCANNER && $usePlaceholder && Plugins::Deezer::Plugin->_pluginDataFor('icon'));
}

sub typeOfItem {
	my ($class, $item) = @_;

	if ( $item->{type} && $item->{type} =~ /(?:playlist|artist|album|track|radio|genre|podcast|episode)/i ) {
		return $item->{type};
	}
	elsif ( $item->{duration} ) {
		return 'track';
	}
	elsif ( grep /tracks|artists|albums|playlists/, keys %$item ) {
		return 'compound';
	}

	return '';
}

sub cacheTrackMetadata {
	my ($class, $tracks, $params) = @_;
	
	return [] unless $tracks;
	
	return [ map {
		my $entry = $_;
		my $oldMeta = $cache->get( 'deezer_meta_' . $entry->{id}) || {};
		my $icon = $class->getImageUrl($entry, 'usePlaceholder', 'track');

		# consolidate metadata in case parsing of stream came first (huh?)
		my $meta = {
			%$oldMeta,
			id => $entry->{id},
			title => $entry->{title},
			artist => $entry->{artist},
			album => $entry->{album},
			duration => $entry->{duration},
			icon => $icon,
			cover => $icon,
			# these are only available for some requests (usually individual tracks or /tracks endpoints)
			replay_gain => $entry->{gain} || 0,
			disc => $entry->{disk_number},
			tracknum => $entry->{track_position},
			link => $entry->{link},
		};
		
		# make sure we won't come back
		$meta->{_complete} = 1 if $meta->{tracknum} || ($params && $params->{cache});

		# cache track metadata aggressively
		$cache->set( 'deezer_meta_' . $entry->{id}, $meta, time() + 90 * 86400);

		$meta;
	} @$tracks ];
}


sub cacheEpisodeMetadata {
	my ($class, $episodes, $params) = @_;
	
	return [] unless $episodes;
	$params ||= {};
	
	return [ map {
		my $entry = $_;
		my $oldMeta = $cache->get( 'deezer_episode_meta_' . $entry->{id}) || {};
		my $icon = $class->getImageUrl($entry, 'usePlaceholder', 'episode');

		# consolidate metadata in case parsing of stream came first (huh?)
		my $meta = {
			%$oldMeta,
			id => $entry->{id},
			title => $entry->{title},
			album => $entry->{podcast} ? $entry->{podcast}->{title} : $params->{podcast},
			duration => $entry->{duration},
			icon => $icon,
			cover => $icon,
			link => $entry->{link},
			comment => $entry->{description},
			date => substr($entry->{release_date}, 0, 10),
		};
		
		# make sure we won't come back
		$meta->{_complete} = 1 if $meta->{album} || $params->{cache};

		# cache track metadata aggressively
		$cache->set( 'deezer_episode_meta_' . $entry->{id}, $meta, time() + 90 * 86400);

		$meta;
	} @$episodes ];
}


1;