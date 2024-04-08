package Plugins::Deezer::ProtocolHandler;

use strict;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);
use Scalar::Util qw(blessed);
use MIME::Base64 qw(encode_base64 decode_base64);
use Digest::MD5 qw(md5_hex);
use Crypt::CBC;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Utils::Errno qw(EWOULDBLOCK);
use Slim::Utils::Scanner::Remote;
use Slim::Utils::Strings qw(cstring);

use Plugins::Deezer::Plugin;
use Plugins::Deezer::API;

use base qw(Slim::Player::Protocols::HTTPS);

my $prefs = preferences('plugin.deezer');
my $serverPrefs = preferences('server');
my $log = logger('plugin.deezer');
my $cache = Slim::Utils::Cache->new;

my $cryptoHelper;

# https://deezer.com/track/95570766
# https://deezer.com/album/95570764
# https://deezer.com/playlist/5a36919b-251c-4fa7-802c-b659aef04216
my $URL_REGEX = qr{^https://(?:\w+\.)?deezer.com/(track|playlist|album|artist|podcast)/([a-z\d-]+)}i;
my $URI_REGEX = qr{^deezer://(playlist|album|artist|podcast|):?([0-9a-z-]+)}i;
Slim::Player::ProtocolHandlers->registerURLHandler($URL_REGEX, __PACKAGE__);
Slim::Player::ProtocolHandlers->registerURLHandler($URI_REGEX, __PACKAGE__);

sub init {
	eval { require Crypt::Blowfish; };
	if ($@) {
		$log->warn('Can\'t use Crypt::Blowfish, will use Crypt:Blowfish_PP');
		$log->warn('Try to add Crypt::Blowfish to Perl, on Debian do:');
		$log->warn("'sudo apt-get install libcrypt-blowfish-perl'");
		require Crypt::Blowfish_PP;
		$cryptoHelper = 'Crypt::Blowfish_PP';
	} else {
		$log->info('Using fast Crypt::Blowfish');
		$cryptoHelper = 'Crypt::Blowfish';
	}
}

# many method do not need override like isRemote, shouldLoop ...
sub canSkip { 1 }	# where is this called?
sub canDirectStream { 0 }

sub canSeek {
	my ($class, $client, $song) = @_;
	my $url = $song->track()->url;
	# can't (don't want to) seek radio/flow
	return !(_getRadio($url) || getFlow($url));
}

sub getFormatForURL {
	my ($class, $url) = @_;
	return if $url =~ m{^deezer://.+:.+};
	return Plugins::Deezer::API::getFormat;
}

sub formatOverride {
	my ($class, $song) = @_;
	my $format = $song->pluginData('format') || Plugins::Deezer::API::getFormat;
	return $format;
}

sub canEnhanceHTTP {
	my $mode = shift->SUPER::canEnhanceHTTP();
	return $mode != Slim::Player::Protocols::HTTP::PERSISTENT ? $mode : 0;
}

sub isRepeatingStream {
	my ( $class, $song ) = @_;
	my $url = $song->track()->url;
	return _getRadio($url) || getFlow($url);
}

sub trackGain {
	my ($class, $client, $url) = @_;

	return unless $client && blessed $client && $serverPrefs->client($client)->get('replayGainMode');

	my $trackId = _getId($url);
	my $meta = $cache->get( 'deezer_meta_' . ($trackId || '') );
	return unless $meta;

	main::INFOLOG && $log->is_info && $log->info("Replay gain: $meta->{replay_gain}");
	return $meta->{replay_gain};
}

=comment
# some streams are compressed in a way which causes stutter on ip3k based players
sub forceTranscode {
	my ($self, $client, $format) = @_;
	return $format eq 'flc' && $client->model =~ /squeezebox|boom|transporter|receiver/;
}
=cut

# for the forgetful, when subclassing Player::Protocol::HTPP, all the open/request/header
# gathering is made on our behalf BUT overload sysread is delicate as it will be called
# during headers reading, and before returning the call to $class->SUPER below. Only when
# starting to read the body will it be called with full context, after the new() has
# returned. Also, the sysread to overload must be _sysread if one wants to benefit from
# networking caching and persistent connection. Otherwise, we can sub class IO::Handle but
# we have to handle the HTTP query by ourselves and won't benefit from the networking
# goodies. Also, methods like isAudio, isRemote, contentType (and maybe others) that are
# provided by HTTP or its ancestors must be provided then.
sub new {
	my ($class, $args) = @_;

	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;
	my $seekdata = $song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};

	main::DEBUGLOG && $log->debug( 'Remote streaming Deezer track: ' . $streamUrl );

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $args->{song},
		client  => $args->{client},
	} ) || return;

	my $key = $Plugins::Deezer::API::Auth::cbc;
	my $id = $song->pluginData('trackId');
	my $md5 = md5_hex($id);
	$key ^= substr($md5, 0, 16) ^ substr($md5, 16, 16);

	my $blowfish = $cryptoHelper->new($key);

	${*$sock}{deezer_cipher} = Crypt::CBC->new(
		-header	     => 'none',
		-padding	 => 'none',
        -iv          => "\x00\x01\x02\x03\x04\x05\x06\x07",
		-cipher 	 => $blowfish,
	);

	${*$sock}{deezer_count} = 0;
	${*$sock}{deezer_backlog} = '';
	${*$sock}{deezer_bytes} = '';

	if ($seekdata) {
		${*$sock}{deezer_count} = int($seekdata->{sourceStreamOffset} / 2048) + 1;
		${*$sock}{deezer_align} = 2048 - $seekdata->{sourceStreamOffset} % 2048;
	}

	return $sock;
}

# Avoid scanning
sub scanUrl {
	my ( $class, $url, $args ) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

# Source for AudioScrobbler
sub audioScrobblerSource {
	my ( $class, $client, $url ) = @_;

	# P = Chosen by the user
	return 'P';
}

sub explodePlaylist {
	my ( $class, $client, $url, $cb ) = @_;

	my ($type, $id) = $url =~ $URL_REGEX;

	if ( !($type && $id) ) {
		($type, $id) = $url =~ $URI_REGEX;
	}

	if ($id) {
		my $method;
		
		return $cb->( [ $url ] ) unless $type;

		if ($type eq 'playlist') {
			$method = \&Plugins::Deezer::Plugin::getPlaylist;
		}
		elsif ($type eq 'album') {
			$method = \&Plugins::Deezer::Plugin::getAlbum;
		}
		elsif ($type eq 'artist') {
			$method = \&Plugins::Deezer::Plugin::getArtistTopTracks;
		}
		elsif ($type eq 'podcast') {
			$method = \&Plugins::Deezer::Plugin::getPodcastEpisodes;
		}

		$method->($client, $cb, { }, { id => $id });
		main::INFOLOG && $log->is_info && $log->info("Getting $url, type:$type, id:$id");
	}
	else {
		$cb->([]);
	}
}

sub _sysread {
	use bytes;
	my ($self, undef, $size, $offset) = @_;
	my $cipher = ${*$self}{deezer_cipher};

	# still reading headers, nothing to decipher yet
	if ( !$cipher ) {
		my $bytes = $self->SUPER::_sysread($_[1], $size, $offset);
		return $bytes;
	}

	# first align if seeking
	if ( ${*$self}{deezer_align} ) {
		my $bytes = $self->SUPER::_sysread(my $buffer, ${*$self}{deezer_align});

		main::INFOLOG && $log->info("Aligning ($bytes) of ${*$self}{deezer_align} with count ${*$self}{deezer_count}") if defined $bytes;
		${*$self}{deezer_align} -= $bytes;

		if ( ${*$self}{deezer_align} ) {
			$! ||= EWOULDBLOCK;
			return undef;
		}
	}

	if ( !${*$self}{deezer_bytes} ) {
		# get some bytes (at least 2048) and add them to backlog
		my $backlog = \${*$self}{deezer_backlog};
		my $bytes = $self->SUPER::_sysread($$backlog, $size + 2048, length $$backlog);

		# really nothing to work on, come back later
		if (!defined $bytes) {
			$! ||= EWOULDBLOCK;
			return undef;
		}

		# end of reception and nothing in backlog - done
		return 0 if !$bytes && !$$backlog;

		# decrypt all we can and store it in decoded buffer
		while ( length($$backlog) >= 2048 || (!$bytes && $$backlog) ) {
			# only one chunk every three needs to be decryted but when decrypting
			# last chunk we must do padding % 8 otherwise CBC fails.
			if ( ${*$self}{deezer_count}++ % 3 == 0 ) {
				my $padding = (8 - length($$backlog) % 8) % 8 unless $bytes;
				${*$self}{deezer_bytes} .= $cipher->decrypt(substr($$backlog, 0, 2048, '') . 0 x $padding);
				substr(${*$self}{deezer_bytes}, -$padding) = '' if $padding;
			} else {
				${*$self}{deezer_bytes} .= substr($$backlog, 0, 2048, '');
			}
		}
	}

	# try to read from the decoded buffer (might be nothing, still)
	my $buffer = substr(${*$self}{deezer_bytes}, 0, $size, '');

	# return length of what has been added, not the whole $_[1]
	if ($buffer) {
		substr($_[1], $offset || 0) = $buffer;
		return length $buffer;
	}

	# not been replenished enough, come back later
	$! ||= EWOULDBLOCK;
	return undef;
}

sub getNextTrack {
	my ( $class, $song, $successCb, $errorCb ) = @_;

	my $client = $song->master();
	my $url = $song->track->url;
	my $path = _getRadio($url);

	if (my $radio = _getRadio($url)) {
		# use tracks we have in the list (if any)
		my $radioTracks = $song->pluginData('radioTracks') || [];
		my $trackId = shift @$radioTracks;
		main::INFOLOG && $log->info("we have ", scalar @$radioTracks, " radio tracks left for $path") if $trackId;

		# process if we have at least one track
		return _getNextTrack( $song, $trackId, sub {
			my ($format, $bitrate) = @_;

			# make this available for when track is current
			$song->pluginData(bitrate => $bitrate || 850_000);
			$successCb->();

		}, $errorCb, 'radioTracks' ) if $trackId;

		# need to fetch more...
		main::INFOLOG && $log->info("need to fetch more radio tracks for $path");
		Plugins::Deezer::Plugin::getAPIHandler($client)->radioTracks( sub {
			my $items = shift;

			my $ids = [ map { $_->{id} } @$items ];
			$song->pluginData('radioTracks', $ids);
			main::INFOLOG && $log->info("acquired ", scalar @$ids, " radio tracks for $path");

			return $errorCb->() unless $ids;
			$class->getNextTrack($song, $successCb, $errorCb);
		}, $path, 10 );
	} elsif (my ($mode, $type) = getFlow($url)) {
		# use tracks we have in the list (if any)
		my $flowTracks = $song->pluginData('flowTracks') || [];
		my $track = shift @$flowTracks;

		main::INFOLOG && $log->info("we have ", scalar @$flowTracks, " flow tracks left for $type\@$mode") if $track;

		# process if we have at least one track
		return _setTrackParams($song, $track, sub {
			my ($format, $bitrate) = @_;

			# make this available for when track is current
			$song->pluginData(bitrate => $bitrate || 850_000);
			$successCb->();

		}, $errorCb, 'flowTracks' ) if $track;

		main::INFOLOG && $log->info("need to fetch more flow tracks for $mode\@$type");
		my $api = Plugins::Deezer::Plugin::getAPIHandler($client);
		
		$api->flowTracks( sub {
			my $tracks = shift;
			return $errorCb->("no flow track") unless $tracks && @$tracks;

			main::INFOLOG && $log->info("acquired ", scalar @$tracks, " flow tracks for $type\@$mode");			
			$song->pluginData('flowTracks', $tracks);
			$class->getNextTrack($song, $successCb, $errorCb);
		}, {
			mode => $mode,
			type => $type,
			flow => $prefs->get($api->userId . ':flow'),
			quality => Plugins::Deezer::API::getQuality(),
		} );
	} elsif (my $trackId = _getId($url)) {
		_getNextTrack( $song, $trackId, sub {
			my ($format, $bitrate) = @_;

			# metadata update request will be done below
			my $meta = $cache->get( 'deezer_meta_' . $trackId );
			Slim::Music::Info::setDuration( $song->track, $meta->{duration} );

			# pretty things up
			$song->track->content_type($format);

			# no need to parse header in mp3 but in flac we need bitrate for seeking
			if ($format =~ /mp3/) {
				main::INFOLOG && $log->info("got $format\@$bitrate track at ", $song->streamUrl);
				Slim::Music::Info::setBitrate( $song->track, $bitrate );
				$client->currentPlaylistUpdateTime( Time::HiRes::time() );
				Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
				$successCb->();
			} else {
				_parseFlac(
					sub {
						# parser has set all we need, just need to trigger update
						main::INFOLOG && $log->info("got $format\@", $song->track->bitrate, " track at ", $song->streamUrl);
						$client->currentPlaylistUpdateTime( Time::HiRes::time() );
						Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
						$successCb->();
					}, $song
				);
			}
		}, $errorCb );
	} else {
		$log->error("can't get next track, unknown url $url");
		return $errorCb->();
	}
}

sub _getNextTrack {
	my ( $song, $trackId, $successCb, $errorCb, $linger ) = @_;
	my $client = $song->master();

	Plugins::Deezer::Plugin::getAPIHandler($client)->getTrackUrl( sub {
		my $result = shift;
		return $errorCb->($@) unless $result && @$result;

		_setTrackParams($song, $result->[0], $successCb, $errorCb, $linger);

	}, [ $trackId ], { quality => Plugins::Deezer::API::getQuality() } );

	main::DEBUGLOG && $log->is_debug && $log->debug("Getting next track playback info for ", $song->track->url);
}

sub _setTrackParams {
	my ( $song, $track, $successCb, $errorCb, $linger ) = @_;
	return $errorCb('no track available') unless $track;

	my $client = $song->master();
	my ($format, $bitrate) = $track->{format} =~ /([^_]+)_?(\d+)?/i;
	my $streamUrl = $track->{urls}[rand(scalar @{$track->{urls}})];
	$format = lc($format);
	$format =~ s/flac/flc/i;

	$song->streamUrl($streamUrl);

	# some pluginData needs to be carried over
	my $lingerItem = $song->pluginData($linger) if $linger;

	# need to reset it as it's just a hash pointing to previous song's pluginData
	$song->pluginData({ });

	$song->pluginData($linger, $lingerItem) if $lingerItem;
	$song->pluginData(format => $format);
	$song->pluginData(trackId => $track->{id});

	$successCb->($format, $bitrate * 1000);
	Plugins::Deezer::Plugin::getAPIHandler($client)->listened($track->{id});

	main::DEBUGLOG && $log->is_debug && $log->debug("Getting next track playback info for ", $song->track->url);
}

sub _parseFlac {
	my ($cb, $song) = @_;

	my $key = $Plugins::Deezer::API::Auth::cbc;
	my $md5 = md5_hex($song->pluginData('trackId'));
	$key ^= substr($md5, 0, 16) ^ substr($md5, 16, 16);

	my $blowfish = $cryptoHelper->new($key);

	my $cipher = Crypt::CBC->new(
					  -header	   => 'none',
					  -padding	   => 'none',
                      -iv          => "\x00\x01\x02\x03\x04\x05\x06\x07",
					  -cipher 	   => $blowfish,
	);

	my $count = 0;
	my $buffer = '';

	my $context = { cb => $cb };
	my $http = Slim::Networking::Async::HTTP->new;

	$http->send_request( {
		request     => HTTP::Request->new( GET => $song->streamUrl ),
		onStream    => sub {
			my ($http, $dataref) = @_;

			my $more = 1;
			$buffer .= $$dataref;

			while (length $buffer >= 2048 && $more) {
				my $chunk = substr($buffer, 0, 2048, '');
				$chunk = $cipher->decrypt($chunk) unless $count++ % 3;
				$more = Slim::Utils::Scanner::Remote::parseFlacHeader($http, \$chunk, $song->track, $context);
			}

			# in case we faild to get bitrate swag it
			if (!$more && !$song->bitrate) {
				my $bitrate = int($http->response->content_length / $song->duration * 8) if $song->duration;
				$bitrate ||= 850_000;
				Slim::Music::Info::setBitrate( $song->track, $bitrate );
				$log->warn("Failed to get flac bitrate for track id", $song->pluginData('trackId'), ", guessing it at $bitrate");
			}

			return $more;
		},
		onError 	=> $cb,
	} );
}

=comment
# I fail to see the real benefit of that function as I think we still need
# to create an action menu with trackinfo command. Maybe it's useful for
# remote CLI queries 
sub trackInfoURL {
	my ( $class, $client, $url ) = @_;

	return [ {
		title => "this is a title",
		type => 'text',
	} ];
}
=cut

my @pendingMeta = ();

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;
	return {} unless $url;

	my $meta;
	my $trackId;
	my $song = $client->playingSong();
	my $icon = $class->getIcon();
	my $defaultMeta = {
		bitrate   => 'N/A',
		type      => Plugins::Deezer::API::getFormat(),
		icon      => $icon,
		cover     => $icon,
	};

	# when trying to get metadata for a radio/flow, we must be playing it
	if ( _getRadio($url) || getFlow($url) ) {
		$defaultMeta->{title} = cstring($client, 'PLUGIN_DEEZER_DSTM_SMART_RADIO');
		return $defaultMeta unless $song && $song->track->url eq $url;

		$trackId = $song->pluginData('trackId');
		return $defaultMeta unless $trackId;

		$meta = $cache->get( 'deezer_meta_' . $trackId );
		my $bitrate = $song->pluginData('bitrate');

		# bitrate still in pluginData shall trigger update of current track
		if ($bitrate && $meta) {
			Slim::Music::Info::setDuration( $song->track, $meta->{duration} );
			Slim::Music::Info::setBitrate( $song->track, $bitrate);
			$song->track->content_type($song->pluginData('format'));
			$song->pluginData(bitrate => 0);

			$client->currentPlaylistUpdateTime( Time::HiRes::time() );
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		}
	} else {
		$trackId = _getId($url);
		return $defaultMeta unless $trackId;
		$meta = $cache->get( 'deezer_meta_' . ($trackId || '') );
	}

	# if metadata is in cache and is full
	if ($meta) {
		$meta->{artist} = $meta->{artist}->{name} if ref $meta->{artist};
		$meta->{album} = $meta->{album}->{title} if ref $meta->{album};
		return $meta if $meta->{_complete} || ($song && $song->track->url ne $url);
	}

	my $now = time();

	# first cleanup old requests in case some got lost
	@pendingMeta = grep { $_->{time} + 60 > $now } @pendingMeta;

	# only proceed if our request is not pending and we have less than 10 in parallel
	if ( !(grep { $_->{id} == $trackId } @pendingMeta) && scalar(@pendingMeta) < 10 ) {

		push @pendingMeta, {
			id => $trackId,
			time => $now,
		};

		main::DEBUGLOG && $log->is_debug && $log->debug("adding metadata query for $trackId");

		Plugins::Deezer::Plugin::getAPIHandler($client)->track(sub {
			my $meta = shift;
			@pendingMeta = grep { $_->{id} != $trackId } @pendingMeta;
			return unless $meta;

			main::INFOLOG && $log->is_info && $log->info("updating metadata for $trackId");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($meta));
			return if @pendingMeta;

			# Update the playlist time so the web will refresh, etc
			$client->currentPlaylistUpdateTime( Time::HiRes::time() );
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		}, $trackId );
	}

	return $meta || $defaultMeta;
}

sub getIcon {
	my ( $class, $url ) = @_;
	return Plugins::Deezer::Plugin->_pluginDataFor('icon');
}

sub _getId {
	my ($id) = $_[0] =~ m|deezer://(-?\d+)|;
	return $id;
}

sub _getRadio{
	my ($path) = $_[0] =~ m|deezer://(.+)\.dzr$|;
	return $path;
}

sub getFlow{
	my ($flow, $type) = $_[0] =~ /deezer:\/\/(genre|mood|user)(?:\:(.+))?\.flow$/;
	return $flow ? ($flow, $type || 'n/a') : ();
}

sub getPlayingId {
	my ($client, $url) = @_;

	if ( getFlow($url) || _getRadio($url) ) {
		return $client->playingSong->pluginData('trackId');
	}

	return _getId($url)
}	

1;
