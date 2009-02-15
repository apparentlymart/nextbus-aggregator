
package NextBus::Direction;

use base qw(DBIx::Class);

__PACKAGE__->load_components('Core');
__PACKAGE__->table('direction');
__PACKAGE__->add_columns(qw/id route_id key title name shown_in_ui/);
__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to('route', 'NextBus::Route', 'route_id');

__PACKAGE__->has_many('direction_stops', 'NextBus::DirectionStop', 'direction_id');
__PACKAGE__->many_to_many('stops', 'direction_stops', 'stop');

1;
