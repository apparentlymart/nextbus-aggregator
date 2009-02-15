
package NextBus;

use strict;
use warnings;

use DBI;

use base qw(DBIx::Class::Schema);

__PACKAGE__->load_classes(qw(Agency Route Stop Direction RouteStop DirectionStop));

sub populate_database {
    my ($class, $dsn, $user, $password, $attrs, @agencies) = @_;

    {
        # Create our tables

        my $dbh = DBI->connect($dsn, $user, $password, $attrs);

        $dbh->do('CREATE TABLE agency (id INTEGER PRIMARY KEY, key TEXT)');
        $dbh->do('CREATE TABLE direction (id INTEGER PRIMARY KEY, key TEXT, route_id NUMERIC, name TEXT, shown_in_ui NUMERIC, title TEXT)');
        $dbh->do('CREATE TABLE direction_stop (direction_id NUMERIC, stop_id NUMERIC, seq NUMERIC)');
        $dbh->do('CREATE TABLE route (bgcolor TEXT, fgcolor TEXT, id INTEGER PRIMARY KEY, key TEXT, title TEXT, agency_id NUMERIC)');
        $dbh->do('CREATE TABLE route_stop (route_id NUMERIC, stop_id NUMERIC)');
        $dbh->do('CREATE TABLE stop (id INTEGER PRIMARY KEY, lat NUMERIC, lon NUMERIC, title TEXT)');

        $dbh->disconnect();
    }

    {
        # Now we can actually use the ORM to do the inserts.

        my $nextbus = $class->connect($dsn, $user, $password, $attrs);

        require LWP::UserAgent;
        require HTTP::Request;
        require XML::LibXML;

        my $ua = new LWP::UserAgent;
        $ua->agent("Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.5) Gecko/2008121621 Ubuntu/8.04 (hardy) Firefox/3.0.5");
        my $p = XML::LibXML->new();

        # Track which stops we've already inserted, since we don't yet
        # have the indexes in the DB to do it for us.
        my %seen_stops = ();

        foreach my $agency_key (@agencies) {

            my $agency = $nextbus->resultset('Agency')->create({
                key => $agency_key,
            });
            $agency->update();

            my $agency_id = $agency->id;

            print STDERR "Created agency $agency_key with id $agency_id\n";

            my $session_id = undef;

            my $make_request = sub {
                my ($url) = @_;

                print STDERR "* Requesting $url\n";

                my $req = HTTP::Request->new(GET => $url);
                if ($session_id) {
                    $req->header('Cookie' => 'JSESSIONID='.$session_id);

                    # Make us look like a web browser
                    $req->header('Accept' => 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
                    $req->header('Accept-Language' => 'en-us,en;q=0.5');
                }

                my $res = $ua->request($req);

                my $ret = undef;

                if ($res->is_success) {
                    if (my $set_cookie = $res->header('Set-Cookie')) {
                        if ($set_cookie =~ /JSESSIONID=(\w+)/) {
                            $session_id = $1;
                            print STDERR "session id is now $session_id\n";
                        }
                    }

                    if ($res->header('Content-Type') eq 'text/xml') {
                        return $p->parse_string($res->content);
                    }
                    else {
                        $ret = $res->content;
                    }
                }

                return $ret;
            };

            # Now we request the route selector page (HTML) to get a list of routes
            my $html = $make_request->("http://www.nextmuni.com/googleMap/routeSelector.jsp?a=".eurl($agency_key));

            my @route_keys = ();

            while ($html =~ m!routeSelected\('([^']+)'\)!g) {
                push @route_keys, $1;
            }

            # Request the main HTML page just to seed the session_id
            $make_request->("http://www.nextmuni.com/googleMap/googleMap.jsp?a=".eurl($agency_key));

            # We need to request the configuration for each route separately.
            # This time it's XML we're getting.

            foreach my $route_key (@route_keys) {
                my $route_doc = $make_request->("http://www.nextmuni.com/s/COM.NextBus.Servlets.XMLFeed?command=routeConfig&a=".eurl($agency_key)."&r=".eurl($route_key));

                my $xp = XML::LibXML::XPathContext->new($route_doc);

                my ($route_elem) = $xp->findnodes('/body/route');

                my $title = $route_elem->getAttribute("title");
                my $bgcolor = $route_elem->getAttribute("color");
                my $fgcolor = $route_elem->getAttribute("oppositeColor");

                my $route = $nextbus->resultset('Route')->create({
                    key => $route_key,
                    title => $title,
                    bgcolor => $bgcolor,
                    fgcolor => $fgcolor,
                    agency_id => $agency_id,
                });
                $route->update();
                my $route_id = $route->id;

                print STDERR "Created route $route_key with id $route_id\n";

                # Now find all the stops for this route.
                foreach my $stop_elem ($xp->findnodes('/body/route/stop')) {
                    my $stop_id = $stop_elem->getAttribute("tag");

                    # Where a given stop is present on multiple routes,
                    # only add the first instance we see.
                    unless ($seen_stops{$stop_id}) {

                        my $title = $stop_elem->getAttribute("title");
                        my $lat = $stop_elem->getAttribute("lat");
                        my $lon = $stop_elem->getAttribute("lon");

                        my $stop = $nextbus->resultset('Stop')->create({
                            id => $stop_id,
                            title => $title,
                            lat => $lat,
                            lon => $lon,
                        });
                        $stop->update();

                        $seen_stops{$stop_id} = 1;

                    }

                    $nextbus->resultset('RouteStop')->create({
                        route_id => $route_id,
                        stop_id => $stop_id,
                    })->update();

                }

                foreach my $direction_elem ($xp->findnodes('/body/route/direction')) {
                    my $key = $direction_elem->getAttribute('tag');
                    my $title = $direction_elem->getAttribute('title');
                    my $name = $direction_elem->getAttribute('name');
                    my $shown_in_ui = ($direction_elem->getAttribute('useForUI') eq 'true') ? 1 : 0;

                    my $direction = $nextbus->resultset('Direction')->create({
                        route_id => $route_id,
                        key => $key,
                        title => $title,
                        name => $name,
                        shown_in_ui => $shown_in_ui,
                    });
                    $direction->update();

                    my $direction_id = $direction->id;

                    my $seq = 1;
                    foreach my $stop_elem ($xp->findnodes('stop', $direction_elem)) {
                        my $stop_id = $stop_elem->getAttribute('tag');
                        $nextbus->resultset('DirectionStop')->create({
                            direction_id => $direction_id,
                            stop_id => $stop_id,
                            seq => $seq++,
                        })->update();
                    }

                }

            }

        }

    }

    {
        # Now we've inserted everything, create the indexes.

        my $dbh = DBI->connect($dsn, $user, $password, $attrs);
        $dbh->do('CREATE UNIQUE INDEX agency_key ON agency(key ASC)');
        $dbh->do('CREATE UNIQUE INDEX direction_key ON direction(key ASC)');
        $dbh->do('CREATE UNIQUE INDEX direction_stop_key ON direction_stop (direction_id, stop_id)');
        $dbh->do('CREATE UNIQUE INDEX route_key ON route(key ASC)');
        $dbh->do('CREATE UNIQUE INDEX route_stop_key ON route_stop (route_id, stop_id)');
        $dbh->do('CREATE INDEX route_direction_key ON direction (route_id)');
        $dbh->do('CREATE INDEX route_agency_key ON route (agency_id)');
        $dbh->disconnect();
    }

}

sub eurl {
    my $str = shift;
    $str =~ s/([\W])/"%".uc(sprintf("%2.2x",ord($1)))/eg;
    return $str;
}

1;

=head1 NAME

NextBus - interface to NextBus data mirrored in a local database

