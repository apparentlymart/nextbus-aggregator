
# Perlbal requires plugins to be named with this casing. Lame.
package Perlbal::Plugin::Nextbusaggregator;

use Perlbal;
use strict;
use warnings;
use Symbol;
use Data::Dumper;
use Gearman::Client::Async;
use Gearman::Task;
use URI;
use Storable;
use JSON::Any;

my $gearman = undef;
my $json = JSON::Any->new(pretty => 1);

my %url_handlers = (
    '/vehicle-locations' => \&handle_vehicle_locations,
);

sub handle_request {
    my $class = shift;
    my Perlbal::Service $svc = shift;
    my Perlbal::ClientProxy $pb = shift;

    return 0 unless $pb->{req_headers};

    $class->prepare_gearman($svc);

    my $req_header = $pb->{req_headers};
    if ($req_header->request_method ne 'GET') {
        $pb->send_response(405, "This service only supports GET requests");
        return 1;
    }

    my $url = URI->new('http://whatever'.$req_header->request_uri);
    my $path = $url->path;
    my %args = $url->query_form;

    if (my $handler = $url_handlers{$path}) {
        return $handler->($pb, %args);
    }
    else {
        $pb->send_response(404, "There's nothing here");
        return 1;
    }

    return 1;
}

sub handle_vehicle_locations {
    my ($pb, %args) = @_;

    unless ($args{routes}) {
        return return_bad_request($pb, "No routes specified");
    }

    my $requests = {};

    foreach my $route (split(/,/, $args{routes})) {
        $requests->{$route} = ['get_vehicle_locations', ['sf-muni', $route]];
    }

    my $min_lat;
    my $max_lat;
    my $min_lon;
    my $max_lon;
    my $filter_by_location = 0;

    if (my $bbox = $args{bbox}) {
        ($min_lat, $min_lon, $max_lat, $max_lon) = split(/,/, $bbox);
        $filter_by_location = 1;
    }

    fetch_data_multi($requests, sub {
        my $result = shift;

        use Data::Dumper;
        print Data::Dumper::Dumper($result);

        my $ret = [];
        foreach my $list (values %$result) {
            next unless ref $list eq 'ARRAY';

            if ($filter_by_location) {
                foreach my $vehicle (@$list) {
                    if (
                        $vehicle->{lat} >= $min_lat &&
                        $vehicle->{lat} <= $max_lat &&
                        $vehicle->{lon} >= $min_lon &&
                        $vehicle->{lon} <= $max_lon
                    ) {
                        push @$ret, $vehicle;
                    }
                }
            }
            else {
                # Fast path!
                push @$ret, @$list;
            }
        }

        return_data($pb, $ret);
    });

    return 1;
}

sub fetch_data {
    my ($worker_name, $args, $callback) = @_;

    fetch_data_multi({r => [$worker_name, $args]}, sub {
        $callback->($_[0]->{r});
    });
}

sub fetch_data_multi {
    my ($requests, $callback) = @_;

    my $num_requests = scalar(keys(%$requests));
    my $requests_handled = 0;
    my $ret = {};

    foreach my $k (keys %$requests) {
        my ($worker_name, $args) = @{$requests->{$k}};

        # Things we need to do for both complete and fail
        my $handle_response = sub {
            $requests_handled++;
            if ($requests_handled >= $num_requests) {
                # We're finished!
                $callback->($ret);
            }
        };

        my $raw_args = Storable::nfreeze($args);

        my $task = Gearman::Task->new($worker_name, \$raw_args, {
            uniq => '-',
            on_complete => sub {
                my $raw_result = shift;
                $ret->{$k} = Storable::thaw($$raw_result);
                $handle_response->();
            },
            on_fail => sub {
                $ret->{$k} = undef;
                $handle_response->();
            },
            timeout => 3,
        });

        $gearman->add_task($task);
    }

}

sub return_data {
    my ($pb, $data) = @_;

    my $data_json = $json->encode($data);

    my $res_header = Perlbal::HTTPHeaders->new_response(200);
    $res_header->header('Content-Type', 'application/json');
    $res_header->header('Content-Length', length($data_json));
    $pb->write($res_header->to_string_ref);
    $pb->write($data_json);
    $pb->write(sub { $pb->http_response_sent; });
}

sub return_bad_request {
    my ($pb, $err) = @_;

    $pb->send_response(400, $err);
    return 1;
}

sub prepare_gearman {
    my $class = shift;
    my $svc = shift;

    if (! $gearman) {
        $gearman = Gearman::Client::Async->new(
            job_servers => $svc->{extra_config}{nba_job_servers}
        );
    }
}

sub handle_nba_job_server_command {
    my $mc = shift->parse(qr/^nba_job_server\s*(\d+\.\d+\.\d+\.\d+:\d+)$/, "usage: NBA_JOB_SERVER <ipaddr>:<port>");

    my ($addr) = $mc->args;

    my $svcname;
    unless ($svcname ||= $mc->{ctx}{last_created}) {
        return $mc->err("No service name in context from CREATE SERVICE <name> or USE <service_name>");
    }

    my $svc = Perlbal->service($svcname);
    return $mc->err("Non-existent service '$svcname'") unless $svc;

    $svc->{extra_config}->{nba_job_servers} ||= [];
    push @{$svc->{extra_config}->{nba_job_servers}}, $addr;
}

sub register {
    my ($class, $svc) = @_;

    print STDERR "Extra config is ".Data::Dumper::Dumper($svc->{extra_config});

    $svc->register_hook('NextBusAggregator', 'start_http_request', sub {
        $class->handle_request($svc, $_[0]);
    });
}

sub unregister {
    my ($class, $svc) = @_;

    $svc->unregister_hooks('NextBusAggregator');
}

sub load {
    Perlbal::register_global_hook('manage_command.nba_job_server', \&handle_nba_job_server_command);
    return 1;
}

sub unload {
    return 1;
}

1;

=head1 NAME

Perlbal::Plugin::Nextbusaggregator - Perlbal Plugin that provides a NextBusAggregator web service.

=head1 SYNOPSIS

CREATE SERVICE nextbus
  SET listen          = 0.0.0.0:9080
  SET role            = web_server
  SET plugins         = NextBusAggregator
  NBA_JOB_SERVER 127.0.0.1:7003
ENABLE nextbus

