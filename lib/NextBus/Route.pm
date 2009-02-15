
package NextBus::Route;

use base qw(DBIx::Class);

__PACKAGE__->load_components('Core');
__PACKAGE__->table('route');
__PACKAGE__->add_columns(qw/id key agency_id title key fgcolor bgcolor/);
__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to('agency', 'NextBus::Agency', 'agency_id');
__PACKAGE__->has_many('directions', 'NextBus::Direction', 'route_id');

1;
