package Plugins::Deezer::LastMix;

use strict;

use base qw(Plugins::LastMix::Services::Base);

use Slim::Utils::Log;

my $log = logger('plugin.deezer');

sub isEnabled {
	my ($class, $client) = @_;

	return unless $client;

	return unless Slim::Utils::PluginManager->isEnabled('Plugins::Deezer::Plugin');

	require Plugins::Deezer::API;
	return Plugins::Deezer::API::->getSomeUserId() ? 'Deezer' : undef;
}

sub lookup {
	my ($class, $client, $cb, $args) = @_;

	$class->client($client) if $client;
	$class->cb($cb) if $cb;
	$class->args($args) if $args;

	Plugins::Deezer::Plugin::getAPIHandler($client)->search(sub {
		my $tracks = shift;

		if (!$tracks) {
			$class->cb->();
		}

		my $candidates = [];
		my $searchArtist = $class->args->{artist};
		my $ct = Plugins::Deezer::API::getFormat();

		for my $track ( @$tracks ) {
			next unless $track->{artist} && $track->{id} && $track->{title} && $track->{artist}->{name};

			push @$candidates, {
				title  => $track->{title},
				artist => $track->{artist}->{name},
				url    => "deezer://$track->{id}.$ct",
			};
		}

		my $track = $class->extractTrack($candidates);

		main::INFOLOG && $log->is_info && $track && $log->info("Found $track for: $args->{title} - $args->{artist}");

		$class->cb->($track);
	}, {
		type => 'track',
		search => $args->{title},
		limit => 20,
	});
}

sub protocol { 'deezer' }

1;