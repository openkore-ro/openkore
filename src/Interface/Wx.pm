#########################################################################
#  OpenKore - WxWidgets Interface
#  You need:
#  * WxPerl (the Perl bindings for WxWidgets) - http://wxperl.sourceforge.net/
#
#  More information about WxWidgets here: http://www.wxwidgets.org/
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
#  $Revision$
#  $Id$
#
#########################################################################
package Interface::Wx;

use strict;
use Wx ':everything';
use Wx::Event qw(EVT_CLOSE EVT_MENU EVT_MENU_OPEN EVT_LISTBOX_DCLICK
		EVT_CHOICE EVT_TIMER EVT_TASKBAR_LEFT_DOWN EVT_KEY_DOWN
		EVT_BUTTON);
use Time::HiRes qw(time sleep);
use File::Spec;
use FindBin qw($RealBin);


use Globals;
use Interface;
use base qw(Wx::App Interface);
use Modules;
use Interface::Wx::Dock;
use Interface::Wx::MapViewer;
use Interface::Wx::LogView;
use Interface::Wx::Console;
use Interface::Wx::Input;
use Interface::Wx::ItemList;
use Interface::Wx::ConfigEditor;
use Interface::Wx::DockNotebook;
use AI;
use Settings;
use Plugins;
use Misc;
use Commands;
use Utils;


our $CVS;
our $iterationTime;


sub OnInit {
	my $self = shift;

	$CVS = ($Settings::CVS =~ /CVS/);
	$self->createInterface;
	$self->iterate;

	my $onChat = sub { $self->onChatAdd(@_); };
	$self->{hooks} = Plugins::addHooks(
		['loadfiles',               sub { $self->onLoadFiles(@_); }],
		['postloadfiles',           sub { $self->onLoadFiles(@_); }],
		['parseMsg/addPrivMsgUser', sub { $self->onAddPrivMsgUser(@_); }],
		['ChatQueue::add',          $onChat],
		['packet_selfChat',         $onChat],
		['packet_privMsg',          $onChat],
		['packet_sentPM',           $onChat]
	);

	$self->{history} = [];
	$self->{historyIndex} = -1;

	Modules::register("Interface::Wx::Dock",
		"Interface::Wx::MapViewer",
		"Interface::Wx::Console",
		"Interface::Wx::Input",
		"Interface::Wx::ItemList",
		"Interface::Wx::ConfigEditor");


	# Update user interface controls

	my $timer = new Wx::Timer($self, 248);
	EVT_TIMER($self, 248, sub {
		$self->updateStatusBar;
		$self->updateMapViewer;
	});
	$timer->Start(150);

	$timer = new Wx::Timer($self, 249);
	EVT_TIMER($self, 249, sub {
		$self->updateItemList;
	});
	$timer->Start(350);

	return 1;
}

sub DESTROY {
	my $self = shift;
	Plugins::delHooks($self->{hooks});
}


######################
## METHODS
######################


sub mainLoop {
	my $self = shift;
	my $timer = new Wx::Timer($self, 247);
	my $sleepTime = $config{sleepTime};
	my $quitting;
	my $sub = sub {
		return if ($quitting);
		if ($quit) {
			$quitting = 1;
			$self->ExitMainLoop;
			return;
		} elsif ($self->{iterating}) {
			return;
		}

		$self->{iterating}++;

		if ($sleepTime ne $config{sleepTime}) {
			$sleepTime = $config{sleepTime};
			$timer->Start($sleepTime / 1000);
		}
		main::mainLoop();
		main::checkConnection();

		$self->{iterating}--;
	};

	EVT_TIMER($self, 247, $sub);
	$timer->Start($config{sleepTime} / 1000);
	$self->MainLoop;
}

sub iterate {
	my $self = shift;

	while ($self->Pending) {
		$self->Dispatch;
	}
	$self->Yield;
	$iterationTime = time;
}

sub getInput {
	my $self = shift;
	my $timeout = shift;
	my $msg;

	if ($timeout < 0) {
		while (!defined $self->{input} && !$quit) {
			$self->iterate;
			sleep 0.01;
		}
		$msg = $self->{input};

	} elsif ($timeout == 0) {
		$msg = $self->{input};

	} else {
		my $begin = time;
		until (defined $self->{input} || time - $begin > $timeout || $quit) {
			$self->iterate;
			sleep 0.01;
		}
		$msg = $self->{input};
	}

	undef $self->{input};
	undef $msg if (defined($msg) && $msg eq "");

	# Make sure we update the GUI. This is to work around the effect
	# of functions that block for a while
	$self->iterate if (timeOut($iterationTime, 0.05));

	return $msg;
}

sub writeOutput {
	my $self = shift;
	$self->{console}->add(@_);
	# Make sure we update the GUI. This is to work around the effect
	# of functions that block for a while
	$self->iterate if (timeOut($iterationTime, 0.05));
}

sub title {
	my $self = shift;
	my $title = shift;

	if (defined $title) {
		if ($title ne $self->{title}) {
			$self->{frame}->SetTitle($title);
			$self->{title} = $title;
		}
	} else {
		return $self->{title};
	}
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

	my $title = ($fatal) ? "Fatal error" : "Error";
	$self->{iterating}++;
	Wx::MessageBox($msg, "$title - $Settings::NAME", wxICON_ERROR, $self->{frame});
	$self->{iterating}--;
}

sub beep {
	Wx::Bell();
}


#########################
## INTERFACE CREATION
#########################


sub createInterface {
	my $self = shift;

	### Main window
	my $frame = $self->{frame} = new Wx::Frame(undef, -1, $Settings::NAME);
	$self->{title} = $frame->GetTitle();


	### Menu bar
	$self->createMenuBar;

	### Vertical box sizer
	my $vsizer = $self->{vsizer} = new Wx::BoxSizer(wxVERTICAL);
	$frame->SetSizer($vsizer);

	### Horizontal panel with HP/SP/Exp box
	$self->createInfoPanel;


	## Splitter with console and another splitter
	my $splitter = new Wx::SplitterWindow($frame, 928, wxDefaultPosition, wxDefaultSize,
		wxSP_LIVE_UPDATE);
	$self->{splitter} = $splitter;
	$splitter->SetMinimumPaneSize(25);
	$vsizer->Add($splitter, 1, wxGROW);
	$self->createSplitterContent;


	### Input field
	$self->createInputField;

	### Status bar
	my $statusbar = $self->{statusbar} = new Wx::StatusBar($frame, -1, wxST_SIZEGRIP);
	$statusbar->SetFieldsCount(3);
	$statusbar->SetStatusWidths(-1, 65, 175);
	$frame->SetStatusBar($statusbar);


	#################

	$frame->SetSizeHints(300, 250);
	$frame->SetClientSize(730, 400);
	$frame->SetIcon(Wx::GetWxPerlIcon);
	$frame->Show(1);
	$self->SetTopWindow($frame);
	EVT_CLOSE($frame, \&onClose);

	# For some reason the input box doesn't get focus even if
	# I call SetFocus(), so do it in 100 msec
	my $timer = new Wx::Timer($self, 73289);
	EVT_TIMER($self, 73289, sub {
		$self->{inputBox}->SetFocus;
	});
	$timer->Start(100, 1);

	# Hide console on Win32
	if ($buildType == 0 && !$CVS) {
		eval 'use Win32::Console; Win32::Console->new(STD_OUTPUT_HANDLE)->Free();';
	}
}


sub createMenuBar {
	my $self = shift;
	my $menu = $self->{menu} = new Wx::MenuBar;
	my $frame = $self->{frame};
	$frame->SetMenuBar($menu);
	EVT_MENU_OPEN($self->{frame}, sub { $self->onMenuOpen; });

	# Program menu
	my $opMenu = new Wx::Menu;
	$self->{mPause}  = $self->addMenu($opMenu, '&Pause Botting', \&onDisableAI, 'Pause all automated botting activity');
	$self->{mResume} = $self->addMenu($opMenu, '&Resume Botting', \&onEnableAI, 'Resume all automated botting activity');
	$opMenu->AppendSeparator;
	if ($^O eq 'MSWin32') {
		$self->addMenu($opMenu, 'Minimize to &Tray', \&onMinimizeToTray, 'Minimize to a small task bar tray icon');
		$opMenu->AppendSeparator;
	}
	$self->addMenu($opMenu, 'E&xit	Ctrl-W', \&main::quit, 'Exit this program');
	$menu->Append($opMenu, 'P&rogram');

	# Info menu
	my $infoMenu = new Wx::Menu;
	$self->addMenu($infoMenu, '&Status	Alt-S',	sub { Commands::run("s"); });
	$self->addMenu($infoMenu, 'S&tatistics',	sub { Commands::run("st"); });
	$self->addMenu($infoMenu, '&Inventory	Alt-I',	sub { Commands::run("i"); });
	$self->addMenu($infoMenu, 'S&kills',		sub { Commands::run("skills"); });
	$infoMenu->AppendSeparator;
	$self->addMenu($infoMenu, '&Players	Alt-P',	sub { Commands::run("pl"); });
	$self->addMenu($infoMenu, '&Monsters	Alt-M',	sub { Commands::run("ml"); });
	$self->addMenu($infoMenu, '&NPCs',		sub { Commands::run("nl"); });
	$infoMenu->AppendSeparator;
	$self->addMenu($infoMenu, '&Experience Report	Alt+E',	sub { main::parseInput("exp"); });
	$menu->Append($infoMenu, 'I&nfo');

	# View menu
	my $viewMenu = $self->{viewMenu} = new Wx::Menu;
	$self->addMenu($viewMenu,
		'&Map	Ctrl-M',	\&onMapToggle, 'Show where you are on the current map');
	$self->{infoBarToggle} = $self->addCheckMenu($viewMenu,
		'&Info Bar',		\&onInfoBarToggle, 'Show or hide the information bar.');
	$self->{chatLogToggle} = $self->addCheckMenu($viewMenu,
		'Chat &Log',		\&onChatLogToggle, 'Show or hide the chat log.');
	$viewMenu->AppendSeparator;
	$self->addMenu($viewMenu,
		'&Font...',		\&onFontChange, 'Change console font');
	$viewMenu->AppendSeparator;
	$self->addMenu($viewMenu,
		'&Clear Console',	\&onClearConsole);
	$menu->Append($viewMenu, '&View');

	# Settings menu
	my $settingsMenu = new Wx::Menu;
	$self->createSettingsMenu($settingsMenu) if ($self->can('createSettingsMenu'));
	$self->addMenu($settingsMenu, '&Advanced...', \&onAdvancedConfig, 'Edit advanced configuration options.');
	$menu->Append($settingsMenu, '&Settings');
	$self->createSettingsMenu2($settingsMenu) if ($self->can('createSettingsMenu2'));

	# Help menu
	my $helpMenu = new Wx::Menu();
	$self->addMenu($helpMenu, '&Manual	F1',		\&onManual, 'Read the manual');
	$self->addMenu($helpMenu, '&Forum	Shift-F1',	\&onForum, 'Visit the forum');
	$self->createHelpMenu($helpMenu) if ($self->can('createHelpMenu'));
	$menu->Append($helpMenu, '&Help');
}

sub createInfoPanel {
	my $self = shift;
	my $frame = $self->{frame};
	my $vsizer = $self->{vsizer};
	my $infoPanel = $self->{infoPanel} = new Wx::Panel($frame, -1);

	my $hsizer = new Wx::BoxSizer(wxHORIZONTAL);
	my $label = new Wx::StaticText($infoPanel, -1, "HP: ");
	$hsizer->Add($label, 0, wxLEFT, 3);


	## HP
	my $hpBar = $self->{hpBar} = new Wx::Gauge($infoPanel, -1, 100,
		wxDefaultPosition, [0, $label->GetBestSize->GetHeight + 2],
		wxGA_HORIZONTAL | wxGA_SMOOTH);
	$hsizer->Add($hpBar, 1, wxRIGHT, 8);

	$label = new Wx::StaticText($infoPanel, -1, "SP: ");
	$hsizer->Add($label, 0);

	## SP
	my $spBar = $self->{spBar} = new Wx::Gauge($infoPanel, -1, 100,
		wxDefaultPosition, [0, $label->GetBestSize->GetHeight + 2],
		wxGA_HORIZONTAL | wxGA_SMOOTH);
	$hsizer->Add($spBar, 1, wxRIGHT, 8);

	$label = new Wx::StaticText($infoPanel, -1, "Exp: ");
	$hsizer->Add($label, 0);

	## Exp and job exp
	my $expBar = $self->{expBar} = new Wx::Gauge($infoPanel, -1, 100,
		wxDefaultPosition, [0, $label->GetBestSize->GetHeight + 2],
		wxGA_HORIZONTAL | wxGA_SMOOTH);
	$hsizer->Add($expBar, 1);
	my $jobExpBar = $self->{jobExpBar} = new Wx::Gauge($infoPanel, -1, 100,
		wxDefaultPosition, [0, $label->GetBestSize->GetHeight + 2],
		wxGA_HORIZONTAL | wxGA_SMOOTH);
	$hsizer->Add($jobExpBar, 1, wxRIGHT, 8);

	$label = new Wx::StaticText($infoPanel, -1, "Weight: ");
	$hsizer->Add($label, 0);

	## Weight
	my $weightBar = $self->{weightBar} = new Wx::Gauge($infoPanel, -1, 100,
		wxDefaultPosition, [0, $label->GetBestSize->GetHeight + 2],
		wxGA_HORIZONTAL | wxGA_SMOOTH);
	$hsizer->Add($weightBar, 1);


	$infoPanel->SetSizerAndFit($hsizer);
	$vsizer->Add($infoPanel, 0, wxGROW);
}

sub createInputField {
	my $self = shift;
	my $vsizer = $self->{vsizer};
	my $frame = $self->{frame};

	my $hsizer = new Wx::BoxSizer(wxHORIZONTAL);
	$vsizer->Add($hsizer, 0, wxGROW);

	my $targetBox = $self->{targetBox} = new Wx::ComboBox($frame, -1, "", wxDefaultPosition,
		[115, 0]);
	$targetBox->SetName('targetBox');
	$hsizer->Add($targetBox, 0, wxGROW);
	EVT_KEY_DOWN($self, \&onTargetBoxKeyDown);

	my $inputBox = $self->{inputBox} = new Interface::Wx::Input($frame);
	$inputBox->onEnter($self, \&onInputEnter);
	$hsizer->Add($inputBox, 1, wxGROW);

	my $choice = $self->{inputType} = new Wx::Choice($frame, 456, wxDefaultPosition, wxDefaultSize,
			['Command', 'Public chat', 'Party chat', 'Guild chat']);
	$choice->SetSelection(0);
	EVT_CHOICE($self, 456, sub { $inputBox->SetFocus; });
	$hsizer->Add($choice, 0, wxGROW);
}

sub createSplitterContent {
	my $self = shift;
	my $splitter = $self->{splitter};
	my $frame = $self->{frame};

	## Dockable notebook with console and chat log
	my $notebook = $self->{notebook} = new Interface::Wx::DockNotebook($splitter, -1);
	$notebook->SetName('notebook');
	my $page = $notebook->newPage(0, 'Console');
	my $console = $self->{console} = new Interface::Wx::Console($page);
	$page->set($console);

	$page = $notebook->newPage(1, 'Chat Log', 0);
	my $chatLog = $self->{chatLog} = new Interface::Wx::LogView($page);
	$page->set($chatLog);
	$chatLog->addColor("selfchat", 0, 148, 0);
	$chatLog->addColor("pm", 142, 120, 0);
	$chatLog->addColor("p", 164, 0, 143);
	$chatLog->addColor("g", 0, 177, 108);


	## Parallel to the notebook is another sub-splitter
	my $subSplitter = new Wx::SplitterWindow($splitter, 583,
		wxDefaultPosition, wxDefaultSize, wxSP_LIVE_UPDATE);

	## Inside this splitter is a player/monster/item list, and a dock with map viewer

	my $itemList = $self->{itemList} = new Interface::Wx::ItemList($subSplitter);
	$itemList->onActivate(\&onItemListActivate, $self);
	$self->customizeItemList($itemList) if ($self->can('customizeItemList'));
	$subSplitter->Initialize($itemList);


	# Dock
	my $mapDock = $self->{mapDock} = new Interface::Wx::Dock($subSplitter, -1, 'Map');
	$mapDock->Show(0);
	$mapDock->setHideFunc($self, sub {
		$subSplitter->Unsplit($mapDock);
		$mapDock->Show(0);
		$self->{inputBox}->SetFocus;
	});
	$mapDock->setShowFunc($self, sub {
		$subSplitter->SplitVertically($itemList, $mapDock, -$mapDock->GetBestSize->GetWidth);
		$mapDock->Show(1);
		$self->{inputBox}->SetFocus;
	});

	# Map viewer
	my $mapView = $self->{mapViewer} = new Interface::Wx::MapViewer($mapDock);
	$mapDock->setParentFrame($frame);
	$mapDock->set($mapView);
	$mapView->onMouseMove(\&onMapMouseMove, $self);
	$mapView->onClick(\&onMapClick, $self);
	$mapView->onMapChange(\&onMap_MapChange, $mapDock);
	if (%field && $char) {
		$mapView->set($field{name}, $char->{pos_to}{x}, $char->{pos_to}{y}, \%field);
	}

	$splitter->SplitVertically($notebook, $subSplitter, -150);
}


sub addMenu {
	my ($self, $menu, $label, $callback, $help) = @_;

	$self->{menuIDs}++;
	my $item = new Wx::MenuItem(undef, $self->{menuIDs}, $label, $help);
	$menu->Append($item);
	EVT_MENU($self->{frame}, $self->{menuIDs}, sub { $callback->($self); });
	return $item;
}

sub addCheckMenu {
	my ($self, $menu, $label, $callback, $help) = @_;

	$self->{menuIDs}++;
	my $item = new Wx::MenuItem(undef, $self->{menuIDs}, $label, $help, wxITEM_CHECK);
	$menu->Append($item);
	EVT_MENU($self->{frame}, $self->{menuIDs}, sub { $callback->($self); }) if ($callback);
	return $item;
}


##########################
## INTERFACE UPDATING
##########################


sub updateStatusBar {
	my $self = shift;

	my ($statText, $xyText, $aiText) = ('', '', '');

	if ($self->{loadingFiles}) {
		$statText = sprintf("Loading files... %.0f%%", $self->{loadingFiles}{percent} * 100);
	} elsif (!$conState) {
		$statText = "Initializing...";
	} elsif ($conState == 1) {
		$statText = "Not connected";
	} elsif ($conState > 1 && $conState < 5) {
		$statText = "Connecting...";
	} elsif ($self->{mouseMapText}) {
		$statText = $self->{mouseMapText};
	}

	if ($conState == 5) {
		$xyText = "$char->{pos_to}{x}, $char->{pos_to}{y}";

		if ($AI) {
			if (@ai_seq) {
				my @seqs = @ai_seq;
				foreach (@seqs) {
					s/^route_//;
					s/_/ /g;
					s/([a-z])([A-Z])/$1 $2/g;
					$_ = lc $_;
				}
				substr($seqs[0], 0, 1) = uc substr($seqs[0], 0, 1);
				$aiText = join(', ', @seqs);
			} else {
				$aiText = "";
			}
		} else {
			$aiText = "Paused";
		}
	}

	# Only set status bar text if it has changed
	my $i = 0;
	my $setStatus = sub {
		if (defined $_[1] && $self->{$_[0]} ne $_[1]) {
			$self->{$_[0]} = $_[1];
			$self->{statusbar}->SetStatusText($_[1], $i);
		}
		$i++;
	};

	$setStatus->('statText', $statText);
	$setStatus->('xyText', $xyText);
	$setStatus->('aiText', $aiText);
}

sub updateMapViewer {
	my $self = shift;
	my $map = $self->{mapViewer};
	return unless ($map && %field && $char);

	my $myPos;
	$myPos = calcPosition($char);

	$map->set($field{name}, $myPos->{x}, $myPos->{y}, \%field);
	my $i = AI::findAction("route");
	my $args;
	if (defined $i && ($args = AI::args($i)) && $args->{dest} && $args->{dest}{pos}) {
		$map->setDest($args->{dest}{pos}{x}, $args->{dest}{pos}{y});
	} else {
		$map->setDest;
	}

	my @players = values %players;
	$map->setPlayers(\@players);
	my @monsters = values %monsters;
	$map->setMonsters(\@monsters);
	my @npcs = values %npcs;
	$map->setNPCs(\@npcs);

	$map->update;
	$self->{mapViewTimeout}{time} = time;
}

sub updateItemList {
	my $self = shift;
	if ($conState == 5) {
		$self->{itemList}->set(\@playersID, \%players, \@monstersID, \%monsters,
			\@itemsID, \%items, \@npcsID, \%npcs);
		$self->{hpBar}->SetValue($char->{hp} / $char->{hp_max} * 100) if ($char->{hp_max});
		$self->{spBar}->SetValue($char->{sp} / $char->{sp_max} * 100) if ($char->{sp_max});
		$self->{expBar}->SetValue($char->{exp} / $char->{exp_max} * 100) if ($char->{exp_max});
		$self->{jobExpBar}->SetValue($char->{exp_job} / $char->{exp_job_max} * 100) if ($char->{exp_job_max});
		$self->{weightBar}->SetValue($char->{weight} / $char->{weight_max} * 100) if ($char->{weight_max});
	}
}


##################
## Callbacks
##################


sub onInputEnter {
	my $self = shift;
	my $text = shift;
	my $command;

	my $n = $self->{inputType}->GetSelection;
	if ($n == 0 || $text =~ /^\/(.*)/) {
		my $command = ($n == 0) ? $text : $1;
		$self->{console}->SetDefaultStyle($self->{console}{inputStyle});
		$self->{console}->AppendText("$command\n");
		$self->{console}->SetDefaultStyle($self->{console}{defaultStyle});
		$self->{inputBox}->Remove(0, -1);
		$self->{input} = $command;
		return;
	}

	if ($conState != 5) {
		$self->{console}->add("error", "You're not logged in.\n");
		return;
	}

	if ($self->{targetBox}->GetValue ne "") {
		sendMessage(\$remote_socket, "pm", $text, $self->{targetBox}->GetValue);
	} elsif ($n == 1) { # Public chat
		sendMessage(\$remote_socket, "c", $text);
	} elsif ($n == 2) { # Party chat
		sendMessage(\$remote_socket, "p", $text);
	} else { # Guild chat
		sendMessage(\$remote_socket, "g", $text);
	}
}

sub onMenuOpen {
	my $self = shift;
	$self->{mPause}->Enable($AI);
	$self->{mResume}->Enable(!$AI);
	$self->{infoBarToggle}->Check($self->{infoPanel}->IsShown);
	$self->{chatLogToggle}->Check(defined $self->{notebook}->hasPage('Chat Log') ? 1 : 0);
}

sub onLoadFiles {
	my ($self, $hook, $param) = @_;
	if ($hook eq 'loadfiles') {
		$self->{loadingFiles}{percent} = $param->{current} / scalar(@{$param->{files}});
	} else {
		delete $self->{loadingFiles};
	}
}

sub onEnableAI {
	$AI = 1;
}

sub onDisableAI {
	$AI = 0;
}

sub onMinimizeToTray {
	my $self = shift;
	my $tray = new Wx::TaskBarIcon;
	my $title = ($char) ? "$char->{name} - $Settings::NAME" : "$Settings::NAME";
	$tray->SetIcon(Wx::GetWxPerlIcon, $title);
	EVT_TASKBAR_LEFT_DOWN($tray, sub {
		$tray->RemoveIcon;
		undef $tray;
		$self->{frame}->Show(1);
	});
	$self->{frame}->Show(0);
}

sub onClose {
	my $self = shift;
	$self->Show(0);
	main::quit();
}

sub onFontChange {
	my $self = shift;
	$self->{console}->selectFont($self->{frame});
}

sub onClearConsole {
	my $self = shift;
	$self->{console}->Remove(0, -1);
}

sub onAdvancedConfig {
	my $self = shift;
	if ($self->{notebook}->hasPage('Advanced Configuration')) {
		$self->{notebook}->switchPage('Advanced Configuration');
		return;
	}

	my $page = $self->{notebook}->newPage(1, 'Advanced Configuration');
	my $panel = new Wx::Panel($page, -1);

	my $vsizer = new Wx::BoxSizer(wxVERTICAL);
	$panel->SetSizer($vsizer);

	my $cfg = new Interface::Wx::ConfigEditor($panel, -1);
	$cfg->setConfig(\%config);
#	$cfg->addCategory('Attacks', 'Grid', ['attackAuto', 'attackDistance', 'attackMaxDistance']);
	$cfg->addCategory('All', 'Grid');
	$cfg->onChange(sub {
		my ($key, $value) = @_;
		configModify($key, $value) if ($value ne $config{$key});
	});
	$vsizer->Add($cfg, 1, wxGROW | wxALL, 8);


	my $sizer = new Wx::BoxSizer(wxHORIZONTAL);
	$vsizer->Add($sizer, 0, wxGROW | wxLEFT | wxRIGHT | wxBOTTOM, 8);

	my $revert = new Wx::Button($panel, 46, '&Revert');
	$revert->SetToolTip('Revert settings to before you opened the selected category');
	$sizer->Add($revert, 0);
	EVT_BUTTON($revert, 46, sub {
		$cfg->revert;
	});
	$revert->Enable(0);
	$cfg->onRevertEnable(sub {
		$revert->Enable($_[0]);
	});

	my $pad = new Wx::Window($panel, -1);
	$sizer->Add($pad, 1);

	my $close = new Wx::Button($panel, 47, '&Close');
	$close->SetToolTip('Close this panel/dialog');
	$close->SetDefault;
	$sizer->Add($close, 0);
	EVT_BUTTON($close, 47, sub {
		$self->{notebook}->closePage('Advanced Configuration');
	});

	$page->set($panel);
}

sub onMapToggle {
	my $self = shift;
	$self->{mapDock}->attach;
}

sub onInfoBarToggle {
	my $self = shift;
	$self->{vsizer}->Show($self->{infoPanel}, $self->{infoBarToggle}->IsChecked);
	$self->{frame}->Layout;
}

sub onChatLogToggle {
	my $self = shift;
	if (!$self->{chatLogToggle}->IsChecked) {
		$self->{notebook}->closePage('Chat Log');

	} elsif (!$self->{notebook}->hasPage('Chat Log')) {
		my $page = $self->{notebook}->newPage(1, 'Chat Log', 0);
		my $chatLog = $self->{chatLog} = new Interface::Wx::LogView($page);
		$page->set($chatLog);
		$chatLog->addColor("selfchat", 0, 148, 0);
		$chatLog->addColor("pm", 142, 120, 0);
		$chatLog->addColor("p", 164, 0, 143);
		$chatLog->addColor("g", 0, 177, 108);
		$page->set($chatLog);

	} else {
		$self->{notebook}->switchPage('Chat Log');
	}
}

sub onManual {
	my $self = shift;
	launchURL('http://openkore.sourceforge.net/manual/');
}

sub onForum {
	my $self = shift;
	launchURL('http://openkore.sourceforge.net/forum.php');
}

sub onItemListActivate {
	my $self = shift;
	my $ID = shift;
	my $object = shift;
	my $type = shift;

	if ($type eq 'p' && $players{$ID}) {
		Commands::run("pl " . $players{$ID}{binID});

	} elsif ($type eq 'm' && $monsters{$ID}) {
		main::attack($ID);

	} elsif ($type eq 'i' && $items{$ID}) {
		$self->{console}->add("message", "Taking item $items{$ID}{name} ($items{$ID}{binID})\n", "info");
		main::take($ID);

	} elsif ($type eq 'n' && $npcs{$ID}) {
		Commands::run("nl " . $npcs{$ID}{binID});
	}

	$self->{inputBox}->SetFocus;
}

sub onTargetBoxKeyDown {
	my $self = shift;
	my $event = shift;

	if ($event->GetKeyCode == WXK_TAB && !$event->ShiftDown) {
		$self->{inputBox}->SetFocus;

	} else {
		$event->Skip;
	}
}

sub onAddPrivMsgUser {
	my $self = shift;
	my $param = $_[1];
	$self->{targetBox}->Append($param->{user});
}

sub onChatAdd {
	my ($self, $hook, $params) = @_;

	return if (!$self->{notebook}->hasPage('Chat Log'));
	if ($hook eq "ChatQueue::add" && $params->{type} ne "pm") {
		my $msg = '';
		if ($params->{type} ne "c") {
			$msg = "[$params->{type}] ";
		}
		$msg .= "$params->{user} : $params->{msg}\n";
		$self->{chatLog}->add($msg, $params->{type});

	} elsif ($hook eq "packet_selfChat") {
		$self->{chatLog}->add("$params->{user} : $params->{msg}\n", "selfchat");
	} elsif ($hook eq "packet_privMsg") {
		$self->{chatLog}->add("(From: $params->{privMsgUser}) : $params->{privMsg}\n", "pm");
	} elsif ($hook eq "packet_sentPM") {
		$self->{chatLog}->add("(To: $params->{to}) : $params->{msg}\n", "pm");
	}
}

sub onMapMouseMove {
	# Mouse moved over the map viewer control
	my ($self, $x, $y) = @_;
	my $walkable;

	$walkable = checkFieldWalkable(\%field, $x, $y);
	if ($x >= 0 && $y >= 0 && $walkable) {
		$self->{mouseMapText} = "Mouse over: $x, $y";
	} else {
		delete $self->{mouseMapText};
	}
	$self->{statusbar}->SetStatusText($self->{mouseMapText}, 0);
}

sub onMapClick {
	# Clicked on map viewer control
	my ($self, $x, $y) = @_;
	delete $self->{mouseMapText};
	$self->writeOutput("message", "Moving to $x, $y\n", "info");
	AI::clear("mapRoute", "route", "move");
	main::ai_route($field{name}, $x, $y, attackOnRoute => 1);
	$self->{inputBox}->SetFocus;
}

sub onMap_MapChange {
	my ($mapDock) = @_;
	$mapDock->title($field{name});
	$mapDock->Fit;
}

1;
