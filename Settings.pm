package Plugins::Deezer::Settings;

use strict;
use base qw(Slim::Web::Settings);

use JSON::XS::VersionOneAndTwo;
use HTTP::Status qw(RC_MOVED_TEMPORARILY);
use Data::URIEncode qw(complex_to_query);
use MIME::Base64 qw(decode_base64);

use Slim::Utils::Prefs;
use Plugins::Deezer::API::Auth;
use Plugins::Deezer::API qw(AURL);

my $prefs = preferences('plugin.deezer');
my $log = Slim::Utils::Log::logger('plugin.deezer');
my $seed = int(rand(1000)) + 1;

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_DEEZER_NAME') }

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/Deezer/settings.html') }

sub prefs { return ($prefs, qw(quality liveformat liverate unfold_collection check_track_rights rights_cache_ttl)) }

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ($params->{addAccount}) {
		my $arl = $params->{arl};
		main::INFOLOG && $log->is_info && $log->info("Adding/Refreshing account with arl $arl");
		
		Plugins::Deezer::API::Async::getUserFromARL( sub {	
			my $user = shift;
		
			if ( my $userId = $user->{id} ) {
				$user->{status} = 2;
				$user->{arl} = $arl;
			
				main::INFOLOG && $log->is_info && $log->info("Added/refreshed user $user->{name} successfully");

				my $accounts = $prefs->get('accounts');
				my %account = (%{$accounts->{$userId} || {}}, 
								%{$user}, 
				);
				$accounts->{$userId} = \%account;
				$prefs->set('accounts', $accounts);
				Plugins::Deezer::API::Async::refreshArl($userId);
			} else {
				$params->{'warning'} = Slim::Utils::Strings::string('PLUGIN_DEEZER_AUTH_FAILED');
				$log->error("Unable to add /refresh user with ARL $arl");
			}
			
			my $body = $class->SUPER::handler( $client, $params );
			$callback->($client, $params, $body, @args);
		},  $arl );
		
=comment		
		Plugins::Deezer::API::Auth::authRegister($params->{seed}, sub {
			my ($seed, $success) = @_;
			$params->{'warning'} = Slim::Utils::Strings::string('PLUGIN_DEEZER_AUTH_FAILED') unless $success;
			my $body = $class->SUPER::handler( $client, $params );
			$callback->($client, $params, $body, @args);
		} );
=cut		
		return;
	}

	if ( my ($deleteAccount) = map { /delete_(.*)/; $1 } grep /^delete_/, keys %$params ) {
		my $accounts = $prefs->get('accounts') || {};
		delete $accounts->{$deleteAccount};
		$prefs->set('accounts', $accounts);
	}

	if ($params->{saveSettings}) {
		my $dontImportAccounts = $prefs->get('dontImportAccounts') || {};
		my $accounts = $prefs->get('accounts') || {};
		foreach my $prefName (keys %$params) {
			if ($prefName =~ /^pref_dontimport_(.*)/) {
				$dontImportAccounts->{$1} = $params->{$prefName};
			}
			if ($prefName =~ /^pref_arl_(.*)/ && $accounts->{$1}) {
				$accounts->{$1}->{arl} = $params->{$prefName};
				Plugins::Deezer::API::Async::refreshArl($accounts->{$1}->{id});
			}
		}
		$prefs->set('dontImportAccounts', $dontImportAccounts);
		$prefs->set('accounts', $accounts);
	}

	return $class->SUPER::handler($client, $params);
}

sub beforeRender {
	my ($class, $params) = @_;

	my $accounts = $prefs->get('accounts') || {};

	$params->{credentials} = [ sort {
		$a->{name} cmp $b->{name}
	} map {
		{
			name => $_->{name} || $_->{email},
			id => $_->{id},
			arl => $_->{arl},
		}
	} values %$accounts] if scalar keys %$accounts;

=comment
	my $cid = decode_base64($Plugins::Deezer::API::Auth::serial);
	$cid = pack('H*', $cid);
	$cid =~ s/_.*//;

	my $query = complex_to_query( {
		app_id => $cid,
		redirect_uri => 'https://philippe44.github.io/lms-deezer/index.html?args=' .
						Slim::Utils::Network::serverAddr() . ':' .
						preferences('server')->get('httpport') .
						"&seed=$seed",
		perms => 'basic_access,offline_access,email,manage_library,delete_library,listening_history',
	} );

	$params->{seed} = $seed++;
	$params->{authLink} = AURL . '/auth.php?' . $query;
=cut	
	$params->{dontImportAccounts} = $prefs->get('dontImportAccounts') || {};
}

1;