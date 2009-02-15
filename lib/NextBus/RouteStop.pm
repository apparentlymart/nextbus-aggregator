
package NextBus::RouteStop;

use base qw(DBIx::Class);

__PACKAGE__->load_components('Core');
__PACKAGE__->table('route_stop');
__PACKAGE__->add_columns(qw/route_id stop_id/);
__PACKAGE__->set_primary_key('route_id', 'stop_id');

__PACKAGE__->belongs_to('route', 'NextBus::Route', 'route_id');
__PACKAGE__->belongs_to('stop', 'NextBus::Stop', 'stop_id');

1;
