#!/usr/bin/perl
#########################################################################
#  OpenKore - Interface::Console::Curses
#  You need Curses (the Perl bindings for (n)curses)
#
#  Copyright (c) 2004 OpenKore development team 
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#
#  $Revision$
#  $Id$
#
#########################################################################
package Interface::Console::Curses;

use strict;
use Curses;
use Time::HiRes qw(time);

use Globals;
use Utils;
use base qw(Interface::Console);
use Modules;

use constant MAXHISTORY => 50;

sub new {
	my %interface = ();
	bless \%interface, __PACKAGE__;
	my $self = \%interface;

	initscr;
	idlok 1;
	idcok 1;
	nonl;
	cbreak;
	noecho;
	intrflush 1;
	keypad 1;
	nodelay 1;
	start_color;
	use_default_colors;
	init_pair(1, COLOR_BLACK, -1);
	init_pair(2, COLOR_RED, -1);
	init_pair(3, COLOR_GREEN, -1);
	init_pair(4, COLOR_YELLOW, -1);
	init_pair(5, COLOR_BLUE, -1);
	init_pair(6, COLOR_MAGENTA, -1);
	init_pair(7, COLOR_CYAN, -1);
	init_pair(8, COLOR_WHITE, -1);
	$self->{winStatus} = newwin(4, 0, 0, 0);
	$self->{winObjects} = newwin($LINES-5, 15, 4, $COLS-15);
	$self->{winLog} = newwin($LINES-5, $COLS-15, 4, 0);
	scrollok $self->{winLog}, 1;
	$self->{winInput} = newwin(1, 0, $LINES-1, 0);
	$self->updateLayout;
	$self->setCursor;

	$self->{time_start} = time;

	return \%interface;
}

sub DESTROY {
	my $self = shift;

	delwin $self->{winHelp} if ($self->{winHelp});
	delwin $self->{winInput};
	delwin $self->{winChat} if ($self->{winChat});
	delwin $self->{winLog};
	delwin $self->{winFight} if ($self->{winFight});
	delwin $self->{winObjects} if ($self->{winObjects});
	delwin $self->{winStatus};
	endwin;
}

sub iterate {
	my $self = shift;

	return if (!timeOut($self->{time_refresh}, 0.5));
	$self->{time_refresh} = time;

	if ($self->{lines} != $LINES || $self->{cols} != $COLS) {
		$self->updateLayout;
	} else {
		$self->updatePeriodic;
	}
	$self->setCursor;
}

sub getInput {
	my $self = shift;
	my $timeout = shift;

	my $ch = getch();
	return undef if ($ch eq ERR);

	my $ret;
	while ($ch ne ERR) {
		if ($ch eq "\r" || $ch eq KEY_ENTER) {
			# Enter
			$ret = $self->{inputBuffer};
			undef $self->{inputBuffer};
			$self->{inputPos} = 0;
			if (length($ret) > 0 && $ret ne $self->{inputHistory}[0]) {
				unshift @{$self->{inputHistory}}, $ret;
				pop @{$self->{inputHistory}} if (@{$self->{inputHistory}} > MAXHISTORY);
			}
			$self->{inputHistoryPos} = 0;
			last;
		} elsif ((ord($ch) == 9 || ord($ch) == 127 || $ch eq KEY_BACKSPACE) && $self->{inputBuffer}) {
			# Backspace
			$self->{inputBuffer} = substr($self->{inputBuffer}, 0, -1);
			$self->{inputPos}--;
		} elsif (ord($ch) == 12) {
			# Ctrl-L
			clear;
			$self->updateLayout;
		} elsif (ord($ch) == 21) {
			# Ctrl-U
			undef $self->{inputBuffer};
			$self->{inputPos} = 0;
			$self->{inputHistoryPos} = 0;
		} elsif ($ch == KEY_LEFT) {
			# Cursor left
			$self->{inputPos}-- if ($self->{inputPos} > 0);
		} elsif ($ch == KEY_RIGHT) {
			# Cursor right
			$self->{inputPos}++ if ($self->{inputPos} < length($self->{inputBuffer}));
		} elsif ($ch == KEY_UP) {
			# Input history
			$self->{inputHistoryPos}++ if (defined $self->{inputHistory}[$self->{inputHistoryPos}]);
			$self->{inputBuffer} = $self->{inputHistory}[$self->{inputHistoryPos}-1];
			$self->{inputPos} = length($self->{inputBuffer});
		} elsif ($ch == KEY_DOWN) {
			# Input history
			$self->{inputHistoryPos}-- if ($self->{inputHistoryPos} > 0);
			$self->{inputBuffer} = $self->{inputHistoryPos} ? $self->{inputHistory}[$self->{inputHistoryPos}-1] : "";
			$self->{inputPos} = length($self->{inputBuffer});
		} elsif ($ch == KEY_PPAGE) {
			# TODO: Scrollback buffer
		} elsif ($ch == KEY_NPAGE) {
			# TODO: Scrollback buffer
		} elsif ($ch == KEY_F(1)) {
			# Toggle help window
			$self->toggleWindow("Help");
			$self->updateLayout;
		} elsif ($ch == KEY_F(2)) {
			# Toggle objects window
			$self->toggleWindow("Objects");
			$self->updateLayout;
		} elsif ($ch == KEY_F(3)) {
			# Toggle fight window
			$self->toggleWindow("Fight");
			$self->updateLayout;
		} elsif ($ch == KEY_F(4)) {
			# Toggle chat window
			$self->toggleWindow("Chat");
			$self->updateLayout;
		} elsif (ord($ch) >= 32 && ord($ch) <= 126) {
			# Normal character
			$self->{inputBuffer} = substr($self->{inputBuffer}, 0, $self->{inputPos}) . $ch . substr($self->{inputBuffer}, $self->{inputPos});
			$self->{inputPos} += length($ch);
		}
		$ch = getch();
	}

	my $pos = 0;
	$pos += 10 while (length($self->{inputBuffer}) - $pos >= $COLS);
	erase $self->{winInput};
	addstr $self->{winInput}, 0, 0, substr($self->{inputBuffer}, $pos);
	refresh $self->{winInput};
	$self->setCursor;

	return ($ret ne "") ? $ret : undef;
}

sub writeOutput {
	my $self = shift;
	my $type = shift;
	my $msg = shift;
	my $domain = shift;

	my @localtime = localtime time;
	my $time = sprintf("%02d:%02d:%02d", $localtime[2], $localtime[1], $localtime[0]);
	my $color = $consoleColors{$type}{$domain} ne "" ? lc($consoleColors{$type}{$domain}) : lc($consoleColors{$type}{default});
	$color = "bold|" . $color unless $color eq "" || $color =~ /^dark/;
	$color =~ s/^dark//g;
	$color =~ s/gr[ae]y/white/g;
	$color = "{" . $color . "}" unless $color eq "";
	foreach my $s (split("\n", $msg)) {
		if ($self->{winFight} && existsInList("attackMon,attackMonMiss,attacked,attackedMiss,skill", $domain)) {
			scroll $self->{winFight};
			$self->printw($self->{winFight}, $self->{winFightHeight} - 2, 0, "{normal}@<<<<<<< $color@*", $time, $s);
		} elsif ($self->{winChat} && existsInList("emotion,gmchat,guildchat,partychat,pm,publicchat,selfchat", $domain)) {
			scroll $self->{winChat};
			$self->printw($self->{winChat}, $self->{winChatHeight} - 2, 0, "{normal}@<<<<<<< $color@*", $time, $s);
		} else {
			scroll $self->{winLog};
			$self->printw($self->{winLog}, $self->{winLogHeight} - 1, 0, "{normal}@<<<<<<< $color@*", $time, $s);
		}
	}
	refresh $self->{winFight} if $self->{winFight};
	refresh $self->{winLog};
	refresh $self->{winChat} if $self->{winChat};
	$self->setCursor;
}

sub title {
	my $self = shift;
	my $title = shift;
}

sub displayUsage {
	my $self = shift;
	my $text = shift;

	print $text;
}

sub errorDialog {
	my $self = shift;
	my $msg = shift;
	my $fatal = shift;

	# FIXME: Need better error dialog
	print "ERROR: $msg";
}

################################

sub printw {
	my $self = shift;
	my $win = shift;
	my $line = shift;
	my $col = shift;
	my $picture = shift;
	my @params = @_;

	my %attrtable = (
		normal => A_NORMAL,
		underline => A_UNDERLINE,
		reverse => A_REVERSE,
		blink => A_BLINK,
		dim => A_DIM,
		bold => A_BOLD,
		black => COLOR_PAIR(1),
		red => COLOR_PAIR(2),
		green => COLOR_PAIR(3),
		yellow => COLOR_PAIR(4),
		blue => COLOR_PAIR(5),
		magenta => COLOR_PAIR(6),
		cyan => COLOR_PAIR(7),
		white => COLOR_PAIR(8)
	);

	$^A = '';
	formline $picture, @params;
	my @text = split(/{([^}]+)}/, $^A);
	move $win, $line, $col;
	for (my $i = 0; $i < @text; $i += 2) {
		addstr $win, $text[$i];
		if ($text[$i+1] ne "") {
			attrset $win, A_NORMAL;
			foreach my $attr (split(/\|/, $text[$i+1])) {
				attron $win, $attrtable{$attr} if $attrtable{$attr};
			}
		}
	}
}

sub makeBar {
	my $self = shift;
	my $len = shift;
	my $cur = shift;
	my $max = shift;
	my $color1 = shift;
	my $treshold = shift;
	my $color2 = shift;

	$len -= 2;
	my $pct = $max ? ($cur / $max * 100) : 0;
	my $cnt = int($len * $pct / 100);

	my $color = ($color1 ne "") ? (($pct >= $treshold && $color2 ne "") ? $color2 : $color1) : undef;
	my $bar = "";
	$bar .= "{normal}" if $color ne "";
	$bar .= "[";
	if (!$cur && !$max) {
		$bar .= (" " x $len);
	} else {
		$bar .= "{".$color."}" if $color ne "";
		$bar .= ("#" x $cnt);
		$bar .= "{normal}" if $color ne "";
		$bar .= ("-" x ($len-$cnt));
	}
	$bar .= "]";

	return $bar;
}

sub toggleWindow {
	my $self = shift;
	my $name = shift;

	if (!$self->{"win".$name}) {
		$self->{"win".$name} = newwin(5, 0, 0, 0);
		scrollok $self->{"win".$name}, 1 if ($name eq "Fight" || $name eq "Chat");
	} else {
		delwin $self->{"win".$name};
		undef $self->{"win".$name};
	}
}

sub updateLayout {
	my $self = shift;

	# Calculate window sizes
	$self->{winStatusHeight} = 5;
	$self->{winStatusWidth} = $COLS;
	$self->{winObjectsHeight} = $LINES - $self->{winStatusHeight} - 2;
	$self->{winObjectsWidth} = int($COLS * 0.20);
	$self->{winObjectsWidth} = 0 unless ($self->{winObjects});
	$self->{winChatHeight} = int(($LINES - $self->{winStatusHeight} - 2) * 0.20);
	$self->{winChatHeight} = 0 unless ($self->{winChat});
	$self->{winChatWidth} = $COLS - $self->{winObjectsWidth};
	$self->{winFightHeight} = int(($LINES - $self->{winStatusHeight} - 2) * 0.20);
	$self->{winFightHeight} = 0 unless ($self->{winFight});
	$self->{winFightWidth} = $COLS - $self->{winObjectsWidth};
	$self->{winLogHeight} = $LINES - $self->{winStatusHeight} - $self->{winFightHeight} - $self->{winChatHeight} - 2;
	$self->{winLogWidth} = $COLS - $self->{winObjectsWidth};

	# Status window
	resize $self->{winStatus}, $self->{winStatusHeight}-1, $self->{winStatusWidth};
	mvwin $self->{winStatus}, 0, 0;
	hline $self->{winStatusHeight}-1, 0, 0, $self->{winStatusWidth};
	# Objects window
	if ($self->{winObjects}) {
		resize $self->{winObjects}, $self->{winObjectsHeight}, $self->{winObjectsWidth}-1;
		mvwin $self->{winObjects}, $self->{winStatusHeight}, $self->{winLogWidth}+1;
		vline $self->{winStatusHeight}, $self->{winLogWidth}, 0, $self->{winObjectsHeight};
	}
	# Fight window
	if ($self->{winFight}) {
		resize $self->{winFight}, $self->{winFightHeight}-1, $self->{winFightWidth};
		mvwin $self->{winFight}, $self->{winStatusHeight}, 0;
		hline $self->{winStatusHeight} + $self->{winFightHeight} - 1, 0, 0, $self->{winFightWidth};
	}
	# Log Window
	if ($self->{winLog}) {
		resize $self->{winLog}, $self->{winLogHeight}, $self->{winLogWidth};
		mvwin $self->{winLog}, $self->{winStatusHeight} + $self->{winFightHeight}, 0;
	}
	# Chat window
	if ($self->{winChat}) {
		hline $self->{winStatusHeight} + $self->{winFightHeight} + $self->{winLogHeight}, 0, 0, $self->{winChatWidth};
		resize $self->{winChat}, $self->{winChatHeight}-1, $self->{winChatWidth};
		mvwin $self->{winChat}, $self->{winStatusHeight} + $self->{winFightHeight} + $self->{winLogHeight} + 1, 0;
	}
	# Input window
	hline $LINES-2, 0, 0, $COLS;
	resize $self->{winInput}, 1, $COLS;
	mvwin $self->{winInput}, $LINES-1, 0;
	refresh;

	$self->{lines} = $LINES;
	$self->{cols} = $COLS;

	$self->updateAll;
}

sub updateAll {
	my $self = shift;

	$self->updateStatus;
	$self->updateObjects;
	refresh $self->{winFight} if ($self->{winFight});
	refresh $self->{winLog};
	refresh $self->{winChat} if ($self->{winChat});
	refresh $self->{winInput};
	$self->updateHelp;
}

sub updatePeriodic {
	my $self = shift;

	$self->updateStatus;
	$self->updateObjects;
	$self->updateHelp;
}

sub updateStatus {
	my $self = shift;

	return if (!$self->{winStatus});

	erase $self->{winStatus};
	my $width = int($self->{winStatusWidth} / 2);

	$self->printw($self->{winStatus}, 0, 0, "{bold|yellow}   Char: {bold|white}@*{normal} (@* @*)",
		$char->{name}, $jobs_lut{$char->{jobID}}, $sex_lut{$char->{sex}});
	my $bexpbar = $self->makeBar($width-24, $char->{exp}, $char->{exp_max});
	$self->printw($self->{winStatus}, 1, 0, "{bold|yellow}   Base:{normal} @<< $bexpbar (@#.##%)",
		$char->{lv}, $char->{exp_max} ? $char->{exp} / $char->{exp_max} * 100 : 0);
	my $jexpbar = $self->makeBar($width-24, $char->{exp_job}, $char->{exp_job_max});
	$self->printw($self->{winStatus}, 2, 0, "{bold|yellow}    Job:{normal} @<< $jexpbar (@#.##%)",
		$char->{lv_job}, $char->{exp_job_max} ? $char->{exp_job} / $char->{exp_job_max} * 100 : 0);
	$self->printw($self->{winStatus}, 3, 0, "{bold|yellow}    Map:{normal} @* (@*,@*)",
		$field{name}, $char->{pos}{x}, $char->{pos}{y});

	vline $self->{winStatus}, 0, $width-1, 0, $self->{winStatusHeight};
	my $hpbar = $self->makeBar($width-29, $char->{hp}, $char->{hp_max}, "bold|red", 15, "bold|green");
	$self->printw($self->{winStatus}, 0, $width, "{bold|yellow}     HP:{normal} @####/@#### $hpbar (@##%)",
		$char->{hp}, $char->{hp_max}, $char->{hp_max} ? $char->{hp} / $char->{hp_max} * 100 : 0);
	my $spbar = $self->makeBar($width-29, $char->{sp}, $char->{sp_max}, "bold|blue");
	$self->printw($self->{winStatus}, 1, $width, "{bold|yellow}     SP:{normal} @####/@#### $spbar (@##%)",
		$char->{sp}, $char->{sp_max}, $char->{sp_max} ? $char->{sp} / $char->{sp_max} * 100 : 0);
	my $weightbar = $self->makeBar($width-29, $char->{weight}, $char->{weight_max}, "cyan", 50, "red");
	$self->printw($self->{winStatus}, 2, $width, "{bold|yellow} Weight:{normal} @####/@#### $weightbar (@##%)",
		$char->{weight}, $char->{weight_max}, $char->{weight_max} ? $char->{weight} / $char->{weight_max} * 100 : 0);
	my $statuses = ($char->{statuses}) ? join(",", keys %{$char->{statuses}}) : "none";
	$self->printw($self->{winStatus}, 3, $width, "{bold|yellow} Status:{normal} @*",
		$statuses);

	$self->{heartBeat} = !$self->{heartBeat};
	addstr $self->{winStatus}, 0, 0, $self->{heartBeat} ? ":" : ".";

	refresh $self->{winStatus};
}

sub updateObjects {
	my $self = shift;

	return if (!$self->{winObjects});

	my $line = 0;
	my $namelen = $self->{winObjectsWidth} - 8;
	erase $self->{winObjects};

	# Players
	for (my $i = 0; $i < @playersID && $line < $self->{winObjectsHeight} - 1; $i++) {
		my $id = $playersID[$i];
		next if ($id eq "");
		my $name = $players{$id}{name};
		my $dist = distance($char->{pos}, $players{$id}{pos});
		$self->printw($self->{winObjects}, $line++, 0, "{bold|cyan}@# {cyan}@".("<"x$namelen)." {normal}@#", $i, $name, $dist);
	}

	# Monsters
	for (my $i = 0; $i < @monstersID && $line < $self->{winObjectsHeight} - 1; $i++) {
		my $id = $monstersID[$i];
		next if ($id eq "");
		my $name = $monsters{$id}{name};
		my $dist = distance($char->{pos}, $monsters{$id}{pos});
		$self->printw($self->{winObjects}, $line++, 0, "{bold|red}@# {red}@".("<"x$namelen)." {normal}@#", $i, $name, $dist);
	}

	# Items
	for (my $i = 0; $i < @itemsID && $line < $self->{winObjectsHeight} - 1; $i++) {
		my $id = $itemsID[$i];
		next if ($id eq "");
		my $name = $items{$id}{name};
		my $dist = distance($char->{pos}, $items{$id}{pos});
		$self->printw($self->{winObjects}, $line++, 0, "{bold|green}@# {green}@".("<"x$namelen)." {normal}@#", $i, $name, $dist);
	}

	# NPCs
	for (my $i = 0; $i < @npcsID && $line < $self->{winObjectsHeight} - 1; $i++) {
		my $id = $npcsID[$i];
		next if ($id eq "");
		my $name = $npcs{$id}{name};
		my $dist = distance($char->{pos}, $npcs{$id}{pos});
		$self->printw($self->{winObjects}, $line++, 0, "{bold|blue}@# {blue}@".("<"x$namelen)." {normal}@#", $i, $name, $dist);
	}

	refresh $self->{winObjects};
}

sub updateHelp {
	my $self = shift;

	return if (!$self->{winHelp});

	my $height = 15;
	my $width = 70;
	resize $self->{winHelp}, $height, $width;
	mvwin $self->{winHelp}, int(($LINES-$height)/2), int(($COLS-$width)/2);

	erase $self->{winHelp};
	box $self->{winHelp}, 0, 0;
	my $center = "@" . ("|" x ($width-7));
	$self->printw($self->{winHelp}, 1, 1, " {bold|white} $center {normal}",
		"OpenKore v$Settings::VERSION");
	$self->printw($self->{winHelp}, 3, 1, " {bold|white}<F1>{normal}     Show/hide this help window");
	$self->printw($self->{winHelp}, 4, 1, " {bold|white}<F2>{normal}     Show/hide objects (players,monsters,items,NPCs) pane");
	$self->printw($self->{winHelp}, 5, 1, " {bold|white}<F3>{normal}     Show/hide fight message pane");
	$self->printw($self->{winHelp}, 6, 1, " {bold|white}<F4>{normal}     Show/hide chat message pane");
	$self->printw($self->{winHelp}, 8, 1, " {bold|white}<Ctrl-L>{normal} Redraw screen");
	$self->printw($self->{winHelp}, 9, 1, " {bold|white}<Ctrl-U>{normal} Clear input line");
	$self->printw($self->{winHelp}, 13, 1, " {bold|blue} $center {normal}",
		"Visit http://openkore.sourceforge.net/ for more stuff");

	refresh $self->{winHelp};
}

sub setCursor {
	my $self = shift;

	my $pos = $self->{inputPos};
	$pos -= 10 while ($pos >= $COLS);
	move $LINES - 1, $pos;
	refresh;
}

1;
