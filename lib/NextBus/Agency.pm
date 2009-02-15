
package NextBus::Agency;

use base qw(DBIx::Class);

__PACKAGE__->load_components('Core');
__PACKAGE__->table('agency');
__PACKAGE__->add_columns(qw/id key/);
__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many('routes', 'NextBus::Route', 'agency_id');

1;
x
