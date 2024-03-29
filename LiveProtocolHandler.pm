package Plugins::Deezer::LiveProtocolHandler;

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Scanner::Remote;

use Plugins::Deezer::Plugin;
use Plugins::Deezer::API;

use base qw(Slim::Player::Protocols::HTTPS);

my $prefs = preferences('plugin.deezer');
my $log = logger('plugin.deezer');

# https://www.deezer.com/livestream/611754312
my $URL_REGEX = qr{^https://(?:\w+\.)?deezer.com/(live|channel)/(.]+)}i;
my $URI_REGEX = qr{^deezerlive://(channel|):?(.+)}i;
Slim::Player::ProtocolHandlers->registerURLHandler($URL_REGEX, __PACKAGE__);
Slim::Player::ProtocolHandlers->registerURLHandler($URI_REGEX, __PACKAGE__);
Slim::Player::ProtocolHandlers->registerHandler('deezerlive', 'Plugins::Deezer::LiveProtocolHandler');

sub explodePlaylist {
	my ( $class, $client, $url, $cb ) = @_;

	my ($type, $id) = $url =~ $URL_REGEX;

	if ( !($type && $id) ) {
		($type, $id) = $url =~ $URI_REGEX;
	}

	main::INFOLOG && $log->is_info && $log->info("Getting $url, type:$type, id:$id");

	if (!$type) {
		$cb->( [ $url ] );	
	} elsif ($type eq 'channel') {
		Plugins::Deezer::Custom::getItems($client, $cb, { }, { target => $id } );
	} else {
		$cb->([]);
	}
}

sub scanUrl {
	my ( $class, $url, $args ) = @_;

	my $api = Plugins::Deezer::Plugin::getAPIHandler($args->{song}->master);
	my $id = _getId($url);

	Plugins::Deezer::Custom::liveStream( $api, sub {
		my $urls = shift;
		return $args->{cb}->() unless $urls;
		
		# get offered rates and select one
		my @rates = sort keys %$urls;
		my ($rate) = grep { $_ >= $prefs->get('liverate') } @rates;
		$rate ||= $rates[-1];
		
		# select format for that rate
		my @formats = keys %{$urls->{$rate}};
		my ($format) = grep { $_ =~ /$prefs->get('liveformat')/i } @formats;
		$format ||= $formats[0];

		my $streamUrl = $urls->{$rate}->{$format};	
		my $cache = Slim::Utils::Cache->new;
		my $image = $cache->get("deezer_live_image_$id");		
		$cache->set("remote_image_$streamUrl", $image, '1 weeks');		
		main::INFOLOG && $log->is_info && $log->info("Streaming $url using $streamUrl and image $image");		
		
		$class->SUPER::scanUrl($streamUrl, $args);

	}, $id );
}

sub _getId {
	my ($id) = $_[0] =~ m|deezerlive://(\d+)|;
	return $id;
}


1;
