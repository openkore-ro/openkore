#########################################################################
#  OpenKore - Utility Functions
#
#  Copyright (c) 2004,2005 OpenKore Development Team
#
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#########################################################################
##
# MODULE DESCRIPTION: Utility functions
#
# This module contains various general-purpose and independant utility
# functions. Functions in this module should have <b>no</b> dependancies
# on other Kore modules.

package Utils;

use strict;
use Time::HiRes qw(time usleep);
use IO::Socket::INET;
use Math::Trig;
use bytes;
use Exporter;
use base qw(Exporter);
use Config;
use FastUtils;
use Globals qw(%config);
# Do not use any other Kore modules here. It will create circular dependancies.

our @EXPORT = (
	# Hash/array management
	qw(binAdd binFind binFindReverse binRemove binRemoveAndShift binRemoveAndShiftByIndex binSize
	compactArray existsInList findIndex findIndexString findIndexString_lc findIndexString_lc_not_equip
	findIndexStringList_lc findKey findKeyString hashCopyByKey minHeapAdd shuffleArray),
	# Math
	qw(calcPosition checkMovementDirection distance getVector moveAlongVector normalize vectorToDegree max min),
	# OS-specific
	qw(checkLaunchedApp launchApp launchScript),
	# Other stuff
	qw(dataWaiting dumpHash formatNumber getCoordString getFormattedDate getHex giveHex getRange getTickCount
	inRange judgeSkillArea makeCoords makeCoords2 makeDistMap makeIP parseArgs swrite timeConvert timeOut
	vocalString)
	);


# use SelfLoader; 1;
# __DATA__


#######################################
#######################################
### CATEGORY: Hash/array management
#######################################
#######################################


##
# binAdd(r_array, ID)
# r_array: a reference to an array.
# ID: the element to add to @r_array.
# Returns: the index of the element inside @r_array.
#
# Add $ID to the first empty slot in @r_array, or append it to
# the end of @r_array if there are no empty slots.
#
# Example:
# @list = ("ID1", undef, "ID2");
# binAdd(\@list, "New");   # --> Returns: 1
# # Result:
# # $list[0] eq "ID1"
# # $list[1] eq "New"
# # $list[2] eq "ID2"
#
# @list = ("ID1", "ID2");
# binAdd(\@list, "New");   # --> Returns: 2
# # Result:
# # $list[0] eq "ID1"
# # $list[1] eq "ID2"
# # $list[2] eq "New"
sub binAdd {
	my $r_array = shift;
	my $ID = shift;
	my $i;
	for ($i = 0; $i <= @{$r_array};$i++) {
		if ($$r_array[$i] eq "") {
			$$r_array[$i] = $ID;
			return $i;
		}
	}
}

##
# binFind(r_array, ID)
# r_array: a reference to an array.
# ID: the element to search for.
# Returns: the index of the element for $ID, or undef is $ID
#          is not an element in @r_array.
#
# Look for element $ID in @r_array.
#
# Example:
# our @array = ("hello", "world", "!");
# binFind(\@array, "world");   # => 1
# binFind(\@array, "?");       # => undef

# This function is written in tools/misc/fastutils.xs

##
# binFindReverse(r_array, ID)
#
# Same as binFind() but starts looking from the end of the array
# instead of from the beginning.
sub binFindReverse {
	my $r_array = shift;
	my $ID = shift;
	my $i;
	for ($i = @{$r_array} - 1; $i >= 0;$i--) {
		if ($$r_array[$i] eq $ID) {
			return $i;
		}
	}
}

##
# binRemove(r_array, ID)
# r_array: a reference to an array
# ID: the element to remove.
#
# Find a value in @r_array which has the same value as $ID,
# and remove it.
#
# Example:
# our @array = ("hello", "world", "!");
# # Same as: delete $array[1];
# binRemove(\@array, "world");
sub binRemove {
	my $r_array = shift;
	my $ID = shift;
	my $i;
	for ($i = 0; $i < @{$r_array};$i++) {
		if ($$r_array[$i] eq $ID) {
			delete $$r_array[$i];
			last;
		}
	}
}

sub binRemoveAndShift {
	my $r_array = shift;
	my $ID = shift;
	my $found;
	my $i;
	my @newArray;
	for ($i = 0; $i < @{$r_array};$i++) {
		if ($$r_array[$i] ne $ID || $found ne "") {
			push @newArray, $$r_array[$i];
		} else {
			$found = $i;
		}
	}
	@{$r_array} = @newArray;
	return $found;
}

sub binRemoveAndShiftByIndex {
	my $r_array = shift;
	my $index = shift;
	my $found;
	my $i;
	my @newArray;
	for ($i = 0; $i < @{$r_array};$i++) {
		if ($i != $index) {
			push @newArray, $$r_array[$i];
		} else {
			$found = 1;
		}
	}
	@{$r_array} = @newArray;
	return $found;
}

##
# binSize(r_array)
# r_array: a reference to an array.
# Returns: a number.
#
# Calculates the size of @r_array, excluding undefined values.
#
# Example:
# our @array = ("hello", undef, "world");
# scalar @array;        # -> 3
# binSize(\@array);     # -> 2
sub binSize {
	my $r_array = shift;
	return 0 if !defined $r_array;

	my $found = 0;
	my $i;
	for ($i = 0; $i < @{$r_array};$i++) {
		if ($$r_array[$i] ne "") {
			$found++;
		}
	}
	return $found;
}

##
# compactArray(r_array)
#
# Resize an array by removing undefined items.
sub compactArray {
	my ($array) = @_;
	my @new;

	foreach my $item (@{$array}) {
		push @new, $item if (defined $item);
	}
	@{$array} = @new;
}

##
# existsInList(list, val)
# list: a string containing a list of comma-seperated items.
# val: the value to check for.
#
# Check whether $val exists in $list. This function is case-insensitive.
#
# Example:
# my $list = "Apple,Orange Juice";
# existsInList($list, "apple");		# => 1
# existsInList($list, "Orange Juice");	# => 1
# existsInList($list, "juice");		# => 0
sub existsInList {
	my ($list, $val) = @_;
	return 0 if ($val eq "");
	my @array = split / *, */, $list;
	$val = lc($val);
	foreach (@array) {
		s/^\s+//;
		s/\s+$//;
		s/\s+/ /g;
		next if ($_ eq "");
		return 1 if (lc($_) eq $val);
	}
	return 0;
}


##
# findIndex(r_array, key, [num])
# r_array: A reference to an array, which contains a hash in each element.
# key: The name of the key to lookup.
# num: The number to compare with.
# Returns: The index in r_array of the found item, or undef if not found. Or, if not found and $num is not given: returns the index of first undefined array element, or the index of the last array element + 1.
#
# This function loops through the entire array, looking for a hash item whose
# value equals $num.
#
# Example:
# my @inventory;
# $inventory[0]{amount} = 50;
# $inventory[1]{amount} = 100;
# $inventory[2] = undef;
# $inventory[3]{amount} = 200;
# findIndex(\@inventory, "amount", 100);    # 1
# findIndex(\@inventory, "amount", 99);     # undef
# findIndex(\@inventory, "amount");         # 2
#
# @inventory = ();
# $inventory[0]{amount} = 50;
# findIndex(\@inventory, "amount");         # 1
sub findIndex {
	my $r_array = shift;
	return undef if !$r_array;
	my $key = shift;
	my $num = shift;

	if ($num ne "") {
		my $max = @{$r_array};
		for (my $i = 0; $i < $max; $i++) {
			return $i if ($r_array->[$i]{$key} == $num);
		}
		return undef;
	} else {
		my $max = @{$r_array};
		my $i;
		for ($i = 0; $i < $max; $i++) {
			return $i if (!$r_array->[$i] || !keys(%{$r_array->[$i]}));
		}
		return $i;
	}
}


##
# findIndexString(r_array, key, [str])
#
# Same as findIndex(), except this function compares strings, not numbers.
sub findIndexString {
	my $r_array = shift;
	return undef if !$r_array;
	my $key = shift;
	my $str = shift;

	if ($str ne "") {
		my $max = @{$r_array};
		for (my $i = 0; $i < $max; $i++) {
			if ($r_array->[$i]{$key} eq $str) {
				return $i;
			}
		}
		return undef;
	} else {
		my $max = @{$r_array};
		my $i;
		for ($i = 0; $i < $max; $i++) {
			return $i if (!$r_array->[$i] || !keys(%{$r_array->[$i]}));
		}
		return $i;
	}
}


##
# findIndexString_lc(r_array, key, [str])
#
# Same has findIndexString(), except this function does case-insensitive string comparisons.
sub findIndexString_lc {
	my $r_array = shift;
	return undef if !$r_array;
	my $key = shift;
	my $str = shift;

	if ($str ne "") {
		$str = lc $str;
		my $max = @{$r_array};
		for (my $i = 0; $i < $max; $i++) {
			return $i if (lc $r_array->[$i]{$key} eq $str);
		}
		return undef;
	} else {
		my $max = @{$r_array};
		my $i;
		for ($i = 0; $i < $max; $i++) {
			return $i if (!$r_array->[$i] || !keys(%{$r_array->[$i]}));
		}
		return $i;
	}
}

our %findIndexStringList_lc_cache;

sub findIndexStringList_lc {
	my $r_array = shift;
	return undef if !defined $r_array;
	my $match = shift;
	my $ID = shift;
	my $skipID = shift;

	my $max = @{$r_array};
	my ($i, $arr);
	if (exists $findIndexStringList_lc_cache{$ID}) {
		$arr = $findIndexStringList_lc_cache{$ID};
	} else {
		my @tmp = split / *, */, lc($ID);
		$arr = \@tmp;
		%findIndexStringList_lc_cache = () if (scalar(keys %findIndexStringList_lc_cache) > 30);
		$findIndexStringList_lc_cache{$ID} = $arr;
	}

	foreach (@{$arr}) {
		for ($i = 0; $i < $max; $i++) {
			next if $i eq $skipID;
			if (lc($r_array->[$i]{$match}) eq $_) {
				return $i;
			}
		}
	}
	if ($ID eq "") {
		return $i;
	} else {
		return undef;
	}
}

##
# findIndexString_lc_not_equip(r_array, key, [str])
#
# Same has findIndexString(), except this function does case-insensitive string comparisons.
# It only finds items which are not equipped AND are able to be equipped (identified).
sub findIndexString_lc_not_equip {
	my $r_array = shift;
	return undef if !defined $r_array;
	my $match = shift;
	my $ID = lc(shift);
	my $i;
	for ($i = 0; $i < @{$r_array} ;$i++) {
		if ((lc($$r_array[$i]{$match}) eq $ID && ($$r_array[$i]{'identified'}) && !($$r_array[$i]{'equipped'}))
			 || (!$$r_array[$i] && $ID eq "")) {
			return $i;
		}
	}
	if ($ID eq "") {
		return $i;
	} else {
		return undef;
	}
}

sub findKey {
	my $r_hash = shift;
	my $match = shift;
	my $ID = shift;
	foreach (keys %{$r_hash}) {
		if ($r_hash->{$_}{$match} == $ID) {
			return $_;
		}
	}
}

sub findKeyString {
	my $r_hash = shift;
	my $match = shift;
	my $ID = shift;
	foreach (keys %{$r_hash}) {
		if (ref($r_hash->{$_}) && $r_hash->{$_}{$match} eq $ID) {
			return $_;
		}
	}
}

##
# hashCopyByKey(target source keys)
#
# Copies each key from the target to the source.
#
# Example: hashCopyByKey(\%target,\%source,qw(some keys);
# would copy 'some' and 'keys' from the source hash to the
# target hash
#
sub hashCopyByKey {
  my ($target, $source, @keys) = @_;
  foreach (@keys){
    $target->{$_} = $source->{$_} if exists $source->{$_};
  }
}

sub minHeapAdd {
	my $r_array = shift;
	my $r_hash = shift;
	my $match = shift;
	my $i;
	my $found;
	my @newArray;
	for ($i = 0; $i < @{$r_array};$i++) {
		if (!$found && $$r_hash{$match} < $$r_array[$i]{$match}) {
			push @newArray, $r_hash;
			$found = 1;
		}
		push @newArray, $$r_array[$i];
	}
	if (!$found) {
		push @newArray, $r_hash;
	}
	@{$r_array} = @newArray;
}

##
# shuffleArray(r_array)
# r_array: A reference to an array.
#
# This function randomizes the order of the items in the array.
sub shuffleArray {
	my $r_array = shift;
	my $i = @{$r_array};
	my $j;
        while ($i--) {
               $j = int rand ($i+1);
               @$r_array[$i,$j] = @$r_array[$j,$i];
        }
}


################################
################################
### CATEGORY: Math
################################
################################


##
# calcPosition(object, [extra_time, float])
# object: $char (yourself), or a value in %monsters or %players.
# float: If set to 1, return coordinates as floating point.
# Returns: reference to a position hash.
#
# The position information server that the server sends indicates a motion:
# it says that an object is walking from A to B, and that it will arrive at B shortly.
# This function calculates the current position of $object based on the motion information.
#
# If $extra_time is given, this function will calculate where $object will be
# after $extra_time seconds.
#
# Example:
# my $pos;
# $pos = calcPosition($char);
# print "You are currently at: $pos->{x}, $pos->{y}\n";
#
# $pos = calcPosition($monsters{$ID});
# # Calculate where the player will be after 2 seconds
# $pos = calcPosition($players{$ID}, 2);
sub calcPosition {
	my ($object, $extra_time, $float) = @_;
	my $time_needed = $object->{time_move_calc};
	my $elasped = time - $object->{time_move} + $extra_time;

	if ($elasped >= $time_needed || !$time_needed) {
		return $object->{pos_to};
	} else {
		my (%vec, %result, $dist);
		my $pos = $object->{pos};
		my $pos_to = $object->{pos_to};

		getVector(\%vec, $pos_to, $pos);
		$dist = (distance($pos, $pos_to) - 1) * ($elasped / $time_needed);
		moveAlongVector(\%result, $pos, \%vec, $dist);
		$result{x} = int sprintf("%.0f", $result{x}) if (!$float);
		$result{y} = int sprintf("%.0f", $result{y}) if (!$float);
		return \%result;
	}
}

##
# checkMovementDirection(pos1, vec, pos2, fuzziness)
#
# Check whether an object - which is moving into the direction of vector $vec,
# and is currently at position $pos1 - is moving towards $pos2.
#
# Example:
# # Get monster movement direction
# my %vec;
# getVector(\%vec, $monster->{pos_to}, $monster->{pos});
# if (checkMovementDirection($monster->{pos}, \%vec, $char->{pos}, 15)) {
# 	warning "Monster $monster->{name} is moving towards you\n";
#}
sub checkMovementDirection {
	my ($pos1, $vec, $pos2, $fuzziness) = @_;
	my %objVec;
	getVector(\%objVec, $pos2, $pos1);

	my $movementDegree = vectorToDegree($vec);
	my $obj1ToObj2Degree = vectorToDegree(\%objVec);
	return abs($obj1ToObj2Degree - $movementDegree) <= $fuzziness ||
		(($obj1ToObj2Degree - $movementDegree) % 360) <= $fuzziness;
}

##
# distance(r_hash1, r_hash2)
# pos1, pos2: references to position hash tables.
# Returns: the distance as integer, in blocks.
#
# Calculates the number of steps (NOT pythagorean distance, which RO
# doesn't go by; see
# http://openkore.sourceforge.net/forum/viewtopic.php?t=9176) between
# ($pos1->{x}, $pos1->{y}) and ($pos2->{x}, $pos2->{y}).
#
# Example:
# # Calculates the distance between you and a monster
# my $dist = distance($char->{pos_to},
#                     $monsters{$ID}{pos_to});
sub distance {
    my $pos1 = shift;
    my $pos2 = shift;
    return 0 if (!$pos1 && !$pos2);
    
    my %line;
    if (defined $pos2) {
        $line{x} = abs($pos1->{x} - $pos2->{x});
        $line{y} = abs($pos1->{y} - $pos2->{y});
    } else {
        %line = %{$pos1};
    }
    return sqrt($line{x} ** 2 + $line{y} ** 2);
}

##
# getVector(r_store, to, from)
# r_store: reference to a hash. The result will be stored here.
# to, from: reference to position hashes.
#
# Create a vector object. For those who don't know: a vector
# is a mathematical term for describing a movement and its direction.
# So this function creates a vector object, which describes the direction of the
# movement %from to %to. You can use this vector object with other math functions.
#
# See also: moveAlongVector(), vectorToDegree()
sub getVector {
	my $r_store = shift;
	my $to = shift;
	my $from = shift;
	$r_store->{x} = $to->{x} - $from->{x};
	$r_store->{y} = $to->{y} - $from->{y};
}

##
# moveAlongVector(result, r_pos, r_vec, dist)
# result: reference to a hash, in which the destination position is stored.
# r_pos: the source position.
# r_vec: a vector object, as created by getVector()
# dist: the distance to move from the source position.
#
# Calculate where you will end up to, if you walk $dist blocks from %r_pos
# into the direction specified by %r_vec.
#
# See also: getVector()
#
# Example:
# my %from = (x => 100, y => 100);
# my %to = (x => 120, y => 120);
# my %vec;
# getVector(\%vec, \%to, \%from);
# my %result;
# moveAlongVector(\%result, \%from, \%vec, 10);
# print "You are at $from{x},$from{y}.\n";
# print "If you walk $dist blocks into the direction of $to{x},$to{y}, you will end up at:\n";
# print "$result{x},$result{y}\n";
sub moveAlongVector {
	my $result = shift;
	my $r_pos = shift;
	my $r_vec = shift;
	my $dist = shift;
	if ($dist) {
		my %norm;
		normalize(\%norm, $r_vec);
		$result->{x} = $$r_pos{'x'} + $norm{'x'} * $dist;
		$result->{y} = $$r_pos{'y'} + $norm{'y'} * $dist;
	} else {
		$result->{x} = $$r_pos{'x'} + $$r_vec{'x'};
		$result->{y} = $$r_pos{'y'} + $$r_vec{'y'};
	}
}

sub normalize {
	my $r_store = shift;
	my $r_vec = shift;
	my $dist;
	$dist = distance($r_vec);
	if ($dist > 0) {
		$$r_store{'x'} = $$r_vec{'x'} / $dist;
		$$r_store{'y'} = $$r_vec{'y'} / $dist;
	} else {
		$$r_store{'x'} = 0;
		$$r_store{'y'} = 0;
	}
}

##
# vectorToDegree(vector)
# vector: a reference to a vector hash, as created by getVector().
# Returns: the degree as a number.
#
# Converts a vector into a degree number.
#
# See also: getVector()
#
# Example:
# my %from = (x => 100, y => 100);
# my %to = (x => 120, y => 120);
# my %vec;
# getVector(\%vec, \%to, \%from);
# vectorToDegree(\%vec);	# => 45
sub vectorToDegree {
	my $vec = shift;
	my $x = $vec->{x};
	my $y = $vec->{y};

	if ($y == 0) {
		if ($x < 0) {
			return 270;
		} elsif ($x > 0) {
			return 90;
		} else {
			return undef;
		}
	} else {
		my $ret = rad2deg(atan2($x, $y));
		if ($ret < 0) {
			return 360 + $ret;
		} else {
			return $ret;
		}
	}
}

##
# max($a, $b)
#
# Returns the greater of $a or $b.
sub max {
	my ($a, $b) = @_;

	return $a > $b ? $a : $b;
}

##
# min($a, $b)
#
# Returns the lesser of $a or $b.
sub min {
	my ($a, $b) = @_;

	return $a < $b ? $a : $b;
}


#################################################
#################################################
### CATEGORY: Operating system-specific stuff
#################################################
#################################################

##
# checkLaunchApp(pid, [retval])
# pid: the return value of launchApp() or launchScript()
# retval: a reference to a scalar. If the app exited, the return value will be stored in here.
# Returns: 1 if the app is still running, 0 if it has exited.
#
# If you ran a script or an app asynchronously, you can use this function to check
# whether it's currently still running.
#
# See also: launchApp(), launchScript()
sub checkLaunchedApp {
	my ($pid, $retval) = @_;
	if ($^O eq 'MSWin32') {
		my $result = ($pid->Wait(0) == 0);
		if ($result == 0 && $retval) {
			my $code;
			$pid->GetExitCode($code);
			$$retval = $code;
		}
		return $result;
	} else {
		import POSIX ':sys_wait_h';
		my $wnohang = eval "WNOHANG";
		return (waitpid($pid, $wnohang) <= 0);
	}
}

##
# launchApp(detach, args...)
# detach: set to 1 if you don't care when this application exits.
# args: the application's name and arguments.
# Returns: a PID on Unix; a Win32::Process object on Windows.
#
# Asynchronously launch an application.
#
# See also: checkLaunchedApp()
sub launchApp {
	my $detach = shift;
	if ($^O eq 'MSWin32') {
		my @args = @_;
		foreach (@args) {
			$_ = "\"$_\"";
		}

		my ($priority, $obj);
		undef $@;
		eval 'use Win32::Process; $priority = NORMAL_PRIORITY_CLASS;';
		die if ($@);
		Win32::Process::Create($obj, $_[0], "@args", 0, $priority, '.');
		return $obj;

	} else {
		require POSIX;
		import POSIX;
		my $pid = fork();

		if ($detach) {
			if ($pid == 0) {
				open(STDOUT, "> /dev/null");
				open(STDERR, "> /dev/null");
				POSIX::setsid();
				if (fork() == 0) {
					exec(@_);
				}
				POSIX::_exit(1);
			} elsif ($pid) {
				waitpid($pid, 0);
			}
		} else {
			if ($pid == 0) {
				#open(STDOUT, "> /dev/null");
				#open(STDERR, "> /dev/null");
				POSIX::setsid();
				exec(@_);
				POSIX::_exit(1);
			}
		}
		return $pid;
	}
}

##
# launchScript(async, module_paths, script, [args...])
# async: 1 if you want to run the script in the background, or 0 if you want to wait until the script has exited.
# module_paths: reference to an array which contains paths to look for modules, or undef.
# script: filename of the Perl script.
# args: parameters to pass to the script.
# Returns: a PID on Unix, a Win32::Process object on Windows.
#
# Run a Perl script.
#
# See also: launchApp(), checkLaunchedApp()
sub launchScript {
	my $async = shift;
	my $module_paths = shift;
	my $script = shift;
	my @interp;

	if (-f $Config{perlpath}) {
		@interp = ($Config{perlpath});
		delete $ENV{INTERPRETER};
	} else {
		@interp = ($ENV{INTERPRETER}, '!');
	}

	my @paths;
	if ($module_paths) {
		foreach (@{$module_paths}) {
			push @paths, "-I$_";
		}
	}

	if ($async) {
		return launchApp(0, @interp, @paths, $script, @_);
	} else {
		system(@interp, @paths, $script, @_);
	}
}


########################################
########################################
### CATEGORY: Misc utility functions
########################################
########################################


##
# dataWaiting(r_handle)
# r_handle: A reference to a handle or a socket.
# Returns: 1 if there's pending incoming data, 0 if not.
#
# Checks whether the socket $r_handle has pending incoming data.
# If there is, then you can read from $r_handle without being blocked.
sub dataWaiting {
	my $r_fh = shift;
	return 0 if (!defined $r_fh || !defined $$r_fh);

	my $bits = '';
	vec($bits, fileno($$r_fh), 1) = 1;
	# The timeout was 0.005
	return (select($bits, undef, undef, 0) > 0);
	#return select($bits, $bits, $bits, 0) > 1);
}

##
# dumpHash(r_hash)
# r_hash: a reference to a hash/array.
#
# Return a formated output of the contents of a hash/array, for debugging purposes.
sub dumpHash {
	my $out;
	my $buf = $_[0];
	if (ref($buf) eq "") {
		$buf =~ s/'/\\'/gs;
		$buf =~ s/[\000-\037]/\./gs;
		$out .= "'$buf'";
	} elsif (ref($buf) eq "HASH") {
		$out .= "{";
		foreach (keys %{$buf}) {
			s/'/\\'/gs;
			$out .= "$_=>" . dumpHash($buf->{$_}) . ",";
		}
		chop $out;
		$out .= "}";
	} elsif (ref($buf) eq "ARRAY") {
		$out .= "[";
		for (my $i = 0; $i < @{$buf}; $i++) {
			s/'/\\'/gs;
			$out .= "$i=>" . dumpHash($buf->[$i]) . ",";
		}
		chop $out;
		$out .= "]";
	}
	$out = '{empty}' if ($out eq '}');
	return $out;
}

##
# formatNumber(num)
# num: An integer number.
# Returns: A formatted number with commas.
#
# Add commas to $num so large numbers are more readable.
# $num must be an integer, not a floating point number.
#
# Example:
# formatNumber(1000000);   # -> 1,000,000
sub formatNumber {
	my $num = reverse $_[0];
	if ($num == 0) {
		return 0;
	}else {
		$num =~ s/(\d\d\d)(?=\d)(?!\d*\.)/$1,/g;
		return scalar reverse $num;
	}
}

sub _find_x {
	my ($x, $y) = @_;
	my $a = _find_x_top($x, $y);

	my @ans = (
		[$a,$a+1,$a+2,$a+3,$a+4,$a+5,$a+6,$a+7],
		[$a+1,$a,$a+3,$a+2,$a+5,$a+4,$a+7,$a+6],
		[$a+2,$a+3,$a,$a+1,$a+6,$a+7,$a+4,$a+5],
		[$a+3,$a+2,$a+1,$a,$a+7,$a+6,$a+5,$a+4],
		[$a+4,$a+5,$a+6,$a+7,$a,$a+1,$a+2,$a+3],
		[$a+5,$a+4,$a+7,$a+6,$a+1,$a,$a+3,$a+2],
		[$a+6,$a+7,$a+4,$a+5,$a+2,$a+3,$a,$a+2],
		[$a+7,$a+6,$a+5,$a+4,$a+3,$a+2,$a+1,$a]
	);
	return $ans[int($x % 32) / 4][int($y % 32) / 4];
}

sub _find_x_top {
	my ($x, $y) = @_;
	my $b;

	if ($x < 256 && $y < 256) {
		$b = 0;
	} elsif ($x >= 256 && $y >= 256) {
		$b = 0;
	} else {
		$b = 64;
	}

	my @ans = (
		[$b,$b+1*8,$b+2*8,$b+3*8,$b+4*8,$b+5*8,$b+6*8,$b+7*8],
		[$b+1*8,$b,$b+3*8,$b+2*8,$b+5*8,$b+4*8,$b+7*8,$b+6*8],
		[$b+2*8,$b+3*8,$b,$b+1*8,$b+6*8,$b+7*8,$b+4*8,$b+5*8],
		[$b+3*8,$b+2*8,$b+1*8,$b,$b+7*8,$b+6*8,$b+5*8,$b+4*8],
		[$b+4*8,$b+5*8,$b+6*8,$b+7*8,$b,$b+1*8,$b+2*8,$b+3*8],
		[$b+5*8,$b+4*8,$b+7*8,$b+6*8,$b+1*8,$b,$b+3*8,$b+2*8],
		[$b+6*8,$b+7*8,$b+4*8,$b+5*8,$b+2*8,$b+3*8,$b,$b+2*8],
		[$b+7*8,$b+6*8,$b+5*8,$b+4*8,$b+3*8,$b+2*8,$b+1*8,$b]
	);
	return $ans[int($x % 256) / 32][int($y % 256) / 32];
}

sub getCoordString {
	my $x = int(shift);
	my $y = int(shift);
	if (($config{serverType} == 0) || ($config{serverType} == 3) || ($config{serverType} == 5)) {
 		return pack("C*", int($x / 4), ($x % 4) * 64 + int($y / 16), ($y % 16) * 16);
		
	} else {
		# Old method
		#return pack("C*", _find_x($x, $y),
		#	(64 * (($x + $y) % 4) + 31 - int($y / 16)),
		#	(($y - int(($y - 8 ) / 16) * 16 - 8 ) *16));

		# Slow new method
		#my $b0 = 0x00; #unknown
		#my $b1 = ($x & 0x3FC)>>2;
		#my $b2 = (($x & 0x03)<<6) | (($y & 0x3F0)>>4);
		#my $b3 = ($y & 0x0F)<<4;
		#return pack("C*",$b0,$b1,$b2,$b3);

		# Faster (i think) new method
		# I don't know how this first byte is generated
		my $dw = 0x44000000 | (($x & 0x3FF) << 14) | (($y & 0x3FF) << 4);
		# Reorder the 4-bytes (oops! i forgot about endians!)
		return pack("C*", ($dw & 0xFF000000) >> 24, ($dw & 0xFF0000) >> 16, ($dw & 0xFF00) >> 8, $dw & 0xFF);
	}
}

sub getFormattedDate {
        my $thetime = shift;
        my $r_date = shift;
        my @localtime = localtime $thetime;
        my $themonth = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)[$localtime[4]];
        $localtime[2] = "0" . $localtime[2] if ($localtime[2] < 10);
        $localtime[1] = "0" . $localtime[1] if ($localtime[1] < 10);
        $localtime[0] = "0" . $localtime[0] if ($localtime[0] < 10);
        $$r_date = "$themonth $localtime[3] $localtime[2]:$localtime[1]:$localtime[0] " . ($localtime[5] + 1900);
        return $$r_date;
}

sub getHex {
	my $data = shift;
	my $i;
	my $return;
	for ($i = 0; $i < length($data); $i++) {
		$return .= uc(unpack("H2",substr($data, $i, 1)));
		if ($i + 1 < length($data)) {
			$return .= " ";
		}
	}
	return $return;
}

sub giveHex {
	return pack("H*",split(' ',shift));
}


sub getRange {
	my $param = shift;
	return if (!defined $param);

	# remove % from the first number here (i.e. hp 50%..60%) because it's easiest
	if (($param =~ /(\d+)\%*\s*-\s*(\d+)/) || ($param =~ /(\d+)\%*\s*\.\.\s*(\d+)/)) {
		return ($1, $2);
	} elsif ($param =~ />\s*(\d+)/) {
		return ($1+1, undef);
	} elsif ($param =~ />=\s*(\d+)/) {
		return ($1, undef);
	} elsif ($param =~ /<\s*(\d+)/) {
		return (undef, $1-1);
	} elsif ($param =~ /<=\s*(\d+)/) {
		return (undef, $1);
	} elsif ($param =~/^(\d+)/) {
		return ($1, $1);
	}
}

sub getTickCount {
	my $time = int(time()*1000);
	if (length($time) > 9) {
		return substr($time, length($time) - 8, length($time));
	} else {
		return $time;
	}
}

sub inRange {
	my $value = shift;
	my $param = shift;

	return 1 if (!defined $param);
	my ($min, $max) = getRange($param);

	if (defined $min && defined $max) {
		return 1 if ($value >= $min && $value <= $max);
	} elsif (defined $min) {
		return 1 if ($value >= $min);
	} elsif (defined $max) {
		return 1 if ($value <= $max);
	}

	return 0;
}

##
# judgeSkillArea(ID)
# ID: a skill ID.
# Returns: the size of the skill's area.
#
# Figure out how large the skill area is, in diameters.
sub judgeSkillArea {
	my $id = shift;

	if ($id == 81 || $id == 85 || $id == 89 || $id == 83 || $id == 110 || $id == 91) {
		 return 5;
	} elsif ($id == 70 || $id == 79 ) {
		 return 4;
	} elsif ($id == 21 || $id == 17 ){
		 return 3;
	} elsif ($id == 88  || $id == 80
	      || $id == 11  || $id == 18
	      || $id == 140 || $id == 229 ) {
		 return 2;
	} else {
		 return 0;
	}
}

sub makeCoords {
	my $r_hash = shift;
	my $rawCoords = shift;
	$$r_hash{'x'} = unpack("C", substr($rawCoords, 0, 1)) * 4 + (unpack("C", substr($rawCoords, 1, 1)) & 0xC0) / 64;
	$$r_hash{'y'} = (unpack("C",substr($rawCoords, 1, 1)) & 0x3F) * 16 +
				(unpack("C",substr($rawCoords, 2, 1)) & 0xF0) / 16;
}

sub makeCoords2 {
	my $r_hash = shift;
	my $rawCoords = shift;
	$$r_hash{'x'} = (unpack("C",substr($rawCoords, 1, 1)) & 0xFC) / 4 +
				(unpack("C",substr($rawCoords, 0, 1)) & 0x0F) * 64;
	$$r_hash{'y'} = (unpack("C", substr($rawCoords, 1, 1)) & 0x03) * 256 + unpack("C", substr($rawCoords, 2, 1));
}

##
# makeDistMap(data, width, height)
# data: the raw field data.
# width: the field's width.
# height: the field's height.
# Returns: the raw data of the distance map.
#
# Create a distance map from raw field data. This distance map data is used by pathfinding
# for wall avoidance support.
#
# This function is used internally by getField(). You shouldn't have to use this directly.
sub old_makeDistMap {
	# makeDistMap() is now written in C++ (src/auto/XSTools/misc/fastutils.xs)
	# The old Perl function is still here in case anyone wants to read it
	my $data = shift;
	my $width = shift;
	my $height = shift;

	# Simplify the raw map data. Each byte in the raw map data
	# represents a block on the field, but only some bytes are
	# interesting to pathfinding.
	for (my $i = 0; $i < length($data); $i++) {
		my $v = ord(substr($data, $i, 1));
		# 0 is open, 3 is walkable water
		if ($v == 0 || $v == 3) {
			$v = 255;
		} else {
			$v = 0;
		}
		substr($data, $i, 1, chr($v));
	}

	my $done = 0;
	until ($done) {
		$done = 1;
		#'push' wall distance right and up
		for (my $y = 0; $y < $height; $y++) {
			for (my $x = 0; $x < $width; $x++) {
				my $i = $y * $width + $x;
				my $dist = ord(substr($data, $i, 1));
				if ($x != $width - 1) {
					my $ir = $y * $width + $x + 1;
					my $distr = ord(substr($data, $ir, 1));
					my $comp = $dist - $distr;
					if ($comp > 1) {
						my $val = $distr + 1;
						$val = 255 if $val > 255;
						substr($data, $i, 1, chr($val));
						$done = 0;
					} elsif ($comp < -1) {
						my $val = $dist + 1;
						$val = 255 if $val > 255;
						substr($data, $ir, 1, chr($val));
						$done = 0;
					}
				}
				if ($y != $height - 1) {
					my $iu = ($y + 1) * $width + $x;
					my $distu = ord(substr($data, $iu, 1));
					my $comp = $dist - $distu;
					if ($comp > 1) {
						my $val = $distu + 1;
						$val = 255 if $val > 255;
						substr($data, $i, 1, chr($val));
						$done = 0;
					} elsif ($comp < -1) {
						my $val = $dist + 1;
						$val = 255 if $val > 255;
						substr($data, $iu, 1, chr($val));
						$done = 0;
					}
				}
			}
		}
		#'push' wall distance left and down
		for (my $y = $height - 1; $y >= 0; $y--) {
			for (my $x = $width - 1; $x >= 0 ; $x--) {
				my $i = $y * $width + $x;
				my $dist = ord(substr($data, $i, 1));
				if ($x != 0) {
					my $il = $y * $width + $x - 1;
					my $distl = ord(substr($data, $il, 1));
					my $comp = $dist - $distl;
					if ($comp > 1) {
						my $val = $distl + 1;
						$val = 255 if $val > 255;
						substr($data, $i, 1, chr($val));
						$done = 0;
					} elsif ($comp < -1) {
						my $val = $dist + 1;
						$val = 255 if $val > 255;
						substr($data, $il, 1, chr($val));
						$done = 0;
					}
				}
				if ($y != 0) {
					my $id = ($y - 1) * $width + $x;
					my $distd = ord(substr($data, $id, 1));
					my $comp = $dist - $distd;
					if ($comp > 1) {
						my $val = $distd + 1;
						$val = 255 if $val > 255;
						substr($data, $i, 1, chr($val));
						$done = 0;
					} elsif ($comp < -1) {
						my $val = $dist + 1;
						$val = 255 if $val > 255;
						substr($data, $id, 1, chr($val));
						$done = 0;
					}
				}
			}
		}
	}
	return $data;
}

sub makeIP {
	my $raw = shift;
	my $ret;
	for (my $i = 0; $i < 4; $i++) {
		$ret .= hex(getHex(substr($raw, $i, 1)));
		if ($i + 1 < 4) {
			$ret .= ".";
		}
	}
	return $ret;
}

##
# parseArgs(command, [max], [delimiters = ' '], [last_arg_pos])
# command: a command string.
# max: maximum number of arguments.
# delimiters: a character array of delimiters for arguments.
# last_arg_pos: reference to a scalar. The position of the start of the last argument is stored here.
# Returns: an array of arguments.
#
# Parse a command string and split it into an array of arguments.
# Quoted parts inside the command strings are considered one argument.
# Backslashes can be used to escape a special character (like quotes).
# Leadingand trailing whitespaces are ignored, unless quoted.
#
# Example:
# parseArgs("guild members");		# => ("guild", "members")
# parseArgs("c hello there", 2);	# => ("c", "hello there")
# parseArgs("pm 'My Friend' hey there", 3);	# ("pm", "My Friend", "hey there")
sub parseArgs {
	my $command = shift;
	my $max = shift;
	my $delimiters = shift;
	my $r_last_arg_pos = shift;
	my @args;

	if (!defined $delimiters) {
		$delimiters = qr/ /;
	} else {
		$delimiters = quotemeta $delimiters;
		$delimiters = qr/[$delimiters]/;
	}

	my $last_arg_pos;
	my $tmp;
	($tmp, $command) = $command =~ /^( *)(.*)/;
	$last_arg_pos = length($tmp);
	$command =~ s/ *$//;

	my $len = length $command;
	my $within_quote;
	my $quote_char = '';
	my $i;

	for ($i = 0; $i < $len; $i++) {
		my $char = substr($command, $i, 1);

		if ($max && @args == $max) {
			$args[0] = $command;
			last;

		} elsif ($char eq '\\') {
			$args[0] .= substr($command, $i + 1, 1);
			$i++;

		} elsif (($char eq '"' || $char eq "'") && ($quote_char eq '' || $quote_char eq $char)) {
			$within_quote = !$within_quote;
			$quote_char = ($within_quote) ? $char : '';

		} elsif ($within_quote) {
			$args[0] .= $char;

		} elsif ($char =~ /$delimiters/) {
			unshift @args, '';
			$command = substr($command, $i + 1);
			($tmp, $command) =~ /^(${delimiters}*)(.*)/;
			$len = length $command;
			$last_arg_pos += $i + 1;
			$i = -1;

		} else {
			$args[0] .= $char;
		}
	}
	$$r_last_arg_pos = $last_arg_pos if ($r_last_arg_pos);
	return reverse @args;
}

sub swrite {
	my $result = '';
	for (my $i = 0; $i < @_; $i += 2) {
		my $format = $_[$i];
		my @args = @{$_[$i+1]};
		if ($format =~ /@[<|>]/) {
			$^A = '';
			formline($format, @args);
			$result .= "$^A\n";
		} else {
			$result .= "$format\n";
		}
	}
	$^A = '';
	return $result;
}

##
# timeConvert(seconds)
# seconds: number of seconds.
# Returns: a human-readable version of $seconds.
#
# Converts $seconds into a string in the form of "x hours y minutes z seconds".
sub timeConvert {
	my $time = shift;
	my $hours = int($time / 3600);
	my $time = $time % 3600;
	my $minutes = int($time / 60);
	my $time = $time % 60;
	my $seconds = $time;
	my $gathered = '';

	$gathered = "$hours hours " if ($hours);
	$gathered .= "$minutes minutes " if ($minutes);
	$gathered .= "$seconds seconds" if ($seconds);
	$gathered =~ s/ $//;
	$gathered = '0 seconds' if ($gathered eq '');
	return $gathered;
}

##
# timeOut(r_time, [timeout])
# r_time: a time value, or a hash.
# timeout: the timeout value to use if $r_time is a time value.
# Returns: a boolean.
#
# If r_time is a time value:
# Check whether $timeout seconds have passed since $r_time.
#
# If r_time is a hash:
# Check whether $r_time->{timeout} seconds have passed since $r_time->{time}.
#
# This function is usually used to handle timeouts in a loop.
#
# Example:
# my %time;
# $time{time} = time;
# $time{timeout} = 10;
#
# while (1) {
#     if (timeOut(\%time)) {
#         print "10 seconds have passed since this loop was started.\n";
#         last;
#     }
# }
#
# my $startTime = time;
# while (1) {
#     if (timeOut($startTime, 6)) {
#         print "6 seconds have passed since this loop was started.\n";
#         last;
#     }
# }

# timeOut() is implemented in tools/misc/fastutils.xs

##
# vocalString(letter_length, [r_string])
# letter_length: the requested length of the result.
# r_string: a reference to a scalar. If given, the result will be stored here.
# Returns: the resulting string.
#
# Creates a random string of $letter_length long. The resulting string is pronouncable.
# This function can be used to generate a random password.
#
# Example:
# for (my $i = 0; $i < 5; $i++) {
#     printf("%s\n", vocalString(10));
# }
sub vocalString {
	my $letter_length = shift;
	return if ($letter_length <= 0);
	my $r_string = shift;
	my $test;
	my $i;
	my $password;
	my @cons = ("b", "c", "d", "g", "h", "j", "k", "l", "m", "n", "p", "r", "s", "t", "v", "w", "y", "z", "tr", "cl", "cr", "br", "fr", "th", "dr", "ch", "st", "sp", "sw", "pr", "sh", "gr", "tw", "wr", "ck");
	my @vowels = ("a", "e", "i", "o", "u" , "a", "e" ,"i","o","u","a","e","i","o", "ea" , "ou" , "ie" , "ai" , "ee" ,"au", "oo");
	my %badend = ( "tr" => 1, "cr" => 1, "br" => 1, "fr" => 1, "dr" => 1, "sp" => 1, "sw" => 1, "pr" =>1, "gr" => 1, "tw" => 1, "wr" => 1, "cl" => 1, "kr" => 1);
	for (;;) {
		$password = "";
		for($i = 0; $i < $letter_length; $i++){
			$password .= $cons[rand(@cons - 1)] . $vowels[rand(@vowels - 1)];
		}
		$password = substr($password, 0, $letter_length);
		($test) = ($password =~ /(..)\z/);
		last if ($badend{$test} != 1);
	}
	$$r_string = $password if ($r_string);
	return $password;
}

return 1;
