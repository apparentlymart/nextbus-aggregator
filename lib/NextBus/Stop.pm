
package NextBus::Stop;

use base qw(DBIx::Class);

__PACKAGE__->load_components('Core');
__PACKAGE__->table('stop');
__PACKAGE__->add_columns(qw/id title lat lon/);
__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many('direction_stops', 'NextBus::DirectionStop', 'stop_id');
__PACKAGE__->many_to_many('directions', 'direction_stops', 'direction');

__PACKAGE__->has_many('route_stops', 'NextBus::RouteStop', 'stop_id');
__PACKAGE__->many_to_many('routes', 'route_stops', 'route');

1;
