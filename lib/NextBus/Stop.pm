
package NextBus::Stop;

use base qw(DBIx::Class);

__PACKAGE__->load_components('Core');
__PACKAGE__->table('stop');
__PACKAGE__->add_columns(qw/id title lat lon/);
__PACKAGE__->set_primary_key('id');

#__PACKAGE__->belongs_to('agency', 'NextBus::Agency', 'agency_id');

1;
