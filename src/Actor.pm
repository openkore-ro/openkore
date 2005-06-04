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
##
# MODULE DESCRIPTION: Base class for all actor objects
#
# The Actor class is a base class for all actor objects.
# An actor object is a monster or player (all members of %monsters and
# %players). Do not create an object of this class; use one of the
# subclasses instead.
#
# An actor object is also a hash.
#
# See also: Actor::Monster.pm, Actor::Player.pm and Actor::You.pm

package Actor;
use strict;
use Globals;
use Utils;
use Log qw(message error debug);

### CATEGORY: Class methods

##
# Actor::get($ID)
#
# Returns the actor object for $ID.
sub get {
	my ($ID) = @_;

	if ($ID eq $accountID) {
		return $char;
	} elsif ($monsters{$ID}) {
		return $monsters{$ID} if UNIVERSAL::isa($monsters{$ID}, "Actor");
		return new Actor::Unknown($ID);
	} elsif ($players{$ID}) {
		return $players{$ID} if UNIVERSAL::isa($players{$ID}, "Actor");
		return new Actor::Unknown($ID);
	} elsif ($items{$ID}) {
		return $items{$ID};
	} else {
		return new Actor::Unknown($ID);
	}
}

### CATEGORY: Hash members

##
# $actor->{type}
#
# The actor's type. Can be "Monster", "Player" or "You".


### CATEGORY: Methods

##
# $actor->name()
#
# Returns the name string of an actor, e.g. "Player pmak (3)",
# "Monster Poring (0)" or "You".
sub name {
	my ($self) = @_;

	return "You" if $self->{type} eq 'You';
	return "$self->{type} $self->{name} ($self->{binID})";
}

##
# $actor->verb($you, $other)
#
# Returns $you if $actor is you; $other otherwise.
sub verb {
	my ($self, $you, $other) = @_;

	return $you if $self->{type} eq 'You';
	return $other;
}

##
# $actor->position()
#
# Returns the position of the actor.
sub position {
	my ($self) = @_;

	return calcPosition($self);
}

##
# $actor->distance([$otherActor])
#
# Returns the distance to another actor (defaults to yourself).
sub distance {
	my ($self, $otherActor) = @_;

	$otherActor ||= $char;
	return Utils::distance($self->position, $otherActor->position);
}

1;
