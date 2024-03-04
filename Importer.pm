package Plugins::Deezer::Importer;

use strict;

use base qw(Slim::Plugin::OnlineLibraryBase);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;
use Slim::Utils::Strings qw(string);

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.deezer');
my $prefs = preferences('plugin.deezer');

my ($ct, $splitChar);

sub startScan { if (main::SCANNER) {
	my ($class) = @_;

	require Plugins::Deezer::API::Sync;
	$ct = Plugins::Deezer::API::getFormat();
	$splitChar = substr(preferences('server')->get('splitList'), 0, 1);

	my $accounts = _enabledAccounts();

	if (scalar keys %$accounts) {
		my $playlistsOnly = Slim::Music::Import->scanPlaylistsOnly();

		$class->initOnlineTracksTable();

		if (!$playlistsOnly) {
			$class->scanAlbums($accounts);
			$class->scanArtists($accounts);
		}

		if (!$class->can('ignorePlaylists') || !$class->ignorePlaylists) {
			$class->scanPlaylists($accounts);
		}

		$class->deleteRemovedTracks();
		$cache->set('deezer_library_last_scan', time(), '1y');
	}

	Slim::Music::Import->endImporter($class);
} }

sub scanAlbums { if (main::SCANNER) {
	my ($class, $accounts) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_deezer_albums',
		'total' => 1,
		'every' => 1,
	});

	while (my ($accountName, $userId) = each %$accounts) {
		my %missingAlbums;

		main::INFOLOG && $log->is_info && $log->info("Reading albums... " . $accountName);
		$progress->update(string('PLUGIN_DEEZER_PROGRESS_READ_ALBUMS', $accountName));

		my $albums = Plugins::Deezer::API::Sync->getFavorites($userId, 'albums') || [];
		$progress->total(scalar @$albums);

		foreach my $album (@$albums) {
			my $albumDetails = $cache->get('deezer_album_with_tracks_' . $album->{id});

			if ($albumDetails && $albumDetails->{tracks} && ref $albumDetails->{tracks}) {
				$progress->update($album->{title});

				$class->storeTracks([
					map { _prepareTrack($albumDetails, $_) } @{ $albumDetails->{tracks} }
				], undef, $accountName);

				main::SCANNER && Slim::Schema->forceCommit;
			}
			else {
				$missingAlbums{$album->{id}} = $album;
			}
		}

		while ( my ($albumId, $album) = each %missingAlbums ) {
			$progress->update($album->{title});

			# we already have tracks through favorites but they are incomplete and don't include contributors
			$album->{contributors} = Plugins::Deezer::API::Sync->album($userId, $albumId)->{contributors};
			$album->{tracks} = Plugins::Deezer::API::Sync->albumTracks($userId, $albumId, $album->{title});

			if (!$album->{tracks}) {
				$log->warn("Didn't receive tracks for $album->{title}/$album->{id}");
				next;
			}

			$cache->set('deezer_album_with_tracks_' . $albumId, $album, '3M');

			$class->storeTracks([
				map { _prepareTrack($album, $_) } @{ $album->{tracks} }
			], undef, $accountName);

			main::SCANNER && Slim::Schema->forceCommit;
		}
	}

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
} }

sub scanArtists { if (main::SCANNER) {
	my ($class, $accounts) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_deezer_artists',
		'total' => 1,
		'every' => 1,
	});

	while (my ($accountName, $userId) = each %$accounts) {
		main::INFOLOG && $log->is_info && $log->info("Reading artists... " . $accountName);
		$progress->update(string('PLUGIN_DEEZER_PROGRESS_READ_ARTISTS', $accountName));

		my $artists = Plugins::Deezer::API::Sync->getFavorites($userId, 'artists') || [];

		$progress->total($progress->total + scalar @$artists);

		foreach my $artist (@$artists) {
			my $name = $artist->{name};

			$artist->{cover} ||= $artist->{picture};

			$progress->update($name);
			main::SCANNER && Slim::Schema->forceCommit;

			Slim::Schema::Contributor->add({
				'artist' => $class->normalizeContributorName($name),
				'extid'  => 'deezer:artist:' . $artist->{id},
			});

			_cacheArtistPictureUrl($artist, '3M');
		}
	}

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
} }

sub scanPlaylists { if (main::SCANNER) {
	my ($class, $accounts) = @_;

	my $dbh = Slim::Schema->dbh();
	my $insertTrackInTempTable_sth = $dbh->prepare_cached("INSERT OR IGNORE INTO online_tracks (url) VALUES (?)") if !$main::wipe;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_deezer_playlists',
		'total' => 0,
		'every' => 1,
	});

	main::INFOLOG && $log->is_info && $log->info("Removing playlists...");
	$progress->update(string('PLAYLIST_DELETED_PROGRESS'), $progress->done);
	my $deletePlaylists_sth = $dbh->prepare_cached("DELETE FROM tracks WHERE url LIKE 'deezer://playlist:%'");
	$deletePlaylists_sth->execute();

	while (my ($accountName, $userId) = each %$accounts) {
		$progress->update(string('PLUGIN_DEEZER_PROGRESS_READ_PLAYLISTS', $accountName), $progress->done);

		main::INFOLOG && $log->is_info && $log->info("Reading playlists for $accountName...");
		my $playlists = Plugins::Deezer::API::Sync->getFavorites($userId, 'playlists') || [];

		$progress->total($progress->total + @$playlists);

		my $prefix = 'Deezer' . string('COLON') . ' ';

		main::INFOLOG && $log->is_info && $log->info(sprintf("Importing tracks for %s playlists...", scalar @$playlists));
		foreach my $playlist (@{$playlists || []}) {
			my $id = $playlist->{id} or next;

			my $tracks = Plugins::Deezer::API::Sync->playlist($userId, $id);

			$progress->update($accountName . string('COLON') . ' ' . $playlist->{title});
			Slim::Schema->forceCommit;

			my $url = "deezer://playlist:$id";

			my $playlistObj = Slim::Schema->updateOrCreate({
				url        => $url,
				playlist   => 1,
				integrateRemote => 1,
				attributes => {
					TITLE        => $prefix . $playlist->{title},
					COVER        => $playlist->{cover},
					AUDIO        => 1,
					EXTID        => $url,
					CONTENT_TYPE => 'ssp'
				},
			});

			my @trackIds = map { "deezer://$_->{id}.$ct" } @$tracks;

			$playlistObj->setTracks(\@trackIds) if $playlistObj && scalar @trackIds;
			$insertTrackInTempTable_sth && $insertTrackInTempTable_sth->execute($url);
		}

		Slim::Schema->forceCommit;
	}

	$progress->final();
	Slim::Schema->forceCommit;
} }

sub getArtistPicture { if (main::SCANNER) {
	my ($class, $id) = @_;

	my $url = $cache->get('deezer_artist_image' . $id);

	return $url if $url;

	$id =~ s/deezer:artist://;

	my $artist = Plugins::Deezer::API::Sync->getArtist(undef, $id) || {};

	if ($artist->{cover}) {
		_cacheArtistPictureUrl($artist, '3M');
		return $artist->{cover};
	}

	return;
} }

my $previousArtistId = '';
sub _cacheArtistPictureUrl {
	my ($artist, $ttl) = @_;

	if ($artist->{cover} && $artist->{id} ne $previousArtistId) {
		$cache->set('deezer_artist_image' . 'deezer:artist:' . $artist->{id}, $artist->{cover}, $ttl || '3M');
		$previousArtistId = $artist->{id};
	}
}

sub trackUriPrefix { 'deezer://' }

# This code is not run in the scanner, but in LMS
sub needsUpdate { if (!main::SCANNER) {
	my ($class, $cb) = @_;

	return $cb->() unless scalar keys %{_enabledAccounts()};

	my $lastScanTime = $cache->get('deezer_library_last_scan') || return $cb->(1);

	my $checkFav = sub {
		my ($userId, $type, $previous, $acb) = @_;

		return $acb->($previous) if $previous;

		Plugins::Deezer::API::Async->new({
			userId => $userId
		})->getCollectionFingerprint(sub {
			my $fingerprint = shift;
			main::INFOLOG && $log->is_info && $log->info("Last update for $type is $fingerprint->{time}");
			$acb->($fingerprint->{time} > $lastScanTime);
		}, $type);
	};

	my $workers = [ map {
		my $userId = $_;
		my @tasks = (
			sub { $checkFav->($userId, 'albums', @_) },
			sub { $checkFav->($userId, 'artists', @_) },
		);

		if (!$class->can('ignorePlaylists') || !$class->ignorePlaylists) {
			push @tasks, sub { $checkFav->($userId, 'playlists', @_) };
		}

		@tasks;
	} sort {
		$a <=> $b
	} values %{_enabledAccounts()} ];

	Async::Util::achain(
		steps => $workers,
		cb => sub {
			my ($result, $error) = @_;
			$cb->($result && !$error);
		}
	);
} }

sub _enabledAccounts {
	my $accounts = $prefs->get('accounts');
	my $dontImportAccounts = $prefs->get('dontImportAccounts');

	my $enabledAccounts = {};

	while (my ($id, $account) = each %$accounts) {
		$enabledAccounts->{$account->{name} || $account->{email}} = $id unless $dontImportAccounts->{$id}
	}

	return $enabledAccounts;
}

sub _prepareTrack {
	my ($album, $track) = @_;

	$ct ||= Plugins::Deezer::API::getFormat();
	my $url = 'deezer://' . $track->{id} . ".$ct";

	my $trackData = {
		url          => $url,
		TITLE        => $track->{title},
		ARTIST       => $track->{artist}->{name},
		ARTIST_EXTID => 'deezer:artist:' . $track->{artist}->{id},
		ALBUM        => $album->{title},
		ALBUM_EXTID  => 'deezer:album:' . $album->{id},
		TRACKNUM     => $track->{tracknum},
		GENRE        => 'Deezer',
		DISC         => $track->{disc},
		DISCC        => $album->{numberOfVolumes} || 1,
		SECS         => $track->{duration},
		YEAR         => substr($album->{release_date} || '', 0, 4),
		COVER        => $album->{cover},
		AUDIO        => 1,
		EXTID        => $url,
		TIMESTAMP    => $album->{added},
		CONTENT_TYPE => $ct,
		LOSSLESS     => $ct eq 'flc' ? 1 : 0,
		RELEASETYPE  => $album->{type},
	};

	my @trackArtists = map { $_->{name} } grep { $_->{name} ne $track->{artist}->{name} } @{ $album->{contributors} };
	if (scalar @trackArtists) {
		$splitChar ||= substr(preferences('server')->get('splitList'), 0, 1);
		$trackData->{TRACKARTIST} = join($splitChar, @trackArtists);
	}

	return $trackData;
}

1;