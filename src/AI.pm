# Helper functions for managing @ai_seq.
#
# Eventually, @ai_seq should never be referenced directly, and then it can be
# moved into this package.

package AI;

use strict;
use Globals;
use Utils qw(binFind);
use Log qw(message warning error debug);
use Network;
use Network::Send;
use Utils;
use Exporter;
use base qw(Exporter);

our @EXPORT = (
	qw/
	ai_clientSuspend
	ai_drop
	ai_follow
	ai_partyfollow
	ai_getAggressives
	ai_getPlayerAggressives
	ai_getMonstersAttacking
	ai_getSkillUseType
	ai_mapRoute_searchStep
	ai_items_take
	ai_route
	ai_route_getRoute
	ai_sellAutoCheck
	ai_setMapChanged
	ai_setSuspend
	ai_skillUse
	ai_skillUse2
	ai_storageAutoCheck
	ai_waypoint
	cartGet
	cartAdd
	ai_talkNPC
	attack
	gather
	move
	sit
	stand
	take/
);

sub action {
	my $i = (defined $_[0] ? $_[0] : 0);
	return $ai_seq[$i];
}

sub args {
	my $i = (defined $_[0] ? $_[0] : 0);
	return \%{$ai_seq_args[$i]};
}

sub dequeue {
	shift @ai_seq;
	shift @ai_seq_args;
}

sub queue {
	unshift @ai_seq, shift;
	my $args = shift;
	unshift @ai_seq_args, ((defined $args) ? $args : {});
}

sub clear {
	if (@_) {
		my $changed;
		for (my $i = 0; $i < @ai_seq; $i++) {
			if (defined binFind(\@_, $ai_seq[$i])) {
				delete $ai_seq[$i];
				delete $ai_seq_args[$i];
				$changed = 1;
			}
		}

		if ($changed) {
			my (@new_seq, @new_args);
			for (my $i = 0; $i < @ai_seq; $i++) {
				if (defined $ai_seq[$i]) {
					push @new_seq, $ai_seq[$i];
					push @new_args, $ai_seq_args[$i];
				}
			}
			@ai_seq = @new_seq;
			@ai_seq_args = @new_args;
		}

	} else {
		undef @ai_seq;
		undef @ai_seq_args;
	}
}

sub suspend {
	my $i = (defined $_[0] ? $_[0] : 0);
	$ai_seq_args[$i]{suspended} = time if $i < @ai_seq_args;
}

sub mapChanged {
	my $i = (defined $_[0] ? $_[0] : 0);
	$ai_seq_args[$i]{mapChanged} = time if $i < @ai_seq_args;
}

sub findAction {
	return binFind(\@ai_seq, $_[0]);
}

sub inQueue {
	foreach (@_) {
		# Apparently using a loop is faster than calling
		# binFind() (which is optimized in C), because
		# of function call overhead.
		#return 1 if defined binFind(\@ai_seq, $_);
		foreach my $seq (@ai_seq) {
			return 1 if ($_ eq $seq);
		}
	}
	return 0;
}

sub isIdle {
	return $ai_seq[0] eq "";
}

sub is {
	foreach (@_) {
		return 1 if ($ai_seq[0] eq $_);
	}
	return 0;
}


##########################################


##
# ai_clientSuspend(packet_switch, duration, args...)
# initTimeout: a number of seconds.
#
# Freeze the AI for $duration seconds. $packet_switch and @args are only
# used internally and are ignored unless XKore mode is turned on.
sub ai_clientSuspend {
	my ($type, $duration, @args) = @_;
	my %args;
	$args{type} = $type;
	$args{time} = time;
	$args{timeout} = $duration;
	@{$args{args}} = @args;
	AI::queue("clientSuspend", \%args);
	debug "AI suspended by clientSuspend for $args{timeout} seconds\n";
}

##
# ai_drop(items, max)
# items: reference to an array of inventory item numbers.
# max: the maximum amount to drop, for each item, or 0 for unlimited.
#
# Drop one or more items.
#
# Example:
# # Drop inventory items 2 and 5.
# ai_drop([2, 5]);
# # Drop inventory items 2 and 5, but at most 30 of each item.
# ai_drop([2, 5], 30);
sub ai_drop {
	my $r_items = shift;
	my $max = shift;
	my %seq = ();

	if (@{$r_items} == 1) {
		# Dropping one item; do it immediately
		Misc::drop($r_items->[0], $max);
	} else {
		# Dropping multiple items; queue an AI sequence
		$seq{items} = \@{$r_items};
		$seq{max} = $max;
		$seq{timeout} = 1;
		AI::queue("drop", \%seq);
	}
}

sub ai_follow {
	my $name = shift;

	if (binFind(\@ai_seq, "follow") eq "") {
		my %args;
		$args{name} = $name;
		push @ai_seq, "follow";
		push @ai_seq_args, \%args;
	}

	return 1;
}

sub ai_partyfollow {
	# we have to enable re-calc of route based on master's possition regulary, even when it is
	# on route and move, otherwise we have finaly moved to the possition and found that the master
	# already teleported to another side of the map.

	# This however will give problem on few seq such as storageAuto as 'move' and 'route' might
	# be triggered to move to the NPC

	my %master;
	$master{id} = main::findPartyUserID($config{followTarget});
	if ($master{id} ne "" && !AI::inQueue("storageAuto","storageGet","sellAuto","buyAuto")) {

		$master{x} = $char->{party}{users}{$master{id}}{pos}{x};
		$master{y} = $char->{party}{users}{$master{id}}{pos}{y};
		($master{map}) = $char->{party}{users}{$master{id}}{map} =~ /([\s\S]*)\.gat/;

		if ($master{map} ne $field{name} || $master{x} == 0 || $master{y} == 0) {
			delete $master{x};
			delete $master{y};
		}

		return unless ($master{map} ne $field{name} || exists $master{x});

		if ((exists $ai_v{master} && distance(\%master, $ai_v{master}) > 15)
			|| $master{map} != $ai_v{master}{map}
			|| (timeOut($ai_v{master}{time}, 15) && distance(\%master, $char->{pos_to}) > $config{followDistanceMax})) {

			$ai_v{master}{x} = $master{x};
			$ai_v{master}{y} = $master{y};
			$ai_v{master}{map} = $master{map};
			$ai_v{master}{time} = time;

			if ($ai_v{master}{map} ne $field{name}) {
				message "Calculating route to find master: $ai_v{master}{map}\n", "follow";
			} elsif (distance(\%master, $char->{pos_to}) > $config{followDistanceMax} ) {
				message "Calculating route to find master: $ai_v{master}{map} ($ai_v{master}{x},$ai_v{master}{y})\n", "follow";
			} else {
				return;
			}

			AI::clear("move", "route", "mapRoute");
			ai_route($ai_v{master}{map}, $ai_v{master}{x}, $ai_v{master}{y}, distFromGoal => $config{followDistanceMin});

			my $followIndex = AI::findAction("follow");
			if (defined $followIndex) {
				$ai_seq_args[$followIndex]{ai_follow_lost_end}{timeout} = $timeout{ai_follow_lost_end}{timeout};
			}
		}
	}
}

##
# ai_getAggressives([check_mon_control], [party])
# Returns: an array of monster hashes.
#
# Get a list of all aggressive monsters on screen.
# The definition of "aggressive" is: a monster who has hit or missed me.
#
# If $check_mon_control is set, then all monsters in mon_control.txt
# with the 'attack_auto' flag set to 2, will be considered as aggressive.
# See also the manual for more information about this.
#
# If $party is set, then monsters that have fought with party members
# (not just you) will be considered as aggressive.
sub ai_getAggressives {
	my ($type, $party) = @_;
	my $wantArray = wantarray;
	my $num = 0;
	my @agMonsters;

	foreach (@monstersID) {
		next if (!$_);
		my $monster = $monsters{$_};

		if ((($type && Misc::mon_control($monster->{name})->{attack_auto} == 2) ||
		    $monster->{dmgToYou} || $monster->{missedYou} ||
			($party && ($monster->{dmgToParty} || $monster->{missedToParty} || $monster->{dmgFromParty})))
		  && timeOut($monster->{attack_failed}, $timeout{ai_attack_unfail}{timeout})) {

			# Remove monsters that are considered forced agressive (when set to 2 on Mon_Control)
			# but has not yet been damaged or attacked by party AND currently has no LOS
			# if this is not done, Kore will keep trying infinitely attack targets set to aggro but who
			# has no Line of Sight (ex.: GH Cemitery when on a higher position seeing an aggro monster in lower levels).
			# The other parameters are re-checked along, so you can continue to attack a monster who has 
			# already been hit but lost the line for some reason.
			# Also, check if the forced aggressive is a clean target when it has not marked as "yours".
			my $pos = calcPosition($monster);

			if ($config{'attackCanSnipe'}) {
				next if (($type && Misc::mon_control($monster->{name})->{attack_auto} == 2) && 
					(!Misc::checkLineSnipable($char->{pos_to}, $pos)) && 
					!$monster->{dmgToYou} && !$monster->{missedYou} &&
				    ($party && (!$monster->{dmgToParty} && !$monster->{missedToParty} && !$monster->{dmgFromParty})));
			} else {
				next if (($type && Misc::mon_control($monster->{name})->{attack_auto} == 2) && 
					(!Misc::checkLineWalkable($char->{pos_to}, $pos)) && 
					!$monster->{dmgToYou} && !$monster->{missedYou} &&
				    ($party && (!$monster->{dmgToParty} && !$monster->{missedToParty} && !$monster->{dmgFromParty})));
			}
			
			# Continuing, check whether the forced Agro is really a clean monster;
			next if (($type && Misc::mon_control($monster->{name})->{attack_auto} == 2) && !Misc::checkMonsterCleanness($_));
			  
			if ($wantArray) {
				# Function is called in array context
				push @agMonsters, $_;

			} else {
				# Function is called in scalar context
				my $mon_control = Misc::mon_control($monster->{name});
				if ($mon_control->{weight} > 0) {
					$num += $mon_control->{weight};
				} elsif ($mon_control->{weight} != -1) {
					$num++;
				}
			}
		}
	}

	if ($wantArray) {
		return @agMonsters;
	} else {
		return $num;
	}
}

sub ai_getPlayerAggressives {
	my $ID = shift;
	my @agMonsters;

	foreach (@monstersID) {
		next if ($_ eq "");
		if ($monsters{$_}{dmgToPlayer}{$ID} > 0 || $monsters{$_}{missedToPlayer}{$ID} > 0 || $monsters{$_}{dmgFromPlayer}{$ID} > 0 || $monsters{$_}{missedFromPlayer}{$ID} > 0) {
			push @agMonsters, $_;
		}
	}
	return @agMonsters;
}

##
# ai_getMonstersAttacking($ID)
#
# Get the monsters who are attacking player $ID.
sub ai_getMonstersAttacking {
	my $ID = shift;
	my @agMonsters;
	foreach (@monstersID) {
		next unless $_;
		my $monster = $monsters{$_};
		push @agMonsters, $_ if $monster->{target} eq $ID;
	}
	return @agMonsters;
}

##
# ai_getSkillUseType(name)
# name: the internal name of the skill (as found in skills.txt), such as
# WZ_FIREPILLAR.
# Returns: 1 if it's a location skill, 0 if it's an object skill.
#
# Determines whether a skill is a skill that's casted on a location, or one
# that's casted on an object (monster/player/etc).
# For example, Firewall is a location skill, while Cold Bolt is an object
# skill.
sub ai_getSkillUseType {
	my $skill = shift;
	return 1 if $skillsArea{$skill} == 1;
	return 0;
}

sub ai_mapRoute_searchStep {
	my $r_args = shift;

	unless ($r_args->{openlist} && %{$r_args->{openlist}}) {
		$r_args->{done} = 1;
		$r_args->{found} = '';
		return 0;
	}

	my $parent = (sort {$$r_args{'openlist'}{$a}{'walk'} <=> $$r_args{'openlist'}{$b}{'walk'}} keys %{$$r_args{'openlist'}})[0];
	debug "$parent, $$r_args{'openlist'}{$parent}{'walk'}\n", "route/path";
	# Uncomment this if you want minimum MAP count. Otherwise use the above for minimum step count
	#foreach my $parent (keys %{$$r_args{'openlist'}})
	{
		my ($portal,$dest) = split /=/, $parent;
		if ($$r_args{'budget'} ne '' && $$r_args{'openlist'}{$parent}{'zenny'} > $$r_args{'budget'}) {
			#This link is too expensive
			delete $$r_args{'openlist'}{$parent};
			next;
		} else {
			#MOVE this entry into the CLOSELIST
			$$r_args{'closelist'}{$parent}{'walk'}   = $$r_args{'openlist'}{$parent}{'walk'};
			$$r_args{'closelist'}{$parent}{'zenny'}  = $$r_args{'openlist'}{$parent}{'zenny'};
			$$r_args{'closelist'}{$parent}{'parent'} = $$r_args{'openlist'}{$parent}{'parent'};
			#Then delete in from OPENLIST
			delete $$r_args{'openlist'}{$parent};
		}

		if ($portals_lut{$portal}{'dest'}{$dest}{'map'} eq $$r_args{'dest'}{'map'}) {
			if ($$r_args{'dest'}{'pos'}{'x'} eq '' && $$r_args{'dest'}{'pos'}{'y'} eq '') {
				$$r_args{'found'} = $parent;
				$$r_args{'done'} = 1;
				undef @{$$r_args{'mapSolution'}};
				my $this = $$r_args{'found'};
				while ($this) {
					my %arg;
					$arg{'portal'} = $this;
					my ($from,$to) = split /=/, $this;
					($arg{'map'},$arg{'pos'}{'x'},$arg{'pos'}{'y'}) = split / /,$from;
					($arg{dest_map}, $arg{dest_pos}{x}, $arg{dest_pos}{y}) = split(' ', $to);
					$arg{'walk'} = $$r_args{'closelist'}{$this}{'walk'};
					$arg{'zenny'} = $$r_args{'closelist'}{$this}{'zenny'};
					$arg{'steps'} = $portals_lut{$from}{'dest'}{$to}{'steps'};
					unshift @{$$r_args{'mapSolution'}},\%arg;
					$this = $$r_args{'closelist'}{$this}{'parent'};
				}
				return;
			} elsif ( ai_route_getRoute(\@{$$r_args{'solution'}}, $$r_args{'dest'}{'field'}, $portals_lut{$portal}{'dest'}{$dest}, $$r_args{'dest'}{'pos'}) ) {
				my $walk = "$$r_args{'dest'}{'map'} $$r_args{'dest'}{'pos'}{'x'} $$r_args{'dest'}{'pos'}{'y'}=$$r_args{'dest'}{'map'} $$r_args{'dest'}{'pos'}{'x'} $$r_args{'dest'}{'pos'}{'y'}";
				$$r_args{'closelist'}{$walk}{'walk'} = scalar @{$$r_args{'solution'}} + $$r_args{'closelist'}{$parent}{$dest}{'walk'};
				$$r_args{'closelist'}{$walk}{'parent'} = $parent;
				$$r_args{'closelist'}{$walk}{'zenny'} = $$r_args{'closelist'}{$parent}{'zenny'};
				$$r_args{'found'} = $walk;
				$$r_args{'done'} = 1;
				undef @{$$r_args{'mapSolution'}};
				my $this = $$r_args{'found'};
				while ($this) {
					my %arg;
					$arg{'portal'} = $this;
					my ($from,$to) = split /=/, $this;
					($arg{'map'},$arg{'pos'}{'x'},$arg{'pos'}{'y'}) = split / /,$from;
					$arg{'walk'} = $$r_args{'closelist'}{$this}{'walk'};
					$arg{'zenny'} = $$r_args{'closelist'}{$this}{'zenny'};
					$arg{'steps'} = $portals_lut{$from}{'dest'}{$to}{'steps'};
					unshift @{$$r_args{'mapSolution'}},\%arg;
					$this = $$r_args{'closelist'}{$this}{'parent'};
				}
				return;
			}
		}
		#get all children of each openlist
		foreach my $child (keys %{$portals_los{$dest}}) {
			next unless $portals_los{$dest}{$child};
			foreach my $subchild (keys %{$portals_lut{$child}{'dest'}}) {
				my $destID = $subchild;
				my $mapName = $portals_lut{$child}{'source'}{'map'};
				#############################################################
				my $penalty = int($routeWeights{lc($mapName)}) + int(($portals_lut{$child}{'dest'}{$subchild}{'steps'} ne '') ? $routeWeights{'NPC'} : $routeWeights{'PORTAL'});
				my $thisWalk = $penalty + $$r_args{'closelist'}{$parent}{'walk'} + $portals_los{$dest}{$child};
				if (!exists $$r_args{'closelist'}{"$child=$subchild"}) {
					if ( !exists $$r_args{'openlist'}{"$child=$subchild"} || $$r_args{'openlist'}{"$child=$subchild"}{'walk'} > $thisWalk ) {
						$$r_args{'openlist'}{"$child=$subchild"}{'parent'} = $parent;
						$$r_args{'openlist'}{"$child=$subchild"}{'walk'} = $thisWalk;
						$$r_args{'openlist'}{"$child=$subchild"}{'zenny'} = $$r_args{'closelist'}{$parent}{'zenny'} + $portals_lut{$child}{'dest'}{$subchild}{'cost'};
					}
				}
			}
		}
	}
}

sub ai_items_take {
	my ($x1, $y1, $x2, $y2) = @_;
	my %args;
	$args{pos}{x} = $x1;
	$args{pos}{y} = $y1;
	$args{pos_to}{x} = $x2;
	$args{pos_to}{y} = $y2;
	$args{ai_items_take_end}{time} = time;
	$args{ai_items_take_end}{timeout} = $timeout{ai_items_take_end}{timeout};
	$args{ai_items_take_start}{time} = time;
	$args{ai_items_take_start}{timeout} = $timeout{ai_items_take_start}{timeout};
	AI::queue("items_take", \%args);
}

sub ai_route {
	my $map = shift;
	my $x = shift;
	my $y = shift;
	my %param = @_;
	debug "On route to: $maps_lut{$map.'.rsw'}($map): $x, $y\n", "route";

	my %args;
	$x = int($x) if ($x ne "");
	$y = int($y) if ($y ne "");
	$args{'dest'}{'map'} = $map;
	$args{'dest'}{'pos'}{'x'} = $x;
	$args{'dest'}{'pos'}{'y'} = $y;
	$args{'maxRouteDistance'} = $param{maxRouteDistance} if exists $param{maxRouteDistance};
	$args{'maxRouteTime'} = $param{maxRouteTime} if exists $param{maxRouteTime};
	$args{'attackOnRoute'} = $param{attackOnRoute} if exists $param{attackOnRoute};
	$args{'distFromGoal'} = $param{distFromGoal} if exists $param{distFromGoal};
	$args{'pyDistFromGoal'} = $param{pyDistFromGoal} if exists $param{pyDistFromGoal};
	$args{'attackID'} = $param{attackID} if exists $param{attackID};
	$args{'noSitAuto'} = $param{noSitAuto} if exists $param{noSitAuto};
	$args{'noAvoidWalls'} = $param{noAvoidWalls} if exists $param{noAvoidWalls};
	$args{notifyUponArrival} = $param{notifyUponArrival} if exists $param{notifyUponArrival};
	$args{'tags'} = $param{tags} if exists $param{tags};
	$args{'time_start'} = time;

	if (!$param{'_internal'}) {
		$args{'solution'} = [];
		$args{'mapSolution'} = [];
	} elsif (exists $param{'_solution'}) {
		$args{'solution'} = $param{'_solution'};
	}

	# Destination is same map and isn't blocked by walls/water/whatever
	my $pos = calcPosition($char);
	if ($param{'_internal'} || ($field{'name'} eq $args{'dest'}{'map'} && ai_route_getRoute(\@{$args{solution}}, \%field, $pos, $args{dest}{pos}, $args{noAvoidWalls}))) {
		# Since the solution array is here, we can start in "Route Solution Ready"
		$args{'stage'} = 'Route Solution Ready';
		debug "Route Solution Ready\n", "route";
		AI::queue("route", \%args);
		return 1;
	} else {
		return 0 if ($param{noMapRoute});
		# Nothing is initialized so we start scratch
		AI::queue("mapRoute", \%args);
		return 1;
	}
}

##
# ai_route_getRoute(returnArray, r_field, r_start, r_dest, [noAvoidWalls])
# returnArray: reference to an array. The solution will be stored in here.
# r_field: reference to a field hash (usually \%field).
# r_start: reference to a hash. This is the start coordinate.
# r_dest: reference to a hash. This is the destination coordinate.
# noAvoidWalls: 1 if you don't want to avoid walls on route.
# Returns: 1 if the calculation succeeded, 0 if not.
#
# Calculates how to walk from $r_start to $r_dest.
# The blocks you have to walk on in order to get to $r_dest are stored in
# $returnArray. This function is a convenience wrapper function for the stuff
# in PathFinding.pm
sub ai_route_getRoute {
	my ($returnArray, $r_field, $r_start, $r_dest, $noAvoidWalls) = @_;
	undef @{$returnArray};
	return 1 if ($r_dest->{x} eq '' || $r_dest->{y} eq '');

	# The exact destination may not be a spot that we can walk on.
	# So we find a nearby spot that is walkable.
	my %start = %{$r_start};
	my %dest = %{$r_dest};
	Misc::closestWalkableSpot($r_field, \%start);
	Misc::closestWalkableSpot($r_field, \%dest);

	# Generate map weights (for wall avoidance)
	my $weights;
	if ($noAvoidWalls) {
		$weights = chr(255) . (chr(1) x 255);
	} else {
		$weights = join '', map chr $_, (255, 8, 7, 6, 5, 4, 3, 2, 1);
		$weights .= chr(1) x (256 - length($weights));
	}

	# Calculate path
	my $pathfinding = new PathFinding(
		start => \%start,
		dest => \%dest,
		field => $r_field,
		weights => $weights
	);
	return undef if !$pathfinding;

	my $ret = $pathfinding->run($returnArray);
	if ($ret <= 0) {
		# Failure
		return undef;
	} else {
		# Success
		return $ret;
	}
}

#sellAuto for items_control - chobit andy 20030210
sub ai_sellAutoCheck {
	for (my $i = 0; $i < @{$char->{inventory}}; $i++) {
		next if (!$char->{inventory}[$i] || !%{$char->{inventory}[$i]} || $char->{inventory}[$i]{equipped});
		my $sell = $items_control{'all'}{'sell'};
		$sell = $items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})}{'sell'} if ($items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})});
		my $keep = $items_control{'all'}{'keep'};
		$keep = $items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})}{'keep'} if ($items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})});
		if ($sell && $chars[$config{'char'}]{'inventory'}[$i]{'amount'} > $keep) {
			return 1;
		}
	}
}

sub ai_setMapChanged {
	my $index = shift;
	$index = 0 if ($index eq "");
	if ($index < @ai_seq_args) {
		$ai_seq_args[$index]{'mapChanged'} = time;
	}
}

sub ai_setSuspend {
	my $index = shift;
	$index = 0 if ($index eq "");
	if ($index < @ai_seq_args) {
		$ai_seq_args[$index]{'suspended'} = time;
	}
}

sub ai_skillUse {
	return if ($char->{muted});
	my %args = (
		skillHandle => shift,
		lv => shift,
		maxCastTime => { time => time, timeout => shift },
		minCastTime => { time => time, timeout => shift },
		target => shift,
		y => shift,
		tag => shift,
		ret => shift,
		waitBeforeUse => { time => time, timeout => shift },
		prefix => shift
	);
	$args{giveup}{time} = time;
	$args{giveup}{timeout} = $timeout{ai_skill_use_giveup}{timeout};

	if ($args{y} ne "") {
		$args{x} = $args{target};
		delete $args{target};
	}
	AI::queue("skill_use", \%args);
}

##
# ai_skillUse2($skill, $lvl, $maxCastTime, $minCastTime, $target)
#
# Calls ai_skillUse(), resolving $target to ($x, $y) if $skillID is an
# area skill.
#
# FIXME: All code of the following structure:
#
# if (!ai_getSkillUseType(...)) {
#     ai_skillUse(..., $ID);
# } else {
#     ai_skillUse(..., $x, $y);
# }
#
# should be converted to use this helper function. Note that this
# function uses objects instead of IDs for the skill and target.
sub ai_skillUse2 {
	my ($skill, $lvl, $maxCastTime, $minCastTime, $target, $prefix) = @_;

	if (!ai_getSkillUseType($skill->handle)) {
		ai_skillUse($skill->handle, $lvl, $maxCastTime, $minCastTime, $target->{ID}, undef, undef, undef, undef, $prefix);
	} else {
		ai_skillUse($skill->handle, $lvl, $maxCastTime, $minCastTime, $target->{pos_to}{x}, $target->{pos_to}{y}, undef, undef, undef, $prefix);
	}
}

##
# ai_storageAutoCheck()
#
# Returns 1 if it is time to perform storageAuto sequence.
# Returns 0 otherwise.
sub ai_storageAutoCheck {
	return 0 if ($char->{skills}{NV_BASIC}{lv} < 6);
	for (my $i = 0; $i < @{$char->{inventory}}; $i++) {
		my $slot = $char->{inventory}[$i];
		next if (!$slot || $slot->{equipped});
		my $store = $items_control{'all'}{'storage'};
		$store = $items_control{lc($slot->{name})}{'storage'} if ($items_control{lc($slot->{name})});
		my $keep = $items_control{'all'}{'keep'};
		$keep = $items_control{lc($slot->{name})}{'keep'} if ($items_control{lc($slot->{name})});
		if ($store && $slot->{amount} > $keep) {
			return 1;
		}
	}
	return 0;
}

##
# ai_waypoint(points, [whenDone, attackOnRoute])
# points: reference to an array containing waypoint information. FileParsers::parseWaypoint() creates such an array.
# whenDone: specifies what to do when the waypoint has finished. Possible values are: 'repeat' (repeat waypoint) or 'reverse' (repeat waypoint, but in opposite direction).
# attackOnRoute: 0 (or not given) if you don't want to attack anything while walking, 1 if you want to attack aggressives, and 2 if you want to attack all monsters.
#
# Initialize a waypoint.
sub ai_waypoint {
	my %args = (
		points => shift,
		index => 0,
		inc => 1,
		whenDone => shift,
		attackOnRoute => shift
	);

	if ($args{whenDone} && $args{whenDone} ne "repeat" && $args{whenDone} ne "reverse") {
		error "Unknown waypoint argument: $args{whenDone}\n";
		return;
	}
	AI::queue("waypoint", \%args);
}




##
# cartGet(items)
# items: a reference to an array of indices.
#
# Get one or more items from cart.
# \@items is a list of hashes; each has must have an "index" key, and may optionally have an "amount" key.
# "index" is the index of the cart inventory item number. If "amount" is given, only the given amount of
# items will retrieved from cart.
#
# Example:
# # You want to get 5 Apples (inventory item 2) and all
# # Fly Wings (inventory item 5) from cart.
# my @items;
# push @items, {index => 2, amount => 5};
# push @items, {index => 5};
# cartGet(\@items);
sub cartGet {
	my $items = shift;
	return unless ($items && @{$items});

	my %args;
	$args{items} = $items;
	$args{timeout} = $timeout{ai_cartAuto} ? $timeout{ai_cartAuto}{timeout} : 0.15;
	AI::queue("cartGet", \%args);
}

##
# cartAdd(items)
# items: a reference to an array of hashes.
#
# Put one or more items in cart.
# \@items is a list of hashes; each has must have an "index" key, and may optionally have an "amount" key.
# "index" is the index of the inventory item number. If "amount" is given, only the given amount of items will be put in cart.
#
# Example:
# # You want to add 5 Apples (inventory item 2) and all
# # Fly Wings (inventory item 5) to cart.
# my @items;
# push @items, {index => 2, amount => 5};
# push @items, {index => 5};
# cartAdd(\@items);
sub cartAdd {
	my $items = shift;
	return unless ($items && @{$items});

	my %args;
	$args{items} = $items;
	$args{timeout} = $timeout{ai_cartAuto} ? $timeout{ai_cartAuto}{timeout} : 0.15;
	AI::queue("cartAdd", \%args);
}

##
# ai_talkNPC(x, y, sequence)
# x, y: the position of the NPC to talk to.
# sequence: A string containing the NPC talk sequences.
#
# Talks to an NPC. You can specify an NPC position, or an NPC ID.
#
# $sequence is a list of whitespace-separated commands:
# ~l
# c       : Continue
# r#      : Select option # from menu.
# n       : Stop talking to NPC.
# b       : Send the "Show shop item list" (Buy) packet.
# w#      : Wait # seconds.
# x       : Initialize conversation with NPC. Useful to perform multiple transaction with a single NPC.
# t="str" : send the text str to NPC, double quote is needed only if the string contains space
# ~l~
#
# Example:
# # Sends "Continue", "Select option 0" to the NPC at (102, 300)
# ai_talkNPC(102, 300, "c r0");
sub ai_talkNPC {
	my %args;
	$args{'pos'}{'x'} = shift;
	$args{'pos'}{'y'} = shift;
	$args{'sequence'} = shift;
	$args{'sequence'} =~ s/^ +| +$//g;
	AI::queue("NPC", \%args);
}

sub attack {
	my $ID = shift;
	my $priorityAttack = shift;
	my %args;

	my $target = Actor::get($ID);

	$args{'ai_attack_giveup'}{'time'} = time;
	$args{'ai_attack_giveup'}{'timeout'} = $timeout{'ai_attack_giveup'}{'timeout'};
	$args{'ID'} = $ID;
	$args{'unstuck'}{'timeout'} = ($timeout{'ai_attack_unstuck'}{'timeout'} || 1.5);
	%{$args{'pos_to'}} = %{$target->{'pos_to'}};
	%{$args{'pos'}} = %{$target->{'pos'}};
	AI::queue("attack", \%args);

	if ($priorityAttack) {
		message "Priority Attacking: $target\n";
	} else {
		message "Attacking: $target\n";
	}

	$startedattack = 1;

	Plugins::callHook('attack_start', {ID => $ID});

	#Mod Start
	AUTOEQUIP: {
		last AUTOEQUIP if ($target->{type} eq 'Player');

		my $i = 0;
		my ($Rdef,$Ldef,$Req,$Leq,$arrow,$j);
		while (exists $config{"autoSwitch_$i"}) {
			if (!$config{"autoSwitch_$i"}) {
				$i++;
				next;
			}

			if (existsInList($config{"autoSwitch_$i"}, $monsters{$ID}{'name'})) {
				message "Encounter Monster : ".$monsters{$ID}{'name'}."\n";

				$Req = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"autoSwitch_$i"."_rightHand"}) if ($config{"autoSwitch_$i"."_rightHand"});
				$Leq = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"autoSwitch_$i"."_leftHand"}) if ($config{"autoSwitch_$i"."_leftHand"});
				$arrow = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"autoSwitch_$i"."_arrow"}) if ($config{"autoSwitch_$i"."_arrow"});

				if ($Leq ne "" && !$chars[$config{'char'}]{'inventory'}[$Leq]{'equipped'}) {
					$Ldef = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "equipped",32);
					sendUnequip(\$remote_socket,$chars[$config{'char'}]{'inventory'}[$Ldef]{'index'}) if($Ldef ne "");
					message "Auto Equiping [L] :".$config{"autoSwitch_$i"."_leftHand"}." ($Leq)\n", "equip";
					$chars[$config{'char'}]{'inventory'}[$Leq]->equip();
				}
				if ($Req ne "" && !$chars[$config{'char'}]{'inventory'}[$Req]{'equipped'} || $config{"autoSwitch_$i"."_rightHand"} eq "[NONE]") {
					$Rdef = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "equipped",34);
					$Rdef = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "equipped",2) if($Rdef eq "");
					#Debug for 2hand Quicken and Bare Hand attack with 2hand weapon
					if((!main::whenStatusActive("Twohand Quicken, Adrenaline, Spear Quicken") || $config{"autoSwitch_$i"."_rightHand"} eq "[NONE]") && $Rdef ne ""){
						sendUnequip(\$remote_socket,$chars[$config{'char'}]{'inventory'}[$Rdef]{'index'});
					}
					if ($Req eq $Leq) {
						for ($j=0; $j < @{$chars[$config{'char'}]{'inventory'}};$j++) {
							next if (!$char->{inventory}[$j] || !%{$char->{inventory}[$j]});
							if ($chars[$config{'char'}]{'inventory'}[$j]{'name'} eq $config{"autoSwitch_$i"."_rightHand"} && $j != $Leq) {
								$Req = $j;
								last;
							}
						}
					}
					if ($config{"autoSwitch_$i"."_rightHand"} ne "[NONE]") {
						message "Auto Equiping [R] :".$config{"autoSwitch_$i"."_rightHand"}."\n", "equip";
						$chars[$config{'char'}]{'inventory'}[$Req]->equip();
					}
				}
				if ($arrow ne "" && !$chars[$config{'char'}]{'inventory'}[$arrow]{'equipped'}) {
					message "Auto Equiping [A] :".$config{"autoSwitch_$i"."_arrow"}."\n", "equip";
					$chars[$config{'char'}]{'inventory'}[$arrow]->equip();
				}
				if ($config{"autoSwitch_$i"."_distance"} && $config{"autoSwitch_$i"."_distance"} != $config{'attackDistance'}) {
					$ai_v{'attackDistance'} = $config{'attackDistance'};
					$config{'attackDistance'} = $config{"autoSwitch_$i"."_distance"};
					message "Change Attack Distance to : ".$config{'attackDistance'}."\n", "equip";
				}
				if ($config{"autoSwitch_$i"."_useWeapon"} ne "") {
					$ai_v{'attackUseWeapon'} = $config{'attackUseWeapon'};
					$config{'attackUseWeapon'} = $config{"autoSwitch_$i"."_useWeapon"};
					message "Change Attack useWeapon to : ".$config{'attackUseWeapon'}."\n", "equip";
				}
				last AUTOEQUIP;
			}
			$i++;
		}
		if ($config{'autoSwitch_default_leftHand'}) {
			$Leq = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{'autoSwitch_default_leftHand'});
			if($Leq ne "" && !$chars[$config{'char'}]{'inventory'}[$Leq]{'equipped'}) {
				$Ldef = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "equipped",32);
				sendUnequip(\$remote_socket,$chars[$config{'char'}]{'inventory'}[$Ldef]{'index'}) if($Ldef ne "" && $chars[$config{'char'}]{'inventory'}[$Ldef]{'equipped'});
				message "Auto equiping default [L] :".$config{'autoSwitch_default_leftHand'}."\n", "equip";
				$chars[$config{'char'}]{'inventory'}[$Leq]->equip();
			}
		}
		if ($config{'autoSwitch_default_rightHand'}) {
			$Req = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{'autoSwitch_default_rightHand'});
			if($Req ne "" && !$chars[$config{'char'}]{'inventory'}[$Req]{'equipped'}) {
				$Rdef = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "equipped",2);
				sendUnequip(\$remote_socket,$chars[$config{'char'}]{'inventory'}[$Rdef]{'index'}) if($Rdef ne "" && $chars[$config{'char'}]{'inventory'}[$Rdef]{'equipped'});
				message "Auto equiping default [R] :".$config{'autoSwitch_default_rightHand'}." (unequip $Rdef)\n", "equip";
				$chars[$config{'char'}]{'inventory'}[$Req]->equip();
			}
		}
		if ($config{'autoSwitch_default_arrow'}) {
			$arrow = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{'autoSwitch_default_arrow'});
			if($arrow ne "" && !$chars[$config{'char'}]{'inventory'}[$arrow]{'equipped'}) {
				message "Auto equiping default [A] :".$config{'autoSwitch_default_arrow'}."\n", "equip";
				$chars[$config{'char'}]{'inventory'}[$arrow]->equip();
			}
		}
		if ($ai_v{'attackDistance'} && $config{'attackDistance'} != $ai_v{'attackDistance'}) {
			$config{'attackDistance'} = $ai_v{'attackDistance'};
			message "Change Attack Distance to Default : ".$config{'attackDistance'}."\n", "equip";
		}
		if ($ai_v{'attackUseWeapon'} ne "" && $config{'attackUseWeapon'} != $ai_v{'attackUseWeapon'}) {
			$config{'attackUseWeapon'} = $ai_v{'attackUseWeapon'};
			message "Change Attack useWeapon to default : ".$config{'attackUseWeapon'}."\n", "equip";
		}
	} #END OF BLOCK AUTOEQUIP
}

sub gather {
	my $ID = shift;
	my %args;
	$args{ai_items_gather_giveup}{time} = time;
	$args{ai_items_gather_giveup}{timeout} = $timeout{ai_items_gather_giveup}{timeout};
	$args{ID} = $ID;
	$args{pos} = { %{$items{$ID}{pos}} };
	AI::queue("items_gather", \%args);
	debug "Targeting for Gather: $items{$ID}{name} ($items{$ID}{binID})\n";
}

sub move {
	my $x = shift;
	my $y = shift;
	my $attackID = shift;
	my %args;
	my $dist;
	$args{move_to}{x} = $x;
	$args{move_to}{y} = $y;
	$args{attackID} = $attackID;
	$args{time_move} = $char->{time_move};
	$dist = distance($char->{pos}, $args{move_to});
	$args{ai_move_giveup}{timeout} = $timeout{ai_move_giveup}{timeout};

	debug sprintf("Sending move from (%d,%d) to (%d,%d) - distance %.2f\n",
		$char->{pos}{x}, $char->{pos}{y}, $x, $y, $dist), "ai_move";
	AI::queue("move", \%args);
}

sub sit {
	$timeout{ai_sit_wait}{time} = time;
	$timeout{ai_sit}{time} = time;

	AI::clear("sitting", "standing");
	if ($char->{skills}{NV_BASIC}{lv} >= 3) {
		AI::queue("sitting");
		sendSit(\$remote_socket);
		Misc::look($config{sitAuto_look}) if (defined $config{sitAuto_look});
	}
}

sub stand {
	$timeout{ai_stand_wait}{time} = time;
	$timeout{ai_sit}{time} = time;

	AI::clear("sitting", "standing");
	if ($char->{skills}{NV_BASIC}{lv} >= 3) {
		sendStand(\$remote_socket);
		AI::queue("standing");
	}
}

sub take {
	my $ID = shift;
	my %args;
	$args{ai_take_giveup}{time} = time;
	$args{ai_take_giveup}{timeout} = $timeout{ai_take_giveup}{timeout};
	$args{ID} = $ID;
	%{$args{pos}} = %{$items{$ID}{pos}};
	AI::queue("take", \%args);
	debug "Picking up: $items{$ID}{name} ($items{$ID}{binID})\n";
}

return 1;

