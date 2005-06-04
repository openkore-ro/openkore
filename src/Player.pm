#########################################################################
#  OpenKore - Base class for all actor objects
#  Copyright (c) 2005 OpenKore Team
#
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#
#  $Revision$
#  $Id$
#
#########################################################################
package Player;

use strict;

our @ISA = qw(Actor);

sub new {
	return bless({type => 'Player'});
}

1;
