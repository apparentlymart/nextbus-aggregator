
package NextBus::DirectionStop;

use base qw(DBIx::Class);

__PACKAGE__->load_components('Core');
__PACKAGE__->table('direction_stop');
__PACKAGE__->add_columns(qw/direction_id stop_id seq/);
__PACKAGE__->set_primary_key('direction_id', 'stop_id');

__PACKAGE__->belongs_to('direction', 'NextBus::Direction', 'direction_id');
__PACKAGE__->belongs_to('stop', 'NextBus::Stop', 'stop_id');

1;
