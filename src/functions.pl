# To run kore, execute openkore.pl instead.

#########################################################################
# This software is open source, licensed under the GNU General Public
# License, version 2.
# Basically, this means that you're allowed to modify and distribute
# this software. However, if you distribute modified versions, you MUST
# also distribute the source code.
# See http://www.gnu.org/licenses/gpl.html for the full license.
#########################################################################

use Time::HiRes qw(time usleep);
use IO::Socket;
use Config;

use Globals;
use Modules;
use Settings;
use Log qw(message warning error debug);
use FileParsers;
use Interface;
use Network;
use Network::Send;
use Commands;
use Misc;
use Plugins;
use Utils;

# PORTAL_PENALTY is used by the map router for calculating the cost of walking through a portal.
# Best values are:
# 0 : favors a minimum step count solutions (ie distance to walk)
# 10000 (or infinity): favors a minimum map count solutions (if you dont like walking through portals)
use constant PORTAL_PENALTY => 0;


#######################################
#INITIALIZE VARIABLES
#######################################

# Calculate next random restart time.
# The restart time will be autoRestartMin + rand(autoRestartSeed)
sub initRandomRestart {
	if ($config{'autoRestart'}) {
		my $autoRestart = $config{'autoRestartMin'} + int(rand $config{'autoRestartSeed'});
		message "Next restart in ".timeConvert($autoRestart).".\n", "system";
		configModify("autoRestart", $autoRestart, 1);
	}
}

# Initialize random configuration switching time
sub initConfChange {
	my $changetime = $config{'autoConfChange_min'} + rand($config{'autoConfChange_seed'});
	return if (!$config{'autoConfChange'});
	$nextConfChangeTime = time + $changetime;
	message "Next Config Change will be in ".timeConvert($changetime).".\n", "system";
}

# Initialize variables when you start a connection to a map server
sub initConnectVars {
	initMapChangeVars();
	undef @{$chars[$config{'char'}]{'inventory'}};
	undef %{$chars[$config{'char'}]{'skills'}};
	undef @skillsID;
}

# Initialize variables when you change map (after a teleport or after you walked into a portal)
sub initMapChangeVars {
	@portalsID_old = @portalsID;
	%portals_old = %portals;
	%{$chars_old[$config{'char'}]{'pos_to'}} = %{$chars[$config{'char'}]{'pos_to'}};
	undef $chars[$config{'char'}]{'sitting'};
	undef $chars[$config{'char'}]{'dead'};
	undef $chars[$config{'char'}]{'warp'};
	$timeout{'play'}{'time'} = time;
	$timeout{'ai_sync'}{'time'} = time;
	$timeout{'ai_sit_idle'}{'time'} = time;
	$timeout{'ai_teleport_idle'}{'time'} = time;
	$timeout{'ai_teleport_search'}{'time'} = time;
	$timeout{'ai_teleport_safe_force'}{'time'} = time;
	undef %incomingDeal;
	undef %outgoingDeal;
	undef %currentDeal;
	undef $currentChatRoom;
	undef @currentChatRoomUsers;
	undef @playersID;
	undef @monstersID;
	undef @portalsID;
	undef @itemsID;
	undef @npcsID;
	undef @identifyID;
	undef @spellsID;
	undef @petsID;
	undef %players;
	undef %monsters;
	undef %portals;
	undef %items;
	undef %npcs;
	undef %spells;
	undef %incomingParty;
	undef $msg;
	undef %talk;
	undef %{$ai_v{'temp'}};
	undef @{$cart{'inventory'}};
	undef @venderItemList;
	undef $venderID;
	undef @venderListsID;
	undef %venderLists;
	undef %guild;
	undef %incomingGuild;

	$shopstarted = 0;
	$timeout{'ai_shop'}{'time'} = time;

	initOtherVars();
}

# Initialize variables when your character logs in
sub initStatVars {
	$totaldmg = 0;
	$dmgpsec = 0;
	$startedattack = 0;
	$monstarttime = 0;
	$monkilltime = 0;
	$elasped = 0;
	$totalelasped = 0;
}

sub initOtherVars {
	# chat response stuff
	undef $nextresptime;
	undef $nextrespPMtime;
}


#######################################
#######################################
#Check Connection
#######################################
#######################################


# $conState contains the connection state:
# 1: Not connected to anything		(next step -> connect to master server).
# 2: Connected to master server		(next step -> connect to login server)
# 3: Connected to login server		(next step -> connect to character server)
# 4: Connected to character server	(next step -> connect to map server)
# 5: Connected to map server; ready and functional.
sub checkConnection {
	return if ($config{'XKore'});

	if ($conState == 1 && !($remote_socket && $remote_socket->connected()) && timeOut(\%{$timeout_ex{'master'}}) && !$conState_tries) {
		message("Connecting to Master Server...\n", "connection");
		$shopstarted = 1;
		$conState_tries++;
		undef $msg;
		Network::connectTo(\$remote_socket, $config{"master_host_$config{'master'}"}, $config{"master_port_$config{'master'}"});

		if ($config{'secureLogin'} >= 1) {
			message("Secure Login...\n", "connection");
			undef $secureLoginKey;
			sendMasterCodeRequest(\$remote_socket,$config{'secureLogin_type'});
		} else {
			sendMasterLogin(\$remote_socket, $config{'username'}, $config{'password'});
		}

		$timeout{'master'}{'time'} = time;

	} elsif ($conState == 1 && $config{'secureLogin'} >= 1 && $secureLoginKey ne "" && !timeOut(\%{$timeout{'master'}}) 
			  && $conState_tries) {

		message("Sending encoded password...\n", "connection");
		sendMasterSecureLogin(\$remote_socket, $config{'username'}, $config{'password'},$secureLoginKey,
						$config{'version'},$config{"master_version_$config{'master'}"},
						$config{'secureLogin'},$config{'secureLogin_account'});
		undef $secureLoginKey;

	} elsif ($conState == 1 && timeOut(\%{$timeout{'master'}}) && timeOut(\%{$timeout_ex{'master'}})) {
		error "Timeout on Master Server, reconnecting...\n", "connection";
		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		Network::disconnect(\$remote_socket);
		undef $conState_tries;

	} elsif ($conState == 2 && !($remote_socket && $remote_socket->connected()) && $config{'server'} ne "" && !$conState_tries) {
		message("Connecting to Game Login Server...\n", "connection");
		$conState_tries++;
		Network::connectTo(\$remote_socket, $servers[$config{'server'}]{'ip'}, $servers[$config{'server'}]{'port'});
		sendGameLogin(\$remote_socket, $accountID, $sessionID, $accountSex);
		$timeout{'gamelogin'}{'time'} = time;

	} elsif ($conState == 2 && timeOut(\%{$timeout{'gamelogin'}}) && $config{'server'} ne "") {
		error "Timeout on Game Login Server, reconnecting...\n", "connection";
		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		Network::disconnect(\$remote_socket);
		undef $conState_tries;
		$conState = 1;

	} elsif ($conState == 3 && !($remote_socket && $remote_socket->connected()) && $config{'char'} ne "" && !$conState_tries) {
		message("Connecting to Character Select Server...\n", "connection");
		$conState_tries++;
		Network::connectTo(\$remote_socket, $servers[$config{'server'}]{'ip'}, $servers[$config{'server'}]{'port'});
		sendCharLogin(\$remote_socket, $config{'char'});
		$timeout{'charlogin'}{'time'} = time;

	} elsif ($conState == 3 && timeOut(\%{$timeout{'charlogin'}}) && $config{'char'} ne "") {
		error "Timeout on Character Select Server, reconnecting...\n", "connection";
		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		Network::disconnect(\$remote_socket);
		$conState = 1;
		undef $conState_tries;

	} elsif ($conState == 4 && !($remote_socket && $remote_socket->connected()) && !$conState_tries) {
		message("Connecting to Map Server...\n", "connection");
		$conState_tries++;
		initConnectVars();
		Network::connectTo(\$remote_socket, $map_ip, $map_port);
		sendMapLogin(\$remote_socket, $accountID, $charID, $sessionID, $accountSex2);
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		$timeout{'maplogin'}{'time'} = time;

	} elsif ($conState == 4 && timeOut(\%{$timeout{'maplogin'}})) {
		message("Timeout on Map Server, connecting to Master Server...\n", "connection");
		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		Network::disconnect(\$remote_socket);
		$conState = 1;
		undef $conState_tries;

	} elsif ($conState == 5 && !($remote_socket && $remote_socket->connected())) {
		$conState = 1;
		undef $conState_tries;

	} elsif ($conState == 5 && timeOut(\%{$timeout{'play'}})) {
		error "Timeout on Map Server, connecting to Master Server...\n", "connection";
		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		Network::disconnect(\$remote_socket);
		$conState = 1;
		undef $conState_tries;
	}
}

# Misc. main loop code
sub mainLoop {
	Plugins::callHook('mainLoop_pre');

	if ($config{'autoRestart'} && time - $KoreStartTime > $config{'autoRestart'}
	 && $conState == 5 && $ai_seq[0] ne "attack" && $ai_seq[0] ne "take") {
		message "\nAuto-restarting!!\n", "system";

		if ($config{'autoRestartSleep'}) {
			my $sleeptime = $config{'autoSleepMin'} + int(rand $config{'autoSleepSeed'});
			$timeout_ex{'master'}{'timeout'} = $sleeptime;
			$sleeptime = $timeout{'reconnect'}{'timeout'} if ($sleeptime < $timeout{'reconnect'}{'timeout'});
			message "Sleeping for ".timeConvert($sleeptime).".\n", "system";
		} else {
			$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		}

		$timeout_ex{'master'}{'time'} = time;
		$KoreStartTime = time + $timeout_ex{'master'}{'timeout'};
		Network::disconnect(\$remote_socket);
		$conState = 1;
		undef $conState_tries;
		initRandomRestart();
	}

	# Automatically switch to a different config file after a while
	if ($config{'autoConfChange'} && $config{'autoConfChange_files'} && $conState == 5
	 && time >= $nextConfChangeTime && $ai_seq[0] ne "attack" && $ai_seq[0] ne "take") {
	 	my ($file, @files);
	 	my ($oldMasterHost, $oldMasterPort, $oldUsername, $oldChar);

		# Choose random config file
		@files = split(/ /, $config{'autoConfChange_files'});
		$file = @files[rand(@files)];
		message "Changing configuration file (from \"$Settings::config_file\" to \"$file\")...\n", "system";

		# A relogin is necessary if the host/port, username or char is different
		$oldMasterHost = $config{"master_host_$config{'master'}"};
		$oldMasterPort = $config{"master_port_$config{'master'}"};
		$oldUsername = $config{'username'};
		$oldChar = $config{'char'};

		foreach (@Settings::configFiles) {
			if ($_->{file} eq $Settings::config_file) {
				$_->{file} = $file;
				last;
			}
		}
		$Settings::config_file = $file;
		parseDataFile2($file, \%config);

		if ($oldMasterHost ne $config{"master_host_$config{'master'}"}
		 || $oldMasterPort ne $config{"master_port_$config{'master'}"}
		 || $oldUsername ne $config{'username'}
		 || $oldChar ne $config{'char'}) {
			relog();
		} else {
			aiRemove("move");
			aiRemove("route");
			aiRemove("mapRoute");
		}

		initConfChange();
	}

	Plugins::callHook('mainLoop_post');
}


#######################################
#PARSE INPUT
#######################################


sub parseInput {
	my $input = shift;
	my $printType;
	my ($hook, $msg);
	$printType = shift if ($config{'XKore'});

	debug("Input: $input\n", "parseInput", 2);

	if ($printType) {
		my $hookOutput = sub {
			my ($type, $domain, $level, $globalVerbosity, $message, $user_data) = @_;
			$msg .= $message if ($type ne 'debug' && $level <= $globalVerbosity);
		};
		$hook = Log::addHook($hookOutput);
		$interface->writeOutput("console", "$input\n");
	}
	$XKore_dontRedirect = 1 if ($config{XKore});

	# Check if in special state
	if (!$config{'XKore'} && $conState == 2 && $waitingForInput) {
		configModify('server', $input, 1);
		$waitingForInput = 0;

	} elsif (!$config{'XKore'} && $conState == 3 && $waitingForInput) {
		configModify('char', $input, 1);
		$waitingForInput = 0;
		sendCharLogin(\$remote_socket, $config{'char'});
		$timeout{'charlogin'}{'time'} = time;

	} else {
		Commands::run($input) || parseCommand($input);
	}

	if ($printType) {
		Log::delHook($hook);
		if ($config{'XKore'} && defined $msg && $conState == 5) {
			$msg =~ s/\n*$//s;
			$msg =~ s/\n/\\n/g;
			sendMessage(\$remote_socket, "k", $msg);
		}
	}
	$XKore_dontRedirect = 0 if ($config{XKore});
}

sub parseCommand {
	my $input = shift;

	my ($switch, $args) = split(' ', $input, 2);
	my ($arg1, $arg2, $arg3, $arg4);

	# Resolve command aliases
	if (my $alias = $config{"alias_$switch"}) {
		$input = $alias;
		$input .= " $args" if defined $args;
		($switch, $args) = split(' ', $input, 2);
	}

	if ($switch eq "a") {
		($arg1) = $input =~ /^[\s\S]*? (\w+)/;
		($arg2) = $input =~ /^[\s\S]*? [\s\S]*? (\d+)/;
		if ($arg1 =~ /^\d+$/ && $monstersID[$arg1] eq "") {
			error	"Error in function 'a' (Attack Monster)\n" .
				"Monster $arg1 does not exist.\n";
		} elsif ($arg1 =~ /^\d+$/) {
			$monsters{$monstersID[$arg1]}{'attackedByPlayer'} = 0;
			attack($monstersID[$arg1]);

		} elsif ($arg1 eq "no") {
			configModify("attackAuto", 1);
		
		} elsif ($arg1 eq "yes") {
			configModify("attackAuto", 2);

		} else {
			error	"Syntax Error in function 'a' (Attack Monster)\n" .
				"Usage: attack <monster # | no | yes >\n";
		}

	} elsif ($switch eq "al") {
		message("----------Items being sold in store------------\n", "list");
		message("#  Name                                     Type         Qty     Price   Sold\n", "list");

		my $i = 1;
		for ($number = 0; $number < @articles; $number++) {
			next if ($articles[$number] eq "");
			my $display = $articles[$number]{'name'};
			if (!($articles[$number]{'identified'})) {
				$display = $display." -- Not Identified";
			}
			if ($articles[$number]{'card1'}) {
				$display = $display."[".$cards_lut{$articles[$number]{'card1'}}."]";
			}
			if ($articles[$number]{'card2'}) {
				$display = $display."[".$cards_lut{$articles[$number]{'card2'}}."]";
			}
			if ($articles[$number]{'card3'}) {
				$display = $display."[".$cards_lut{$articles[$number]{'card3'}}."]";
			}
			if ($articles[$number]{'card4'}) {
				$display = $display."[".$cards_lut{$articles[$number]{'card4'}}."]";
			}

			message(swrite(
				"@< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<< @>>> @>>>>>>>z @>>>>>",
				[$i, $display, $itemTypes_lut{$articles[$number]{'type'}}, $articles[$number]{'quantity'}, $articles[$number]{'price'}, $articles[$number]{'sold'}]),
				"list");
			$i++;
		}
		message("----------------------------------------------\n", "list");
		message("You have earned " . formatNumber($shopEarned) . "z.\n", "list");

	} elsif ($switch eq "as") {
		# Stop attacking monster
		my $index = binFind(\@ai_seq, "attack");
		if ($index ne "") {
			$monsters{$ai_seq_args[$index]{'ID'}}{'ignore'} = 1;
			sendAttackStop(\$remote_socket);
			message "Stopped attacking $monsters{$ai_seq_args[$index]{'ID'}}{'name'} ($monsters{$ai_seq_args[$index]{'ID'}}{'binID'})\n", "success";
			aiRemove("attack");
		}

	} elsif ($switch eq "autobuy") {
		unshift @ai_seq, "buyAuto";
		unshift @ai_seq_args, {};

	} elsif ($switch eq "autosell") {
		unshift @ai_seq, "sellAuto";
		unshift @ai_seq_args, {};

	} elsif ($switch eq "autostorage") {
		unshift @ai_seq, "storageAuto";
		unshift @ai_seq_args, {};

	} elsif ($switch eq "itemexchange") {
		unshift @ai_seq, "itemExchange";
		unshift @ai_seq_args, {};

	} elsif ($switch eq "c") {
		($arg1) = $input =~ /^[\s\S]*? ([\s\S]*)/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'c' (Chat)\n" .
				"Usage: c <message>\n";
		} else {
			sendMessage(\$remote_socket, "c", $arg1);
		}

	#Cart command - chobit andy 20030101
	} elsif ($switch eq "cart") {
		($arg1) = $input =~ /^[\s\S]*? (\w+)/;
		($arg2) = $input =~ /^[\s\S]*? \w+ (\d+)/;
		($arg3) = $input =~ /^[\s\S]*? \w+ \d+ (\d+)/;
		if ($arg1 eq "") {
			message("-------------Cart--------------\n" .
				"#  Name\n", "list");

			for (my $i = 0; $i < @{$cart{'inventory'}}; $i++) {
				next if (!%{$cart{'inventory'}[$i]});
				$display = "$cart{'inventory'}[$i]{'name'} x $cart{'inventory'}[$i]{'amount'}";
				message(sprintf("%-2d %-34s\n", $i, $display), "list");
			}
			message("\nCapacity: " . int($cart{'items'}) . "/" . int($cart{'items_max'}) . "  Weight: " . int($cart{'weight'}) . "/" . int($cart{'weight_max'}) . "\n", "list");
			message("-------------------------------\n", "list");

		} elsif ($arg1 eq "add" && $arg2 =~ /\d+/ && $chars[$config{'char'}]{'inventory'}[$arg2] eq "") {
			error	"Error in function 'cart add' (Add Item to Cart)\n" .
				"Inventory Item $arg2 does not exist.\n";
		} elsif ($arg1 eq "add" && $arg2 =~ /\d+/) {
			if (!$arg3 || $arg3 > $chars[$config{'char'}]{'inventory'}[$arg2]{'amount'}) {
				$arg3 = $chars[$config{'char'}]{'inventory'}[$arg2]{'amount'};
			}
			sendCartAdd(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$arg2]{'index'}, $arg3);
		} elsif ($arg1 eq "add" && $arg2 eq "") {
			error	"Syntax Error in function 'cart add' (Add Item to Cart)\n" .
				"Usage: cart add <item #>\n";
		} elsif ($arg1 eq "get" && $arg2 =~ /\d+/ && !%{$cart{'inventory'}[$arg2]}) {
			error	"Error in function 'cart get' (Get Item from Cart)\n" .
				"Cart Item $arg2 does not exist.\n";
		} elsif ($arg1 eq "get" && $arg2 =~ /\d+/) {
			if (!$arg3 || $arg3 > $cart{'inventory'}[$arg2]{'amount'}) {
				$arg3 = $cart{'inventory'}[$arg2]{'amount'};
			}
			sendCartGet(\$remote_socket, $arg2, $arg3);
		} elsif ($arg1 eq "get" && $arg2 eq "") {
			error	"Syntax Error in function 'cart get' (Get Item from Cart)\n" .
				"Usage: cart get <cart item #>\n";

		} elsif ($arg1 eq "desc" && $arg2 =~ /\d+/) {
			printItemDesc($cart{'inventory'}[$arg2]{'nameID'});
		}

	} elsif ($switch eq "chat") {
		my ($replace, $title) = $input =~ /(^[\s\S]*? \"([\s\S]*?)\" ?)/;
		my $qm = quotemeta $replace;
		my $input =~ s/$qm//;
		my @arg = split / /, $input;
		if ($title eq "") {
			error	"Syntax Error in function 'chat' (Create Chat Room)\n" .
				"Usage: chat \"<title>\" [<limit #> <public flag> <password>]\n";
		} elsif ($currentChatRoom ne "") {
			error	"Error in function 'chat' (Create Chat Room)\n" .
				"You are already in a chat room.\n";
		} else {
			if ($arg[0] eq "") {
				$arg[0] = 20;
			}
			if ($arg[1] eq "") {
				$arg[1] = 1;
			}
			sendChatRoomCreate(\$remote_socket, $title, $arg[0], $arg[1], $arg[2]);
			$createdChatRoom{'title'} = $title;
			$createdChatRoom{'ownerID'} = $accountID;
			$createdChatRoom{'limit'} = $arg[0];
			$createdChatRoom{'public'} = $arg[1];
			$createdChatRoom{'num_users'} = 1;
			$createdChatRoom{'users'}{$chars[$config{'char'}]{'name'}} = 2;
		}

	} elsif ($switch eq "cil") { 
		itemLog_clear();
		message("Item log cleared.\n", "success");

	} elsif ($switch eq "cl") { 
		chatLog_clear();
		message("Chat log cleared.\n", "success");

	#non-functional item count code
	} elsif ($switch eq "icount") {
		message("-[ Item Count ]--------------------------------\n", "list");
		message("#   ID   Name                Count\n", "list");
		my $i = 0;
		while ($pickup_count[$i]) {
			message(swrite(
				"@<< @<<<< @<<<<<<<<<<<<<       @<<<",
				[$i, $pickup_count[$i]{'nameID'}, $pickup_count[$i]{'name'}, $pickup_count[$i]{'count'}]),
				"list");
			$i++;
		}
		message("--------------------------------------------------\n", "list");
	#end of non-functional item count code

	} elsif ($switch eq "cri") {
		if ($currentChatRoom eq "") {
			error "There is no chat room info - you are not in a chat room\n";
		} else {
			message("-----------Chat Room Info-----------\n" .
				"Title                     Users   Public/Private\n",
				"list");
			my $public_string = ($chatRooms{$currentChatRoom}{'public'}) ? "Public" : "Private";
			my $limit_string = $chatRooms{$currentChatRoom}{'num_users'}."/".$chatRooms{$currentChatRoom}{'limit'};

			message(swrite(
				"@<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<< @<<<<<<<<<",
				[$chatRooms{$currentChatRoom}{'title'}, $limit_string, $public_string]),
				"list");

			message("-- Users --\n", "list");
			for (my $i = 0; $i < @currentChatRoomUsers; $i++) {
				next if ($currentChatRoomUsers[$i] eq "");
				my $user_string = $currentChatRoomUsers[$i];
				my $admin_string = ($chatRooms{$currentChatRoom}{'users'}{$currentChatRoomUsers[$i]} > 1) ? "(Admin)" : "";
				message(swrite(
					"@<< @<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<",
					[$i, $user_string, $admin_string]),
					"list");
			}
			message("------------------------------------\n", "list");
		}

	} elsif ($switch eq "crl") {
		message("-----------Chat Room List-----------\n" .
			"#   Title                     Owner                Users   Public/Private\n",
			"list");
		for (my $i = 0; $i < @chatRoomsID; $i++) {
			next if ($chatRoomsID[$i] eq "");
			my $owner_string = ($chatRooms{$chatRoomsID[$i]}{'ownerID'} ne $accountID) ? $players{$chatRooms{$chatRoomsID[$i]}{'ownerID'}}{'name'} : $chars[$config{'char'}]{'name'};
			my $public_string = ($chatRooms{$chatRoomsID[$i]}{'public'}) ? "Public" : "Private";
			my $limit_string = $chatRooms{$chatRoomsID[$i]}{'num_users'}."/".$chatRooms{$chatRoomsID[$i]}{'limit'};
			message(swrite(
				"@<< @<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<          @<<<<<< @<<<<<<<<<",
				[$i, $chatRooms{$chatRoomsID[$i]}{'title'}, $owner_string, $limit_string, $public_string]),
				"list");
		}
		message("------------------------------------\n", "list");

	} elsif ($switch eq "vl") {
		message("-----------Vender List-----------\n" .
			"#   Title                                Owner\n",
			"list");
		for (my $i = 0; $i < @venderListsID; $i++) {
			next if ($venderListsID[$i] eq "");
			my $owner_string = ($venderListsID[$i] ne $accountID) ? $players{$venderListsID[$i]}{'name'} : $chars[$config{'char'}]{'name'};
			message(swrite(
				"@<< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<<<<<<<<<",
				[$i, $venderLists{$venderListsID[$i]}{'title'}, $owner_string]),
				"list");
		}
		message("----------------------------------\n", "list");

	} elsif ($switch eq "vender") {
		($arg1) = $input =~ /^.*? (\d+)/;
		($arg2) = $input =~ /^.*? \d+ (\d+)/;
		($arg3) = $input =~ /^.*? \d+ \d+ (\d+)/;
		if ($arg1 eq "") {
			error	"Error in function 'vender' (Vender Shop)\n" .
				"Usage: vender <vender # | end> [<item #> <amount>]\n";
		} elsif ($arg1 eq "end") {
			undef @venderItemList;
			undef $venderID;
		} elsif ($venderListsID[$arg1] eq "") {
			error	"Error in function 'vender' (Vender Shop)\n" .
				"Vender $arg1 does not exist.\n";
		} elsif ($arg2 eq "") {
			sendEnteringVender(\$remote_socket, $venderListsID[$arg1]);
		} elsif ($venderListsID[$arg1] ne $venderID) {
			error	"Error in function 'vender' (Vender Shop)\n" .
				"Vender ID is wrong.\n";
		} else {
			if ($arg3 <= 0) {
				$arg3 = 1;
			}
			sendBuyVender(\$remote_socket, $venderID, $arg2, $arg3);
		}

	} elsif ($switch eq "deal") {
		@arg = split / /, $input;
		shift @arg;
		if (%currentDeal && $arg[0] =~ /\d+/) {
			error	"Error in function 'deal' (Deal a Player)\n" .
				"You are already in a deal\n";
		} elsif (%incomingDeal && $arg[0] =~ /\d+/) {
			error	"Error in function 'deal' (Deal a Player)\n" .
				"You must first cancel the incoming deal\n";
		} elsif ($arg[0] =~ /\d+/ && !$playersID[$arg[0]]) {
			error	"Error in function 'deal' (Deal a Player)\n" .
				"Player $arg[0] does not exist\n";
		} elsif ($arg[0] =~ /\d+/) {
			$outgoingDeal{'ID'} = $playersID[$arg[0]];
			sendDeal(\$remote_socket, $playersID[$arg[0]]);


		} elsif ($arg[0] eq "no" && !%incomingDeal && !%outgoingDeal && !%currentDeal) {
			error	"Error in function 'deal' (Deal a Player)\n" .
				"There is no incoming/current deal to cancel\n";
		} elsif ($arg[0] eq "no" && (%incomingDeal || %outgoingDeal)) {
			sendDealCancel(\$remote_socket);
		} elsif ($arg[0] eq "no" && %currentDeal) {
			sendCurrentDealCancel(\$remote_socket);


		} elsif ($arg[0] eq "" && !%incomingDeal && !%currentDeal) {
			error	"Error in function 'deal' (Deal a Player)\n" .
				"There is no deal to accept\n";
		} elsif ($arg[0] eq "" && $currentDeal{'you_finalize'} && !$currentDeal{'other_finalize'}) {
			error	"Error in function 'deal' (Deal a Player)\n" .
				"Cannot make the trade - $currentDeal{'name'} has not finalized\n";
		} elsif ($arg[0] eq "" && $currentDeal{'final'}) {
			error	"Error in function 'deal' (Deal a Player)\n" .
				"You already accepted the final deal\n";
		} elsif ($arg[0] eq "" && %incomingDeal) {
			sendDealAccept(\$remote_socket);
		} elsif ($arg[0] eq "" && $currentDeal{'you_finalize'} && $currentDeal{'other_finalize'}) {
			sendDealTrade(\$remote_socket);
			$currentDeal{'final'} = 1;
			message("You accepted the final Deal\n", "deal");
		} elsif ($arg[0] eq "" && %currentDeal) {
			sendDealAddItem(\$remote_socket, 0, $currentDeal{'you_zenny'});
			sendDealFinalize(\$remote_socket);
			

		} elsif ($arg[0] eq "add" && !%currentDeal) {
			error	"Error in function 'deal_add' (Add Item to Deal)\n" .
				"No deal in progress\n";
		} elsif ($arg[0] eq "add" && $currentDeal{'you_finalize'}) {
			error	"Error in function 'deal_add' (Add Item to Deal)\n" .
				"Can't add any Items - You already finalized the deal\n";
		} elsif ($arg[0] eq "add" && $arg[1] =~ /\d+/ && !%{$chars[$config{'char'}]{'inventory'}[$arg[1]]}) {
			error	"Error in function 'deal_add' (Add Item to Deal)\n" .
				"Inventory Item $arg[1] does not exist.\n";
		} elsif ($arg[0] eq "add" && $arg[2] && $arg[2] !~ /\d+/) {
			error	"Error in function 'deal_add' (Add Item to Deal)\n" .
				"Amount must either be a number, or not specified.\n";
		} elsif ($arg[0] eq "add" && $arg[1] =~ /\d+/) {
			if (scalar(keys %{$currentDeal{'you'}}) < 10) {
				if (!$arg[2] || $arg[2] > $chars[$config{'char'}]{'inventory'}[$arg[1]]{'amount'}) {
					$arg[2] = $chars[$config{'char'}]{'inventory'}[$arg[1]]{'amount'};
				}
				$currentDeal{'lastItemAmount'} = $arg[2];
				sendDealAddItem(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$arg[1]]{'index'}, $arg[2]);
			} else {
				error("You can't add any more items to the deal\n", "deal");
			}
		} elsif ($arg[0] eq "add" && $arg[1] eq "z") {
			if (!$arg[2] || $arg[2] > $chars[$config{'char'}]{'zenny'}) {
				$arg[2] = $chars[$config{'char'}]{'zenny'};
			}
			$currentDeal{'you_zenny'} = $arg[2];
			message("You put forward $arg[2] z to Deal\n", "deal");

		} else {
			error	"Syntax Error in function 'deal' (Deal a player)\n" .
				"Usage: deal [<Player # | no | add>] [<item #>] [<amount>]\n";
		}

	} elsif ($switch eq "dl") {
		if (!%currentDeal) {
			error "There is no deal list - You are not in a deal\n";

		} else {
			message("-----------Current Deal-----------\n", "list");
			my $other_string = $currentDeal{'name'};
			my $you_string = "You";
			if ($currentDeal{'other_finalize'}) {
				$other_string .= " - Finalized";
			}
			if ($currentDeal{'you_finalize'}) {
				$you_string .= " - Finalized";
			}

			message(swrite(
				"@<<<<<<<<<<<<<<<<<<<<<<<<<<<<<   @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<",
				[$you_string, $other_string]),
				"list");

			undef @currentDealYou;
			undef @currentDealOther;
			foreach (keys %{$currentDeal{'you'}}) {
				push @currentDealYou, $_;
			}
			foreach (keys %{$currentDeal{'other'}}) {
				push @currentDealOther, $_;
			}

			my ($lastindex, $display);
			$lastindex = @currentDealOther;
			$lastindex = @currentDealYou if (@currentDealYou > $lastindex);
			for (my $i = 0; $i < $lastindex; $i++) {
				if ($i < @currentDealYou) {
					$display = ($items_lut{$currentDealYou[$i]} ne "") 
						? $items_lut{$currentDealYou[$i]}
						: "Unknown ".$currentDealYou[$i];
					$display .= " x $currentDeal{'you'}{$currentDealYou[$i]}{'amount'}";
				} else {
					$display = "";
				}
				if ($i < @currentDealOther) {
					$display2 = ($items_lut{$currentDealOther[$i]} ne "") 
						? $items_lut{$currentDealOther[$i]}
						: "Unknown ".$currentDealOther[$i];
					$display2 .= " x $currentDeal{'other'}{$currentDealOther[$i]}{'amount'}";
				} else {
					$display2 = "";
				}

				message(swrite(
					"@<<<<<<<<<<<<<<<<<<<<<<<<<<<<<   @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<",
					[$display, $display2]),
					"list");
			}
			$you_string = ($currentDeal{'you_zenny'} ne "") ? $currentDeal{'you_zenny'} : 0;
			$other_string = ($currentDeal{'other_zenny'} ne "") ? $currentDeal{'other_zenny'} : 0;

			message(swrite(
				"Zenny: @<<<<<<<<<<<<<            Zenny: @<<<<<<<<<<<<<",
				[$you_string, $other_string]),
				"list");
			message("----------------------------------\n", "list");
		}


	} elsif ($switch eq "drop") {
		($arg1) = $input =~ /^[\s\S]*? ([\d,-]+)/;
		($arg2) = $input =~ /^[\s\S]*? [\d,-]+ (\d+)$/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'drop' (Drop Inventory Item)\n" .
				"Usage: drop <item #> [<amount>]\n";
		} elsif (!%{$chars[$config{'char'}]{'inventory'}[$arg1]}) {
			error	"Error in function 'drop' (Drop Inventory Item)\n" .
				"Inventory Item $arg1 does not exist.\n";
		} else {
			my @temp = split(/,/, $arg1);
			@temp = grep(!/^$/, @temp); # Remove empty entries

			my @items = ();
			foreach (@temp) {
				if (/(\d+)-(\d+)/) {
					for ($1..$2) {
						push(@items, $_) if (%{$chars[$config{'char'}]{'inventory'}[$_]});
					}
				} else {
					push @items, $_;
				}
			}
			ai_drop(\@items, $arg2);
		}

	} elsif ($switch eq "dump") {
		dumpData($msg);
		quit();

	} elsif ($switch eq "dumpnow") {
		dumpData($msg);

	} elsif ($switch eq "exp" || $switch eq "count") {
		# exp report
		($arg1) = $input =~ /^[\s\S]*? (\w+)/;
		if ($arg1 eq ""){
			my ($endTime_EXP,$w_sec,$total,$bExpPerHour,$jExpPerHour,$EstB_sec,$EstB_sec,$percentB,$percentJ,$zennyMade,$zennyPerHour);
			$endTime_EXP = time;
			$w_sec = int($endTime_EXP - $startTime_EXP);
			if ($w_sec > 0) {
				$zennyMade = $chars[$config{'char'}]{'zenny'} - $startingZenny;
				$bExpPerHour = int($totalBaseExp / $w_sec * 3600);
				$jExpPerHour = int($totalJobExp / $w_sec * 3600);
				$zennyPerHour = int($zennyMade / $w_sec * 3600);
				if ($chars[$config{'char'}]{'exp_max'} && $bExpPerHour){
					$percentB = "(".sprintf("%.2f",$totalBaseExp * 100 / $chars[$config{'char'}]{'exp_max'})."%)";
					$EstB_sec = int(($chars[$config{'char'}]{'exp_max'} - $chars[$config{'char'}]{'exp'})/($bExpPerHour/3600));
				}
				if ($chars[$config{'char'}]{'exp_job_max'} && $jExpPerHour){
					$percentJ = "(".sprintf("%.2f",$totalJobExp * 100 / $chars[$config{'char'}]{'exp_job_max'})."%)";
					$EstJ_sec = int(($chars[$config{'char'}]{'exp_job_max'} - $chars[$config{'char'}]{'exp_job'})/($jExpPerHour/3600));
				}
			}
			$chars[$config{'char'}]{'deathCount'} = 0 if (!defined $chars[$config{'char'}]{'deathCount'});
			message("------------Exp Report------------\n" .
			"Botting time : " . timeConvert($w_sec) . "\n" .
			"BaseExp      : " . formatNumber($totalBaseExp) . " $percentB\n" .
			"JobExp       : " . formatNumber($totalJobExp) . " $percentJ\n" .
			"BaseExp/Hour : " . formatNumber($bExpPerHour) . "\n" .
			"JobExp/Hour  : " . formatNumber($jExpPerHour) . "\n" .
			"Zenny        : " . formatNumber($zennyMade) . "\n" .
			"Zenny/Hour   : " . formatNumber($zennyPerHour) . "\n" .
			"Base Levelup Time Estimation : " . timeConvert($EstB_sec) . "\n" .
			"Job Levelup Time Estimation  : " . timeConvert($EstJ_sec) . "\n" .
			"Died : $chars[$config{'char'}]{'deathCount'}\n", "info");

			message("-[Monster Killed Count]-----------\n" .
				"#   ID   Name                Count\n",
				"list");
			for (my $i = 0; $i < @monsters_Killed; $i++) {
				next if ($monsters_Killed[$i] eq "");
				message(swrite(
					"@<< @<<<< @<<<<<<<<<<<<<       @<<< ",
					[$i, $monsters_Killed[$i]{'nameID'}, $monsters_Killed[$i]{'name'}, $monsters_Killed[$i]{'count'}]),
					"list");
				$total += $monsters_Killed[$i]{'count'};
			}
			message("----------------------------------\n" .
				"Total number of killed monsters: $total\n" .
				"----------------------------------\n",
				"list");

		} elsif ($arg1 eq "reset") {
			($bExpSwitch,$jExpSwitch,$totalBaseExp,$totalJobExp) = (2,2,0,0);
			$startTime_EXP = time;
			undef @monsters_Killed;

		} else {
			error "Error in function 'exp' (Exp Report)\n" .
				"Usage: exp [reset]\n";
		}
		
	} elsif ($switch eq "follow") {
		($arg1) = $input =~ /^[\s\S]*? (\w+)/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'follow' (Follow Player)\n" .
				"Usage: follow <player #>\n";
		} elsif ($arg1 eq "stop") {
			aiRemove("follow");
			configModify("follow", 0);

		} elsif ($arg1 =~ /^\d+$/) {
			if (!$playersID[$arg1]) {
				error	"Error in function 'follow' (Follow Player)\n" .
					"Player $arg1 either not visible or not online in party.\n";
			} else {
				ai_follow($players{$playersID[$arg1]}{name});
				configModify("follow", 1);
				configModify("followTarget", $players{$playersID[$arg1]}{name});
			}

		} else {
			ai_follow($arg1);
			configModify("follow", 1);
			configModify("followTarget", $arg1);
		}

	#Guild Chat - chobit andy 20030101
	} elsif ($switch eq "g") {
		($arg1) = $input =~ /^[\s\S]*? ([\s\S]*)/;
		if ($arg1 eq "") {
			error 	"Syntax Error in function 'g' (Guild Chat)\n" .
				"Usage: g <message>\n";
		} else {
			sendMessage(\$remote_socket, "g", $arg1);
		}

	} elsif ($switch eq "guild") {
		($arg1) = $input =~ /^.*? (\w+)/;
		if ($arg1 eq "info") {
			message("---------- Guild Information ----------\n", "info");
			message(swrite(
				"Name    : @<<<<<<<<<<<<<<<<<<<<<<<<",	[$guild{'name'}],
				"Lv      : @<<",			[$guild{'lvl'}],
				"Exp     : @>>>>>>>>>/@<<<<<<<<<<",	[$guild{'exp'}, $guild{'next_exp'}],
				"Master  : @<<<<<<<<<<<<<<<<<<<<<<<<",	[$guild{'master'}],
				"Connect : @>>/@<<",			[$guild{'conMember'}, $guild{'maxMember'}]),
				"info");
			message("---------------------------------------\n", "info");

		} elsif ($arg1 eq "member") {
			message("------------ Guild  Member ------------\n", "list");
			message("#  Name                       Job        Lv  Title                       Online\n", "list");
			my ($i, $name, $job, $lvl, $title, $online);

			my $count = @{$guild{'member'}};
			for ($i = 0; $i < $count; $i++) {
				$name  = $guild{'member'}[$i]{'name'};
				next if ($name eq "");
				$job   = $jobs_lut{$guild{'member'}[$i]{'jobID'}};
				$lvl   = $guild{'member'}[$i]{'lvl'};
				$title = $guild{'member'}[$i]{'title'};
				$online = $guild{'member'}[$i]{'online'} ? "Yes" : "No";

				message(swrite(
					"@< @<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<< @>  @<<<<<<<<<<<<<<<<<<<<<<<<<< @<<",
					[$i, $name, $job, $lvl, $title, $online]),
					"list");
			}
			message("---------------------------------------\n", "list");

		} elsif ($arg1 eq "") {
			message	"Requesting guild information...\n" .
				"Enter command to view guild information: guild < info | member >\n", "info";
			sendGuildInfoRequest(\$remote_socket);
			sendGuildRequest(\$remote_socket, 0);
			sendGuildRequest(\$remote_socket, 1);
		}

	} elsif ($switch eq "identify") {
		($arg1) = $input =~ /^[\s\S]*? (\w+)/;
		if ($arg1 eq "") {
			message("---------Identify List--------\n", "list");
			for (my $i = 0; $i < @identifyID; $i++) {
				next if ($identifyID[$i] eq "");
				message(swrite(
					"@<<< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<",
					[$i, $chars[$config{'char'}]{'inventory'}[$identifyID[$i]]{'name'}]),
					"list");
			}
			message("------------------------------\n", "list");
		} elsif ($arg1 =~ /\d+/ && $identifyID[$arg1] eq "") {
			error	"Error in function 'identify' (Identify Item)\n" .
				"Identify Item $arg1 does not exist\n";

		} elsif ($arg1 =~ /\d+/) {
			sendIdentify(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$identifyID[$arg1]]{'index'});
		} else {
			error	"Syntax Error in function 'identify' (Identify Item)\n" .
				"Usage: identify [<identify #>]\n";
		}

	} elsif ($switch eq "join") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		($arg2) = $input =~ /^[\s\S]*? \d+ ([\s\S]*)$/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'join' (Join Chat Room)\n" .
				"Usage: join <chat room #> [<password>]\n";
		} elsif ($currentChatRoom ne "") {
			error	"Error in function 'join' (Join Chat Room)\n" .
				"You are already in a chat room.\n";
		} elsif ($chatRoomsID[$arg1] eq "") {
			error	"Error in function 'join' (Join Chat Room)\n" .
				"Chat Room $arg1 does not exist.\n";
		} else {
			sendChatRoomJoin(\$remote_socket, $chatRoomsID[$arg1], $arg2);
		}

	} elsif ($switch eq "judge") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		($arg2) = $input =~ /^[\s\S]*? \d+ (\d+)/;
		if ($arg1 eq "" || $arg2 eq "") {
			error	"Syntax Error in function 'judge' (Give an alignment point to Player)\n" .
				"Usage: judge <player #> <0 (good) | 1 (bad)>\n";
		} elsif ($playersID[$arg1] eq "") {
			error	"Error in function 'judge' (Give an alignment point to Player)\n" .
				"Player $arg1 does not exist.\n";
		} else {
			$arg2 = ($arg2 >= 1);
			sendAlignment(\$remote_socket, $playersID[$arg1], $arg2);
		}

	} elsif ($switch eq "kick") {
		($arg1) = $input =~ /^[\s\S]*? ([\s\S]*)/;
		if ($currentChatRoom eq "") {
			error	"Error in function 'kick' (Kick from Chat)\n" .
				"You are not in a Chat Room.\n";
		} elsif ($arg1 eq "") {
			error	"Syntax Error in function 'kick' (Kick from Chat)\n" .
				"Usage: kick <user #>\n";
		} elsif ($currentChatRoomUsers[$arg1] eq "") {
			error	"Error in function 'kick' (Kick from Chat)\n" .
				"Chat Room User $arg1 doesn't exist\n";
		} else {
			sendChatRoomKick(\$remote_socket, $currentChatRoomUsers[$arg1]);
		}

	} elsif ($switch eq "look") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		($arg2) = $input =~ /^[\s\S]*? \d+ (\d+)$/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'look' (Look a Direction)\n" .
				"Usage: look <body dir> [<head dir>]\n";
		} else {
			look($arg1, $arg2);
		}

	} elsif ($switch eq "lookp") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'lookp' (Look at Player)\n" .
				"Usage: lookp <player #>\n";
		} else {
			for (my $i = 0; $i < @playersID; $i++) {
				next if ($players{$playersID[$i]} eq "");
				lookAtPosition($players{$playersID[$i]}{'pos_to'}, int(rand(3)));
				last;
			}
		}

	} elsif ($switch eq "move") {
		($arg1, $arg2, $arg3) = $input =~ /^[\s\S]*? (\d+) (\d+)(.*?)$/;

		undef $ai_v{'temp'}{'map'};
		if ($arg1 eq "") {
			($ai_v{'temp'}{'map'}) = $input =~ /^[\s\S]*? (.*?)$/;
		} else {
			$ai_v{'temp'}{'map'} = $arg3;
		}
		$ai_v{'temp'}{'map'} =~ s/\s//g;
		if (($arg1 eq "" || $arg2 eq "") && !$ai_v{'temp'}{'map'}) {
			error	"Syntax Error in function 'move' (Move Player)\n" .
				"Usage: move <x> <y> &| <map>\n";
		} elsif ($ai_v{'temp'}{'map'} eq "stop") {
			aiRemove("move");
			aiRemove("route");
			aiRemove("mapRoute");
			message "Stopped all movement\n", "success";
		} else {
			$ai_v{'temp'}{'map'} = $field{'name'} if ($ai_v{'temp'}{'map'} eq "");
			if ($maps_lut{$ai_v{'temp'}{'map'}.'.rsw'}) {
				if ($arg2 ne "") {
					message("Calculating route to: $maps_lut{$ai_v{'temp'}{'map'}.'.rsw'}($ai_v{'temp'}{'map'}): $arg1, $arg2\n", "route");
					$ai_v{'temp'}{'x'} = $arg1;
					$ai_v{'temp'}{'y'} = $arg2;
				} else {
					message("Calculating route to: $maps_lut{$ai_v{'temp'}{'map'}.'.rsw'}($ai_v{'temp'}{'map'})\n", "route");
					undef $ai_v{'temp'}{'x'};
					undef $ai_v{'temp'}{'y'};
				}
				ai_route($ai_v{'temp'}{'map'}, $ai_v{'temp'}{'x'}, $ai_v{'temp'}{'y'},
					attackOnRoute => 1);
			} else {
				error "Map $ai_v{'temp'}{'map'} does not exist\n";
			}
		}

	} elsif ($switch eq "openshop"){
		if (!$shopstarted) {
			sendOpenShop(\$remote_socket);
		} else {
			error "Error: a shop has already been opened.\n";
		}

	} elsif ($switch eq "p") {
		($arg1) = $input =~ /^[\s\S]*? ([\s\S]*)/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'p' (Party Chat)\n" .
				"Usage: p <message>\n";
		} else {
			sendMessage(\$remote_socket, "p", $arg1);
		}

	} elsif ($switch eq "party") {
		($arg1) = $input =~ /^[\s\S]*? (\w*)/;
		($arg2) = $input =~ /^[\s\S]*? [\s\S]*? (\d+)\b/;
		if ($arg1 eq "" && !%{$chars[$config{'char'}]{'party'}}) {
			error	"Error in function 'party' (Party Functions)\n" .
				"Can't list party - you're not in a party.\n";
		} elsif ($arg1 eq "") {
			message("----------Party-----------\n", "list");
			message($chars[$config{'char'}]{'party'}{'name'}."\n", "list");
			message("#      Name                  Map                    Online    HP\n", "list");
			for (my $i = 0; $i < @partyUsersID; $i++) {
				next if ($partyUsersID[$i] eq "");
				my $coord_string = "";
				my $hp_string = "";
				my $name_string = $chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'name'};
				my $admin_string = ($chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'admin'}) ? "(A)" : "";
				my $online_string;

				if ($partyUsersID[$i] eq $accountID) {
					$online_string = "Yes";
					($map_string) = $map_name =~ /([\s\S]*)\.gat/;
					$coord_string = $chars[$config{'char'}]{'pos'}{'x'}. ", ".$chars[$config{'char'}]{'pos'}{'y'};
					$hp_string = $chars[$config{'char'}]{'hp'}."/".$chars[$config{'char'}]{'hp_max'}
							." (".int($chars[$config{'char'}]{'hp'}/$chars[$config{'char'}]{'hp_max'} * 100)
							."%)";
				} else {
					$online_string = ($chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'online'}) ? "Yes" : "No";
					($map_string) = $chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'map'} =~ /([\s\S]*)\.gat/;
					$coord_string = $chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'pos'}{'x'}
						. ", ".$chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'pos'}{'y'}
						if ($chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'pos'}{'x'} ne ""
							&& $chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'online'});
					$hp_string = $chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'hp'}."/".$chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'hp_max'}
							." (".int($chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'hp'}/$chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'hp_max'} * 100)
							."%)" if ($chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'hp_max'} && $chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$i]}{'online'});
				}
				message(swrite(
					"@< @<< @<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<< @<<<<<<< @<<       @<<<<<<<<<<<<<<<<<<",
					[$i, $admin_string, $name_string, $map_string, $coord_string, $online_string, $hp_string]),
					"list");
			}
			message("--------------------------\n", "list");

		} elsif ($arg1 eq "create") {
			($arg2) = $input =~ /^[\s\S]*? [\s\S]*? \"([\s\S]*?)\"/;
			if ($arg2 eq "") {
				error	"Syntax Error in function 'party create' (Organize Party)\n" .
					"Usage: party create \"<party name>\"\n";
			} else {
				sendPartyOrganize(\$remote_socket, $arg2);
			}

		} elsif ($arg1 eq "join" && $arg2 ne "1" && $arg2 ne "0") {
			error	"Syntax Error in function 'party join' (Accept/Deny Party Join Request)\n" .
				"Usage: party join <flag>\n";
		} elsif ($arg1 eq "join" && $incomingParty{'ID'} eq "") {
			error	"Error in function 'party join' (Join/Request to Join Party)\n" .
				"Can't accept/deny party request - no incoming request.\n";
		} elsif ($arg1 eq "join") {
			sendPartyJoin(\$remote_socket, $incomingParty{'ID'}, $arg2);
			undef %incomingParty;

		} elsif ($arg1 eq "request" && !%{$chars[$config{'char'}]{'party'}}) {
			error	"Error in function 'party request' (Request to Join Party)\n" .
				"Can't request a join - you're not in a party.\n";
		} elsif ($arg1 eq "request" && $playersID[$arg2] eq "") {
			error	"Error in function 'party request' (Request to Join Party)\n" .
				"Can't request to join party - player $arg2 does not exist.\n";
		} elsif ($arg1 eq "request") {
			sendPartyJoinRequest(\$remote_socket, $playersID[$arg2]);


		} elsif ($arg1 eq "leave" && !%{$chars[$config{'char'}]{'party'}}) {
			error	"Error in function 'party leave' (Leave Party)\n" .
				"Can't leave party - you're not in a party.\n";
		} elsif ($arg1 eq "leave") {
			sendPartyLeave(\$remote_socket);


		} elsif ($arg1 eq "share" && !%{$chars[$config{'char'}]{'party'}}) {
			error	"Error in function 'party share' (Set Party Share EXP)\n" .
				"Can't set share - you're not in a party.\n";
		} elsif ($arg1 eq "share" && $arg2 ne "1" && $arg2 ne "0") {
			error	"Syntax Error in function 'party share' (Set Party Share EXP)\n" .
				"Usage: party share <flag>\n";
		} elsif ($arg1 eq "share") {
			sendPartyShareEXP(\$remote_socket, $arg2);


		} elsif ($arg1 eq "kick" && !%{$chars[$config{'char'}]{'party'}}) {
			error	"Error in function 'party kick' (Kick Party Member)\n" .
				"Can't kick member - you're not in a party.\n";
		} elsif ($arg1 eq "kick" && $arg2 eq "") {
			error	"Syntax Error in function 'party kick' (Kick Party Member)\n" .
				"Usage: party kick <party member #>\n";
		} elsif ($arg1 eq "kick" && $partyUsersID[$arg2] eq "") {
			error	"Error in function 'party kick' (Kick Party Member)\n" .
				"Can't kick member - member $arg2 doesn't exist.\n";
		} elsif ($arg1 eq "kick") {
			sendPartyKick(\$remote_socket, $partyUsersID[$arg2]
					,$chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$arg2]}{'name'});

		}

	} elsif ($switch eq "petl") {
		message("-----------Pet List-----------\n" .
			"#    Type                     Name\n",
			"list");
		for (my $i = 0; $i < @petsID; $i++) {
			next if ($petsID[$i] eq "");
			message(swrite(
				"@<<< @<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<<<<<<<<<<<<<<",
				[$i, $pets{$petsID[$i]}{'name'}, $pets{$petsID[$i]}{'name_given'}]),
				"list");
		}
		message("----------------------------------\n", "list");

	} elsif ($switch eq "pm") {
		($arg1, $arg2) = $input =~ /^[\S]*? "(.*?)" (.*)/;
		my $type = 0;
		if (!$arg1) {
			($arg1, $arg2) = $input =~ /^[\S]*? (\d+) (.*)/;
			$type = 1;
		}
		if ($arg1 eq "" || $arg2 eq "") {
			error	"Syntax Error in function 'pm' (Private Message)\n" .
				qq~Usage: pm ("<username>" | <pm #>) <message>\n~;
		} elsif ($type) {
			if ($arg1 - 1 >= @privMsgUsers) {
				error	"Error in function 'pm' (Private Message)\n" .
					"Quick look-up $arg1 does not exist\n";
			} else {
				sendMessage(\$remote_socket, "pm", $arg2, $privMsgUsers[$arg1 - 1]);
				$lastpm{'msg'} = $arg2;
				$lastpm{'user'} = $privMsgUsers[$arg1 - 1];
			}
		} else {
			if ($arg1 =~ /^%(\d*)$/) {
				$arg1 = $1;
			}

			if (binFind(\@privMsgUsers, $arg1) eq "") {
				$privMsgUsers[@privMsgUsers] = $arg1;
			}
			sendMessage(\$remote_socket, "pm", $arg2, $arg1);
			$lastpm{'msg'} = $arg2;
			$lastpm{'user'} = $arg1;
		}

	} elsif ($switch eq "pml") {
		message("-----------PM LIST-----------\n", "list");
		for (my $i = 1; $i <= @privMsgUsers; $i++) {
			message(swrite(
				"@<<< @<<<<<<<<<<<<<<<<<<<<<<<",
				[$i, $privMsgUsers[$i - 1]]),
				"list");
		}
		message("-----------------------------\n", "list");

	} elsif ($switch eq "quit") {
		quit();

	} elsif ($switch eq "rc") {
		($args) = $input =~ /^[\s\S]*? ([\s\S]*)/;
		if ($args ne "") {
			Modules::reload($args, 1);

		} else {
			message("Reloading functions.pl...\n", "info");
			if (!do 'functions.pl' || $@) {
				error "Unable to reload functions.pl\n";
				error("$@\n", "syntax", 1) if ($@);
			}
		}

	} elsif ($switch eq "relog") {
		relog();

	} elsif ($switch eq "respawn") {
		useTeleport(2);

	} elsif ($switch eq "sell") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		($arg2) = $input =~ /^[\s\S]*? \d+ (\d+)$/;
		if ($arg1 eq "" && $talk{'buyOrSell'}) {
			sendGetSellList(\$remote_socket, $talk{'ID'});

		} elsif ($arg1 eq "") {
			error	"Syntax Error in function 'sell' (Sell Inventory Item)\n" .
				"Usage: sell <item #> [<amount>]\n";
		} elsif (!%{$chars[$config{'char'}]{'inventory'}[$arg1]}) {
			error	"Error in function 'sell' (Sell Inventory Item)\n" .
				"Inventory Item $arg1 does not exist.\n";
		} else {
			if (!$arg2 || $arg2 > $chars[$config{'char'}]{'inventory'}[$arg1]{'amount'}) {
				$arg2 = $chars[$config{'char'}]{'inventory'}[$arg1]{'amount'};
			}
			sendSell(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$arg1]{'index'}, $arg2);
		}

	} elsif ($switch eq "sit") {
		$ai_v{'attackAuto_old'} = $config{'attackAuto'};
		$ai_v{'route_randomWalk_old'} = $config{'route_randomWalk'};
		$ai_v{'teleportAuto_idle_old'} = $config{'teleportAuto_idle'};
		$ai_v{'itemsGatherAuto_old'} = $config{'itemsGatherAuto'};
		configModify("attackAuto", 1);
		configModify("route_randomWalk", 0);
		configModify("teleportAuto_idle", 0);
		configModify("itemsGatherAuto", 0);
		aiRemove("move");
		aiRemove("route");
		aiRemove("mapRoute");
		sit();
		$ai_v{'sitAuto_forceStop'} = 0;

	} elsif ($switch eq "sl") {
		$input =~ /^[\s\S]*? (\d+) (\d+) (\d+)(?: (\d+))?/;
		my $skill_num = $1;
		my $x = $2;
		my $y = $3;
		my $lvl = $4;
		if (!$skill_num || !defined($x) || !defined($y)) {
			error	"Syntax Error in function 'sl' (Use Skill on Location)\n" .
				"Usage: ss <skill #> <x> <y> [<skill lvl>]\n";
		} elsif (!$skillsID[$skill_num]) {
			error	"Error in function 'sl' (Use Skill on Location)\n" .
				"Skill $skill_num does not exist.\n";
		} else {
			my $skill = $chars[$config{'char'}]{'skills'}{$skillsID[$skill_num]};
			if (!$lvl || $lvl > $skill->{'lv'}) {
				$lvl = $skill->{'lv'};
			}
			ai_skillUse($skill->{'ID'}, $lvl, 0, 0, $x, $y);
		}

	} elsif ($switch eq "sm") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		($arg2) = $input =~ /^[\s\S]*? \d+ (\d+)/;
		($arg3) = $input =~ /^[\s\S]*? \d+ \d+ (\d+)/;
		if ($arg1 eq "" || $arg2 eq "") {
			error	"Syntax Error in function 'sm' (Use Skill on Monster)\n" .
				"Usage: sm <skill #> <monster #> [<skill lvl>]\n";
		} elsif ($monstersID[$arg2] eq "") {
			error	"Error in function 'sm' (Use Skill on Monster)\n" .
				"Monster $arg2 does not exist.\n";	
		} elsif ($skillsID[$arg1] eq "") {
			error	"Error in function 'sm' (Use Skill on Monster)\n" .
				"Skill $arg1 does not exist.\n";
		} else {
			if (!$arg3 || $arg3 > $chars[$config{'char'}]{'skills'}{$skillsID[$arg1]}{'lv'}) {
				$arg3 = $chars[$config{'char'}]{'skills'}{$skillsID[$arg1]}{'lv'};
			}
			if (!ai_getSkillUseType($skillsID[$arg1])) {
				ai_skillUse($chars[$config{'char'}]{'skills'}{$skillsID[$arg1]}{'ID'}, $arg3, 0,0, $monstersID[$arg2]);
			} else {
				ai_skillUse($chars[$config{'char'}]{'skills'}{$skillsID[$arg1]}{'ID'}, $arg3, 0,0, $monsters{$monstersID[$arg2]}{'pos_to'}{'x'}, $monsters{$monstersID[$arg2]}{'pos_to'}{'y'});
			}
		}

	} elsif ($switch eq "sp") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		($arg2) = $input =~ /^[\s\S]*? \d+ (\d+)/;
		($arg3) = $input =~ /^[\s\S]*? \d+ \d+ (\d+)/;
		if ($arg1 eq "" || $arg2 eq "") {
			error	"Syntax Error in function 'sp' (Use Skill on Player)\n" .
				"Usage: sp <skill #> <player #> [<skill lvl>]\n";
		} elsif ($playersID[$arg2] eq "") {
			error	"Error in function 'sp' (Use Skill on Player)\n" .
				"Player $arg2 does not exist.\n";	
		} elsif ($skillsID[$arg1] eq "") {
			error	"Error in function 'sp' (Use Skill on Player)\n" .
				"Skill $arg1 does not exist.\n";
		} else {
			if (!$arg3 || $arg3 > $chars[$config{'char'}]{'skills'}{$skillsID[$arg1]}{'lv'}) {
				$arg3 = $chars[$config{'char'}]{'skills'}{$skillsID[$arg1]}{'lv'};
			}
			if (!ai_getSkillUseType($skillsID[$arg1])) {
				ai_skillUse($chars[$config{'char'}]{'skills'}{$skillsID[$arg1]}{'ID'}, $arg3, 0,0, $playersID[$arg2]);
			} else {
				ai_skillUse($chars[$config{'char'}]{'skills'}{$skillsID[$arg1]}{'ID'}, $arg3, 0,0, $players{$playersID[$arg2]}{'pos_to'}{'x'}, $players{$playersID[$arg2]}{'pos_to'}{'y'});
			}
		}

	} elsif ($switch eq "ss") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		($arg2) = $input =~ /^[\s\S]*? \d+ (\d+)/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'ss' (Use Skill on Self)\n" .
				"Usage: ss <skill #> [<skill lvl>]\n";
		} elsif ($skillsID[$arg1] eq "") {
			error	"Error in function 'ss' (Use Skill on Self)\n" .
				"Skill $arg1 does not exist.\n";
		} else {
			if (!$arg2 || $arg2 > $chars[$config{'char'}]{'skills'}{$skillsID[$arg1]}{'lv'}) {
				$arg2 = $chars[$config{'char'}]{'skills'}{$skillsID[$arg1]}{'lv'};
			}
			if (!ai_getSkillUseType($skillsID[$arg1])) {
				ai_skillUse($chars[$config{'char'}]{'skills'}{$skillsID[$arg1]}{'ID'}, $arg2, 0,0, $accountID);
			} else {
				ai_skillUse($chars[$config{'char'}]{'skills'}{$skillsID[$arg1]}{'ID'}, $arg2, 0,0, $chars[$config{'char'}]{'pos_to'}{'x'}, $chars[$config{'char'}]{'pos_to'}{'y'});
			}
		}

	} elsif ($switch eq "stand") {
		if ($ai_v{'attackAuto_old'} ne "") {
			configModify("attackAuto", $ai_v{'attackAuto_old'});
			configModify("route_randomWalk", $ai_v{'route_randomWalk_old'});
			configModify("teleportAuto_idle", $ai_v{'teleportAuto_idle_old'});
			configModify("itemsGatherAuto", $ai_v{'itemsGatherAuto_old'});
			undef $ai_v{'attackAuto_old'};
			undef $ai_v{'route_randomWalk_old'};
			undef $ai_v{'teleportAuto_idle_old'};
			undef $ai_v{'itemsGatherAuto_old'};
		}
		stand();
		$ai_v{'sitAuto_forceStop'} = 1;

	} elsif ($switch eq "storage") {
		($arg1) = $input =~ /^[\s\S]*? (\w+)/;
		($arg2) = $input =~ /^[\s\S]*? \w+ ([\d,-]+)/;
		($arg3) = $input =~ /^[\s\S]*? \w+ [\d,-]+ (\d+)/;
		if ($arg1 eq "") {
			message("----------Storage-----------\n", "list");
			message("#  Name\n", "list");
			for (my $i = 0; $i < @storageID; $i++) {
				next if ($storageID[$i] eq "");

				my $display = "$storage{$storageID[$i]}{'name'}";
				if ($storage{$storageID[$i]}{'enchant'}) {
					$display = "+$storage{$storageID[$i]}{'enchant'} ".$display;
				}
				if ($storage{$storageID[$i]}{'slotName'} ne "") {
					$display = $display ." [$storage{$storageID[$i]}{'slotName'}]";
				}
				$display = $display . " x $storage{$storageID[$i]}{'amount'}";

				message(swrite(
					"@< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<",
					[$i, $display]),
					"list");
			}
			message("\nCapacity: $storage{'items'}/$storage{'items_max'}\n", "list");
			message("-------------------------------\n", "list");

		} elsif ($arg1 eq "add" && $arg2 =~ /\d+/ && $chars[$config{'char'}]{'inventory'}[$arg2] eq "") {
			error	"Error in function 'storage add' (Add Item to Storage)\n" .
				"Inventory Item $arg2 does not exist\n";
		} elsif ($arg1 eq "add" && $arg2 =~ /\d+/) {
			if (!$arg3 || $arg3 > $chars[$config{'char'}]{'inventory'}[$arg2]{'amount'}) {
				$arg3 = $chars[$config{'char'}]{'inventory'}[$arg2]{'amount'};
			}
			sendStorageAdd(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$arg2]{'index'}, $arg3);

		} elsif ($arg1 eq "get" && $arg2 =~ /\d+/ && $storageID[$arg2] eq "") {
			error	"Error in function 'storage get' (Get Item from Storage)\n" .
				"Storage Item $arg2 does not exist\n";
		} elsif ($arg1 eq "get" && $arg2 =~ /[\d,-]+/) {
			my @temp = split(/,/, $arg2);
			@temp = grep(!/^$/, @temp); # Remove empty entries

			my @items = ();
			foreach (@temp) {
				if (/(\d+)-(\d+)/) {
					for ($1..$2) {
						push(@items, $_) if ($storageID[$_] ne "");
					}
				} else {
					push @items, $_;
				}
			}
			ai_storageGet(\@items, $arg3);

		} elsif ($arg1 eq "close") {
			sendStorageClose(\$remote_socket);

		} else {
			error	"Syntax Error in function 'storage' (Storage Functions)\n" .
				"Usage: storage [<add | get | close>] [<inventory # | storage #>] [<amount>]\n";
		}

	} elsif ($switch eq "store") {
		($arg1) = $input =~ /^[\s\S]*? (\w+)/;
		($arg2) = $input =~ /^[\s\S]*? \w+ (\d+)/;
		if ($arg1 eq "" && !$talk{'buyOrSell'}) {
			message("----------Store List-----------\n", "list");
			message("#  Name                    Type           Price\n", "list");
			for (my $i = 0; $i < @storeList; $i++) {
				$display = $storeList[$i]{'name'};
				message(swrite(
					"@< @<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<<< @>>>>>>>z",
					[$i, $display, $itemTypes_lut{$storeList[$i]{'type'}}, $storeList[$i]{'price'}]),
					"list");
			}
			message("-------------------------------\n", "list");
		} elsif ($arg1 eq "" && $talk{'buyOrSell'}) {
			sendGetStoreList(\$remote_socket, $talk{'ID'});

		} elsif ($arg1 eq "desc" && $arg2 =~ /\d+/ && $storeList[$arg2] eq "") {
			error	"Error in function 'store desc' (Store Item Description)\n" .
				"Usage: Store item $arg2 does not exist\n";
		} elsif ($arg1 eq "desc" && $arg2 =~ /\d+/) {
			printItemDesc($storeList[$arg2]);

		} else {
			error	"Syntax Error in function 'store' (Store Functions)\n" .
				"Usage: store [<desc>] [<store item #>]\n";

		}

	} elsif ($switch eq "take") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)$/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'take' (Take Item)\n" .
				"Usage: take <item #>\n";
		} elsif ($itemsID[$arg1] eq "") {
			error	"Error in function 'take' (Take Item)\n" .
				"Item $arg1 does not exist.\n";
		} else {
			take($itemsID[$arg1]);
		}


	} elsif ($switch eq "talk") {
		($arg1) = $input =~ /^[\s\S]*? (\w+)/;
		($arg2) = $input =~ /^[\s\S]*? [\s\S]*? (\d+)/;

		if ($arg1 =~ /^\d+$/ && $npcsID[$arg1] eq "") {
			error	"Error in function 'talk' (Talk to NPC)\n" .
				"NPC $arg1 does not exist\n";
		} elsif ($arg1 =~ /^\d+$/) {
			sendTalk(\$remote_socket, $npcsID[$arg1]);

		} elsif (($arg1 eq "resp" || $arg1 eq "num") && !%talk) {
			error	"Error in function 'talk resp' (Respond to NPC)\n" .
				"You are not talking to any NPC.\n";

		} elsif ($arg1 eq "resp" && $arg2 eq "") {
			my $display = $npcs{$talk{'nameID'}}{'name'};
			message("----------Responses-----------\n", "list");
			message("NPC: $display\n", "list");
			message("#  Response\n", "list");
			for (my $i = 0; $i < @{$talk{'responses'}}; $i++) {
				message(swrite(
					"@< @<<<<<<<<<<<<<<<<<<<<<<",
					[$i, $talk{'responses'}[$i]]),
					"list");
			}
			message("-------------------------------\n", "list");
		} elsif ($arg1 eq "resp" && $arg2 ne "" && $talk{'responses'}[$arg2] eq "") {
			error	"Error in function 'talk resp' (Respond to NPC)\n" .
				"Response $arg2 does not exist.\n";
		} elsif ($arg1 eq "resp" && $arg2 ne "") {
			if ($talk{'responses'}[$arg2] eq "Cancel Chat") {
				$arg2 = 255;
			} else {
				$arg2 += 1;
			}
			sendTalkResponse(\$remote_socket, $talk{'ID'}, $arg2);

		} elsif ($arg1 eq "num" && $arg2 eq "") {
			error "Error in function 'talk num' (Respond to NPC)\n" .
				"You must specify a number.\n";
		} elsif ($arg1 eq "num" && !($arg2 =~ /^\d$/)) {
			error "Error in function 'talk num' (Respond to NPC)\n" .
				"$num is not a valid number.\n";
		} elsif ($arg1 eq "num" && $arg2 =~ /^\d$/) {
			sendTalkNumber(\$remote_socket, $talk{'ID'}, $num);

		} elsif ($arg1 eq "cont" && !%talk) {
			error	"Error in function 'talk cont' (Continue Talking to NPC)\n" .
				"You are not talking to any NPC.\n";
		} elsif ($arg1 eq "cont") {
			sendTalkContinue(\$remote_socket, $talk{'ID'});


		} elsif ($arg1 eq "no") {
			sendTalkCancel(\$remote_socket, $talk{'ID'});


		} else {
			error	"Syntax Error in function 'talk' (Talk to NPC)\n" .
				"Usage: talk <NPC # | cont | resp | num> [<response #>|<number #>]\n";
		}

	} elsif ($switch eq "tele") {
		useTeleport(1);

	} elsif ($switch eq "where") {
		($map_string) = $map_name =~ /([\s\S]*)\.gat/;
		message("Location $maps_lut{$map_string.'.rsw'}($map_string) : $chars[$config{'char'}]{'pos_to'}{'x'}, $chars[$config{'char'}]{'pos_to'}{'y'}\n", "info");

	} else {
		my $return = 0;
		Plugins::callHook('Command_post', {
			switch => $switch,
			input => $input,
			return => \$return
		});
		if (!$return) {
			error "Unknown command '$switch'. Please read the documentation for a list of commands.\n";
			#error "Command seems to not exist in either the standard OpenKore command set, or in a plugin\n";
		}
	}
}


#######################################
#######################################
#AI
#######################################
#######################################



sub AI {
	my $i, $j;
	my %cmd = %{(shift)};


	if (timeOut(\%{$timeout{'ai_wipe_check'}})) {
		foreach (keys %players_old) {
			delete $players_old{$_} if (time - $players_old{$_}{'gone_time'} >= $timeout{'ai_wipe_old'}{'timeout'});
		}
		foreach (keys %monsters_old) {
			delete $monsters_old{$_} if (time - $monsters_old{$_}{'gone_time'} >= $timeout{'ai_wipe_old'}{'timeout'});
		}
		foreach (keys %npcs_old) {
			delete $npcs_old{$_} if (time - $npcs_old{$_}{'gone_time'} >= $timeout{'ai_wipe_old'}{'timeout'});
		}
		foreach (keys %items_old) {
			delete $items_old{$_} if (time - $items_old{$_}{'gone_time'} >= $timeout{'ai_wipe_old'}{'timeout'});
		}
		foreach (keys %portals_old) {
			delete $portals_old{$_} if (time - $portals_old{$_}{'gone_time'} >= $timeout{'ai_wipe_old'}{'timeout'});
		}
		$timeout{'ai_wipe_check'}{'time'} = time;
		debug "Wiped old\n", "ai", 2;
	}

	if (timeOut(\%{$timeout{'ai_getInfo'}})) {
		foreach (keys %players) {
			if ($players{$_}{'name'} eq "Unknown") {
				sendGetPlayerInfo(\$remote_socket, $_);
				last;
			}
		}
		foreach (keys %monsters) {
			if ($monsters{$_}{'name'} =~ /Unknown/) {
				sendGetPlayerInfo(\$remote_socket, $_);
				last;
			}
		}
		foreach (keys %npcs) { 
			if ($npcs{$_}{'name'} =~ /Unknown/) { 
				sendGetPlayerInfo(\$remote_socket, $_); 
				last; 
			}
		}
		foreach (keys %pets) { 
			if ($pets{$_}{'name_given'} =~ /Unknown/) { 
				sendGetPlayerInfo(\$remote_socket, $_); 
				last; 
			}
		}
		$timeout{'ai_getInfo'}{'time'} = time;
	}

	if (!$config{'XKore'} && timeOut(\%{$timeout{'ai_sync'}})) {
		$timeout{'ai_sync'}{'time'} = time;
		sendSync(\$remote_socket, getTickCount());
	}

	if (timeOut($mapdrt, $config{'intervalMapDrt'})) {
		$mapdrt = time;

		$map_name =~ /([\s\S]*)\.gat/;
		if ($1) {
			open(DATA, ">$Settings::logs_folder/walk.dat");
			print DATA "$1\n";
			print DATA $chars[$config{'char'}]{'pos_to'}{'x'}."\n";
			print DATA $chars[$config{'char'}]{'pos_to'}{'y'}."\n";

			for (my $i = 0; $i < @npcsID; $i++) {
				next if ($npcsID[$i] eq "");
				print DATA "NL " . $npcs{$npcsID[$i]}{'pos'}{'x'} . " " . $npcs{$npcsID[$i]}{'pos'}{'y'} . "\n";
			}
			for (my $i = 0; $i < @playersID; $i++) {
				next if ($playersID[$i] eq "");
				print DATA "PL " . $players{$playersID[$i]}{'pos'}{'x'} . " " . $players{$playersID[$i]}{'pos'}{'y'} . "\n";
			}
			for (my $i = 0; $i < @monstersID; $i++) {
				next if ($monstersID[$i] eq "");
				print DATA "ML " . $monsters{$monstersID[$i]}{'pos'}{'x'} . " " . $monsters{$monstersID[$i]}{'pos'}{'y'} . "\n";
			}

			close(DATA);
		}
	}

	return if (!$AI);



	##### REAL AI STARTS HERE #####

	Plugins::callHook('AI_pre');

	if (!$accountID) {
		$AI = 0;
		injectAdminMessage("Kore does not have enough account information, so AI has been disabled. Relog to enable AI.") if ($config{'verbose'});
		return;
	}

	if (%cmd) {
		$responseVars{'cmd_user'} = $cmd{'user'};
		if ($cmd{'user'} eq $chars[$config{'char'}]{'name'}) {
			return;
		}
 		if ($cmd{'type'} eq "pm" || $cmd{'type'} eq "p" || $cmd{'type'} eq "g") {
			$ai_v{'temp'}{'qm'} = quotemeta $config{'adminPassword'};
			if ($cmd{'msg'} =~ /^$ai_v{'temp'}{'qm'}\b/) {
				if ($overallAuth{$cmd{'user'}} == 1) {
					sendMessage(\$remote_socket, "pm", getResponse("authF"), $cmd{'user'});
				} else {
					auth($cmd{'user'}, 1);
					sendMessage(\$remote_socket, "pm", getResponse("authS"),$cmd{'user'});
				}
			}
		}
		$ai_v{'temp'}{'qm'} = quotemeta $config{'callSign'};
		if ($overallAuth{$cmd{'user'}} >= 1 
			&& ($cmd{'msg'} =~ /\b$ai_v{'temp'}{'qm'}\b/i || $cmd{'type'} eq "pm")) {
			if ($cmd{'msg'} =~ /\bsit\b/i) {
				$ai_v{'sitAuto_forceStop'} = 0;
				$ai_v{'attackAuto_old'} = $config{'attackAuto'};
				$ai_v{'route_randomWalk_old'} = $config{'route_randomWalk'};
				configModify("attackAuto", 1);
				configModify("route_randomWalk", 0);
				aiRemove("move");
				aiRemove("route");
				aiRemove("mapRoute");
				sit();
				sendMessage(\$remote_socket, $cmd{'type'}, getResponse("sitS"), $cmd{'user'}) if $config{'verbose'};
				$timeout{'ai_thanks_set'}{'time'} = time;
			} elsif ($cmd{'msg'} =~ /\bstand\b/i) {
				$ai_v{'sitAuto_forceStop'} = 1;
				if ($ai_v{'attackAuto_old'} ne "") {
					configModify("attackAuto", $ai_v{'attackAuto_old'});
					configModify("route_randomWalk", $ai_v{'route_randomWalk_old'});
				}
				stand();
				sendMessage(\$remote_socket, $cmd{'type'}, getResponse("standS"), $cmd{'user'}) if $config{'verbose'};
				$timeout{'ai_thanks_set'}{'time'} = time;
			} elsif ($cmd{'msg'} =~ /\brelog\b/i) {
				relog();
				sendMessage(\$remote_socket, $cmd{'type'}, getResponse("relogS"), $cmd{'user'}) if $config{'verbose'};
				$timeout{'ai_thanks_set'}{'time'} = time;
			} elsif ($cmd{'msg'} =~ /\blogout\b/i) {
				quit();
				sendMessage(\$remote_socket, $cmd{'type'}, getResponse("quitS"), $cmd{'user'}) if $config{'verbose'};
				$timeout{'ai_thanks_set'}{'time'} = time;
			} elsif ($cmd{'msg'} =~ /\breload\b/i) {
				Settings::parseReload($');
				sendMessage(\$remote_socket, $cmd{'type'}, getResponse("reloadS"), $cmd{'user'}) if $config{'verbose'};
				$timeout{'ai_thanks_set'}{'time'} = time;
			} elsif ($cmd{'msg'} =~ /\bstatus\b/i) {
				$responseVars{'char_sp'} = $chars[$config{'char'}]{'sp'};
				$responseVars{'char_hp'} = $chars[$config{'char'}]{'hp'};
				$responseVars{'char_sp_max'} = $chars[$config{'char'}]{'sp_max'};
				$responseVars{'char_hp_max'} = $chars[$config{'char'}]{'hp_max'};
				$responseVars{'char_lv'} = $chars[$config{'char'}]{'lv'};
				$responseVars{'char_lv_job'} = $chars[$config{'char'}]{'lv_job'};
				$responseVars{'char_exp'} = $chars[$config{'char'}]{'exp'};
				$responseVars{'char_exp_max'} = $chars[$config{'char'}]{'exp_max'};
				$responseVars{'char_exp_job'} = $chars[$config{'char'}]{'exp_job'};
				$responseVars{'char_exp_job_max'} = $chars[$config{'char'}]{'exp_job_max'};
				$responseVars{'char_weight'} = $chars[$config{'char'}]{'weight'};
				$responseVars{'char_weight_max'} = $chars[$config{'char'}]{'weight_max'};
				$responseVars{'zenny'} = $chars[$config{'char'}]{'zenny'};
				sendMessage(\$remote_socket, $cmd{'type'}, getResponse("statusS"), $cmd{'user'}) if $config{'verbose'};
			} elsif ($cmd{'msg'} =~ /\bconf\b/i) {
				$ai_v{'temp'}{'after'} = $';
				($ai_v{'temp'}{'arg1'}, $ai_v{'temp'}{'arg2'}) = $ai_v{'temp'}{'after'} =~ /(\w+) (\w+)/;
				@{$ai_v{'temp'}{'conf'}} = keys %config;
				if ($ai_v{'temp'}{'arg1'} eq "") {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("confF1"), $cmd{'user'}) if $config{'verbose'};
				} elsif (binFind(\@{$ai_v{'temp'}{'conf'}}, $ai_v{'temp'}{'arg1'}) eq "") {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("confF2"), $cmd{'user'}) if $config{'verbose'};
				} elsif ($ai_v{'temp'}{'arg2'} eq "value") {
					if ($ai_v{'temp'}{'arg1'} =~ /username/i || $ai_v{'temp'}{'arg1'} =~ /password/i) {
						sendMessage(\$remote_socket, $cmd{'type'}, getResponse("confF3"), $cmd{'user'}) if $config{'verbose'};
					} else {
						$responseVars{'key'} = $ai_v{'temp'}{'arg1'};
						$responseVars{'value'} = $config{$ai_v{'temp'}{'arg1'}};
						sendMessage(\$remote_socket, $cmd{'type'}, getResponse("confS1"), $cmd{'user'}) if $config{'verbose'};
						$timeout{'ai_thanks_set'}{'time'} = time;
					}
				} else {
					configModify($ai_v{'temp'}{'arg1'}, $ai_v{'temp'}{'arg2'});
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("confS2"), $cmd{'user'}) if $config{'verbose'};
					$timeout{'ai_thanks_set'}{'time'} = time;
				}
			} elsif ($cmd{'msg'} =~ /\btimeout\b/i) {
				$ai_v{'temp'}{'after'} = $';
				($ai_v{'temp'}{'arg1'}, $ai_v{'temp'}{'arg2'}) = $ai_v{'temp'}{'after'} =~ /([\s\S]+) (\w+)/;
				if ($ai_v{'temp'}{'arg1'} eq "") {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("timeoutF1"), $cmd{'user'}) if $config{'verbose'};
				} elsif ($timeout{$ai_v{'temp'}{'arg1'}} eq "") {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("timeoutF2"), $cmd{'user'}) if $config{'verbose'};
				} elsif ($ai_v{'temp'}{'arg2'} eq "") {
					$responseVars{'key'} = $ai_v{'temp'}{'arg1'};
					$responseVars{'value'} = $timeout{$ai_v{'temp'}{'arg1'}};
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("timeoutS1"), $cmd{'user'}) if $config{'verbose'};
					$timeout{'ai_thanks_set'}{'time'} = time;
				} else {
					setTimeout($ai_v{'temp'}{'arg1'}, $ai_v{'temp'}{'arg2'});
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("timeoutS2"), $cmd{'user'}) if $config{'verbose'};
					$timeout{'ai_thanks_set'}{'time'} = time;
				}
			} elsif ($cmd{'msg'} =~ /\bshut[\s\S]*up\b/i) {
				if ($config{'verbose'}) {
					configModify("verbose", 0);
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("verboseOffS"), $cmd{'user'});
					$timeout{'ai_thanks_set'}{'time'} = time;
				} else {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("verboseOffF"), $cmd{'user'});
				}
			} elsif ($cmd{'msg'} =~ /\bspeak\b/i) {
				if (!$config{'verbose'}) {
					configModify("verbose", 1);
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("verboseOnS"), $cmd{'user'});
					$timeout{'ai_thanks_set'}{'time'} = time;
				} else {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("verboseOnF"), $cmd{'user'});
				}
			} elsif ($cmd{'msg'} =~ /\bdate\b/i) {
				$responseVars{'date'} = getFormattedDate(int(time));
				sendMessage(\$remote_socket, $cmd{'type'}, getResponse("dateS"), $cmd{'user'}) if $config{'verbose'};
				$timeout{'ai_thanks_set'}{'time'} = time;
			} elsif ($cmd{'msg'} =~ /\bmove\b/i
				&& $cmd{'msg'} =~ /\bstop\b/i) {
				aiRemove("move");
				aiRemove("route");
				aiRemove("mapRoute");
				sendMessage(\$remote_socket, $cmd{'type'}, getResponse("moveS"), $cmd{'user'}) if $config{'verbose'};
				$timeout{'ai_thanks_set'}{'time'} = time;
			} elsif ($cmd{'msg'} =~ /\bmove\b/i) {
				$ai_v{'temp'}{'after'} = $';
				$ai_v{'temp'}{'after'} =~ s/^\s+//;
				$ai_v{'temp'}{'after'} =~ s/\s+$//;
				($ai_v{'temp'}{'arg1'}, $ai_v{'temp'}{'arg2'}, $ai_v{'temp'}{'arg3'}) = $ai_v{'temp'}{'after'} =~ /(\d+)\D+(\d+)(.*?)$/;
				undef $ai_v{'temp'}{'map'};
				if ($ai_v{'temp'}{'arg1'} eq "") {
					($ai_v{'temp'}{'map'}) = $ai_v{'temp'}{'after'} =~ /(.*?)$/;
				} else {
					$ai_v{'temp'}{'map'} = $ai_v{'temp'}{'arg3'};
				}
				$ai_v{'temp'}{'map'} =~ s/\s//g;
				if (($ai_v{'temp'}{'arg1'} eq "" || $ai_v{'temp'}{'arg2'} eq "") && !$ai_v{'temp'}{'map'}) {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("moveF"), $cmd{'user'}) if $config{'verbose'};
				} else {
					$ai_v{'temp'}{'map'} = $field{'name'} if ($ai_v{'temp'}{'map'} eq "");
					if ($maps_lut{$ai_v{'temp'}{'map'}.'.rsw'}) {
						if ($ai_v{'temp'}{'arg2'} ne "") {
							message "Calculating route to: $maps_lut{$ai_v{'temp'}{'map'}.'.rsw'}($ai_v{'temp'}{'map'}): $ai_v{'temp'}{'arg1'}, $ai_v{'temp'}{'arg2'}\n", "route";
							$ai_v{'temp'}{'x'} = $ai_v{'temp'}{'arg1'};
							$ai_v{'temp'}{'y'} = $ai_v{'temp'}{'arg2'};
						} else {
							message "Calculating route to: $maps_lut{$ai_v{'temp'}{'map'}.'.rsw'}($ai_v{'temp'}{'map'})\n", "route";
							undef $ai_v{'temp'}{'x'};
							undef $ai_v{'temp'}{'y'};
						}
						sendMessage(\$remote_socket, $cmd{'type'}, getResponse("moveS"), $cmd{'user'}) if $config{'verbose'};
						ai_route($ai_v{'temp'}{'map'}, $ai_v{'temp'}{'x'}, $ai_v{'temp'}{'y'},
							attackOnRoute => 1);
						$timeout{'ai_thanks_set'}{'time'} = time;
					} else {
						error "Map $ai_v{'temp'}{'map'} does not exist\n";
						sendMessage(\$remote_socket, $cmd{'type'}, getResponse("moveF"), $cmd{'user'}) if $config{'verbose'};
					}
				}
			} elsif ($cmd{'msg'} =~ /\blook\b/i) {
				($ai_v{'temp'}{'body'}) = $cmd{'msg'} =~ /(\d+)/;
				($ai_v{'temp'}{'head'}) = $cmd{'msg'} =~ /\d+ (\d+)/;
				if ($ai_v{'temp'}{'body'} ne "") {
					look($ai_v{'temp'}{'body'}, $ai_v{'temp'}{'head'});
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("lookS"), $cmd{'user'}) if $config{'verbose'};
					$timeout{'ai_thanks_set'}{'time'} = time;
				} else {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("lookF"), $cmd{'user'}) if $config{'verbose'};
				}	

			} elsif ($cmd{'msg'} =~ /\bfollow/i
				&& $cmd{'msg'} =~ /\bstop\b/i) {
				if ($config{'follow'}) {
					aiRemove("follow");
					configModify("follow", 0);
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("followStopS"), $cmd{'user'}) if $config{'verbose'};
					$timeout{'ai_thanks_set'}{'time'} = time;
				} else {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("followStopF"), $cmd{'user'}) if $config{'verbose'};
				}
			} elsif ($cmd{'msg'} =~ /\bfollow\b/i) {
				$ai_v{'temp'}{'after'} = $';
				$ai_v{'temp'}{'after'} =~ s/^\s+//;
				$ai_v{'temp'}{'after'} =~ s/\s+$//;
				$ai_v{'temp'}{'targetID'} = ai_getIDFromChat(\%players, $cmd{'user'}, $ai_v{'temp'}{'after'});
				if ($ai_v{'temp'}{'targetID'} ne "") {
					aiRemove("follow");
					ai_follow($players{$ai_v{'temp'}{'targetID'}}{'name'});
					configModify("follow", 1);
					configModify("followTarget", $players{$ai_v{'temp'}{'targetID'}}{'name'});
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("followS"), $cmd{'user'}) if $config{'verbose'};
					$timeout{'ai_thanks_set'}{'time'} = time;
				} else {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("followF"), $cmd{'user'}) if $config{'verbose'};
				}
			} elsif ($cmd{'msg'} =~ /\btank/i
				&& $cmd{'msg'} =~ /\bstop\b/i) {
				if (!$config{'tankMode'}) {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("tankStopF"), $cmd{'user'}) if $config{'verbose'};
				} elsif ($config{'tankMode'}) {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("tankStopS"), $cmd{'user'}) if $config{'verbose'};
					configModify("tankMode", 0);
					$timeout{'ai_thanks_set'}{'time'} = time;
				}
			} elsif ($cmd{'msg'} =~ /\btank/i) {
				$ai_v{'temp'}{'after'} = $';
				$ai_v{'temp'}{'after'} =~ s/^\s+//;
				$ai_v{'temp'}{'after'} =~ s/\s+$//;
				$ai_v{'temp'}{'targetID'} = ai_getIDFromChat(\%players, $cmd{'user'}, $ai_v{'temp'}{'after'});
				if ($ai_v{'temp'}{'targetID'} ne "") {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("tankS"), $cmd{'user'}) if $config{'verbose'};
					configModify("tankMode", 1);
					configModify("tankModeTarget", $players{$ai_v{'temp'}{'targetID'}}{'name'});
					$timeout{'ai_thanks_set'}{'time'} = time;
				} else {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("tankF"), $cmd{'user'}) if $config{'verbose'};
				}
			} elsif ($cmd{'msg'} =~ /\btown/i) {
				sendMessage(\$remote_socket, $cmd{'type'}, getResponse("moveS"), $cmd{'user'}) if $config{'verbose'};
				useTeleport(2);
				
			} elsif ($cmd{'msg'} =~ /\bwhere\b/i) {
				$responseVars{'x'} = $chars[$config{'char'}]{'pos_to'}{'x'};
				$responseVars{'y'} = $chars[$config{'char'}]{'pos_to'}{'y'};
				$responseVars{'map'} = qq~$maps_lut{$field{'name'}.'.rsw'} ($field{'name'})~;
				$timeout{'ai_thanks_set'}{'time'} = time;
				sendMessage(\$remote_socket, $cmd{'type'}, getResponse("whereS"), $cmd{'user'}) if $config{'verbose'};
			}

			#HEAL
			if ($cmd{'msg'} =~ /\bheal\b/i) {
				$ai_v{'temp'}{'after'} = $';
				($ai_v{'temp'}{'amount'}) = $ai_v{'temp'}{'after'} =~ /(\d+)/;
				$ai_v{'temp'}{'after'} =~ s/\d+//;
				$ai_v{'temp'}{'after'} =~ s/^\s+//;
				$ai_v{'temp'}{'after'} =~ s/\s+$//;
				$ai_v{'temp'}{'targetID'} = ai_getIDFromChat(\%players, $cmd{'user'}, $ai_v{'temp'}{'after'});
				if ($ai_v{'temp'}{'targetID'} eq "") {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healF1"), $cmd{'user'}) if $config{'verbose'};
				} elsif ($chars[$config{'char'}]{'skills'}{'AL_HEAL'}{'lv'} > 0) {
					undef $ai_v{'temp'}{'amount_healed'};
					undef $ai_v{'temp'}{'sp_needed'};
					undef $ai_v{'temp'}{'sp_used'};
					undef $ai_v{'temp'}{'failed'};
					undef @{$ai_v{'temp'}{'skillCasts'}};
					while ($ai_v{'temp'}{'amount_healed'} < $ai_v{'temp'}{'amount'}) {
						for ($i = 1; $i <= $chars[$config{'char'}]{'skills'}{'AL_HEAL'}{'lv'}; $i++) {
							$ai_v{'temp'}{'sp'} = 10 + ($i * 3);
							$ai_v{'temp'}{'amount_this'} = int(($chars[$config{'char'}]{'lv'} + $chars[$config{'char'}]{'int'}) / 8)
									* (4 + $i * 8);
							last if ($ai_v{'temp'}{'amount_healed'} + $ai_v{'temp'}{'amount_this'} >= $ai_v{'temp'}{'amount'});
						}
						$ai_v{'temp'}{'sp_needed'} += $ai_v{'temp'}{'sp'};
						$ai_v{'temp'}{'amount_healed'} += $ai_v{'temp'}{'amount_this'};
					}
					while ($ai_v{'temp'}{'sp_used'} < $ai_v{'temp'}{'sp_needed'} && !$ai_v{'temp'}{'failed'}) {
						for ($i = 1; $i <= $chars[$config{'char'}]{'skills'}{'AL_HEAL'}{'lv'}; $i++) {
							$ai_v{'temp'}{'lv'} = $i;
							$ai_v{'temp'}{'sp'} = 10 + ($i * 3);
							if ($ai_v{'temp'}{'sp_used'} + $ai_v{'temp'}{'sp'} > $chars[$config{'char'}]{'sp'}) {
								$ai_v{'temp'}{'lv'}--;
								$ai_v{'temp'}{'sp'} = 10 + ($ai_v{'temp'}{'lv'} * 3);
								last;
							}
							last if ($ai_v{'temp'}{'sp_used'} + $ai_v{'temp'}{'sp'} >= $ai_v{'temp'}{'sp_needed'});
						}
						if ($ai_v{'temp'}{'lv'} > 0) {
							$ai_v{'temp'}{'sp_used'} += $ai_v{'temp'}{'sp'};
							$ai_v{'temp'}{'skillCast'}{'skill'} = 28;
							$ai_v{'temp'}{'skillCast'}{'lv'} = $ai_v{'temp'}{'lv'};
							$ai_v{'temp'}{'skillCast'}{'maxCastTime'} = 0;
							$ai_v{'temp'}{'skillCast'}{'minCastTime'} = 0;
							$ai_v{'temp'}{'skillCast'}{'ID'} = $ai_v{'temp'}{'targetID'};
							unshift @{$ai_v{'temp'}{'skillCasts'}}, {%{$ai_v{'temp'}{'skillCast'}}};
						} else {
							$responseVars{'char_sp'} = $chars[$config{'char'}]{'sp'} - $ai_v{'temp'}{'sp_used'};
							sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healF2"), $cmd{'user'}) if $config{'verbose'};
							$ai_v{'temp'}{'failed'} = 1;
						}
					}
					if (!$ai_v{'temp'}{'failed'}) {
						sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healS"), $cmd{'user'}) if $config{'verbose'};
					}
					foreach (@{$ai_v{'temp'}{'skillCasts'}}) {
						ai_skillUse($$_{'skill'}, $$_{'lv'}, $$_{'maxCastTime'}, $$_{'minCastTime'}, $$_{'ID'});
					}
				} else {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healF3"), $cmd{'user'}) if $config{'verbose'};
				}
			}


			#INC AGI
			if ($cmd{'msg'} =~ /\bagi\b/i){
				$ai_v{'temp'}{'after'} = $';
				($ai_v{'temp'}{'amount'}) = $ai_v{'temp'}{'after'} =~ /(\d+)/;
				$ai_v{'temp'}{'after'} =~ s/\d+//;
				$ai_v{'temp'}{'after'} =~ s/^\s+//;
				$ai_v{'temp'}{'after'} =~ s/\s+$//;
				$ai_v{'temp'}{'targetID'} = ai_getIDFromChat(\%players, $cmd{'user'}, $ai_v{'temp'}{'after'});
				if ($ai_v{'temp'}{'targetID'} eq "") {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healF1"), $cmd{'user'}) if $config{'verbose'};
				} elsif ($chars[$config{'char'}]{'skills'}{'AL_INCAGI'}{'lv'} > 0) {
					undef $ai_v{'temp'}{'failed'};
					$ai_v{'temp'}{'failed'} = 1;
					for ($i = $chars[$config{'char'}]{'skills'}{'AL_INCAGI'}{'lv'}; $i >=1; $i--) {
						if ($chars[$config{'char'}]{'sp'} >= $skillsSP_lut{$skills_rlut{lc("Increase AGI")}}{$i}) {
							ai_skillUse(29,$i,0,0,$ai_v{'temp'}{'targetID'});
							$ai_v{'temp'}{'failed'} = 0;
							last;
						}
					}
					if (!$ai_v{'temp'}{'failed'}) {
						sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healS"), $cmd{'user'}) if $config{'verbose'};
					}else{
						sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healF2"), $cmd{'user'}) if $config{'verbose'};
					}
				} else {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healF3"), $cmd{'user'}) if $config{'verbose'};
				}
				$timeout{'ai_thanks_set'}{'time'} = time;
			}


			#BLESSING
			if ($cmd{'msg'} =~ /\bbless\b/i || $cmd{'msg'} =~ /\bblessing\b/i){
				$ai_v{'temp'}{'after'} = $';
				($ai_v{'temp'}{'amount'}) = $ai_v{'temp'}{'after'} =~ /(\d+)/;
				$ai_v{'temp'}{'after'} =~ s/\d+//;
				$ai_v{'temp'}{'after'} =~ s/^\s+//;
				$ai_v{'temp'}{'after'} =~ s/\s+$//;
				$ai_v{'temp'}{'targetID'} = ai_getIDFromChat(\%players, $cmd{'user'}, $ai_v{'temp'}{'after'});
				if ($ai_v{'temp'}{'targetID'} eq "") {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healF1"), $cmd{'user'}) if $config{'verbose'};
				} elsif ($chars[$config{'char'}]{'skills'}{'AL_BLESSING'}{'lv'} > 0) {
					undef $ai_v{'temp'}{'failed'};
					$ai_v{'temp'}{'failed'} = 1;
					for ($i = $chars[$config{'char'}]{'skills'}{'AL_BLESSING'}{'lv'}; $i >=1; $i--) {
						if ($chars[$config{'char'}]{'sp'} >= $skillsSP_lut{$skills_rlut{lc("Blessing")}}{$i}) {
							ai_skillUse(34,$i,0,0,$ai_v{'temp'}{'targetID'});
							$ai_v{'temp'}{'failed'} = 0;
							last;
						}
					}
					if (!$ai_v{'temp'}{'failed'}) {
						sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healS"), $cmd{'user'}) if $config{'verbose'};
					}else{
						sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healF2"), $cmd{'user'}) if $config{'verbose'};
					}
				} else {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healF3"), $cmd{'user'}) if $config{'verbose'};
				}
				$timeout{'ai_thanks_set'}{'time'} = time;
			}


			#Kyrie
			if ($cmd{'msg'} =~ /\bkyrie\b/i){
				$ai_v{'temp'}{'after'} = $';
				($ai_v{'temp'}{'amount'}) = $ai_v{'temp'}{'after'} =~ /(\d+)/;
				$ai_v{'temp'}{'after'} =~ s/\d+//;
				$ai_v{'temp'}{'after'} =~ s/^\s+//;
				$ai_v{'temp'}{'after'} =~ s/\s+$//;
				$ai_v{'temp'}{'targetID'} = ai_getIDFromChat(\%players, $cmd{'user'}, $ai_v{'temp'}{'after'});
				if ($ai_v{'temp'}{'targetID'} eq "") {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healF1"), $cmd{'user'}) if $config{'verbose'};
				} elsif ($chars[$config{'char'}]{'skills'}{'PR_KYRIE'}{'lv'} > 0) {
					undef $ai_v{'temp'}{'failed'};
					$ai_v{'temp'}{'failed'} = 1;
					for ($i = $chars[$config{'char'}]{'skills'}{'PR_KYRIE'}{'lv'}; $i >=1; $i--) {
						if ($chars[$config{'char'}]{'sp'} >= $skillsSP_lut{$skills_rlut{lc("Kyrie Eleison")}}{$i}) {
							ai_skillUse(73,$i,0,0,$ai_v{'temp'}{'targetID'});
							$ai_v{'temp'}{'failed'} = 0;
							last;
						}
					}
					if (!$ai_v{'temp'}{'failed'}) {
						sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healS"), $cmd{'user'}) if $config{'verbose'};
					}else{
						sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healF2"), $cmd{'user'}) if $config{'verbose'};
					}
				} else {
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("healF3"), $cmd{'user'}) if $config{'verbose'};
				}
				$timeout{'ai_thanks_set'}{'time'} = time;
			}


			if ($cmd{'msg'} =~ /\bthank/i || $cmd{'msg'} =~ /\bthn/i) {
				if (!timeOut(\%{$timeout{'ai_thanks_set'}})) {
					$timeout{'ai_thanks_set'}{'time'} -= $timeout{'ai_thanks_set'}{'timeout'};
					sendMessage(\$remote_socket, $cmd{'type'}, getResponse("thankS"), $cmd{'user'}) if $config{'verbose'};
				}
			}
		}
	}


	##### MISC #####

	if ($ai_seq[0] eq "look" && timeOut(\%{$timeout{'ai_look'}})) {
		$timeout{'ai_look'}{'time'} = time;
		sendLook(\$remote_socket, $ai_seq_args[0]{'look_body'}, $ai_seq_args[0]{'look_head'});
		shift @ai_seq;
		shift @ai_seq_args;
	}

	if ($ai_seq[0] ne "deal" && %currentDeal) {
		unshift @ai_seq, "deal";
		unshift @ai_seq_args, "";
	} elsif ($ai_seq[0] eq "deal" && %currentDeal && !$currentDeal{'you_finalize'} && timeOut(\%{$timeout{'ai_dealAuto'}}) && $config{'dealAuto'}==2) {
		sendDealFinalize(\$remote_socket);
		$timeout{'ai_dealAuto'}{'time'} = time;
	} elsif ($ai_seq[0] eq "deal" && %currentDeal && $currentDeal{'other_finalize'} && $currentDeal{'you_finalize'} &&timeOut(\%{$timeout{'ai_dealAuto'}}) && $config{'dealAuto'}==2) {
		sendDealTrade(\$remote_socket);
		$timeout{'ai_dealAuto'}{'time'} = time;
	} elsif ($ai_seq[0] eq "deal" && !%currentDeal) {
		shift @ai_seq;
		shift @ai_seq_args;
	}

	# dealAuto 1=refuse 2=accept
	if ($config{'dealAuto'} && %incomingDeal && timeOut(\%{$timeout{'ai_dealAuto'}})) {
		if ($config{'dealAuto'}==1) {
			sendDealCancel(\$remote_socket);
		}elsif ($config{'dealAuto'}==2) {
			sendDealAccept(\$remote_socket);
		}
		$timeout{'ai_dealAuto'}{'time'} = time;
	}


	# partyAuto 1=refuse 2=accept
	if ($config{'partyAuto'} && %incomingParty && timeOut(\%{$timeout{'ai_partyAuto'}})) {
		if ($config{partyAuto} == 1) {
			message "Auto-denying party request\n";
		} else {
			message "Auto-accepting party request\n";
		}
		sendPartyJoin(\$remote_socket, $incomingParty{'ID'}, $config{'partyAuto'} - 1);
		$timeout{'ai_partyAuto'}{'time'} = time;
		undef %incomingParty;
	}

	if ($config{'guildAutoDeny'} && %incomingGuild && timeOut(\%{$timeout{'ai_guildAutoDeny'}})) {
		sendGuildJoin(\$remote_socket, $incomingGuild{'ID'}, 0) if ($incomingGuild{'Type'} == 1);
		sendGuildAlly(\$remote_socket, $incomingGuild{'ID'}, 0) if ($incomingGuild{'Type'} == 2);
		$timeout{'ai_guildAutoDeny'}{'time'} = time;
		undef %incomingGuild;
	}


	##### PORTALRECORD #####
	# Automatically record new unknown portals

	if ($ai_v{'portalTrace_mapChanged'}) {
		undef $ai_v{'portalTrace_mapChanged'};
		my $first = 1;
		my ($foundID, $smallDist, $dist);

		# Find the nearest portal or the only portal on the map you came from (source portal)
		foreach (@portalsID_old) {
			$dist = distance($chars_old[$config{'char'}]{'pos_to'}, $portals_old{$_}{'pos'});
			if ($dist <= 7 && ($first || $dist < $smallDist)) {
				$smallDist = $dist;
				$foundID = $_;
				undef $first;
			}
		}

		my ($sourceMap, $sourceID, %sourcePos);
		if ($foundID) {
			$sourceMap = $portals_old{$foundID}{'source'}{'map'};
			$sourceID = $portals_old{$foundID}{'nameID'};
			%sourcePos = %{$portals_old{$foundID}{'pos'}};
		}

		# Continue only if the source portal isn't already in portals.txt
		if ($foundID && portalExists($sourceMap, \%sourcePos) eq "" && $field{'name'}) {
			$first = 1;
			undef $foundID;
			undef $smallDist;

			# Find the nearest portal or only portal on the current map
			foreach (@portalsID) {
				$dist = distance($chars[$config{'char'}]{'pos_to'}, $portals{$_}{'pos'});
				if ($first || $dist < $smallDist) {
					$smallDist = $dist;
					$foundID = $_;
					undef $first;
				}
			}

			# Final sanity check
			if (%{$portals{$foundID}} && portalExists($field{'name'}, $portals{$foundID}{'pos'}) eq ""
			 && $sourceMap && defined $sourcePos{x} && defined $sourcePos{y}
			 && defined $portals{$foundID}{'pos'}{'x'} && defined $portals{$foundID}{'pos'}{'y'}) {

				my ($ID, $ID2, $destName);
				$portals{$foundID}{'name'} = "$field{'name'} -> $sourceMap";
				$portals{pack("L", $sourceID)}{'name'} = "$sourceMap -> $field{'name'}";

				# Record information about the portal we walked into
				$ID = "$sourceMap $sourcePos{x} $sourcePos{y}";
				$portals_lut{$ID}{'source'}{'map'} = $sourceMap;
				%{$portals_lut{$ID}{'source'}{'pos'}} = %sourcePos;
				$destName = $field{'name'} . " " . $portals{$foundID}{'pos'}{'x'} . " " . $portals{$foundID}{'pos'}{'y'};
				$portals_lut{$ID}{'dest'}{$destName}{'map'} = $field{'name'};
				%{$portals_lut{$ID}{'dest'}{$destName}{'pos'}} = %{$portals{$foundID}{'pos'}};

				updatePortalLUT("$Settings::tables_folder/portals.txt",
					$sourceMap, $sourcePos{x}, $sourcePos{y},
					$field{'name'}, $portals{$foundID}{'pos'}{'x'}, $portals{$foundID}{'pos'}{'y'});

				# Record information about the portal in which we came out
				$ID2 = "$field{'name'} $portals{$foundID}{'pos'}{'x'} $portals{$foundID}{'pos'}{'y'}";
				$portals_lut{$ID2}{'source'}{'map'} = $field{'name'};
				%{$portals_lut{$ID2}{'source'}{'pos'}} = %{$portals{$foundID}{'pos'}};
				$destName = $sourceMap . " " . $sourcePos{x} . " " . $sourcePos{y};
				$portals_lut{$ID2}{'dest'}{$destName}{'map'} = $sourceMap;
				%{$portals_lut{$ID2}{'dest'}{$destName}{'pos'}} = %sourcePos;

				updatePortalLUT("$Settings::tables_folder/portals.txt",
					$field{'name'}, $portals{$foundID}{'pos'}{'x'}, $portals{$foundID}{'pos'}{'y'},
					$sourceMap, $sourcePos{x}, $sourcePos{y});
			}
		}
	}


	if ($config{'XKore'} && !$sentWelcomeMessage && timeOut(\%{$timeout{'welcomeText'}})) {
		injectAdminMessage($Settings::welcomeText) if ($config{'verbose'});
		$sentWelcomeMessage = 1;
	}


	##### CLIENT SUSPEND #####
	# The clientSuspend AI sequence is used to freeze all other AI activity
	# for a certain period of time.

	if ($ai_seq[0] eq "clientSuspend" && timeOut(\%{$ai_seq_args[0]})) {
		shift @ai_seq;
		shift @ai_seq_args;
	} elsif ($ai_seq[0] eq "clientSuspend" && $config{'XKore'}) {
		# When XKore mode is turned on, clientSuspend will increase it's timeout
		# every time the user tries to do something manually.

		if ($ai_seq_args[0]{'type'} eq "0089") {
			# Player's manually attacking
			if ($ai_seq_args[0]{'args'}[0] == 2) {
				if ($chars[$config{'char'}]{'sitting'}) {
					$ai_seq_args[0]{'time'} = time;
				}
			} elsif ($ai_seq_args[0]{'args'}[0] == 3) {
				$ai_seq_args[0]{'timeout'} = 6;
			} else {
				if (!$ai_seq_args[0]{'forceGiveup'}{'timeout'}) {
					$ai_seq_args[0]{'forceGiveup'}{'timeout'} = 6;
					$ai_seq_args[0]{'forceGiveup'}{'time'} = time;
				}
				if ($ai_seq_args[0]{'dmgFromYou_last'} != $monsters{$ai_seq_args[0]{'args'}[1]}{'dmgFromYou'}) {
					$ai_seq_args[0]{'forceGiveup'}{'time'} = time;
				}
				$ai_seq_args[0]{'dmgFromYou_last'} = $monsters{$ai_seq_args[0]{'args'}[1]}{'dmgFromYou'};
				$ai_seq_args[0]{'missedFromYou_last'} = $monsters{$ai_seq_args[0]{'args'}[1]}{'missedFromYou'};
				if (%{$monsters{$ai_seq_args[0]{'args'}[1]}}) {
					$ai_seq_args[0]{'time'} = time;
				} else {
					$ai_seq_args[0]{'time'} -= $ai_seq_args[0]{'timeout'};
				}
				if (timeOut(\%{$ai_seq_args[0]{'forceGiveup'}})) {
					$ai_seq_args[0]{'time'} -= $ai_seq_args[0]{'timeout'};
				}
			}

		} elsif ($ai_seq_args[0]{'type'} eq "009F") {
			# Player's manually picking up an item
			if (!$ai_seq_args[0]{'forceGiveup'}{'timeout'}) {
				$ai_seq_args[0]{'forceGiveup'}{'timeout'} = 4;
				$ai_seq_args[0]{'forceGiveup'}{'time'} = time;
			}
			if (%{$items{$ai_seq_args[0]{'args'}[0]}}) {
				$ai_seq_args[0]{'time'} = time;
			} else {
				$ai_seq_args[0]{'time'} -= $ai_seq_args[0]{'timeout'};
			}
			if (timeOut(\%{$ai_seq_args[0]{'forceGiveup'}})) {
				$ai_seq_args[0]{'time'} -= $ai_seq_args[0]{'timeout'};
			}
		}
	}


	##### CHECK FOR UPDATES #####
	# We force the user to download an update if this version of kore is too old.
	# This is to prevent bots from KSing people because of new packets
	# (like it happened with Comodo and Juno).
	if (!($Settings::VERSION =~ /CVS/) && !$checkUpdate{checked}) {
		if ($checkUpdate{stage} eq '') {
			# We only want to check at most once a day
			open(F, "< $Settings::tables_folder/updatecheck.txt");
			my $time = <F>;
			close F;

			$time =~ s/[\r\n].*//;
			if (timeOut($time, 60 * 60 * 24)) {
				$checkUpdate{stage} = 'Connect';
			} else {
				$checkUpdate{checked} = 1;
				debug "Version up-to-date\n";
			}

		} elsif ($checkUpdate{stage} eq 'Connect') {
			my $sock = new IO::Socket::INET(
				PeerHost	=> 'openkore.sourceforge.net',
				PeerPort	=> 80,
				Proto		=> 'tcp',
				Timeout		=> 4
			);
			if (!$sock) {
				$checkUpdate{checked} = 1;
			} else {
				$checkUpdate{sock} = $sock;
				$checkUpdate{stage} = 'Request';
			}

		} elsif ($checkUpdate{stage} eq 'Request') {
			$checkUpdate{sock}->send("GET /misc/leastVersion.txt HTTP/1.1\r\n", 0);
			$checkUpdate{sock}->send("Host: openkore.sourceforge.net\r\n\r\n", 0);
			$checkUpdate{sock}->flush;
			$checkUpdate{stage} = 'Receive';

		} elsif ($checkUpdate{stage} eq 'Receive' && dataWaiting(\$checkUpdate{sock})) {
			my $data;
			$checkUpdate{sock}->recv($data, 1024 * 32);
			if ($data =~ /^HTTP\/.\.. 200/s) {
				$data =~ s/.*?\r\n\r\n//s;
				$data =~ s/[\r\n].*//s;

				debug "Update check - least version: $data\n";
				unless (($Settings::VERSION cmp $data) >= 0) {
					Network::disconnect(\$remote_socket);
					$interface->errorDialog("Your version of $Settings::NAME " .
						"(${Settings::VERSION}${Settings::CVS}) is too old.\n" .
						"Please upgrade to at least version $data\n");
					quit();

				} else {
					# Store the current time in a file
					open(F, "> $Settings::tables_folder/updatecheck.txt");
					print F time;
					close F;
				}
			}

			$checkUpdate{sock}->close;
			undef %checkUpdate;
			$checkUpdate{checked} = 1;
		}
	}

	##### TALK WITH NPC ######
	NPCTALK: {
		last NPCTALK if ($ai_seq[0] ne "NPC");
		$ai_seq_args[0]{'time'} = time unless $ai_seq_args[0]{'time'};

		if ($ai_seq_args[0]{'stage'} eq '') {
			if (timeOut($ai_seq_args[0]{'time'}, $timeout{'ai_npcTalk'}{'timeout'})) {
				error "Could not find the NPC at the designated location.\n", "ai_npcTalk";
				shift @ai_seq;
				shift @ai_seq_args;

			} elsif ($ai_seq_args[0]{'nameID'}) {
				# An NPC ID has been passed
				my $npc = pack("L1", $ai_seq_args[0]{'nameID'});
				last if (!$npcs{$npc} || $npcs{$npc}{'name'} eq '' || $npcs{$npc}{'name'} =~ /Unknown/i);
				$ai_seq_args[0]{'ID'} = $npc;
				$ai_seq_args[0]{'name'} = $npcs{$npc}{'name'};
				$ai_seq_args[0]{'stage'} = 'Talking to NPC';
				@{$ai_seq_args[0]{'steps'}} = split /\s+/, "w3 x $ai_seq_args[0]{'sequence'}";
				undef $ai_seq_args[0]{'time'};
				undef $ai_v{'npc_talk'}{'time'};

			} else {
				# An x,y position has been passed
				foreach my $npc (@npcsID) {
					next if !$npc || $npcs{$npc}{'name'} eq '' || $npcs{$npc}{'name'} =~ /Unknown/i;
					if ( $npcs{$npc}{'pos'}{'x'} eq $ai_seq_args[0]{'pos'}{'x'} &&
					     $npcs{$npc}{'pos'}{'y'} eq $ai_seq_args[0]{'pos'}{'y'} ) {
						debug "Target NPC $npcs{$npc}{'name'} at ($ai_seq_args[0]{'pos'}{'x'},$ai_seq_args[0]{'pos'}{'y'}) found.\n", "ai_npcTalk";
					     	$ai_seq_args[0]{'nameID'} = $npcs{$npc}{'nameID'};
				     		$ai_seq_args[0]{'ID'} = $npc;
					     	$ai_seq_args[0]{'name'} = $npcs{$npc}{'name'};
						$ai_seq_args[0]{'stage'} = 'Talking to NPC';
						@{$ai_seq_args[0]{'steps'}} = split /\s+/, "w3 x $ai_seq_args[0]{'sequence'}";
						undef $ai_seq_args[0]{'time'};
						undef $ai_v{'npc_talk'}{'time'};
						last;
					}
				}
			}


		} elsif ($ai_seq_args[0]{'mapChanged'} || @{$ai_seq_args[0]{'steps'}} == 0) {
			message "Done talking with $ai_seq_args[0]{'name'}.\n", "ai_npcTalk";
			sendTalkCancel(\$remote_socket, $ai_seq_args[0]{'ID'});
			shift @ai_seq;
			shift @ai_seq_args;

		} elsif (timeOut($ai_seq_args[0]{'time'}, $timeout{'ai_npcTalk'}{'timeout'})) {
			# If NPC does not respond before timing out, then by default, it's a failure
			error "NPC did not respond.\n", "ai_npcTalk";
			sendTalkCancel(\$remote_socket, $ai_seq_args[0]{'ID'});
			shift @ai_seq;
			shift @ai_seq_args;

		} elsif (timeOut($ai_v{'npc_talk'}{'time'}, 0.25)) {
			$ai_seq_args[0]{'time'} = time;
			$ai_v{'npc_talk'}{'time'} = time + $timeout{'ai_npcTalk'}{'timeout'} + 5;

			if ($ai_seq_args[0]{'steps'}[0] =~ /w(\d+)/i) {
				my $time = $1;
				$ai_v{'npc_talk'}{'time'} = time + $time;
				$ai_seq_args[0]{'time'}   = time + $time;
			} elsif ( $ai_seq_args[0]{'steps'}[0] =~ /x/i ) {
				sendTalk(\$remote_socket, $ai_seq_args[0]{'ID'});
			} elsif ( $ai_seq_args[0]{'steps'}[0] =~ /c/i ) {
				sendTalkContinue(\$remote_socket, $ai_seq_args[0]{'ID'});
			} elsif ( $ai_seq_args[0]{'steps'}[0] =~ /r(\d+)/i ) {
				sendTalkResponse(\$remote_socket, $ai_seq_args[0]{'ID'}, $1+1);
			} elsif ( $ai_seq_args[0]{'steps'}[0] =~ /n/i ) {
				sendTalkCancel(\$remote_socket, $ai_seq_args[0]{'ID'});
				$ai_v{'npc_talk'}{'time'} = time;
				$ai_seq_args[0]{'time'}   = time;
			} elsif ( $ai_seq_args[0]{'steps'}[0] =~ /b/i ) {
				sendGetStoreList(\$remote_socket, $ai_seq_args[0]{'ID'});
			}
			shift @{$ai_seq_args[0]{'steps'}};
		}
	}


	#####STORAGE GET#####
	# Get one or more items from storage.

	if ($ai_seq[0] eq "storageGet" && timeOut($ai_seq_args[0])) {
		my $item = $ai_seq_args[0]{'items'}[0];
		my $amount = $ai_seq_args[0]{'max'};

		if (!$amount || $amount > $storage{$storageID[$item]}{'amount'}) {
			$amount = $storage{$storageID[$item]}{'amount'};
		}
		sendStorageGet(\$remote_socket, $storage{$storageID[$item]}{'index'}, $amount);
		shift @{$ai_seq_args[0]{'items'}};
		$ai_seq_args[0]{'time'} = time;

		if (@{$ai_seq_args[0]{'items'}} <= 0) {
			shift @ai_seq;
			shift @ai_seq_args;
		}
	}


	#####DROPPING#####
	# Drop one or more items from inventory.

	if ($ai_seq[0] eq "drop" && timeOut($ai_seq_args[0])) {
		my $item = $ai_seq_args[0]{'items'}[0];
		my $amount = $ai_seq_args[0]{'max'};

		if (!$amount || $amount > $chars[$config{'char'}]{'inventory'}[$item]{'amount'}) {
			$amount = $chars[$config{'char'}]{'inventory'}[$item]{'amount'};
		}
		sendDrop(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$item]{'index'}, $amount);
		shift @{$ai_seq_args[0]{'items'}};
		$ai_seq_args[0]{'time'} = time;

		if (@{$ai_seq_args[0]{'items'}} <= 0) {
			shift @ai_seq;
			shift @ai_seq_args;
		}
	}


	#storageAuto - chobit aska 20030128
	#####AUTO STORAGE#####

	AUTOSTORAGE: {

	if (($ai_seq[0] eq "" || $ai_seq[0] eq "route" || $ai_seq[0] eq "sitAuto" || $ai_seq[0] eq "follow") && $config{'storageAuto'} && $config{'storageAuto_npc'} ne ""
	  && (($config{'itemsMaxWeight_sellOrStore'} && percent_weight(\%{$chars[$config{'char'}]}) >= $config{'itemsMaxWeight_sellOrStore'})
	      || (!$config{'itemsMaxWeight_sellOrStore'} && percent_weight(\%{$chars[$config{'char'}]}) >= $config{'itemsMaxWeight'})
	  )) {
		$ai_v{'temp'}{'ai_route_index'} = binFind(\@ai_seq, "route");
		if ($ai_v{'temp'}{'ai_route_index'} ne "") {
			$ai_v{'temp'}{'ai_route_attackOnRoute'} = $ai_seq_args[$ai_v{'temp'}{'ai_route_index'}]{'attackOnRoute'};
		}
		if (!($ai_v{'temp'}{'ai_route_index'} ne "" && $ai_v{'temp'}{'ai_route_attackOnRoute'} <= 1) && ai_storageAutoCheck()) {
			unshift @ai_seq, "storageAuto";
			unshift @ai_seq_args, {};
		}
	} elsif (($ai_seq[0] eq "" || $ai_seq[0] eq "route" || $ai_seq[0] eq "attack")
	      && $config{'storageAuto'} && $config{'storageAuto_npc'} ne "" && timeOut(\%{$timeout{'ai_storageAuto'}})) {
		undef $ai_v{'temp'}{'found'};
		$i = 0;
		while (1) {
			last if (!$config{"getAuto_$i"});
			$ai_v{'temp'}{'invIndex'} = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"getAuto_$i"});
			
			if ($config{"getAuto_$i"."_minAmount"} ne "" && $config{"getAuto_$i"."_maxAmount"} ne "" && findKeyString(\%storage, "name", $config{"getAuto_$ai_seq_args[0]{index}"}) ne ""
			   && !$config{"getAuto_$i"."_passive"}
			   && ($ai_v{'temp'}{'invIndex'} eq ""
			       || ($chars[$config{'char'}]{'inventory'}[$ai_v{'temp'}{'invIndex'}]{'amount'} <= $config{"getAuto_$i"."_minAmount"}
			           && $chars[$config{'char'}]{'inventory'}[$ai_v{'temp'}{'invIndex'}]{'amount'} < $config{"getAuto_$i"."_maxAmount"})
			      )
			   ) {
				$ai_v{'temp'}{'found'} = 1;
			}
			$i++;
		}

		$ai_v{'temp'}{'ai_route_index'} = binFind(\@ai_seq, "route");
		if ($ai_v{'temp'}{'ai_route_index'} ne "") {
			$ai_v{'temp'}{'ai_route_attackOnRoute'} = $ai_seq_args[$ai_v{'temp'}{'ai_route_index'}]{'attackOnRoute'};
		}
		if (!($ai_v{'temp'}{'ai_route_index'} ne "" && $ai_v{'temp'}{'ai_route_attackOnRoute'} <= 1) && $ai_v{'temp'}{'found'}) {
			unshift @ai_seq, "storageAuto";
			unshift @ai_seq_args, {};
		}
		$timeout{'ai_storageAuto'}{'time'} = time;
	}

	if ($ai_seq[0] eq "storageAuto" && $ai_seq_args[0]{'done'}) {
		$ai_v{'temp'}{'var'} = $ai_seq_args[0]{'forcedBySell'};
		shift @ai_seq;
		shift @ai_seq_args;
		if (!$ai_v{'temp'}{'var'}) {
			unshift @ai_seq, "sellAuto";
			unshift @ai_seq_args, {forcedByStorage => 1};
		}
	} elsif ($ai_seq[0] eq "storageAuto" && timeOut(\%{$timeout{'ai_storageAuto'}})) {
		getNPCInfo($config{'storageAuto_npc'}, \%{$ai_seq_args[0]{'npc'}});
		if (!$config{'storageAuto'} || !defined($ai_seq_args[0]{'npc'}{'ok'})) {
			$ai_seq_args[0]{'done'} = 1;
			last AUTOSTORAGE;
		}

		undef $ai_v{'temp'}{'do_route'};
		if ($field{'name'} ne $ai_seq_args[0]{'npc'}{'map'}) {
			$ai_v{'temp'}{'do_route'} = 1;
		} else {
			$ai_v{'temp'}{'distance'} = distance(\%{$ai_seq_args[0]{'npc'}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}});
			if ($ai_v{'temp'}{'distance'} > $config{'storageAuto_distance'}) {
				$ai_v{'temp'}{'do_route'} = 1;
			}
		}
		if ($ai_v{'temp'}{'do_route'}) {
			if ($ai_seq_args[0]{'warpedToSave'} && !$ai_seq_args[0]{'mapChanged'}) {
				undef $ai_seq_args[0]{'warpedToSave'};
			}

			if ($config{'saveMap'} ne "" && $config{'saveMap_warpToBuyOrSell'} && !$ai_seq_args[0]{'warpedToSave'} 
				&& !$cities_lut{$field{'name'}.'.rsw'}) {
				$ai_seq_args[0]{'warpedToSave'} = 1;
				useTeleport(2);
				$timeout{'ai_storageAuto'}{'time'} = time;
			} else {
				message "Calculating auto-storage route to: $maps_lut{$ai_seq_args[0]{'npc'}{'map'}.'.rsw'}($ai_seq_args[0]{'npc'}{'map'}): $ai_seq_args[0]{'npc'}{'pos'}{'x'}, $ai_seq_args[0]{'npc'}{'pos'}{'y'}\n", "route";
				ai_route($ai_seq_args[0]{'npc'}{'map'}, $ai_seq_args[0]{'npc'}{'pos'}{'x'}, $ai_seq_args[0]{'npc'}{'pos'}{'y'},
					attackOnRoute => 1,
					distFromGoal => $config{'storageAuto_distance'});
			}
		} else {
			if (!defined($ai_seq_args[0]{'sentStore'})) {
				if ($config{'storageAuto_npc_type'} eq "" || $config{'storageAuto_npc_type'} eq "1") {
					warning "Warning storageAuto has changed. Please read News.txt\n" if ($config{'storageAuto_npc_type'} eq "");
					$config{'storageAuto_npc_steps'} = "c r1 n";
					debug "Using standard iRO npc storage steps.\n", "npc";				
				} elsif ($config{'storageAuto_npc_type'} eq "2") {
					$config{'storageAuto_npc_steps'} = "c c r1 n";
					debug "Using iRO comodo (location) npc storage steps.\n", "npc";
				} elsif ($config{'storageAuto_npc_type'} eq "3") {
					message "Using storage steps defined in config.\n", "info";
				} elsif ($config{'storageAuto_npc_type'} ne "" && $config{'storageAuto_npc_type'} ne "1" && $config{'storageAuto_npc_type'} ne "2" && $config{'storageAuto_npc_type'} ne "3") {
					error "Something is wrong with storageAuto_npc_type in your config.\n";
				}

				undef $ai_v{temp}{storage_opened};
				$ai_seq_args[0]{'sentStore'} = 1;
				
				if (defined $ai_seq_args[0]{'npc'}{'id'}) { 
					ai_talkNPC(ID => $ai_seq_args[0]{'npc'}{'id'}, $config{'storageAuto_npc_steps'}); 
				} else {
					ai_talkNPC($ai_seq_args[0]{'npc'}{'pos'}{'x'}, $ai_seq_args[0]{'npc'}{'pos'}{'y'}, $config{'storageAuto_npc_steps'}); 
				}

				$timeout{'ai_storageAuto'}{'time'} = time;
				last AUTOSTORAGE;
			}
			
			if (!defined $ai_v{temp}{storage_opened}) {
				last AUTOSTORAGE;
			}
			
			if (!$ai_seq_args[0]{'getStart'}) {
				$ai_seq_args[0]{'done'} = 1;
				for (my $i = 0; $i < @{$chars[$config{'char'}]{'inventory'}}; $i++) {
					next if (!%{$chars[$config{'char'}]{'inventory'}[$i]} || $chars[$config{'char'}]{'inventory'}[$i]{'equipped'});
					if ($items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})}{'storage'}
						&& $chars[$config{'char'}]{'inventory'}[$i]{'amount'} > $items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})}{'keep'}) {
						if ($ai_seq_args[0]{'lastIndex'} ne "" && $ai_seq_args[0]{'lastIndex'} == $chars[$config{'char'}]{'inventory'}[$i]{'index'}
							&& timeOut(\%{$timeout{'ai_storageAuto_giveup'}})) {
							last AUTOSTORAGE;
						} elsif ($ai_seq_args[0]{'lastIndex'} eq "" || $ai_seq_args[0]{'lastIndex'} != $chars[$config{'char'}]{'inventory'}[$i]{'index'}) {
							$timeout{'ai_storageAuto_giveup'}{'time'} = time;
						}
						undef $ai_seq_args[0]{'done'};
						$ai_seq_args[0]{'lastIndex'} = $chars[$config{'char'}]{'inventory'}[$i]{'index'};
						sendStorageAdd(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$i]{'index'}, $chars[$config{'char'}]{'inventory'}[$i]{'amount'} - $items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})}{'keep'});
						$timeout{'ai_storageAuto'}{'time'} = time;
						last AUTOSTORAGE;
					}
				}
			}
			
			# getAuto begin
			
			if (!$ai_seq_args[0]{getStart} && $ai_seq_args[0]{done} == 1) {
				$ai_seq_args[0]{getStart} = 1;
				undef $ai_seq_args[0]{done};
				$ai_seq_args[0]{index} = 0;
				$ai_seq_args[0]{retry} = 0;

				last AUTOSTORAGE;
			}
			
			if (defined($ai_seq_args[0]{getStart}) && $ai_seq_args[0]{done} != 1) {

				my %item;
				while ($config{"getAuto_$ai_seq_args[0]{index}"}) {
					undef %item;
					$item{name} = $config{"getAuto_$ai_seq_args[0]{index}"};
					$item{inventory}{index} = findIndexString_lc(\@{$chars[$config{char}]{inventory}}, "name", $item{name});
					$item{inventory}{amount} = ($item{inventory}{index} ne "")? $chars[$config{char}]{inventory}[$item{inventory}{index}]{amount}: 0;
					$item{storage}{index} = findKeyString(\%storage, "name", $item{name});
					$item{storage}{amount} = ($item{storage}{index} ne "")? $storage{$item{storage}{index}}{amount} : 0;
					$item{max_amount} = $config{"getAuto_$ai_seq_args[0]{index}"."_maxAmount"};
					$item{amount_needed} = $item{max_amount} - $item{inventory}{amount};
					
					if ($item{amount_needed} > 0) {
						$item{amount_get} = ($item{storage}{amount} >= $item{amount_needed})? $item{amount_needed} : $item{storage}{amount};
					}
					
					if (($item{amount_get} > 0) && ($ai_seq_args[0]{retry} < 3)) {
						message "Attempt to get $item{amount_get} x $item{name} from storage, retry: $ai_seq_args[0]{retry}\n", "storage", 1;
						sendStorageGet(\$remote_socket, $item{storage}{index}, $item{amount_get});
						$timeout{ai_storageAuto}{time} = time;
						$ai_seq_args[0]{retry}++;
						last AUTOSTORAGE;
						
						# we don't inc the index when amount_get is more then 0, this will enable a way of retrying
						# on next loop if it fails this time
					}
					
					if ($item{storage}{amount} < $item{amount_needed}) {
						warning "storage: $item{name} out of stock\n";
					}
	
					# otherwise, increment the index
					$ai_seq_args[0]{index}++;
					$ai_seq_args[0]{retry} = 0;
				}
			}
			
			sendStorageClose(\$remote_socket);
			$ai_seq_args[0]{done} = 1;
		}
	}
	} #END OF BLOCK AUTOSTORAGE



	#####AUTO SELL#####

	AUTOSELL: {

	if (($ai_seq[0] eq "" || $ai_seq[0] eq "route" || $ai_seq[0] eq "sitAuto" || $ai_seq[0] eq "follow") && $config{'sellAuto'} && $config{'sellAuto_npc'} ne ""
	  && (($config{'itemsMaxWeight_sellOrStore'} && percent_weight(\%{$chars[$config{'char'}]}) >= $config{'itemsMaxWeight_sellOrStore'})
	      || (!$config{'itemsMaxWeight_sellOrStore'} && percent_weight(\%{$chars[$config{'char'}]}) >= $config{'itemsMaxWeight'})
	  )) {
		$ai_v{'temp'}{'ai_route_index'} = binFind(\@ai_seq, "route");
		if ($ai_v{'temp'}{'ai_route_index'} ne "") {
			$ai_v{'temp'}{'ai_route_attackOnRoute'} = $ai_seq_args[$ai_v{'temp'}{'ai_route_index'}]{'attackOnRoute'};
		}
		if (!($ai_v{'temp'}{'ai_route_index'} ne "" && $ai_v{'temp'}{'ai_route_attackOnRoute'} <= 1) && ai_sellAutoCheck()) {
			unshift @ai_seq, "sellAuto";
			unshift @ai_seq_args, {};
		}
	}

	if ($ai_seq[0] eq "sellAuto" && $ai_seq_args[0]{'done'}) {
		$ai_v{'temp'}{'var'} = $ai_seq_args[0]{'forcedByBuy'};
		shift @ai_seq;
		shift @ai_seq_args;
		if (!$ai_v{'temp'}{'var'}) {
			unshift @ai_seq, "buyAuto";
			unshift @ai_seq_args, {forcedBySell => 1};
		}
	} elsif ($ai_seq[0] eq "sellAuto" && timeOut(\%{$timeout{'ai_sellAuto'}})) {
		getNPCInfo($config{'sellAuto_npc'}, \%{$ai_seq_args[0]{'npc'}});
		if (!$config{'sellAuto'} || !defined($ai_seq_args[0]{'npc'}{'ok'})) {
			$ai_seq_args[0]{'done'} = 1;
			last AUTOSELL;
		}

		undef $ai_v{'temp'}{'do_route'};
		if ($field{'name'} ne $ai_seq_args[0]{'npc'}{'map'}) {
			$ai_v{'temp'}{'do_route'} = 1;
		} else {
			$ai_v{'temp'}{'distance'} = distance(\%{$ai_seq_args[0]{'npc'}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}});
			if ($ai_v{'temp'}{'distance'} > $config{'sellAuto_distance'}) {
				$ai_v{'temp'}{'do_route'} = 1;
			}
		}
		if ($ai_v{'temp'}{'do_route'}) {
			if ($ai_seq_args[0]{'warpedToSave'} && !$ai_seq_args[0]{'mapChanged'}) {
				undef $ai_seq_args[0]{'warpedToSave'};
			}

			if ($config{'saveMap'} ne "" && $config{'saveMap_warpToBuyOrSell'} && !$ai_seq_args[0]{'warpedToSave'} 
				&& !$cities_lut{$field{'name'}.'.rsw'}) {
				$ai_seq_args[0]{'warpedToSave'} = 1;
				useTeleport(2);
				$timeout{'ai_sellAuto'}{'time'} = time;
			} else {
				message "Calculating auto-sell route to: $maps_lut{$ai_seq_args[0]{'npc'}{'map'}.'.rsw'}($ai_seq_args[0]{'npc'}{'map'}): $ai_seq_args[0]{'npc'}{'pos'}{'x'}, $ai_seq_args[0]{'npc'}{'pos'}{'y'}\n", "route";
				ai_route($ai_seq_args[0]{'npc'}{'map'}, $ai_seq_args[0]{'npc'}{'pos'}{'x'}, $ai_seq_args[0]{'npc'}{'pos'}{'y'},
					attackOnRoute => 1,
					distFromGoal => $config{'sellAuto_distance'});
			}
		} else {
			if (!defined($ai_seq_args[0]{'sentSell'})) {
				$ai_seq_args[0]{'sentSell'} = 1;
				
				if (defined $ai_seq_args[0]{'npc'}{'id'}) { 
					ai_talkNPC(ID => $ai_seq_args[0]{'npc'}{'id'}, "b"); 
				} else {
					ai_talkNPC($ai_seq_args[0]{'npc'}{'pos'}{'x'}, $ai_seq_args[0]{'npc'}{'pos'}{'y'}, "b"); 
				}
				last AUTOSELL;
			}
			$ai_seq_args[0]{'done'} = 1;
			for ($i = 0; $i < @{$chars[$config{'char'}]{'inventory'}};$i++) {
				next if (!%{$chars[$config{'char'}]{'inventory'}[$i]} || $chars[$config{'char'}]{'inventory'}[$i]{'equipped'});
				if ($items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})}{'sell'}
					&& $chars[$config{'char'}]{'inventory'}[$i]{'amount'} > $items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})}{'keep'}) {
					if ($ai_seq_args[0]{'lastIndex'} ne "" && $ai_seq_args[0]{'lastIndex'} == $chars[$config{'char'}]{'inventory'}[$i]{'index'}
						&& timeOut(\%{$timeout{'ai_sellAuto_giveup'}})) {
						last AUTOSELL;
					} elsif ($ai_seq_args[0]{'lastIndex'} eq "" || $ai_seq_args[0]{'lastIndex'} != $chars[$config{'char'}]{'inventory'}[$i]{'index'}) {
						$timeout{'ai_sellAuto_giveup'}{'time'} = time;
					}
					undef $ai_seq_args[0]{'done'};
					$ai_seq_args[0]{'lastIndex'} = $chars[$config{'char'}]{'inventory'}[$i]{'index'};
					sendSell(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$i]{'index'}, $chars[$config{'char'}]{'inventory'}[$i]{'amount'} - $items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})}{'keep'});
					$timeout{'ai_sellAuto'}{'time'} = time;
					last AUTOSELL;
				}
			}
		}
	}

	} #END OF BLOCK AUTOSELL



	#####AUTO BUY#####

	AUTOBUY: {

	if (($ai_seq[0] eq "" || $ai_seq[0] eq "route"  || $ai_seq[0] eq "attack" || $ai_seq[0] eq "follow")
	  && timeOut(\%{$timeout{'ai_buyAuto'}})) {
		undef $ai_v{'temp'}{'found'};
		$i = 0;
		while (1) {
			last if (!$config{"buyAuto_$i"} || !$config{"buyAuto_$i"."_npc"});
			$ai_v{'temp'}{'invIndex'} = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"buyAuto_$i"});
			if ($config{"buyAuto_$i"."_minAmount"} ne "" && $config{"buyAuto_$i"."_maxAmount"} ne ""
				&& ($ai_v{'temp'}{'invIndex'} eq ""
				|| ($chars[$config{'char'}]{'inventory'}[$ai_v{'temp'}{'invIndex'}]{'amount'} <= $config{"buyAuto_$i"."_minAmount"}
				&& $chars[$config{'char'}]{'inventory'}[$ai_v{'temp'}{'invIndex'}]{'amount'} < $config{"buyAuto_$i"."_maxAmount"}))) {
				$ai_v{'temp'}{'found'} = 1;
			}
			$i++;
		}
		$ai_v{'temp'}{'ai_route_index'} = binFind(\@ai_seq, "route");
		if ($ai_v{'temp'}{'ai_route_index'} ne "") {
			$ai_v{'temp'}{'ai_route_attackOnRoute'} = $ai_seq_args[$ai_v{'temp'}{'ai_route_index'}]{'attackOnRoute'};
		}
		if (!($ai_v{'temp'}{'ai_route_index'} ne "" && $ai_v{'temp'}{'ai_route_attackOnRoute'} <= 1) && $ai_v{'temp'}{'found'}) {
			unshift @ai_seq, "buyAuto";
			unshift @ai_seq_args, {};
		}
		$timeout{'ai_buyAuto'}{'time'} = time;
	}

	if ($ai_seq[0] eq "buyAuto" && $ai_seq_args[0]{'done'}) {
		$ai_v{'temp'}{'var'} = $ai_seq_args[0]{'forcedBySell'};
		shift @ai_seq;
		shift @ai_seq_args;
		if (!$ai_v{'temp'}{'var'} && ai_sellAutoCheck()) {
			unshift @ai_seq, "sellAuto";
			unshift @ai_seq_args, {forcedByBuy => 1};
		}
	} elsif ($ai_seq[0] eq "buyAuto" && timeOut(\%{$timeout{'ai_buyAuto_wait'}}) && timeOut(\%{$timeout{'ai_buyAuto_wait_buy'}})) {
		$i = 0;
		undef $ai_seq_args[0]{'index'};
		
		while (1) {
			last if (!$config{"buyAuto_$i"});
			$ai_seq_args[0]{'invIndex'} = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"buyAuto_$i"});
			if (!$ai_seq_args[0]{'index_failed'}{$i} && $config{"buyAuto_$i"."_maxAmount"} ne "" && ($ai_seq_args[0]{'invIndex'} eq "" 
				|| $chars[$config{'char'}]{'inventory'}[$ai_seq_args[0]{'invIndex'}]{'amount'} < $config{"buyAuto_$i"."_maxAmount"})) {

				getNPCInfo($config{"buyAuto_$i"."_npc"}, \%{$ai_seq_args[0]{'npc'}});
				if (defined $ai_seq_args[0]{'npc'}{'ok'}) {
					$ai_seq_args[0]{'index'} = $i;
				}
				last;
			}
			$i++;
		}
		if ($ai_seq_args[0]{'index'} eq ""
			|| ($ai_seq_args[0]{'lastIndex'} ne "" && $ai_seq_args[0]{'lastIndex'} == $ai_seq_args[0]{'index'}
			&& timeOut(\%{$timeout{'ai_buyAuto_giveup'}}))) {
			$ai_seq_args[0]{'done'} = 1;
			last AUTOBUY;
		}
		undef $ai_v{'temp'}{'do_route'};
		if ($field{'name'} ne $ai_seq_args[0]{'npc'}{'map'}) {
			$ai_v{'temp'}{'do_route'} = 1;			
		} else {
			$ai_v{'temp'}{'distance'} = distance(\%{$ai_seq_args[0]{'npc'}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}});
			if ($ai_v{'temp'}{'distance'} > $config{"buyAuto_$ai_seq_args[0]{'index'}"."_distance"}) {
				$ai_v{'temp'}{'do_route'} = 1;
			}
		}
		if ($ai_v{'temp'}{'do_route'}) {
			if ($ai_seq_args[0]{'warpedToSave'} && !$ai_seq_args[0]{'mapChanged'}) {
				undef $ai_seq_args[0]{'warpedToSave'};
			}

			if ($config{'saveMap'} ne "" && $config{'saveMap_warpToBuyOrSell'} && !$ai_seq_args[0]{'warpedToSave'} 
				&& !$cities_lut{$field{'name'}.'.rsw'}) {
				$ai_seq_args[0]{'warpedToSave'} = 1;
				useTeleport(2);
				$timeout{'ai_buyAuto_wait'}{'time'} = time;
			} else {
				message qq~Calculating auto-buy route to: $maps_lut{$ai_seq_args[0]{'npc'}{'map'}.'.rsw'}($ai_seq_args[0]{'npc'}{'map'}): $ai_seq_args[0]{'npc'}{'pos'}{'x'}, $ai_seq_args[0]{'npc'}{'pos'}{'y'}\n~, "route";
				ai_route($ai_seq_args[0]{'npc'}{'map'}, $ai_seq_args[0]{'npc'}{'pos'}{'x'}, $ai_seq_args[0]{'npc'}{'pos'}{'y'},
					attackOnRoute => 1,
					distFromGoal => $config{"buyAuto_$ai_seq_args[0]{'index'}"."_distance"});
			}
		} else {
			if ($ai_seq_args[0]{'lastIndex'} eq "" || $ai_seq_args[0]{'lastIndex'} != $ai_seq_args[0]{'index'}) {
				undef $ai_seq_args[0]{'itemID'};
				if ($config{"buyAuto_$ai_seq_args[0]{'index'}"."_npc"} != $config{"buyAuto_$ai_seq_args[0]{'lastIndex'}"."_npc"}) {
					undef $ai_seq_args[0]{'sentBuy'};
				}
				$timeout{'ai_buyAuto_giveup'}{'time'} = time;
			}
			$ai_seq_args[0]{'lastIndex'} = $ai_seq_args[0]{'index'};
			if ($ai_seq_args[0]{'itemID'} eq "") {
				foreach (keys %items_lut) {
					if (lc($items_lut{$_}) eq lc($config{"buyAuto_$ai_seq_args[0]{'index'}"})) {
						$ai_seq_args[0]{'itemID'} = $_;
					}
				}
				if ($ai_seq_args[0]{'itemID'} eq "") {
					$ai_seq_args[0]{'index_failed'}{$ai_seq_args[0]{'index'}} = 1;
					debug "autoBuy index $ai_seq_args[0]{'index'} failed\n", "npc";
					last AUTOBUY;
				}
			}

			if (!defined($ai_seq_args[0]{'sentBuy'})) {
				$ai_seq_args[0]{'sentBuy'} = 1;
				$timeout{'ai_buyAuto_wait'}{'time'} = time;
				if (defined $ai_seq_args[0]{'npc'}{'id'}) { 
					ai_talkNPC(ID => $ai_seq_args[0]{'npc'}{'id'}, "b"); 
				} else {
					ai_talkNPC($ai_seq_args[0]{'npc'}{'pos'}{'x'}, $ai_seq_args[0]{'npc'}{'pos'}{'y'}, "b"); 
				}
				last AUTOBUY;
			}	
			if ($ai_seq_args[0]{'invIndex'} ne "") {
				sendBuy(\$remote_socket, $ai_seq_args[0]{'itemID'}, $config{"buyAuto_$ai_seq_args[0]{'index'}"."_maxAmount"} - $chars[$config{'char'}]{'inventory'}[$ai_seq_args[0]{'invIndex'}]{'amount'});
			} else {
				sendBuy(\$remote_socket, $ai_seq_args[0]{'itemID'}, $config{"buyAuto_$ai_seq_args[0]{'index'}"."_maxAmount"});
			}
			$timeout{'ai_buyAuto_wait_buy'}{'time'} = time;
		}
	}

	} #END OF BLOCK AUTOBUY


	##### LOCKMAP #####

	%{$ai_v{'temp'}{'lockMap_coords'}} = ();
	$ai_v{'temp'}{'lockMap_coords'}{'x'} = $config{'lockMap_x'} + ((int(rand(3))-1)*(int(rand($config{'lockMap__randX'}))+1));
	$ai_v{'temp'}{'lockMap_coords'}{'y'} = $config{'lockMap_y'} + ((int(rand(3))-1)*(int(rand($config{'lockMap__randY'}))+1));
	if ($ai_seq[0] eq "" && $config{'lockMap'} && $field{'name'}
		&& ($field{'name'} ne $config{'lockMap'} || ($config{'lockMap_x'} ne "" && $config{'lockMap_y'} ne "" 
		&& ($chars[$config{'char'}]{'pos_to'}{'x'} != $config{'lockMap_x'} || $chars[$config{'char'}]{'pos_to'}{'y'} != $config{'lockMap_y'}) 
		&& distance($ai_v{'temp'}{'lockMap_coords'}, $chars[$config{'char'}]{'pos_to'}) > 1.42))
	) {
		if ($maps_lut{$config{'lockMap'}.'.rsw'} eq "") {
			error "Invalid map specified for lockMap - map $config{'lockMap'} doesn't exist\n";
		} else {
			if ($config{'lockMap_x'} ne "" && $config{'lockMap_y'} ne "") {
				message "Calculating lockMap route to: $maps_lut{$config{'lockMap'}.'.rsw'}($config{'lockMap'}): $config{'lockMap_x'}, $config{'lockMap_y'}\n", "route";
			} else {
				message "Calculating lockMap route to: $maps_lut{$config{'lockMap'}.'.rsw'}($config{'lockMap'})\n", "route";
			}
			ai_route($config{'lockMap'}, $config{'lockMap_x'}, $config{'lockMap_y'},
				attackOnRoute => !$config{'attackAuto_inLockOnly'});
		}
	}
	undef $ai_v{'temp'}{'lockMap_coords'};


	##### RANDOM WALK #####
	if ($config{'route_randomWalk'} && $ai_seq[0] eq "" && @{$field{'field'}} > 1 && !$cities_lut{$field{'name'}.'.rsw'}) {
		# Find a random block on the map that we can walk on
		do { 
			$ai_v{'temp'}{'randX'} = int(rand() * ($field{'width'} - 1));
			$ai_v{'temp'}{'randY'} = int(rand() * ($field{'height'} - 1));
		} while ($field{'field'}[$ai_v{'temp'}{'randY'}*$field{'width'} + $ai_v{'temp'}{'randX'}]);

		# Move to that block
		message "Calculating random route to: $maps_lut{$field{'name'}.'.rsw'}($field{'name'}): $ai_v{'temp'}{'randX'}, $ai_v{'temp'}{'randY'}\n", "route";
		ai_route($field{'name'}, $ai_v{'temp'}{'randX'}, $ai_v{'temp'}{'randY'},
			maxRouteTime => $config{'route_randomWalk_maxRouteTime'},
			attackOnRoute => 2);
	}

	##### DEAD #####


	if ($ai_seq[0] eq "dead" && !$chars[$config{'char'}]{'dead'}) {
		shift @ai_seq;
		shift @ai_seq_args;

		if ($chars[$config{'char'}]{'resurrected'}) {
			# We've been resurrected
			$chars[$config{'char'}]{'resurrected'} = 0;

		} else {
			# Force storage after death
			unshift @ai_seq, "storageAuto";
			unshift @ai_seq_args, {};
		}

	} elsif ($ai_seq[0] ne "dead" && $chars[$config{'char'}]{'dead'}) {
		undef @ai_seq;
		undef @ai_seq_args;
		unshift @ai_seq, "dead";
		unshift @ai_seq_args, {};
	}

	if ($ai_seq[0] eq "dead" && $config{'dcOnDeath'} != -1 && time - $chars[$config{'char'}]{'dead_time'} >= $timeout{'ai_dead_respawn'}{'timeout'}) {
		sendRespawn(\$remote_socket);
		$chars[$config{'char'}]{'dead_time'} = time;
	}
	
	if ($ai_seq[0] eq "dead" && $config{'dcOnDeath'} && $config{'dcOnDeath'} != -1) {
		message "Disconnecting on death!\n";
		$quit = 1;
	}


	##### AUTO-ITEM USE #####


	if (($ai_seq[0] eq "" || $ai_seq[0] eq "route" || $ai_seq[0] eq "mapRoute"
		|| $ai_seq[0] eq "follow" || $ai_seq[0] eq "sitAuto" || $ai_seq[0] eq "take" || $ai_seq[0] eq "items_gather"
		|| $ai_seq[0] eq "items_take" || $ai_seq[0] eq "attack"
	    ) && timeOut(\%{$timeout{'ai_item_use_auto'}}))
	{
		$i = 0;
		while (1) {
			last if (!$config{"useSelf_item_$i"});
			if (percent_hp(\%{$chars[$config{'char'}]}) <= $config{"useSelf_item_$i"."_hp_upper"} && percent_hp(\%{$chars[$config{'char'}]}) >= $config{"useSelf_item_$i"."_hp_lower"}
			 && percent_sp(\%{$chars[$config{'char'}]}) <= $config{"useSelf_item_$i"."_sp_upper"} && percent_sp(\%{$chars[$config{'char'}]}) >= $config{"useSelf_item_$i"."_sp_lower"}
			 && !($config{"useSelf_item_$i"."_stopWhenHit"} && ai_getMonstersWhoHitMe())
			 && $config{"useSelf_item_$i"."_minAggressives"} <= ai_getAggressives()
			 && (!$config{"useSelf_item_$i"."_maxAggressives"} || $config{"useSelf_item_$i"."_maxAggressives"} >= ai_getAggressives()) 
			 && timeOut($ai_v{"useSelf_item_$i"."_time"}, $config{"useSelf_item_$i"."_timeout"})
			 && (!$config{"useSelf_item_$i"."_inLockOnly"} || ($config{"useSelf_item_$i"."_inLockOnly"} && $field{'name'} eq $config{'lockMap'}))
			 && (!$config{"useSelf_item_$i"."_whenStatusActive"} || whenStatusActive($config{"useSelf_item_$i"."_whenStatusActive"}))
			 && (!$config{"useSelf_item_$i"."_whenStatusInactive"} || !whenStatusActive($config{"useSelf_item_$i"."_whenStatusInactive"}))
			 && (!$config{"useSelf_item_$i"."_whenAffected"} || whenAffected($config{"useSelf_item_$i"."_whenAffected"}))
				)
				{
				undef $ai_v{'temp'}{'invIndex'};
				$ai_v{'temp'}{'invIndex'} = findIndexStringList_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"useSelf_item_$i"});
				if ($ai_v{'temp'}{'invIndex'} ne "") {
					sendItemUse(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$ai_v{'temp'}{'invIndex'}]{'index'}, $accountID);
					$ai_v{"useSelf_item_$i"."_time"} = time;
					$timeout{'ai_item_use_auto'}{'time'} = time;
					debug qq~Auto-item use: $items_lut{$chars[$config{'char'}]{'inventory'}[$ai_v{'temp'}{'invIndex'}]{'nameID'}}\n~, "npc";
					last;
				}
			}
			$i++;
		}
	}

	#Auto Equip - Kaldi Update 12/03/2004
	##### AUTO-EQUIP #####
	if (($ai_seq[0] eq "" || $ai_seq[0] eq "route" || $ai_seq[0] eq "mapRoute" || 
		 $ai_seq[0] eq "follow" || $ai_seq[0] eq "sitAuto" || 
		 $ai_seq[0] eq "take" || $ai_seq[0] eq "items_gather" || $ai_seq[0] eq "items_take" || 
		 $ai_seq[0] eq "attack")&& timeOut(\%{$timeout{'ai_equip_auto'}}) 
		){
		my $i = 0;
		my $ai_index_attack = binFind(\@ai_seq, "attack");
		my $ai_index_skill_use = binFind(\@ai_seq, "skill_use");
		while ($config{"equipAuto_$i"}) {
			#last if (!$config{"equipAuto_$i"});
			if (percent_hp(\%{$chars[$config{'char'}]}) <= $config{"equipAuto_$i" . "_hp_upper"}
			 && percent_hp(\%{$chars[$config{'char'}]}) >= $config{"equipAuto_$i" . "_hp_lower"}
			 && percent_sp(\%{$chars[$config{'char'}]}) <= $config{"equipAuto_$i" . "_sp_upper"}
			 && percent_sp(\%{$chars[$config{'char'}]}) >= $config{"equipAuto_$i" . "_sp_lower"}
			 && $config{"equipAuto_$i" . "_minAggressives"} <= ai_getAggressives()
			 && (!$config{"equipAuto_$i" . "_maxAggressives"} || $config{"equipAuto_$i" . "_maxAggressives"} >= ai_getAggressives())
			 && (!$config{"equipAuto_$i" . "_monsters"} || existsInList($config{"equipAuto_$i" . "_monsters"}, $monsters{$ai_seq_args[0]{'ID'}}{'name'}))
			 && (!$config{"equipAuto_$i" . "_weight"} || $chars[$config{'char'}]{'percent_weight'} >= $config{"equipAuto_$i" . "_weight"})
			 && ($config{"equipAuto_$i"."_whileSitting"} || !$chars[$config{'char'}]{'sitting'})
			 && (!$config{"equipAuto_$i" . "_skills"} || $ai_index_skill_use ne "" && existsInList($config{"equipAuto_$i" . "_skills"},$skillsID_lut{$ai_seq_args[$ai_index_skill_use]{'skill_use_id'}}))
			) {
				undef $ai_v{'temp'}{'invIndex'};
				$ai_v{'temp'}{'invIndex'} = findIndexString_lc_not_equip(\@{$chars[$config{'char'}]{'inventory'}},"name", $config{"equipAuto_$i"});
				if ($ai_v{'temp'}{'invIndex'} ne "") {
					sendEquip(\$remote_socket,$chars[$config{'char'}]{'inventory'}[$ai_v{'temp'}{'invIndex'}]{'index'},$chars[$config{'char'}]{'inventory'}[$ai_v{'temp'}{'invIndex'}]{'type_equip'});
					$timeout{'ai_item_equip_auto'}{'time'} = time;
					debug qq~Auto-equip: $items_lut{$chars[$config{'char'}]{'inventory'}[$ai_v{'temp'}{'invIndex'}]{'nameID'}}\n~ if $config{'debug'};
					last;
				}
			} elsif ($config{"equipAuto_$i" . "_def"} && !$chars[$config{'char'}]{'sitting'}) {
				undef $ai_v{'temp'}{'invIndex'};
				$ai_v{'temp'}{'invIndex'} = findIndexString_lc_not_equip(\@{$chars[$config{'char'}]{'inventory'}},"name", $config{"equipAuto_$i" . "_def"});
				if ($ai_v{'temp'}{'invIndex'} ne "") {
					sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$ai_v{'temp'}{'invIndex'}]{'index'},$chars[$config{'char'}]{'inventory'}[$ai_v{'temp'}{'invIndex'}]{'type_equip'});
					$timeout{'ai_item_equip_auto'}{'time'} = time;
					debug qq~Auto-equip: $items_lut{$chars[$config{'char'}]{'inventory'}[$ai_v{'temp'}{'invIndex'}]{'nameID'}}\n~ if $config{'debug'};
				}
			}
			$i++;
		}
	}


	##### AUTO-SKILL USE #####


	if ($ai_seq[0] eq "" || $ai_seq[0] eq "route" || $ai_seq[0] eq "mapRoute"
		|| $ai_seq[0] eq "follow" || $ai_seq[0] eq "sitAuto" || $ai_seq[0] eq "take" || $ai_seq[0] eq "items_gather" 
		|| $ai_seq[0] eq "items_take" || $ai_seq[0] eq "attack"
	) {
		$i = 0;
		undef $ai_v{'useSelf_skill'};
		undef $ai_v{'useSelf_skill_lvl'};
		while (1) {
			last if (!$config{"useSelf_skill_$i"});
			if (percent_hp(\%{$chars[$config{'char'}]}) <= $config{"useSelf_skill_$i"."_hp_upper"} && percent_hp(\%{$chars[$config{'char'}]}) >= $config{"useSelf_skill_$i"."_hp_lower"}
			 && percent_sp(\%{$chars[$config{'char'}]}) <= $config{"useSelf_skill_$i"."_sp_upper"} && percent_sp(\%{$chars[$config{'char'}]}) >= $config{"useSelf_skill_$i"."_sp_lower"}
			 && $chars[$config{'char'}]{'sp'} >= $skillsSP_lut{$skills_rlut{lc($config{"useSelf_skill_$i"})}}{$config{"useSelf_skill_$i"."_lvl"}}
			 && timeOut($ai_v{"useSelf_skill_$i"."_time"}, $config{"useSelf_skill_$i"."_timeout"})
			 && !($config{"useSelf_skill_$i"."_stopWhenHit"} && ai_getMonstersWhoHitMe())
			 && (!$config{"useSelf_skill_$i"."_inLockOnly"} || ($config{"useSelf_skill_$i"."_inLockOnly"} && $field{'name'} eq $config{'lockMap'}))
			 && $config{"useSelf_skill_$i"."_minAggressives"} <= ai_getAggressives()
			 && (!$config{"useSelf_skill_$i"."_maxAggressives"} || $config{"useSelf_skill_$i"."_maxAggressives"} >= ai_getAggressives())
			 && (!$config{"useSelf_skill_$i"."_whenStatusActive"} || whenStatusActive($config{"useSelf_skill_$i"."_whenStatusActive"}))
			 && (!$config{"useSelf_skill_$i"."_whenStatusInactive"} || !whenStatusActive($config{"useSelf_skill_$i"."_whenStatusInactive"}))
			 && (!$config{"useSelf_skill_$i"."_whenAffected"} || whenAffected($config{"useSelf_skill_$i"."_whenAffected"}))
			 && (!$config{"useSelf_skill_$i"."_notWhileSitting"} || !$chars[$config{'char'}]{'sitting'})
			 && (!$config{"useSelf_skill_$i"."_notInTown"} || !$cities_lut{$field{'name'}.'.rsw'})
			) {
				$ai_v{"useSelf_skill_$i"."_time"} = time;
				$ai_v{'useSelf_skill'} = $config{"useSelf_skill_$i"};
				$ai_v{'useSelf_skill_lvl'} = $config{"useSelf_skill_$i"."_lvl"};
				$ai_v{'useSelf_skill_maxCastTime'} = $config{"useSelf_skill_$i"."_maxCastTime"};
				$ai_v{'useSelf_skill_minCastTime'} = $config{"useSelf_skill_$i"."_minCastTime"};
				last;
			}
			$i++;
		}
		if ($config{'useSelf_skill_smartHeal'} && $skills_rlut{lc($ai_v{'useSelf_skill'})} eq "AL_HEAL") {
			undef $ai_v{'useSelf_skill_smartHeal_lvl'};
			$ai_v{'useSelf_skill_smartHeal_hp_dif'} = $chars[$config{'char'}]{'hp_max'} - $chars[$config{'char'}]{'hp'};
			for ($i = 1; $i <= $chars[$config{'char'}]{'skills'}{$skills_rlut{lc($ai_v{'useSelf_skill'})}}{'lv'}; $i++) {
				$ai_v{'useSelf_skill_smartHeal_lvl'} = $i;
				$ai_v{'useSelf_skill_smartHeal_sp'} = 10 + ($i * 3);
				$ai_v{'useSelf_skill_smartHeal_amount'} = int(($chars[$config{'char'}]{'lv'} + $chars[$config{'char'}]{'int'}) / 8)
						* (4 + $i * 8);
				if ($chars[$config{'char'}]{'sp'} < $ai_v{'useSelf_skill_smartHeal_sp'}) {
					$ai_v{'useSelf_skill_smartHeal_lvl'}--;
					last;
				}
				last if ($ai_v{'useSelf_skill_smartHeal_amount'} >= $ai_v{'useSelf_skill_smartHeal_hp_dif'});
			}
			$ai_v{'useSelf_skill_lvl'} = $ai_v{'useSelf_skill_smartHeal_lvl'};
		}
		if ($ai_v{'useSelf_skill_lvl'} > 0) {
			debug qq~Auto-skill on self: $skills_lut{$skills_rlut{lc($ai_v{'useSelf_skill'})}} (lvl $ai_v{'useSelf_skill_lvl'})\n~, "ai";
			if (!ai_getSkillUseType($skills_rlut{lc($ai_v{'useSelf_skill'})})) {
				ai_skillUse($chars[$config{'char'}]{'skills'}{$skills_rlut{lc($ai_v{'useSelf_skill'})}}{'ID'}, $ai_v{'useSelf_skill_lvl'}, $ai_v{'useSelf_skill_maxCastTime'}, $ai_v{'useSelf_skill_minCastTime'}, $accountID);
			} else {
				ai_skillUse($chars[$config{'char'}]{'skills'}{$skills_rlut{lc($ai_v{'useSelf_skill'})}}{'ID'}, $ai_v{'useSelf_skill_lvl'}, $ai_v{'useSelf_skill_maxCastTime'}, $ai_v{'useSelf_skill_minCastTime'}, $chars[$config{'char'}]{'pos_to'}{'x'}, $chars[$config{'char'}]{'pos_to'}{'y'});
			}
		}
	}


	##### PARTY-SKILL USE ##### 

	#FIXME: need to move closer before using skill, there might be light of sight problem too...
	
	if (%{$chars[$config{'char'}]{'party'}} && ($ai_seq[0] eq "" || $ai_seq[0] eq "route" || $ai_seq[0] eq "mapRoute"
	  || $ai_seq[0] eq "follow" || $ai_seq[0] eq "sitAuto" || $ai_seq[0] eq "take" || $ai_seq[0] eq "items_gather"
	  || $ai_seq[0] eq "items_take" || $ai_seq[0] eq "attack" || $ai_seq[0] eq "move") ){
		my $i = 0;
		undef $ai_v{'partySkill'};
		undef $ai_v{'partySkill_lvl'};
		undef $ai_v{'partySkill_targetID'};
		while (defined($config{"partySkill_$i"})) {
			for (my $j = 0; $j < @partyUsersID; $j++) {
				next if ($partyUsersID[$j] eq "" || $partyUsersID[$j] eq $accountID);
				if ($chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$j]}{'online'}
					&& distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$j]}{'pos'}}) <= 8
					&& distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$j]}{'pos'}}) > 0
					&& (!$config{"partySkill_$i"."_target"} || $config{"partySkill_$i"."_target"} eq $chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$j]}{'name'})
					&& percent_hp(\%{$chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$j]}}) <= $config{"partySkill_$i"."_targetHp_upper"} 
					&& percent_hp(\%{$chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$j]}}) >= $config{"partySkill_$i"."_targetHp_lower"}
					&& percent_sp(\%{$chars[$config{'char'}]}) <= $config{"partySkill_$i"."_sp_upper"} && percent_sp(\%{$chars[$config{'char'}]}) >= $config{"partySkill_$i"."_sp_lower"}
					&& $chars[$config{'char'}]{'sp'} >= $skillsSP_lut{$skills_rlut{lc($config{"partySkill_$i"})}}{$config{"partySkill_$i"."_lvl"}}
					&& !($config{"partySkill_$i"."_stopWhenHit"} && ai_getMonstersWhoHitMe())
					&& (!$config{"partySkill_$i"."_targetWhenStatusActive"} || whenStatusActivePL($partyUsersID[$j], $config{"partySkill_$i"."_targetWhenStatusActive"}))
					&& (!$config{"partySkill_$i"."_targetWhenStatusInactive"} || !whenStatusActivePL($partyUsersID[$j], $config{"partySkill_$i"."_targetWhenStatusInactive"}))
					&& (!$config{"partySkill_$i"."_targetWhenAffected"} || whenAffectedPL($partyUsersID[$j], $config{"partySkill_$i"."_targetWhenAffected"}))
					&& timeOut($ai_v{"partySkill_$i"."_time"},$config{"partySkill_$i"."_timeout"})
					){
						$ai_v{"partySkill_$i"."_time"} = time;
						$ai_v{'partySkill'} = $config{"partySkill_$i"};
						$ai_v{'partySkill_target'} = $chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$j]}{'name'};
						$ai_v{'partySkill_targetID'} = $partyUsersID[$j];
						$ai_v{'partySkill_lvl'} = $config{"partySkill_$i"."_lvl"};
						$ai_v{'partySkill_maxCastTime'} = $config{"partySkill_$i"."_maxCastTime"};
						$ai_v{'partySkill_minCastTime'} = $config{"partySkill_$i"."_minCastTime"};						
						last;
				}
			}
			
			$i++;
			last if (defined($ai_v{'partySkill_targetID'}));
		}

		if ($config{'useSelf_skill_smartHeal'} && $skills_rlut{lc($ai_v{'partySkill'})} eq "AL_HEAL") {
			undef $ai_v{'partySkill_smartHeal_lvl'};
			$ai_v{'partySkill_smartHeal_hp_dif'} = $chars[$config{'char'}]{'party'}{'users'}{$ai_v{'partySkill_targetID'}}{'hp_max'} - $chars[$config{'char'}]{'party'}{'users'}{$ai_v{'partySkill_targetID'}}{'hp'};
			for ($i = 1; $i <= $chars[$config{'char'}]{'skills'}{$skills_rlut{lc($ai_v{'partySkill'})}}{'lv'}; $i++) {
				$ai_v{'partySkill_smartHeal_lvl'} = $i;
				$ai_v{'partySkill_smartHeal_sp'} = 10 + ($i * 3);
				$ai_v{'partySkill_smartHeal_amount'} = int(($chars[$config{'char'}]{'lv'} + $chars[$config{'char'}]{'int'}) / 8) * (4 + $i * 8);
				if ($chars[$config{'char'}]{'sp'} < $ai_v{'partySkill_smartHeal_sp'}) {
					$ai_v{'partySkill_smartHeal_lvl'}--;
					last;
				}
				last if ($ai_v{'partySkill_smartHeal_amount'} >= $ai_v{'partySkill_smartHeal_hp_dif'});
			}
			$ai_v{'partySkill_lvl'} = $ai_v{'partySkill_smartHeal_lvl'};
		}
		if ($ai_v{'partySkill_lvl'} > 0) {
			debug qq~Party Skill used ($chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$j]}{'name'}) Skills Used: $skills_lut{$skills_rlut{lc($ai_v{'follow_skill'})}} (lvl $ai_v{'follow_skill_lvl'})\n~ if $config{'debug'};
			if (!ai_getSkillUseType($skills_rlut{lc($ai_v{'partySkill'})})) {
				ai_skillUse($chars[$config{'char'}]{'skills'}{$skills_rlut{lc($ai_v{'partySkill'})}}{'ID'}, $ai_v{'partySkill_lvl'}, $ai_v{'partySkill_maxCastTime'}, $ai_v{'partySkill_minCastTime'}, $ai_v{'partySkill_targetID'});
			} else {
				ai_skillUse($chars[$config{'char'}]{'skills'}{$skills_rlut{lc($ai_v{'partySkill'})}}{'ID'}, $ai_v{'partySkill_lvl'}, $ai_v{'partySkill_maxCastTime'}, $ai_v{'partySkill_minCastTime'}, $chars[$config{'char'}]{'party'}{'users'}{$ai_v{'partySkill_targetID'}}{'pos'}{'x'}, $chars[$config{'char'}]{'party'}{'users'}{$ai_v{'partySkill_targetID'}}{'pos'}{'y'});
			}
		}
	}


	##### FOLLOW #####
	
	# TODO: follow should be a 'mode' rather then a sequence, hence all var/flag about follow
	# should be moved to %ai_v

	FOLLOW: {
	last FOLLOW	if (!$config{follow});
	
	my $followIndex;
	if (($followIndex = binFind(\@ai_seq, "follow")) eq "") {
		# ai_follow will determine if the Target is 'follow-able'
		last FOLLOW if (!ai_follow($config{followTarget}));
	}
	
	# if we are not following now but master is in the screen...
	if (!defined $ai_seq_args[$followIndex]{'ID'}) {
		foreach (keys %players) {
			if ($players{$_}{'name'} eq $ai_seq_args[$followIndex]{'name'} && !$players{$_}{'dead'}) {
				$ai_seq_args[$followIndex]{'ID'} = $_;
				$ai_seq_args[$followIndex]{'following'} = 1;
				message "Found my master - $ai_seq_args[$followIndex]{'name'}\n", "follow";
				last;
			}
		}
	} elsif (!$ai_seq_args[$followIndex]{'following'} && %{$players{$ai_seq_args[$followIndex]{'ID'}}}) {
		$ai_seq_args[$followIndex]{'following'} = 1;
		delete $ai_seq_args[$followIndex]{'ai_follow_lost'};
		message "Found my master!\n", "follow"
	}

	# if we are not doing anything else now...
	if ($ai_seq[0] eq "follow") {
		if ($ai_seq_args[0]{'suspended'}) {
			if ($ai_seq_args[0]{'ai_follow_lost'}) {
				$ai_seq_args[0]{'ai_follow_lost_end'}{'time'} += time - $ai_seq_args[0]{'suspended'};
			}
			delete $ai_seq_args[0]{'suspended'};
		}
	
		# if we are not doing anything else now...
		if (!$ai_seq_args[$followIndex]{'ai_follow_lost'}) {
			if ($ai_seq_args[$followIndex]{'following'} && $players{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}) {
				$ai_v{'temp'}{'dist'} = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$players{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}});
				if ($ai_v{'temp'}{'dist'} > $config{'followDistanceMax'} && timeOut($ai_seq_args[$followIndex]{'move_timeout'}, 0.25)) {
					$ai_seq_args[$followIndex]{'move_timeout'} = time;
					if ($ai_v{'temp'}{'dist'} > 15) {
						ai_route($field{'name'}, $players{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}{'x'}, $players{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}{'y'},
							attackOnRoute => 1,
							distFromGoal => $config{'followDistanceMin'});
					} else {
						my $dist = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$players{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}});
						my (%vec, %pos);
	
						stand() if ($chars[$config{char}]{sitting});
						getVector(\%vec, \%{$players{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}}, \%{$chars[$config{'char'}]{'pos_to'}});
						moveAlongVector(\%pos, \%{$chars[$config{'char'}]{'pos_to'}}, \%vec, $dist - $config{'followDistanceMin'});
						sendMove(\$remote_socket, $pos{'x'}, $pos{'y'});
					}
				}
			}
			
			if ($ai_seq_args[$followIndex]{'following'} && %{$players{$ai_seq_args[$followIndex]{'ID'}}}) {
				if ($config{'followSitAuto'} && $players{$ai_seq_args[$followIndex]{'ID'}}{'sitting'} == 1 && $chars[$config{'char'}]{'sitting'} == 0) {
					sit();
				}
	
				my $dx = $ai_seq_args[$followIndex]{'last_pos_to'}{'x'} - $players{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}{'x'};
				my $dy = $ai_seq_args[$followIndex]{'last_pos_to'}{'y'} - $players{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}{'y'};
				$ai_seq_args[$followIndex]{'last_pos_to'}{'x'} = $players{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}{'x'};
				$ai_seq_args[$followIndex]{'last_pos_to'}{'y'} = $players{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}{'y'};
				if ($dx != 0 || $dy != 0) {
					lookAtPosition($players{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}, int(rand(3))) if ($config{'followFaceDirection'});
				}
			}
		}
	}

	if ($ai_seq[0] eq "follow" && $ai_seq_args[$followIndex]{'following'} && ($players{$ai_seq_args[$followIndex]{'ID'}}{'dead'} || (!%{$players{$ai_seq_args[$followIndex]{'ID'}}} && $players_old{$ai_seq_args[$followIndex]{'ID'}}{'dead'}))) {
		message "Master died.  I'll wait here.\n", "party";
		delete $ai_seq_args[$followIndex]{'following'};
	} elsif ($ai_seq_args[$followIndex]{'following'} && !%{$players{$ai_seq_args[$followIndex]{'ID'}}}) {
		message "I lost my master\n", "follow";
		if ($config{'followBot'}) {
			message "Trying to get him back\n", "follow";
			sendMessage(\$remote_socket, "pm", "move $chars[$config{'char'}]{'pos_to'}{'x'} $chars[$config{'char'}]{'pos_to'}{'y'}", $config{followTarget});
		}

		delete $ai_seq_args[$followIndex]{'following'};

		if ($players_old{$ai_seq_args[$followIndex]{'ID'}}{'disconnected'}) {
			message "My master disconnected\n", "follow";

		} elsif ($players_old{$ai_seq_args[$followIndex]{'ID'}}{'teleported'}) {
			message "My master teleported\n", "follow", 1;

		} elsif ($players_old{$ai_seq_args[$followIndex]{'ID'}}{'disappeared'}) {
			message "Trying to find lost master\n", "follow", 1;

			delete $ai_seq_args[followIndex]{'ai_follow_lost_char_last_pos'};
			delete $ai_seq_args[followIndex]{'follow_lost_portal_tried'};
			$ai_seq_args[$followIndex]{'ai_follow_lost'} = 1;
			$ai_seq_args[$followIndex]{'ai_follow_lost_end'}{'timeout'} = $timeout{'ai_follow_lost_end'}{'timeout'};
			$ai_seq_args[$followIndex]{'ai_follow_lost_end'}{'time'} = time;
			getVector(\%{$ai_seq_args[$followIndex]{'ai_follow_lost_vec'}}, \%{$players_old{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}}, \%{$chars[$config{'char'}]{'pos_to'}});

			#check if player went through portal
			my $first = 1;
			my $foundID;
			my $smallDist;
			foreach (@portalsID) {
				$ai_v{'temp'}{'dist'} = distance(\%{$players_old{$ai_seq_args[$followIndex]{'ID'}}{'pos_to'}}, \%{$portals{$_}{'pos'}});
				if ($ai_v{'temp'}{'dist'} <= 7 && ($first || $ai_v{'temp'}{'dist'} < $smallDist)) {
					$smallDist = $ai_v{'temp'}{'dist'};
					$foundID = $_;
					undef $first;
				}
			}
			$ai_seq_args[$followIndex]{'follow_lost_portalID'} = $foundID;
		} else {
			message "Don't know what happened to Master\n", "follow", 1;
		}
	}

	##### FOLLOW-LOST #####

	if ($ai_seq[0] eq "follow" && $ai_seq_args[$followIndex]{'ai_follow_lost'}) {
		if ($ai_seq_args[$followIndex]{'ai_follow_lost_char_last_pos'}{'x'} == $chars[$config{'char'}]{'pos_to'}{'x'} && $ai_seq_args[$followIndex]{'ai_follow_lost_char_last_pos'}{'y'} == $chars[$config{'char'}]{'pos_to'}{'y'}) {
			$ai_seq_args[$followIndex]{'lost_stuck'}++;
		} else {
			delete $ai_seq_args[$followIndex]{'lost_stuck'};
		}
		%{$ai_seq_args[0]{'ai_follow_lost_char_last_pos'}} = %{$chars[$config{'char'}]{'pos_to'}};

		if (timeOut(\%{$ai_seq_args[$followIndex]{'ai_follow_lost_end'}})) {
			delete $ai_seq_args[$followIndex]{'ai_follow_lost'};
			message "Couldn't find master, giving up\n", "follow";

		} elsif ($players_old{$ai_seq_args[$followIndex]{'ID'}}{'disconnected'}) {
			delete $ai_seq_args[0]{'ai_follow_lost'};
			message "My master disconnected\n", "follow";

		} elsif ($players_old{$ai_seq_args[$followIndex]{'ID'}}{'teleported'}) {
			delete $ai_seq_args[0]{'ai_follow_lost'};
			message "My master teleported\n", "follow";

		} elsif ($ai_seq_args[$followIndex]{'lost_stuck'}) {
			if ($ai_seq_args[$followIndex]{'follow_lost_portalID'} eq "") {
				moveAlongVector(\%{$ai_v{'temp'}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[$followIndex]{'ai_follow_lost_vec'}}, $config{'followLostStep'} / ($ai_seq_args[$followIndex]{'lost_stuck'} + 1));
				move($ai_v{'temp'}{'pos'}{'x'}, $ai_v{'temp'}{'pos'}{'y'});
			}
		} else {
			if ($ai_seq_args[$followIndex]{'follow_lost_portalID'} ne "") {
				if (%{$portals{$ai_seq_args[$followIndex]{'follow_lost_portalID'}}} && !$ai_seq_args[$followIndex]{'follow_lost_portal_tried'}) {
					$ai_seq_args[$followIndex]{'follow_lost_portal_tried'} = 1;
					%{$ai_v{'temp'}{'pos'}} = %{$portals{$ai_seq_args[$followIndex]{'follow_lost_portalID'}}{'pos'}};
					ai_route($field{'name'}, $ai_v{'temp'}{'pos'}{'x'}, $ai_v{'temp'}{'pos'}{'y'},
						attackOnRoute => 1);
				}
			} else {
				moveAlongVector(\%{$ai_v{'temp'}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[$followIndex]{'ai_follow_lost_vec'}}, $config{'followLostStep'});
				move($ai_v{'temp'}{'pos'}{'x'}, $ai_v{'temp'}{'pos'}{'y'});
			}
		}
	}

	# Use party information to find master
	if (!exists $ai_seq_args[$followIndex]{'following'} && !exists $ai_seq_args[$followIndex]{'ai_follow_lost'}) {
		ai_partyfollow();
	}
	} # end of FOLLOW block
	
	##### AUTO-SIT/SIT/STAND #####

	if ($config{'sitAuto_idle'} && ($ai_seq[0] ne "" && $ai_seq[0] ne "follow")) {
		$timeout{'ai_sit_idle'}{'time'} = time;
	}
	if (($ai_seq[0] eq "" || $ai_seq[0] eq "follow") && $config{'sitAuto_idle'} && !$chars[$config{'char'}]{'sitting'} && timeOut(\%{$timeout{'ai_sit_idle'}})) {
		sit();
	}
	if ($ai_seq[0] eq "sitting" && ($chars[$config{'char'}]{'sitting'} || $chars[$config{'char'}]{'skills'}{'NV_BASIC'}{'lv'} < 3)) {
		shift @ai_seq;
		shift @ai_seq_args;
		$timeout{'ai_sit'}{'time'} -= $timeout{'ai_sit'}{'timeout'};
	} elsif ($ai_seq[0] eq "sitting" && !$chars[$config{'char'}]{'sitting'} && timeOut(\%{$timeout{'ai_sit'}}) && timeOut(\%{$timeout{'ai_sit_wait'}})) {
		sendSit(\$remote_socket);
		$timeout{'ai_sit'}{'time'} = time;
	}
	if ($ai_seq[0] eq "standing" && !$chars[$config{'char'}]{'sitting'} && !$timeout{'ai_stand_wait'}{'time'}) {
		$timeout{'ai_stand_wait'}{'time'} = time;
	} elsif ($ai_seq[0] eq "standing" && !$chars[$config{'char'}]{'sitting'} && timeOut(\%{$timeout{'ai_stand_wait'}})) {
		shift @ai_seq;
		shift @ai_seq_args;
		undef $timeout{'ai_stand_wait'}{'time'};
		$timeout{'ai_sit'}{'time'} -= $timeout{'ai_sit'}{'timeout'};
	} elsif ($ai_seq[0] eq "standing" && $chars[$config{'char'}]{'sitting'} && timeOut(\%{$timeout{'ai_sit'}})) {
		sendStand(\$remote_socket);
		$timeout{'ai_sit'}{'time'} = time;
	}

	if ($ai_v{'sitAuto_forceStop'} && percent_hp(\%{$chars[$config{'char'}]}) >= $config{'sitAuto_hp_lower'} && percent_sp(\%{$chars[$config{'char'}]}) >= $config{'sitAuto_sp_lower'}) {
		$ai_v{'sitAuto_forceStop'} = 0;
	}

	if (!$ai_v{'sitAuto_forceStop'} && ($ai_seq[0] eq "" || $ai_seq[0] eq "follow" || $ai_seq[0] eq "route" || $ai_seq[0] eq "mapRoute") && binFind(\@ai_seq, "attack") eq "" && !ai_getAggressives()
		&& (percent_hp(\%{$chars[$config{'char'}]}) < $config{'sitAuto_hp_lower'} || percent_sp(\%{$chars[$config{'char'}]}) < $config{'sitAuto_sp_lower'})) {
		unshift @ai_seq, "sitAuto";
		unshift @ai_seq_args, {};
		debug "Auto-sitting\n", "ai";
	}
	if ($ai_seq[0] eq "sitAuto" && !$chars[$config{'char'}]{'sitting'} && $chars[$config{'char'}]{'skills'}{'NV_BASIC'}{'lv'} >= 3 && !ai_getAggressives() && $chars[$config{'char'}]{'weight_max'} && (int($chars[$config{'char'}]{'weight'}/$chars[$config{'char'}]{'weight_max'} * 100) < 50 || $config{'sitAuto_over_50'} eq '1')) {
		sit();
	}
	if ($ai_seq[0] eq "sitAuto" && ($ai_v{'sitAuto_forceStop'}
		|| (percent_hp(\%{$chars[$config{'char'}]}) >= $config{'sitAuto_hp_upper'} && percent_sp(\%{$chars[$config{'char'}]}) >= $config{'sitAuto_sp_upper'}))) {
		shift @ai_seq;
		shift @ai_seq_args;
		if (!$config{'sitAuto_idle'} && $chars[$config{'char'}]{'sitting'}) {
			stand();
		}
	}


	##### AUTO-ATTACK #####


	if (($ai_seq[0] eq "" || $ai_seq[0] eq "route" || $ai_seq[0] eq "mapRoute" || $ai_seq[0] eq "follow" 
		|| $ai_seq[0] eq "sitAuto" || $ai_seq[0] eq "take" || $ai_seq[0] eq "items_gather" || $ai_seq[0] eq "items_take")
		&& !($config{'itemsTakeAuto'} >= 2 && ($ai_seq[0] eq "take" || $ai_seq[0] eq "items_take"))
		&& !($config{'itemsGatherAuto'} >= 2 && ($ai_seq[0] eq "take" || $ai_seq[0] eq "items_gather"))
		&& timeOut(\%{$timeout{'ai_attack_auto'}})) {
		undef @{$ai_v{'ai_attack_agMonsters'}};
		undef @{$ai_v{'ai_attack_cleanMonsters'}};
		undef @{$ai_v{'ai_attack_partyMonsters'}};
		undef $ai_v{'temp'}{'priorityAttack'};
		undef $ai_v{'temp'}{'foundID'};

		# If we're in tanking mode, only attack something if the person we're tanking for is on screen.
		if ($config{'tankMode'}) {
			undef $ai_v{'temp'}{'found'};
			foreach (@playersID) {	
				next if ($_ eq "");
				if ($config{'tankModeTarget'} eq $players{$_}{'name'}) {
					$ai_v{'temp'}{'found'} = 1;
					last;
				}
			}
		}

		# Generate a list of all monsters that we are allowed to attack.
		if (!$config{'tankMode'} || ($config{'tankMode'} && $ai_v{'temp'}{'found'})) {
			$ai_v{'temp'}{'ai_follow_index'} = binFind(\@ai_seq, "follow");
			if ($ai_v{'temp'}{'ai_follow_index'} ne "") {
				$ai_v{'temp'}{'ai_follow_following'} = $ai_seq_args[$ai_v{'temp'}{'ai_follow_index'}]{'following'};
				$ai_v{'temp'}{'ai_follow_ID'} = $ai_seq_args[$ai_v{'temp'}{'ai_follow_index'}]{'ID'};
			} else {
				undef $ai_v{'temp'}{'ai_follow_following'};
			}
			$ai_v{'temp'}{'ai_route_index'} = binFind(\@ai_seq, "route");
			if ($ai_v{'temp'}{'ai_route_index'} ne "") {
				$ai_v{'temp'}{'ai_route_attackOnRoute'} = $ai_seq_args[$ai_v{'temp'}{'ai_route_index'}]{'attackOnRoute'};
			}

			# List aggressive monsters
			@{$ai_v{'ai_attack_agMonsters'}} = ai_getAggressives() if ($config{'attackAuto'} && !($ai_v{'temp'}{'ai_route_index'} ne "" && !$ai_v{'temp'}{'ai_route_attackOnRoute'}));

			# There are two types of non-aggressive monsters. We generate two lists:
			foreach (@monstersID) {
				next if ($_ eq "");
				# List monsters that the follow target or party members are attacking
				if (( ($config{'attackAuto_party'}
				      && $ai_seq[0] ne "take" && $ai_seq[0] ne "items_take"
				      && ($monsters{$_}{'dmgToParty'} > 0 || $monsters{$_}{'dmgFromParty'} > 0)
				      )
				   || ($config{'attackAuto_followTarget'} && $ai_v{'temp'}{'ai_follow_following'} 
				       && ($monsters{$_}{'dmgToPlayer'}{$ai_v{'temp'}{'ai_follow_ID'}} > 0 || $monsters{$_}{'missedToPlayer'}{$ai_v{'temp'}{'ai_follow_ID'}} > 0 || $monsters{$_}{'dmgFromPlayer'}{$ai_v{'temp'}{'ai_follow_ID'}} > 0))
				    )
				   && !($ai_v{'temp'}{'ai_route_index'} ne "" && !$ai_v{'temp'}{'ai_route_attackOnRoute'})
				   && $monsters{$_}{'attack_failed'} == 0 && ($mon_control{lc($monsters{$_}{'name'})}{'attack_auto'} >= 1 || $mon_control{lc($monsters{$_}{'name'})}{'attack_auto'} eq "")
				) {
					push @{$ai_v{'ai_attack_partyMonsters'}}, $_;

				# Begin the attack only when noone else is on screen, stollen from the skore forums a long time ago.
				} elsif ($config{'attackAuto_onlyWhenSafe'}
					&& $config{'attackAuto'} >= 1
					&& binSize(\@playersID) == 0
					&& $ai_seq[0] ne "sitAuto" && $ai_seq[0] ne "take" && $ai_seq[0] ne "items_gather" && $ai_seq[0] ne "items_take"
					&& !($monsters{$_}{'dmgFromYou'} == 0 && ($monsters{$_}{'dmgTo'} > 0 || $monsters{$_}{'dmgFrom'} > 0 || %{$monsters{$_}{'missedFromPlayer'}} || %{$monsters{$_}{'missedToPlayer'}} || %{$monsters{$_}{'castOnByPlayer'}})) && $monsters{$_}{'attack_failed'} == 0
					&& !($ai_v{'temp'}{'ai_route_index'} ne "" && $ai_v{'temp'}{'ai_route_attackOnRoute'} <= 1)
					&& ($mon_control{lc($monsters{$_}{'name'})}{'attack_auto'} >= 1 || $mon_control{lc($monsters{$_}{'name'})}{'attack_auto'} eq "")) {
						push @{$ai_v{'ai_attack_cleanMonsters'}}, $_;
					
				# List monsters that nobody's attacking
				} elsif ($config{'attackAuto'} >= 2
					&& !$config{'attackAuto_onlyWhenSafe'}
					&& $ai_seq[0] ne "sitAuto" && $ai_seq[0] ne "take" && $ai_seq[0] ne "items_gather" && $ai_seq[0] ne "items_take"
					&& !($monsters{$_}{'dmgFromYou'} == 0 && ($monsters{$_}{'dmgTo'} > 0 || $monsters{$_}{'dmgFrom'} > 0 || %{$monsters{$_}{'missedFromPlayer'}} || %{$monsters{$_}{'missedToPlayer'}} || %{$monsters{$_}{'castOnByPlayer'}})) && $monsters{$_}{'attack_failed'} == 0
					&& !($ai_v{'temp'}{'ai_route_index'} ne "" && $ai_v{'temp'}{'ai_route_attackOnRoute'} <= 1)
					&& ($mon_control{lc($monsters{$_}{'name'})}{'attack_auto'} >= 1 || $mon_control{lc($monsters{$_}{'name'})}{'attack_auto'} eq "")) {
					push @{$ai_v{'ai_attack_cleanMonsters'}}, $_;
				}
			}
			undef $ai_v{'temp'}{'distSmall'};
			undef $ai_v{'temp'}{'foundID'};
			undef $ai_v{'temp'}{'highestPri'};
			undef $ai_v{'temp'}{'priorityAttack'};

			# Look for all aggressive monsters that have the highest priority
			foreach (@{$ai_v{'ai_attack_agMonsters'}}) {
				# Don't attack monsters near portals
				next if (positionNearPortal(\%{$monsters{$_}{'pos_to'}}, 4));

				if (defined ($priority{lc($monsters{$_}{'name'})}) &&
				    $priority{lc($monsters{$_}{'name'})} > $ai_v{'temp'}{'highestPri'}) {
					$ai_v{'temp'}{'highestPri'} = $priority{lc($monsters{$_}{'name'})};
				}
			}

			$ai_v{'temp'}{'first'} = 1;
			if (!$ai_v{'temp'}{'highestPri'}) {
				# If not found, look for the closest aggressive monster (without priority)
				foreach (@{$ai_v{'ai_attack_agMonsters'}}) {
					# Don't attack monsters near portals
					next if (positionNearPortal(\%{$monsters{$_}{'pos_to'}}, 4));

					$ai_v{'temp'}{'dist'} = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$monsters{$_}{'pos_to'}});
					if (($ai_v{'temp'}{'first'} || $ai_v{'temp'}{'dist'} < $ai_v{'temp'}{'distSmall'}) && !%{$monsters{$_}{'state'}}) {
						$ai_v{'temp'}{'distSmall'} = $ai_v{'temp'}{'dist'};
						$ai_v{'temp'}{'foundID'} = $_;
						undef $ai_v{'temp'}{'first'};
					}
				}
			} else {
				# If found, look for the closest monster with the highest priority
				foreach (@{$ai_v{'ai_attack_agMonsters'}}) {
					next if ($priority{lc($monsters{$_}{'name'})} != $ai_v{'temp'}{'highestPri'});
					# Don't attack monsters near portals
					next if (positionNearPortal(\%{$monsters{$_}{'pos_to'}}, 4));

					$ai_v{'temp'}{'dist'} = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$monsters{$_}{'pos_to'}});
					if (($ai_v{'temp'}{'first'} || $ai_v{'temp'}{'dist'} < $ai_v{'temp'}{'distSmall'}) && !%{$monsters{$_}{'state'}}) {
						$ai_v{'temp'}{'distSmall'} = $ai_v{'temp'}{'dist'};
						$ai_v{'temp'}{'foundID'} = $_;
						$ai_v{'temp'}{'priorityAttack'} = 1;
						undef $ai_v{'temp'}{'first'};
					}
				}
			}

			if (!$ai_v{'temp'}{'foundID'}) {
				# There are no aggressive monsters; look for the closest monster that a party member is attacking
				undef $ai_v{'temp'}{'distSmall'};
				undef $ai_v{'temp'}{'foundID'};
				$ai_v{'temp'}{'first'} = 1;
				foreach (@{$ai_v{'ai_attack_partyMonsters'}}) {
					$ai_v{'temp'}{'dist'} = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$monsters{$_}{'pos_to'}});
					if (($ai_v{'temp'}{'first'} || $ai_v{'temp'}{'dist'} < $ai_v{'temp'}{'distSmall'}) && !$monsters{$_}{'ignore'} && !%{$monsters{$_}{'state'}}) {
						$ai_v{'temp'}{'distSmall'} = $ai_v{'temp'}{'dist'};
						$ai_v{'temp'}{'foundID'} = $_;
						undef $ai_v{'temp'}{'first'};
					}
				}
			}

			if (!$ai_v{'temp'}{'foundID'}) {
				# No party monsters either; look for the closest, non-aggressive monster that:
				# 1) nobody's attacking
				# 2) isn't within 2 blocks distance of someone else

				# Look for the monster with the highest priority
				undef $ai_v{'temp'}{'distSmall'};
				undef $ai_v{'temp'}{'foundID'};
				$ai_v{'temp'}{'first'} = 1;
				foreach (@{$ai_v{'ai_attack_cleanMonsters'}}) {
					$ai_v{'temp'}{'dist'} = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$monsters{$_}{'pos_to'}});
					if (($ai_v{'temp'}{'first'} || $ai_v{'temp'}{'dist'} < $ai_v{'temp'}{'distSmall'})
					 && !$monsters{$_}{'ignore'} && !%{$monsters{$_}{'state'}}
					 && !positionNearPlayer(\%{$monsters{$_}{'pos_to'}}, 3)
					 && !positionNearPortal(\%{$monsters{$_}{'pos_to'}}, 4)) {
						$ai_v{'temp'}{'distSmall'} = $ai_v{'temp'}{'dist'};
						$ai_v{'temp'}{'foundID'} = $_;
						undef $ai_v{'temp'}{'first'};
					}
				}
			}
		}

		# If an appropriate monster's found, attack it. If not, wait ai_attack_auto secs before searching again.
		if ($ai_v{'temp'}{'foundID'}) {
			ai_setSuspend(0);
			attack($ai_v{'temp'}{'foundID'}, $ai_v{'temp'}{'priorityAttack'});
		} else {
			$timeout{'ai_attack_auto'}{'time'} = time;
		}
	}




	##### ATTACK #####


	if ($ai_seq[0] eq "attack" && $ai_seq_args[0]{'suspended'}) {
		$ai_seq_args[0]{'ai_attack_giveup'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		undef $ai_seq_args[0]{'suspended'};
	}

	if ($ai_seq[0] eq "attack" && $ai_seq_args[0]{movedCount} <= 3) {
		# Make sure we don't immediately timeout when we've moved to the monster
		$ai_seq_args[0]{'ai_attack_giveup'}{'time'} = time;

	} elsif (($ai_seq[0] eq "route" || $ai_seq[0] eq "move") && $ai_seq_args[0]{attackID}) {
		# We're on route to the monster; check whether the monster has moved
		my $ID = $ai_seq_args[0]{attackID};
		my $attackSeq = ($ai_seq[0] eq "route") ? $ai_seq_args[1] : $ai_seq_args[2];

		if ($monsters{$ID} && %{$monsters{$ID}} && $ai_seq_args[1]{monsterPos} && %{$attackSeq->{monsterPos}}
		 && distance($monsters{$ID}{pos_to}, $attackSeq->{monsterPos}) > $attackSeq->{'attackMethod'}{'distance'}) {
			shift @ai_seq;
			shift @ai_seq_args;
			if ($ai_seq[0] eq "move") {
				shift @ai_seq;
				shift @ai_seq_args;
			}
			$ai_seq_args[0]{movedCount}--;
			$ai_seq_args[0]{'ai_attack_giveup'}{'time'} = time;
		}
	}

	if ($ai_seq[0] eq "attack" && timeOut($ai_seq_args[0]{'ai_attack_giveup'})) {
		$monsters{$ai_seq_args[0]{'ID'}}{'attack_failed'}++;
		shift @ai_seq;
		shift @ai_seq_args;
		message "Can't reach or damage target, dropping target\n", "ai_attack", 1;
		ai_clientSuspend(0, 5);

	} elsif ($ai_seq[0] eq "attack" && !%{$monsters{$ai_seq_args[0]{'ID'}}}) {
		# Monster died or disappeared
		$timeout{'ai_attack'}{'time'} -= $timeout{'ai_attack'}{'timeout'};
		$ai_v{'ai_attack_ID_old'} = $ai_seq_args[0]{'ID'};
		shift @ai_seq;
		shift @ai_seq_args;

		if ($monsters_old{$ai_v{'ai_attack_ID_old'}}{'dead'}) {
			message "Target died\n";

			monKilled();
			$monsters_Killed{$monsters_old{$ai_v{'ai_attack_ID_old'}}{'nameID'}}++;

			# Pickup loot when monster's dead
			if ($config{'itemsTakeAuto'} && $monsters_old{$ai_v{'ai_attack_ID_old'}}{'dmgFromYou'} > 0 && !$monsters_old{$ai_v{'ai_attack_ID_old'}}{'attackedByPlayer'} && !$monsters_old{$ai_v{'ai_attack_ID_old'}}{'ignore'}) {
				ai_items_take($monsters_old{$ai_v{'ai_attack_ID_old'}}{'pos'}{'x'}, $monsters_old{$ai_v{'ai_attack_ID_old'}}{'pos'}{'y'}, $monsters_old{$ai_v{'ai_attack_ID_old'}}{'pos_to'}{'x'}, $monsters_old{$ai_v{'ai_attack_ID_old'}}{'pos_to'}{'y'});
			} elsif (!ai_getAggressives()) {
				# Cheap way to suspend all movement to make it look real
				ai_clientSuspend(0, $timeout{'ai_attack_waitAfterKill'}{'timeout'});
			}

			## kokal start
			## mosters counting
			my $i = 0;
			my $found = 0;
			while ($monsters_Killed[$i]) {
				if ($monsters_Killed[$i]{'nameID'} eq $monsters_old{$ai_v{'ai_attack_ID_old'}}{'nameID'}) {
					$monsters_Killed[$i]{'count'}++;
					monsterLog($monsters_Killed[$i]{'name'});
					$found = 1;
					last;
				}
				$i++;
			}
			if (!$found) {
				$monsters_Killed[$i]{'nameID'} = $monsters_old{$ai_v{'ai_attack_ID_old'}}{'nameID'};
				$monsters_Killed[$i]{'name'} = $monsters_old{$ai_v{'ai_attack_ID_old'}}{'name'};
				$monsters_Killed[$i]{'count'} = 1;
				monsterLog($monsters_Killed[$i]{'name'})
			}
			## kokal end

		} else {
			message "Target lost\n", 1;
		}

	} elsif ($ai_seq[0] eq "attack") {
		# The attack sequence hasn't timed out and the monster is on screen

		# Update information about the monster and the current situation
		my $followIndex = binFind(\@ai_seq, "follow");
		my $following;
		my $followID;
		if (defined $followIndex) {
			$following = $ai_seq_args[$followIndex]{'following'};
			$followID = $ai_seq_args[$followIndex]{'ID'};
		}

		my $ID = $ai_seq_args[0]{'ID'};
		my $monsterDist = distance($chars[$config{'char'}]{'pos_to'}, $monsters{$ID}{'pos_to'});
		my $cleanMonster = (
			  !($monsters{$ID}{'dmgFromYou'} == 0 && ($monsters{$ID}{'dmgTo'} > 0 || $monsters{$ID}{'dmgFrom'} > 0 || %{$monsters{$ID}{'missedFromPlayer'}} || %{$monsters{$ID}{'missedToPlayer'}} || %{$monsters{$ID}{'castOnByPlayer'}}))
			|| ($config{'attackAuto_party'} && ($monsters{$ID}{'dmgFromParty'} > 0 || $monsters{$ID}{'dmgToParty'} > 0 || $monsters{$ID}{'missedToParty'} > 0))
			|| ($config{'attackAuto_followTarget'} && $following && ($monsters{$ID}{'dmgToPlayer'}{$followID} > 0 || $monsters{$ID}{'missedToPlayer'}{$followID} > 0 || $monsters{$ID}{'dmgFromPlayer'}{$followID} > 0))
			|| ($monsters{$ID}{'dmgToYou'} > 0 || $monsters{$ID}{'missedYou'} > 0)
		);
		$cleanMonster = 0 if ($monsters{$ID}{'attackedByPlayer'} && (!$following || $monsters{$ID}{'lastAttackFrom'} ne $followID));


		if ($ai_seq_args[0]{'dmgToYou_last'} != $monsters{$ID}{'dmgToYou'}
		 || $ai_seq_args[0]{'missedYou_last'} != $monsters{$ID}{'missedYou'}
		 || $ai_seq_args[0]{'dmgFromYou_last'} != $monsters{$ID}{'dmgFromYou'}) {
			$ai_seq_args[0]{'ai_attack_giveup'}{'time'} = time;
		}
		$ai_seq_args[0]{'dmgToYou_last'} = $monsters{$ID}{'dmgToYou'};
		$ai_seq_args[0]{'missedYou_last'} = $monsters{$ID}{'missedYou'};
		$ai_seq_args[0]{'dmgFromYou_last'} = $monsters{$ID}{'dmgFromYou'};
		$ai_seq_args[0]{'missedFromYou_last'} = $monsters{$ID}{'missedFromYou'};


		if (!%{$ai_seq_args[0]{'attackMethod'}}) {
			if ($config{'attackUseWeapon'}) {
				$ai_seq_args[0]{'attackMethod'}{'distance'} = $config{'attackDistance'};
				$ai_seq_args[0]{'attackMethod'}{'type'} = "weapon";
			} else {
				$ai_seq_args[0]{'attackMethod'}{'distance'} = 30;
				undef $ai_seq_args[0]{'attackMethod'}{'type'};
			}
			$i = 0;
			while ($config{"attackSkillSlot_$i"} ne "") {
				if (percent_hp(\%{$chars[$config{'char'}]}) >= $config{"attackSkillSlot_$i"."_hp_lower"} && percent_hp(\%{$chars[$config{'char'}]}) <= $config{"attackSkillSlot_$i"."_hp_upper"}
					&& percent_sp(\%{$chars[$config{'char'}]}) >= $config{"attackSkillSlot_$i"."_sp_lower"} && percent_sp(\%{$chars[$config{'char'}]}) <= $config{"attackSkillSlot_$i"."_sp_upper"}
					&& $chars[$config{'char'}]{'sp'} >= $skillsSP_lut{$skills_rlut{lc($config{"attackSkillSlot_$i"})}}{$config{"attackSkillSlot_$i"."_lvl"}}
					&& !($config{"attackSkillSlot_$i"."_stopWhenHit"} && ai_getMonstersWhoHitMe())
					&& (!$config{"attackSkillSlot_$i"."_maxUses"} || $ai_seq_args[0]{'attackSkillSlot_uses'}{$i} < $config{"attackSkillSlot_$i"."_maxUses"})
					&& $config{"attackSkillSlot_$i"."_minAggressives"} <= ai_getAggressives()
					&& (!$config{"attackSkillSlot_$i"."_maxAggressives"} || $config{"attackSkillSlot_$i"."_maxAggressives"} >= ai_getAggressives())
					&& (!$config{"attackSkillSlot_$i"."_monsters"} || existsInList($config{"attackSkillSlot_$i"."_monsters"}, $monsters{$ID}{'name'}))
					&& (!$config{"attackSkillSlot_$i"."_targetWhenStatusActive"} || whenStatusActiveMon($ID, $config{"attackSkillSlot_$i"."_targetWhenStatusActive"}))
					&& (!$config{"attackSkillSlot_$i"."_targetWhenStatusInactive"} || !whenStatusActiveMon($ID, $config{"attackSkillSlot_$i"."_targetWhenStatusInactive"}))
					&& (!$config{"attackSkillSlot_$i"."_targetWhenAffected"} || whenAffectedMon($ID, $config{"attackSkillSlot_$i"."_targetWhenAffected"}))
					&& (!$config{"attackSkillSlot_$i"."_targetWhenNotAffected"} || !whenAffectedMon($ID, $config{"attackSkillSlot_$i"."_targetWhenNotAffected"}))
				) {
					$ai_seq_args[0]{'attackSkillSlot_uses'}{$i}++;
					$ai_seq_args[0]{'attackMethod'}{'distance'} = $config{"attackSkillSlot_$i"."_dist"};
					$ai_seq_args[0]{'attackMethod'}{'type'} = "skill";
					$ai_seq_args[0]{'attackMethod'}{'skillSlot'} = $i;
					last;
				}
				$i++;
			}
		}

		if ($chars[$config{'char'}]{'sitting'}) {
			ai_setSuspend(0);
			stand();

		} elsif (!$cleanMonster) {
			# Drop target if it's already attacked by someone else
			message "Dropping target - you will not kill steal others\n", "ai_attack", 1;
			$monsters{$ID}{'ignore'} = 1;
			sendAttackStop(\$remote_socket);
			shift @ai_seq;
			shift @ai_seq_args;

		} elsif ($monsterDist > $ai_seq_args[0]{'attackMethod'}{'distance'}) {
			# Move to target
			$ai_seq_args[0]{movedCount}++;
			%{$ai_seq_args[0]{monsterPos}} = %{$monsters{$ID}{pos_to}};
			ai_route($field{'name'}, $monsters{$ID}{pos_to}{x}, $monsters{$ID}{pos_to}{y},
				pyDistFromGoal => $ai_seq_args[0]{'attackMethod'}{'distance'},
				maxRouteTime => $config{'attackMaxRouteTime'},
				attackID => $ID);

		} elsif ((($config{'tankMode'} && $monsters{$ID}{'dmgFromYou'} == 0)
		        || !$config{'tankMode'})) {
			# Attack the target. In case of tanking, only attack if it hasn't been hit once.

			if ($ai_seq_args[0]{'attackMethod'}{'type'} eq "weapon" && timeOut(\%{$timeout{'ai_attack'}})) {
				if ($config{'tankMode'}) {
					sendAttack(\$remote_socket, $ID, 0);
				} else {
					sendAttack(\$remote_socket, $ID, 7);
				}
				$timeout{'ai_attack'}{'time'} = time;
				undef %{$ai_seq_args[0]{'attackMethod'}};

			} elsif ($ai_seq_args[0]{'attackMethod'}{'type'} eq "skill") {
				$ai_v{'ai_attack_method_skillSlot'} = $ai_seq_args[0]{'attackMethod'}{'skillSlot'};
				undef %{$ai_seq_args[0]{'attackMethod'}};
				ai_setSuspend(0);

				if (!ai_getSkillUseType($skills_rlut{lc($config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"})})) {
					ai_skillUse(
						$chars[$config{'char'}]{'skills'}{$skills_rlut{lc($config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"})}}{'ID'},
						$config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_lvl"},
						$config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_maxCastTime"},
						$config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_minCastTime"},
						$ID);
				} else {
					ai_skillUse(
						$chars[$config{'char'}]{'skills'}{$skills_rlut{lc($config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"})}}{'ID'},
						$config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_lvl"},
						$config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_maxCastTime"},
						$config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_minCastTime"},
						$monsters{$ID}{'pos_to'}{'x'},
						$monsters{$ID}{'pos_to'}{'y'});
				}
				$ai_seq_args[0]{monsterID} = $ai_v{'ai_attack_ID'};

				debug qq~Auto-skill on monster: $skills_lut{$skills_rlut{lc($config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"})}} (lvl $config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_lvl"})\n~, "ai";
			}
			
		} elsif ($config{'tankMode'}) {
			if ($ai_seq_args[0]{'dmgTo_last'} != $monsters{$ID}{'dmgTo'}) {
				$ai_seq_args[0]{'ai_attack_giveup'}{'time'} = time;
			}
			$ai_seq_args[0]{'dmgTo_last'} = $monsters{$ID}{'dmgTo'};
		}
	}

	# Check for kill steal while moving
	if (binFind(\@ai_seq, "attack") ne ""
	  && (($ai_seq[0] eq "move" || $ai_seq[0] eq "route") && $ai_seq_args[0]{'attackID'})) {
		$ai_v{'temp'}{'ai_follow_index'} = binFind(\@ai_seq, "follow");
		if ($ai_v{'temp'}{'ai_follow_index'} ne "") {
			$ai_v{'temp'}{'ai_follow_following'} = $ai_seq_args[$ai_v{'temp'}{'ai_follow_index'}]{'following'};
			$ai_v{'temp'}{'ai_follow_ID'} = $ai_seq_args[$ai_v{'temp'}{'ai_follow_index'}]{'ID'};
		} else {
			undef $ai_v{'temp'}{'ai_follow_following'};
		}

		my $ID = $ai_seq_args[0]{'attackID'};
		$ai_v{'ai_attack_cleanMonster'} = (
				  !($monsters{$ID}{'dmgFromYou'} == 0 && ($monsters{$ID}{'dmgTo'} > 0 || $monsters{$ID}{'dmgFrom'} > 0 || %{$monsters{$ID}{'missedFromPlayer'}} || %{$monsters{$ID}{'missedToPlayer'}} || %{$monsters{$ID}{'castOnByPlayer'}}))
				|| ($config{'attackAuto_party'} && ($monsters{$ID}{'dmgFromParty'} > 0 || $monsters{$ID}{'dmgToParty'} > 0))
				|| ($config{'attackAuto_followTarget'} && $ai_v{'temp'}{'ai_follow_following'} && ($monsters{$ID}{'dmgToPlayer'}{$ai_v{'temp'}{'ai_follow_ID'}} > 0 || $monsters{$ID}{'missedToPlayer'}{$ai_v{'temp'}{'ai_follow_ID'}} > 0 || $monsters{$ID}{'dmgFromPlayer'}{$ai_v{'temp'}{'ai_follow_ID'}} > 0))
				|| ($monsters{$ID}{'dmgToYou'} > 0 || $monsters{$ID}{'missedYou'} > 0)
			);
		$ai_v{'ai_attack_cleanMonster'} = 0 if ($monsters{$ID}{'attackedByPlayer'});

		if (!$ai_v{'ai_attack_cleanMonster'}) {
			message "Dropping target - you will not kill steal others\n",,1;
			sendAttackStop(\$remote_socket);
			$monsters{$ai_seq_args[0]{'ID'}}{'ignore'} = 1;

			# Remove "move"
			shift @ai_seq;
			shift @ai_seq_args;
			# Remove "route"
			if ($ai_seq[0] eq "route") {
				$ai_seq_args[0]{'destroyFunction'}->($ai_seq_args[$index]) if ($ai_seq_args[0]{'destroyFunction'});
				shift @ai_seq;
				shift @ai_seq_args;
			}
			# Remove "attack"
			shift @ai_seq;
			shift @ai_seq_args;
		}
	}



	##### SKILL USE #####


	if ($ai_seq[0] eq "skill_use" && $ai_seq_args[0]{'suspended'}) {
		$ai_seq_args[0]{'ai_skill_use_giveup'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		$ai_seq_args[0]{'ai_skill_use_minCastTime'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		$ai_seq_args[0]{'ai_skill_use_maxCastTime'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		undef $ai_seq_args[0]{'suspended'};
	}
	if ($ai_seq[0] eq "skill_use") {
		if (defined $ai_seq_args[0]{monsterID} && !%{$monsters{$ai_seq_args[0]{monsterID}}}) {
			# This skill is supposed to be used for attacking a monster, but that monster has died
			shift @ai_seq;
			shift @ai_seq_args;

		} elsif ($chars[$config{'char'}]{'sitting'}) {
			ai_setSuspend(0);
			stand();
		} elsif (!$ai_seq_args[0]{'skill_used'}) {
			$ai_seq_args[0]{'skill_used'} = 1;
			$ai_seq_args[0]{'ai_skill_use_giveup'}{'time'} = time;
			if ($ai_seq_args[0]{'skill_use_target_x'} ne "") {
				sendSkillUseLoc(\$remote_socket, $ai_seq_args[0]{'skill_use_id'}, $ai_seq_args[0]{'skill_use_lv'}, $ai_seq_args[0]{'skill_use_target_x'}, $ai_seq_args[0]{'skill_use_target_y'});
			} else {
				sendSkillUse(\$remote_socket, $ai_seq_args[0]{'skill_use_id'}, $ai_seq_args[0]{'skill_use_lv'}, $ai_seq_args[0]{'skill_use_target'});
			}
			$ai_seq_args[0]{'skill_use_last'} = $chars[$config{'char'}]{'skills'}{$skills_rlut{lc($skillsID_lut{$ai_seq_args[0]{'skill_use_id'}})}}{'time_used'};

		} elsif (($ai_seq_args[0]{'skill_use_last'} != $chars[$config{'char'}]{'skills'}{$skills_rlut{lc($skillsID_lut{$ai_seq_args[0]{'skill_use_id'}})}}{'time_used'}
			|| (timeOut(\%{$ai_seq_args[0]{'ai_skill_use_giveup'}}) && (!$chars[$config{'char'}]{'time_cast'} || !$ai_seq_args[0]{'skill_use_maxCastTime'}{'timeout'}))
			|| ($ai_seq_args[0]{'skill_use_maxCastTime'}{'timeout'} && timeOut(\%{$ai_seq_args[0]{'skill_use_maxCastTime'}})))
			&& timeOut(\%{$ai_seq_args[0]{'skill_use_minCastTime'}})) {
			shift @ai_seq;
			shift @ai_seq_args;
		}
	}



	####### ROUTE #######

	if ( $ai_seq[0] eq "route" && $field{'name'} && $chars[$config{'char'}]{'pos_to'}{'x'} ne '' && $chars[$config{'char'}]{'pos_to'}{'y'} ne '' ) {

		if ( $ai_seq_args[0]{'maxRouteTime'} && time - $ai_seq_args[0]{'time_start'} > $ai_seq_args[0]{'maxRouteTime'} ) {
			# we spent too much time
			debug "We spent too much time; bailing out.\n", "route";
			shift @ai_seq;
			shift @ai_seq_args;

		} elsif ( ($field{'name'} ne $ai_seq_args[0]{'dest'}{'map'} || $ai_seq_args[0]{'mapChanged'}) ) {
			debug "Map changed: <$field{'name'}> <$ai_seq_args[0]{'dest'}{'map'}>\n", "route";
			shift @ai_seq;
			shift @ai_seq_args;

		} elsif ($ai_seq_args[0]{'stage'} eq '') {
			undef @{$ai_seq_args[0]{'solution'}};
			if (ai_route_getRoute( \@{$ai_seq_args[0]{'solution'}}, \%field, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[0]{'dest'}{'pos'}}) ) {
				$ai_seq_args[0]{'stage'} = 'Route Solution Ready';
				debug "Route Solution Ready\n", "route";
			} else {
				debug "Something's wrong; there is no path to $field{'name'}($ai_seq_args[0]{'dest'}{'pos'}{'x'},$ai_seq_args[0]{'dest'}{'pos'}{'y'}).\n", "debug";
				shift @ai_seq;
				shift @ai_seq_args;
			}

		} elsif ( $ai_seq_args[0]{'stage'} eq 'Route Solution Ready' ) {
			if ($ai_seq_args[0]{'maxRouteDistance'} > 0 && $ai_seq_args[0]{'maxRouteDistance'} < 1) {
				#fractional route motion
				$ai_seq_args[0]{'maxRouteDistance'} = int($ai_seq_args[0]{'maxRouteDistance'} * scalar @{$ai_seq_args[0]{'solution'}});
			}
			splice(@{$ai_seq_args[0]{'solution'}},1+$ai_seq_args[0]{'maxRouteDistance'}) if $ai_seq_args[0]{'maxRouteDistance'} && $ai_seq_args[0]{'maxRouteDistance'} < @{$ai_seq_args[0]{'solution'}};
			undef $ai_seq_args[0]{'mapChanged'};
			undef $ai_seq_args[0]{'index'};
			undef $ai_seq_args[0]{'old_x'};
			undef $ai_seq_args[0]{'old_y'};
			$ai_seq_args[0]{'new_x'} = $chars[$config{'char'}]{'pos_to'}{'x'};
			$ai_seq_args[0]{'new_y'} = $chars[$config{'char'}]{'pos_to'}{'y'};
			$ai_seq_args[0]{'stage'} = 'Walk the Route Solution';

		} elsif ( $ai_seq_args[0]{'stage'} eq 'Walk the Route Solution' ) {

			my $cur_x = $chars[$config{'char'}]{'pos_to'}{'x'};
			my $cur_y = $chars[$config{'char'}]{'pos_to'}{'y'};

			unless (@{$ai_seq_args[0]{'solution'}}) {
				#no more points to cover
				shift @ai_seq;
				shift @ai_seq_args;
			} elsif ($ai_seq_args[0]{'index'} eq '0' 		#if index eq '0' (but not index == 0)
			      && $ai_seq_args[0]{'old_x'} == $cur_x		#and we are still on the same
			      && $ai_seq_args[0]{'old_y'} == $cur_y ) {	#old XY coordinate,
				
				debug "Stuck: $field{'name'} ($cur_x,$cur_y)->($ai_seq_args[0]{'new_x'},$ai_seq_args[0]{'new_y'})\n", "route";
				#ShowValue('solution', \@{$ai_seq_args[0]{'solution'}});
				shift @ai_seq;
				shift @ai_seq_args;

			} elsif ($ai_seq_args[0]{'distFromGoal'} >= @{$ai_seq_args[0]{'solution'}}
			      || $ai_seq_args[0]{'pyDistFromGoal'} > distance($ai_seq_args[0]{'dest'}{'pos'}, $chars[$config{'char'}]{'pos_to'}) ) {
				# We are near the goal, thats good enough.
				# Distance is computed based on step counts (distFromGoal) or pythagorean distance (pyDistFromGoal).
				debug "We are near our goal\n", "route";
				shift @ai_seq;
				shift @ai_seq_args;
			} elsif ($ai_seq_args[0]{'old_x'} == $cur_x && $ai_seq_args[0]{'old_y'} == $cur_y) {
				#we are still on the same spot
				#decrease step movement
				$ai_seq_args[0]{'index'} = int($ai_seq_args[0]{'index'}*0.85);
				if (@{$ai_seq_args[0]{'solution'}}) {
					#if we still have more points to cover, walk to next point
					$ai_seq_args[0]{'index'} = @{$ai_seq_args[0]{'solution'}}-1 if $ai_seq_args[0]{'index'} >= @{$ai_seq_args[0]{'solution'}};
					$ai_seq_args[0]{'new_x'} = $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'x'};
					$ai_seq_args[0]{'new_y'} = $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'y'};
					$ai_seq_args[0]{'old_x'} = $cur_x;
					$ai_seq_args[0]{'old_y'} = $cur_y;
					move($ai_seq_args[0]{'new_x'}, $ai_seq_args[0]{'new_y'}, $ai_seq_args[0]{'attackID'});
				}
			} elsif ($ai_seq_args[0]{'new_x'} == $cur_x && $ai_seq_args[0]{'new_y'} == $cur_y) {
				#we arrived there
				#trim down the solution tree
				splice(@{$ai_seq_args[0]{'solution'}}, 0, $ai_seq_args[0]{'index'}+1) if $ai_seq_args[0]{'index'} ne '' && @{$ai_seq_args[0]{'solution'}} > $ai_seq_args[0]{'index'};
				$ai_seq_args[0]{'index'} = $config{'route_step'} unless $ai_seq_args[0]{'index'};
				$ai_seq_args[0]{'index'}++ if $ai_seq_args[0]{'index'} < $config{'route_step'};
				if (@{$ai_seq_args[0]{'solution'}}) {
					#if we still have more points to cover, walk to next point
					$ai_seq_args[0]{'index'} = @{$ai_seq_args[0]{'solution'}}-1 if $ai_seq_args[0]{'index'} >= @{$ai_seq_args[0]{'solution'}};
					$ai_seq_args[0]{'new_x'} = $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'x'};
					$ai_seq_args[0]{'new_y'} = $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'y'};
					$ai_seq_args[0]{'old_x'} = $cur_x;
					$ai_seq_args[0]{'old_y'} = $cur_y;
					move($ai_seq_args[0]{'new_x'}, $ai_seq_args[0]{'new_y'}, $ai_seq_args[0]{'attackID'});
				} else {
					#no more points to cover
					shift @ai_seq;
					shift @ai_seq_args;
				}
			} else {
				#since we are not on the same old-position, then we have moved
				#let us check if we moved to the new position or somewhere in between
				$ai_seq_args[0]{'index'} = 0;
				while ( $ai_seq_args[0]{'index'} < @{$ai_seq_args[0]{'solution'}} && 
					($cur_x != $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'x'} || 
					 $cur_y != $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'y'}) ) {
					$ai_seq_args[0]{'index'}++;
				}
				if ($ai_seq_args[0]{'index'} < @{$ai_seq_args[0]{'solution'}}) {
					splice @{$ai_seq_args[0]{'solution'}}, 0, $ai_seq_args[0]{'index'}+1;
					if (@{$ai_seq_args[0]{'solution'}}) {
						$ai_seq_args[0]{'index'} = $config{'route_step'} if $ai_seq_args[0]{'index'} eq '' || $ai_seq_args[0]{'index'} > $config{'route_step'};
						$ai_seq_args[0]{'index'} = @{$ai_seq_args[0]{'solution'}}-1 if $ai_seq_args[0]{'index'} >= @{$ai_seq_args[0]{'solution'}};
						$ai_seq_args[0]{'new_x'} = $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'x'};
						$ai_seq_args[0]{'new_y'} = $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'y'};
						$ai_seq_args[0]{'old_x'} = $cur_x;
						$ai_seq_args[0]{'old_y'} = $cur_y;
						move($ai_seq_args[0]{'new_x'}, $ai_seq_args[0]{'new_y'}, $ai_seq_args[0]{'attackID'});
					}
				} else {
					debug "Something disturbed our walk.\n", "route";
					$ai_seq_args[0]{'stage'} = '';
				}
			}
		} else {
			debug "Unexpected route stage [$ai_seq_args[0]{'stage'}] occured.\n", "route";
			shift @ai_seq;
			shift @ai_seq_args;
		}
	}


	####### MAPROUTE #######

	if ( $ai_seq[0] eq "mapRoute" && $field{'name'} && $chars[$config{'char'}]{'pos_to'}{'x'} ne '' && $chars[$config{'char'}]{'pos_to'}{'y'} ne '' ) {

		if ($ai_seq_args[0]{'stage'} eq '') {
			$ai_seq_args[0]{'budget'} = $config{'route_maxWarpFee'} eq '' ?
				'' :
				$config{'route_maxWarpFee'} > $chars[$config{'char'}]{'zenny'} ?
					$chars[$config{'char'}]{'zenny'} :
					$config{'route_maxWarpFee'};
			delete $ai_seq_args[0]{'done'};
			delete $ai_seq_args[0]{'found'};
			delete $ai_seq_args[0]{'mapChanged'};
			delete $ai_seq_args[0]{'openlist'};
			delete $ai_seq_args[0]{'closelist'};
			undef @{$ai_seq_args[0]{'mapSolution'}};
			getField("$Settings::def_field/$ai_seq_args[0]{'dest'}{'map'}.fld", \%{$ai_seq_args[0]{'dest'}{'field'}});

			# Initializes the openlist with portals walkable from the starting point
			foreach my $portal (keys %portals_lut) {
				next if $portals_lut{$portal}{'source'}{'map'} ne $field{'name'};
				if ( ai_route_getRoute(\@{$ai_seq_args[0]{'solution'}}, \%field, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$portals_lut{$portal}{'source'}{'pos'}}) ) {
					foreach my $dest (keys %{$portals_lut{$portal}{'dest'}}) {
						$ai_seq_args[0]{'openlist'}{"$portal=$dest"}{'walk'} = PORTAL_PENALTY + scalar @{$ai_seq_args[0]{'solution'}};
						$ai_seq_args[0]{'openlist'}{"$portal=$dest"}{'zenny'} = $portals_lut{$portal}{'dest'}{$dest}{'cost'};
					}
				}
			}
			$ai_seq_args[0]{'stage'} = 'Getting Map Solution';

		} elsif ( $ai_seq_args[0]{'stage'} eq 'Getting Map Solution' ) {
			$timeout{'ai_route_calcRoute'}{'time'} = time;
			while (!$ai_seq_args[0]{'done'} && !timeOut(\%{$timeout{'ai_route_calcRoute'}})) {
				ai_mapRoute_searchStep(\%{$ai_seq_args[0]});
			}
			if ($ai_seq_args[0]{'found'}) {
				$ai_seq_args[0]{'stage'} = 'Traverse the Map Solution';
				delete $ai_seq_args[0]{'openlist'};
				delete $ai_seq_args[0]{'solution'};
				delete $ai_seq_args[0]{'closelist'};
				delete $ai_seq_args[0]{'dest'}{'field'};
				debug "Map Solution Ready for traversal.\n", "route";
			} elsif ($ai_seq_args[0]{'done'}) {
				warning "No map solution was found from [$field{'name'}($chars[$config{'char'}]{'pos_to'}{'x'},$chars[$config{'char'}]{'pos_to'}{'y'})] to [$ai_seq_args[0]{'dest'}{'map'}($ai_seq_args[0]{'dest'}{'pos'}{'x'},$ai_seq_args[0]{'dest'}{'pos'}{'y'})].\n", "route";
				shift @ai_seq;
				shift @ai_seq_args;
			}
		} elsif ( $ai_seq_args[0]{'stage'} eq 'Traverse the Map Solution' ) {

			my %args;
			undef @{$args{'solution'}};
			unless (@{$ai_seq_args[0]{'mapSolution'}}) {
				#mapSolution is now empty
				shift @ai_seq;
				shift @ai_seq_args;
				debug "Map Router is finish traversing the map solution\n", "route";

			} elsif ( $field{'name'} ne $ai_seq_args[0]{'mapSolution'}[0]{'map'} || $ai_seq_args[0]{'mapChanged'} ) {
				#Solution Map does not match current map
				debug "Current map $field{'name'} does not match solution [ $ai_seq_args[0]{'mapSolution'}[0]{'portal'} ].\n", "route";
				delete $ai_seq_args[0]{'substage'};
				delete $ai_seq_args[0]{'timeout'};
				delete $ai_seq_args[0]{'mapChanged'};
				shift @{$ai_seq_args[0]{'mapSolution'}};

			} elsif ( $ai_seq_args[0]{'mapSolution'}[0]{'steps'} ) {
				#If current solution has conversation steps specified
				if ( $ai_seq_args[0]{'substage'} eq 'Waiting for Warp' ) {
					$ai_seq_args[0]{'timeout'} = time unless $ai_seq_args[0]{'timeout'};
					if (time - $ai_seq_args[0]{'timeout'} > 10) {
						#We waited for 10 seconds and got nothing
						#NPC sequence is a failure
						#We delete that portal and try again
						delete $portals_lut{"$ai_seq_args[0]{'mapSolution'}[0]{'map'} $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'} $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'}"};
						delete $ai_seq_args[0]{'substage'};
						delete $ai_seq_args[0]{'timeout'};
						debug "CRITICAL ERROR: NPC Sequence was a failure at $field{'name'} ($ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'},$ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'}).\n", "debug";
						$ai_seq_args[0]{'stage'} = '';	#redo MAP router
					}

				} elsif ( 4 > distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[0]{'mapSolution'}[0]{'pos'}}) ) {
					my ($from,$to) = split /=/, $ai_seq_args[0]{'mapSolution'}[0]{'portal'};
					if ($chars[$config{'char'}]{'zenny'} >= $portals_lut{$from}{'dest'}{$to}{'cost'}) {
						#we have enough money for this service
						$ai_seq_args[0]{'substage'} = 'Waiting for Warp';
						$ai_seq_args[0]{'old_x'} = $chars[$config{'char'}]{'pos_to'}{'x'};
						$ai_seq_args[0]{'old_y'} = $chars[$config{'char'}]{'pos_to'}{'y'};
						$ai_seq_args[0]{'old_map'} = $field{'name'};
						ai_talkNPC($ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'}, $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'}, $ai_seq_args[0]{'mapSolution'}[0]{'steps'} );
					} else {
						error "Insufficient zenny to pay for service at $field{'name'} ($ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'},$ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'}).\n", "route";
						$ai_seq_args[0]{'stage'} = ''; #redo MAP router
					}

				} elsif ( $ai_seq_args[0]{'maxRouteTime'} && time - $ai_seq_args[0]{'time_start'} > $ai_seq_args[0]{'maxRouteTime'} ) {
					# we spent too long a time
					debug "We spent too much time; bailing out.\n", "route";
					shift @ai_seq;
					shift @ai_seq_args;

				} elsif ( ai_route_getRoute( \@{$args{'solution'}}, \%field, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[0]{'mapSolution'}[0]{'pos'}} ) ) {
					# NPC is reachable from current position
					# >> Then "route" to it
					debug "Walking towards the NPC\n", "route";
					if (0) {
						$args{'dest'}{'map'} = $ai_seq_args[0]{'mapSolution'}[0]{'map'};
						$args{'dest'}{'pos'}{'x'} = $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'};
						$args{'dest'}{'pos'}{'y'} = $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'};
						$args{'attackOnRoute'} = $ai_seq_args[0]{'attackOnRoute'};
						$args{'maxRouteTime'} = $ai_seq_args[0]{'maxRouteTime'};
						$args{'time_start'} = time;
						$args{'distFromGoal'} = 3;
						$args{'stage'} = 'Route Solution Ready';
						unshift @ai_seq, "route";
						unshift @ai_seq_args, \%args;
					} else {
						ai_route($ai_seq_args[0]{'mapSolution'}[0]{'map'}, $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'}, $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'},
							attackOnRoute => $ai_seq_args[0]{'attackOnRoute'},
							maxRouteTime => $ai_seq_args[0]{'maxRouteTime'},
							distFromGoal => 3,
							_solution => $args{'solution'},
							_internal => 1);
					}

				} else {
					#Error, NPC is not reachable from current pos
					debug "CRTICAL ERROR: NPC is not reachable from current location.\n", "route";
					error "Unable to walk from $field{'name'} ($chars[$config{'char'}]{'pos_to'}{'x'},$chars[$config{'char'}]{'pos_to'}{'y'}) to NPC at ($ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'},$ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'}).\n", "route";
					shift @{$ai_seq_args[0]{'mapSolution'}};
				}

			} elsif ( $ai_seq_args[0]{'mapSolution'}[0]{'portal'} eq "$ai_seq_args[0]{'mapSolution'}[0]{'map'} $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'} $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'}=$ai_seq_args[0]{'mapSolution'}[0]{'map'} $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'} $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'}" ) {
				#This solution points to an X,Y coordinate
				if ( 4 > distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[0]{'mapSolution'}[0]{'pos'}})) {
					#We need to specify 4 because sometimes the exact spot is occupied by someone else
					shift @{$ai_seq_args[0]{'mapSolution'}};

				} elsif ( $ai_seq_args[0]{'maxRouteTime'} && time - $ai_seq_args[0]{'time_start'} > $ai_seq_args[0]{'maxRouteTime'} ) {
					#we spent too long a time
					debug "We spent too much time; bailing out.\n", "route";
					shift @ai_seq;
					shift @ai_seq_args;

				} elsif ( ai_route_getRoute( \@{$args{'solution'}}, \%field, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[0]{'mapSolution'}[0]{'pos'}} ) ) {
					# X,Y is reachable from current position
					# >> Then "route" to it
					if (0) {
						$args{'dest'}{'map'} = $ai_seq_args[0]{'mapSolution'}[0]{'map'};
						$args{'dest'}{'pos'}{'x'} = $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'};
						$args{'dest'}{'pos'}{'y'} = $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'};
						$args{'attackOnRoute'} = $ai_seq_args[0]{'attackOnRoute'};
						$args{'maxRouteTime'} = $ai_seq_args[0]{'maxRouteTime'};
						$args{'time_start'} = time;
						$args{'stage'} = 'Route Solution Ready';
						$args{'distFromGoal'} = 4;
						unshift @ai_seq, "route";
						unshift @ai_seq_args, \%args;
					} else {
						ai_route($ai_seq_args[0]{'mapSolution'}[0]{'map'}, $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'}, $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'},
							attackOnRoute => $ai_seq_args[0]{'attackOnRoute'},
							maxRouteTime => $ai_seq_args[0]{'maxRouteTime'},
							distFromGoal => 4,
							_solution => $args{'solution'},
							_internal => 1);
					}

				} else {
					warning "No LOS from $field{'name'} ($chars[$config{'char'}]{'pos_to'}{'x'},$chars[$config{'char'}]{'pos_to'}{'y'}) to Final Destination at ($ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'},$ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'}).\n", "route";
					error "Cannot reach ($ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'},$ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'}) from current position.\n", "route";
					shift @{$ai_seq_args[0]{'mapSolution'}};
				}

			} elsif ( $portals_lut{"$ai_seq_args[0]{'mapSolution'}[0]{'map'} $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'} $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'}"}{'source'}{'ID'} ) {
				# This is a portal solution

				if ( 2 > distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[0]{'mapSolution'}[0]{'pos'}}) ) {
					# Portal is within 'Enter Distance'
					$timeout{'ai_portal_wait'}{'timeout'} = $timeout{'ai_portal_wait'}{'timeout'} || 0.5;
					if ( timeOut(\%{$timeout{'ai_portal_wait'}}) ) {
						sendMove( \$remote_socket, int($ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'}), int($ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'}) );
						$timeout{'ai_portal_wait'}{'time'} = time;
					}

				} elsif ( ai_route_getRoute( \@{$args{'solution'}}, \%field, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[0]{'mapSolution'}[0]{'pos'}} ) ) {
					debug "portal within same map\n", "route";
					# Portal is reachable from current position
					# >> Then "route" to it
					if (0) {
						$args{'dest'}{'map'} = $ai_seq_args[0]{'mapSolution'}[0]{'map'};
						$args{'dest'}{'pos'}{'x'} = $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'};
						$args{'dest'}{'pos'}{'y'} = $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'};
						$args{'attackOnRoute'} = $ai_seq_args[0]{'attackOnRoute'};
						$args{'maxRouteTime'} = $ai_seq_args[0]{'maxRouteTime'};
						$args{'time_start'} = time;
						$args{'stage'} = 'Route Solution Ready';
						unshift @ai_seq, "route";
						unshift @ai_seq_args, \%args;
					} else {
						ai_route($ai_seq_args[0]{'mapSolution'}[0]{'map'}, $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'}, $ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'},
							attackOnRoute => $ai_seq_args[0]{'attackOnRoute'},
							maxRouteTime => $ai_seq_args[0]{'maxRouteTime'},
							_solution => $args{'solution'},
							_internal => 1);
					}

				} else {
					warning "No LOS from $field{'name'} ($chars[$config{'char'}]{'pos_to'}{'x'},$chars[$config{'char'}]{'pos_to'}{'y'}) to Portal at ($ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'x'},$ai_seq_args[0]{'mapSolution'}[0]{'pos'}{'y'}).\n", "route";
					error "Cammpt reach portal from current position\n", "route";
					shift @{$ai_seq_args[0]{'mapSolution'}};
				}
			}
		}
	}


	##### ITEMS TAKE #####
	# Look for loot to pickup when your monster died.

	if ($ai_seq[0] eq "items_take" && $ai_seq_args[0]{'suspended'}) {
		$ai_seq_args[0]{'ai_items_take_start'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		$ai_seq_args[0]{'ai_items_take_end'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		undef $ai_seq_args[0]{'suspended'};
	}
	if ($ai_seq[0] eq "items_take" && (percent_weight(\%{$chars[$config{'char'}]}) >= $config{'itemsMaxWeight'})) {
		shift @ai_seq;
		shift @ai_seq_args;
		ai_clientSuspend(0, $timeout{'ai_attack_waitAfterKill'}{'timeout'});
	}
	if ($config{'itemsTakeAuto'} && $ai_seq[0] eq "items_take" && timeOut(\%{$ai_seq_args[0]{'ai_items_take_start'}})) {
		undef $ai_v{'temp'}{'foundID'};
		foreach (@itemsID) {
			next if ($_ eq "" || $itemsPickup{lc($items{$_}{'name'})} eq "0" || (!$itemsPickup{'all'} && !$itemsPickup{lc($items{$_}{'name'})}));
			$ai_v{'temp'}{'dist'} = distance(\%{$items{$_}{'pos'}}, \%{$ai_seq_args[0]{'pos'}});
			$ai_v{'temp'}{'dist_to'} = distance(\%{$items{$_}{'pos'}}, \%{$ai_seq_args[0]{'pos_to'}});
			if (($ai_v{'temp'}{'dist'} <= 4 || $ai_v{'temp'}{'dist_to'} <= 4) && $items{$_}{'take_failed'} == 0) {
				$ai_v{'temp'}{'foundID'} = $_;
				last;
			}
		}
		if ($ai_v{'temp'}{'foundID'}) {
			$ai_seq_args[0]{'ai_items_take_end'}{'time'} = time;
			$ai_seq_args[0]{'started'} = 1;
			take($ai_v{'temp'}{'foundID'});
		} elsif ($ai_seq_args[0]{'started'} || timeOut(\%{$ai_seq_args[0]{'ai_items_take_end'}})) {
			shift @ai_seq;
			shift @ai_seq_args;
			ai_clientSuspend(0, $timeout{'ai_attack_waitAfterKill'}{'timeout'});
		}
	}



	##### ITEMS AUTO-GATHER #####


	if (($ai_seq[0] eq "" || $ai_seq[0] eq "follow" || $ai_seq[0] eq "route" || $ai_seq[0] eq "mapRoute")
	    && $config{'itemsGatherAuto'}
	    && !(percent_weight(\%{$chars[$config{'char'}]}) >= $config{'itemsMaxWeight'})
	    && timeOut(\%{$timeout{'ai_items_gather_auto'}})) {
		undef @{$ai_v{'ai_items_gather_foundIDs'}};
		foreach (@playersID) {
			next if ($_ eq "");
			if (!%{$chars[$config{'char'}]{'party'}} || !%{$chars[$config{'char'}]{'party'}{'users'}{$_}}) {
				push @{$ai_v{'ai_items_gather_foundIDs'}}, $_;
			}
		}
		foreach $item (@itemsID) {
			next if ($item eq "" || time - $items{$item}{'appear_time'} < $timeout{'ai_items_gather_start'}{'timeout'}
				|| $items{$item}{'take_failed'} >= 1
				|| $itemsPickup{lc($items{$item}{'name'})} eq "0" || (!$itemsPickup{'all'} && !$itemsPickup{lc($items{$item}{'name'})}));
			undef $ai_v{'temp'}{'dist'};
			undef $ai_v{'temp'}{'found'};
			foreach (@{$ai_v{'ai_items_gather_foundIDs'}}) {
				$ai_v{'temp'}{'dist'} = distance(\%{$items{$item}{'pos'}}, \%{$players{$_}{'pos_to'}});
				if ($ai_v{'temp'}{'dist'} < 9) {
					$ai_v{'temp'}{'found'} = 1;
					last;
				}
			}
			if ($ai_v{'temp'}{'found'} == 0) {
				gather($item);
				last;
			}
		}
		$timeout{'ai_items_gather_auto'}{'time'} = time;
	}



	##### ITEMS GATHER #####


	if ($ai_seq[0] eq "items_gather" && $ai_seq_args[0]{'suspended'}) {
		$ai_seq_args[0]{'ai_items_gather_giveup'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		undef $ai_seq_args[0]{'suspended'};
	}
	if ($ai_seq[0] eq "items_gather" && !%{$items{$ai_seq_args[0]{'ID'}}}) {
    message "Failed to gather $items_old{$ai_seq_args[0]{'ID'}}{'name'} ($items_old{$ai_seq_args[0]{'ID'}}{'binID'}) : Lost target\n", "drop";
		shift @ai_seq;
		shift @ai_seq_args;
	} elsif ($ai_seq[0] eq "items_gather") {
		undef $ai_v{'temp'}{'dist'};
		undef @{$ai_v{'ai_items_gather_foundIDs'}};
		undef $ai_v{'temp'}{'found'};
		foreach (@playersID) {
			next if ($_ eq "");
			if (%{$chars[$config{'char'}]{'party'}} && !%{$chars[$config{'char'}]{'party'}{'users'}{$_}}) {
				push @{$ai_v{'ai_items_gather_foundIDs'}}, $_;
			}
		}
		foreach (@{$ai_v{'ai_items_gather_foundIDs'}}) {
			$ai_v{'temp'}{'dist'} = distance(\%{$items{$ai_seq_args[0]{'ID'}}{'pos'}}, \%{$players{$_}{'pos'}});
			if ($ai_v{'temp'}{'dist'} < 9) {
				$ai_v{'temp'}{'found'}++;
			}
		}
		$ai_v{'temp'}{'dist'} = distance(\%{$items{$ai_seq_args[0]{'ID'}}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}});
		if (timeOut(\%{$ai_seq_args[0]{'ai_items_gather_giveup'}})) {
			message "Failed to gather $items{$ai_seq_args[0]{'ID'}}{'name'} ($items{$ai_seq_args[0]{'ID'}}{'binID'}) : Timeout\n",,1;
			$items{$ai_seq_args[0]{'ID'}}{'take_failed'}++;
			shift @ai_seq;
			shift @ai_seq_args;
		} elsif ($chars[$config{'char'}]{'sitting'}) {
			ai_setSuspend(0);
			stand();
		} elsif ($ai_v{'temp'}{'found'} == 0 && $ai_v{'temp'}{'dist'} > 2) {
			getVector(\%{$ai_v{'temp'}{'vec'}}, \%{$items{$ai_seq_args[0]{'ID'}}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}});
			moveAlongVector(\%{$ai_v{'temp'}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_v{'temp'}{'vec'}}, $ai_v{'temp'}{'dist'} - 1);
			move($ai_v{'temp'}{'pos'}{'x'}, $ai_v{'temp'}{'pos'}{'y'});
		} elsif ($ai_v{'temp'}{'found'} == 0) {
			$ai_v{'ai_items_gather_ID'} = $ai_seq_args[0]{'ID'};
			shift @ai_seq;
			shift @ai_seq_args;
			take($ai_v{'ai_items_gather_ID'});
		} elsif ($ai_v{'temp'}{'found'} > 0) {
			message "Failed to gather $items{$ai_seq_args[0]{'ID'}}{'name'} ($items{$ai_seq_args[0]{'ID'}}{'binID'}) : No looting!\n",,1;
			shift @ai_seq;
			shift @ai_seq_args;
		}
	}



	##### TAKE #####


	if ($ai_seq[0] eq "take" && $ai_seq_args[0]{'suspended'}) {
		$ai_seq_args[0]{'ai_take_giveup'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		undef $ai_seq_args[0]{'suspended'};
	}
	if ($ai_seq[0] eq "take" && !%{$items{$ai_seq_args[0]{'ID'}}}) {
		shift @ai_seq;
		shift @ai_seq_args;

	} elsif ($ai_seq[0] eq "take" && timeOut(\%{$ai_seq_args[0]{'ai_take_giveup'}})) {
		message "Failed to take $items{$ai_seq_args[0]{'ID'}}{'name'} ($items{$ai_seq_args[0]{'ID'}}{'binID'})\n",,1;
		$items{$ai_seq_args[0]{'ID'}}{'take_failed'}++;
		shift @ai_seq;
		shift @ai_seq_args;

	} elsif ($ai_seq[0] eq "take") {

		$ai_v{'temp'}{'dist'} = distance(\%{$items{$ai_seq_args[0]{'ID'}}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}});
		if ($chars[$config{'char'}]{'sitting'}) {
			stand();
		} elsif ($ai_v{'temp'}{'dist'} > 2) {
			getVector(\%{$ai_v{'temp'}{'vec'}}, \%{$items{$ai_seq_args[0]{'ID'}}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}});
			moveAlongVector(\%{$ai_v{'temp'}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_v{'temp'}{'vec'}}, $ai_v{'temp'}{'dist'} - 1);
			move($ai_v{'temp'}{'pos'}{'x'}, $ai_v{'temp'}{'pos'}{'y'});
		} elsif (timeOut(\%{$timeout{'ai_take'}})) {
			sendTake(\$remote_socket, $ai_seq_args[0]{'ID'});
			$timeout{'ai_take'}{'time'} = time;
		}
	}

	
	##### MOVE #####

	if ($ai_seq[0] eq "move" && $ai_seq_args[0]{'suspended'}) {
		$ai_seq_args[0]{'ai_move_giveup'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		undef $ai_seq_args[0]{'suspended'};
	}
	if ($ai_seq[0] eq "move") {
		if (timeOut(\%{$ai_seq_args[0]{'ai_move_giveup'}})) {
			# We couldn't move within ai_move_giveup seconds; abort
			debug("Move - give up\n", "ai_move");
			stuckCheck(1);
			shift @ai_seq;
			shift @ai_seq_args;

		} elsif ($chars[$config{'char'}]{'sitting'}) {
			# Stand if we're sitting
			ai_setSuspend(0);
			stand();

		} elsif ($ai_seq_args[0]{'stage'} eq '') {
			my $from = "$chars[$config{char}]{pos_to}{x}, $chars[$config{char}]{pos_to}{y}";
			my $to = int($ai_seq_args[0]{move_to}{x}) . ", " . int($ai_seq_args[0]{move_to}{y});
			my $dist = sprintf("%.1f", distance($chars[$config{char}]{pos_to}, $ai_seq_args[0]{move_to}));
			debug("Move - sending move from ($from) to ($to), distance $dist\n", "ai_move");

			sendMove(\$remote_socket, $ai_seq_args[0]{'move_to'}{'x'}, $ai_seq_args[0]{'move_to'}{'y'});
			$ai_seq_args[0]{'ai_move_giveup'}{'time'} = time;
			$ai_seq_args[0]{'ai_move_time_last'} = $chars[$config{'char'}]{'time_move'};
			$ai_seq_args[0]{'ai_move_started'}{'time'} = time;
			$ai_seq_args[0]{'ai_move_started'}{'timeout'} = ($timeout{'ai_move_retry'}{'timeout'} || 0.25);
			$ai_seq_args[0]{'stage'} = 'Sent Move Request';

		} elsif ($ai_seq_args[0]{'ai_move_time_last'} eq $chars[$config{'char'}]{'time_move'}
		     && timeOut($ai_seq_args[0]{'ai_move_started'})) {
			# We haven't moved yet, send move request again
			$ai_seq_args[0]{'ai_move_started'}{'time'} = time;
			sendMove(\$remote_socket, int($ai_seq_args[0]{'move_to'}{'x'}), int($ai_seq_args[0]{'move_to'}{'y'}));

		} elsif ($ai_seq_args[0]{'move_to'}{'x'} eq $chars[$config{'char'}]{'pos_to'}{'x'}
		      && $ai_seq_args[0]{'move_to'}{'y'} eq $chars[$config{'char'}]{'pos_to'}{'y'}) {
			# We've arrived at our destination. Remove the move AI sequence.
			debug("Move - arrived\n", "ai_move");
			stuckCheck(0);
			shift @ai_seq;
			shift @ai_seq_args;
		}
	}


	##### AUTO-TELEPORT #####

	($ai_v{'map_name_lu'}) = $map_name =~ /([\s\S]*)\./;
	$ai_v{'map_name_lu'} .= ".rsw";
	if ($config{'teleportAuto_onlyWhenSafe'} && binSize(\@playersID)) {
		undef $ai_v{'ai_teleport_safe'};
		if (!$cities_lut{$ai_v{'map_name_lu'}} && timeOut(\%{$timeout{'ai_teleport_safe_force'}})) {
			$ai_v{'ai_teleport_safe'} = 1;
		}
	} elsif (!$cities_lut{$ai_v{'map_name_lu'}}) {
		$ai_v{'ai_teleport_safe'} = 1;
		$timeout{'ai_teleport_safe_force'}{'time'} = time;
	} else {
		undef $ai_v{'ai_teleport_safe'};
	}

	if (timeOut(\%{$timeout{'ai_teleport_away'}}) && $ai_v{'ai_teleport_safe'}) {
		foreach (@monstersID) {
			if ($mon_control{lc($monsters{$_}{'name'})}{'teleport_auto'} == 1) {
				useTeleport(1);
				$ai_v{'temp'}{'search'} = 1;
				last;
			}
		}
		$timeout{'ai_teleport_away'}{'time'} = time;
	}

	if ((($config{'teleportAuto_hp'} && percent_hp(\%{$chars[$config{'char'}]}) <= $config{'teleportAuto_hp'} && ai_getAggressives())
		|| ($config{'teleportAuto_minAggressives'} && ai_getAggressives() >= $config{'teleportAuto_minAggressives'}))
		&& $ai_v{'ai_teleport_safe'} && timeOut(\%{$timeout{'ai_teleport_hp'}})) {
		useTeleport(1);
		$ai_v{'clear_aiQueue'} = 1;
		$timeout{'ai_teleport_hp'}{'time'} = time;
	}

	if ($config{'teleportAuto_search'} && timeOut(\%{$timeout{'ai_teleport_search'}}) && binFind(\@ai_seq, "attack") eq "" && binFind(\@ai_seq, "items_take") eq ""
	 && $ai_v{'ai_teleport_safe'} && binFind(\@ai_seq, "sitAuto") eq "" 
	 && binFind(\@ai_seq, "buyAuto") eq "" && binFind(\@ai_seq, "sellAuto") eq "" && binFind(\@ai_seq, "storageAuto") eq "" 
	 && ($ai_v{'map_name_lu'} eq $config{'lockMap'}.'.rsw' || $config{'lockMap'} eq "")) {
		undef $ai_v{'temp'}{'search'};
		foreach (keys %mon_control) {
			if ($mon_control{$_}{'teleport_search'}) {
				$ai_v{'temp'}{'search'} = 1;
				last;
			}
		}
		if ($ai_v{'temp'}{'search'}) {
			undef $ai_v{'temp'}{'found'};
			foreach (@monstersID) {
				if ($mon_control{lc($monsters{$_}{'name'})}{'teleport_search'} && !$monsters{$_}{'attack_failed'}) {
					$ai_v{'temp'}{'found'} = 1;
					last;
				}
			}
			if (!$ai_v{'temp'}{'found'}) {
				useTeleport(1);
				$ai_v{'clear_aiQueue'} = 1;
			}
		}
		$timeout{'ai_teleport_search'}{'time'} = time;
	}

	if ($config{'teleportAuto_idle'} && $ai_seq[0] ne "") {
		$timeout{'ai_teleport_idle'}{'time'} = time;
	}

	if ($config{'teleportAuto_idle'} && timeOut(\%{$timeout{'ai_teleport_idle'}}) && $ai_v{'ai_teleport_safe'}) {
		useTeleport(1);
		$ai_v{'clear_aiQueue'} = 1;
		$timeout{'ai_teleport_idle'}{'time'} = time;
	}

	if ($config{'teleportAuto_portal'} && timeOut(\%{$timeout{'ai_teleport_portal'}}) && $ai_v{'ai_teleport_safe'}) {
		if (binSize(\@portalsID)) {
			useTeleport(1);
			$ai_v{'clear_aiQueue'} = 1;
		}
		$timeout{'ai_teleport_portal'}{'time'} = time;
	}

	##### AUTO RESPONSE #####

	if ($ai_seq[0] eq "respAuto" && time >= $nextresptime) {
		$i = $ai_seq_args[0]{'resp_num'};
		$num_resp = getListCount($chat_resp{"words_resp_$i"});
		sendMessage(\$remote_socket, "c", getFromList($chat_resp{"words_resp_$i"}, int(rand() * ($num_resp - 1))));
		shift @ai_seq;
		shift @ai_seq_args;
	}

	if ($ai_seq[0] eq "respPMAuto" && time >= $nextrespPMtime) {
		$i = $ai_seq_args[0]{'resp_num'};
		$privMsgUser = $ai_seq_args[0]{'resp_user'};
		$num_resp = getListCount($chat_resp{"words_resp_$i"});
		sendMessage(\$remote_socket, "pm", getFromList($chat_resp{"words_resp_$i"}, int(rand() * ($num_resp - 1))), $privMsgUser);
		shift @ai_seq;
		shift @ai_seq_args;
	}



	##### AVOID GM OR PLAYERS #####

	if (timeOut(\%{$timeout{'ai_avoidcheck'}})) {
		if ($config{'avoidGM_near'} && (!$config{'avoidGM_near_inTown'} || !$cities_lut{$field{'name'}.'.rsw'})) {
			avoidGM_near ();
		}
		if ($config{'avoidList'}) {
			avoidList_near ();
		}
		$timeout{'ai_avoidcheck'}{'time'} = time;
	}


	##### SEND EMOTICON #####

	SENDEMOTION: {
		my $index = binFind(\@ai_seq, "sendEmotion");
		last SENDEMOTION if ($index eq "" || time < $ai_seq_args[$index]{'timeout'});
		sendEmotion(\$remote_socket, $ai_seq_args[$index]{'emotion'});
		aiRemove ("sendEmotion");
	}


	##### AUTO SHOP OPEN #####

	if ($config{"shopAuto_open"} && $ai_seq[0] eq "" && $conState == 5 && !$shopstarted && $chars[$config{'char'}]{'sitting'}
	    && timeOut(\%{$timeout{'ai_shop'}})) {
		sendOpenShop(\$remote_socket);
	}


	##########

	# DEBUG CODE
	if (time - $ai_v{'time'} > 2 && $config{'debug'} >= 2) {
		$stuff = @ai_seq_args;
		debug "AI: @ai_seq | $stuff\n", "ai";
		$ai_v{'time'} = time;
	}

	if ($ai_v{'clear_aiQueue'}) {
		undef $ai_v{'clear_aiQueue'};
		undef @ai_seq;
		undef @ai_seq_args;
	}
	
}


#######################################
#######################################
# Parse RO Client Send Message
#######################################
#######################################

sub parseSendMsg {
	my $msg = shift;

	$sendMsg = $msg;
	if (length($msg) >= 4 && $conState >= 4 && length($msg) >= unpack("S1", substr($msg, 0, 2))) {
		decrypt(\$msg, $msg);
	}
	$switch = uc(unpack("H2", substr($msg, 1, 1))) . uc(unpack("H2", substr($msg, 0, 1)));
	debug "Packet Switch SENT_BY_CLIENT: $switch\n", "parseSendMsg", 0 if ($config{'debugPacket_ro_sent'} && !existsInList($config{'debugPacket_exclude'}, $switch));

	# If the player tries to manually do something in the RO client, disable AI for a small period
	# of time using ai_clientSuspend().

	if ($switch eq "0066") {
 		# Login character selected
		configModify("char", unpack("C*",substr($msg, 2, 1)));

	} elsif ($switch eq "0072") {
		# Map login
		if ($config{'sex'} ne "") {
			$sendMsg = substr($sendMsg, 0, 18) . pack("C",$config{'sex'});
		}

	} elsif ($switch eq "007D") {
		# Map loaded
		$conState = 5;
		$timeout{'ai'}{'time'} = time;
		if ($firstLoginMap) {
			undef $sentWelcomeMessage;
			undef $firstLoginMap;
		}
		$timeout{'welcomeText'}{'time'} = time;
		message "Map loaded\n", "connection";

	} elsif ($switch eq "0085") {
		# Move
		aiRemove("clientSuspend");
		makeCoords(\%coords, substr($msg, 2, 3));
		ai_clientSuspend($switch, (distance(\%{$chars[$config{'char'}]{'pos'}}, \%coords) * $config{'seconds_per_block'}) + 2);
		
	} elsif ($switch eq "0089") {
		# Attack
		if (!($config{'tankMode'} && binFind(\@ai_seq, "attack") ne "")) {
			aiRemove("clientSuspend");
			ai_clientSuspend($switch, 2, unpack("C*",substr($msg,6,1)), substr($msg,2,4));
		} else {
			undef $sendMsg;
		}
	} elsif ($switch eq "008C" || $switch eq "0108" || $switch eq "017E") {
		# Public, party and guild chat
		my $length = unpack("S",substr($msg,2,2));
		my $message = substr($msg, 4, $length - 4);
		my ($chat) = $message =~ /^[\s\S]*? : ([\s\S]*)\000?/;
		$chat =~ s/^\s*//;
		if ($chat =~ /^$config{'commandPrefix'}/) {
			$chat =~ s/^$config{'commandPrefix'}//;
			$chat =~ s/^\s*//;
			$chat =~ s/\s*$//;
			$chat =~ s/\000*$//;
			parseInput($chat, 1);
			undef $sendMsg;
		}

	} elsif ($switch eq "0096") {
		# Private message
		$length = unpack("S",substr($msg,2,2));
		($user) = substr($msg, 4, 24) =~ /([\s\S]*?)\000/;
		$chat = substr($msg, 28, $length - 29);
		$chat =~ s/^\s*//;
		if ($chat =~ /^$config{'commandPrefix'}/) {
			$chat =~ s/^$config{'commandPrefix'}//;
			$chat =~ s/^\s*//;
			$chat =~ s/\s*$//;
			parseInput($chat, 1);
			undef $sendMsg;
		} else {
			undef %lastpm;
			$lastpm{'msg'} = $chat;
			$lastpm{'user'} = $user;
			push @lastpm, {%lastpm};
		}

	} elsif ($switch eq "009F") {
		# Take
		aiRemove("clientSuspend");
		ai_clientSuspend($switch, 2, substr($msg,2,4));

	} elsif ($switch eq "00B2") {
		# Trying to exit (respawn)
		aiRemove("clientSuspend");
		ai_clientSuspend($switch, 10);

	} elsif ($switch eq "018A") {
		# Trying to exit
		aiRemove("clientSuspend");
		ai_clientSuspend($switch, 10);
	}

	if ($sendMsg ne "") {
		sendToServerByInject(\$remote_socket, $sendMsg);
	}

	Plugins::callHook('AI_post');
}


#######################################
#######################################
#Parse Message
#######################################
#######################################



##
# parseMsg(msg)
# msg: The data to parse, as received from the socket.
# Returns: The remaining bytes.
#
# When data (packets) from the RO server is received, it will be send to this
# function. It will determine what kind of packet this data is and process it.
# The length of the packets are gotten from recvpackets.txt.
#
# The received data does not always contain a complete packet, or may contain a
# piece of the next packet.
# If it contains a piece of the next packet too, parseMsg will delete the bytes
# of the first packet that's processed, and return the remaining bytes.
# If the data doesn't contain a complete packet, parseMsg will return "". $msg
# will be remembered by the main loop.
# Next time data from the RO server is received, the remaining bytes as returned
# by paseMsg, or the incomplete packet that the main loop remembered, will be
# prepended to the fresh data received from the RO server and then passed to
# parseMsg again.
# See also the main loop about how parseMsg's return value is treated.

# Types:
# word : 2-byte unsigned integer
# long : 4-byte unsigned integer
# byte : 1-byte character/integer
# bool : 1-byte boolean (true/false)
sub parseMsg {
	my $msg = shift;
	my $msg_size;

	# Determine packet switch
	$switch = uc(unpack("H2", substr($msg, 1, 1))) . uc(unpack("H2", substr($msg, 0, 1)));
	if (length($msg) >= 4 && substr($msg,0,4) ne $accountID && $conState >= 4 && $lastswitch ne $switch
	 && length($msg) >= unpack("S1", substr($msg, 0, 2))) {
		decrypt(\$msg, $msg);
	}
	$switch = uc(unpack("H2", substr($msg, 1, 1))) . uc(unpack("H2", substr($msg, 0, 1)));
	debug "Packet Switch: $switch\n", "parseMsg", 0 if ($config{'debugPacket_received'} && !existsInList($config{'debugPacket_exclude'}, $switch));

	# The user is running in X-Kore mode and wants to switch character.
	# We're now expecting an accountID.
	if ($conState == 2.5) {
		if (length($msg) >= 4) {
			$conState = 2;
			$accountID = substr($msg, 0, 4);
			return substr($msg, 4);
		} else {
			return $msg;
		}
	}

	$lastswitch = $switch;
	# Determine packet length using recvpackets.txt.
	if (substr($msg,0,4) ne $accountID || ($conState != 2 && $conState != 4)) {
		if ($rpackets{$switch} eq "-") {
			# Complete packet; the size of this packet is equal
			# to the size of the entire data
			$msg_size = length($msg);

		} elsif ($rpackets{$switch} eq "0") {
			# Variable length packet
			if (length($msg) < 4) {
				return $msg;
			}
			$msg_size = unpack("S1", substr($msg, 2, 2));
			if (length($msg) < $msg_size) {
				return $msg;
			}

		} elsif ($rpackets{$switch} > 1) {
			# Static length packet
			$msg_size = $rpackets{$switch};
			if (length($msg) < $msg_size) {
				return $msg;
			}

		} else {
			# Unknown packet - ignore it
			if (!existsInList($config{'debugPacket_exclude'}, $switch)) {
				warning("Unknown packet - $switch\n", "connection");
				dumpData($msg) if ($config{'debugPacket_unparsed'});
			}
			return "";
		}
	}

	if ((substr($msg,0,4) eq $accountID && ($conState == 2 || $conState == 4))
	 || ($config{'XKore'} && !$accountID && length($msg) == 4)) {
		$accountID = substr($msg, 0, 4);
		$AI = 1 if (!$AI_forcedOff);
		if ($config{'encrypt'} && $conState == 4) {
			my $encryptKey1 = unpack("L1", substr($msg, 6, 4));
			my $encryptKey2 = unpack("L1", substr($msg, 10, 4));
			my ($imult, $imult2);
			{
				use integer;
				$imult = (($encryptKey1 * $encryptKey2) + $encryptKey1) & 0xFF;
				$imult2 = ((($encryptKey1 * $encryptKey2) << 4) + $encryptKey2 + ($encryptKey1 * 2)) & 0xFF;
			}
			$encryptVal = $imult + ($imult2 << 8);
			$msg_size = 14;
		} else {
			$msg_size = 4;
		}

	} elsif ($switch eq "0069") {
		$conState = 2;
		undef $conState_tries;
		if ($versionSearch) {
			$versionSearch = 0;
			Misc::saveConfigFile();
		}
		$sessionID = substr($msg, 4, 4);
		$accountID = substr($msg, 8, 4);
		$accountSex = unpack("C1",substr($msg, 46, 1));
		$accountSex2 = ($config{'sex'} ne "") ? $config{'sex'} : $accountSex;
		message(swrite(
			"---------Account Info----------", [undef],
			"Account ID: @<<<<<<<<<<<<<<<<<<", [getHex($accountID)],
			"Sex:        @<<<<<<<<<<<<<<<<<<", [$sex_lut{$accountSex}],
			"Session ID: @<<<<<<<<<<<<<<<<<<", [getHex($sessionID)],
			"-------------------------------", [undef],
		), "connection");

		$num = 0;
		undef @servers;
		for($i = 47; $i < $msg_size; $i+=32) {
			$servers[$num]{'ip'} = makeIP(substr($msg, $i, 4));
			$servers[$num]{'port'} = unpack("S1", substr($msg, $i+4, 2));
			($servers[$num]{'name'}) = substr($msg, $i + 6, 20) =~ /([\s\S]*?)\000/;
			$servers[$num]{'users'} = unpack("L",substr($msg, $i + 26, 4));
			$num++;
		}

		message("--------- Servers ----------\n", "connection");
		message("#         Name            Users  IP              Port\n", "connection");
		for ($num = 0; $num < @servers; $num++) {
			message(swrite(
				"@<< @<<<<<<<<<<<<<<<<<<<< @<<<<< @<<<<<<<<<<<<<< @<<<<<",
				[$num, $servers[$num]{'name'}, $servers[$num]{'users'}, $servers[$num]{'ip'}, $servers[$num]{'port'}]
			), "connection");
		}
		message("-------------------------------\n", "connection");

		if (!$config{'XKore'}) {
			message("Closing connection to Master Server\n", "connection");
			Network::disconnect(\$remote_socket);
			if ($config{'server'} eq "") {
				message("Choose your server.  Enter the server number: ", "input");
				$waitingForInput = 1;
			} else {
				message("Server $config{'server'} selected\n", "connection");
			}
		}

	} elsif ($switch eq "006A") {
		$type = unpack("C1",substr($msg, 2, 1));
		if ($type == 0) {
			error("Account name doesn't exist\n", "connection");
			if (!$config{'XKore'}) {
				message("Enter Username Again: ", "input");
				$msg = $interface->getInput(-1);
				configModify('username', $msg, 1);
			}
			relog();
		} elsif ($type == 1) {
			error("Password Error\n", "connection");
			if (!$config{'XKore'}) {
				message("Enter Password Again: ", "input");
				$msg = $interface->getInput(-1);
				configModify('password', $msg, 1);
			}
		} elsif ($type == 3) {
			error("Server connection has been denied\n", "connection");
		} elsif ($type == 4) {
			$interface->errorDialog("Critical Error: Your account has been blocked.");
			$quit = 1;
		} elsif ($type == 5) {
			error("Version $config{'version'} failed...trying to find version\n", "connection");
			$config{'version'}++;
			if (!$versionSearch) {
				$config{'version'} = 0;
				$versionSearch = 1;
			}
			relog();
		} elsif ($type == 6) {
			error("The server is temporarily blocking your connection\n", "connection");
		}
		if ($type != 5 && $versionSearch) {
			$versionSearch = 0;
			Misc::saveConfigFile();
		}

	} elsif ($switch eq "006B") {
		message("Received characters from Game Login Server\n", "connection");
		$conState = 3;
		undef $conState_tries;
		undef @chars;

		#my ($startVal, $num);
		#if ($config{"master_version_$config{'master'}"} ne "" && $config{"master_version_$config{'master'}"} == 0) {
		#	$startVal = 24;
		#} else {
		#	$startVal = 4;
		#}
		$startVal = $msg_size % 106;

		for (my $i = $startVal; $i < $msg_size; $i += 106) {
			#exp display bugfix - chobit andy 20030129
			$num = unpack("C1", substr($msg, $i + 104, 1));
			$chars[$num]{'exp'} = unpack("L1", substr($msg, $i + 4, 4));
			$chars[$num]{'zenny'} = unpack("L1", substr($msg, $i + 8, 4));
			$chars[$num]{'exp_job'} = unpack("L1", substr($msg, $i + 12, 4));
			$chars[$num]{'lv_job'} = unpack("C1", substr($msg, $i + 16, 1));
			$chars[$num]{'hp'} = unpack("S1", substr($msg, $i + 42, 2));
			$chars[$num]{'hp_max'} = unpack("S1", substr($msg, $i + 44, 2));
			$chars[$num]{'sp'} = unpack("S1", substr($msg, $i + 46, 2));
			$chars[$num]{'sp_max'} = unpack("S1", substr($msg, $i + 48, 2));
			$chars[$num]{'jobID'} = unpack("C1", substr($msg, $i + 52, 1));
			$chars[$num]{'ID'} = substr($msg, $i, 4) ;
			$chars[$num]{'lv'} = unpack("C1", substr($msg, $i + 58, 1));
			($chars[$num]{'name'}) = substr($msg, $i + 74, 24) =~ /([\s\S]*?)\000/;
			$chars[$num]{'str'} = unpack("C1", substr($msg, $i + 98, 1));
			$chars[$num]{'agi'} = unpack("C1", substr($msg, $i + 99, 1));
			$chars[$num]{'vit'} = unpack("C1", substr($msg, $i + 100, 1));
			$chars[$num]{'int'} = unpack("C1", substr($msg, $i + 101, 1));
			$chars[$num]{'dex'} = unpack("C1", substr($msg, $i + 102, 1));
			$chars[$num]{'luk'} = unpack("C1", substr($msg, $i + 103, 1));
			$chars[$num]{'sex'} = $accountSex2;
		}

		for ($num = 0; $num < @chars; $num++) {
			message(swrite(
				"-------  Character @< ---------",
				[$num],
				"Name: @<<<<<<<<<<<<<<<<<<<<<<<<",
				[$chars[$num]{'name'}],
				"Job:  @<<<<<<<      Job Exp: @<<<<<<<",
				[$jobs_lut{$chars[$num]{'jobID'}}, $chars[$num]{'exp_job'}],
				"Lv:   @<<<<<<<      Str: @<<<<<<<<",
				[$chars[$num]{'lv'}, $chars[$num]{'str'}],
				"J.Lv: @<<<<<<<      Agi: @<<<<<<<<",
				[$chars[$num]{'lv_job'}, $chars[$num]{'agi'}],
				"Exp:  @<<<<<<<      Vit: @<<<<<<<<",
				[$chars[$num]{'exp'}, $chars[$num]{'vit'}],
				"HP:   @||||/@||||   Int: @<<<<<<<<",
				[$chars[$num]{'hp'}, $chars[$num]{'hp_max'}, $chars[$num]{'int'}],
				"SP:   @||||/@||||   Dex: @<<<<<<<<",
				[$chars[$num]{'sp'}, $chars[$num]{'sp_max'}, $chars[$num]{'dex'}],
				"Zenny: @<<<<<<<<<<  Luk: @<<<<<<<<",
				[$chars[$num]{'zenny'}, $chars[$num]{'luk'}],
				"-------------------------------", []),
				"connection");

				my $j = 0;
				while ($avoid{"avoid_$j"} ne "") {
					if ($chars[$num]{'name'} eq $avoid{"avoid_$j"} || $chars[$num]{'name'} =~ /^([a-z]?ro)?-?(Sub)?-?\[?GM\]?/i) {
						$interface->errorDialog("Sanity Checking FAILED: Invalid username detected.");
						Network::disconnect(\$remote_socket);
						quit();
					}
					$j++;
				}
			}
		if (!$config{'XKore'}) {
			if ($config{'char'} eq "") {
				message("Choose your character.  Enter the character number:\n", "input");
				$waitingForInput = 1;
			} else {
				message("Character $config{'char'} selected\n", "connection");
				sendCharLogin(\$remote_socket, $config{'char'});
				$timeout{'charlogin'}{'time'} = time;
			}
		}
		$firstLoginMap = 1;
		$startingZenny = $chars[$config{'char'}]{'zenny'} unless defined $startingZenny;
		$sentWelcomeMessage = 1;

	} elsif ($switch eq "006C") {
		error("Error logging into Game Login Server (invalid character specified)...\n", "connection");
		$conState = 1;
		undef $conState_tries;
		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		Network::disconnect(\$remote_socket);

	} elsif ($switch eq "0071") {
		message "Recieved character ID and Map IP from Game Login Server\n", "connection";
		$conState = 4;
		undef $conState_tries;
		$charID = substr($msg, 2, 4);
		($map_name) = substr($msg, 6, 16) =~ /([\s\S]*?)\000/;

		($ai_v{'temp'}{'map'}) = $map_name =~ /([\s\S]*)\./;
		if ($ai_v{'temp'}{'map'} ne $field{'name'}) {
			getField("$Settings::def_field/$ai_v{'temp'}{'map'}.fld", \%field);
		}

		$map_ip = makeIP(substr($msg, 22, 4));
		$map_port = unpack("S1", substr($msg, 26, 2));
		message(swrite(
			"---------Game Info----------", [],
			"Char ID: @<<<<<<<<<<<<<<<<<<",
			[getHex($charID)],
			"MAP Name: @<<<<<<<<<<<<<<<<<<",
			[$map_name],
			"MAP IP: @<<<<<<<<<<<<<<<<<<",
			[$map_ip],
			"MAP Port: @<<<<<<<<<<<<<<<<<<",
			[$map_port],
			"-------------------------------", []),
			"connection");
		message("Closing connection to Game Login Server\n", "connection") if (!$config{'XKore'});
		Network::disconnect(\$remote_socket) if (!$config{'XKore'});
		initStatVars();

	} elsif ($switch eq "0073") {
		$conState = 5;
		undef $conState_tries;
		makeCoords(\%{$chars[$config{'char'}]{'pos'}}, substr($msg, 6, 3));
		%{$chars[$config{'char'}]{'pos_to'}} = %{$chars[$config{'char'}]{'pos'}};
		message("Your Coordinates: $chars[$config{'char'}]{'pos'}{'x'}, $chars[$config{'char'}]{'pos'}{'y'}\n", undef, 1);
		message("You are now in the game\n", "connection") if (!$config{'XKore'});
		message("Waiting for map to load...\n", "connection") if ($config{'XKore'});
		sendMapLoaded(\$remote_socket) if (!$config{'XKore'});
		sendIgnoreAll(\$remote_socket, "all") if ($config{'ignoreAll'});
		$timeout{'ai'}{'time'} = time if (!$config{'XKore'});

	} elsif ($switch eq "0075") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});

	} elsif ($switch eq "0077") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});

	} elsif ($switch eq "0078") {
		# 0078: long ID, word speed, word opt1, word opt2, word option, word class, word hair,
		# word weapon, word head_option_bottom, word sheild, word head_option_top, word head_option_mid,
		# word hair_color, word ?, word head_dir, long guild, long emblem, word manner, byte karma,
		# byte sex, 3byte X_Y_dir, byte ?, byte ?, byte sit, byte level
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		my $ID = substr($msg, 2, 4);
		makeCoords(\%coords, substr($msg, 46, 3));
		my $type = unpack("S*",substr($msg, 14,  2));
		my $pet = unpack("C*",substr($msg, 16,  1));
		my $sex = unpack("C*",substr($msg, 45,  1));
		my $sitting = unpack("C*",substr($msg, 51,  1));
		
		if ($type >= 1000) {
			if ($pet) {
				if (!%{$pets{$ID}}) {
					$pets{$ID}{'appear_time'} = time;
					$display = ($monsters_lut{$type} ne "") 
							? $monsters_lut{$type}
							: "Unknown ".$type;
					binAdd(\@petsID, $ID);
					$pets{$ID}{'nameID'} = $type;
					$pets{$ID}{'name'} = $display;
					$pets{$ID}{'name_given'} = "Unknown";
					$pets{$ID}{'binID'} = binFind(\@petsID, $ID);
				}
				%{$pets{$ID}{'pos'}} = %coords;
				%{$pets{$ID}{'pos_to'}} = %coords;
				debug "Pet Exists: $pets{$ID}{'name'} ($pets{$ID}{'binID'})\n", "parseMsg";
			} else {
				if (!%{$monsters{$ID}}) {
					$monsters{$ID}{'appear_time'} = time;
					$display = ($monsters_lut{$type} ne "") 
							? $monsters_lut{$type}
							: "Unknown ".$type;
					binAdd(\@monstersID, $ID);
					$monsters{$ID}{'nameID'} = $type;
					$monsters{$ID}{'name'} = $display;
					$monsters{$ID}{'binID'} = binFind(\@monstersID, $ID);
				}
				%{$monsters{$ID}{'pos'}} = %coords;
				%{$monsters{$ID}{'pos_to'}} = %coords;

				debug "Monster Exists: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'})\n", "parseMsg", 1;


				# Monster state
				my $param1 = unpack("S*", substr($msg, 8, 2));
				$param1 = 0 if $param1 == 5; # 5 has got something to do with the monster being undead
				if ($param1) {
					my $state = (defined $skillsState{$param1}) ? $skillsState{$param1} : "Unknown $param1";
					$monsters{$ID}{state}{$state} = 1;
					message "Monster $monsters{$ID}{name} ($monsters{$ID}{binID}) is affected by $state ($param1)\n", "parseMsg_statuslook", 1;
				} elsif ($monsters{$ID}{state}) {
					undef %{$monsters{$ID}{state}};
				}
			}

		} elsif ($jobs_lut{$type}) {
			if (!%{$players{$ID}}) {
				$players{$ID}{'appear_time'} = time;
				binAdd(\@playersID, $ID);
				$players{$ID}{'jobID'} = $type;
				$players{$ID}{'sex'} = $sex;
				$players{$ID}{'name'} = "Unknown";
				$players{$ID}{'nameID'} = unpack("L1", $ID);
				$players{$ID}{'binID'} = binFind(\@playersID, $ID);
			}
			$players{$ID}{'sitting'} = $sitting > 0;
			%{$players{$ID}{'pos'}} = %coords;
			%{$players{$ID}{'pos_to'}} = %coords;
			debug "Player Exists: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg", 1;

		} elsif ($type == 45) {
			if (!%{$portals{$ID}}) {
				$portals{$ID}{'appear_time'} = time;
				$nameID = unpack("L1", $ID);
				$exists = portalExists($field{'name'}, \%coords);
				$display = ($exists ne "")
					? "$portals_lut{$exists}{'source'}{'map'} -> " . getPortalDestName($exists)
					: "Unknown ".$nameID;
				binAdd(\@portalsID, $ID);
				$portals{$ID}{'source'}{'map'} = $field{'name'};
				$portals{$ID}{'type'} = $type;
				$portals{$ID}{'nameID'} = $nameID;
				$portals{$ID}{'name'} = $display;
				$portals{$ID}{'binID'} = binFind(\@portalsID, $ID);
			}
			%{$portals{$ID}{'pos'}} = %coords;
			message "Portal Exists: $portals{$ID}{'name'} - ($portals{$ID}{'binID'})\n", "portals", 1;

		} elsif ($type < 1000) {
			if (!%{$npcs{$ID}}) {
				$npcs{$ID}{'appear_time'} = time;
				$nameID = unpack("L1", $ID);
				$display = (%{$npcs_lut{$nameID}}) 
					? $npcs_lut{$nameID}{'name'}
					: "Unknown ".$nameID;
				binAdd(\@npcsID, $ID);
				$npcs{$ID}{'type'} = $type;
				$npcs{$ID}{'nameID'} = $nameID;
				$npcs{$ID}{'name'} = $display;
				$npcs{$ID}{'binID'} = binFind(\@npcsID, $ID);
			}
			%{$npcs{$ID}{'pos'}} = %coords;
			message "NPC Exists: $npcs{$ID}{'name'} (ID $npcs{$ID}{'nameID'}) - ($npcs{$ID}{'binID'})\n", undef, 1;

		} else {
			debug "Unknown Exists: $type - ".unpack("L*",$ID)."\n", "parseMsg";
		}

	} elsif ($switch eq "0079") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		my $ID = substr($msg, 2, 4);
		makeCoords(\%coords, substr($msg, 46, 3));
		my $type = unpack("S*",substr($msg, 14,  2));
		my $sex = unpack("C*",substr($msg, 45,  1));

		if ($jobs_lut{$type}) {
			if (!%{$players{$ID}}) {
				$players{$ID}{'appear_time'} = time;
				binAdd(\@playersID, $ID);
				$players{$ID}{'jobID'} = $type;
				$players{$ID}{'sex'} = $sex;
				$players{$ID}{'name'} = "Unknown";
				$players{$ID}{'nameID'} = unpack("L1", $ID);
				$players{$ID}{'binID'} = binFind(\@playersID, $ID);
			}
			%{$players{$ID}{'pos'}} = %coords;
			%{$players{$ID}{'pos_to'}} = %coords;
			debug "Player Connected: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg";

		} else {
			debug "Unknown Connected: $type - ", "parseMsg";
		}

	} elsif ($switch eq "007A") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});

	} elsif ($switch eq "007B") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$ID = substr($msg, 2, 4);
		makeCoords(\%coordsFrom, substr($msg, 50, 3));
		makeCoords2(\%coordsTo, substr($msg, 52, 3));
		$type = unpack("S*",substr($msg, 14,  2));
		$pet = unpack("C*",substr($msg, 16,  1));
		$sex = unpack("C*",substr($msg, 49,  1));
		if ($type >= 1000) {
			if ($pet) {
				if (!%{$pets{$ID}}) {
					$pets{$ID}{'appear_time'} = time;
					$display = ($monsters_lut{$type} ne "") 
							? $monsters_lut{$type}
							: "Unknown ".$type;
					binAdd(\@petsID, $ID);
					$pets{$ID}{'nameID'} = $type;
					$pets{$ID}{'name'} = $display;
					$pets{$ID}{'name_given'} = "Unknown";
					$pets{$ID}{'binID'} = binFind(\@petsID, $ID);
				}
				%{$pets{$ID}{'pos'}} = %coords;
				%{$pets{$ID}{'pos_to'}} = %coords;
				if (%{$monsters{$ID}}) {
					binRemove(\@monstersID, $ID);
					undef %{$monsters{$ID}};
				}
				debug "Pet Moved: $pets{$ID}{'name'} ($pets{$ID}{'binID'})\n", "parseMsg";
			} else {
				if (!%{$monsters{$ID}}) {
					binAdd(\@monstersID, $ID);
					$monsters{$ID}{'appear_time'} = time;
					$monsters{$ID}{'nameID'} = $type;
					$display = ($monsters_lut{$type} ne "") 
						? $monsters_lut{$type}
						: "Unknown ".$type;
					$monsters{$ID}{'nameID'} = $type;
					$monsters{$ID}{'name'} = $display;
					$monsters{$ID}{'binID'} = binFind(\@monstersID, $ID);
					debug "Monster Appeared: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'})\n", "parseMsg";
				}
				%{$monsters{$ID}{'pos'}} = %coordsFrom;
				%{$monsters{$ID}{'pos_to'}} = %coordsTo;
				debug "Monster Moved: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'})\n", "parseMsg", 2;
			}
		} elsif ($jobs_lut{$type}) {
			if (!%{$players{$ID}}) {
				binAdd(\@playersID, $ID);
				$players{$ID}{'appear_time'} = time;
				$players{$ID}{'sex'} = $sex;
				$players{$ID}{'jobID'} = $type;
				$players{$ID}{'name'} = "Unknown";
				$players{$ID}{'nameID'} = unpack("L1", $ID);
				$players{$ID}{'binID'} = binFind(\@playersID, $ID);
				
				debug "Player Appeared: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$sex} $jobs_lut{$type}\n", "parseMsg";
			}
			%{$players{$ID}{'pos'}} = %coordsFrom;
			%{$players{$ID}{'pos_to'}} = %coordsTo;
			debug "Player Moved: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg";
		} else {
			debug "Unknown Moved: $type - ".getHex($ID)."\n", "parseMsg";
		}

	} elsif ($switch eq "007C") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$ID = substr($msg, 2, 4);
		makeCoords(\%coords, substr($msg, 36, 3));
		$type = unpack("S*",substr($msg, 20,  2));
		$pet = unpack("C*",substr($msg, 22,  1));
		$sex = unpack("C*",substr($msg, 35,  1));
		if ($type >= 1000) {
			if ($pet) {
				if (!%{$pets{$ID}}) { 
					binAdd(\@petsID, $ID); 
					$pets{$ID}{'nameID'} = $type; 
					$pets{$ID}{'appear_time'} = time; 
					$display = ($monsters_lut{$pets{$ID}{'nameID'}} ne "") 
					? $monsters_lut{$pets{$ID}{'nameID'}} 
					: "Unknown ".$pets{$ID}{'nameID'}; 
					$pets{$ID}{'name'} = $display; 
					$pets{$ID}{'name_given'} = "Unknown";
					$pets{$ID}{'binID'} = binFind(\@petsID, $ID); 
				}
				%{$pets{$ID}{'pos'}} = %coords; 
				%{$pets{$ID}{'pos_to'}} = %coords; 
				debug "Pet Spawned: $pets{$ID}{'name'} ($pets{$ID}{'binID'})\n", "parseMsg";
			} else {
				if (!%{$monsters{$ID}}) {
					binAdd(\@monstersID, $ID);
					$monsters{$ID}{'nameID'} = $type;
					$monsters{$ID}{'appear_time'} = time;
					$display = ($monsters_lut{$monsters{$ID}{'nameID'}} ne "") 
							? $monsters_lut{$monsters{$ID}{'nameID'}}
							: "Unknown ".$monsters{$ID}{'nameID'};
					$monsters{$ID}{'name'} = $display;
					$monsters{$ID}{'binID'} = binFind(\@monstersID, $ID);
				}
				%{$monsters{$ID}{'pos'}} = %coords;
				%{$monsters{$ID}{'pos_to'}} = %coords;
				debug "Monster Spawned: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'})\n", "parseMsg";
			}
		} elsif ($jobs_lut{$type}) {
			if (!%{$players{$ID}}) {
				binAdd(\@playersID, $ID);
				$players{$ID}{'jobID'} = $type;
				$players{$ID}{'sex'} = $sex;
				$players{$ID}{'name'} = "Unknown";
				$players{$ID}{'nameID'} = unpack("L1", $ID);
				$players{$ID}{'appear_time'} = time;
				$players{$ID}{'binID'} = binFind(\@playersID, $ID);
			}
			%{$players{$ID}{'pos'}} = %coords;
			%{$players{$ID}{'pos_to'}} = %coords;
			debug "Player Spawned: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg";
		} else {
			debug "Unknown Spawned: $type - ".getHex($ID)."\n", "parseMsg";
		}
		
	} elsif ($switch eq "007F") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$time = unpack("L1",substr($msg, 2, 4));
		debug "Recieved Sync\n", "parseMsg", 2;
		$timeout{'play'}{'time'} = time;

	} elsif ($switch eq "0080") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$ID = substr($msg, 2, 4);
		$type = unpack("C1",substr($msg, 6, 1));

		if ($ID eq $accountID) {
			message "You have died\n";
			sendCloseShop(\$remote_socket);
			$chars[$config{'char'}]{'deathCount'}++;
			$chars[$config{'char'}]{'dead'} = 1;
			$chars[$config{'char'}]{'dead_time'} = time;

		} elsif (%{$monsters{$ID}}) {
			%{$monsters_old{$ID}} = %{$monsters{$ID}};
			$monsters_old{$ID}{'gone_time'} = time;
			if ($type == 0) {
				debug "Monster Disappeared: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'})\n", "parseMsg";
				$monsters_old{$ID}{'disappeared'} = 1;

			} elsif ($type == 1) {
				debug "Monster Died: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'})\n", "parseMsg";
				$monsters_old{$ID}{'dead'} = 1;
			}
			binRemove(\@monstersID, $ID);
			undef %{$monsters{$ID}};
			delete $monsters{$ID};

		} elsif (%{$players{$ID}}) {
			if ($type == 1) {
				message "Player Died: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n";
				$players{$ID}{'dead'} = 1;
			} else {
				if ($type == 0) {
					debug "Player Disappeared: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg";
					$players{$ID}{'disappeared'} = 1;
				} elsif ($type == 2) {
					debug "Player Disconnected: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg";
					$players{$ID}{'disconnected'} = 1;
				} elsif ($type == 3) {
					debug "Player Teleported: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg";
					$players{$ID}{'teleported'} = 1;
				} else {
					debug "Player Disappeared in an unknown way: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg";
					$players{$ID}{'disappeared'} = 1;
				}

				%{$players_old{$ID}} = %{$players{$ID}};
				$players_old{$ID}{'gone_time'} = time;
				binRemove(\@playersID, $ID);
				undef %{$players{$ID}};
				delete $players{$ID};

				binRemove(\@venderListsID, $ID);
				undef %{$venderLists{$ID}};
				delete $venderLists{$ID};
			}

		} elsif (%{$players_old{$ID}}) {
			if ($type == 2) {
				debug "Player Disconnected: $players_old{$ID}{'name'}\n", "parseMsg";
				$players_old{$ID}{'disconnected'} = 1;
			} elsif ($type == 3) {
				debug "Player Teleported: $players_old{$ID}{'name'}\n", "parseMsg";
				$players_old{$ID}{'teleported'} = 1;
			}
		} elsif (%{$portals{$ID}}) {
			debug "Portal Disappeared: $portals{$ID}{'name'} ($portals{$ID}{'binID'})\n", "parseMsg";
			%{$portals_old{$ID}} = %{$portals{$ID}};
			$portals_old{$ID}{'disappeared'} = 1;
			$portals_old{$ID}{'gone_time'} = time;
			binRemove(\@portalsID, $ID);
			undef %{$portals{$ID}};
			delete $portals{$ID};
		} elsif (%{$npcs{$ID}}) {
			debug "NPC Disappeared: $npcs{$ID}{'name'} ($npcs{$ID}{'binID'})\n", "parseMsg";
			%{$npcs_old{$ID}} = %{$npcs{$ID}};
			$npcs_old{$ID}{'disappeared'} = 1;
			$npcs_old{$ID}{'gone_time'} = time;
			binRemove(\@npcsID, $ID);
			undef %{$npcs{$ID}};
			delete $npcs{$ID};
		} elsif (%{$pets{$ID}}) {
			debug "Pet Disappeared: $pets{$ID}{'name'} ($pets{$ID}{'binID'})\n", "parseMsg";
			binRemove(\@petsID, $ID);
			undef %{$pets{$ID}};
			delete $pets{$ID};
		} else {
			debug "Unknown Disappeared: ".getHex($ID)."\n", "parseMsg";
		}

	} elsif ($switch eq "0081") {
		$type = unpack("C1", substr($msg, 2, 1));
		$conState = 1;
		undef $conState_tries;

		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		Network::disconnect(\$remote_socket);

		if ($type == 2) {
			if ($config{'dcOnDualLogin'} == 1) {
				$interface->errorDialog("Critical Error: Dual login prohibited - Someone trying to login!\n\n" .
					"$Settings::NAME will now immediately disconnect.");
				$quit = 1;
			} elsif ($config{'dcOnDualLogin'} >= 2) {
				error("Critical Error: Dual login prohibited - Someone trying to login!\n", "connection");
				message "Disconnect for $config{'dcOnDualLogin'} seconds...\n", "connection";
				$timeout_ex{'master'}{'timeout'} = $config{'dcOnDualLogin'};
			} else {
				error("Critical Error: Dual login prohibited - Someone trying to login!\n", "connection");
			}

		} elsif ($type == 3) {
			error("Error: Out of sync with server\n", "connection");
		} elsif ($type == 6) {
			$interface->errorDialog("Critical Error: You must pay to play this account!");
			$quit = 1;
		} elsif ($type == 8) {
			error("Error: The server still recognizes your last connection\n", "connection");
		}

	} elsif ($switch eq "0087") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		makeCoords(\%coordsFrom, substr($msg, 6, 3));
		makeCoords2(\%coordsTo, substr($msg, 8, 3));
		%{$chars[$config{'char'}]{'pos'}} = %coordsFrom;
		%{$chars[$config{'char'}]{'pos_to'}} = %coordsTo;
		my $dist = sprintf("%.1f", distance(\%coordsFrom, \%coordsTo));
		debug "You move from ($coordsFrom{x}, $coordsFrom{y}) to ($coordsTo{x}, $coordsTo{y}) - distance $dist\n", "parseMsg";
		$chars[$config{'char'}]{'time_move'} = time;
		$chars[$config{'char'}]{'time_move_calc'} = distance(\%{$chars[$config{'char'}]{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}}) * $config{'seconds_per_block'};

	} elsif ($switch eq "0088") {
		# Long distance attack solution
		$ID = substr($msg, 2, 4);
		undef %coords;
		$coords{'x'} = unpack("S1", substr($msg, 6, 2));
		$coords{'y'} = unpack("S1", substr($msg, 8, 2));
		if ($ID eq $accountID) {
			%{$chars[$config{'char'}]{'pos'}} = %coords;
			%{$chars[$config{'char'}]{'pos_to'}} = %coords;
			debug "Movement interrupted, your coordinates: $chars[$config{'char'}]{'pos'}{'x'}, $chars[$config{'char'}]{'pos'}{'y'}\n", "parseMsg";
			aiRemove("move");
		} elsif (%{$monsters{$ID}}) {
			%{$monsters{$ID}{'pos'}} = %coords;
			%{$monsters{$ID}{'pos_to'}} = %coords;
		} elsif (%{$players{$ID}}) {
			%{$players{$ID}{'pos'}} = %coords;
			%{$players{$ID}{'pos_to'}} = %coords;
		}
		# End of Long Distance attack Solution

	} elsif ($switch eq "008A") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		my $ID1 = substr($msg, 2, 4);
		my $ID2 = substr($msg, 6, 4);
		my $standing = unpack("C1", substr($msg, 26, 2)) - 2;
		my $damage = unpack("S1", substr($msg, 22, 2));
		my $type = unpack("C1", substr($msg, 26, 1));

		if ($damage == 0) {
			$dmgdisplay = "Miss!";
			$dmgdisplay .= "!" if ($type == 11);
		} else {
			$dmgdisplay = $damage;
			$dmgdisplay .= "!" if ($type == 10);
		}

		updateDamageTables($ID1, $ID2, $damage);
		if ($ID1 eq $accountID) {
			if (%{$monsters{$ID2}}) { 
				message(sprintf("[%3d/%3d]", percent_hp(\%{$chars[$config{'char'}]}), percent_sp(\%{$chars[$config{'char'}]}))
					. " You attack $monsters{$ID2}{'name'} ($monsters{$ID2}{'binID'}) - Dmg: $dmgdisplay\n",
					($damage > 0) ? "attackMon" : "attackMonMiss");

				if ($startedattack) {
					$monstarttime = time();
					$monkilltime = time();
					$startedattack = 0;
				}
				calcStat($damage);
			} elsif (%{$items{$ID2}}) {
				debug "You pick up Item: $items{$ID2}{'name'} ($items{$ID2}{'binID'})\n", "parseMsg";
				$items{$ID2}{'takenBy'} = $accountID;
			} elsif ($ID2 == 0) {
				if ($standing) {
					$chars[$config{'char'}]{'sitting'} = 0;
					message "You're Standing\n";
				} else {
					$chars[$config{'char'}]{'sitting'} = 1;
					message "You're Sitting\n";
				}
			}
		} elsif ($ID2 eq $accountID) {
			if (%{$monsters{$ID1}}) {
				useTeleport(1) if ($monsters{$ID1}{'name'} eq "" && $config{'teleportAuto_emptyName'} ne '0');

				message(sprintf("[%3d/%3d]", percent_hp(\%{$chars[$config{'char'}]}), percent_sp(\%{$chars[$config{'char'}]}))
					. " Get Dmg : $monsters{$ID1}{'name'} $monsters{$ID1}{'nameID'} ($monsters{$ID1}{'binID'}) attacks You: $dmgdisplay\n",
					($damage > 0)? "attacked" : "attackedMiss");
			}
			undef $chars[$config{'char'}]{'time_cast'};
		} elsif (%{$monsters{$ID1}}) {
			if (%{$players{$ID2}}) {
				debug "Monster $monsters{$ID1}{'name'} ($monsters{$ID1}{'binID'}) attacks Player $players{$ID2}{'name'} ($players{$ID2}{'binID'}) - Dmg: $dmgdisplay\n", "parseMsg";
			}
			
		} elsif (%{$players{$ID1}}) {
			if (%{$monsters{$ID2}}) {
				debug "Player $players{$ID1}{'name'} ($players{$ID1}{'binID'}) attacks Monster $monsters{$ID2}{'name'} ($monsters{$ID2}{'binID'}) - Dmg: $dmgdisplay\n", "parseMsg";
			} elsif (%{$items{$ID2}}) {
				$items{$ID2}{'takenBy'} = $ID1;
				debug "Player $players{$ID1}{'name'} ($players{$ID1}{'binID'}) picks up Item $items{$ID2}{'name'} ($items{$ID2}{'binID'})\n", "parseMsg";
			} elsif ($ID2 == 0) {
				if ($standing) {
					$players{$ID1}{'sitting'} = 0;
					debug "Player is Standing: $players{$ID1}{'name'} ($players{$ID1}{'binID'})\n", "parseMsg";
				} else {
					$players{$ID1}{'sitting'} = 1;
					debug "Player is Sitting: $players{$ID1}{'name'} ($players{$ID1}{'binID'})\n", "parseMsg";
				}
			}
		} else {
			debug "Unknown ".getHex($ID1)." attacks ".getHex($ID2)." - Dmg: $dmgdisplay\n", "parseMsg";
		}

	} elsif ($switch eq "008D") {
		$ID = substr($msg, 4, 4);
		$chat = substr($msg, 8, $msg_size - 8);
		$chat =~ s/\000//g;
		($chatMsgUser, $chatMsg) = $chat =~ /([\s\S]*?) : ([\s\S]*)/;
		$chatMsgUser =~ s/ $//;

		chatLog("c", "$chat\n") if ($config{'logChat'});
		if ($config{'relay'}) {
			sendMessage(\$remote_socket, "pm", $chat, $config{'relay_user'});
		}
		message "$chat\n", "publicchat";

		my %item;
		$item{type} = "c";
		$item{ID} = $ID;
		$item{user} = $chatMsgUser;
		$item{msg} = $chatMsg;
		$item{time} = time;
		binAdd(\@ai_cmdQue, \%item);
		$ai_cmdQue++;


		# FIXME: the stuff below should be handled by the AI

		# Auto-emote
		$i = 0;
		while ($config{"autoEmote_word_$i"} ne "") {
			if ($chat =~/.*$config{"autoEmote_word_$i"}+$/i || $chat =~ /.*$config{"autoEmote_word_$i"}+\W/i) {
				my %args = ();
				$args{'timeout'} = time + rand (1) + 0.75;
				$args{'emotion'} = $config{"autoEmote_num_$i"};
				unshift @ai_seq, "sendEmotion";
				unshift @ai_seq_args, \%args;
				last;
			}
			$i++;
		}

		# Auto-response
		if ($config{"autoResponse"}) {
			$i = 0;
			while ($chat_resp{"words_said_$i"} ne "") {
				if (($chat =~/.*$chat_resp{"words_said_$i"}+$/i || $chat =~ /.*$chat_resp{"words_said_$i"}+\W/i) &&
				    binFind(\@ai_seq, "respAuto") eq "") {
					$args{'resp_num'} = $i;
					unshift @ai_seq, "respAuto";			
					unshift @ai_seq_args, \%args;
					$nextresptime = time + 5;
					last;
				}
				$i++;
			}
		}

		avoidGM_talk($chatMsgUser, $chatMsg);
		avoidList_talk($chatMsgUser, $chatMsg);

	} elsif ($switch eq "008E") {
		# Public messages that you sent yourself

		$chat = substr($msg, 4, $msg_size - 4);
		$chat =~ s/\000//g;
		($chatMsgUser, $chatMsg) = $chat =~ /([\s\S]*?) : ([\s\S]*)/;
		chatLog("c", $chat."\n") if ($config{'logChat'});
		if ($config{'relay'}) {
			sendMessage(\$remote_socket, "pm", $chat, $config{'relay_user'});
		}
		message "$chat\n", "selfchat";

		my %item;
		$item{type} = "c";
		$item{user} = $chatMsgUser;
		$item{msg} = $chatMsg;
		$item{time} = time;
		binAdd(\@ai_cmdQue, \%item);
		$ai_cmdQue++;

	} elsif ($switch eq "0091") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		initMapChangeVars();
		for ($i = 0; $i < @ai_seq; $i++) {
			ai_setMapChanged($i);
		}
		$ai_v{'portalTrace_mapChanged'} = 1;

		($map_name) = substr($msg, 2, 16) =~ /([\s\S]*?)\000/;
		($ai_v{'temp'}{'map'}) = $map_name =~ /([\s\S]*)\./;
		if ($ai_v{'temp'}{'map'} ne $field{'name'}) {
			getField("$Settings::def_field/$ai_v{'temp'}{'map'}.fld", \%field);
		}
		$coords{'x'} = unpack("S1", substr($msg, 18, 2));
		$coords{'y'} = unpack("S1", substr($msg, 20, 2));
		%{$chars[$config{'char'}]{'pos'}} = %coords;
		%{$chars[$config{'char'}]{'pos_to'}} = %coords;
		message "Map Change: $map_name\n", "connection";
		debug "Your Coordinates: $chars[$config{'char'}]{'pos'}{'x'}, $chars[$config{'char'}]{'pos'}{'y'}\n", "parseMsg";
		debug "Sending Map Loaded\n", "parseMsg";
		sendMapLoaded(\$remote_socket) if (!$config{'XKore'});

	} elsif ($switch eq "0092") {
		$conState = 4;
		initMapChangeVars() if ($config{'XKore'});
		undef $conState_tries;
		for (my $i = 0; $i < @ai_seq; $i++) {
			ai_setMapChanged($i);
		}
		$ai_v{'portalTrace_mapChanged'} = 1;

		($map_name) = substr($msg, 2, 16) =~ /([\s\S]*?)\000/;
		($ai_v{'temp'}{'map'}) = $map_name =~ /([\s\S]*)\./;
		if ($ai_v{'temp'}{'map'} ne $field{'name'}) {
			getField("$Settings::def_field/$ai_v{'temp'}{'map'}.fld", \%field);
		}

		$map_ip = makeIP(substr($msg, 22, 4));
		$map_port = unpack("S1", substr($msg, 26, 2));
		message(swrite(
			"---------Map Change Info----------", [],
			"MAP Name: @<<<<<<<<<<<<<<<<<<",
			[$map_name],
			"MAP IP: @<<<<<<<<<<<<<<<<<<",
			[$map_ip],
			"MAP Port: @<<<<<<<<<<<<<<<<<<",
			[$map_port],
			"-------------------------------", []),
			"connection");

		message("Closing connection to Map Server\n", "connection");
		Network::disconnect(\$remote_socket) if (!$config{'XKore'});

		# Reset item and skill times. The effect of items (like aspd potions)
		# and skills (like Twohand Quicken) disappears when we change map server.
		my $i = 0;
		while ($config{"useSelf_item_$i"}) {
			$ai_v{"useSelf_item_$i"."_time"} = 0;
			$i++;
		}
		$i = 0;
		while ($config{"useSelf_skill_$i"}) {
			$ai_v{"useSelf_skill_$i"."_time"} = 0;
			$i++;
		}
		undef %{$chars[$config{char}]{statuses}} if ($chars[$config{char}]{statuses});
		undef %{$chars[$config{char}]{ailments}} if ($chars[$config{char}]{ailments});
		undef %{$chars[$config{char}]{looks}} if ($chars[$config{char}]{looks});

	} elsif ($switch eq "0095") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$ID = substr($msg, 2, 4);
		if (%{$players{$ID}}) {
			($players{$ID}{'name'}) = substr($msg, 6, 24) =~ /([\s\S]*?)\000/;
			if ($config{'debug'} >= 2) {
				$binID = binFind(\@playersID, $ID);
				debug "Player Info: $players{$ID}{'name'} ($binID)\n", "parseMsg", 2;
			}
		}
		if (%{$monsters{$ID}}) {
			($monsters{$ID}{'name'}) = substr($msg, 6, 24) =~ /([\s\S]*?)\000/;
			if ($config{'debug'} >= 2) {
				$binID = binFind(\@monstersID, $ID);
				debug "Monster Info: $monsters{$ID}{'name'} ($binID)\n", "parseMsg", 2;
			}
			if ($monsters_lut{$monsters{$ID}{'nameID'}} eq "") {
				$monsters_lut{$monsters{$ID}{'nameID'}} = $monsters{$ID}{'name'};
				updateMonsterLUT("tables/monsters.txt", $monsters{$ID}{'nameID'}, $monsters{$ID}{'name'});
			}
		}
		if (%{$npcs{$ID}}) {
			($npcs{$ID}{'name'}) = substr($msg, 6, 24) =~ /([\s\S]*?)\000/; 
			if ($config{'debug'} >= 2) { 
				$binID = binFind(\@npcsID, $ID); 
				debug "NPC Info: $npcs{$ID}{'name'} ($binID)\n", "parseMsg", 2;
			} 
			if (!%{$npcs_lut{$npcs{$ID}{'nameID'}}}) { 
				$npcs_lut{$npcs{$ID}{'nameID'}}{'name'} = $npcs{$ID}{'name'};
				$npcs_lut{$npcs{$ID}{'nameID'}}{'map'} = $field{'name'};
				%{$npcs_lut{$npcs{$ID}{'nameID'}}{'pos'}} = %{$npcs{$ID}{'pos'}};
				updateNPCLUT("tables/npcs.txt", $npcs{$ID}{'nameID'}, $field{'name'}, $npcs{$ID}{'pos'}{'x'}, $npcs{$ID}{'pos'}{'y'}, $npcs{$ID}{'name'}); 
			}
		}
		if (%{$pets{$ID}}) {
			($pets{$ID}{'name_given'}) = substr($msg, 6, 24) =~ /([\s\S]*?)\000/;
			if ($config{'debug'} >= 2) {
				$binID = binFind(\@petsID, $ID);
				debug "Pet Info: $pets{$ID}{'name_given'} ($binID)\n", "parseMsg", 2;
			}
		}

	} elsif ($switch eq "0097") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		decrypt(\$newmsg, substr($msg, 28, length($msg)-28));
		$msg = substr($msg, 0, 28).$newmsg;
		($privMsgUser) = substr($msg, 4, 24) =~ /([\s\S]*?)\000/;
		$privMsg = substr($msg, 28, $msg_size - 29);
		if ($privMsgUser ne "" && binFind(\@privMsgUsers, $privMsgUser) eq "") {
			$privMsgUsers[@privMsgUsers] = $privMsgUser;
		}

		chatLog("pm", "(From: $privMsgUser) : $privMsg\n") if ($config{'logPrivateChat'});
		if ($config{'relay'}) {
			sendMessage(\$remote_socket, "pm", "(From: $privMsgUser) : $privMsg", $config{'relay_user'});
		}
		message "(From: $privMsgUser) : $privMsg\n", "pm";

		my %item;
		$item{type} = "pm";
		$item{user} = $privMsgUser;
		$item{msg} = $privMsg;
		$item{time} = time;
		binAdd(\@ai_cmdQue, \%item);
		$ai_cmdQue++;

		avoidGM_talk($privMsgUser, $privMsg);
		avoidList_talk($privMsgUser, $privMsg);

		Plugins::callHook('packet_privMsg', {
			privMsgUser => $privMsgUser,
			privMsg => $privMsg
			});

		# auto-response
		if ($config{"autoResponse"}) {
			$i = 0;
			while ($chat_resp{"words_said_$i"} ne "") {
				if (($privMsg =~/.*$chat_resp{"words_said_$i"}+$/i || $chat =~ /.*$chat_resp{"words_said_$i"}+\W/i) &&
				    binFind(\@ai_seq, "respPMAuto") eq "") {
					$args{'resp_num'} = $i;
					$args{'resp_user'} = $privMsgUser;
					unshift @ai_seq, "respPMAuto";
					unshift @ai_seq_args, \%args;
					$nextrespPMtime = time + 5;
					last;
				}
				$i++;
			}
		}

	} elsif ($switch eq "0098") {
		$type = unpack("C1",substr($msg, 2, 1));
		if ($type == 0) {
			message "(To $lastpm[0]{'user'}) : $lastpm[0]{'msg'}\n", "pm";
			chatLog("pm", "(To: $lastpm[0]{'user'}) : $lastpm[0]{'msg'}\n") if ($config{'logPrivateChat'});
		} elsif ($type == 1) {
			warning "$lastpm[0]{'user'} is not online\n";
		} elsif ($type == 2) {
			warning "Player can't hear you - you are ignored\n";
		}
		shift @lastpm;

	} elsif ($switch eq "009A") {
		$chat = substr($msg, 4, $msg_size - 4);
		$chat =~ s/\000$//;
		chatLog("s", $chat."\n") if ($config{'logSystemChat'});
		message "$chat\n", "gmchat";
		avoidGM_talk(undef, $chat);

	} elsif ($switch eq "009C") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$ID = substr($msg, 2, 4);
		$body = unpack("C1",substr($msg, 8, 1));
		$head = unpack("C1",substr($msg, 6, 1));
		if ($ID eq $accountID) {
			$chars[$config{'char'}]{'look'}{'head'} = $head;
			$chars[$config{'char'}]{'look'}{'body'} = $body;
			debug "You look at $chars[$config{'char'}]{'look'}{'body'}, $chars[$config{'char'}]{'look'}{'head'}\n", "parseMsg", 2;

		} elsif (%{$players{$ID}}) {
			$players{$ID}{'look'}{'head'} = $head;
			$players{$ID}{'look'}{'body'} = $body;
			debug "Player $players{$ID}{'name'} ($players{$ID}{'binID'}) looks at $players{$ID}{'look'}{'body'}, $players{$ID}{'look'}{'head'}\n", "parseMsg";

		} elsif (%{$monsters{$ID}}) {
			$monsters{$ID}{'look'}{'head'} = $head;
			$monsters{$ID}{'look'}{'body'} = $body;
			debug "Monster $monsters{$ID}{'name'} ($monsters{$ID}{'binID'}) looks at $monsters{$ID}{'look'}{'body'}, $monsters{$ID}{'look'}{'head'}\n", "parseMsg";
		}

	} elsif ($switch eq "009D") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$ID = substr($msg, 2, 4);
		$type = unpack("S1",substr($msg, 6, 2));
		$x = unpack("S1", substr($msg, 9, 2));
		$y = unpack("S1", substr($msg, 11, 2));
		$amount = unpack("S1", substr($msg, 13, 2));
		if (!%{$items{$ID}}) {
			binAdd(\@itemsID, $ID);
			$items{$ID}{'appear_time'} = time;
			$items{$ID}{'amount'} = $amount;
			$items{$ID}{'nameID'} = $type;
			$display = ($items_lut{$items{$ID}{'nameID'}} ne "") 
				? $items_lut{$items{$ID}{'nameID'}}
				: "Unknown ".$items{$ID}{'nameID'};
			$items{$ID}{'binID'} = binFind(\@itemsID, $ID);
			$items{$ID}{'name'} = $display;
		}
		$items{$ID}{'pos'}{'x'} = $x;
		$items{$ID}{'pos'}{'y'} = $y;
		message "Item Exists: $items{$ID}{'name'} ($items{$ID}{'binID'}) x $items{$ID}{'amount'}\n", "drop", 1;

	} elsif ($switch eq "009E") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$ID = substr($msg, 2, 4);
		$type = unpack("S1",substr($msg, 6, 2));
		$x = unpack("S1", substr($msg, 9, 2));
		$y = unpack("S1", substr($msg, 11, 2));
		$amount = unpack("S1", substr($msg, 15, 2));
		if (!%{$items{$ID}}) {
			binAdd(\@itemsID, $ID);
			$items{$ID}{'appear_time'} = time;
			$items{$ID}{'amount'} = $amount;
			$items{$ID}{'nameID'} = $type;
			$display = ($items_lut{$items{$ID}{'nameID'}} ne "") 
				? $items_lut{$items{$ID}{'nameID'}}
				: "Unknown ".$items{$ID}{'nameID'};
			$items{$ID}{'binID'} = binFind(\@itemsID, $ID);
			$items{$ID}{'name'} = $display;
		}
		$items{$ID}{'pos'}{'x'} = $x;
		$items{$ID}{'pos'}{'y'} = $y;
		message "Item Appeared: $items{$ID}{'name'} ($items{$ID}{'binID'}) x $items{$ID}{'amount'}\n", "drop", 1;

	} elsif ($switch eq "00A0") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$index = unpack("S1",substr($msg, 2, 2));
		$amount = unpack("S1",substr($msg, 4, 2));
		$ID = unpack("S1",substr($msg, 6, 2));
		$type = unpack("C1",substr($msg, 21, 1));
		$type_equip = unpack("C1",substr($msg, 19, 2));
		makeCoords(\%test, substr($msg, 8, 3));
		$fail = unpack("C1",substr($msg, 22, 1));

		my $invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
		if ($fail == 0) {
			if ($invIndex eq "" || $itemSlots_lut{$ID} != 0) {
				$invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "nameID", "");
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'index'} = $index;
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'} = $ID;
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} = $amount;
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'type'} = $type;
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'type_equip'} = $type_equip;
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'identified'} = unpack("C1",substr($msg, 8, 1));
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'enchant'} = unpack("C1",substr($msg, 10, 1));
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'elementID'} = unpack("S1",substr($msg, 12, 2));
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'elementName'} = $elements_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'elementID'}};
				undef @cnt;
				$count = 0;

				my $j;
				for ($j = 1 ; $j < 5; $j++) {
					if (unpack("S1", substr($msg, 9 + $j + $j, 2)) > 0) {
						$chars[$config{'char'}]{'inventory'}[$invIndex]{'slotID_$j'} = unpack("S1", substr($msg, 9 + $j + $j, 2));
						for (my $k = 0;$k < 4;$k++) {
							if (($chars[$config{'char'}]{'inventory'}[$invIndex]{'slotID_$j'} eq $cnt[$k]{'ID'}) && ($chars[$config{'char'}]{'inventory'}[$invIndex]{'slotID_$j'} ne "")) {
								$cnt[$k]{'amount'} += 1;
								last;
							} elsif ($chars[$config{'char'}]{'inventory'}[$invIndex]{'slotID_$j'} ne "") {
								$cnt[$k]{'amount'} = 1;
								$cnt[$k]{'name'} = $cards_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'slotID_$j'}};
								$cnt[$k]{'ID'} = $chars[$config{'char'}]{'inventory'}[$invIndex]{'slotID_$j'};
								$count++;
								last;
							}
						}
					}
				}
				$display = "";
				$count ++;
				for ($j = 0; $j < $count; $j++) {
					if ($j == 0 && $cnt[$j]{'amount'}) {
						if ($cnt[$j]{'amount'} > 1) {
							$display .= "$cnt[$j]{'amount'}X$cnt[$j]{'name'}";
                  				} else {
							$display .= "$cnt[$j]{'name'}"; 
						}
					} elsif ($cnt[$j]{'amount'}) {
						if ($cnt[$j]{'amount'} > 1) {
							$display .= ",$cnt[$j]{'amount'}X$cnt[$j]{'name'}";
						} else {
							$display .= ",$cnt[$j]{'name'}";
						}
					}
				}
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'slotName'} = $display;
				undef @cnt;
				undef $count;

			} else {
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} += $amount;
			}
			$display = ($items_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'}} ne "")
				? $items_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'}}
				: "Unknown ".$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'};
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} = $display;

			my $disp = "Item added to inventory: ";
			if ($chars[$config{'char'}]{'inventory'}[$invIndex]{'enchant'} > 0) {
				$disp .= "+$chars[$config{'char'}]{'inventory'}[$invIndex]{'enchant'} ";
			}
			$disp .= $display;
			if ($chars[$config{'char'}]{'inventory'}[$invIndex]{'elementName'} ne "") {
				$disp .= " [$chars[$config{'char'}]{'inventory'}[$invIndex]{'elementName'}]";
			}
			if ($chars[$config{'char'}]{'inventory'}[$invIndex]{'slotName'} ne "") {
				$disp .= " [$chars[$config{'char'}]{'inventory'}[$invIndex]{'slotName'}]";
			}
			$disp .= " ($invIndex) x $amount - $itemTypes_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'type'}}";
			message "$disp\n", "drop";
			($map_string) = $map_name =~ /([\s\S]*)\.gat/;
			$disp .= " ($map_string)\n";
			itemLog($disp);

		} elsif ($fail == 6) {
			message "Can't loot item...wait...\n", "drop";
		}

	} elsif ($switch eq "00A1") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$ID = substr($msg, 2, 4);
		if (%{$items{$ID}}) {
			debug "Item Disappeared: $items{$ID}{'name'} ($items{$ID}{'binID'})\n", "parseMsg";
			%{$items_old{$ID}} = %{$items{$ID}};
			$items_old{$ID}{'disappeared'} = 1;
			$items_old{$ID}{'gone_time'} = time;
			undef %{$items{$ID}};
			binRemove(\@itemsID, $ID);
		}

	} elsif ($switch eq "00A3" || $switch eq "01EE") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		decrypt(\$newmsg, substr($msg, 4, length($msg)-4));
		$msg = substr($msg, 0, 4).$newmsg;
		my $psize = ($switch eq "00A3") ? 10 : 18;
		undef $invIndex;

		for($i = 4; $i < $msg_size; $i += $psize) {
			$index = unpack("S1", substr($msg, $i, 2));
			$ID = unpack("S1", substr($msg, $i + 2, 2));
			$invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
			if ($invIndex eq "") {
				$invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "nameID", "");
			}
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'index'} = $index;
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'} = $ID;
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} = unpack("S1", substr($msg, $i + 6, 2));
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'type'} = unpack("C1", substr($msg, $i + 4, 1));
			$display = ($items_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'}} ne "")
				? $items_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'}}
				: "Unknown ".$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'};
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} = $display;
			debug "Inventory: $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} ($invIndex) x $chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} - $itemTypes_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'type'}}\n", "parseMsg";
		}

	} elsif ($switch eq "00A4") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		decrypt(\$newmsg, substr($msg, 4, length($msg)-4));
		$msg = substr($msg, 0, 4) . $newmsg;
		undef $invIndex;
		for (my $i = 4; $i < $msg_size; $i += 20) {
			$index = unpack("S1", substr($msg, $i, 2));
			$ID = unpack("S1", substr($msg, $i + 2, 2));
			$invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
			if ($invIndex eq "") {
				$invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "nameID", "");
			}

			$chars[$config{'char'}]{'inventory'}[$invIndex]{'index'} = $index;
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'} = $ID;
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} = 1;
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'type'} = unpack("C1", substr($msg, $i + 4, 1));
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'identified'} = unpack("C1", substr($msg, $i + 5, 1));
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'type_equip'} = $itemSlots_lut{$ID};
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'equipped'} = unpack("C1", substr($msg, $i + 8, 1));
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'enchant'} = unpack("C1", substr($msg, $i + 11, 1)); 

			if (unpack("C1", substr($msg, $i + 9, 1)) > 0) {
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'equipped'} = unpack("C1", substr($msg, $i + 9, 1));
			}
			$display = ($items_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'}} ne "")
				? $items_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'}}
				: "Unknown ".$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'};
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} = $display;
			undef @cnt;

			$count = 0;
			for (my $j = 1; $j < 5; $j++) {
				if (unpack("S1", substr($msg, $i + 10 + $j + $j, 2)) > 0) {
					$chars[$config{'char'}]{'inventory'}[$invIndex]{'slotID_$j'} = unpack("S1", substr($msg, $i + 10 + $j + $j, 2));
					for (my $k = 0; $k < 4; $k++) {
						if (($chars[$config{'char'}]{'inventory'}[$invIndex]{'slotID_$j'} eq $cnt[$k]{'ID'}) && ($chars[$config{'char'}]{'inventory'}[$invIndex]{'slotID_$j'} ne "")) {
							$cnt[$k]{'amount'} += 1;
							last;
						} elsif ($chars[$config{'char'}]{'inventory'}[$invIndex]{'slotID_$j'} ne "") {
							$cnt[$k]{'amount'} = 1;
							$cnt[$k]{'name'} = $cards_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'slotID_$j'}};
							$cnt[$k]{'ID'} = $chars[$config{'char'}]{'inventory'}[$invIndex]{'slotID_$j'};
							$count++;
							last;
						}
					}
				}
			}

			$display = ""; 
			$count ++;
			for (my $j = 0; $j < $count; $j++) {
				if ($j == 0 && $cnt[$j]{'amount'}) {
					if ($cnt[$j]{'amount'} > 1) {
						$display .= "$cnt[$j]{'amount'}X$cnt[$j]{'name'}";
					} else {
						$display .= "$cnt[$j]{'name'}";
					}
				} elsif ($cnt[$j]{'amount'}) {
					if($cnt[$j]{'amount'} > 1) {
						$display .= ",$cnt[$j]{'amount'}X$cnt[$j]{'name'}";
					} else {
						$display .= ",$cnt[$j]{'name'}";
					}
				}
			}
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'slotName'} = $display;
			undef @cnt;
			undef $count;
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'elementID'} = unpack("S1",substr($msg, $i + 13, 2));
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'elementName'} = $elements_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'elementID'}};

			$display = $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'};
			if ($chars[$config{'char'}]{'inventory'}[$invIndex]{'enchant'} > 0) {
				$display = "+$chars[$config{'char'}]{'inventory'}[$invIndex]{'enchant'} ".$display;
			}
			if ($chars[$config{'char'}]{'inventory'}[$invIndex]{'elementName'}) {
				$display .= " [$chars[$config{'char'}]{'inventory'}[$invIndex]{'elementName'}]";
			}
			if($chars[$config{'char'}]{'inventory'}[$invIndex]{'slotName'} ne "") {
				$display .= " [$chars[$config{'char'}]{'inventory'}[$invIndex]{'slotName'}]";
			}
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} = $display;

			debug "Inventory: +$chars[$config{'char'}]{'inventory'}[$invIndex]{'enchant'} $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} [$chars[$config{'char'}]{'inventory'}[$invIndex]{'slotName'}] [$chars[$config{'char'}]{'inventory'}[$invIndex]{'elementName'}] ($invIndex) x $chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} - $itemTypes_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'type'}} - $equipTypes_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'type_equip'}}\n", "parseMsg";
		}

	} elsif ($switch eq "00A5" || $switch eq "01F0") {
		# Retrieve list of stackable storage items
		my $newmsg;
		decrypt(\$newmsg, substr($msg, 4, length($msg)-4));
		$msg = substr($msg, 0, 4).$newmsg;
		undef %storage;
		undef @storageID;

		my $psize = ($switch eq "00A5") ? 10 : 18;
		for(my $i = 4; $i < $msg_size; $i += $psize) {
			my $index = unpack("C1", substr($msg, $i, 1));
			my $ID = unpack("S1", substr($msg, $i + 2, 2));
			binAdd(\@storageID, $index);
			$storage{$index}{'index'} = $index;
			$storage{$index}{'nameID'} = $ID;
			$storage{$index}{'amount'} = unpack("L1", substr($msg, $i + 6, 4));
			$display = ($items_lut{$ID} ne "")
				? $items_lut{$ID}
				: "Unknown $ID";
			$storage{$index}{'name'} = $display;
			$storage{$index}{'binID'} = binFind(\@storageID, $index);
			debug "Storage: $display ($storage{$index}{'binID'})\n", "parseMsg";
		}
		
		$ai_v{temp}{storage_opened} = 1;
		message "Storage Opened\n", "storage";
		
	} elsif ($switch eq "00A6") {
		# Retrieve list of non-stackable (weapons & armor) storage items.
		# This packet is sent immediately after 00A5/01F0.
		my $newmsg;
		decrypt(\$newmsg, substr($msg, 4, length($msg)-4));
		$msg = substr($msg, 0, 4).$newmsg;

		for (my $i = 4; $i < $msg_size; $i += 20) {
			my $index = unpack("C1", substr($msg, $i, 1));
			my $ID = unpack("S1", substr($msg, $i + 2, 2));

			binAdd(\@storageID, $index);
			$storage{$index}{'index'} = $index;
			$storage{$index}{'nameID'} = $ID;
			$storage{$index}{'amount'} = 1;
			$storage{$index}{'enchant'} = unpack("C1", substr($msg, $i + 11, 1));

			my @cnt;
			my $count = 0;

			for (my $j = 1; $j < 5; $j++) {
				if (unpack("S1", substr($msg, $i + $j + $j + 10, 2)) > 0) {
					$storage{$index}{'slotID_$j'} = unpack("S1", substr($msg, $i + $j + $j + 10, 2));
					for (my $k = 0; $k < 4; $k++) {
						if (($storage{$index}{'slotID_$j'} eq $cnt[$k]{'ID'}) && ($storage{$index}{'slotID_$j'} ne "")) {
							$cnt[$k]{'amount'} += 1;
							last;
						} elsif ($storage{$index}{'slotID_$j'} ne "") {
							$cnt[$k]{'amount'} = 1;
							$cnt[$k]{'name'} = $cards_lut{$storage{$index}{'slotID_$j'}};
							$cnt[$k]{'ID'} = $storage{$index}{'slotID_$j'};
							$count++;
							last;
						}
					}
				}
			}
			$count ++;

			my $display = "";
			for (my $j = 0; $j < $count; $j++) {
				if ($j == 0 && $cnt[$j]{'amount'}) {
					if ($cnt[$j]{'amount'} > 1) {
						$display .= "$cnt[$j]{'amount'}X$cnt[$j]{'name'}";
					} else {
						$display .= "$cnt[$j]{'name'}";
					}
				} elsif ($cnt[$j]{'amount'}) {
					if ($cnt[$j]{'amount'} > 1) {
						$display .= ",$cnt[$j]{'amount'}X$cnt[$j]{'name'}";
					} else {
						$display .= ",$cnt[$j]{'name'}"; 
					}
				}
			}
			$storage{$index}{'slotName'} = $display;

			$display = ($items_lut{$ID} ne "")
				? $items_lut{$ID}
				: "Unknown $ID";
			$storage{$index}{'name'} = $display;
			$storage{$index}{'binID'} = binFind(\@storageID, $index);
			debug "Storage: $storage{$index}{'name'} ($storage{$index}{'binID'})\n", "parseMsg";
		}
	} elsif ($switch eq "00A8") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		my $index = unpack("S1",substr($msg, 2, 2));
		my $amount = unpack("C1",substr($msg, 6, 1));
		my $invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
		$chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} -= $amount;
		message "You used Item: $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} ($invIndex) x $amount\n", "useItem";
		if ($chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} <= 0) {
			undef %{$chars[$config{'char'}]{'inventory'}[$invIndex]};
		}

	} elsif ($switch eq "00AA") {
		my $index = unpack("S1",substr($msg, 2, 2));
		my $type = unpack("S1",substr($msg, 4, 2));
		my $fail = unpack("C1",substr($msg, 6, 1));
		my $invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
		if ($fail == 0) {
			message "You can't put on $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} ($invIndex)\n";
		} else {
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'equipped'} = $chars[$config{'char'}]{'inventory'}[$invIndex]{'type_equip'};
			message "You equip $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} ($invIndex) - $equipTypes_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'type_equip'}}\n";
		}

	} elsif ($switch eq "00AC") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$index = unpack("S1",substr($msg, 2, 2));
		$type = unpack("S1",substr($msg, 4, 2));
		undef $invIndex;
		$invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
		$chars[$config{'char'}]{'inventory'}[$invIndex]{'equipped'} = "";
		message "You unequip $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} ($invIndex) - $equipTypes_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'type_equip'}}\n";

	} elsif ($switch eq "00AF") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$index = unpack("S1",substr($msg, 2, 2));
		$amount = unpack("S1",substr($msg, 4, 2));
		undef $invIndex;
		$invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
		if (!$chars[$config{'char'}]{'arrow'} || ($chars[$config{'char'}]{'arrow'} && !($chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} =~/arrow/i))) {
			message "Inventory Item Removed: $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} ($invIndex) x $amount\n", "inventory";
		}
		$chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} -= $amount;
		if ($chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} <= 0) {
			undef %{$chars[$config{'char'}]{'inventory'}[$invIndex]};
		}

	} elsif ($switch eq "00B0") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		my $type = unpack("S1",substr($msg, 2, 2));
		my $val = unpack("L1",substr($msg, 4, 4));
		if ($type == 0) {
			debug "Something1: $val\n", "parseMsg", 2;
		} elsif ($type == 3) {
			print "Something2: $val\n", "parseMsg", 2;
		} elsif ($type == 5) {
			$chars[$config{'char'}]{'hp'} = $val;
			debug "Hp: $val\n", "parseMsg", 2;
		} elsif ($type == 6) {
			$chars[$config{'char'}]{'hp_max'} = $val;
			debug "Max Hp: $val\n", "parseMsg", 2;
		} elsif ($type == 7) {
			$chars[$config{'char'}]{'sp'} = $val;
			debug "Sp: $val\n", "parseMsg", 2;
		} elsif ($type == 8) {
			$chars[$config{'char'}]{'sp_max'} = $val;
			debug "Max Sp: $val\n", "parseMsg", 2;
		} elsif ($type == 9) {
			$chars[$config{'char'}]{'points_free'} = $val;
			debug "Status Points: $val\n", "parseMsg", 2;
		} elsif ($type == 11) {
			$chars[$config{'char'}]{'lv'} = $val;
			debug "Level: $val\n", "parseMsg", 2;
		} elsif ($type == 12) {
			$chars[$config{'char'}]{'points_skill'} = $val;
			debug "Skill Points: $val\n", "parseMsg", 2;
		} elsif ($type == 24) {
			$chars[$config{'char'}]{'weight'} = int($val / 10);
			debug "Weight: $chars[$config{'char'}]{'weight'}\n", "parseMsg", 2;
		} elsif ($type == 25) {
			$chars[$config{'char'}]{'weight_max'} = int($val / 10);
			debug "Max Weight: $chars[$config{'char'}]{'weight_max'}\n", "parseMsg", 2;
		} elsif ($type == 41) {
			$chars[$config{'char'}]{'attack'} = $val;
			debug "Attack: $val\n", "parseMsg", 2;
		} elsif ($type == 42) {
			$chars[$config{'char'}]{'attack_bonus'} = $val;
			debug "Attack Bonus: $val\n", "parseMsg", 2;
		} elsif ($type == 43) {
			$chars[$config{'char'}]{'attack_magic_min'} = $val;
			debug "Magic Attack Min: $val\n", "parseMsg", 2;
		} elsif ($type == 44) {
			$chars[$config{'char'}]{'attack_magic_max'} = $val;
			debug "Magic Attack Max: $val\n", "parseMsg", 2;
		} elsif ($type == 45) {
			$chars[$config{'char'}]{'def'} = $val;
			debug "Defense: $val\n", "parseMsg", 2;
		} elsif ($type == 46) {
			$chars[$config{'char'}]{'def_bonus'} = $val;
			debug "Defense Bonus: $val\n", "parseMsg", 2;
		} elsif ($type == 47) {
			$chars[$config{'char'}]{'def_magic'} = $val;
			debug "Magic Defense: $val\n", "parseMsg", 2;
		} elsif ($type == 48) {
			$chars[$config{'char'}]{'def_magic_bonus'} = $val;
			debug "Magic Defense Bonus: $val\n", "parseMsg", 2;
		} elsif ($type == 49) {
			$chars[$config{'char'}]{'hit'} = $val;
			debug "Hit: $val\n", "parseMsg", 2;
		} elsif ($type == 50) {
			$chars[$config{'char'}]{'flee'} = $val;
			debug "Flee: $val\n", "parseMsg", 2;
		} elsif ($type == 51) {
			$chars[$config{'char'}]{'flee_bonus'} = $val;
			debug "Flee Bonus: $val\n", "parseMsg", 2;
		} elsif ($type == 52) {
			$chars[$config{'char'}]{'critical'} = $val;
			debug "Critical: $val\n", "parseMsg", 2;
		} elsif ($type == 53) { 
			$chars[$config{'char'}]{'attack_speed'} = 200 - $val/10; 
			debug "Attack Speed: $chars[$config{'char'}]{'attack_speed'}\n", "parseMsg", 2;
		} elsif ($type == 55) {
			$chars[$config{'char'}]{'lv_job'} = $val;
			debug "Job Level: $val\n", "parseMsg", 2;
		} elsif ($type == 124) {
			debug "Something3: $val\n", "parseMsg", 2;
		} else {
			debug "Something: $val\n", "parseMsg", 2;
		}

	} elsif ($switch eq "00B1") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$type = unpack("S1",substr($msg, 2, 2));
		$val = unpack("L1",substr($msg, 4, 4));
		if ($type == 1) {
			$chars[$config{'char'}]{'exp_last'} = $chars[$config{'char'}]{'exp'};
			$chars[$config{'char'}]{'exp'} = $val;
			debug "Exp: $val\n", "parseMsg";
			if (!$bExpSwitch) {
				$bExpSwitch = 1;
			} else {
				if ($chars[$config{'char'}]{'exp_last'} > $chars[$config{'char'}]{'exp'}) {
					$monsterBaseExp = 0;
				} else { 
					$monsterBaseExp = $chars[$config{'char'}]{'exp'} - $chars[$config{'char'}]{'exp_last'}; 
				} 
			$totalBaseExp += $monsterBaseExp; 
				if ($bExpSwitch == 1) { 
					$totalBaseExp += $monsterBaseExp; 
					$bExpSwitch = 2; 
				} 
			}
		} elsif ($type == 2) {
			$chars[$config{'char'}]{'exp_job_last'} = $chars[$config{'char'}]{'exp_job'};
			$chars[$config{'char'}]{'exp_job'} = $val;
			debug "Job Exp: $val\n", "parseMsg";
			if ($jExpSwitch == 0) { 
				$jExpSwitch = 1; 
			} else { 
				if ($chars[$config{'char'}]{'exp_job_last'} > $chars[$config{'char'}]{'exp_job'}) { 
					$monsterJobExp = 0; 
				} else { 
					$monsterJobExp = $chars[$config{'char'}]{'exp_job'} - $chars[$config{'char'}]{'exp_job_last'}; 
				} 
				$totalJobExp += $monsterJobExp; 
				if ($jExpSwitch == 1) { 
					$totalJobExp += $monsterJobExp; 
					$jExpSwitch = 2; 
				} 
			}
			message "Exp gained: $monsterBaseExp/$monsterJobExp\n","exp";
			
		} elsif ($type == 20) {
			$chars[$config{'char'}]{'zenny'} = $val;
			debug "Zenny: $val\n", "parseMsg";
		} elsif ($type == 22) {
			$chars[$config{'char'}]{'exp_max_last'} = $chars[$config{'char'}]{'exp_max'};
			$chars[$config{'char'}]{'exp_max'} = $val;
			debug "Required Exp: $val\n", "parseMsg";
		} elsif ($type == 23) {
			$chars[$config{'char'}]{'exp_job_max_last'} = $chars[$config{'char'}]{'exp_job_max'};
			$chars[$config{'char'}]{'exp_job_max'} = $val;
			debug "Required Job Exp: $val\n", "parseMsg";
			message("BaseExp:$monsterBaseExp | JobExp:$monsterJobExp\n","info", 2) if ($monsterBaseExp);
		}

	} elsif ($switch eq "00B3") {
		$conState = 2.5;
		undef $accountID;

	} elsif ($switch eq "00B4") {
		decrypt(\$newmsg, substr($msg, 8, length($msg)-8));
		$msg = substr($msg, 0, 8).$newmsg;
		$ID = substr($msg, 4, 4);
		($talk) = substr($msg, 8, $msg_size - 8) =~ /([\s\S]*?)\000/;
		$talk{'ID'} = $ID;
		$talk{'nameID'} = unpack("L1", $ID);
		$talk{'msg'} = $talk;
		message "$npcs{$ID}{'name'} : $talk{'msg'}\n", "npc";

	} elsif ($switch eq "00B5") {
		# 00b5: long ID
		# "Next" button appeared on the NPC message dialog
		my $ID = substr($msg, 2, 4);
		message "$npcs{$ID}{'name'} : Type 'talk cont' to continue talking\n", "npc";
		$ai_v{'npc_talk'}{'talk'} = 'next';
		$ai_v{'npc_talk'}{'time'} = time;

	} elsif ($switch eq "00B6") {
		# 00b6: long ID
		# "Close" icon appreared on the NPC message dialog
		my $ID = substr($msg, 2, 4);
		undef %talk;
		message "$npcs{$ID}{'name'} : Done talking\n", "npc";
		$ai_v{'npc_talk'}{'talk'} = 'close';
		$ai_v{'npc_talk'}{'time'} = time;

	} elsif ($switch eq "00B7") {
		# 00b7: word len, long ID, string str
		# A list of selections appeared on the NPC message dialog.
		# Each item is divided with ':'
		decrypt(\$newmsg, substr($msg, 8, length($msg)-8));
		$msg = substr($msg, 0, 8).$newmsg;
		$ID = substr($msg, 4, 4);
		($talk) = substr($msg, 8, $msg_size - 8) =~ /([\s\S]*?)\000/;
		$talk = substr($msg, 8) if (!defined $talk);
		@preTalkResponses = split /:/, $talk;
		undef @{$talk{'responses'}};
		foreach (@preTalkResponses) {
			push @{$talk{'responses'}}, $_ if $_ ne "";
		}
		$talk{'responses'}[@{$talk{'responses'}}] = "Cancel Chat";

		$ai_v{'npc_talk'}{'talk'} = 'select';
		$ai_v{'npc_talk'}{'time'} = time;

		message("----------Responses-----------\n", "list");
		message("#  Response\n", "list");
		for (my $i = 0; $i < @{$talk{'responses'}}; $i++) {
			message(swrite(
				"@< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<",
				[$i, $talk{'responses'}[$i]]),
				"list");
		}
		message("-------------------------------\n", "list");
		message("$npcs{$ID}{'name'} : Type 'talk resp #' to choose a response.\n", "npc");

	} elsif ($switch eq "00BC") {
		$type = unpack("S1",substr($msg, 2, 2));
		$val = unpack("C1",substr($msg, 5, 1));
		if ($val == 207) {
			error "Not enough stat points to add\n";
		} else {
			if ($type == 13) {
				$chars[$config{'char'}]{'str'} = $val;
				debug "Strength: $val\n", "parseMsg";
			} elsif ($type == 14) {
				$chars[$config{'char'}]{'agi'} = $val;
				debug "Agility: $val\n", "parseMsg";
			} elsif ($type == 15) {
				$chars[$config{'char'}]{'vit'} = $val;
				debug "Vitality: $val\n", "parseMsg";
			} elsif ($type == 16) {
				$chars[$config{'char'}]{'int'} = $val;
				debug "Intelligence: $val\n", "parseMsg";
			} elsif ($type == 17) {
				$chars[$config{'char'}]{'dex'} = $val;
				debug "Dexterity: $val\n", "parseMsg";
			} elsif ($type == 18) {
				$chars[$config{'char'}]{'luk'} = $val;
				debug "Luck: $val\n", "parseMsg";
			} else {
				debug "Something: $val\n", "parseMsg";
			}
		}


	} elsif ($switch eq "00BD") {
		$chars[$config{'char'}]{'points_free'} = unpack("S1", substr($msg, 2, 2));
		$chars[$config{'char'}]{'str'} = unpack("C1", substr($msg, 4, 1));
		$chars[$config{'char'}]{'points_str'} = unpack("C1", substr($msg, 5, 1));
		$chars[$config{'char'}]{'agi'} = unpack("C1", substr($msg, 6, 1));
		$chars[$config{'char'}]{'points_agi'} = unpack("C1", substr($msg, 7, 1));
		$chars[$config{'char'}]{'vit'} = unpack("C1", substr($msg, 8, 1));
		$chars[$config{'char'}]{'points_vit'} = unpack("C1", substr($msg, 9, 1));
		$chars[$config{'char'}]{'int'} = unpack("C1", substr($msg, 10, 1));
		$chars[$config{'char'}]{'points_int'} = unpack("C1", substr($msg, 11, 1));
		$chars[$config{'char'}]{'dex'} = unpack("C1", substr($msg, 12, 1));
		$chars[$config{'char'}]{'points_dex'} = unpack("C1", substr($msg, 13, 1));
		$chars[$config{'char'}]{'luk'} = unpack("C1", substr($msg, 14, 1));
		$chars[$config{'char'}]{'points_luk'} = unpack("C1", substr($msg, 15, 1));
		$chars[$config{'char'}]{'attack'} = unpack("S1", substr($msg, 16, 2));
		$chars[$config{'char'}]{'attack_bonus'} = unpack("S1", substr($msg, 18, 2));
		$chars[$config{'char'}]{'attack_magic_min'} = unpack("S1", substr($msg, 20, 2));
		$chars[$config{'char'}]{'attack_magic_max'} = unpack("S1", substr($msg, 22, 2));
		$chars[$config{'char'}]{'def'} = unpack("S1", substr($msg, 24, 2));
		$chars[$config{'char'}]{'def_bonus'} = unpack("S1", substr($msg, 26, 2));
		$chars[$config{'char'}]{'def_magic'} = unpack("S1", substr($msg, 28, 2));
		$chars[$config{'char'}]{'def_magic_bonus'} = unpack("S1", substr($msg, 30, 2));
		$chars[$config{'char'}]{'hit'} = unpack("S1", substr($msg, 32, 2));
		$chars[$config{'char'}]{'flee'} = unpack("S1", substr($msg, 34, 2));
		$chars[$config{'char'}]{'flee_bonus'} = unpack("S1", substr($msg, 36, 2));
		$chars[$config{'char'}]{'critical'} = unpack("S1", substr($msg, 38, 2));
		debug	"Strength: $chars[$config{'char'}]{'str'} #$chars[$config{'char'}]{'points_str'}\n"
			."Agility: $chars[$config{'char'}]{'agi'} #$chars[$config{'char'}]{'points_agi'}\n"
			."Vitality: $chars[$config{'char'}]{'vit'} #$chars[$config{'char'}]{'points_vit'}\n"
			."Intelligence: $chars[$config{'char'}]{'int'} #$chars[$config{'char'}]{'points_int'}\n"
			."Dexterity: $chars[$config{'char'}]{'dex'} #$chars[$config{'char'}]{'points_dex'}\n"
			."Luck: $chars[$config{'char'}]{'luk'} #$chars[$config{'char'}]{'points_luk'}\n"
			."Attack: $chars[$config{'char'}]{'attack'}\n"
			."Attack Bonus: $chars[$config{'char'}]{'attack_bonus'}\n"
			."Magic Attack Min: $chars[$config{'char'}]{'attack_magic_min'}\n"
			."Magic Attack Max: $chars[$config{'char'}]{'attack_magic_max'}\n"
			."Defense: $chars[$config{'char'}]{'def'}\n"
			."Defense Bonus: $chars[$config{'char'}]{'def_bonus'}\n"
			."Magic Defense: $chars[$config{'char'}]{'def_magic'}\n"
			."Magic Defense Bonus: $chars[$config{'char'}]{'def_magic_bonus'}\n"
			."Hit: $chars[$config{'char'}]{'hit'}\n"
			."Flee: $chars[$config{'char'}]{'flee'}\n"
			."Flee Bonus: $chars[$config{'char'}]{'flee_bonus'}\n"
			."Critical: $chars[$config{'char'}]{'critical'}\n"
			."Status Points: $chars[$config{'char'}]{'points_free'}\n", "parseMsg";

	} elsif ($switch eq "00BE") {
		$type = unpack("S1",substr($msg, 2, 2));
		$val = unpack("C1",substr($msg, 4, 1));
		if ($type == 32) {
			$chars[$config{'char'}]{'points_str'} = $val;
			debug "Points needed for Strength: $val\n", "parseMsg";
		} elsif ($type == 33) {
			$chars[$config{'char'}]{'points_agi'} = $val;
			debug "Points needed for Agility: $val\n", "parseMsg";
		} elsif ($type == 34) {
			$chars[$config{'char'}]{'points_vit'} = $val;
			debug "Points needed for Vitality: $val\n", "parseMsg";
		} elsif ($type == 35) {
			$chars[$config{'char'}]{'points_int'} = $val;
			debug "Points needed for Intelligence: $val\n", "parseMsg";
		} elsif ($type == 36) {
			$chars[$config{'char'}]{'points_dex'} = $val;
			debug "Points needed for Dexterity: $val\n", "parseMsg";
		} elsif ($type == 37) {
			$chars[$config{'char'}]{'points_luk'} = $val;
			debug "Points needed for Luck: $val\n", "parseMsg";
		}
		
	} elsif ($switch eq "00C0") {
		$ID = substr($msg, 2, 4);
		$type = unpack("C*", substr($msg, 6, 1));
		if ($ID eq $accountID) {
			message "$chars[$config{'char'}]{'name'} : $emotions_lut{$type}\n", "emotion";
			chatLog("e", "$chars[$config{'char'}]{'name'} : $emotions_lut{$type}\n") if (existsInList($config{'logEmoticons'}, $type) || $config{'logEmoticons'} eq "all");
		} elsif (%{$players{$ID}}) {
			message "$players{$ID}{'name'} : $emotions_lut{$type}\n", "emotion";
			chatLog("e", "$players{$ID}{'name'} : $emotions_lut{$type}\n") if (existsInList($config{'logEmoticons'}, $type) || $config{'logEmoticons'} eq "all");

			my $index = binFind(\@ai_seq, "follow");
			if ($index ne "") {
				my $masterID = $ai_seq_args[$index]{'ID'};
				if ($config{'followEmotion'} && $masterID eq $ID &&
			 	       distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$players{$masterID}{'pos_to'}}) <= $config{'followEmotion_distance'})
				{
					my %args = ();
					$args{'timeout'} = time + rand (1) + 0.75;

					if ($type == 30) {
						$args{'emotion'} = 31;
					} elsif ($type == 31) {
						$args{'emotion'} = 30;
					} else {
						$args{'emotion'} = $type;
					}

					unshift @ai_seq, "sendEmotion";
					unshift @ai_seq_args, \%args;
				}
			}
		}

	} elsif ($switch eq "00C2") {
		$users = unpack("L*", substr($msg, 2, 4));
		message "There are currently $users users online\n", "info";

	} elsif ($switch eq "00C4") {
		my $ID = substr($msg, 2, 4);
		undef %talk;
		$talk{'buyOrSell'} = 1;
		$talk{'ID'} = $ID;
		$ai_v{'npc_talk'}{'talk'} = 'buy';
		$ai_v{'npc_talk'}{'time'} = time;
		message "$npcs{$ID}{'name'} : Type 'store' to start buying, or type 'sell' to start selling\n", "npc";

	} elsif ($switch eq "00C6") {
		decrypt(\$newmsg, substr($msg, 4, length($msg)-4));
		$msg = substr($msg, 0, 4).$newmsg;
		undef @storeList;
		$storeList = 0;
		undef $talk{'buyOrSell'};
		for (my $i = 4; $i < $msg_size; $i += 11) {
			$price = unpack("L1", substr($msg, $i, 4));
			$type = unpack("C1", substr($msg, $i + 8, 1));
			$ID = unpack("S1", substr($msg, $i + 9, 2));
			$storeList[$storeList]{'nameID'} = $ID;
			$display = ($items_lut{$ID} ne "") 
				? $items_lut{$ID}
				: "Unknown ".$ID;
			$storeList[$storeList]{'name'} = $display;
			$storeList[$storeList]{'nameID'} = $ID;
			$storeList[$storeList]{'type'} = $type;
			$storeList[$storeList]{'price'} = $price;
			debug "Item added to Store: $storeList[$storeList]{'name'} - $price z\n", "parseMsg", 2;
			$storeList++;
		}
		message "$npcs{$talk{'ID'}}{'name'} : Check my store list by typing 'store'\n";
		
	} elsif ($switch eq "00C7") {
		#sell list, similar to buy list
		if (length($msg) > 4) {
			decrypt(\$newmsg, substr($msg, 4, length($msg)-4));
			$msg = substr($msg, 0, 4).$newmsg;
		}
		undef $talk{'buyOrSell'};
		message "Ready to start selling items\n";

	} elsif ($switch eq "00D1") {
		my $type = unpack("C1", substr($msg, 2, 1));
		my $error = unpack("C1", substr($msg, 3, 1));
		if ($type == 0) {
			message "Player ignored\n";
		} elsif ($type == 1) {
			if ($error == 0) {
				message "Player unignored\n";
			}
		}

	} elsif ($switch eq "00D2") {
		my $type = unpack("C1", substr($msg, 2, 1));
		my $error = unpack("C1", substr($msg, 3, 1));
		if ($type == 0) {
			message "All Players ignored\n";
		} elsif ($type == 1) {
			if ($error == 0) {
				message "All players unignored\n";
			}
		}

	} elsif ($switch eq "00D6") {
		$currentChatRoom = "new";
		%{$chatRooms{'new'}} = %createdChatRoom;
		binAdd(\@chatRoomsID, "new");
		binAdd(\@currentChatRoomUsers, $chars[$config{'char'}]{'name'});
		message "Chat Room Created\n";

	} elsif ($switch eq "00D7") {
		decrypt(\$newmsg, substr($msg, 17, length($msg)-17));
		$msg = substr($msg, 0, 17).$newmsg;
		$ID = substr($msg,8,4);
		if (!%{$chatRooms{$ID}}) {
			binAdd(\@chatRoomsID, $ID);
		}
		$chatRooms{$ID}{'title'} = substr($msg,17,$msg_size - 17);
		$chatRooms{$ID}{'ownerID'} = substr($msg,4,4);
		$chatRooms{$ID}{'limit'} = unpack("S1",substr($msg,12,2));
		$chatRooms{$ID}{'public'} = unpack("C1",substr($msg,16,1));
		$chatRooms{$ID}{'num_users'} = unpack("S1",substr($msg,14,2));
		
	} elsif ($switch eq "00D8") {
		$ID = substr($msg,2,4);
		binRemove(\@chatRoomsID, $ID);
		undef %{$chatRooms{$ID}};

	} elsif ($switch eq "00DA") {
		$type = unpack("C1",substr($msg, 2, 1));
		if ($type == 1) {
			message "Can't join Chat Room - Incorrect Password\n";
		} elsif ($type == 2) {
			message "Can't join Chat Room - You're banned\n";
		}

	} elsif ($switch eq "00DB") {
		decrypt(\$newmsg, substr($msg, 8, length($msg)-8));
		$msg = substr($msg, 0, 8).$newmsg;
		$ID = substr($msg,4,4);
		$currentChatRoom = $ID;
		$chatRooms{$currentChatRoom}{'num_users'} = 0;
		for ($i = 8; $i < $msg_size; $i+=28) {
			$type = unpack("C1",substr($msg,$i,1));
			($chatUser) = substr($msg,$i + 4,24) =~ /([\s\S]*?)\000/;
			if ($chatRooms{$currentChatRoom}{'users'}{$chatUser} eq "") {
				binAdd(\@currentChatRoomUsers, $chatUser);
				if ($type == 0) {
					$chatRooms{$currentChatRoom}{'users'}{$chatUser} = 2;
				} else {
					$chatRooms{$currentChatRoom}{'users'}{$chatUser} = 1;
				}
				$chatRooms{$currentChatRoom}{'num_users'}++;
			}
		}
		message qq~You have joined the Chat Room "$chatRooms{$currentChatRoom}{'title'}"\n~;

	} elsif ($switch eq "00DC") {
		if ($currentChatRoom ne "") {
			$num_users = unpack("S1", substr($msg,2,2));
			($joinedUser) = substr($msg,4,24) =~ /([\s\S]*?)\000/;
			binAdd(\@currentChatRoomUsers, $joinedUser);
			$chatRooms{$currentChatRoom}{'users'}{$joinedUser} = 1;
			$chatRooms{$currentChatRoom}{'num_users'} = $num_users;
			message "$joinedUser has joined the Chat Room\n";
		}
	
	} elsif ($switch eq "00DD") {
		$num_users = unpack("S1", substr($msg,2,2));
		($leaveUser) = substr($msg,4,24) =~ /([\s\S]*?)\000/;
		$chatRooms{$currentChatRoom}{'users'}{$leaveUser} = "";
		binRemove(\@currentChatRoomUsers, $leaveUser);
		$chatRooms{$currentChatRoom}{'num_users'} = $num_users;
		if ($leaveUser eq $chars[$config{'char'}]{'name'}) {
			binRemove(\@chatRoomsID, $currentChatRoom);
			undef %{$chatRooms{$currentChatRoom}};
			undef @currentChatRoomUsers;
			$currentChatRoom = "";
			message "You left the Chat Room\n";
		} else {
			message "$leaveUser has left the Chat Room\n";
		}

	} elsif ($switch eq "00DF") {
		decrypt(\$newmsg, substr($msg, 17, length($msg)-17));
		$msg = substr($msg, 0, 17).$newmsg;
		$ID = substr($msg,8,4);
		$ownerID = substr($msg,4,4);
		if ($ownerID eq $accountID) {
			$chatRooms{'new'}{'title'} = substr($msg,17,$msg_size - 17);
			$chatRooms{'new'}{'ownerID'} = $ownerID;
			$chatRooms{'new'}{'limit'} = unpack("S1",substr($msg,12,2));
			$chatRooms{'new'}{'public'} = unpack("C1",substr($msg,16,1));
			$chatRooms{'new'}{'num_users'} = unpack("S1",substr($msg,14,2));
		} else {
			$chatRooms{$ID}{'title'} = substr($msg,17,$msg_size - 17);
			$chatRooms{$ID}{'ownerID'} = $ownerID;
			$chatRooms{$ID}{'limit'} = unpack("S1",substr($msg,12,2));
			$chatRooms{$ID}{'public'} = unpack("C1",substr($msg,16,1));
			$chatRooms{$ID}{'num_users'} = unpack("S1",substr($msg,14,2));
		}
		message "Chat Room Properties Modified\n";
		
	} elsif ($switch eq "00E1") {
		$type = unpack("C1",substr($msg, 2, 1));
		($chatUser) = substr($msg, 6, 24) =~ /([\s\S]*?)\000/;
		if ($type == 0) {
			if ($chatUser eq $chars[$config{'char'}]{'name'}) {
				$chatRooms{$currentChatRoom}{'ownerID'} = $accountID;
			} else {
				$key = findKeyString(\%players, "name", $chatUser);
				$chatRooms{$currentChatRoom}{'ownerID'} = $key;
			}
			$chatRooms{$currentChatRoom}{'users'}{$chatUser} = 2;
		} else {
			$chatRooms{$currentChatRoom}{'users'}{$chatUser} = 1;
		}

	} elsif ($switch eq "00E5") {
		($dealUser) = substr($msg, 2, 24) =~ /([\s\S]*?)\000/;
		$incomingDeal{'name'} = $dealUser;
		$timeout{'ai_dealAutoCancel'}{'time'} = time;
		message "$dealUser Requests a Deal\n", "deal";
		message "Type 'deal' to start dealing, or 'deal no' to deny the deal.\n", "deal";

	} elsif ($switch eq "00E7") {
		$type = unpack("C1", substr($msg, 2, 1));
		
		if ($type == 3) {
			if (%incomingDeal) {
				$currentDeal{'name'} = $incomingDeal{'name'};
			} else {
				$currentDeal{'ID'} = $outgoingDeal{'ID'};
				$currentDeal{'name'} = $players{$outgoingDeal{'ID'}}{'name'};
			} 
			message "Engaged Deal with $currentDeal{'name'}\n", "deal";
		}
		undef %outgoingDeal;
		undef %incomingDeal;

	} elsif ($switch eq "00E9") {
		my $amount = unpack("L*", substr($msg, 2,4));
		my $ID = unpack("S*", substr($msg, 6,2));
		if ($ID > 0) {
			$currentDeal{'other'}{$ID}{'amount'} += $amount;
			$display = ($items_lut{$ID} ne "")
					? $items_lut{$ID}
					: "Unknown ".$ID;
			$currentDeal{'other'}{$ID}{'name'} = $display;
			message "$currentDeal{'name'} added Item to Deal: $currentDeal{'other'}{$ID}{'name'} x $amount\n", "deal";
		} elsif ($amount > 0) {
			$currentDeal{'other_zenny'} += $amount;
			$amount = formatNumber($amount);
			message "$currentDeal{'name'} added $amount z to Deal\n", "deal";
		}

	} elsif ($switch eq "00EA") {
		$index = unpack("S1", substr($msg, 2, 2));
		undef $invIndex;
		if ($index > 0) {
			$invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
			$currentDeal{'you'}{$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'}}{'amount'} += $currentDeal{'lastItemAmount'};
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} -= $currentDeal{'lastItemAmount'};
			message "You added Item to Deal: $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} x $currentDeal{'lastItemAmount'}\n", "deal";
			if ($chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} <= 0) {
				undef %{$chars[$config{'char'}]{'inventory'}[$invIndex]};
			}
		} elsif ($currentDeal{'lastItemAmount'} > 0) {
			$chars[$config{'char'}]{'zenny'} -= $currentDeal{'you_zenny'};
		}

	} elsif ($switch eq "00EC") {
		$type = unpack("C1", substr($msg, 2, 1));
		if ($type == 1) {
			$currentDeal{'other_finalize'} = 1;
			message "$currentDeal{'name'} finalized the Deal\n", "deal";


		} else {
			$currentDeal{'you_finalize'} = 1;
			message "You finalized the Deal\n", "deal";
		}

	} elsif ($switch eq "00EE") {
		undef %incomingDeal;
		undef %outgoingDeal;
		undef %currentDeal;
		message "Deal Cancelled\n", "deal";

	} elsif ($switch eq "00F0") {
		message "Deal Complete\n", "deal";
		undef %currentDeal;

	} elsif ($switch eq "00F2") {
		$storage{'items'} = unpack("S1", substr($msg, 2, 2));
		$storage{'items_max'} = unpack("S1", substr($msg, 4, 2));

	} elsif ($switch eq "00F4") {
		my $index = unpack("S1", substr($msg, 2, 2));
		my $amount = unpack("L1", substr($msg, 4, 4));
		my $ID = unpack("S1", substr($msg, 8, 2));
		if (%{$storage{$index}}) {
			$storage{$index}{'amount'} += $amount;
		} else {
			binAdd(\@storageID, $index);
			$storage{$index}{'index'} = $index;
			$storage{$index}{'amount'} = $amount;
			my $display = ($items_lut{$ID} ne "")
				? $items_lut{$ID}
				: "Unknown $ID";
			$storage{$index}{'name'} = $display;
			$storage{$index}{'binID'} = binFind(\@storageID, $index);
		}
		message("Storage Item Added: $storage{$index}{'name'} ($storage{$index}{'binID'}) x $amount\n", "storage", 1);

	} elsif ($switch eq "00F6") {
		$index = unpack("S1", substr($msg, 2, 2));
		$amount = unpack("L1", substr($msg, 4, 4));
		$storage{$index}{'amount'} -= $amount;
		message "Storage Item Removed: $storage{$index}{'name'} ($storage{$index}{'binID'}) x $amount\n", "storage";
		if ($storage{$index}{'amount'} <= 0) {
			undef %{$storage{$index}};
			delete $storage{$index};
			binRemove(\@storageID, $index);
		}

	} elsif ($switch eq "00F8") {
		message "Storage Closed\n", "storage";
		undef $ai_v{temp}{storage_opened}
		
	} elsif ($switch eq "00FA") {
		$type = unpack("C1", substr($msg, 2, 1));
		if ($type == 1) {
			warning "Can't organize party - party name exists\n";
		} 

	} elsif ($switch eq "00FB") {
		my $newmsg;
		decrypt(\$newmsg, substr($msg, 28, length($msg)-28));
		$msg = substr($msg, 0, 28).$newmsg;
		($chars[$config{'char'}]{'party'}{'name'}) = substr($msg, 4, 24) =~ /([\s\S]*?)\000/;
		for (my $i = 28; $i < $msg_size; $i += 46) {
			my $ID = substr($msg, $i, 4);
			my $num = unpack("C1",substr($msg, $i + 44, 1));
			if (binFind(\@partyUsersID, $ID) eq "") {
				binAdd(\@partyUsersID, $ID);
			}
			($chars[$config{'char'}]{'party'}{'users'}{$ID}{'name'}) = substr($msg, $i + 4, 24) =~ /([\s\S]*?)\000/;
			($chars[$config{'char'}]{'party'}{'users'}{$ID}{'map'}) = substr($msg, $i + 28, 16) =~ /([\s\S]*?)\000/;
			$chars[$config{'char'}]{'party'}{'users'}{$ID}{'online'} = !(unpack("C1",substr($msg, $i + 45, 1)));
			$chars[$config{'char'}]{'party'}{'users'}{$ID}{'admin'} = 1 if ($num == 0);
		}
		sendPartyShareEXP(\$remote_socket, 1) if ($config{'partyAutoShare'} && %{$chars[$config{'char'}]{'party'}});

	} elsif ($switch eq "00FD") {
		my ($name) = substr($msg, 2, 24) =~ /([\s\S]*?)\000/;
		my $type = unpack("C1", substr($msg, 26, 1));
		if ($type == 0) {
			warning "Join request failed: $name is already in a party\n";
		} elsif ($type == 1) {
			warning "Join request failed: $name denied request\n";
		} elsif ($type == 2) {
			message "$name accepted your request\n", "info";
		}

	} elsif ($switch eq "00FE") {
		my $ID = substr($msg, 2, 4);
		my ($name) = substr($msg, 6, 24) =~ /([\s\S]*?)\000/;
		message "Incoming Request to join party '$name'\n";
		$incomingParty{'ID'} = $ID;
		$timeout{'ai_partyAutoDeny'}{'time'} = time;

	} elsif ($switch eq "0101") {
		$type = unpack("C1", substr($msg, 2, 1));
		if ($type == 0) {
			message "Party EXP set to Individual Take\n";
		} elsif ($type == 1) {
			message "Party EXP set to Even Share\n";
		} else {
			error "Error setting party option\n";
		}
		
	} elsif ($switch eq "0104") {
		$ID = substr($msg, 2, 4);
		$x = unpack("S1", substr($msg,10, 2));
		$y = unpack("S1", substr($msg,12, 2));
		$type = unpack("C1",substr($msg, 14, 1));
		($name) = substr($msg, 15, 24) =~ /([\s\S]*?)\000/;
		($partyUser) = substr($msg, 39, 24) =~ /([\s\S]*?)\000/;
		($map) = substr($msg, 63, 16) =~ /([\s\S]*?)\000/;
		if (!%{$chars[$config{'char'}]{'party'}{'users'}{$ID}}) {
			binAdd(\@partyUsersID, $ID) if (binFind(\@partyUsersID, $ID) eq "");
			if ($ID eq $accountID) {
				message "You joined party '$name'\n", undef, 1;
			} else {
				message "$partyUser joined your party '$name'\n", undef, 1;
			}
		}
		if ($type == 0) {
			$chars[$config{'char'}]{'party'}{'users'}{$ID}{'online'} = 1;
		} elsif ($type == 1) {
			$chars[$config{'char'}]{'party'}{'users'}{$ID}{'online'} = 0;
		}
		$chars[$config{'char'}]{'party'}{'name'} = $name;
		$chars[$config{'char'}]{'party'}{'users'}{$ID}{'pos'}{'x'} = $x;
		$chars[$config{'char'}]{'party'}{'users'}{$ID}{'pos'}{'y'} = $y;
		$chars[$config{'char'}]{'party'}{'users'}{$ID}{'map'} = $map;
		$chars[$config{'char'}]{'party'}{'users'}{$ID}{'name'} = $partyUser;

	
	} elsif ($switch eq "0105") {
		my $ID = substr($msg, 2, 4);
		my ($name) = substr($msg, 6, 24) =~ /([\s\S]*?)\000/;
		undef %{$chars[$config{'char'}]{'party'}{'users'}{$ID}};
		binRemove(\@partyUsersID, $ID);
		if ($ID eq $accountID) {
			message "You left the party\n";
			undef %{$chars[$config{'char'}]{'party'}};
			$chars[$config{'char'}]{'party'} = "";
			undef @partyUsersID;
		} else {
			message "$name left the party\n";
		}

	} elsif ($switch eq "0106") {
		my $ID = substr($msg, 2, 4);
		$chars[$config{'char'}]{'party'}{'users'}{$ID}{'hp'} = unpack("S1", substr($msg, 6, 2));
		$chars[$config{'char'}]{'party'}{'users'}{$ID}{'hp_max'} = unpack("S1", substr($msg, 8, 2));

	} elsif ($switch eq "0107") {
		my $ID = substr($msg, 2, 4);
		my $x = unpack("S1", substr($msg,6, 2));
		my $y = unpack("S1", substr($msg,8, 2));
		$chars[$config{'char'}]{'party'}{'users'}{$ID}{'pos'}{'x'} = $x;
		$chars[$config{'char'}]{'party'}{'users'}{$ID}{'pos'}{'y'} = $y;
		$chars[$config{'char'}]{'party'}{'users'}{$ID}{'online'} = 1;
		debug "Party member location: $chars[$config{'char'}]{'party'}{'users'}{$ID}{'name'} - $x, $y\n", "parseMsg";

	} elsif ($switch eq "0108") {
		my $type =  unpack("S1",substr($msg, 2, 2));
		my $index = unpack("S1",substr($msg, 4, 2));
		my $enchant = unpack("S1",substr($msg, 6, 2));
		my $invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
		$chars[$config{'char'}]{'inventory'}[$invIndex]{'enchant'} = $enchant;

	} elsif ($switch eq "0109") {
		decrypt(\$newmsg, substr($msg, 8, length($msg)-8));
		$msg = substr($msg, 0, 8).$newmsg;
		$chat = substr($msg, 8, $msg_size - 8);
		$chat =~ s/\000$//;
		($chatMsgUser, $chatMsg) = $chat =~ /([\s\S]*?) : ([\s\S]*)\000/;
		chatLog("p", $chat."\n") if ($config{'logPartyChat'});
		message "%$chat\n", "partychat";

		my %item;
		$item{type} = "p";
		$item{user} = $chatMsgUser;
		$item{msg} = $catMsg;
		$item{time} = time;
		binAdd(\@ai_cmdQue, \%item);
		$ai_cmdQue++;

	# Hambo Started
	# 3 Packets About MVP
	} elsif ($switch eq "010A") {
		my $ID = unpack("S1", substr($msg, 2, 2));
		my $display = ($items_lut{$ID} ne "")
		? $items_lut{$ID}
		: "Unknown" . $ID;
		message "Get MVP item&#65306;$display\n";
		chatLog("k", "Get MVP item&#65306;$display\n");

	} elsif ($switch eq "010B") {
		my $expAmount = unpack("L1", substr($msg, 2, 4));
		message "Congradulations, you are the MVP! Your reward is $expAmount exp!\n";
		chatLog("k", "Congradulations, you are the MVP! Your reward is $expAmount exp!\n");

	} elsif ($switch eq "010C") {
		my $ID = substr($msg, 2, 4);
		my $display = "Unknown";
		if (%{$players{$ID}}) {
			$display = "Player ". $players{$ID}{'name'} . "(" . $players{$ID}{'binID'} . ") ";
		} elsif ($ID eq $accountID) {
			$display = "Your";
		}
		message "$displaybecome MVP!\n";
		chatLog("k", $display . "become MVP!\n");
	# Hambo Ended

	} elsif ($switch eq "010E") {
		$ID = unpack("S1",substr($msg, 2, 2));
		$lv = unpack("S1",substr($msg, 4, 2));
		$chars[$config{'char'}]{'skills'}{$skills_rlut{lc($skillsID_lut{$ID})}}{'lv'} = $lv;
		debug "Skill $skillsID_lut{$ID}: $lv\n", "parseMsg";

	} elsif ($switch eq "010F") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		decrypt(\$newmsg, substr($msg, 4, length($msg)-4));
		$msg = substr($msg, 0, 4).$newmsg;
		undef @skillsID;
		for($i = 4;$i < $msg_size;$i+=37) {
			$ID = unpack("S1", substr($msg, $i, 2));
			($name) = substr($msg, $i + 12, 24) =~ /([\s\S]*?)\000/;
			if (!$name) {
				$name = $skills_rlut{lc($skillsID_lut{$ID})};
			}
			$chars[$config{'char'}]{'skills'}{$name}{'ID'} = $ID;
			if (!$chars[$config{'char'}]{'skills'}{$name}{'lv'}) {
				$chars[$config{'char'}]{'skills'}{$name}{'lv'} = unpack("S1", substr($msg, $i + 6, 2));
			}
			$skillsID_lut{$ID} = $skills_lut{$name};
			binAdd(\@skillsID, $name);
		}

	} elsif ($switch eq "0110") {
		my $skillID = unpack("S1", substr($msg, 2, 2));
		error ("Skill $skillsID_lut{$skillID} has failed\n", "skill", 1);

	} elsif ($switch eq "0114" || $switch eq "01DE") {
		# Skill use
		my $skillID = unpack("S1", substr($msg, 2, 2));
		my $sourceID = substr($msg, 4, 4);
		my $targetID = substr($msg, 8, 4);
		my $damage = $switch eq "0114" ?
			unpack("S1", substr($msg, 24, 2)) :
			unpack("L1", substr($msg, 24, 4));
		my $level = ($switch eq "0114") ?
			unpack("S1", substr($msg, 26, 2)) :
		   	unpack("S1", substr($msg, 28, 2));
			
		my $level = unpack("S1", substr($msg, 28, 2));
		if (my $spell = $spells{$sourceID}) {
			# Resolve source of area attack skill
			$sourceID = $spell->{sourceID};
		}

		# Perform trigger actions
		$conState = 5 if $conState != 4 && $config{XKore};
		updateDamageTables($sourceID, $targetID, $damage) if $damage != 35536;
		setSkillUseTimer($skillID) if $sourceID eq $accountID;
		countCastOn($sourceID, $targetID);

		# Resolve source and target names
		my ($source, $uses, $target) = getActorNames($sourceID, $targetID);
		$damage ||= "Miss!";
		my $disp = "$source $uses $skillsID_lut{$skillID}" .
			(($level == 65535)? "" : " (lvl $level)") .
			(($damage == 35536)? "" : " on $target - Dmg: $damage") .
			"\n";

		my $domain;
		$domain = "skill" if (($source eq "You") || ($target eq "You"));

		if ($damage == 0) {
			$domain = "attackMonMiss" if (($source eq "You") && ($target ne "yourself"));
			$domain = "attackedMiss" if (($source ne "You") && ($target eq "You"));

		} elsif ($damage != 35536) {
			$domain = "attackMon" if (($source eq "You") && ($target ne "yourself"));
			$domain = "attacked" if (($source ne "You") && ($target eq "You"));
		}

		message $disp, $domain, 1;

		Plugins::callHook('packet_skilluse', {
			'skillID' => $skillID,
			'sourceID' => $sourceID,
			'targetID' => $targetID,
			'damage' => $damage,
			'amount' => 0,
			'x' => 0,
			'y' => 0
			});

	} elsif ($switch eq "0117") {
		# Skill used on coordinates
		my $skillID = unpack("S1", substr($msg, 2, 2));
		my $sourceID = substr($msg, 4, 4);
		my $lv = unpack("S1", substr($msg, 8, 2));
		my $x = unpack("S1", substr($msg, 10, 2));
		my $y = unpack("S1", substr($msg, 12, 2));
		
		# Perform trigger actions
		setSkillUseTimer($skillID) if $sourceID eq $accountID;

		# Resolve source name
		my ($source, $uses) = getActorNames($sourceID);

		# Print skill use message
		message "$source $uses $skillsID_lut{$skillID} on location ($x, $y)\n", "skill";

		Plugins::callHook('packet_skilluse', {
			'skillID' => $skillID,
			'sourceID' => $sourceID,
			'targetID' => '',
			'damage' => 0,
			'amount' => $lv,
			'x' => $x,
			'y' => $y
		});


	} elsif ($switch eq "0119") {
		# Character looks
		my $ID = substr($msg, 2, 4);
		my $param1 = unpack("S1", substr($msg, 6, 2));
		my $param2 = unpack("S1", substr($msg, 8, 2));
		my $param3 = unpack("S1", substr($msg, 10, 2));

		my $state = (defined($skillsState{$param1})) ? $skillsState{$param1} : "Unknown $param1";
		my $ailment = (defined($skillsAilments{$param2})) ? $skillsAilments{$param2} : "Unknown $param2";
		my $looks = (defined($skillsLooks{$param3})) ? $skillsLooks{$param3} : "Unknown $param3";
		if ($ID eq $accountID) {
			if ($param1) {
				$chars[$config{char}]{state}{$state} = 1;
				message "You have been $state.\n", "parseMsg_statuslook";
			} else {
				delete $chars[$config{char}]{state}{$state};
			}
			if ($param2 && $param2 != 32) {
				$chars[$config{char}]{ailments}{$ailment} = 1;
				message "You have been $ailment.\n", "parseMsg_statuslook";
			} else {
				delete $chars[$config{char}]{ailments}{$ailment};
			}
			if ($param3) {
				$chars[$config{char}]{looks}{$looks} = 1;
				debug "You have look: $looks\n", "parseMsg_statuslook";
			} else {
				delete $chars[$config{char}]{looks}{$looks};
			}

			# FIXME: move this to the AI
			if ($param2 == 0x0001) {
				# Poisoned; if you've got detoxify, use it
				if ($chars[$config{'char'}]{'skills'}{'TF_DETOXIFY'}{'lv'}) {
					ai_skillUse($chars[$config{'char'}]{'skills'}{'TF_DETOXIFY'}{'ID'}, 1, 0, 0, $accountID);
				} else {
					my $index = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"useSelf_item_CurePoison"});
					if ($index ne "") {
						message "Auto cure poison\n";
						sendItemUse(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$index]{'index'}, $accountID);
					}
				}
			}

		} elsif (%{$players{$ID}}) {
			if ($param1) {
				$players{$ID}{state}{$state} = 1;
				message "Player $players{$ID}{name} ($players{$ID}{binID}) has state: $state\n", "parseMsg_statuslook", 2;
			} else {
				delete $players{$ID}{state}{$state};
			}
			if ($param2 && $param2 != 32) {
				$players{$ID}{ailments}{$ailment} = 1;
				message "Player $players{$ID}{name} ($players{$ID}{binID}) affected: $ailment\n", "parseMsg_statuslook", 2;
			} else {
				delete $players{$ID}{ailments}{$ailment};
			}
			if ($param3) {
				$players{$ID}{looks}{$looks} = 1;
				debug "Player $players{$ID}{name} ($players{$ID}{binID}) has look: $looks\n", "parseMsg_statuslook";
			} else {
				delete $players{$ID}{looks}{$looks};
			}

		} elsif (%{$monsters{$ID}}) {
			if ($param1) {
				$monsters{$ID}{state}{$state} = 1;
				message "Monster $monsters{$ID}{name} ($monsters{$ID}{binID}) is affected by $state\n", "parseMsg_statuslook", 1;
			} else {
				delete $monsters{$ID}{state}{$state};
			}
			if ($param2 && $param2 != 32) {
				$monsters{$ID}{ailments}{$ailment} = 1;
				message "Monster $monsters{$ID}{name} ($monsters{$ID}{binID}) is affected by $ailment\n", "parseMsg_statuslook", 1;
			} else {
				delete $monsters{$ID}{ailments}{$ailment};
			}
			if ($param3) {
				$monsters{$ID}{looks}{$looks} = 1;
				debug "Monster $monsters{$ID}{name} ($monsters{$ID}{binID}) has look: $looks\n", "parseMsg_statuslook", 0;
			} else {
				delete $monsters{$ID}{looks}{$looks};
			}
		}

	} elsif ($switch eq "011A") {
		my $skillID = unpack("S1", substr($msg, 2, 2));
		my $targetID = substr($msg, 6, 4);
		my $sourceID = substr($msg, 10, 4);
		my $amount = unpack("S1", substr($msg, 4, 2));
		if (my $spell = $spells{$sourceID}) {
			# Resolve source of area attack skill
			$sourceID = $spell->{sourceID};
		}

		# Perform trigger actions
		$conState = 5 if $conState != 4 && $config{XKore};
		setSkillUseTimer($skillID) if $sourceID eq $accountID;
		countCastOn($sourceID, $targetID);
		if ($config{'autoResponseOnHeal'}) {
			# Handle auto-response on heal
			if ((%{$players{$sourceID}}) && (($skillID == 28) || ($skillID == 29) || ($skillID == 34))) {
				if ($targetID eq $accountID) {
					chatLog("k", "***$sourceDisplay $skillsID_lut{$skillID} on $targetDisplay$extra***\n");
					sendMessage(\$remote_socket, "pm", getResponse("skillgoodM"), $players{$sourceID}{'name'});
				} elsif ($monsters{$targetID}) {
					chatLog("k", "***$sourceDisplay $skillsID_lut{$skillID} on $targetDisplay$extra***\n");
					sendMessage(\$remote_socket, "pm", getResponse("skillbadM"), $players{$sourceID}{'name'});
				}
			}
		}

		# Resolve source and target names
		my ($source, $uses, $target) = getActorNames($sourceID, $targetID);

		# Print skill use message
		my $extra = "";
		if ($skillID == 28) {
			$extra = ": $amount hp gained";
		} elsif ($amount != 65535) {
			$extra = ": Lv $amount";
		}
  
		message "$source $uses $skillsID_lut{$skillID} on $target$extra\n", "skill";
		Plugins::callHook('packet_skilluse', {
			'skillID' => $skillID,
			'sourceID' => $sourceID,
			'targetID' => $targetID,
			'damage' => 0,
			'amount' => $amount,
			'x' => 0,
			'y' => 0
			});

	} elsif ($switch eq "011C") {
		# Warp portal list
		my $type = unpack("S1",substr($msg, 2, 2));

		my ($memo1) = substr($msg, 4, 16) =~ /([\s\S]*?)\000/;
		my ($memo2) = substr($msg, 20, 16) =~ /([\s\S]*?)\000/;
		my ($memo3) = substr($msg, 36, 16) =~ /([\s\S]*?)\000/;
		my ($memo4) = substr($msg, 52, 16) =~ /([\s\S]*?)\000/;

		($memo1) = $memo1 =~ /([\s\S]*)\.gat/;
		($memo2) = $memo2 =~ /([\s\S]*)\.gat/;
		($memo3) = $memo3 =~ /([\s\S]*)\.gat/;
		($memo4) = $memo4 =~ /([\s\S]*)\.gat/;

		$chars[$config{'char'}]{'warp'}{'type'} = $type;
		undef @{$chars[$config{'char'}]{'warp'}{'memo'}};
		push @{$chars[$config{'char'}]{'warp'}{'memo'}}, $memo1 if $memo1 ne "";
		push @{$chars[$config{'char'}]{'warp'}{'memo'}}, $memo2 if $memo2 ne "";
		push @{$chars[$config{'char'}]{'warp'}{'memo'}}, $memo3 if $memo3 ne "";
		push @{$chars[$config{'char'}]{'warp'}{'memo'}}, $memo4 if $memo4 ne "";

		message("----------------- Warp Portal --------------------\n", "list");
		message("#  Place                           Map\n", "list");
		for (my $i = 0; $i < @{$chars[$config{'char'}]{'warp'}{'memo'}}; $i++) {
			message(swrite(
				"@< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<<<<<",
				[$i, $maps_lut{$chars[$config{'char'}]{'warp'}{'memo'}[$i].'.rsw'},
				$chars[$config{'char'}]{'warp'}{'memo'}[$i]]),
				"list");
		}
		message("--------------------------------------------------\n", "list");

	} elsif ($switch eq "011E") {
		my $fail = unpack("C1", substr($msg, 2, 1));
		if ($fail) {
			warning "Memo Failed\n";
		} else {
			message "Memo Succeeded\n", "success";
		}

	} elsif ($switch eq "011F" || $switch eq "01C9") {
		# Area effect spell; including traps!
		my $ID = substr($msg, 2, 4);
		my $SourceID = substr($msg, 6, 4);
		my $x = unpack("S1",substr($msg, 10, 2));
		my $y = unpack("S1",substr($msg, 12, 2));

		$spells{$ID}{'sourceID'} = $SourceID;
		$spells{$ID}{'pos'}{'x'} = $x;
		$spells{$ID}{'pos'}{'y'} = $y;
		$binID = binAdd(\@spellsID, $ID);
		$spells{$ID}{'binID'} = $binID;

	} elsif ($switch eq "0120") {
		# The area effect spell with ID dissappears
		my $ID = substr($msg, 2, 4);
		undef %{$spells{$ID}};
		binRemove(\@spellsID, $ID);

	# Parses - chobit andy 20030102
	} elsif ($switch eq "0121") {
		$cart{'items'} = unpack("S1", substr($msg, 2, 2));
		$cart{'items_max'} = unpack("S1", substr($msg, 4, 2));
		$cart{'weight'} = int(unpack("L1", substr($msg, 6, 4)) / 10);
		$cart{'weight_max'} = int(unpack("L1", substr($msg, 10, 4)) / 10);

	} elsif ($switch eq "0122") {
		# "0122" sends non-stackable item info
		# "0123" sends stackable item info
		my $newmsg;
		decrypt(\$newmsg, substr($msg, 4, length($msg)-4));
		$msg = substr($msg, 0, 4).$newmsg;

		for (my $i = 4; $i < $msg_size; $i += 20) {
			my $index = unpack("S1", substr($msg, $i, 2));
			my $ID = unpack("S1", substr($msg, $i+2, 2));
			my $type = unpack("C1",substr($msg, $i+4, 1));
			my $display = ($items_lut{$ID} ne "") ? $items_lut{$ID} : "Unknown $ID";
			$cart{'inventory'}[$index]{'nameID'} = $ID;
			$cart{'inventory'}[$index]{'amount'} = 1;
			$cart{'inventory'}[$index]{'name'} = $display;
			$cart{'inventory'}[$index]{'identified'} = unpack("C1", substr($msg, $i+5, 1));
			$cart{'inventory'}[$index]{'type_equip'} = $itemSlots_lut{$ID};

			debug "Non-Stackable Cart Item: $cart{'inventory'}[$index]{'name'} ($index) x 1\n", "parseMsg";
		}

	} elsif ($switch eq "0123" || $switch eq "01EF") {
		my $newmsg;
		decrypt(\$newmsg, substr($msg, 4, length($msg)-4));
		$msg = substr($msg, 0, 4).$newmsg;
		my $psize = ($switch eq "0123") ? 10 : 18;

		for (my $i = 4; $i < $msg_size; $i += $psize) {
			my $index = unpack("S1", substr($msg, $i, 2));
			my $ID = unpack("S1", substr($msg, $i+2, 2));
			my $amount = unpack("S1", substr($msg, $i+6, 2));

			if (%{$cart{'inventory'}[$index]}) {
				$cart{'inventory'}[$index]{'amount'} += $amount;
			} else {
				$cart{'inventory'}[$index]{'nameID'} = $ID;
				$cart{'inventory'}[$index]{'amount'} = $amount;
				$display = ($items_lut{$ID} ne "") ? $items_lut{$ID} : "Unknown ".$ID;
				$cart{'inventory'}[$index]{'name'} = $display;
			}
			debug "Stackable Cart Item: $cart{'inventory'}[$index]{'name'} ($index) x $amount\n", "parseMsg";
		}

	} elsif ($switch eq "0124" || $switch eq "01C5") {
		my $index = unpack("S1", substr($msg, 2, 2));
		my $amount = unpack("L1", substr($msg, 4, 4));
		my $ID = unpack("S1", substr($msg, 8, 2));

		if (%{$cart{'inventory'}[$index]}) {
			$cart{'inventory'}[$index]{'amount'} += $amount;
		} else {
			$cart{'inventory'}[$index]{'nameID'} = $ID;
			$cart{'inventory'}[$index]{'amount'} = $amount;
			$display = (defined $items_lut{$ID}) ? $items_lut{$ID} : "Unknown $ID";
			$cart{'inventory'}[$index]{'name'} = $display;
			message "Cart Item Added: $display ($index) x $amount\n";
		}

	} elsif ($switch eq "0125") {
		my $index = unpack("S1", substr($msg, 2, 2));
		my $amount = unpack("L1", substr($msg, 4, 4));

		$cart{'inventory'}[$index]{'amount'} -= $amount;
		message "Cart Item Removed: $cart{'inventory'}[$index]{'name'} ($index) x $amount\n";
		if ($cart{'inventory'}[$index]{'amount'} <= 0) {
			undef %{$cart{'inventory'}[$index]};
		}

	} elsif ($switch eq "012C") {
		my $index = unpack("S1", substr($msg, 3, 2));
		my $amount = unpack("L1", substr($msg, 7, 2));
		my $ID = unpack("S1", substr($msg, 9, 2));
		if (defined $items_lut{$ID}) {
			message "Can't Add Cart Item: $items_lut{$ID}\n";
		}

	} elsif ($switch eq "012D") {
		# Used the shop skill.
		my $number = unpack("S1",substr($msg, 2, 2));
		message "You can sell $number items!\n";

	} elsif ($switch eq "0131") {
		my $ID = substr($msg,2,4);
		if (!%{$venderLists{$ID}}) {
			binAdd(\@venderListsID, $ID);
			Plugins::callHook('packet_vender', {ID => $ID});
		}
		($venderLists{$ID}{'title'}) = substr($msg,6,36) =~ /(.*?)\000/;
		$venderLists{$ID}{'id'} = $ID;

	} elsif ($switch eq "0132") {
		my $ID = substr($msg,2,4);
		binRemove(\@venderListsID, $ID);
		undef %{$venderLists{$ID}};

	} elsif ($switch eq "0133") {
			undef @venderItemList;
			undef $venderID;
			$venderID = substr($msg,4,4);
			$venderItemList = 0;

			message("----------Vender Store List-----------\n", "list");
			message("#  Name                                         Type           Amount Price\n", "list");
			for ($i = 8; $i < $msg_size; $i+=22) {
				$price = unpack("L1", substr($msg, $i, 4));
				$amount = unpack("S1", substr($msg, $i + 4, 2));
				$number = unpack("S1", substr($msg, $i + 6, 2));
				$type = unpack("C1", substr($msg, $i + 8, 1));
				$ID = unpack("S1", substr($msg, $i + 9, 2));
				$identified = unpack("C1", substr($msg, $i + 11, 1));
				$custom = unpack("C1", substr($msg, $i + 13, 1));
				$card1 = unpack("S1", substr($msg, $i + 14, 2));
				$card2 = unpack("S1", substr($msg, $i + 16, 2));
				$card3 = unpack("S1", substr($msg, $i + 18, 2));
				$card4 = unpack("S1", substr($msg, $i + 20, 2));

				$venderItemList[$number]{'nameID'} = $ID;
				$display = ($items_lut{$ID} ne "") 
					? $items_lut{$ID}
					: "Unknown ".$ID;
				if ($custom) {
					$display = "+$custom " . $display;
				}
				$venderItemList[$number]{'name'} = $display;
				$venderItemList[$number]{'amount'} = $amount;
				$venderItemList[$number]{'type'} = $type;
				$venderItemList[$number]{'identified'} = $identified;
				$venderItemList[$number]{'custom'} = $custom;
				$venderItemList[$number]{'card1'} = $card1;
				$venderItemList[$number]{'card2'} = $card2;
				$venderItemList[$number]{'card3'} = $card3;
				$venderItemList[$number]{'card4'} = $card4;
				$venderItemList[$number]{'price'} = $price;
				$venderItemList++;
				debug("Item added to Vender Store: $items{$ID}{'name'} - $price z\n", "vending", 2);

				$display = $venderItemList[$number]{'name'};
				if (!($venderItemList[$number]{'identified'})) {
					$display = $display."[NI]";
				}
				if ($venderItemList[$number]{'card1'}) {
					$display = $display."[".$cards_lut{$venderItemList[$number]{'card1'}}."]";
				}
				if ($venderItemList[$number]{'card2'}) {
					$display = $display."[".$cards_lut{$venderItemList[$number]{'card2'}}."]";
				}
				if ($venderItemList[$number]{'card3'}) {
					$display = $display."[".$cards_lut{$venderItemList[$number]{'card3'}}."]";
				}
				if ($venderItemList[$number]{'card4'}) {
					$display = $display."[".$cards_lut{$venderItemList[$number]{'card4'}}."]";
				}

				Plugins::callHook('packet_vender_store', {
					venderID => $venderID,
					number => $number,
					name => $display,
					amount => $amount,
					price => $price
				});

				message(swrite(
					"@< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<<< @>>>>> @>>>>>>>z",
					[$number, $display, $itemTypes_lut{$venderItemList[$number]{'type'}}, $venderItemList[$number]{'amount'}, $venderItemList[$number]{'price'}]),
					"list");
			}
			message("--------------------------------------\n", "list");

	} elsif ($switch eq "0136") {
		$msg_size = unpack("S1",substr($msg,2,2));

		#started a shop.
		undef @articles;
		$articles = 0;

		message("----------Items added to shop ------------------\n", "list");
		message("#  Name                                         Type        Amount     Price\n", "list");
		for (my $i = 8; $i < $msg_size; $i+=22) {
			$price = unpack("L1", substr($msg, $i, 4));
			$number = unpack("S1", substr($msg, $i + 4, 2));
			$amount = unpack("S1", substr($msg, $i + 6, 2));
			$type = unpack("C1", substr($msg, $i + 8, 1));
			$ID = unpack("S1", substr($msg, $i + 9, 2));
			$identified = unpack("C1", substr($msg, $i + 11, 1));
			$custom = unpack("C1", substr($msg, $i + 13, 1));
			$card1 = unpack("S1", substr($msg, $i + 14, 2));
			$card2 = unpack("S1", substr($msg, $i + 16, 2));
			$card3 = unpack("S1", substr($msg, $i + 18, 2));
			$card4 = unpack("S1", substr($msg, $i + 20, 2));

			$articles[$number]{'nameID'} = $ID;
			$display = ($items_lut{$ID} ne "") 
				? $items_lut{$ID}
				: "Unknown ".$ID;
			if ($custom) {
				$display = "+$custom " . $display;
			}
			$articles[$number]{'name'} = $display;
			$articles[$number]{'quantity'} = $amount;
			$articles[$number]{'type'} = $type;
			$articles[$number]{'identified'} = $identified;
			$articles[$number]{'custom'} = $custom;
			$articles[$number]{'card1'} = $card1;
			$articles[$number]{'card2'} = $card2;
			$articles[$number]{'card3'} = $card3;
			$articles[$number]{'card4'} = $card4;
			$articles[$number]{'price'} = $price;
			undef $articles[$number]{'sold'};
			$articles++;

			debug("Item added to Vender Store: $items{$ID}{'name'} - $price z\n", "vending", 2);
			$display = $articles[$number]{'name'};
			if (!($articles[$number]{'identified'})) {
				$display = $display."[NI]";
			}
			if ($articles[$number]{'card1'}) {
				$display = $display."[".$cards_lut{$articles[$number]{'card1'}}."]";
			}
			if ($articles[$number]{'card2'}) {
				$display = $display."[".$cards_lut{$articles[$number]{'card2'}}."]";
			}
			if ($articles[$number]{'card3'}) {
				$display = $display."[".$cards_lut{$articles[$number]{'card3'}}."]";
			}
			if ($articles[$number]{'card4'}) {
				$display = $display."[".$cards_lut{$articles[$number]{'card4'}}."]";
			}

			message(swrite(
				"@< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<< @>>>>> @>>>>>>>z",
				[$articles, $display, $itemTypes_lut{$articles[$number]{'type'}}, $articles[$number]{'quantity'}, $articles[$number]{'price'}]),
				"list");
		}
		message("-----------------------------------------\n", "list");
		$shopEarned = 0 if (!defined($shopEarned));

	} elsif ($switch eq "0137") {
		#sold something.
		$number = unpack("S1",substr($msg, 2, 2));
		$amount = unpack("S1",substr($msg, 4, 2));
		$articles[$number]{'sold'} += $amount;
		$shopEarned += $amount * $articles[$number]{'price'};
		$articles[$number]{'quantity'} -= $amount;
		message("sold: $amount $articles[$number]{'name'}.\n", "sold");
		if ($articles[$number]{'quantity'} < 1) {
			message("sold out: $articles[$number]{'name'}.\n", "sold");
			#$articles[$number] = "";
			if (!--$articles){
				message("sold all out.^^\n", "sold");
				sendCloseShop(\$remote_socket);
			}
		}

	} elsif ($switch eq "0139") {
		$ID = substr($msg, 2, 4);
		$type = unpack("C1",substr($msg, 14, 1));
		$coords1{'x'} = unpack("S1",substr($msg, 6, 2));
		$coords1{'y'} = unpack("S1",substr($msg, 8, 2));
		$coords2{'x'} = unpack("S1",substr($msg, 10, 2));
		$coords2{'y'} = unpack("S1",substr($msg, 12, 2));
		%{$monsters{$ID}{'pos_attack_info'}} = %coords1;
		%{$chars[$config{'char'}]{'pos'}} = %coords2;
		%{$chars[$config{'char'}]{'pos_to'}} = %coords2;
		debug "Recieved attack location - $monsters{$ID}{'pos_attack_info'}{'x'}, $monsters{$ID}{'pos_attack_info'}{'y'} - ".getHex($ID)."\n", "parseMsg", 2;

	} elsif ($switch eq "013A") {
		$type = unpack("S1",substr($msg, 2, 2));

	# Hambo Arrow Equip
	} elsif ($switch eq "013B") {
		$type = unpack("S1",substr($msg, 2, 2)); 
		if ($type == 0) { 
			$interface->errorDialog("Please equip arrow first.");
			undef $chars[$config{'char'}]{'arrow'};
			quit() if ($config{'dcOnEmptyArrow'});

		} elsif ($type == 3) {
			message "Arrow equipped\n" if ($config{'debug'}); 
		} 

	} elsif ($switch eq "013C") {
		$index = unpack("S1", substr($msg, 2, 2)); 
		$invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index); 
		if ($invIndex ne "") { 
			$chars[$config{'char'}]{'arrow'}=1 if (!defined($chars[$config{'char'}]{'arrow'}));
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'equipped'} = 32768; 
			message "Arrow equipped: $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} ($invIndex)\n";
		} 

	} elsif ($switch eq "013D") {
		$type = unpack("S1",substr($msg, 2, 2));
		$amount = unpack("S1",substr($msg, 4, 2));
		if ($type == 5) {
			$chars[$config{'char'}]{'hp'} += $amount;
			$chars[$config{'char'}]{'hp'} = $chars[$config{'char'}]{'hp_max'} if ($chars[$config{'char'}]{'hp'} > $chars[$config{'char'}]{'hp_max'});
		} elsif ($type == 7) {
			$chars[$config{'char'}]{'sp'} += $amount;
			$chars[$config{'char'}]{'sp'} = $chars[$config{'char'}]{'sp_max'} if ($chars[$config{'char'}]{'sp'} > $chars[$config{'char'}]{'sp_max'});
		}

	} elsif ($switch eq "013E") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$sourceID = substr($msg, 2, 4);
		$targetID = substr($msg, 6, 4);
		$x = unpack("S1",substr($msg, 10, 2));
		$y = unpack("S1",substr($msg, 12, 2));
		$skillID = unpack("S1",substr($msg, 14, 2));
		undef $sourceDisplay;
		undef $targetDisplay;
		if (%{$monsters{$sourceID}}) {
			$sourceDisplay = "$monsters{$sourceID}{'name'} ($monsters{$sourceID}{'binID'}) is casting";
		} elsif (%{$players{$sourceID}}) {
			$sourceDisplay = "$players{$sourceID}{'name'} ($players{$sourceID}{'binID'}) is casting";
		} elsif ($sourceID eq $accountID) {
			$sourceDisplay = "You are casting";
			$chars[$config{'char'}]{'time_cast'} = time;
		} else {
			$sourceDisplay = "Unknown is casting";
		}

		if (%{$monsters{$targetID}}) {
			$targetDisplay = "$monsters{$targetID}{'name'} ($monsters{$targetID}{'binID'})";
			if ($sourceID eq $accountID) {
				$monsters{$targetID}{'castOnByYou'}++;
			} elsif (%{$players{$sourceID}}) {
				$monsters{$targetID}{'castOnByPlayer'}{$sourceID}++;
			} elsif (%{$monsters{$sourceID}}) {
				$monsters{$targetID}{'castOnByMonster'}{$sourceID}++;
			}
		} elsif (%{$players{$targetID}}) {
			$targetDisplay = "$players{$targetID}{'name'} ($players{$targetID}{'binID'})";
		} elsif ($targetID eq $accountID) {
			if ($sourceID eq $accountID) {
				$targetDisplay = "yourself";
			} else {
				$targetDisplay = "you";
			}
		} elsif ($x != 0 || $y != 0) {
			$targetDisplay = "location ($x, $y)";
		} else {
			$targetDisplay = "unknown";
		}
		message "$sourceDisplay $skillsID_lut{$skillID} on $targetDisplay\n", "skill", 1;

	} elsif ($switch eq "0141") {
		$type = unpack("S1",substr($msg, 2, 2));
		$val = unpack("S1",substr($msg, 6, 2));
		$val2 = unpack("S1",substr($msg, 10, 2));
		if ($type == 13) {
			$chars[$config{'char'}]{'str'} = $val;
			$chars[$config{'char'}]{'str_bonus'} = $val2;
			debug "Strength: $val + $val2\n", "parseMsg";
		} elsif ($type == 14) {
			$chars[$config{'char'}]{'agi'} = $val;
			$chars[$config{'char'}]{'agi_bonus'} = $val2;
			debug "Agility: $val + $val2\n", "parseMsg";
		} elsif ($type == 15) {
			$chars[$config{'char'}]{'vit'} = $val;
			$chars[$config{'char'}]{'vit_bonus'} = $val2;
			debug "Vitality: $val + $val2\n", "parseMsg";
		} elsif ($type == 16) {
			$chars[$config{'char'}]{'int'} = $val;
			$chars[$config{'char'}]{'int_bonus'} = $val2;
			debug "Intelligence: $val + $val2\n", "parseMsg";
		} elsif ($type == 17) {
			$chars[$config{'char'}]{'dex'} = $val;
			$chars[$config{'char'}]{'dex_bonus'} = $val2;
			debug "Dexterity: $val + $val2\n", "parseMsg";
		} elsif ($type == 18) {
			$chars[$config{'char'}]{'luk'} = $val;
			$chars[$config{'char'}]{'luk_bonus'} = $val2;
			debug "Luck: $val + $val2\n", "parseMsg";
		}

	} elsif ($switch eq "0142") {
		$ID = substr($msg, 2, 4);
		message("$npcs{$ID}{'name'} : Type 'talk num <numer #>' to input a number.\n", "input");

	} elsif ($switch eq "0147") {
		my $skillID = unpack("S*",substr($msg, 2, 2));
		my $skillLv = unpack("S*",substr($msg, 8, 2)); 
      		message "Now use $skillsID_lut{$skillID}, level $skillLv\n";
      		sendSkillUse(\$remote_socket, $skillID, $skillLv, $accountID);

	} elsif ($switch eq "0148") {
		# 0148 long ID, word type
		my $targetID = substr($msg, 2, 4);
		my $type = unpack("S1",substr($msg, 6, 2));

		if ($type) {
			if ($targetID eq $accountID) {
				message("You have been resurrected\n", "info");
				undef $chars[$config{'char'}]{'dead'};
				undef $chars[$config{'char'}]{'dead_time'};
				$chars[$config{'char'}]{'resurrected'} = 1;

			} elsif (%{$players{$targetID}}) {
				undef $players{$targetID}{'dead'};
			}
		}

        } elsif ($switch eq "0154") {
        	my $newmsg;
		decrypt(\$newmsg, substr($msg, 4, length($msg) - 4));
		my $msg = substr($msg, 0, 4) . $newmsg;
		my $c = 0;
		for (my $i = 4; $i < $msg_size; $i+=104){
			$guild{'member'}[$c]{'ID'}    = substr($msg, $i, 4);
			$guild{'member'}[$c]{'jobID'} = unpack("S1", substr($msg, $i + 14, 2));
			$guild{'member'}[$c]{'lvl'}   = unpack("S1", substr($msg, $i + 16, 2));
			$guild{'member'}[$c]{'contribution'} = unpack("L1", substr($msg, $i + 18, 4));
			$guild{'member'}[$c]{'online'} = unpack("S1", substr($msg, $i + 22, 2));
			my $gtIndex = unpack("L1", substr($msg, $i + 26, 4));
			$guild{'member'}[$c]{'title'} = $guild{'title'}[$gtIndex];
			($guild{'member'}[$c]{'name'}) = substr($msg, $i + 80, 24) =~ /([\s\S]*?)\000/;
			$c++;
		}

	} elsif ($switch eq "0166") {
		my $newmsg;
		decrypt(\$newmsg, substr($msg, 4, length($msg) - 4));
		my $msg = substr($msg, 0, 4) . $newmsg;
		my $gtIndex;
		for (my $i = 4; $i < $msg_size; $i+=28) {
			$gtIndex = unpack("L1", substr($msg, $i, 4));
			($guild{'title'}[$gtIndex]) = substr($msg, $i + 4, 24) =~ /([\s\S]*?)\000/;
		}

	} elsif ($switch eq "016A") {
		# Guild request
		my $ID = substr($msg, 2, 4);
		my ($name) = substr($msg, 4, 24) =~ /([\s\S]*?)\000/;
		message "Incoming Request to join Guild '$name'\n";
		$incomingGuild{'ID'} = $ID;
		$incomingGuild{'Type'} = 1;
		$timeout{'ai_guildAutoDeny'}{'time'} = time;

	} elsif ($switch eq "016C") {
		($chars[$config{'char'}]{'guild'}{'name'}) = substr($msg, 19, 24) =~ /([\s\S]*?)\000/;
	
	} elsif ($switch eq "016D") {
		my $ID = substr($msg, 2, 4);
		my $TargetID =  substr($msg, 6, 4);
		my $type = unpack("L1", substr($msg, 10, 4));
		if ($type) {
			$isOnline = "Log In";
		} else {
			$isOnline = "Log Out";
		}
		sendGuildMemberNameRequest(\$remote_socket, $TargetID);

	} elsif ($switch eq "016F") {
		my ($address) = substr($msg, 2, 60) =~ /([\s\S]*?)\000/;
		my ($message) = substr($msg, 62, 120) =~ /([\s\S]*?)\000/;
		message	"---Guild Notice---\n"
			."$address\n\n"
			."$message\n"
			."------------------\n";

	} elsif ($switch eq "0171") {
		my $ID = substr($msg, 2, 4);
		my ($name) = substr($msg, 6, 24) =~ /[\s\S]*?\000/;
		message "Incoming Request to Ally Guild '$name'\n";
		$incomingGuild{'ID'} = $ID;
		$incomingGuild{'Type'} = 2;
		$timeout{'ai_guildAutoDeny'}{'time'} = time;

	} elsif ($switch eq "0177") {
		my $newmsg;
		decrypt(\$newmsg, substr($msg, 4, length($msg)-4));
		my $msg = substr($msg, 0, 4).$newmsg;
		undef @identifyID;
		undef $invIndex;
		for (my $i = 4; $i < $msg_size; $i += 2) {
			my $index = unpack("S1", substr($msg, $i, 2));
			my $invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
			binAdd(\@identifyID, $invIndex);
		}
		message "Recieved Possible Identify List - type 'identify'\n";

	} elsif ($switch eq "0179") {
		$index = unpack("S*",substr($msg, 2, 2));
		undef $invIndex;
		$invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
		$chars[$config{'char'}]{'inventory'}[$invIndex]{'identified'} = 1;
		$chars[$config{'char'}]{'inventory'}[$invIndex]{'type_equip'} = $itemSlots_lut{$chars[$config{'char'}]{'inventory'}[$invIndex]{'nameID'}};
		message "Item Identified: $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'}\n", "info";
		undef @identifyID;

	} elsif ($switch eq "017F") { 
		decrypt(\$newmsg, substr($msg, 4, length($msg)-4));
		$msg = substr($msg, 0, 4).$newmsg;
		$ID = substr($msg, 4, 4);
		$chat = substr($msg, 4, $msg_size - 4);
		$chat =~ s/\000$//;
		($chatMsgUser, $chatMsg) = $chat =~ /([\s\S]*?) : ([\s\S]*)\000/;
		chatLog("g", $chat."\n") if ($config{'logGuildChat'});
		message "[Guild] $chat\n", "guildchat";

		my %item;
		$item{type} = "g";
		$item{ID} = $ID;
		$item{user} = $chatMsgUser;
		$item{msg} = $chatMsg;
		$item{time} = time;
		binAdd(\@ai_cmdQue, \%item);
		$ai_cmdQue++;

	} elsif ($switch eq "0188") {
		$type =  unpack("S1",substr($msg, 2, 2));
		$index = unpack("S1",substr($msg, 4, 2));
		$enchant = unpack("S1",substr($msg, 6, 2));
		$invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
		$chars[$config{'char'}]{'inventory'}[$invIndex]{'enchant'} = $enchant;

	} elsif ($switch eq "0194") {
		my $ID = substr($msg, 2, 4);
		if ($characterID ne $ID) {
			my ($name) = substr($msg, 6, 24) =~ /([\s\S]*?)\000/;
			message "Guild Member $name $isOnline\n";
		}

	} elsif ($switch eq "0195") {
		my $ID = substr($msg, 2, 4);
		if (%{$players{$ID}}) {
			($players{$ID}{'name'}) = substr($msg, 6, 24) =~ /([\s\S]*?)\000/;
			($players{$ID}{'party'}{'name'}) = substr($msg, 30, 24) =~ /([\s\S]*?)\000/;
			($players{$ID}{'guild'}{'name'}) = substr($msg, 54, 24) =~ /([\s\S]*?)\000/;
			($players{$ID}{'guild'}{'men'}{$players{$ID}{'name'}}{'title'}) = substr($msg, 78, 24) =~ /([\s\S]*?)\000/;
			debug "Player Info: $players{$ID}{'name'} ($players{$ID}{'binID'})\n", "parseMsg", 2;
		}

	} elsif ($switch eq "0196") {
		# 0196 - type: word, ID: long, flag: bool
		# This packet tells you about character statuses (such as when blessing or poison is (de)activated)
                my $type = unpack("S1", substr($msg, 2, 2));
                my $ID = substr($msg, 4, 4);
                my $flag = unpack("C1", substr($msg, 8, 1));

                my $skillName = (defined($skillsStatus{$type})) ? $skillsStatus{$type} : "Unknown $type";

		if ($ID eq $accountID) {
			if ($flag) {
				# Skill activated
				$chars[$config{char}]{statuses}{$skillName} = 1;

			} else {
				# Skill de-activate (expired)
				delete $chars[$config{char}]{statuses}{$skillName};
				message "$skillName deactivated\n";
			}

		} elsif (%{$players{$ID}}) {
			if ($flag) {
				$players{$ID}{statuses}{$skillName} = 1;
				message "Player $players{$ID}{name} got status $skillName\n", "parseMsg_statuslook", 2;
			} else {
				delete $players{$ID}{statuses}{$skillName};
				message "Player $players{$ID}{name} lost status $skillName\n", "parseMsg_statuslook", 2;
			}

		} elsif (%{$monsters{$ID}}) {
			if ($flag) {
				$monsters{$ID}{statuses}{$skillName} = 1;
				message "Monster $monsters{$ID}{name} got status $skillName\n", "parseMsg_statuslook", 2;
			} else {
				delete $monsters{$ID}{statuses}{$skillName};
				message "Monster $monsters{$ID}{name} lost status $skillName\n", "parseMsg_statuslook", 2;
			}
		}

	} elsif ($switch eq "019B") {
		$ID = substr($msg, 2, 4);
		$type = unpack("L1",substr($msg, 6, 4));
		if (%{$players{$ID}}) {
			$name = $players{$ID}{'name'};
		} else {
			$name = "Unknown";
		}
		if ($type == 0) {
			message "Player $name gained a level!\n";
		} elsif ($type == 1) {
			message "Player $name gained a job level!\n";
		}

	} elsif ($switch eq "01A2") {
		#pet
		my ($name) = substr($msg, 2, 24) =~ /([\s\S]*?)\000/;
		$pets{$ID}{'name_given'} = 1;

	} elsif ($switch eq "01A4") {
		#pet spawn
		my $type = unpack("C1",substr($msg, 2, 1));
		my $ID = substr($msg, 3, 4);
		if (!%{$pets{$ID}}) {
			binAdd(\@petsID, $ID);
			%{$pets{$ID}} = %{$monsters{$ID}};
			$pets{$ID}{'name_given'} = "Unknown";
			$pets{$ID}{'binID'} = binFind(\@petsID, $ID);
		}
		if (%{$monsters{$ID}}) {
			binRemove(\@monstersID, $ID);
			undef %{$monsters{$ID}};
		}
		debug "Pet Spawned: $pets{$ID}{'name'} ($pets{$ID}{'binID'})\n", "parseMsg";
		#end of pet spawn code
		
	} elsif ($switch eq "01AA") {
		# pet

	} elsif ($switch eq "01B0") {
		# Class change
		# 01B0 : long ID, byte WhateverThisIs, long class
		my $ID = unpack("L", substr($msg, 2, 4));
		my $class = unpack("L", substr($msg, 7, 4));

	} elsif ($switch eq "01B3") {
		# NPC image 
		my $npc_image = substr($msg, 2,64); 
		($npc_image) = $npc_image =~ /(\S+)/; 
		debug "NPC image: $npc_image\n", "parseMsg";

	} elsif ($switch eq "01B6") {
		# Guild Info 
		$guild{'ID'}        = substr($msg, 2, 4);
		$guild{'lvl'}       = unpack("L1", substr($msg,  6, 4));
		$guild{'conMember'} = unpack("L1", substr($msg, 10, 4));
		$guild{'maxMember'} = unpack("L1", substr($msg, 14, 4));
		$guild{'average'}   = unpack("L1", substr($msg, 18, 4));
		$guild{'exp'}       = unpack("L1", substr($msg, 22, 4));
		$guild{'next_exp'}  = unpack("L1", substr($msg, 26, 4));
		$guild{'members'}   = unpack("L1", substr($msg, 42, 4)) + 1;
		($guild{'name'})    = substr($msg, 46, 24) =~ /([\s\S]*?)\000/;
		($guild{'master'})  = substr($msg, 70, 24) =~ /([\s\S]*?)\000/;

	} elsif ($switch eq "01C4") {
		my $index = unpack("S1", substr($msg, 2, 2));
		my $amount = unpack("L1", substr($msg, 4, 4));
		my $ID = unpack("S1", substr($msg, 8, 2));
		my $display = ($items_lut{$ID} ne "")
			? $items_lut{$ID}
			: "Unknown $ID";

		if (%{$storage{$index}}) {
			$storage{$index}{'amount'} += $amount;
		} else {
			binAdd(\@storageID, $index);
			$storage{$index}{'nameID'} = $ID;
			$storage{$index}{'index'} = $index;
			$storage{$index}{'amount'} = $amount;
			$storage{$index}{'name'} = $display;
			$storage{$index}{'binID'} = binFind(\@storageID, $index);
		}
		message("Storage Item Added: $display ($index) x $amount\n", "storage", 1);

	} elsif ($switch eq "01C8") {
		my $index = unpack("S1",substr($msg, 2, 2));
		my $ID = substr($msg, 6, 4);
		my $itemType = unpack("S1", substr($msg, 4, 2));
		my $amountleft = unpack("S1",substr($msg, 10, 2));
		my $itemDisplay = ($items_lut{$itemType} ne "") 
			? $items_lut{$itemType}
			: "Unknown " . unpack("L*", $ID);

		if ($ID eq $accountID) {
			my $invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "index", $index);
			my $amount = $chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} - $amountleft;
			$chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} -= $amount;

			message("You used Item: $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} ($invIndex) x $amount\n", "useItem", 1);
			if ($chars[$config{'char'}]{'inventory'}[$invIndex]{'amount'} <= 0) {
				undef %{$chars[$config{'char'}]{'inventory'}[$invIndex]};
			}

		} elsif (%{$players{$ID}}) {
			message("Player $players{$ID}{'name'} ($players{$ID}{'binID'}) used Item: $itemDisplay - $amountleft left\n", "useItem", 2);

		} elsif (%{$monsters{$ID}}) {
			message("Monster $monsters{$ID}{'name'} ($monsters{$ID}{'binID'}) used Item: $itemDisplay - $amountleft left\n", "useItem", 2);

		} else {
			message("Unknown " . unpack("L*", $ID) . " used Item: $itemDisplay - $amountleft left\n", "useItem", 2);

		}

	} elsif ($switch eq "01D7") {
		# Weapon Display (type - 2:hand eq, 9:foot eq)
		my $sourceID = substr($msg, 2, 4);
		my $type = unpack("C1",substr($msg, 6, 1));
		my $ID1 = unpack("S1", substr($msg, 7, 2));
		my $ID2 = unpack("S1", substr($msg, 9, 2));

	} elsif ($switch eq "01D8") {
		$ID = substr($msg, 2, 4);
		makeCoords(\%coords, substr($msg, 46, 3));
		$type = unpack("S*",substr($msg, 14,  2));
		$pet = unpack("C*",substr($msg, 16,  1));
		$sex = unpack("C*",substr($msg, 45,  1));
		$sitting = unpack("C*",substr($msg, 51,  1));
		if ($type >= 1000) {
			if ($pet) {
				if (!%{$pets{$ID}}) {
					$pets{$ID}{'appear_time'} = time;
					$display = ($monsters_lut{$type} ne "") 
							? $monsters_lut{$type}
							: "Unknown ".$type;
					binAdd(\@petsID, $ID);
					$pets{$ID}{'nameID'} = $type;
					$pets{$ID}{'name'} = $display;
					$pets{$ID}{'name_given'} = "Unknown";
					$pets{$ID}{'binID'} = binFind(\@petsID, $ID);
				}
				%{$pets{$ID}{'pos'}} = %coords;
				%{$pets{$ID}{'pos_to'}} = %coords;
				debug "Pet Exists: $pets{$ID}{'name'} ($pets{$ID}{'binID'})\n", "parseMsg";
			} else {
				if (!%{$monsters{$ID}}) {
					$monsters{$ID}{'appear_time'} = time;
					$display = ($monsters_lut{$type} ne "") 
							? $monsters_lut{$type}
							: "Unknown ".$type;
					binAdd(\@monstersID, $ID);
					$monsters{$ID}{'nameID'} = $type;
					$monsters{$ID}{'name'} = $display;
					$monsters{$ID}{'binID'} = binFind(\@monstersID, $ID);
				}
				%{$monsters{$ID}{'pos'}} = %coords;
				%{$monsters{$ID}{'pos_to'}} = %coords;
				debug "Monster Exists: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'})\n", "parseMsg", 1;
			}

		} elsif ($jobs_lut{$type}) {
			if (!%{$players{$ID}}) {
				$players{$ID}{'appear_time'} = time;
				binAdd(\@playersID, $ID);
				$players{$ID}{'jobID'} = $type;
				$players{$ID}{'sex'} = $sex;
				$players{$ID}{'name'} = "Unknown";
				$players{$ID}{'nameID'} = unpack("L1", $ID);
				$players{$ID}{'binID'} = binFind(\@playersID, $ID);
			}
			$players{$ID}{'sitting'} = $sitting > 0;
			%{$players{$ID}{'pos'}} = %coords;
			%{$players{$ID}{'pos_to'}} = %coords;
			debug "Player Exists: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg", 1;

		} elsif ($type == 45) {
			if (!%{$portals{$ID}}) {
				$portals{$ID}{'appear_time'} = time;
				$nameID = unpack("L1", $ID);
				$exists = portalExists($field{'name'}, \%coords);
				$display = ($exists ne "") 
					? "$portals_lut{$exists}{'source'}{'map'} -> " . getPortalDestName($exists)
					: "Unknown ".$nameID;
				binAdd(\@portalsID, $ID);
				$portals{$ID}{'source'}{'map'} = $field{'name'};
				$portals{$ID}{'type'} = $type;
				$portals{$ID}{'nameID'} = $nameID;
				$portals{$ID}{'name'} = $display;
				$portals{$ID}{'binID'} = binFind(\@portalsID, $ID);
			}
			%{$portals{$ID}{'pos'}} = %coords;
			message "Portal Exists: $portals{$ID}{'name'} - ($portals{$ID}{'binID'})\n", "portals", 1;

		} elsif ($type < 1000) {
			if (!%{$npcs{$ID}}) {
				$npcs{$ID}{'appear_time'} = time;
				$nameID = unpack("L1", $ID);
				$display = (%{$npcs_lut{$nameID}}) 
					? $npcs_lut{$nameID}{'name'}
					: "Unknown ".$nameID;
				binAdd(\@npcsID, $ID);
				$npcs{$ID}{'type'} = $type;
				$npcs{$ID}{'nameID'} = $nameID;
				$npcs{$ID}{'name'} = $display;
				$npcs{$ID}{'binID'} = binFind(\@npcsID, $ID);
			}
			%{$npcs{$ID}{'pos'}} = %coords;
			message "NPC Exists: $npcs{$ID}{'name'} (ID $npcs{$ID}{'nameID'}) - ($npcs{$ID}{'binID'})\n", undef, 1;

		} else {
			debug "Unknown Exists: $type - ".unpack("L*",$ID)."\n", "parseMsg";
		}
      		
	} elsif ($switch eq "01D9") {
		$ID = substr($msg, 2, 4);
		makeCoords(\%coords, substr($msg, 46, 3));
		$type = unpack("S*",substr($msg, 14,  2));
		$sex = unpack("C*",substr($msg, 45,  1));
		if ($jobs_lut{$type}) {
			if (!%{$players{$ID}}) {
				$players{$ID}{'appear_time'} = time;
				binAdd(\@playersID, $ID);
				$players{$ID}{'jobID'} = $type;
				$players{$ID}{'sex'} = $sex;
				$players{$ID}{'name'} = "Unknown";
				$players{$ID}{'nameID'} = unpack("L1", $ID);
				$players{$ID}{'binID'} = binFind(\@playersID, $ID);
			}
			%{$players{$ID}{'pos'}} = %coords;
			%{$players{$ID}{'pos_to'}} = %coords;
			debug "Player Connected: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg";

		} else {
			debug "Unknown Connected: $type - ".getHex($ID)."\n", "parseMsg";
		}

	} elsif ($switch eq "01DA") {
		$ID = substr($msg, 2, 4);
		makeCoords(\%coordsFrom, substr($msg, 50, 3));
		makeCoords2(\%coordsTo, substr($msg, 52, 3));
		$type = unpack("S*",substr($msg, 14,  2));
		$pet = unpack("C*",substr($msg, 16,  1));
		$sex = unpack("C*",substr($msg, 49,  1));
		if ($type >= 1000) {
			if ($pet) {
				if (!%{$pets{$ID}}) {
					$pets{$ID}{'appear_time'} = time;
					$display = ($monsters_lut{$type} ne "") 
							? $monsters_lut{$type}
							: "Unknown ".$type;
					binAdd(\@petsID, $ID);
					$pets{$ID}{'nameID'} = $type;
					$pets{$ID}{'name'} = $display;
					$pets{$ID}{'name_given'} = "Unknown";
					$pets{$ID}{'binID'} = binFind(\@petsID, $ID);
				}
				%{$pets{$ID}{'pos'}} = %coords;
				%{$pets{$ID}{'pos_to'}} = %coords;
				if (%{$monsters{$ID}}) {
					binRemove(\@monstersID, $ID);
					undef %{$monsters{$ID}};
				}
				debug "Pet Moved: $pets{$ID}{'name'} ($pets{$ID}{'binID'})\n", "parseMsg";
			} else {
				if (!%{$monsters{$ID}}) {
					binAdd(\@monstersID, $ID);
					$monsters{$ID}{'appear_time'} = time;
					$monsters{$ID}{'nameID'} = $type;
					$display = ($monsters_lut{$type} ne "") 
						? $monsters_lut{$type}
						: "Unknown ".$type;
					$monsters{$ID}{'nameID'} = $type;
					$monsters{$ID}{'name'} = $display;
					$monsters{$ID}{'binID'} = binFind(\@monstersID, $ID);
					debug "Monster Appeared: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'})\n", "parseMsg";
				}
				%{$monsters{$ID}{'pos'}} = %coordsFrom;
				%{$monsters{$ID}{'pos_to'}} = %coordsTo;
				debug "Monster Moved: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'})\n", "parseMsg";
			}
		} elsif ($jobs_lut{$type}) {
			if (!%{$players{$ID}}) {
				binAdd(\@playersID, $ID);
				$players{$ID}{'appear_time'} = time;
				$players{$ID}{'sex'} = $sex;
				$players{$ID}{'jobID'} = $type;
				$players{$ID}{'name'} = "Unknown";
				$players{$ID}{'nameID'} = unpack("L1", $ID);
				$players{$ID}{'binID'} = binFind(\@playersID, $ID);

				debug "Player Appeared: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$sex} $jobs_lut{$type}\n", "parseMsg";
			}
			%{$players{$ID}{'pos'}} = %coordsFrom;
			%{$players{$ID}{'pos_to'}} = %coordsTo;
			debug "Player Moved: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg", 2;
		} else {
			debug "Unknown Moved: $type - ".getHex($ID)."\n", "parseMsg";
		}

	} elsif ($switch eq "01DC") {
		$secureLoginKey = substr($msg, 4, $msg_size);

	} elsif ($switch eq "01F4") {
		# Recieving deal request
		# 01DC: 24byte nick, long charID, word level
		($dealUser) = substr($msg, 2, 24) =~ /([\s\S]*?)\000/;
		my $dealUserLevel = unpack("S1",substr($msg, 30, 2));
		$incomingDeal{'name'} = $dealUser;
		$timeout{'ai_dealAutoCancel'}{'time'} = time;
		message "$dealUser (level $dealUserLevel) Requests a Deal\n", "deal";
		message "Type 'deal' to start dealing, or 'deal no' to deny the deal.\n", "deal";

	} elsif ($switch eq "01F5") {
		# The deal you request has been accepted
		# 01F5: byte fail, long charID, word level
		my $type = unpack("C1", substr($msg, 2, 1));
		if ($type == 3) {
			if (%incomingDeal) {
				$currentDeal{'name'} = $incomingDeal{'name'};
			} else {
				$currentDeal{'ID'} = $outgoingDeal{'ID'};
				$currentDeal{'name'} = $players{$outgoingDeal{'ID'}}{'name'};
			}
			message "Engaged Deal with $currentDeal{'name'}\n", "deal";
		}
		undef %outgoingDeal;
		undef %incomingDeal;

	#} elsif ($switch eq "0187") {
		# 0187 - ID: long
		# Deal canceled
	#	undef %incomingDeal;
	#	undef %outgoingDeal;
	#	undef %currentDeal;
	#	message "Deal Cancelled\n", "deal";
	#}
	}

	$msg = (length($msg) >= $msg_size) ? substr($msg, $msg_size, length($msg) - $msg_size) : "";
	return $msg;
}




#######################################
#######################################
#AI FUNCTIONS
#######################################
#######################################

##
# ai_clientSuspend(type, initTimeout, args...)
# initTimeout: a number of seconds.
#
# Freeze the AI for $initTimeout seconds. $type and @args are only
# used internally and are ignored unless XKore mode is turned on.
sub ai_clientSuspend {
	my ($type,$initTimeout,@args) = @_;
	my %args;
	$args{'type'} = $type;
	$args{'time'} = time;
	$args{'timeout'} = $initTimeout;
	@{$args{'args'}} = @args;
	unshift @ai_seq, "clientSuspend";
	unshift @ai_seq_args, \%args;
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

	$seq{'items'} = \@{$r_items};
	$seq{'max'} = $max;
	$seq{'timeout'} = 1;
	unshift @ai_seq, "drop";
	unshift @ai_seq_args, \%seq;
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
	$master{id} = findPartyUserID($config{followTarget});
	if (($master{id} ne "") 
	 && $ai_seq[0] ne "dead"
	 && (binFind(\@ai_seq, "storageAuto") eq "")
	 && (binFind(\@ai_seq, "storageGet") eq "")
	 && (binFind(\@ai_seq, "sellAuto") eq "")
	 && (binFind(\@ai_seq, "buyAuto") eq "")) {

		$master{x} = $chars[$config{char}]{party}{users}{$master{id}}{pos}{x};
		$master{y} = $chars[$config{char}]{party}{users}{$master{id}}{pos}{y};
		($master{map}) = $chars[$config{char}]{party}{users}{$master{id}}{map} =~ /([\s\S]*)\.gat/;

		if ($master{map} ne $field{'name'}) {
			undef $master{x};
			undef $master{y};
		}			

		if (distance(\%master, \%{$ai_v{temp}{master}}) > 15 || $master{map} != $ai_v{temp}{master}{map}
		|| (timeOut($ai_v{temp}{time}, 15) && distance(\%master, $chars[$config{char}]{pos_to}) > $config{followDistanceMax})) {
			$ai_v{temp}{master}{x} = $master{x};
			$ai_v{temp}{master}{y} = $master{y};
			$ai_v{temp}{master}{map} = $master{map};
			$ai_v{temp}{time} = time; 

			if (defined($ai_v{temp}{master}{x}) && defined($ai_v{temp}{master}{y})) {
				message "Calculating route to find master: $maps_lut{$ai_v{temp}{master}{map}.'.rsw'} ($ai_v{temp}{master}{x},$ai_v{temp}{master}{y})\n", "follow";
			} elsif ($ai_v{temp}{master}{x} ne '0' && $ai_v{temp}{master}{y} ne '0') {
				message "Calculating route to find master: $maps_lut{$ai_v{temp}{master}{map}.'.rsw'}\n", "follow";
			} else {
				return;
			}

			aiRemove("move");
			aiRemove("route");
			aiRemove("mapRoute");
			ai_route($ai_v{temp}{master}{map}, $ai_v{temp}{master}{x}, $ai_v{temp}{master}{y}, distFromGoal => $config{'followDistanceMin'});
			
			my $followIndex;
			if (($followIndex = binFind(\@ai_seq, "follow")) ne "") {
				$ai_seq_args[$followIndex]{'ai_follow_lost_end'}{'timeout'} = $timeout{'ai_follow_lost_end'}{'timeout'};
			}
		}		
	}
}

sub ai_getAggressives {
	my @agMonsters;
	foreach (@monstersID) {
		next if ($_ eq "");
		if (($monsters{$_}{'dmgToYou'} > 0 || $monsters{$_}{'missedYou'} > 0) && $monsters{$_}{'attack_failed'} <= 1) {
			push @agMonsters, $_;
		}
	}
	return @agMonsters;
}

sub ai_getIDFromChat {
	my $r_hash = shift;
	my $msg_user = shift;
	my $match_text = shift;
	my $qm;
	if ($match_text !~ /\w+/ || $match_text eq "me") {
		foreach (keys %{$r_hash}) {
			next if ($_ eq "");
			if ($msg_user eq $$r_hash{$_}{'name'}) {
				return $_;
			}
		}
	} else {
		foreach (keys %{$r_hash}) {
			next if ($_ eq "");
			$qm = quotemeta $match_text;
			if ($$r_hash{$_}{'name'} =~ /$qm/i) {
				return $_;
			}
		}
	}
}

sub ai_getMonstersWhoHitMe {
	my @agMonsters;
	foreach (@monstersID) {
		next if ($_ eq "");
		if ($monsters{$_}{'dmgToYou'} > 0 && $monsters{$_}{'attack_failed'} <= 1) {
			push @agMonsters, $_;
		}
	}
	return @agMonsters;
}

##
# ai_getSkillUseType(name)
# name: the internal name of the skill (as found in skills.txt), such as WZ_FIREPILLAR.
# Returns: 1 if it's a location skill, 0 if it's an object skill.
#
# Determines whether a skill is a skill that's casted on a location, or one that's
# casted on an object (monster/player/etc).
# For example, Firewall is a location skill, while Cold Bolt is an object skill.
sub ai_getSkillUseType {
	my $skill = shift;
	if ($skill eq "WZ_FIREPILLAR" || $skill eq "WZ_METEOR" 
		|| $skill eq "WZ_VERMILION" || $skill eq "WZ_STORMGUST" 
		|| $skill eq "WZ_HEAVENDRIVE" || $skill eq "WZ_QUAGMIRE" 
		|| $skill eq "MG_SAFETYWALL" || $skill eq "MG_FIREWALL" 
		|| $skill eq "MG_THUNDERSTORM") { 
		return 1;
	} else {
		return 0;
	}

}

sub ai_mapRoute_searchStep {
	my $r_args = shift;

	unless (%{$$r_args{'openlist'}}) {
		$$r_args{'done'} = 1;
		$$r_args{'found'} = '';
		return 0;
	}

	my $parent = (sort {$$r_args{'openlist'}{$a}{'walk'} <=> $$r_args{'openlist'}{$b}{'walk'}} keys %{$$r_args{'openlist'}})[0];
	# use this if you want minimum MAP count otherwise, use the above for minimum step count
	foreach my $parent (keys %{$$r_args{'openlist'}})
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
					$arg{'walk'} = $$r_args{'closelist'}{$this}{'walk'};
					$arg{'zenny'} = $$r_args{'closelist'}{$this}{'zenny'};
					$arg{'steps'} = $portals_lut{$from}{'dest'}{$to}{'steps'};
					unshift @{$$r_args{'mapSolution'}},\%arg;
					$this = $$r_args{'closelist'}{$this}{'parent'};
				}
				return;
			} elsif ( ai_route_getRoute(\@{$$r_args{'solution'}}, \%{$$r_args{'dest'}{'field'}}, \%{$portals_lut{$portal}{'dest'}{$dest}{'pos'}}, \%{$$r_args{'dest'}{'pos'}}) ) {
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
				my $destID = $portals_lut{$child}{'dest'}{$subchild}{'ID'};
				#############################################################
				my $thisWalk = PORTAL_PENALTY + $$r_args{'closelist'}{$parent}{'walk'} + $portals_los{$dest}{$child};
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
	$args{'pos'}{'x'} = $x1;
	$args{'pos'}{'y'} = $y1;
	$args{'pos_to'}{'x'} = $x2;
	$args{'pos_to'}{'y'} = $y2;
	$args{'ai_items_take_end'}{'time'} = time;
	$args{'ai_items_take_end'}{'timeout'} = $timeout{'ai_items_take_end'}{'timeout'};
	$args{'ai_items_take_start'}{'time'} = time;
	$args{'ai_items_take_start'}{'timeout'} = $timeout{'ai_items_take_start'}{'timeout'};
	unshift @ai_seq, "items_take";
	unshift @ai_seq_args, \%args;
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
	$args{'param'} = [@_];
	$args{'time_start'} = time;

	if (!$param{'_internal'}) {
		undef @{$args{'solution'}};
		undef @{$args{'mapSolution'}};
	} elsif (exists $param{'_solution'}) {
		$args{'solution'} = $param{'_solution'};
	}

	# Destination is same map and isn't blocked by walls/water/whatever
	if ($param{'_internal'} || ($field{'name'} eq $args{'dest'}{'map'} && ai_route_getRoute(\@{$args{'solution'}}, \%field, $chars[$config{'char'}]{'pos_to'}, $args{'dest'}{'pos'}))) {
		# Since the solution array is here, we can start in "Route Solution Ready"
		$args{'stage'} = 'Route Solution Ready';
		debug "Route Solution Ready\n", "route";
		unshift @ai_seq, "route";
		unshift @ai_seq_args, \%args;
	} else {
		# Nothing is initialized so we start scratch
		unshift @ai_seq, "mapRoute";
		unshift @ai_seq_args, \%args;
	}
}

sub ai_route_getDiagSuccessors {
	my $r_args = shift;
	my $r_pos = shift;
	my $r_array = shift;
	my $type = shift;
	my %pos;

	if (ai_route_getMap($r_args, $$r_pos{'x'}-1, $$r_pos{'y'}-1) == $type
		&& !($$r_pos{'parent'} && $$r_pos{'parent'}{'x'} == $$r_pos{'x'}-1 && $$r_pos{'parent'}{'y'} == $$r_pos{'y'}-1)) {
		$pos{'x'} = $$r_pos{'x'}-1;
		$pos{'y'} = $$r_pos{'y'}-1;
		push @{$r_array}, {%pos};
	}

	if (ai_route_getMap($r_args, $$r_pos{'x'}+1, $$r_pos{'y'}-1) == $type
		&& !($$r_pos{'parent'} && $$r_pos{'parent'}{'x'} == $$r_pos{'x'}+1 && $$r_pos{'parent'}{'y'} == $$r_pos{'y'}-1)) {
		$pos{'x'} = $$r_pos{'x'}+1;
		$pos{'y'} = $$r_pos{'y'}-1;
		push @{$r_array}, {%pos};
	}	

	if (ai_route_getMap($r_args, $$r_pos{'x'}+1, $$r_pos{'y'}+1) == $type
		&& !($$r_pos{'parent'} && $$r_pos{'parent'}{'x'} == $$r_pos{'x'}+1 && $$r_pos{'parent'}{'y'} == $$r_pos{'y'}+1)) {
		$pos{'x'} = $$r_pos{'x'}+1;
		$pos{'y'} = $$r_pos{'y'}+1;
		push @{$r_array}, {%pos};
	}	

		
	if (ai_route_getMap($r_args, $$r_pos{'x'}-1, $$r_pos{'y'}+1) == $type
		&& !($$r_pos{'parent'} && $$r_pos{'parent'}{'x'} == $$r_pos{'x'}-1 && $$r_pos{'parent'}{'y'} == $$r_pos{'y'}+1)) {
		$pos{'x'} = $$r_pos{'x'}-1;
		$pos{'y'} = $$r_pos{'y'}+1;
		push @{$r_array}, {%pos};
	}	
}

sub ai_route_getMap {
	my $r_args = shift;
	my $x = shift;
	my $y = shift;
	if($x < 0 || $x >= $$r_args{'field'}{'width'} || $y < 0 || $y >= $$r_args{'field'}{'height'}) {
		return 1;	 
	}
	return $$r_args{'field'}{'field'}[($y*$$r_args{'field'}{'width'})+$x];
}


sub ai_route_getRoute {
	my %args;
	my ($returnArray, $r_field, $r_start, $r_dest) = @_;
	$args{'returnArray'} = $returnArray;
	undef @{$args{'returnArray'}};
	$args{'field'} = $r_field;
	%{$args{'start'}} = %{$r_start};
	%{$args{'dest'}} = %{$r_dest};

	return 1 if $args{'dest'}{'x'} eq '' || $args{'dest'}{'y'} eq '';

	foreach my $z ( [0,0], [0,1],[1,0],[0,-1],[-1,0], [-1,1],[1,1],[1,-1],[-1,-1] ) {
		next if $args{'field'}{'field'}[$args{'start'}{'x'}+$$z[0] + $args{'field'}{'width'}*($args{'start'}{'y'}+$$z[1])];
		$args{'start'}{'x'} += $$z[0];
		$args{'start'}{'y'} += $$z[1];
		last;
	}
	foreach my $z ( [0,0], [0,1],[1,0],[0,-1],[-1,0], [-1,1],[1,1],[1,-1],[-1,-1] ) {
		next if $args{'field'}{'field'}[$args{'dest'}{'x'}+$$z[0] + $args{'field'}{'width'}*($args{'dest'}{'y'}+$$z[1])];
		$args{'dest'}{'x'} += $$z[0];
		$args{'dest'}{'y'} += $$z[1];
		last;
	}

	my $SOLUTION_MAX = 5000;
	$args{'solution'} = "\0" x ($SOLUTION_MAX*4+4);
	my $weights = join '', map chr $_, (255, 8, 7, 6, 5, 4, 3, 2, 1);
	$weights .= chr(1) x (256 - length($weights));

	if (!$buildType) {
		$args{'session'} = $CalcPath_init->Call(
			$args{'solution'},
			$args{'field'}{'dstMap'},
			$weights,
			$args{'field'}{'width'},
			$args{'field'}{'height'}, 
			pack("S*",$args{'start'}{'x'}, $args{'start'}{'y'}),
			pack("S*",$args{'dest'}{'x'} , $args{'dest'}{'y'} ),
			2000);
	} elsif ($buildType == 1) {
		$args{'session'} = Tools::CalcPath_init(
			$args{'solution'},
			$args{'field'}{'dstMap'},
			$weights,
			$args{'field'}{'width'},
			$args{'field'}{'height'},
			pack("S*",$args{'start'}{'x'}, $args{'start'}{'y'}),
			pack("S*",$args{'dest'}{'x'} , $args{'dest'}{'y'} ),
			2000);
	}
	return undef if $args{'session'} < 0;

	my $ret;
	if (!$buildType) {
		$ret = $CalcPath_pathStep->Call($args{'session'});
		$CalcPath_destroy->Call($args{'session'});
	} else {
		$ret = Tools::CalcPath_pathStep($args{'session'});
		Tools::CalcPath_destroy($args{'session'});
	}
	return undef if $ret;

	my $size = unpack("L", substr($args{'solution'}, 0, 4));
	my $j = 0;
	for (my $i = ($size-1)*4+4; $i >= 4; $i-=4) {
		$args{'returnArray'}[$j]{'x'} = unpack("S",substr($args{'solution'}, $i, 2));
		$args{'returnArray'}[$j]{'y'} = unpack("S",substr($args{'solution'}, $i+2, 2));
		$j++;
	}
	return scalar @{$args{'returnArray'}}; #successful
}

sub ai_route_getSuccessors {
	my $r_args = shift;
	my $r_pos = shift;
	my $r_array = shift;
	my $type = shift;
	my %pos;

	if (ai_route_getMap($r_args, $$r_pos{'x'}-1, $$r_pos{'y'}) == $type
		&& !($$r_pos{'parent'} && $$r_pos{'parent'}{'x'} == $$r_pos{'x'}-1 && $$r_pos{'parent'}{'y'} == $$r_pos{'y'})) {
		$pos{'x'} = $$r_pos{'x'}-1;
		$pos{'y'} = $$r_pos{'y'};
		push @{$r_array}, {%pos};
	}

	if (ai_route_getMap($r_args, $$r_pos{'x'}, $$r_pos{'y'}-1) == $type
		&& !($$r_pos{'parent'} && $$r_pos{'parent'}{'x'} == $$r_pos{'x'} && $$r_pos{'parent'}{'y'} == $$r_pos{'y'}-1)) {
		$pos{'x'} = $$r_pos{'x'};
		$pos{'y'} = $$r_pos{'y'}-1;
		push @{$r_array}, {%pos};
	}	

	if (ai_route_getMap($r_args, $$r_pos{'x'}+1, $$r_pos{'y'}) == $type
		&& !($$r_pos{'parent'} && $$r_pos{'parent'}{'x'} == $$r_pos{'x'}+1 && $$r_pos{'parent'}{'y'} == $$r_pos{'y'})) {
		$pos{'x'} = $$r_pos{'x'}+1;
		$pos{'y'} = $$r_pos{'y'};
		push @{$r_array}, {%pos};
	}	

		
	if (ai_route_getMap($r_args, $$r_pos{'x'}, $$r_pos{'y'}+1) == $type
		&& !($$r_pos{'parent'} && $$r_pos{'parent'}{'x'} == $$r_pos{'x'} && $$r_pos{'parent'}{'y'} == $$r_pos{'y'}+1)) {
		$pos{'x'} = $$r_pos{'x'};
		$pos{'y'} = $$r_pos{'y'}+1;
		push @{$r_array}, {%pos};
	}	
}

#sellAuto for items_control - chobit andy 20030210
sub ai_sellAutoCheck {
	for ($i = 0; $i < @{$chars[$config{'char'}]{'inventory'}};$i++) {
		next if (!%{$chars[$config{'char'}]{'inventory'}[$i]} || $chars[$config{'char'}]{'inventory'}[$i]{'equipped'});
		if ($items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})}{'sell'}
			&& $chars[$config{'char'}]{'inventory'}[$i]{'amount'} > $items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})}{'keep'}) {
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
	my $ID = shift;
	my $lv = shift;
	my $maxCastTime = shift;
	my $minCastTime = shift;
	my $target = shift;
	my $y = shift;
	my %args;
	$args{'ai_skill_use_giveup'}{'time'} = time;
	$args{'ai_skill_use_giveup'}{'timeout'} = $timeout{'ai_skill_use_giveup'}{'timeout'};
	$args{'skill_use_id'} = $ID;
	$args{'skill_use_lv'} = $lv;
	$args{'skill_use_maxCastTime'}{'time'} = time;
	$args{'skill_use_maxCastTime'}{'timeout'} = $maxCastTime;
	$args{'skill_use_minCastTime'}{'time'} = time;
	$args{'skill_use_minCastTime'}{'timeout'} = $minCastTime;
	if ($y eq "") {
		$args{'skill_use_target'} = $target;
	} else {
		$args{'skill_use_target_x'} = $target;
		$args{'skill_use_target_y'} = $y;
	}
	unshift @ai_seq, "skill_use";
	unshift @ai_seq_args, \%args;
}

#storageAuto for items_control - chobit andy 20030210
sub ai_storageAutoCheck {
	for (my $i = 0; $i < @{$chars[$config{'char'}]{'inventory'}};$i++) {
		next if (!%{$chars[$config{'char'}]{'inventory'}[$i]} || $chars[$config{'char'}]{'inventory'}[$i]{'equipped'});
		if ($items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})}{'storage'}
			&& $chars[$config{'char'}]{'inventory'}[$i]{'amount'} > $items_control{lc($chars[$config{'char'}]{'inventory'}[$i]{'name'})}{'keep'}) {
			return 1;
		}
	}
}

##
# ai_storageGet(items, max)
# items: reference to an array of storage item numbers.
# max: the maximum amount to get, for each item, or 0 for unlimited.
#
# Get one or more items from storage.
#
# Example:
# # Get items 2 and 5 from storage.
# ai_storageGet([2, 5]);
# # Get items 2 and 5 from storage, but at most 30 of each item.
# ai_storageGet([2, 5], 30);
sub ai_storageGet {
	my $r_items = shift;
	my $max = shift;
	my %seq = ();

	$seq{'items'} = \@{$r_items};
	$seq{'max'} = $max;
	$seq{'timeout'} = 0.15;
	unshift @ai_seq, "storageGet";
	unshift @ai_seq_args, \%seq;
}

##
# ai_talkNPC( (x, y | ID => number), sequence)
# x, y: the position of the NPC to talk to.
# ID: the ID of the NPC to talk to.
# sequence: A string containing the NPC talk sequences.
#
# Talks to an NPC. You can specify an NPC position, or an NPC ID.
#
# $sequence is a list of whitespace-separated commands:
# ~l
# c  : Continue
# r# : Select option # from menu.
# n  : Stop talking to NPC.
# b  : Send the "Show shop item list" (Buy) packet.
# w# : Wait # seconds.
# x  : Initialize conversation with NPC. Useful to perform multiple transaction with a single NPC.
# ~l~
#
# Example:
# # Sends "Continue", "Select option 0" to the NPC at (102, 300)
# ai_talkNPC(102, 300, "c r0");
# # Do the same thing with the NPC whose ID is 1337
# ai_talkNPC(ID => 1337, "c r0");
sub ai_talkNPC {
	my %args;
	if ($_[0] eq 'ID') {
		shift;
		$args{'nameID'} = shift;
	} else {
		$args{'pos'}{'x'} = shift;
		$args{'pos'}{'y'} = shift;
	}
	$args{'sequence'} = shift;
	$args{'sequence'} =~ s/^ +| +$//g;
	unshift @ai_seq, "NPC";
	unshift @ai_seq_args,\%args;
}

sub attack {
	my $ID = shift;
	my $priorityAttack = shift;
	my %args;
	$args{'ai_attack_giveup'}{'time'} = time;
	$args{'ai_attack_giveup'}{'timeout'} = $timeout{'ai_attack_giveup'}{'timeout'};
	$args{'ID'} = $ID;
	%{$args{'pos_to'}} = %{$monsters{$ID}{'pos_to'}};
	%{$args{'pos'}} = %{$monsters{$ID}{'pos'}};
	unshift @ai_seq, "attack";
	unshift @ai_seq_args, \%args;
	if ($priorityAttack) {
		message "Priority Attacking: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'}) [$monsters{$ID}{'nameID'}]\n";
	} else {
		message "Attacking: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'}) [$monsters{$ID}{'nameID'}]\n";
	}


	$startedattack = 1;
	if ($config{"monsterCount"}) {	
		my $i = 0;
		while ($config{"monsterCount_mon_$i"} ne "") {
			if ($config{"monsterCount_mon_$i"} eq $monsters{$ID}{'name'}) {
				$monsters_killed[$i] = $monsters_killed[$i] + 1;
			}
			$i++;
		}
	}

	#Mod Start
	AUTOEQUIP: {
		my $i = 0;
		my ($Rdef,$Ldef,$Req,$Leq,$arrow,$j);
		while ($config{"autoSwitch_$i"} ne "") { 
			if (existsInList($config{"autoSwitch_$i"}, $monsters{$ID}{'name'})) {
				message "Encounter Monster : ".$monsters{$ID}{'name'}."\n";

				$Req = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"autoSwitch_$i"."_rightHand"}) if ($config{"autoSwitch_$i"."_rightHand"});
				$Leq = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"autoSwitch_$i"."_leftHand"}) if ($config{"autoSwitch_$i"."_leftHand"});
				$arrow = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"autoSwitch_$i"."_arrow"}) if ($config{"autoSwitch_$i"."_arrow"});

				if ($Leq ne "" && !$chars[$config{'char'}]{'inventory'}[$Leq]{'equipped'}) { 
					$Ldef = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "equipped",32);
					sendUnequip(\$remote_socket,$chars[$config{'char'}]{'inventory'}[$Ldef]{'index'}) if($Ldef ne "");
					message "Auto Equiping [L] :".$config{"autoSwitch_$i"."_leftHand"}." ($Leq)\n", "equip";
					sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$Leq]{'index'},$chars[$config{'char'}]{'inventory'}[$Leq]{'type_equip'}); 
				}
				if ($Req ne "" && !$chars[$config{'char'}]{'inventory'}[$Req]{'equipped'} || $config{"autoSwitch_$i"."_rightHand"} eq "[NONE]") {
					$Rdef = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "equipped",34);
					$Rdef = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "equipped",2) if($Rdef eq "");
					#Debug for 2hand Quicken and Bare Hand attack with 2hand weapon
					if(((binFind(\@skillsST,$skillsST_lut{2}) eq "" && binFind(\@skillsST,$skillsST_lut{23}) eq "" && binFind(\@skillsST,$skillsST_lut{68}) eq "") 
						|| $config{"autoSwitch_$i"."_rightHand"} eq "[NONE]" )
						&& $Rdef ne ""){
						sendUnequip(\$remote_socket,$chars[$config{'char'}]{'inventory'}[$Rdef]{'index'});
					}
					if ($Req eq $Leq) {
						for ($j=0; $j < @{$chars[$config{'char'}]{'inventory'}};$j++) {
							next if (!%{$chars[$config{'char'}]{'inventory'}[$j]});
							if ($chars[$config{'char'}]{'inventory'}[$j]{'name'} eq $config{"autoSwitch_$i"."_rightHand"} && $j != $Leq) {
								$Req = $j;
								last;
							}
						}
					}
					if ($config{"autoSwitch_$i"."_rightHand"} ne "[NONE]") {
						message "Auto Equiping [R] :".$config{"autoSwitch_$i"."_rightHand"}."($Req)\n", "equip"; 
						sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$Req]{'index'},$chars[$config{'char'}]{'inventory'}[$Req]{'type_equip'});
					}
				}
				if ($arrow ne "" && !$chars[$config{'char'}]{'inventory'}[$arrow]{'equipped'}) { 
					message "Auto Equiping [A] :".$config{"autoSwitch_$i"."_arrow"}."\n", "equip";
					sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$arrow]{'index'},0); 
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
				sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$Leq]{'index'},$chars[$config{'char'}]{'inventory'}[$Leq]{'type_equip'});
			}
		}
		if ($config{'autoSwitch_default_rightHand'}) { 
			$Req = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{'autoSwitch_default_rightHand'}); 
			if($Req ne "" && !$chars[$config{'char'}]{'inventory'}[$Req]{'equipped'}) {
				message "Auto equiping default [R] :".$config{'autoSwitch_default_rightHand'}."\n", "equip"; 
				sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$Req]{'index'},$chars[$config{'char'}]{'inventory'}[$Req]{'type_equip'});
			}
		}
		if ($config{'autoSwitch_default_arrow'}) { 
			$arrow = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{'autoSwitch_default_arrow'}); 
			if($arrow ne "" && !$chars[$config{'char'}]{'inventory'}[$arrow]{'equipped'}) {
				message "Auto equiping default [A] :".$config{'autoSwitch_default_arrow'}."\n", "equip"; 
				sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$arrow]{'index'},0);
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

sub aiRemove {
	my $ai_type = shift;
	my $index;
	while (1) {
		$index = binFind(\@ai_seq, $ai_type);
		if ($index ne "") {
			if ($ai_seq_args[$index]{'destroyFunction'}) {
				&{$ai_seq_args[$index]{'destroyFunction'}}(\%{$ai_seq_args[$index]});
			}
			binRemoveAndShiftByIndex(\@ai_seq, $index);
			binRemoveAndShiftByIndex(\@ai_seq_args, $index);
		} else {
			last;
		}
	}
}


sub gather {
	my $ID = shift;
	my %args;
	$args{'ai_items_gather_giveup'}{'time'} = time;
	$args{'ai_items_gather_giveup'}{'timeout'} = $timeout{'ai_items_gather_giveup'}{'timeout'};
	$args{'ID'} = $ID;
	%{$args{'pos'}} = %{$items{$ID}{'pos'}};
	unshift @ai_seq, "items_gather";
	unshift @ai_seq_args, \%args;
	debug "Targeting for Gather: $items{$ID}{'name'} ($items{$ID}{'binID'})\n";
}


sub look {
	my $body = shift;
	my $head = shift;
	my %args;
	unshift @ai_seq, "look";
	$args{'look_body'} = $body;
	$args{'look_head'} = $head;
	unshift @ai_seq_args, \%args;
}

sub move {
	my $x = shift;
	my $y = shift;
	my $triggeredByRoute = shift;
	my $attackID = shift;
	my %args;
	$args{'move_to'}{'x'} = $x;
	$args{'move_to'}{'y'} = $y;
	$args{'triggeredByRoute'} = $triggeredByRoute;
	$args{'attackID'} = $attackID;
	$args{'ai_move_giveup'}{'time'} = time;
	$args{'ai_move_giveup'}{'timeout'} = $timeout{'ai_move_giveup'}{'timeout'};
	unshift @ai_seq, "move";
	unshift @ai_seq_args, \%args;
}

sub quit {
	$quit = 1;
	message "Exiting...\n", "system";
}

sub relog {
	$conState = 1;
	undef $conState_tries;
	$timeout_ex{'master'}{'time'} = time;
	$timeout_ex{'master'}{'timeout'} = 5;
	Network::disconnect(\$remote_socket);
	message "Relogging in 5 seconds...\n", "connection";
}

sub sendMessage {
	my $r_socket = shift;
	my $type = shift;
	my $msg = shift;
	my $user = shift;
	my $i, $j;
	my @msg;
	my @msgs;
	my $oldmsg;
	my $amount;
	my $space;
	@msgs = split /\\n/,$msg;
	for ($j = 0; $j < @msgs; $j++) {
	@msg = split / /, $msgs[$j];
	undef $msg;
	for ($i = 0; $i < @msg; $i++) {
		if (!length($msg[$i])) {
			$msg[$i] = " ";
			$space = 1;
		}
		if (length($msg[$i]) > $config{'message_length_max'}) {
			while (length($msg[$i]) >= $config{'message_length_max'}) {
				$oldmsg = $msg;
				if (length($msg)) {
					$amount = $config{'message_length_max'};
					if ($amount - length($msg) > 0) {
						$amount = $config{'message_length_max'} - 1;
						$msg .= " " . substr($msg[$i], 0, $amount - length($msg));
					}
				} else {
					$amount = $config{'message_length_max'};
					$msg .= substr($msg[$i], 0, $amount);
				}
				if ($type eq "c") {
					sendChat($r_socket, $msg);
				} elsif ($type eq "g") { 
					sendGuildChat($r_socket, $msg); 
				} elsif ($type eq "p") {
					sendPartyChat($r_socket, $msg);
				} elsif ($type eq "pm") {
					sendPrivateMsg($r_socket, $user, $msg);
					undef %lastpm;
					$lastpm{'msg'} = $msg;
					$lastpm{'user'} = $user;
					push @lastpm, {%lastpm};
				} elsif ($type eq "k" && $config{'XKore'}) {
					injectMessage($msg);
 				}
				$msg[$i] = substr($msg[$i], $amount - length($oldmsg), length($msg[$i]) - $amount - length($oldmsg));
				undef $msg;
			}
		}
		if (length($msg[$i]) && length($msg) + length($msg[$i]) <= $config{'message_length_max'}) {
			if (length($msg)) {
				if (!$space) {
					$msg .= " " . $msg[$i];
				} else {
					$space = 0;
					$msg .= $msg[$i];
				}
			} else {
				$msg .= $msg[$i];
			}
		} else {
			if ($type eq "c") {
				sendChat($r_socket, $msg);
			} elsif ($type eq "g") { 
				sendGuildChat($r_socket, $msg); 
			} elsif ($type eq "p") {
				sendPartyChat($r_socket, $msg);
			} elsif ($type eq "pm") {
				sendPrivateMsg($r_socket, $user, $msg);
				undef %lastpm;
				$lastpm{'msg'} = $msg;
				$lastpm{'user'} = $user;
				push @lastpm, {%lastpm};
			} elsif ($type eq "k" && $config{'XKore'}) {
				injectMessage($msg);
			}
			$msg = $msg[$i];
		}
		if (length($msg) && $i == @msg - 1) {
			if ($type eq "c") {
				sendChat($r_socket, $msg);
			} elsif ($type eq "g") { 
				sendGuildChat($r_socket, $msg); 
			} elsif ($type eq "p") {
				sendPartyChat($r_socket, $msg);
			} elsif ($type eq "pm") {
				sendPrivateMsg($r_socket, $user, $msg);
				undef %lastpm;
				$lastpm{'msg'} = $msg;
				$lastpm{'user'} = $user;
				push @lastpm, {%lastpm};
			} elsif ($type eq "k" && $config{'XKore'}) {
				injectMessage($msg);
			}
		}
	}
	}
}

sub sit {
	$timeout{'ai_sit_wait'}{'time'} = time;
	unshift @ai_seq, "sitting";
	unshift @ai_seq_args, {};
}

sub stand {
	unshift @ai_seq, "standing";
	unshift @ai_seq_args, {};
}

sub take {
	my $ID = shift;
	my %args;
	$args{'ai_take_giveup'}{'time'} = time;
	$args{'ai_take_giveup'}{'timeout'} = $timeout{'ai_take_giveup'}{'timeout'};
	$args{'ID'} = $ID;
	%{$args{'pos'}} = %{$items{$ID}{'pos'}};
	unshift @ai_seq, "take";
	unshift @ai_seq_args, \%args;
	debug "Picking up: $items{$ID}{'name'} ($items{$ID}{'binID'})\n";
}

#######################################
#######################################
#AI MATH
#######################################
#######################################


sub getVector {
	my $r_store = shift;
	my $r_head = shift;
	my $r_tail = shift;
	$$r_store{'x'} = $$r_head{'x'} - $$r_tail{'x'};
	$$r_store{'y'} = $$r_head{'y'} - $$r_tail{'y'};
}

sub lineIntersection {
	my $r_pos1 = shift;
	my $r_pos2 = shift;
	my $r_pos3 = shift;
	my $r_pos4 = shift;
	my ($x1, $x2, $x3, $x4, $y1, $y2, $y3, $y4, $result, $result1, $result2);
	$x1 = $$r_pos1{'x'};
	$y1 = $$r_pos1{'y'};
	$x2 = $$r_pos2{'x'};
	$y2 = $$r_pos2{'y'};
	$x3 = $$r_pos3{'x'};
	$y3 = $$r_pos3{'y'};
	$x4 = $$r_pos4{'x'};
	$y4 = $$r_pos4{'y'};
	$result1 = ($x4 - $x3)*($y1 - $y3) - ($y4 - $y3)*($x1 - $x3);
	$result2 = ($y4 - $y3)*($x2 - $x1) - ($x4 - $x3)*($y2 - $y1);
	if ($result2 != 0) {
		$result = $result1 / $result2;
	}
	return $result;
}


sub moveAlongVector {
	my $r_store = shift;
	my $r_pos = shift;
	my $r_vec = shift;
	my $amount = shift;
	my %norm;
	if ($amount) {
		normalize(\%norm, $r_vec);
		$$r_store{'x'} = $$r_pos{'x'} + $norm{'x'} * $amount;
		$$r_store{'y'} = $$r_pos{'y'} + $norm{'y'} * $amount;
	} else {
		$$r_store{'x'} = $$r_pos{'x'} + $$r_vec{'x'};
		$$r_store{'y'} = $$r_pos{'y'} + $$r_vec{'y'};
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

sub percent_hp {
	my $r_hash = shift;
	if (!$$r_hash{'hp_max'}) {
		return 0;
	} else {
		return ($$r_hash{'hp'} / $$r_hash{'hp_max'} * 100);
	}
}

sub percent_sp {
	my $r_hash = shift;
	if (!$$r_hash{'sp_max'}) {
		return 0;
	} else {
		return ($$r_hash{'sp'} / $$r_hash{'sp_max'} * 100);
	}
}

sub percent_weight {
	my $r_hash = shift;
	if (!$$r_hash{'weight_max'}) {
		return 0;
	} else {
		return ($$r_hash{'weight'} / $$r_hash{'weight_max'} * 100);
	}
}

sub positionNearPlayer {
	my $r_hash = shift;
	my $dist = shift;

	for (my $i = 0; $i < @playersID; $i++) {
		next if ($playersID[$i] eq "");
		return 1 if (distance($r_hash, \%{$players{$playersID[$i]}{'pos_to'}}) <= $dist);
	}
	return 0;
}

sub positionNearPortal {
	my $r_hash = shift;
	my $dist = shift;

	for (my $i = 0; $i < @portalsID; $i++) {
		next if ($portalsID[$i] eq "");
		return 1 if (distance($r_hash, \%{$portals{$portalsID[$i]}{'pos'}}) <= $dist);
	}
	return 0;
}


#######################################
#######################################
#FILE PARSING AND WRITING
#######################################
#######################################

sub chatLog {
	my $type = shift;
	my $message = shift;
	open CHAT, ">> $Settings::chat_file";
	print CHAT "[".getFormattedDate(int(time))."][".uc($type)."] $message";
	close CHAT;
}

sub itemLog {
	my $crud = shift;
	return if (!$config{'itemHistory'});
	open ITEMLOG, ">> $Settings::item_log_file";
	print ITEMLOG "[".getFormattedDate(int(time))."] $crud";
	close ITEMLOG;
}

sub monsterLog {
	my $crud = shift;
	return if (!$config{'monsterLog'});
	open MONLOG, ">> $Settings::monster_log";
	print MONLOG "[".getFormattedDate(int(time))."] $crud\n";
	close MONLOG;
}

sub chatLog_clear { 
	if (-f $Settings::chat_file) { unlink($Settings::chat_file); } 
}

sub itemLog_clear { 
	if (-f $Settings::item_log_file) { unlink($Settings::item_log_file); } 
}

sub convertGatField {
	my $file = shift;
	my $r_hash = shift;
	my $i;
	open FILE, "+> $file";
	binmode(FILE);
	print FILE pack("S*", $$r_hash{'width'}, $$r_hash{'height'});
	for ($i = 0; $i < @{$$r_hash{'field'}}; $i++) {
		print FILE pack("C1", $$r_hash{'field'}[$i]);
	}
	close FILE;
}

sub dumpData {
	my $msg = shift;
	my $dump;
	my $puncations = quotemeta '~!@#$%^&*()_+|\"\'';

	$dump = "\n\n================================================\n" .
		getFormattedDate(int(time)) . "\n\n" . 
		length($msg) . " bytes\n\n";

	for (my $i = 0; $i < length($msg); $i += 16) {
		my $line;
		my $data = substr($msg, $i, 16);
		my $rawData = '';

		for (my $j = 0; $j < length($data); $j++) {
			my $char = substr($data, $j, 1);

			if (($char =~ /\W/ && $char =~ /\S/ && !($char =~ /[$puncations]/))
			    || ($char eq chr(10) || $char eq chr(13) || $char eq "\t")) {
				$rawData .= '.';
			} else {
				$rawData .= substr($data, $j, 1);
			}
		}

		$line = getHex(substr($data, 0, 8));
		$line .= '    ' . getHex(substr($data, 8)) if (length($data) > 8);

		$line .= ' ' x (50 - length($line)) if (length($line) < 54);
		$line .= "    $rawData\n";
		$line = sprintf("%3d>  ", $i) . $line;
		$dump .= $line;
	}

	open DUMP, ">> DUMP.txt";
	print DUMP $dump;
	close DUMP;
 
	debug "$dump\n", "parseMsg", 2;
	message "Message Dumped into DUMP.txt!\n", undef, 1;
}

sub getField {
	my $file = shift;
	my $r_hash = shift;
	my $result = 1;
	
	undef %{$r_hash};
	unless (-e $file) {
		warning "Could not load field $file - you must install the kore-field pack!\n";
		$result = 0;
	}
	
	($$r_hash{'name'}) = $file =~ m{/?([^/.]*)\.};
	open FILE, "<", $file;
	binmode(FILE);
	my $data;
	{
		local($/);
		$data = <FILE>;
	}
	close FILE;
	@$r_hash{'width', 'height'} = unpack("S1 S1", substr($data, 0, 4, ''));
	$$r_hash{'rawMap'} = $data;
	$$r_hash{'binMap'} = pack('b*', $data);
	$$r_hash{'field'} = [unpack("C*", $data)];


	(my $dist_file = $file) =~ s/\.fld$/.dist/i;
	if (-e $dist_file) {
		open FILE, "<", $dist_file;
		binmode(FILE);
		my $dist_data;

		{
			local($/);
			$dist_data = <FILE>;
		}
		close FILE;
		my $dversion = 0;
		if (substr($dist_data, 0, 2) eq "V#") {
			$dversion = unpack("xx S1", substr($dist_data, 0, 4, ''));
		}
		my ($dw, $dh) = unpack("S1 S1", substr($dist_data, 0, 4, ''));
		if (
			#version 0 files had a bug when height != width, so keep version 0 files not effected by the bug.
			   $dversion == 0 && $dw == $dh && $$r_hash{'width'} == $dw && $$r_hash{'height'} == $dh
			#version 1 and greater have no know bugs, so just do a minimum validity check.
			|| $dversion >= 1 && $$r_hash{'width'} == $dw && $$r_hash{'height'} == $dh
		) {
			$$r_hash{'dstMap'} = $dist_data;
		}
	}
	unless ($$r_hash{'dstMap'}) {
		$$r_hash{'dstMap'} = makeDistMap(@$r_hash{'rawMap', 'width', 'height'});
		open FILE, ">", $dist_file or die "Could not write dist cache file: $!\n";
		binmode(FILE);
		print FILE pack("a2 S1", 'V#', 1);
		print FILE pack("S1 S1", @$r_hash{'width', 'height'});
		print FILE $$r_hash{'dstMap'};
		close FILE;
	}
	
	return $result;
}

sub makeDistMap {
	my $data = shift;
	my $width = shift;
	my $height = shift;
	for (my $i = 0; $i < length($data); $i++) {
		substr($data, $i, 1, (ord(substr($data, $i, 1)) ? chr(0) : chr(255)));
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

sub getGatField {
	my $file = shift;
	my $r_hash = shift;
	my $i, $data;
	undef %{$r_hash};
	($$r_hash{'name'}) = $file =~ /([\s\S]*)\./;
	open FILE, $file;
	binmode(FILE);
	read(FILE, $data, 16);
	my $width = unpack("L1", substr($data, 6,4));
	my $height = unpack("L1", substr($data, 10,4));
	$$r_hash{'width'} = $width;
	$$r_hash{'height'} = $height;
	while (read(FILE, $data, 20)) {
		$$r_hash{'field'}[$i] = unpack("C1", substr($data, 14,1));
		$i++;
	}
	close FILE;
}

sub getResponse {
	my $type = shift;
	my $key;
	my @keys;
	my $msg;
	foreach $key (keys %responses) {
		if ($key =~ /^$type\_\d+$/) {
			push @keys, $key;
		} 
	}
	$msg = $responses{$keys[int(rand(@keys))]};
	$msg =~ s/\%\$(\w+)/$responseVars{$1}/eig;
	return $msg;
}

sub updateDamageTables {
	my ($ID1, $ID2, $damage) = @_;
	if ($ID1 eq $accountID) {
		if (%{$monsters{$ID2}}) {
			# You attack monster
			$monsters{$ID2}{'dmgTo'} += $damage;
			$monsters{$ID2}{'dmgFromYou'} += $damage;
			if ($damage == 0) {
				$monsters{$ID2}{'missedFromYou'}++;
			}
		}
	} elsif ($ID2 eq $accountID) {
		if (%{$monsters{$ID1}}) {
			# Monster attacks you
			$monsters{$ID1}{'dmgFrom'} += $damage;
			$monsters{$ID1}{'dmgToYou'} += $damage;
			if ($damage == 0) {
				$monsters{$ID1}{'missedYou'}++;
			}
			$monsters{$ID1}{'attackedByPlayer'} = 0;
			$monsters{$ID1}{'attackedYou'}++ unless (
								binSize(keys %{$monsters{$ID1}{'dmgFromPlayer'}}) ||
								binSize(keys %{$monsters{$ID1}{'dmgToPlayer'}}) ||
								$monsters{$ID1}{'missedFromPlayer'} ||
								$monsters{$ID1}{'missedToPlayer'});

			my $teleport = 0;
			if ($mon_control{lc($monsters{$ID1}{'name'})}{'teleport_auto'}==2){
				message "Teleport due to $monsters{$ID1}{'name'} attack\n";
				$teleport = 1;
			} elsif ($config{'teleportAuto_deadly'} && $damage >= $chars[$config{'char'}]{'hp'}) {
				message "Next $damage dmg could kill you. Teleporting...\n";
				$teleport = 1;
			} elsif ($config{'teleportAuto_maxDmg'} && $damage >= $config{'teleportAuto_maxDmg'}) {
				message "$monsters{$ID1}{'name'} attack you more than $config{'teleportAuto_maxDmg'} dmg. Teleporting...\n";
				$teleport = 1;
			}
			useTeleport(1) if ($teleport && $AI);
		}
	} elsif (%{$monsters{$ID1}}) {
		if (%{$players{$ID2}}) {
			# Monster attacks player
			$monsters{$ID1}{'dmgFrom'} += $damage;
			$monsters{$ID1}{'dmgToPlayer'}{$ID2} += $damage;
			$players{$ID2}{'dmgFromMonster'}{$ID1} += $damage;
			if ($damage == 0) {
				$monsters{$ID1}{'missedToPlayer'}{$ID2}++;
				$players{$ID2}{'missedFromMonster'}{$ID1}++;
			}
			if (%{$chars[$config{'char'}]{'party'}} && %{$chars[$config{'char'}]{'party'}{'users'}{$ID2}}) {
				# Monster attacks party member
				$monsters{$ID1}{'dmgToParty'} += $damage;
				$monsters{$ID1}{'missedToParty'}++ if ($damage == 0);
				$monsters{$ID1}{'attackedByPlayer'} = 0 if ($config{'attackAuto_party'} || ( 
						$config{'attackAuto_followTarget'} &&
						$ai_v{'temp'}{'ai_follow_following'} &&
						$ID2 eq $ai_v{'temp'}{'ai_follow_ID'}
					)); 
			} else {
				$monsters{$ID1}{'attackedByPlayer'} = 1 unless (
					($config{'attackAuto_followTarget'} && $ai_v{'temp'}{'ai_follow_following'} && $ID2 eq $ai_v{'temp'}{'ai_follow_ID'})
					|| $monsters{$ID1}{'attackedYou'}
				);
			}
		}
		
	} elsif (%{$players{$ID1}}) {
		if (%{$monsters{$ID2}}) {
			# Player attacks monster
			$monsters{$ID2}{'dmgTo'} += $damage;
			$monsters{$ID2}{'dmgFromPlayer'}{$ID1} += $damage;
			$monsters{$ID2}{'lastAttackFrom'} = $ID1;
			$players{$ID1}{'dmgToMonster'}{$ID2} += $damage;
			
			if ($damage == 0) {
				$monsters{$ID2}{'missedFromPlayer'}{$ID1}++;
				$players{$ID1}{'missedToMonster'}{$ID2}++;
			}
			if (%{$chars[$config{'char'}]{'party'}} && %{$chars[$config{'char'}]{'party'}{'users'}{$ID1}}) {
				$monsters{$ID2}{'dmgFromParty'} += $damage;
				$monsters{$ID2}{'attackedByPlayer'} = 0 if ($config{'attackAuto_party'} || ( 
				$config{'attackAuto_followTarget'} && 
				$config{'follow'} && $players{$ID1}{'name'} eq $config{'followTarget'})); 
			} else {
				$monsters{$ID2}{'attackedByPlayer'} = 1 unless (
							($config{'attackAuto_followTarget'} && $ai_v{'temp'}{'ai_follow_following'} && $ID1 eq $ai_v{'temp'}{'ai_follow_ID'})
							|| $monsters{$ID2}{'attackedYou'}
					);
			}
		}
	}
}


#######################################
#######################################
#MISC FUNCTIONS
#######################################
#######################################

sub avoidGM_near {
	for (my $i = 0; $i < @playersID; $i++) {
		next if($playersID[$i] eq "");

		# Check whether this "GM" is on the ignore list
		# in order to prevent false matches
		my $statusGM = 1;
		my $j = 0;
		while ($config{"avoid_ignore_$j"} ne "") {
			if ($players{$playersID[$i]}{'name'} eq $config{"avoid_ignore_$j"}) {
				$statusGM = 0;
				last;
			}
			$j++;
		}

		if ($statusGM && $players{$playersID[$i]}{'name'} =~ /^([a-z]?ro)?-?(Sub)?-?\[?GM\]?/i) {
			warning "GM $players{$playersID[$i]}{'name'} is nearby, disconnecting...\n";
			chatLog("k", "*** Found GM $players{$playersID[$i]}{'name'} nearby and disconnected ***\n");

			my $tmp = $config{'avoidGM_reconnect'};
			warning "Disconnect for $tmp seconds...\n";
			$timeout_ex{'master'}{'time'} = time;
			$timeout_ex{'master'}{'timeout'} = $tmp;
			Network::disconnect(\$remote_socket);
			return 1;
		}
	}
	return 0;
}

sub avoidGM_talk {
	return if (!$config{'avoidGM_talk'});
	my ($chatMsgUser, $chatMsg) = @_;

	# Check whether this "GM" is on the ignore list
	# in order to prevent false matches
	my $statusGM = 1;
	my $j = 0;
	while ($config{"avoid_ignore_$j"} ne "") {
		if ($chatMsgUser eq $config{"avoid_ignore_$j"}) {
			$statusGM = 0;
			last;
		}
		$j++;
	}

	if ($statusGM && $chatMsgUser =~ /^([a-z]?ro)?-?(Sub)?-?\[?GM\]?/i) {
		warning "Disconnecting to avoid GM!\n";
		chatLog("k", "*** The GM $chatMsgUser talked to you, auto disconnected ***\n");

		my $tmp = $config{'avoidGM_reconnect'};
		warning "Disconnect for $tmp seconds...\n";
		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $tmp;
		Network::disconnect(\$remote_socket);
		return 1;
	}
	return 0;
}

sub avoidList_near {
	for (my $i = 0; $i < @playersID; $i++) {
		next if($playersID[$i] eq "");
		my $j = 0;
		while ($avoid{"avoid_$j"} ne "") {
			if ($players{$playersID[$i]}{'name'} eq $avoid{"avoid_$j"} || $players{$playersID[$i]}{'nameID'} eq $avoid{"avoid_aid_$j"}) {
				warning "$players{$playersID[$i]}{'name'} is nearby, disconnecting...\n";
				chatLog("k", "*** Found $players{$playersID[$i]}{'name'} nearby and disconnected ***\n");
				warning "Disconnect for $config{'avoidList_reconnect'} seconds...\n";
				$timeout_ex{'master'}{'time'} = time;
				$timeout_ex{'master'}{'timeout'} = $config{'avoidList_reconnect'};
				Network::disconnect(\$remote_socket);
				return 1;
			}
			$j++;
		}
	}
	return 0;
}

sub avoidList_talk {
	return if (!$config{'avoidList'});
	my ($chatMsgUser, $chatMsg) = @_;

	my $j = 0;
	while ($avoid{"avoid_$j"} ne "") {
		if ($chatMsgUser eq $avoid{"avoid_$j"}) { 
			warning "Disconnecting to avoid $chatMsgUser!\n";
			chatLog("k", "*** $chatMsgUser talked to you, auto disconnected ***\n"); 
			warning "Disconnect for $config{'avoidList_reconnect'} seconds...\n";
			$timeout_ex{'master'}{'time'} = time;
			$timeout_ex{'master'}{'timeout'} = $config{'avoidList_reconnect'};
			Network::disconnect(\$remote_socket);
		}
		$j++;
	}
}

sub compilePortals {
	my %missingMap;
	my %mapPortals;
	my @solution;

	foreach my $portal (keys %portals_lut) {
		%{$mapPortals{$portals_lut{$portal}{'source'}{'map'}}{$portal}{'pos'}} = %{$portals_lut{$portal}{'source'}{'pos'}};
	}
	foreach my $map (sort keys %mapPortals) {
		my @list = sort keys %{$mapPortals{$map}};
		foreach my $this (@list) {
			foreach my $that (@list) {
				next if $this eq $that;
				next if $portals_los{$this}{$that} ne '' && $portals_los{$that}{$this} ne '';
				if ($field{'name'} ne $map) { if (!getField("$Settings::def_field/$map.fld", \%field)) { $missingMap{$map} = 1; }}
				ai_route_getRoute(\@solution, \%field, \%{$mapPortals{$map}{$this}{'pos'}}, \%{$mapPortals{$map}{$that}{'pos'}});
				$portals_los{$this}{$that} = scalar @solution;
				$portals_los{$that}{$this} = scalar @solution;
				message sprintf("Path cost: [%4d] $map ($mapPortals{$map}{$this}{'pos'}{'x'},$mapPortals{$map}{$this}{'pos'}{'y'}) ($mapPortals{$map}{$that}{'pos'}{'x'},$mapPortals{$map}{$that}{'pos'}{'y'})\n", $portals_los{$this}{$that}), "system";
			}
		}
	}
	message "Adding NPC's Destination\n", "system";
	foreach my $portal (keys %portals_lut) {
		foreach my $npc (keys %{$portals_lut{$portal}{'dest'}}) {
			next unless $portals_lut{$portal}{'dest'}{$npc}{'steps'};
			my $map = $portals_lut{$portal}{'dest'}{$npc}{'map'};
			foreach my $dest (keys %{$mapPortals{$map}}) {
				next if $portals_los{$npc}{$dest} ne '';
				if ($field{'name'} ne $map) { if (!getField("$Settings::def_field/$map.fld", \%field)) { $missingMap{$map} = 1; }}
				ai_route_getRoute(\@solution, \%field, \%{$portals_lut{$portal}{'dest'}{$npc}{'pos'}}, \%{$mapPortals{$map}{$dest}{'pos'}});
				$portals_los{$npc}{$dest} = scalar @solution;
				message sprintf("Path cost: [%4d] $map ($npc) ($dest)\n", $portals_los{$npc}{$dest}), "system";
			}
		}
	}

	writePortalsLOS("$Settings::tables_folder/portalsLOS.txt", \%portals_los);
	message "Wrote portals Line of Sight table to '$Settings::tables_folder/portalsLOS.txt'\n", "system";

	if (%missingMap) {
		warning "----------------------------Error Summary----------------------------\n";
		warning "Missing: $_.fld\n" foreach (sort keys %missingMap);
		warning "Note: LOS information for the above listed map(s) will be inaccurate;\n";
		warning "      however it is safe to ignore if those map(s) are not in used\n";
		warning "----------------------------Error Summary----------------------------\n";
	}	
}

sub compilePortals_check {
	my %mapPortals;
	foreach (keys %portals_lut) {
		%{$mapPortals{$portals_lut{$_}{'source'}{'map'}}{$_}{'pos'}} = %{$portals_lut{$_}{'source'}{'pos'}};
	}
	foreach my $map (sort keys %mapPortals) {
		foreach my $this (sort keys %{$mapPortals{$map}}) {
			foreach my $that (sort keys %{$mapPortals{$map}}) {
				next if $this eq $that;
				next if $portals_los{$this}{$that} ne '' && $portals_los{$that}{$this} ne '';
				return 1;
			}
		}
	}
	foreach my $portal (keys %portals_lut) {
		foreach my $npc (keys %{$portals_lut{$portal}{'dest'}}) {
			next unless $portals_lut{$portal}{'dest'}{$npc}{'steps'};
			my $map = $portals_lut{$portal}{'dest'}{$npc}{'map'};
			foreach my $dest (keys %{$mapPortals{$map}}) {
				next if $portals_los{$npc}{$dest} ne '';
				return 1;
			}
		}
	}
	return 0;
}

##
# lookAtPosition(pos, [headdir])
# pos: a reference to a coordinate hash.
# headdir: 0 = face directly, 1 = look right, 2 = look left
#
# Turn face and body direction to position %pos.
sub lookAtPosition {
	my $pos1 = $chars[$config{'char'}]{'pos_to'};
	my $pos2 = shift;
	my $headdir = shift;
	my $dx = $pos2->{'x'} - $pos1->{'x'};
	my $dy = $pos2->{'y'} - $pos1->{'y'};
	my $bodydir = undef;

	if ($dx == 0) {
		if ($dy > 0) {
			$bodydir = 0;
		} elsif ($dy < 0) {
			$bodydir = 4;
		}
	} elsif ($dx < 0) {
		if ($dy > 0) {
			$bodydir = 1;
		} elsif ($dy < 0) {
			$bodydir = 3;
		} else {
			$bodydir = 2;
		}
	} else {
		if ($dy > 0) {
			$bodydir = 7;
		} elsif ($dy < 0) {
			$bodydir = 5;
		} else {
			$bodydir = 6;
		}
	}

	return unless (defined($bodydir));
	if ($headdir == 1) {
		$bodydir++;
		$bodydir -= 8 if ($bodydir > 7);
		look($bodydir, 1);
	} elsif ($headdir == 2) {
		$bodydir--;
		$bodydir += 8 if ($bodydir < 0);
		look($bodydir, 2);
	} else {
		look($bodydir);
	}
}

sub portalExists {
	my ($map, $r_pos) = @_;
	foreach (keys %portals_lut) {
		if ($portals_lut{$_}{'source'}{'map'} eq $map && $portals_lut{$_}{'source'}{'pos'}{'x'} == $$r_pos{'x'}
		 && $portals_lut{$_}{'source'}{'pos'}{'y'} == $$r_pos{'y'}) {
			return $_;
		}
	}
}

sub redirectXKoreMessages {
	my ($type, $domain, $level, $globalVerbosity, $message, $user_data) = @_;

	return if ($type eq "debug" || $level > 0 || $conState != 5 || $XKore_dontRedirect);
	return if ($domain =~ /^(connection|startup|pm|publicchat|guildchat|selfchat|emotion|drop|inventory|deal)$/);
	return if ($domain =~ /^(attack|skill|list|info|partychat|npc)/);

	$message =~ s/\n*$//s;
	$message =~ s/\n/\\n/g;
	sendMessage(\$remote_socket, "k", $message);
}

sub calcStat {
	my $damage = shift;
	$totaldmg = $totaldmg + $damage;
}

sub monKilled {
	$monkilltime = time();
	# if someone kills it
	if (($monstarttime == 0) || ($monkilltime < $monstarttime)) { 
		$monstarttime = 0;
		$monkilltime = 0; 
	}
	$elasped = $monkilltime - $monstarttime;
	$totalelasped = $totalelasped + $elasped;
	if ($totalelasped == 0) {
		$dmgpsec = 0
	} else {
		$dmgpsec = $totaldmg / $totalelasped;
	}
}

sub findIndexString_lc_not_equip {
	my $r_array = shift;
	my $match = shift;
	my $ID = shift;
	my $i;
	for ($i = 0; $i < @{$r_array} ;$i++) {
		if ((%{$$r_array[$i]} && lc($$r_array[$i]{$match}) eq lc($ID) && !($$r_array[$i]{'equipped'}))
			 || (!%{$$r_array[$i]} && $ID eq "")) {			  
			return $i;
		}
	}
	if ($ID eq "") {
		return $i;
	}
}

sub getListCount {
	my ($list) = @_;
	my $i = 0;
	my @array = split / *, */, $list;
	foreach (@array) {
		s/^\s+//;
		s/\s+$//;
		s/\s+/ /g;
		next if ($_ eq "");
		$i++;
	}
	return $i;
}

sub getFromList {
	my ($list, $num) = @_;
	my $i = 0;
	my @array = split(/ *, */, $list);
	foreach (@array) {
		s/^\s+//;
		s/\s+$//;
		s/\s+/ /g;
		next if ($_ eq "");
		$i++;
		return $_ if ($i eq $num);
	}
	return undef;
}

# Resolves a player or monster ID into a name
sub getActorName {
	my $id = shift;
	if (!$id) {
		return 'Nothing';
	} elsif ($id eq $accountID) {
		return 'You';
	} elsif (my $monster = $monsters{$id}) {
		return "Monster $monster->{name} ($monster->{binID})";
	} elsif (my $player = $players{$id}) {
		return "Player $player->{name} ($player->{binID})";
	} else {
		return "Unknown #".unpack("L1", $id);
	}
}

# Resolves a pair of player/monster IDs into names
sub getActorNames {
	my ($sourceID, $targetID) = @_;

	my $source = getActorName($sourceID);
	my $uses = $source eq 'You' ? 'use' : 'uses';
	my $target;

	if ($targetID eq $sourceID) {
		if ($targetID eq $accountID) {
			$target = 'yourself';
		} else {
			$target = 'self';
		}
	} else {
		$target = getActorName($targetID);
	}

	return ($source, $uses, $target);
}

sub useTeleport {
	my $level = shift;
	my $invIndex = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "nameID", $level + 600);
	if (!$config{'teleportAuto_useItem'} || $chars[$config{'char'}]{'skills'}{'AL_TELEPORT'}{'lv'} ) {
		sendTeleport(\$remote_socket, "Random") if ($level == 1);
		sendTeleport(\$remote_socket, $config{'saveMap'}.".gat") if ($level == 2);
	} elsif ($config{'teleportAuto_useItem'} && $invIndex ne "") {
		sendItemUse(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$invIndex]{'index'}, $accountID);
		if ($level == 1) {
			sendTeleport(\$remote_socket, "Random");
		}
	} else {
		warning "You don't have wing or skill to teleport or respawn\n";
	}
}

# Keep track of when we last cast a skill
sub setSkillUseTimer {
	my $skillID = shift;

	$chars[$config{char}]{skills}{$skills_rlut{lc($skillsID_lut{$skillID})}}{time_used} = time;
	undef $chars[$config{char}]{time_cast};
}

# Increment counter for monster being casted on
sub countCastOn {
	my ($sourceID, $targetID) = @_;

	if ($monsters{$targetID}) {
		if ($sourceID eq $accountID) {
			$monsters{$targetID}{'castOnByYou'}++;
		} elsif (%{$players{$sourceID}}) {
			$monsters{$targetID}{'castOnByPlayer'}{$sourceID}++;
		} elsif (%{$monsters{$sourceID}}) {
			$monsters{$targetID}{'castOnByMonster'}{$sourceID}++;
		}
	}
}

# return ID based on name if party member is online
sub findPartyUserID {
	if (%{$chars[$config{'char'}]{'party'}}) {
		my $partyUserName = shift; 
		for (my $j = 0; $j < @partyUsersID; $j++) {
	        	next if ($partyUsersID[$j] eq "");
			if ($partyUserName eq $chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$j]}{'name'}
				&& $chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$j]}{'online'}) {
				return $partyUsersID[$j];
			}
		}
	}

	return undef;
}

# fill in a hash of NPC information either base on ID or location ("map x y")
sub getNPCInfo {
	my $id = shift;
	my $return_hash = shift;

	undef %{$return_hash};
	
	if ($id =~ /^\d+$/) {
		if (%{$npcs_lut{$id}}) {
			$$return_hash{id} = $id;
			$$return_hash{map} = $npcs_lut{$id}{map};
			$$return_hash{pos}{x} = $npcs_lut{$id}{pos}{x};
			$$return_hash{pos}{y} = $npcs_lut{$id}{pos}{y};		
		}
	}
	else {
		my ($map, $x, $y) = split(/ +/, $id, 3);
		
		$$return_hash{map} = $map;
		$$return_hash{pos}{x} = $x;
		$$return_hash{pos}{y} = $y;
	}
	
	if (defined($$return_hash{map}) && defined($$return_hash{pos}{x}) && defined($$return_hash{pos}{y})) {
		$$return_hash{ok} = 1;
	}
	else {
		error "Incomplete NPC info or ID not found in npcs.txt\n";
	}
}

# should not happened but just to safeguard
sub stuckCheck {
	return if (($config{stuckcheckLimit} eq "") || ($config{stuckcheckLimit} == 0));
	
	my $stuck = shift;
	if ($stuck) {
		$ai_v{stuck_count}++;
		if ($ai_v{stuck_count} > $config{stuckcheckLimit}) {
			my $msg = "Failed to move for $ai_v{stuck_count} times, teleport. ($field{'name'} $chars[$config{char}]{pos}{x},$chars[$config{char}]{pos}{y})\n";
			warning $msg;
			chatLog("k", $msg);
			useTeleport(1);
			delete $ai_v{stuck_count};
		}
	} else {
		delete $ai_v{stuck_count};
	}
}


return 1;
