package Plugins::Deezer::API::Sync;

use strict;
use Data::URIEncode qw(complex_to_query);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min);

use Slim::Networking::SimpleSyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Deezer::API qw(BURL DEFAULT_LIMIT MAX_LIMIT);

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.deezer');
my $prefs = preferences('plugin.deezer');

sub getFavorites {
	my ($class, $userId, $type) = @_;

	# see if user/me or /user/userId should be used
	my $result = $class->_get("/user/$userId/$type", $userId);

	my $items = [ map {
		my $item = $_;
		$item->{added} = delete $item->{time_add} if $item->{time_add};
		$item->{cover} = Plugins::Deezer::API->getImageUrl($item);

		foreach (qw(adSupportedStreamReady allowStreaming audioModes audioQuality copyright djReady explicit
			mediaMetadata numberOfVideos popularity premiumStreamingOnly stemReady streamReady
			streamStartDate upc url version vibrantColor videoCover
		)) {
			delete $item->{$_};
		}

		$item;
	} @{$result->{data} || []} ] if $result;
	
	return $items;
}

sub album {
	my ($class, $userId, $id) = @_;

	my $album = $class->_get("/album/$id", $userId);
	return $album || {};
}

sub albumTracks {
	my ($class, $userId, $id, $title) = @_;

	my $album = $class->_get("/album/$id", $userId);
	my $tracks = $album->{tracks}->{data} if $album;
	$tracks = Plugins::Deezer::API->cacheTrackMetadata($tracks) if $tracks;

	return $tracks;
}

sub playlist {
	my ($class, $userId, $id) = @_;

	my $playlist = $class->_get("/playlist/$id/tracks", $userId);
	my $tracks = Plugins::Deezer::API->cacheTrackMetadata( [ grep {
			$_->{type} && $_->{type} eq 'track'
	} @{$playlist->{data} || []} ]) if $playlist;
	
	return $tracks;
}

sub getArtist {
	my ($class, $userId, $id) = @_;

	my $artist = $class->_get("/artist/$id", $userId);
	$artist->{cover} = Plugins::Deezer::API->getImageUrl($artist) if $artist;
	return $artist;
}

sub _get {
	my ( $class, $url, $userId, $params ) = @_;

	$userId ||= Plugins::Deezer::API->getSomeUserId();
	
	$params ||= {};
	$params->{limit} ||= DEFAULT_LIMIT;
	
	if ($userId) {
		my $accounts = $prefs->get('accounts') || {};
		my $profile  = $accounts->{$userId};
		$params->{access_token} = $profile->{token};
	}

	my $query = complex_to_query($params);

	main::INFOLOG && $log->is_info && $log->info("Getting $url?$query");

	my $response = Slim::Networking::SimpleSyncHTTP->new({
		timeout => 15,
		cache => 1,
		expiry => 86400,
	})->get(BURL . "$url?$query");

	if ($response->code == 200) {
		my $result = eval { from_json($response->content) };

		$@ && $log->error($@);
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));
		
		# see note on the Async version

		if (ref $result eq 'HASH' && $result->{data} && $result->{total}) {
			my $maxItems = min(MAX_LIMIT, $result->{total});
			my $offset = ($params->{index} || 0) + DEFAULT_LIMIT;

			if ($maxItems > $offset) {
				my $remaining = $result->{total} - $offset;
				main::INFOLOG && $log->is_info && $log->info("We need to page to get $remaining more results");

				my $moreResult = $class->_get($url, $userId, {
					%$params,
					index => $offset,
				});

				if ($moreResult && ref $moreResult && $moreResult->{data}) {
					push @{$result->{data}}, @{$moreResult->{data}};
				}
			}
		}

		return $result;
	}
	else {
		$log->error("Request failed for $url/$query");
		main::INFOLOG && $log->info(Data::Dump::dump($response));
	}

	return;
}

1;