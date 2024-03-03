package Plugins::Deezer::API::Auth;

use strict;
use Data::URIEncode qw(complex_to_query);
use JSON::XS::VersionOneAndTwo;
use Digest::SHA qw(sha512_hex);
use MIME::Base64 qw(decode_base64);
use URI::Escape qw(uri_unescape);
use URI::QueryParam;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::Deezer::API qw(AURL BURL);

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.deezer');
my $prefs = preferences('plugin.deezer');

our ($serial, $cbc);
my $cbcRetry = 30;
my (%waiters);

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/Deezer/auth.html') }

sub init {
	Slim::Web::Pages->addRawFunction("deezer/auth", \&authCallback);
	
	my $sha = sha512_hex(__PACKAGE__);
	$serial = $prefs->get('serial'),
	$serial = pack('H*', $serial);
	$serial ^= substr($sha, 0, length $serial);

	_getCBC();
}

sub _getCBC {
		Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my ($url) = shift->content =~ /<script src=\"(https:\/\/[a-z-.\/]+app-web[a-z0-9.]+).*<\/script>/;
			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					my $content = shift->content;
					my $v1 = uri_unescape($1) if $content =~ /%5B(0x61.*?)%5D/;
					my $v2 = uri_unescape($1) if $content =~ /%5B(0x31.*?)%5D/;
					my @data = reverse(map { hex } split /,/, "$v1,$v2");
					$cbc .= pack('C', $data[$_+8]) . pack('C', $data[$_]) foreach (0..7);
					if (!$cbc) {
						Slim::Utils::Timers::setTimer(undef, time() + $cbcRetry, \&_getCBC);				
						$log->warn("Fail to get bootstrapped, retrying in $cbcRetry sec");
						$cbcRetry *= 2;
					} else {	
						main::INFOLOG && $log->is_info && $log->info("Successfully bootstrapped") if $cbc;
					}
				}, sub {				
					Slim::Utils::Timers::setTimer(undef, time() + $cbcRetry, \&_getCBC);				
					$log->warn("Fail to get bootstrapped $url ($_[1]), retrying in $cbcRetry sec");
					$cbcRetry *= 2;
				}
			)->get($url);
		},
		sub {
			Slim::Utils::Timers::setTimer(undef, time() + $cbcRetry, \&_getCBC);
			$log->warn("Fail to get jumpstart ($_[1]), retrying in $cbcRetry sec");
			$cbcRetry *= 2;
		}
	)->get('https://www.deezer.com/en/channels/explore');
}	

sub authRegister {
	my ($seed, $cb) = @_;

	$waiters{$seed} = $cb;
	
	Slim::Utils::Timers::setTimer($seed, time() + 60, sub {
		my $seedd = shift;
		return unless $waiters{$seed};
		
		main::INFOLOG && $log->is_info && $log->info("Timeout waiting for approval on seed $seed");
		$waiters{$seed}->($seed);
		delete $waiters{$seed};		
	}, $seed);
}	

sub authCallback {
	my ($httpClient, $response, $func) = @_;
	my $code = $response->request->uri->query_param('code');
	my $seed = $response->request->uri->query_param('seed');
	
	# make sure this is not a rogue call
	return $log->warn("unexpected auth callback $seed") unless $waiters{$seed};
	
$log->error("GOT OAUTH CODE $code WITH SEED $seed");
	
	my $epilog = sub {
		my $httpCode  = shift;
		
		$response->code($httpCode);
		$response->header('Connection' => 'close');
		$response->content_type('text/html');
		
		my $body =
			'<!DOCTYPE html>
			<title>close</title>
			<html lang="en">
				<head><script>window.close()</script></head>
			</html>';
		Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$body);
		
		$waiters{$seed}->($seed, $httpCode == 200);
		delete $waiters{$seed};
	};

	_getAPIToken( $code, sub {
		my $token = shift;
		return $epilog->(500) if !$token;

		_getUserData( $token->{access_token}, sub {
			my $user = shift;
			return $epilog->(500) if !$user;

			my $userId = $user->{id};
			main::INFOLOG && $log->is_info && $log->info("Got token for user $user->{name} using seed $seed");
$log->error("TOKEN IS $token->{access_token}");

			my $accounts = $prefs->get('accounts');
			my %account = (%{$accounts->{$userId} || {}}, 
						   %{$user}, 
						   token => $token->{access_token}
		    );
			$accounts->{$userId} = \%account;
			$prefs->set('accounts', $accounts);

			$epilog->(200);
		} );
	} );
}

sub _getUserData {
	my ( $token, $cb ) = @_;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $user = eval { from_json($_[0]->content) };
			$@ && $log->error($@) && return $cb->();
			undef $user if $user->{status} != 2;
			$cb->($user);
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));
			$cb->();
		}
	)->get(BURL . "/user/me?access_token=$token");
}

sub _getAPIToken {
	my ( $code, $cb ) = @_;
	
	my $data = decode_base64($serial);
	$data = pack('H*', $data);
	my ($cid, $sec) = $data =~ /(\w+)_(\w+)/;
	
	my $query = complex_to_query( {
		app_id => $cid,
		secret => $sec,
		output => 'json',
		code => $code,
	} );

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $result = eval { from_json($_[0]->content) };
			$@ && $log->error($@) && return $cb->();

			$cb->($result);
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));
			$cb->();
		}
	)->get(AURL . '/access_token.php?' . $query );
}


1;