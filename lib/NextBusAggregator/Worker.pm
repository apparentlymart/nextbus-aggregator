
package NextBusAggregator::Worker;

use strict;
use warnings;

use Gearman::Worker;
use Gearman::Client;
use Storable;
use LWP::UserAgent;
use HTTP::Request;
use Carp;
use Cache::Memcached;
use XML::LibXML;

my $worker;
my $cache;
my $session_cookie;
my $job_servers;
my $cache_servers;
my $ua;

sub run {
    my ($class, %opts) = @_;

    $job_servers = delete $opts{job_servers};
    $cache_servers = delete $opts{cache_servers};

    Carp::croak("Unrecognised options(s): ".join(keys(%opts))) if %opts;

    # TEMP: Make a log file
    open(LOG, '>>', 'worker.log');
    print LOG "Opened log file\n";

    $cache = Cache::Memcached->new({
        servers => $cache_servers,
    });

    $ua = LWP::UserAgent->new();
    $ua->agent("Mozilla/4.0 (Compatible)");

    my $h = sub {
        my $handler = shift;
        return sub {
            my $job = shift;
            my $args = $job->arg ? Storable::thaw($job->arg) : undef;
            my $ret = $handler->($args ? @$args : ());
            return Storable::nfreeze(ref $ret ? $ret : \$ret);
        };
    };

    $worker = Gearman::Worker->new(job_servers => $job_servers);
    $worker->register_function(get_config => $h->(\&get_config));
    $worker->register_function(get_stops => $h->(\&get_stops));
    $worker->register_function(get_vehicle_locations => $h->(\&get_vehicle_locations));
    $worker->register_function(get_predictions => $h->(\&get_predictions));
    $worker->register_function(get_session_cookie => $h->(\&get_session_cookie));

    $SIG{INT} = $SIG{TERM} = sub {
        exit(0);
    };

    _log("Entering job loop");
    $worker->work while 1;
}

sub get_session_cookie {

    my $cookie = $cache->get("session_cookie");

    if ($cookie) {
        return $cookie;
    }
    else {
        # Need to go get a new one from the NextBus server.
        _log("Starting a session with NextBus");
        my $req = HTTP::Request->new("GET" => "http://www.nextmuni.com/googleMap/googleMap.jsp?a=sf-muni");
        print STDERR $req->as_string;

        my $res = $ua->request($req);

        if ($res->is_success) {
            my $cookie_header = $res->header('Set-Cookie');
            if ($cookie_header =~ /JSESSIONID=(\w+)/) {
                $cookie = $1;
                $cache->set("session_cookie", $cookie);
                _log("Session key is ", $cookie);
                return $cookie;
            }
            else {
                # Huh?
                return undef;
            }
        }
        else {
            # NextBus has changed something, I guess?
            return undef;
        }
    }

}

sub get_config {
}

sub get_stops {
}

sub get_vehicle_locations {
    my ($agency, $route) = @_;

    my $cache_key = join('.', 'vehicle_locations', $agency, $route);

    if (my $ret = $cache->get($cache_key)) {
        return $ret;
    }

    my $url = "http://www.nextmuni.com/s/COM.NextBus.Servlets.XMLFeed?command=vehicleLocations&a=".eurl($agency)."&r=".eurl($route)."&t=1";

    _log("Getting vehicle locations for $agency $route");
    my $doc = _fetch($url);
    return undef unless $doc;

    my $ret = [];
    my $xp = XML::LibXML::XPathContext->new($doc);
    foreach my $elem ($xp->findnodes('/body/vehicle')) {
        next if $elem->getAttribute('predictable') ne 'true';
        next if $elem->getAttribute('leadingVehicleId');

        my $vehicle = {};

        foreach my $k (qw(id routeTag dirTag lat lon secsSinceReport heading)) {
            $vehicle->{$k} = $elem->getAttribute($k);
        }

        push @$ret, $vehicle;
    }

    $cache->set($cache_key, $ret, @$ret ? 30 : 5);
    return $ret;
}

sub get_predictions {
}

sub _fetch {
    my ($url, $no_retry) = @_;

    _log("Fetching $url".($no_retry ? ' again' : ''));

    _initialize_session();

    my $req = HTTP::Request->new(GET => $url);
    $req->header('Cookie' => 'JSESSIONID='.$session_cookie);
    print STDERR $req->as_string;
    my $res = $ua->request($req);

    if ($res->is_success) {
        my $content = $res->content;

        if ($content !~ /<Error /) {
            my $parser = XML::LibXML->new();
            my $ret = undef;
            eval {
                $ret = $parser->parse_string($content);
            };
            _log("Fetch succeeded");
            # If parsing failed then $ret will still be undef here
            return $ret;
        }
        else {
            # Session expired?
            _log("Session has expired");
            $cache->delete("session_cookie");
            $session_cookie = undef;
            return $no_retry ? undef : _fetch($url, 1);
        }
    }
    else {
        _log("Request failed: ".$res->status_line);
        return undef;
    }

}

sub _initialize_session {

    unless (defined $session_cookie) {

        # TEMP: Doing this with gearman doesn't seem to work right,
        # so for now let's just do it directly.
        $session_cookie = get_session_cookie();
        _log("New session cookie is $session_cookie");
        return;

        # Need to go get a session cookie
        # We do this with a nested gearman call so that
        # when the session expires the workers don't
        # all stampede the server.
        _log("Doing session cookie request");
        my $client = Gearman::Client->new(job_servers => $job_servers);
        my $result = $client->do_task("get_session_cookie", "", {
            uniq => "-",
            timeout => 5,
        });
        if ($result) {
            _log("Session cookie request succeeded");
            $session_cookie = ${Storable::thaw($$result)};
            _log("New session cookie is $session_cookie");
        }
        else {
            _log("Session cookie request failed");
        }
    }

}

sub eurl {
    my $str = shift;
    $str =~ s/([\W])/"%".uc(sprintf("%2.2x",ord($1)))/eg;
    return $str;
}

sub _log {
    print LOG @_, "\n";
    $| = 1;
}

1;
