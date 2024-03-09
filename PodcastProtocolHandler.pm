package Plugins::Deezer::PodcastProtocolHandler;

use strict;

use Scalar::Util qw(blessed);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Scanner::Remote;

use Plugins::Deezer::Plugin;
use Plugins::Deezer::API;

use base qw(Slim::Player::Protocols::HTTPS);

my $prefs = preferences('plugin.deezer');
my $serverPrefs = preferences('server');
my $log = logger('plugin.deezer');
my $cache = Slim::Utils::Cache->new;

# https://www.deezer.com/episode/611754312
# is there a link for podcast?
my $URL_REGEX = qr{^https://(?:\w+\.)?deezer.com/(episode)/([a-z\d-]+)}i;
my $URI_REGEX = qr{^deezerpodcast://(\d+)\/(\d+)(?:_(\d+))}i;
Slim::Player::ProtocolHandlers->registerURLHandler($URL_REGEX, __PACKAGE__);
Slim::Player::ProtocolHandlers->registerURLHandler($URI_REGEX, __PACKAGE__);

sub formatOverride {
	my ($class, $song) = @_;
	my ($format) = $song->streamUrl =~ /\.(mp3|flc|flac|mp4|wav)/;
	return $format =~ s/flac/flc/r;
}

sub new {
	my ($class, $args) = @_;
	$args->{url} = $args->{song}->streamUrl unless $args->{redir};
	return $class->SUPER::new( $args );
}	

# Avoid scanning
sub scanUrl {
	my ( $class, $url, $args ) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

=comment
# Source for AudioScrobbler
sub audioScrobblerSource {
	my ( $class, $client, $url ) = @_;

	# P = Chosen by the user
	return 'P';
}
=cut

sub explodePlaylist {
	my ( $class, $client, $url, $cb ) = @_;

	my ($type, $id) = $url =~ $URL_REGEX;

	if ( !($type && $id) ) {
		($type, $id) = $url =~ $URI_REGEX;
	}

	if ($id) {
		main::INFOLOG && $log->is_info && $log->info("Getting $url, type:$type, id:$id");
		return $cb->( [ $url ] );
	} else {
		$cb->([]);
	}
}

sub getNextTrack {
	my ( $class, $song, $successCb, $errorCb ) = @_;

	my $client = $song->master();
	my $url = $song->track->url;
	my ($podcast, $episode, $index) = _getId($url);
	
	Plugins::Deezer::Plugin::getAPIHandler($client)->getEpisodesUrl( sub {
		my $results = shift;
		return $errorCb->($@) unless $results && @$results;
		
		# was ask for more than one track in case more have been added since
		my ($entry) = grep { $_->{EPISODE_ID} == $episode } @$results;
		return $errorCb->("can't find track") unless $entry;
		
		my $streamUrl = $entry->{EPISODE_DIRECT_STREAM_URL};
		$song->streamUrl($streamUrl);		
		my $format = $class->formatOverride($song);
		
		# force the CT in the track as it might not been set which then
		# might prevent parseRemoteHeader from working
		$song->track->content_type($format);
		
		main::INFOLOG && $log->is_info && $log->info("Streaming $format $url using $streamUrl");

		# try to parse url 
		Slim::Utils::Scanner::Remote::parseRemoteHeader(
			$song->track, $streamUrl, $format, 
			sub {
				$client->currentPlaylistUpdateTime( Time::HiRes::time() );
				Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );				
				$successCb->();
			},
			sub {
				my ($self, $error) = @_;
				$log->warn( "could not find $format header $error" );
				$successCb->();
			}
		);
	}, $podcast, $index, 4 );
}

=comment
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

	my $song = $client->playingSong();
	my $icon = Plugins::Deezer::Plugin->_pluginDataFor('icon');
	my $defaultMeta = {
		bitrate   => 'N/A',
		type      => Plugins::Deezer::API::getFormat(),
		icon      => $icon,
		cover     => $icon,
	};

	my ($podcast, $episode) = _getId($url);
	return $defaultMeta unless $podcast && $episode;

	# episode identifier is unique across podcasts
	my $id = $episode;
	my $meta = $cache->get('deezer_episode_meta_' . $id);

	# if metadata is in cache and is full
	return $meta if $meta && $meta->{_complete};

	my $now = time();

	# first cleanup old requests in case some got lost
	@pendingMeta = grep { $_->{time} + 60 > $now } @pendingMeta;

	# only proceed if our request is not pending and we have less than 10 in parallel
	if ( !(grep { $_->{id} eq $id } @pendingMeta) && scalar(@pendingMeta) < 10 ) {

		push @pendingMeta, {
			id => $id,
			time => $now,
		};

		main::DEBUGLOG && $log->is_debug && $log->debug("adding metadata query for $podcast:$episode");

		Plugins::Deezer::Plugin::getAPIHandler($client)->episode(sub {
			my $meta = shift;
			@pendingMeta = grep { $_->{id} != $id } @pendingMeta;
			return unless $meta;

			main::INFOLOG && $log->is_info && $log->info("updating metadata for $id");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($meta));
			return if @pendingMeta;

			# Update the playlist time so the web will refresh, etc
			$client->currentPlaylistUpdateTime( Time::HiRes::time() );
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		}, $id );
	}

	return $meta || $defaultMeta;
}

sub _getId {
	return $_[0] =~ m|deezerpodcast://(\d+)/(\d+)(?:_(\d+))?|;
}


1;
