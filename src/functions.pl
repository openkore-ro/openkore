# To run kore, execute openkore.pl instead.

#########################################################################
# This software is open source, licensed under the GNU General Public
# License, version 2.
# Basically, this means that you're allowed to modify and distribute
# this software. However, if you distribute modified versions, you MUST
# also distribute the source code.
# See http://www.gnu.org/licenses/gpl.html for the full license.
#
# $Revision$
# $Id$
#########################################################################

use Time::HiRes qw(time usleep);
use IO::Socket;
use Digest::MD5;
use Config;
use Globals;
use Log qw(message warning error debug);
use FileParsers;
use Interface;
use Plugins;


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
	# route error check variables
	undef $old_x;
	undef $old_y;
	undef $old_pos_x;
	undef $old_pos_y;
	undef $move_x;
	undef $move_y;
	undef $move_pos_x;
	undef $move_pos_y;
	$calcFrom_SameSpot = 0;
	$calcTo_SameSpot = 0;
	$moveFrom_SameSpot = 0;
	$moveTo_SameSpot = 0;
	$route_stuck = 0;
	$totalStuckCount = 0 if ($totalStuckCount > 10 || $totalStuckCount < 0);
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
		connection(\$remote_socket, $config{"master_host_$config{'master'}"},$config{"master_port_$config{'master'}"});

		if ($config{'SecureLogin'} >= 1) {
			message("Secure Login...\n", "connection");
			undef $secureLoginKey;
			sendMasterCodeRequest(\$remote_socket,$config{'SecureLogin_RequestType'});
		} else {
			sendMasterLogin(\$remote_socket, $config{'username'}, $config{'password'});
		}

		$timeout{'master'}{'time'} = time;

	} elsif ($conState == 1 && $config{'SecureLogin'} >= 1 && $secureLoginKey ne "" && !timeOut(\%{$timeout{'master'}}) 
			  && $conState_tries) {

		message("Sending encoded password...\n", "connection");
		sendMasterSecureLogin(\$remote_socket, $config{'username'}, $config{'password'},$secureLoginKey,
											$config{'version'},$config{"master_version_$config{'master'}"},
											$config{'SecureLogin'},$config{'SecureLogin_Account'});
		undef $secureLoginKey;

	} elsif ($conState == 1 && timeOut(\%{$timeout{'master'}}) && timeOut(\%{$timeout_ex{'master'}})) {
		error "Timeout on Master Server, reconnecting...\n", "connection";
		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		killConnection(\$remote_socket);
		undef $conState_tries;

	} elsif ($conState == 2 && !($remote_socket && $remote_socket->connected()) && $config{'server'} ne "" && !$conState_tries) {
		message("Connecting to Game Login Server...\n", "connection");
		$conState_tries++;
		connection(\$remote_socket, $servers[$config{'server'}]{'ip'},$servers[$config{'server'}]{'port'});
		sendGameLogin(\$remote_socket, $accountID, $sessionID, $accountSex);
		$timeout{'gamelogin'}{'time'} = time;

	} elsif ($conState == 2 && timeOut(\%{$timeout{'gamelogin'}}) && $config{'server'} ne "") {
		error "Timeout on Game Login Server, reconnecting...\n", "connection";
		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		killConnection(\$remote_socket);
		undef $conState_tries;
		$conState = 1;

	} elsif ($conState == 3 && !($remote_socket && $remote_socket->connected()) && $config{'char'} ne "" && !$conState_tries) {
		message("Connecting to Character Select Server...\n", "connection");
		$conState_tries++;
		connection(\$remote_socket, $servers[$config{'server'}]{'ip'},$servers[$config{'server'}]{'port'});
		sendCharLogin(\$remote_socket, $config{'char'});
		$timeout{'charlogin'}{'time'} = time;

	} elsif ($conState == 3 && timeOut(\%{$timeout{'charlogin'}}) && $config{'char'} ne "") {
		error "Timeout on Character Select Server, reconnecting...\n", "connection";
		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		killConnection(\$remote_socket);
		$conState = 1;
		undef $conState_tries;

	} elsif ($conState == 4 && !($remote_socket && $remote_socket->connected()) && !$conState_tries) {
		message("Connecting to Map Server...\n", "connection");
		$conState_tries++;
		initConnectVars();
		connection(\$remote_socket, $map_ip, $map_port);
		sendMapLogin(\$remote_socket, $accountID, $charID, $sessionID, $accountSex2);
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		$timeout{'maplogin'}{'time'} = time;

	} elsif ($conState == 4 && timeOut(\%{$timeout{'maplogin'}})) {
		message("Timeout on Map Server, connecting to Master Server...\n", "connection");
		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		killConnection(\$remote_socket);
		$conState = 1;
		undef $conState_tries;

	} elsif ($conState == 5 && !($remote_socket && $remote_socket->connected())) {
		$conState = 1;
		undef $conState_tries;

	} elsif ($conState == 5 && timeOut(\%{$timeout{'play'}})) {
		error "Timeout on Map Server, connecting to Master Server...\n", "connection";
		$timeout_ex{'master'}{'time'} = time;
		$timeout_ex{'master'}{'timeout'} = $timeout{'reconnect'}{'timeout'};
		killConnection(\$remote_socket);
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
		killConnection(\$remote_socket);
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

		$Settings::config_file = $file;
		$parseFiles[0]{'file'} = $file;
		parseDataFile2($file, \%config);

		if ($oldMasterHost ne $config{"master_host_$config{'master'}"}
		 || $oldMasterPort ne $config{"master_port_$config{'master'}"}
		 || $oldUsername ne $config{'username'}
		 || $oldChar ne $config{'char'}) {
			relog();
		} else {
			aiRemove("move");
			aiRemove("route");
			aiRemove("route_getRoute");
			aiRemove("route_getMapRoute");
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
			$msg .= $message;
		};
		$hook = Log::addHook($hookOutput);
		$interface->writeOutput("console", "$input\n");
	}

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
		parseCommand($input);
	}

	if ($printType) {
		Log::delHook($hook);
		if ($config{'XKore'} && defined $msg) {
			$msg =~ s/\n*$//s;
			$msg =~ s/\n/\\n/g;
			sendMessage(\$remote_socket, "k", $msg);
		}
	}
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

	} elsif ($switch eq "ai") {
		if ($AI) {
			undef $AI;
			$AI_forcedOff = 1;
			message "AI turned off\n", "success";
		} else {
			$AI = 1;
			undef $AI_forcedOff;
			message "AI turned on\n", "success";
		}

	} elsif ($switch eq "aiv") {
		message("ai_seq = @ai_seq\n", "list");
		if ($ai_seq_args[0]{'waitingForMapSolution'}) {
			message("waitingForMapSolution\n", "list");
		}
		if ($ai_seq_args[0]{'waitingForSolution'}) {
			message("waitingForSolution\n", "list");
		}
		if ($ai_seq_args[0]{'solution'}) {
			message("solution\n", "list");
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

	} elsif ($switch eq "auth") {
		($arg1, $arg2) = $input =~ /^[\s\S]*? ([\s\S]*) ([\s\S]*?)$/;
		if ($arg1 eq "" || ($arg2 ne "1" && $arg2 ne "0")) {
			error	"Syntax Error in function 'auth' (Overall Authorize)\n" .
				"Usage: auth <username> <flag>\n";
		} else {
			auth($arg1, $arg2);
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
		
	} elsif ($switch eq "bestow") {
		($arg1) = $input =~ /^[\s\S]*? ([\s\S]*)/;
		if ($currentChatRoom eq "") {
			error	"Error in function 'bestow' (Bestow Admin in Chat)\n" .
				"You are not in a Chat Room.\n";
		} elsif ($arg1 eq "") {
			error	"Syntax Error in function 'bestow' (Bestow Admin in Chat)\n" .
				"Usage: bestow <user #>\n";
		} elsif ($currentChatRoomUsers[$arg1] eq "") {
			error	"Error in function 'bestow' (Bestow Admin in Chat)\n" .
				"Chat Room User $arg1 doesn't exist\n";
		} else {
			sendChatRoomBestow(\$remote_socket, $currentChatRoomUsers[$arg1]);
		}

	} elsif ($switch eq "buy") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		($arg2) = $input =~ /^[\s\S]*? \d+ (\d+)$/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'buy' (Buy Store Item)\n" .
				"Usage: buy <item #> [<amount>]\n";
		} elsif ($storeList[$arg1] eq "") {
			error	"Error in function 'buy' (Buy Store Item)\n" .
				"Store Item $arg1 does not exist.\n";
		} else {
			if ($arg2 <= 0) {
				$arg2 = 1;
			}
			sendBuy(\$remote_socket, $storeList[$arg1]{'nameID'}, $arg2);
		}

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

	} elsif ($switch eq "chatmod") {
		my ($replace, $title) = $input =~ /(^[\s\S]*? \"([\s\S]*?)\" ?)/;
		my $qm = quotemeta $replace;
		my $input =~ s/$qm//;
		my @arg = split / /, $input;
		if ($title eq "") {
			error	"Syntax Error in function 'chatmod' (Modify Chat Room)\n" .
				"Usage: chatmod \"<title>\" [<limit #> <public flag> <password>]\n";
		} else {
			if ($arg[0] eq "") {
				$arg[0] = 20;
			}
			if ($arg[1] eq "") {
				$arg[1] = 1;
			}
			sendChatRoomChange(\$remote_socket, $title, $arg[0], $arg[1], $arg[2]);
		}

	} elsif ($switch eq "chist") { 
    ($arg1) = $input =~ /^[\s\S]*? (\d+)/;
    if ($arg1 eq "") {
      $arg1 = 5;
    }
    
		if (open(CHAT, $Settings::chat_file)) {
			my @chat = <CHAT>;
			close(CHAT);
			message("------ Chat History --------------------\n", "list");
			my $i = @chat - $arg1;
			$i = 0 if ($i < 0);
			for (; $i < @chat;$i++) {
				message($chat[$i], "list");
			}
			message("----------------------------------------\n", "list");
		} else {
			error "Unable to open $Settings::chat_file\n";
		}

	} elsif ($switch eq "cil") { 
		itemLog_clear();
		message("Item log cleared.\n", "success");

	} elsif ($switch eq "cl") { 
		chatLog_clear();
		message("Chat log cleared.\n", "success");

	} elsif ($switch eq "closeshop") {
		sendCloseShop(\$remote_socket);

	} elsif ($switch eq "conf") {
		($arg1) = $input =~ /^[\s\S]*? (\w+)/;
		($arg2) = $input =~ /^[\s\S]*? \w+ ([\s\S]+)$/;
		@{$ai_v{'temp'}{'conf'}} = keys %config;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'conf' (Config Modify)\n" .
				"Usage: conf <variable> [<value>]\n";
		} elsif (binFind(\@{$ai_v{'temp'}{'conf'}}, $arg1) eq "") {
			error "Config variable $arg1 doesn't exist\n";
		} elsif ($arg2 eq "value") {
			message("Config '$arg1' is $config{$arg1}\n", "info");
		} else {
			configModify($arg1, $arg2);
		}

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

	} elsif ($switch eq "debug") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		if ($arg1 eq "0") {
			configModify("debug", 0);
		} elsif ($arg1 eq "1") {
			configModify("debug", 1);
		} elsif ($arg1 eq "2") {
			configModify("debug", 2);
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

	} elsif ($switch eq "e") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		if ($arg1 eq "" || $arg1 > 33 || $arg1 < 0) {
			error	"Syntax Error in function 'e' (Emotion)\n" .
				"Usage: e <emotion # (0-33)>\n";
		} else {
			sendEmotion(\$remote_socket, $arg1);
		}

	} elsif ($switch eq "eq") {
		my ($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		my ($arg2) = $input =~ /^[\s\S]*? \d+ (\w+)/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'equip' (Equip Inventory Item)\n" .
				"Usage: equip <item #> [r]\n";
		} elsif (!%{$chars[$config{'char'}]{'inventory'}[$arg1]}) {
			error	"Error in function 'equip' (Equip Inventory Item)\n" .
				"Inventory Item $arg1 does not exist.\n";
		} elsif ($chars[$config{'char'}]{'inventory'}[$arg1]{'type_equip'} == 0 && $chars[$config{'char'}]{'inventory'}[$arg1]{'type'} != 10) {
			error	"Error in function 'equip' (Equip Inventory Item)\n" .
				"Inventory Item $arg1 can't be equipped.\n";
		} else {
			sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$arg1]{'index'}, $chars[$config{'char'}]{'inventory'}[$arg1]{'type_equip'});
		}

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
		} elsif ($playersID[$arg1] eq "") {
			error	"Error in function 'follow' (Follow Player)\n" .
				"Player $arg1 does not exist.\n";
		} else {
			ai_follow($players{$playersID[$arg1]}{'name'});
			configModify("follow", 1);
			configModify("followTarget", $players{$playersID[$arg1]}{'name'});
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

	} elsif ($switch eq "i") {
		($arg1) = $input =~ /^[\s\S]*? (\w+)/;
		($arg2) = $input =~ /^[\s\S]*? \w+ (\d+)/;
		if ($arg1 eq "" || $arg1 eq "eq" || $arg1 eq "u" || $arg1 eq "nu") {
			my @useable;
			my @equipment;
			my @non_useable;
			for ($i = 0; $i < @{$chars[$config{'char'}]{'inventory'}};$i++) {
				next if (!%{$chars[$config{'char'}]{'inventory'}[$i]});
				if ($chars[$config{'char'}]{'inventory'}[$i]{'type_equip'} != 0) {
					push @equipment, $i;
				} elsif ($chars[$config{'char'}]{'inventory'}[$i]{'type'} <= 2) {
					push @useable, $i;
				} else {
					push @non_useable, $i;
				} 
			}

			message("-----------Inventory-----------\n", "list");
			if ($arg1 eq "" || $arg1 eq "eq") {
				message("-- Equipment --\n", "list");
				for ($i = 0; $i < @equipment; $i++) {
					$display = $chars[$config{'char'}]{'inventory'}[$equipment[$i]]{'name'};
					$display .= " ($itemTypes_lut{$chars[$config{'char'}]{'inventory'}[$equipment[$i]]{'type'}})";

					if ($chars[$config{'char'}]{'inventory'}[$equipment[$i]]{'equipped'}) {
						$display .= " -- Eqp: $equipTypes_lut{$chars[$config{'char'}]{'inventory'}[$equipment[$i]]{'type_equip'}}";
					}

					if (!$chars[$config{'char'}]{'inventory'}[$equipment[$i]]{'identified'}) {
						$display .= " -- Not Identified";
					}
					$index = $equipment[$i];

					message(swrite(
						"@<<< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<",
						[$index, $display]),
						"list");
				}
			}
			if ($arg1 eq "" || $arg1 eq "nu") {
				message("-- Non-Useable --\n", "list");
				for ($i = 0; $i < @non_useable; $i++) {
					$display = $chars[$config{'char'}]{'inventory'}[$non_useable[$i]]{'name'};
					$display .= " x $chars[$config{'char'}]{'inventory'}[$non_useable[$i]]{'amount'}";
					$index = $non_useable[$i];
					message(swrite(
						"@<<< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<",
						[$index, $display]),
						"list");
				}
			}
			if ($arg1 eq "" || $arg1 eq "u") {
				message("-- Useable --\n", "list");
				for ($i = 0; $i < @useable; $i++) {
					$display = $chars[$config{'char'}]{'inventory'}[$useable[$i]]{'name'};
					$display .= " x $chars[$config{'char'}]{'inventory'}[$useable[$i]]{'amount'}";
					$index = $useable[$i];
					message(swrite(
						"@<<< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<",
						[$index, $display]),
						"list");
				}
			}
			message("-------------------------------\n", "list");

		} elsif ($arg1 eq "desc" && $arg2 =~ /\d+/ && $chars[$config{'char'}]{'inventory'}[$arg2] eq "") {
			error	"Error in function 'i' (Inventory Item Desciption)\n" .
				"Inventory Item $arg2 does not exist\n";
		} elsif ($arg1 eq "desc" && $arg2 =~ /\d+/) {
			printItemDesc($chars[$config{'char'}]{'inventory'}[$arg2]{'nameID'});

		} else {
			error	"Syntax Error in function 'i' (Inventory List)\n" .
				"Usage: i [<u|eq|nu|desc>] [<inventory #>]\n";
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


	} elsif ($switch eq "ignore") {
		($arg1, $arg2) = $input =~ /^[\s\S]*? (\d+) ([\s\S]*)/;
		if ($arg1 eq "" || $arg2 eq "" || ($arg1 ne "0" && $arg1 ne "1")) {
			error	"Syntax Error in function 'ignore' (Ignore Player/Everyone)\n" .
				"Usage: ignore <flag> <name | all>\n";
		} else {
			if ($arg2 eq "all") {
				sendIgnoreAll(\$remote_socket, !$arg1);
			} else {
				sendIgnore(\$remote_socket, $arg2, !$arg1);
			}
		}

	} elsif ($switch eq "il") {
		message("-----------Item List-----------\n" .
			"#    Name                      \n",
			"list");
		for (my $i = 0; $i < @itemsID; $i++) {
			next if ($itemsID[$i] eq "");
			$display = $items{$itemsID[$i]}{'name'};
			$display .= " x $items{$itemsID[$i]}{'amount'}";
			message(swrite(
				"@<<< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<",
				[$i, $display]),
				"list");
		}
		message("-------------------------------\n", "list");

	} elsif ($switch eq "im") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		($arg2) = $input =~ /^[\s\S]*? \d+ (\d+)/;
		if ($arg1 eq "" || $arg2 eq "") {
			error	"Syntax Error in function 'im' (Use Item on Monster)\n" .
				"Usage: im <item #> <monster #>\n";
		} elsif (!%{$chars[$config{'char'}]{'inventory'}[$arg1]}) {
			error	"Error in function 'im' (Use Item on Monster)\n" .
				"Inventory Item $arg1 does not exist.\n";
		} elsif ($chars[$config{'char'}]{'inventory'}[$arg1]{'type'} > 2) {
			error	"Error in function 'im' (Use Item on Monster)\n" .
				"Inventory Item $arg1 is not of type Usable.\n";
		} elsif ($monstersID[$arg2] eq "") {
			error	"Error in function 'im' (Use Item on Monster)\n" .
				"Monster $arg2 does not exist.\n";
		} else {
			sendItemUse(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$arg1]{'index'}, $monstersID[$arg2]);
		}

	} elsif ($switch eq "ip") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		($arg2) = $input =~ /^[\s\S]*? \d+ (\d+)/;
		if ($arg1 eq "" || $arg2 eq "") {
			error	"Syntax Error in function 'ip' (Use Item on Player)\n" .
				"Usage: ip <item #> <player #>\n";
		} elsif (!%{$chars[$config{'char'}]{'inventory'}[$arg1]}) {
			error	"Error in function 'ip' (Use Item on Player)\n" .
				"Inventory Item $arg1 does not exist.\n";
		} elsif ($chars[$config{'char'}]{'inventory'}[$arg1]{'type'} > 2) {
			error	"Error in function 'ip' (Use Item on Player)\n" .
				"Inventory Item $arg1 is not of type Usable.\n";
		} elsif ($playersID[$arg2] eq "") {
			error	"Error in function 'ip' (Use Item on Player)\n" .
				"Player $arg2 does not exist.\n";
		} else {
			sendItemUse(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$arg1]{'index'}, $playersID[$arg2]);
		}

	} elsif ($switch eq "is") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'is' (Use Item on Self)\n" .
				"Usage: is <item #>\n";
		} elsif (!%{$chars[$config{'char'}]{'inventory'}[$arg1]}) {
			error	"Error in function 'is' (Use Item on Self)\n" .
				"Inventory Item $arg1 does not exist.\n";
		} elsif ($chars[$config{'char'}]{'inventory'}[$arg1]{'type'} > 2) {
			error	"Error in function 'is' (Use Item on Self)\n" .
				"Inventory Item $arg1 is not of type Usable.\n";
		} else {
			sendItemUse(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$arg1]{'index'}, $accountID);
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

	} elsif ($switch eq "leave") {
		if ($currentChatRoom eq "") {
			error	"Error in function 'leave' (Leave Chat Room)\n" .
				"You are not in a Chat Room.\n";
		} else {
			sendChatRoomLeave(\$remote_socket);
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

	} elsif ($switch eq "memo") {
		sendMemo(\$remote_socket);

	} elsif ($switch eq "ml") {
		my ($dmgTo, $dmgFrom, $dist, $pos);
		message("-----------Monster List-----------\n" .
			"#    Name                     DmgTo    DmgFrom    Distance    Coordinates\n",
			"list");
		for (my $i = 0; $i < @monstersID; $i++) {
			next if ($monstersID[$i] eq "");
			$dmgTo = ($monsters{$monstersID[$i]}{'dmgTo'} ne "")
				? $monsters{$monstersID[$i]}{'dmgTo'}
				: 0;
			$dmgFrom = ($monsters{$monstersID[$i]}{'dmgFrom'} ne "")
				? $monsters{$monstersID[$i]}{'dmgFrom'}
				: 0;
			$dist = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$monsters{$monstersID[$i]}{'pos_to'}});
			$dist = sprintf ("%.1f", $dist) if (index($dist, '.') > -1);
			$pos = '(' . $monsters{$monstersID[$i]}{'pos_to'}{'x'} . ', ' . $monsters{$monstersID[$i]}{'pos_to'}{'y'} . ')';

			message(swrite(
				"@<<< @<<<<<<<<<<<<<<<<<<<<<<< @<<<<    @<<<<      @<<<<<      @<<<<<<<<<<",
				[$i, $monsters{$monstersID[$i]}{'name'}, $dmgTo, $dmgFrom, $dist, $pos]),
				"list");
		}
		message("----------------------------------\n", "list");

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
			aiRemove("route_getRoute");
			aiRemove("route_getMapRoute");
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
				ai_route(\%{$ai_v{'temp'}{'returnHash'}}, $ai_v{'temp'}{'x'}, $ai_v{'temp'}{'y'}, $ai_v{'temp'}{'map'}, 0, 0, 1, 0, 0, 1);
			} else {
				error "Map $ai_v{'temp'}{'map'} does not exist\n";
			}
		}

	} elsif ($switch eq "nl") {
		message("-----------NPC List-----------\n" .
			"#    Name                         Coordinates   ID\n",
			"list");
		for (my $i = 0; $i < @npcsID; $i++) {
			next if ($npcsID[$i] eq "");
			my $pos = "($npcs{$npcsID[$i]}{'pos'}{'x'}, $npcs{$npcsID[$i]}{'pos'}{'y'})";
			message(swrite(
				"@<<< @<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<   @<<<<<<<<",
				[$i, $npcs{$npcsID[$i]}{'name'}, $pos, $npcs{$npcsID[$i]}{'nameID'}]),
				"list");
		}
		message("---------------------------------\n", "list");

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
			error	"Syntax Error in function 'party join' (Accept/Deny Party Join Request)\n"
				,"Usage: party join <flag>\n";
		} elsif ($arg1 eq "join" && $incomingParty{'ID'} eq "") {
			error	"Error in function 'party join' (Join/Request to Join Party)\n"
				,"Can't accept/deny party request - no incoming request.\n";
		} elsif ($arg1 eq "join") {
			sendPartyJoin(\$remote_socket, $incomingParty{'ID'}, $arg2);
			undef %incomingParty;

		} elsif ($arg1 eq "request" && !%{$chars[$config{'char'}]{'party'}}) {
			error	"Error in function 'party request' (Request to Join Party)\n"
				,"Can't request a join - you're not in a party.\n";
		} elsif ($arg1 eq "request" && $playersID[$arg2] eq "") {
			error	"Error in function 'party request' (Request to Join Party)\n"
				,"Can't request to join party - player $arg2 does not exist.\n";
		} elsif ($arg1 eq "request") {
			sendPartyJoinRequest(\$remote_socket, $playersID[$arg2]);


		} elsif ($arg1 eq "leave" && !%{$chars[$config{'char'}]{'party'}}) {
			error	"Error in function 'party leave' (Leave Party)\n"
				,"Can't leave party - you're not in a party.\n";
		} elsif ($arg1 eq "leave") {
			sendPartyLeave(\$remote_socket);


		} elsif ($arg1 eq "share" && !%{$chars[$config{'char'}]{'party'}}) {
			error	"Error in function 'party share' (Set Party Share EXP)\n"
				,"Can't set share - you're not in a party.\n";
		} elsif ($arg1 eq "share" && $arg2 ne "1" && $arg2 ne "0") {
			error	"Syntax Error in function 'party share' (Set Party Share EXP)\n"
				,"Usage: party share <flag>\n";
		} elsif ($arg1 eq "share") {
			sendPartyShareEXP(\$remote_socket, $arg2);


		} elsif ($arg1 eq "kick" && !%{$chars[$config{'char'}]{'party'}}) {
			error	"Error in function 'party kick' (Kick Party Member)\n"
				,"Can't kick member - you're not in a party.\n";
		} elsif ($arg1 eq "kick" && $arg2 eq "") {
			error	"Syntax Error in function 'party kick' (Kick Party Member)\n"
				,"Usage: party kick <party member #>\n";
		} elsif ($arg1 eq "kick" && $partyUsersID[$arg2] eq "") {
			error	"Error in function 'party kick' (Kick Party Member)\n"
				,"Can't kick member - member $arg2 doesn't exist.\n";
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

	} elsif ($switch eq "pl") {
		message("-----------Player List-----------\n" .
			"#    Name                                    Sex   Job         Dist  Coord\n",
			"list");
		for (my $i = 0; $i < @playersID; $i++) {
			next if ($playersID[$i] eq "");
			my ($name, $dist, $pos);
			if (%{$players{$playersID[$i]}{'guild'}}) {
				$name = "$players{$playersID[$i]}{'name'} [$players{$playersID[$i]}{'guild'}{'name'}]";
			} else {
				$name = $players{$playersID[$i]}{'name'};
			}
			$dist = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$players{$playersID[$i]}{'pos_to'}});
			$dist = sprintf ("%.1f", $dist) if (index ($dist, '.') > -1);
			$pos = '(' . $players{$playersID[$i]}{'pos_to'}{'x'} . ', ' . $players{$playersID[$i]}{'pos_to'}{'y'} . ')';

			message(swrite(
				"@<<< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<< @<<<<<<<<<< @<<<< @<<<<<<<<<<",
				[$i, $name, $sex_lut{$players{$playersID[$i]}{'sex'}}, $jobs_lut{$players{$playersID[$i]}{'jobID'}}, $dist, $pos]),
				"list");
		}
		message("---------------------------------\n", "list");

	} elsif ($switch eq "portals") {
		message("-----------Portal List-----------\n" .
			"#    Name                                Coordinates\n",
			"list");
		for (my $i = 0; $i < @portalsID; $i++) {
			next if ($portalsID[$i] eq "");
			my $coords = "($portals{$portalsID[$i]}{'pos'}{'x'},$portals{$portalsID[$i]}{'pos'}{'y'})";
			message(swrite(
				"@<<< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<",
				[$i, $portals{$portalsID[$i]}{'name'}, $coords]),
				"list");
		}
		message("---------------------------------\n", "list");

	} elsif ($switch eq "quit") {
		quit();

	} elsif ($switch eq "rc") {
		($args) = $input =~ /^[\s\S]*? ([\s\S]*)/;
		if ($args ne "") {
			Modules::reload($args, 1);

		} else {
			my $ok = 1;

			if (! -f 'functions.pl') {
				$ok = 0;
				error "Unable to reload code: functions.pl does not exist";
			} elsif (-f $Config{'perlpath'}) {
				$ok = 0;
				message "Checking functions.pl for errors...\n", "info";
				system($Config{'perlpath'}, '-c', 'functions.pl');
				if ($? == -1) {
					error "Error: failed to execute $Config{'perlpath'}\n";
				} elsif ($? & 127) {
					error "Error: $Config{'perlpath'} exited abnormally\n";
				} elsif (($? >> 8) == 0) {
					message("functions.pl passed syntax check.\n", "success");
					$ok = 1;
				} else {
					error "Error: functions.pl contains syntax errors.\n";
				}
			}

			if ($ok) {
				message("Reloading functions.pl...\n", "info");
				if (!do 'functions.pl' || $@) {
					error "Unable to reload functions.pl\n";
					error("$@\n", "syntax", 1) if ($@);
				}
			}
		}

	} elsif ($switch eq "reload") {
		($arg1) = $input =~ /^[\s\S]*? ([\s\S]*)/;
		parseReload($arg1);

	} elsif ($switch eq "relog") {
		relog();

	} elsif ($switch eq "respawn") {
		useTeleport(2);

	} elsif ($switch eq "s") {
		my ($baseEXPKill, $jobEXPKill);

		if ($chars[$config{'char'}]{'exp_last'} > $chars[$config{'char'}]{'exp'}) {
			$baseEXPKill = $chars[$config{'char'}]{'exp_max_last'} - $chars[$config{'char'}]{'exp_last'} + $chars[$config{'char'}]{'exp'};
		} elsif ($chars[$config{'char'}]{'exp_last'} == 0 && $chars[$config{'char'}]{'exp_max_last'} == 0) {
			$baseEXPKill = 0;
		} else {
			$baseEXPKill = $chars[$config{'char'}]{'exp'} - $chars[$config{'char'}]{'exp_last'};
		}
		if ($chars[$config{'char'}]{'exp_job_last'} > $chars[$config{'char'}]{'exp_job'}) {
			$jobEXPKill = $chars[$config{'char'}]{'exp_job_max_last'} - $chars[$config{'char'}]{'exp_job_last'} + $chars[$config{'char'}]{'exp_job'};
		} elsif ($chars[$config{'char'}]{'exp_job_last'} == 0 && $chars[$config{'char'}]{'exp_job_max_last'} == 0) {
			$jobEXPKill = 0;
		} else {
			$jobEXPKill = $chars[$config{'char'}]{'exp_job'} - $chars[$config{'char'}]{'exp_job_last'};
		}

		my ($hp_string, $sp_string, $base_string, $job_string, $weight_string, $job_name_string, $zeny_string);

		$hp_string = $chars[$config{'char'}]{'hp'}."/".$chars[$config{'char'}]{'hp_max'}." ("
				.int($chars[$config{'char'}]{'hp'}/$chars[$config{'char'}]{'hp_max'} * 100)
				."%)" if $chars[$config{'char'}]{'hp_max'};
		$sp_string = $chars[$config{'char'}]{'sp'}."/".$chars[$config{'char'}]{'sp_max'}." ("
				.int($chars[$config{'char'}]{'sp'}/$chars[$config{'char'}]{'sp_max'} * 100)
				."%)" if $chars[$config{'char'}]{'sp_max'};
		$base_string = $chars[$config{'char'}]{'exp'}."/".$chars[$config{'char'}]{'exp_max'}." /$baseEXPKill ("
				.sprintf("%.2f",$chars[$config{'char'}]{'exp'}/$chars[$config{'char'}]{'exp_max'} * 100)
				."%)" if $chars[$config{'char'}]{'exp_max'};
		$job_string = $chars[$config{'char'}]{'exp_job'}."/".$chars[$config{'char'}]{'exp_job_max'}." /$jobEXPKill ("
				.sprintf("%.2f",$chars[$config{'char'}]{'exp_job'}/$chars[$config{'char'}]{'exp_job_max'} * 100)
				."%)" if $chars[$config{'char'}]{'exp_job_max'};
		$weight_string = $chars[$config{'char'}]{'weight'}."/".$chars[$config{'char'}]{'weight_max'}." ("
				.int($chars[$config{'char'}]{'weight'}/$chars[$config{'char'}]{'weight_max'} * 100)
				."%)" if $chars[$config{'char'}]{'weight_max'};
		$job_name_string = "$jobs_lut{$chars[$config{'char'}]{'jobID'}} $sex_lut{$chars[$config{'char'}]{'sex'}}";
		$zeny_string = formatNumber($chars[$config{'char'}]{'zenny'}) if (defined($chars[$config{'char'}]{'zenny'}));

		message("-----------Status-----------\n", "info");
		message(swrite(
			"@<<<<<<<<<<<<<<<<<<<<<<<< HP: @<<<<<<<<<<<<<<<<<<",
			[$chars[$config{'char'}]{'name'}, $hp_string],
			"@<<<<<<<<<<<<<<<<<<<<<<<< SP: @<<<<<<<<<<<<<<<<<<",
			[$job_name_string, $sp_string],
			"Base: @<< @>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>",
			[$chars[$config{'char'}]{'lv'}, $base_string],
			"Job:  @<< @>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>",
			[$chars[$config{'char'}]{'lv_job'}, $job_string],
			"Weight: @>>>>>>>>>>>>>>>> Zenny: @<<<<<<<<<<<<<<",
			[$weight_string, $zeny_string]),
			"info");

		message("----------------------------\n", "info");
		printStat();

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

	} elsif ($switch eq "send") {
		($args) = $input =~ /^[\s\S]*? ([\s\S]*)/;
		sendRaw(\$remote_socket, $args);

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
		aiRemove("route_getRoute");
		aiRemove("route_getMapRoute");
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

	} elsif ($switch eq "skills") {
		($arg1) = $input =~ /^[\s\S]*? (\w+)/;
		($arg2) = $input =~ /^[\s\S]*? \w+ (\d+)/;
		if ($arg1 eq "") {
			message("----------Skill List-----------\n", "list");
			message("#  Skill Name                    Lv     SP\n", "list");
			for (my $i = 0; $i < @skillsID; $i++) {
				message(swrite(
					"@< @<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<    @<<<",
					[$i, $skills_lut{$skillsID[$i]}, $chars[$config{'char'}]{'skills'}{$skillsID[$i]}{'lv'}, $skillsSP_lut{$skillsID[$i]}{$chars[$config{'char'}]{'skills'}{$skillsID[$i]}{'lv'}}]),
					"list");
			}
			message("\nSkill Points: $chars[$config{'char'}]{'points_skill'}\n", "list");
			message("-------------------------------\n", "list");


		} elsif ($arg1 eq "add" && $arg2 =~ /\d+/ && $skillsID[$arg2] eq "") {
			error	"Error in function 'skills add' (Add Skill Point)\n" .
				"Skill $arg2 does not exist.\n";
		} elsif ($arg1 eq "add" && $arg2 =~ /\d+/ && $chars[$config{'char'}]{'points_skill'} < 1) {
			error	"Error in function 'skills add' (Add Skill Point)\n" .
				"Not enough skill points to increase $skills_lut{$skillsID[$arg2]}.\n";
		} elsif ($arg1 eq "add" && $arg2 =~ /\d+/) {
			sendAddSkillPoint(\$remote_socket, $chars[$config{'char'}]{'skills'}{$skillsID[$arg2]}{'ID'});

		} elsif ($arg1 eq "desc" && $arg2 =~ /\d+/ && $skillsID[$arg2] eq "") {
			error	"Error in function 'skills desc' (Skill Description)\n" .
				"Skill $arg2 does not exist.\n";
		} elsif ($arg1 eq "desc" && $arg2 =~ /\d+/) {
			message("===============Skill Description===============\n", "info");
			message("Skill: $skills_lut{$skillsID[$arg2]}\n\n", "info");
			message($skillsDesc_lut{$skillsID[$arg2]}, "info");
			message("==============================================\n", "info");
		} else {
			error	"Syntax Error in function 'skills' (Skills Functions)\n" .
				"Usage: skills [<add | desc>] [<skill #>]\n";
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

	} elsif ($switch eq "st") {
		message("-----------Char Stats-----------\n", "info");
		my $tilde = "~";
		message(swrite(
			"Str: @<<+@<< #@< Atk:  @<<+@<< Def:  @<<+@<<",
			[$chars[$config{'char'}]{'str'}, $chars[$config{'char'}]{'str_bonus'}, $chars[$config{'char'}]{'points_str'}, $chars[$config{'char'}]{'attack'}, $chars[$config{'char'}]{'attack_bonus'}, $chars[$config{'char'}]{'def'}, $chars[$config{'char'}]{'def_bonus'}],
			"Agi: @<<+@<< #@< Matk: @<<@@<< Mdef: @<<+@<<",
			[$chars[$config{'char'}]{'agi'}, $chars[$config{'char'}]{'agi_bonus'}, $chars[$config{'char'}]{'points_agi'}, $chars[$config{'char'}]{'attack_magic_min'}, $tilde, $chars[$config{'char'}]{'attack_magic_max'}, $chars[$config{'char'}]{'def_magic'}, $chars[$config{'char'}]{'def_magic_bonus'}],
			"Vit: @<<+@<< #@< Hit:  @<<     Flee: @<<+@<<",
			[$chars[$config{'char'}]{'vit'}, $chars[$config{'char'}]{'vit_bonus'}, $chars[$config{'char'}]{'points_vit'}, $chars[$config{'char'}]{'hit'}, $chars[$config{'char'}]{'flee'}, $chars[$config{'char'}]{'flee_bonus'}],
			"Int: @<<+@<< #@< Critical: @<< Aspd: @<<",
			[$chars[$config{'char'}]{'int'}, $chars[$config{'char'}]{'int_bonus'}, $chars[$config{'char'}]{'points_int'}, $chars[$config{'char'}]{'critical'}, $chars[$config{'char'}]{'attack_speed'}],
			"Dex: @<<+@<< #@< Status Points: @<<",
			[$chars[$config{'char'}]{'dex'}, $chars[$config{'char'}]{'dex_bonus'}, $chars[$config{'char'}]{'points_dex'}, $chars[$config{'char'}]{'points_free'}],
			"Luk: @<<+@<< #@< Guild: @<<<<<<<<<<<<<<<<<<<<<",
			[$chars[$config{'char'}]{'luk'}, $chars[$config{'char'}]{'luk_bonus'}, $chars[$config{'char'}]{'points_luk'}, $chars[$config{'char'}]{'guild'}{'name'}]),
			"info");
		message("--------------------------------\n", "info");

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

	} elsif ($switch eq "stat_add") {
		($arg1) = $input =~ /^[\s\S]*? ([\s\S]*)$/;
		if ($arg1 ne "str" &&  $arg1 ne "agi" && $arg1 ne "vit" && $arg1 ne "int" 
		 && $arg1 ne "dex" && $arg1 ne "luk") {
			error	"Syntax Error in function 'stat_add' (Add Status Point)\n" .
				"Usage: stat_add <str | agi | vit | int | dex | luk>\n";
		} else {
			my $ID;
			if ($arg1 eq "str") {
				$ID = 0x0D;
			} elsif ($arg1 eq "agi") {
				$ID = 0x0E;
			} elsif ($arg1 eq "vit") {
				$ID = 0x0F;
			} elsif ($arg1 eq "int") {
				$ID = 0x10;
			} elsif ($arg1 eq "dex") {
				$ID = 0x11;
			} elsif ($arg1 eq "luk") {
				$ID = 0x12;
			}
			if ($chars[$config{'char'}]{"points_$arg1"} > $chars[$config{'char'}]{'points_free'}) {
				error	"Error in function 'stat_add' (Add Status Point)\n" .
					"Not enough status points to increase $arg1\n";
			} else {
				$chars[$config{'char'}]{$arg1} += 1;
				sendAddStatusPoint(\$remote_socket, $ID);
			}
		}

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


	} elsif ($switch eq "tank") {
		($arg1) = $input =~ /^[\s\S]*? (\w+)/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'tank' (Tank for a Player)\n" .
				"Usage: tank <player #>\n";
		} elsif ($arg1 eq "stop") {
			configModify("tankMode", 0);
		} elsif ($playersID[$arg1] eq "") {
			error	"Error in function 'tank' (Tank for a Player)\n" .
				"Player $arg1 does not exist.\n";
		} else {
			configModify("tankMode", 1);
			configModify("tankModeTarget", $players{$playersID[$arg1]}{'name'});
		}

	} elsif ($switch eq "tele") {
		useTeleport(1);

	} elsif ($switch eq "timeout") {
		($arg1, $arg2) = $input =~ /^[\s\S]*? ([\s\S]*) ([\s\S]*?)$/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'timeout' (set a timeout)\n" .
				"Usage: timeout <type> [<seconds>]\n";
		} elsif ($timeout{$arg1} eq "") {
			error	"Error in function 'timeout' (set a timeout)\n" .
				"Timeout $arg1 doesn't exist\n";
		} elsif ($arg2 eq "") {
			error "Timeout '$arg1' is $config{$arg1}\n";
		} else {
			setTimeout($arg1, $arg2);
		}


	} elsif ($switch eq "uneq") {
		($arg1) = $input =~ /^[\s\S]*? (\d+)/;
		if ($arg1 eq "") {
			error	"Syntax Error in function 'unequip' (Unequip Inventory Item)\n" .
				"Usage: unequip <item #>\n";
		} elsif (!%{$chars[$config{'char'}]{'inventory'}[$arg1]}) {
			error	"Error in function 'unequip' (Unequip Inventory Item)\n" .
				"Inventory Item $arg1 does not exist.\n";
		} elsif ($chars[$config{'char'}]{'inventory'}[$arg1]{'equipped'} == 0 && $chars[$config{'char'}]{'inventory'}[$arg1]{'type'} != 10) {
			error	"Error in function 'unequip' (Unequip Inventory Item)\n" .
				"Inventory Item $arg1 is not equipped.\n";
		} else {
			sendUnequip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$arg1]{'index'});
		}

	} elsif ($switch eq "warp") {
		my ($map) = $input =~ /^[\s\S]*? ([\s\S]*)/;

		if (!defined $map) {
			error "Error in function 'warp' (Open/List Warp Portal)\n" .
				"Usage: warp <map name|#|list>\n";

		} elsif ($map =~ /^\d$/) {
			if ($map < 0 || $map > @{$chars[$config{'char'}]{'warp'}{'memo'}}) {
				error "Invalid map number $map.\n";
			} else {
				my $name = $chars[$config{'char'}]{'warp'}{'memo'}[$map];
				my $rsw = "$name.rsw";
				message "Attempting to open a warp portal to $maps_lut{$rsw} ($name)\n", "info";
				sendOpenWarp(\$remote_socket, "$name.gat");
			}

		} elsif ($map eq 'list') {
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

		} elsif (!defined $maps_lut{$map.'.rsw'}) {
			error "Map '$map' does not exist.\n";

		} else {
			my $rsw = "$map.rsw";
			message "Attempting to open a warp portal to $maps_lut{$rsw} ($map)\n", "info";
			sendOpenWarp(\$remote_socket, "$map.gat");
		}

	} elsif ($switch eq "where") {
		($map_string) = $map_name =~ /([\s\S]*)\.gat/;
		message("Location $maps_lut{$map_string.'.rsw'}($map_string) : $chars[$config{'char'}]{'pos_to'}{'x'}, $chars[$config{'char'}]{'pos_to'}{'y'}\n", "info");
		message("Last destination calculated : (".int($old_x).", ".int($old_y).") from spot (".int($old_pos_x).", ".int($old_pos_y).").\n", "info");

	} elsif ($switch eq "who") {
		sendWho(\$remote_socket);

	} elsif ($switch eq "v") {
		if ($config{'verbose'}) {
			configModify("verbose", 0);
		} else {
			configModify("verbose", 1);
		}

	} else {
		our $plugin_command_success = 0;
		Plugins::callHook('Command_post', $input);
		if ($plugin_command_success == 0) {
			error "Command seems to not exist in either the standard OpenKore command set, or in a plugin\n";
		}
		
#		We really need a way to allow plugins to retrieve user input, and not return the error message.
#		possibly a standard input.pl plugin, that everyone requiring user input/commands registers a hook in.
#               and if it fails to match a hook there, then the error is displayed.
#               either that, or we move all commands to the plugin system
#		i added this as a command post rather than pre, so a plugin cant override an existing command.

#		ok, this appears to do the trick, but it means that plugin authors adding commands have to change a variable when their plugin accepts the command
#		$main::plugin_command_success = 1;
#		should feature somewhere in their plugin hooked sub.
#		error "Unknown command '$switch'. Please read the documentation for a list of commands.\n";
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
				aiRemove("route_getRoute");
				aiRemove("route_getMapRoute");
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
				parseReload($');
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
				aiRemove("route_getRoute");
				aiRemove("route_getMapRoute");
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
						ai_route(\%{$ai_v{'temp'}{'returnHash'}}, $ai_v{'temp'}{'x'}, $ai_v{'temp'}{'y'}, $ai_v{'temp'}{'map'}, 0, 0, 1, 0, 0, 1);
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

	#dealAuto 1=refuse 2=accept
	if ($config{'dealAuto'} && %incomingDeal && timeOut(\%{$timeout{'ai_dealAuto'}})) {
		if ($config{'dealAuto'}==1) {
			sendDealCancel(\$remote_socket);
		}elsif ($config{'dealAuto'}==2) {
			sendDealAccept(\$remote_socket);
		}
		$timeout{'ai_dealAuto'}{'time'} = time;
	}


	#partyAuto 1=refuse 2=accept
	if ($config{'partyAuto'} && %incomingParty && timeOut(\%{$timeout{'ai_partyAuto'}})) {
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

	if ($ai_v{'portalTrace_mapChanged'}) {
		undef $ai_v{'portalTrace_mapChanged'};
		$ai_v{'temp'}{'first'} = 1;
		undef $ai_v{'temp'}{'foundID'};
		undef $ai_v{'temp'}{'smallDist'};
		
		foreach (@portalsID_old) {
			$ai_v{'temp'}{'dist'} = distance(\%{$chars_old[$config{'char'}]{'pos_to'}}, \%{$portals_old{$_}{'pos'}});
			if ($ai_v{'temp'}{'dist'} <= 7 && ($ai_v{'temp'}{'first'} || $ai_v{'temp'}{'dist'} < $ai_v{'temp'}{'smallDist'})) {
				$ai_v{'temp'}{'smallDist'} = $ai_v{'temp'}{'dist'};
				$ai_v{'temp'}{'foundID'} = $_;
				undef $ai_v{'temp'}{'first'};
			}
		}
		if ($ai_v{'temp'}{'foundID'}) {
			$ai_v{'portalTrace'}{'source'}{'map'} = $portals_old{$ai_v{'temp'}{'foundID'}}{'source'}{'map'};
			$ai_v{'portalTrace'}{'source'}{'ID'} = $portals_old{$ai_v{'temp'}{'foundID'}}{'nameID'};
			%{$ai_v{'portalTrace'}{'source'}{'pos'}} = %{$portals_old{$ai_v{'temp'}{'foundID'}}{'pos'}};
		}
	}

	if (%{$ai_v{'portalTrace'}} && portalExists($ai_v{'portalTrace'}{'source'}{'map'}, \%{$ai_v{'portalTrace'}{'source'}{'pos'}}) ne "") {
		undef %{$ai_v{'portalTrace'}};
	} elsif (%{$ai_v{'portalTrace'}} && $field{'name'}) {
		$ai_v{'temp'}{'first'} = 1;
		undef $ai_v{'temp'}{'foundID'};
		undef $ai_v{'temp'}{'smallDist'};
		
		foreach (@portalsID) {
			$ai_v{'temp'}{'dist'} = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$portals{$_}{'pos'}});
			if ($ai_v{'temp'}{'first'} || $ai_v{'temp'}{'dist'} < $ai_v{'temp'}{'smallDist'}) {
				$ai_v{'temp'}{'smallDist'} = $ai_v{'temp'}{'dist'};
				$ai_v{'temp'}{'foundID'} = $_;
				undef $ai_v{'temp'}{'first'};
			}
		}
		
		if (%{$portals{$ai_v{'temp'}{'foundID'}}}) {
			if (portalExists($field{'name'}, \%{$portals{$ai_v{'temp'}{'foundID'}}{'pos'}}) eq ""
				&& $ai_v{'portalTrace'}{'source'}{'map'} && $ai_v{'portalTrace'}{'source'}{'pos'}{'x'} ne "" && $ai_v{'portalTrace'}{'source'}{'pos'}{'y'} ne ""
				&& $field{'name'} && $portals{$ai_v{'temp'}{'foundID'}}{'pos'}{'x'} ne "" && $portals{$ai_v{'temp'}{'foundID'}}{'pos'}{'y'} ne "") {

				
				$portals{$ai_v{'temp'}{'foundID'}}{'name'} = "$field{'name'} -> $ai_v{'portalTrace'}{'source'}{'map'}";
				$portals{pack("L",$ai_v{'portalTrace'}{'source'}{'ID'})}{'name'} = "$ai_v{'portalTrace'}{'source'}{'map'} -> $field{'name'}";

				$ai_v{'temp'}{'ID'} = "$ai_v{'portalTrace'}{'source'}{'map'} $ai_v{'portalTrace'}{'source'}{'pos'}{'x'} $ai_v{'portalTrace'}{'source'}{'pos'}{'y'}";
				$portals_lut{$ai_v{'temp'}{'ID'}}{'source'}{'map'} = $ai_v{'portalTrace'}{'source'}{'map'};
				%{$portals_lut{$ai_v{'temp'}{'ID'}}{'source'}{'pos'}} = %{$ai_v{'portalTrace'}{'source'}{'pos'}};
				$portals_lut{$ai_v{'temp'}{'ID'}}{'dest'}{'map'} = $field{'name'};
				%{$portals_lut{$ai_v{'temp'}{'ID'}}{'dest'}{'pos'}} = %{$portals{$ai_v{'temp'}{'foundID'}}{'pos'}};

				updatePortalLUT("tables/portals.txt",
					$ai_v{'portalTrace'}{'source'}{'map'}, $ai_v{'portalTrace'}{'source'}{'pos'}{'x'}, $ai_v{'portalTrace'}{'source'}{'pos'}{'y'},
					$field{'name'}, $portals{$ai_v{'temp'}{'foundID'}}{'pos'}{'x'}, $portals{$ai_v{'temp'}{'foundID'}}{'pos'}{'y'});

				$ai_v{'temp'}{'ID2'} = "$field{'name'} $portals{$ai_v{'temp'}{'foundID'}}{'pos'}{'x'} $portals{$ai_v{'temp'}{'foundID'}}{'pos'}{'y'}";
				$portals_lut{$ai_v{'temp'}{'ID2'}}{'source'}{'map'} = $field{'name'};
				%{$portals_lut{$ai_v{'temp'}{'ID2'}}{'source'}{'pos'}} = %{$portals{$ai_v{'temp'}{'foundID'}}{'pos'}};
				$portals_lut{$ai_v{'temp'}{'ID2'}}{'dest'}{'map'} = $ai_v{'portalTrace'}{'source'}{'map'};
				%{$portals_lut{$ai_v{'temp'}{'ID2'}}{'dest'}{'pos'}} = %{$ai_v{'portalTrace'}{'source'}{'pos'}};

				updatePortalLUT("tables/portals.txt",
					$field{'name'}, $portals{$ai_v{'temp'}{'foundID'}}{'pos'}{'x'}, $portals{$ai_v{'temp'}{'foundID'}}{'pos'}{'y'},
					$ai_v{'portalTrace'}{'source'}{'map'}, $ai_v{'portalTrace'}{'source'}{'pos'}{'x'}, $ai_v{'portalTrace'}{'source'}{'pos'}{'y'});
			}
			undef %{$ai_v{'portalTrace'}};
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

	if (($ai_seq[0] eq "" || $ai_seq[0] eq "route") && $config{'storageAuto'} && $config{'storageAuto_npc'} ne ""
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

			if ($config{"getAuto_$i"."_minAmount"} ne "" && $config{"getAuto_$i"."_maxAmount"} ne "" && !$stockVoid[$i]
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
		if (!$config{'storageAuto'} || !%{$npcs_lut{$config{'storageAuto_npc'}}}) {
			$ai_seq_args[0]{'done'} = 1;
			last AUTOSTORAGE;
		}

		undef $ai_v{'temp'}{'do_route'};
		if ($field{'name'} ne $npcs_lut{$config{'storageAuto_npc'}}{'map'}) {
			$ai_v{'temp'}{'do_route'} = 1;
		} else {
			$ai_v{'temp'}{'distance'} = distance(\%{$npcs_lut{$config{'storageAuto_npc'}}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}});
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
				message "Calculating auto-storage route to: $maps_lut{$npcs_lut{$config{'storageAuto_npc'}}{'map'}.'.rsw'}($npcs_lut{$config{'storageAuto_npc'}}{'map'}): $npcs_lut{$config{'storageAuto_npc'}}{'pos'}{'x'}, $npcs_lut{$config{'storageAuto_npc'}}{'pos'}{'y'}\n", "route";
				ai_route(\%{$ai_v{'temp'}{'returnHash'}}, $npcs_lut{$config{'storageAuto_npc'}}{'pos'}{'x'}, $npcs_lut{$config{'storageAuto_npc'}}{'pos'}{'y'}, $npcs_lut{$config{'storageAuto_npc'}}{'map'}, 0, 0, 1, 0, $config{'storageAuto_distance'}, 1);
			}
		} else {
			if ($ai_seq_args[0]{'sentStore'} <= 1) {
				sendTalk(\$remote_socket, pack("L1",$config{'storageAuto_npc'})) if !$ai_seq_args[0]{'sentStore'};
				if ($config{'storageAuto_npc_type'} eq "" || $config{'storageAuto_npc_type'} eq "1") {
					if (!$ai_seq_args[0]{'sentStore'}) {
						if ($config{'storageAuto_npc_type'} eq "") {
							warning "Warning storageAuto has changed. Please read News.txt\n";
						}
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
				}
				@{$ai_seq_args[0]{'steps'}} = split(/ +/, $config{'storageAuto_npc_steps'});
				$timeout{'ai_storageAuto'}{'time'} = time;
				$ai_seq_args[0]{'sentStore'}++;
				last AUTOSTORAGE;
				$ai_seq_args[0]{'step'} = 0;
			} elsif ($ai_seq_args[0]{'steps'}[$ai_seq_args[0]{'step'}]) {
				if ($ai_seq_args[0]{'steps'}[$ai_seq_args[0]{'step'}] =~ /c/i) {
					sendTalkContinue(\$remote_socket, pack("L1",$config{'storageAuto_npc'}));
					debug "Sent Talk Continue.\n", "npc";
				} elsif ($ai_seq_args[0]{'steps'}[$ai_seq_args[0]{'step'}] =~ /n/i) {
					sendTalkCancel(\$remote_socket, pack("L1",$config{'storageAuto_npc'}));
					debug "Sent Talk Cancel.\n", "npc";
				} elsif ($ai_seq_args[0]{'steps'}[$ai_seq_args[0]{'step'}] ne "") {
					($ai_v{'temp'}{'arg'}) = $ai_seq_args[0]{'steps'}[$ai_seq_args[0]{'step'}] =~ /r(\d+)/i;
					if ($ai_v{'temp'}{'arg'} ne "") {
						$ai_v{'temp'}{'arg'}++;
						sendTalkResponse(\$remote_socket, pack("L1",$config{'storageAuto_npc'}), $ai_v{'temp'}{'arg'});
						debug "Sent Talk Responce ".$ai_v{'temp'}{'arg'}."\n", "npc";
					}
				} else {
					undef @{$ai_seq_args[0]{'steps'}};
				}
				$ai_seq_args[0]{'step'}++;
				$timeout{'ai_storageAuto'}{'time'} = time;
				last AUTOSTORAGE;
			}
			$ai_seq_args[0]{'done'} = 1;
			if (!$ai_seq_args[0]{'getStart'}) {
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

			if (!$ai_seq_args[0]{'getStart'} && $ai_seq_args[0]{'done'} == 1) {
				$ai_seq_args[0]{'getStart'} = 1;
				undef $ai_seq_args[0]{'done'};
				last AUTOSTORAGE;
			}
			$i = 0;
			undef $ai_seq_args[0]{'index'};
			while (1) {
				last if (!$config{"getAuto_$i"});
				$ai_seq_args[0]{'invIndex'} = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"getAuto_$i"});
				if (!$ai_seq_args[0]{'index_failed'}{$i} && $config{"getAuto_$i"."_maxAmount"} ne "" && !$stockVoid[$i] && ($ai_seq_args[0]{'invIndex'} eq ""
				   || $chars[$config{'char'}]{'inventory'}[$ai_seq_args[0]{'invIndex'}]{'amount'} < $config{"getAuto_$i"."_maxAmount"})) {
					$ai_seq_args[0]{'index'} = $i;
					last;
				}
				$i++;
			}
			if ($ai_seq_args[0]{'index'} eq ""
			   || ($ai_seq_args[0]{'lastIndex'} ne "" && $ai_seq_args[0]{'lastIndex'} == $ai_seq_args[0]{'index'}
			   && timeOut(\%{$timeout{'ai_storageAuto_giveup'}}))) {
				$ai_seq_args[0]{'done'} = 1;
				sendStorageClose(\$remote_socket);
				last AUTOSTORAGE;
			} elsif ($ai_seq_args[0]{'lastIndex'} eq "" || $ai_seq_args[0]{'lastIndex'} != $ai_seq_args[0]{'index'}) {
				$timeout{'ai_storageAuto_giveup'}{'time'} = time;
			}

			undef $ai_seq_args[0]{'done'};
			undef $ai_seq_args[0]{'storageInvID'};
			$ai_seq_args[0]{'lastIndex'} = $ai_seq_args[0]{'index'};
			$ai_seq_args[0]{'storageInvID'} = findKeyString(\%storage, "name", $config{"getAuto_$ai_seq_args[0]{'index'}"});
			if ($ai_seq_args[0]{'storageInvID'} eq "") {
				$stockVoid[$ai_seq_args[0]{'index'}] = 1;
				last AUTOSTORAGE;
			} elsif ($ai_seq_args[0]{'invIndex'} ne "") {
				if ($config{"getAuto_$ai_seq_args[0]{'index'}"."_maxAmount"} - $chars[$config{'char'}]{'inventory'}[$ai_seq_args[0]{'invIndex'}]{'amount'} > $storage{$ai_seq_args[0]{'storageInvID'}}{'amount'}) {
					$getAmount = $storage{$ai_seq_args[0]{'storageInvID'}}{'amount'};
					$stockVoid[$ai_seq_args[0]{'index'}] = 1;
				} else {
					$getAmount = $config{"getAuto_$ai_seq_args[0]{'index'}"."_maxAmount"} - $chars[$config{'char'}]{'inventory'}[$ai_seq_args[0]{'invIndex'}]{'amount'};
				}
			} else {
				if ($config{"getAuto_$ai_seq_args[0]{'index'}"."_maxAmount"} > $storage{$ai_seq_args[0]{'storageInvID'}}{'amount'}) {
					$getAmount = $storage{$ai_seq_args[0]{'storageInvID'}}{'amount'};
					$stockVoid[$ai_seq_args[0]{'index'}] = 1;
				} else {
					$getAmount = $config{"getAuto_$ai_seq_args[0]{'index'}"."_maxAmount"};
				}
			}
			sendStorageGet(\$remote_socket, $storage{$ai_seq_args[0]{'storageInvID'}}{'index'}, $getAmount);
			$timeout{'ai_storageAuto'}{'time'} = time;
		}
	}

	} #END OF BLOCK AUTOSTORAGE



	#####AUTO SELL#####

	AUTOSELL: {

	if (($ai_seq[0] eq "" || $ai_seq[0] eq "route") && $config{'sellAuto'} && $config{'sellAuto_npc'} ne ""
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
		if (!$config{'sellAuto'} || !%{$npcs_lut{$config{'sellAuto_npc'}}}) {
			$ai_seq_args[0]{'done'} = 1;
			last AUTOSELL;
		}

		undef $ai_v{'temp'}{'do_route'};
		if ($field{'name'} ne $npcs_lut{$config{'sellAuto_npc'}}{'map'}) {
			$ai_v{'temp'}{'do_route'} = 1;
		} else {
			$ai_v{'temp'}{'distance'} = distance(\%{$npcs_lut{$config{'sellAuto_npc'}}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}});
			if ($ai_v{'temp'}{'distance'} > $config{'sellAuto_distance'}) {
				$ai_v{'temp'}{'do_route'} = 1;
			}
		}
		if ($ai_v{'temp'}{'do_route'}) {
			if ($ai_seq_args[0]{'warpedToSave'} && !$ai_seq_args[0]{'mapChanged'}) {
				undef $ai_seq_args[0]{'warpedToSave'};
			}
#Solos Start
			if ($config{'saveMap'} ne "" && $config{'saveMap_warpToBuyOrSell'} && !$ai_seq_args[0]{'warpedToSave'} 
				&& !$cities_lut{$field{'name'}.'.rsw'}) {
				$ai_seq_args[0]{'warpedToSave'} = 1;
				useTeleport(2);
#Solos End
				$timeout{'ai_sellAuto'}{'time'} = time;
			} else {
				message "Calculating auto-sell route to: $maps_lut{$npcs_lut{$config{'sellAuto_npc'}}{'map'}.'.rsw'}($npcs_lut{$config{'sellAuto_npc'}}{'map'}): $npcs_lut{$config{'sellAuto_npc'}}{'pos'}{'x'}, $npcs_lut{$config{'sellAuto_npc'}}{'pos'}{'y'}\n", "route";
				ai_route(\%{$ai_v{'temp'}{'returnHash'}}, $npcs_lut{$config{'sellAuto_npc'}}{'pos'}{'x'}, $npcs_lut{$config{'sellAuto_npc'}}{'pos'}{'y'}, $npcs_lut{$config{'sellAuto_npc'}}{'map'}, 0, 0, 1, 0, $config{'sellAuto_distance'}, 1);
			}
		} else {
			if ($ai_seq_args[0]{'sentSell'} <= 1) {
				sendTalk(\$remote_socket, pack("L1",$config{'sellAuto_npc'})) if !$ai_seq_args[0]{'sentSell'};
				sendGetSellList(\$remote_socket, pack("L1",$config{'sellAuto_npc'})) if $ai_seq_args[0]{'sentSell'};
				$ai_seq_args[0]{'sentSell'}++;
				$timeout{'ai_sellAuto'}{'time'} = time;
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

	if (($ai_seq[0] eq "" || $ai_seq[0] eq "route" 
#Solos Start
	|| $ai_seq[0] eq "attack"
#Solos End
	) && timeOut(\%{$timeout{'ai_buyAuto'}})) {
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
			last if (!$config{"buyAuto_$i"} || !%{$npcs_lut{$config{"buyAuto_$i"."_npc"}}});
			$ai_seq_args[0]{'invIndex'} = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"buyAuto_$i"});
			if (!$ai_seq_args[0]{'index_failed'}{$i} && $config{"buyAuto_$i"."_maxAmount"} ne "" && ($ai_seq_args[0]{'invIndex'} eq "" 
				|| $chars[$config{'char'}]{'inventory'}[$ai_seq_args[0]{'invIndex'}]{'amount'} < $config{"buyAuto_$i"."_maxAmount"})) {
				$ai_seq_args[0]{'index'} = $i;
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
		if ($field{'name'} ne $npcs_lut{$config{"buyAuto_$ai_seq_args[0]{'index'}"."_npc"}}{'map'}) {
			$ai_v{'temp'}{'do_route'} = 1;			
		} else {
			$ai_v{'temp'}{'distance'} = distance(\%{$npcs_lut{$config{"buyAuto_$ai_seq_args[0]{'index'}"."_npc"}}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}});
			if ($ai_v{'temp'}{'distance'} > $config{"buyAuto_$ai_seq_args[0]{'index'}"."_distance"}) {
				$ai_v{'temp'}{'do_route'} = 1;
			}
		}
		if ($ai_v{'temp'}{'do_route'}) {
			if ($ai_seq_args[0]{'warpedToSave'} && !$ai_seq_args[0]{'mapChanged'}) {
				undef $ai_seq_args[0]{'warpedToSave'};
			}
#Solos Start
			if ($config{'saveMap'} ne "" && $config{'saveMap_warpToBuyOrSell'} && !$ai_seq_args[0]{'warpedToSave'} 
				&& !$cities_lut{$field{'name'}.'.rsw'}) {
				$ai_seq_args[0]{'warpedToSave'} = 1;
				useTeleport(2);
#Solos End
				$timeout{'ai_buyAuto_wait'}{'time'} = time;
			} else {
				message qq~Calculating auto-buy route to: $maps_lut{$npcs_lut{$config{"buyAuto_$ai_seq_args[0]{'index'}"."_npc"}}{'map'}.'.rsw'}($npcs_lut{$config{"buyAuto_$ai_seq_args[0]{'index'}"."_npc"}}{'map'}): $npcs_lut{$config{"buyAuto_$ai_seq_args[0]{'index'}"."_npc"}}{'pos'}{'x'}, $npcs_lut{$config{"buyAuto_$ai_seq_args[0]{'index'}"."_npc"}}{'pos'}{'y'}\n~, "route";
				ai_route(\%{$ai_v{'temp'}{'returnHash'}}, $npcs_lut{$config{"buyAuto_$ai_seq_args[0]{'index'}"."_npc"}}{'pos'}{'x'}, $npcs_lut{$config{"buyAuto_$ai_seq_args[0]{'index'}"."_npc"}}{'pos'}{'y'}, $npcs_lut{$config{"buyAuto_$ai_seq_args[0]{'index'}"."_npc"}}{'map'}, 0, 0, 1, 0, $config{"buyAuto_$ai_seq_args[0]{'index'}"."_distance"}, 1);
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

			if ($ai_seq_args[0]{'sentBuy'} <= 1) {
				sendTalk(\$remote_socket, pack("L1",$config{"buyAuto_$ai_seq_args[0]{'index'}"."_npc"})) if !$ai_seq_args[0]{'sentBuy'};
				sendGetStoreList(\$remote_socket, pack("L1",$config{"buyAuto_$ai_seq_args[0]{'index'}"."_npc"})) if $ai_seq_args[0]{'sentBuy'};
				$ai_seq_args[0]{'sentBuy'}++;
				$timeout{'ai_buyAuto_wait'}{'time'} = time;
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
		&& distance(\%{$ai_v{'temp'}{'lockMap_coords'}}, \%{$chars[$config{'char'}]{'pos_to'}}) > 1.42))
	) {
		if ($maps_lut{$config{'lockMap'}.'.rsw'} eq "") {
			error "Invalid map specified for lockMap - map $config{'lockMap'} doesn't exist\n";
		} else {
			if ($config{'lockMap_x'} ne "" && $config{'lockMap_y'} ne "") {
				message "Calculating lockMap route to: $maps_lut{$config{'lockMap'}.'.rsw'}($config{'lockMap'}): $config{'lockMap_x'}, $config{'lockMap_y'}\n", "route";
			} else {
				message "Calculating lockMap route to: $maps_lut{$config{'lockMap'}.'.rsw'}($config{'lockMap'})\n", "route";
			}
			ai_route(\%{$ai_v{'temp'}{'returnHash'}}, $config{'lockMap_x'}, $config{'lockMap_y'}, $config{'lockMap'}, 0, 0, !$config{'attackAuto_inLockOnly'}, 0, 0, 1);
		}
	}
	undef $ai_v{'temp'}{'lockMap_coords'};


	##### RANDOM WALK #####
	if ($config{'route_randomWalk'} && $ai_seq[0] eq "" && @{$field{'field'}} > 1 && !$cities_lut{$field{'name'}.'.rsw'}) {
		do { 
			$ai_v{'temp'}{'randX'} = int(rand() * ($field{'width'} - 1));
			$ai_v{'temp'}{'randY'} = int(rand() * ($field{'height'} - 1));
		} while ($field{'field'}[$ai_v{'temp'}{'randY'}*$field{'width'} + $ai_v{'temp'}{'randX'}]);
		message "Calculating random route to: $maps_lut{$field{'name'}.'.rsw'}($field{'name'}): $ai_v{'temp'}{'randX'}, $ai_v{'temp'}{'randY'}\n", "route";
		ai_route(\%{$ai_v{'temp'}{'returnHash'}}, $ai_v{'temp'}{'randX'}, $ai_v{'temp'}{'randY'}, $field{'name'}, 0, $config{'route_randomWalk_maxRouteTime'}, 2, undef, undef, 1);
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


	if (($ai_seq[0] eq "" || $ai_seq[0] eq "route" || $ai_seq[0] eq "route_getRoute" || $ai_seq[0] eq "route_getMapRoute"
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
				&& (!$config{"useSelf_item_$i"."_inLockOnly"} || ($config{"useSelf_item_$i"."_inLockOnly"} && $field{'name'} eq $config{'lockMap'})))
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
	if (($ai_seq[0] eq "" || $ai_seq[0] eq "route" || $ai_seq[0] eq "route_getRoute" || 
		 $ai_seq[0] eq "route_getMapRoute" || $ai_seq[0] eq "follow" || $ai_seq[0] eq "sitAuto" || 
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


	if ($ai_seq[0] eq "" || $ai_seq[0] eq "route" || $ai_seq[0] eq "route_getRoute" || $ai_seq[0] eq "route_getMapRoute" 
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
			 && (!$config{"useSelf_skill_$i"."_maxAggressives"} || $config{"useSelf_skill_$i"."_maxAggressives"} >= ai_getAggressives())) {
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


	#will doing this event if set only one config
	if ( $config{'partySkill_0'} && %{$chars[$config{'char'}]{'party'}} && ($ai_seq[0] eq "" || $ai_seq[0] eq "route" 
		|| $ai_seq[0] eq "route_getRoute" || $ai_seq[0] eq "route_getMapRoute"
		|| $ai_seq[0] eq "follow" || $ai_seq[0] eq "sitAuto" || $ai_seq[0] eq "take" || $ai_seq[0] eq "items_gather" 
		|| $ai_seq[0] eq "items_take" || $ai_seq[0] eq "attack") ){
		my $i = 0;
		undef $ai_v{'partySkill'};
		undef $ai_v{'partySkill_lvl'};
		my $partyTargetID;
		my $partyTarget_HP_Percent;
		while (defined($config{"partySkill_$i"})) {
			undef $partyTargetID;
			undef $partyTarget_HP_Percent;
			for (my $j = 0; $j < @partyUsersID; $j++) {
				next if ($partyUsersID[$j] eq "");
				if ($config{"partySkill_$i"."_target"} eq $chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$j]}{'name'}
					&& $chars[$config{'char'}]{'party'}{'users'}{$partyUsersID[$j]}{'online'}){
					$partyTargetID = $partyUsersID[$j];
					$partyTarget_HP_Percent = $chars[$config{'char'}]{'party'}{'users'}{$partyTargetID}{'percent_hp'};
					last if (defined($partyTargetID) && defined($partyTarget_HP_Percent));
				}
			}
			#if defined $partyTarget_HP_Percent mean that player is in the screen. else skip to  do think.
			if (defined($partyTargetID) && defined($partyTarget_HP_Percent) 
			&& $partyTarget_HP_Percent <= $config{"partySkill_$i"."_targetHp_upper"} 
			&& $partyTarget_HP_Percent >= $config{"partySkill_$i"."_targetHp_lower"}
			&& percent_sp(\%{$chars[$config{'char'}]}) <= $config{"partySkill_$i"."_sp_upper"} 
			&& percent_sp(\%{$chars[$config{'char'}]}) >= $config{"partySkill_$i"."_sp_lower"}
			&& $chars[$config{'char'}]{'sp'} >= $skillsSP_lut{$skills_rlut{lc($config{"partySkill_$i"})}}{$config{"partySkill_$i"."_lvl"}}
			&& timeOut($ai_v{"partySkill_$i"."_time"},$config{"partySkill_$i"."_timeout"})
			&& !($config{"partySkill_$i"."_stopWhenHit"} && ai_getMonstersWhoHitMe())
			&& (!$config{"partySkill_$i"."_onSit"} || ($config{"partySkill_$i"."_onSit"} && $ai_seq[0] eq "sitAuto"))) {
				$ai_v{"partySkill_$i"."_time"} = time;
				$ai_v{'partySkill'} = $config{"partySkill_$i"};
				$ai_v{'partySkill_target'} = $config{"partySkill_$i"."_target"};
				$ai_v{'partySkill_lvl'} = $config{"partySkill_$i"."_lvl"};
				$ai_v{'partySkill_maxCastTime'} = $config{"partySkill_$i"."_maxCastTime"};
				$ai_v{'partySkill_minCastTime'} = $config{"partySkill_$i"."_minCastTime"};
				last; 
			}
			$i++;
		}
		if ($partyTargetID && $config{'useSelf_skill_smartHeal'} && $skills_rlut{lc($ai_v{'partySkill'})} eq "AL_HEAL") {
			undef $ai_v{'partySkill_smartHeal_lvl'};
			$ai_v{'partySkill_smartHeal_hp_dif'} = $chars[$config{'char'}]{'party'}{'users'}{$partyTargetID}{'hp_max'} - $chars[$config{'char'}]{'party'}{'users'}{$partyTargetID}{'hp'};
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
		if ($ai_v{'partySkill_lvl'} > 0 && $partyTargetID) {
			debug qq~Party Skill used ($chars[$config{'char'}]{'party'}{'users'}{$partyTargetID}{'name'})Skills Used: $skills_lut{$skills_rlut{lc($ai_v{'follow_skill'})}} (lvl $ai_v{'follow_skill_lvl'})\n~ if $config{'debug'};
			if (!ai_getSkillUseType($skills_rlut{lc($ai_v{'partySkill'})})) {
				ai_skillUse($chars[$config{'char'}]{'skills'}{$skills_rlut{lc($ai_v{'partySkill'})}}{'ID'}, $ai_v{'partySkill_lvl'}, $ai_v{'partySkill_maxCastTime'}, $ai_v{'partySkill_minCastTime'}, $partyTargetID);
			} else {
				ai_skillUse($chars[$config{'char'}]{'skills'}{$skills_rlut{lc($ai_v{'partySkill'})}}{'ID'}, $ai_v{'partySkill_lvl'}, $ai_v{'partySkill_maxCastTime'}, $ai_v{'partySkill_minCastTime'}, $chars[$config{'char'}]{'party'}{'users'}{$partyTargetID}{'pos'}{'x'}, $chars[$config{'char'}]{'party'}{'users'}{$partyTargetID}{'pos'}{'y'});
			}
		}
	}


	
	##### FOLLOW #####


	if ($ai_seq[0] eq "" && $config{'follow'}) {
		ai_follow($config{'followTarget'});
	}
	if ($ai_seq[0] eq "follow" && $ai_seq_args[0]{'suspended'}) {
		if ($ai_seq_args[0]{'ai_follow_lost'}) {
			$ai_seq_args[0]{'ai_follow_lost_end'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		}
		undef $ai_seq_args[0]{'suspended'};
	}
	if ($ai_seq[0] eq "follow" && !$ai_seq_args[0]{'ai_follow_lost'}) {
		if (!$ai_seq_args[0]{'following'}) {
			foreach (keys %players) {
				if ($players{$_}{'name'} eq $ai_seq_args[0]{'name'} && !$players{$_}{'dead'}) {
					$ai_seq_args[0]{'ID'} = $_;
					$ai_seq_args[0]{'following'} = 1;
					last;
				}
			}
		}
		if ($ai_seq_args[0]{'following'} && $players{$ai_seq_args[0]{'ID'}}{'pos_to'}) {
			$ai_v{'temp'}{'dist'} = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$players{$ai_seq_args[0]{'ID'}}{'pos_to'}});
			if ($ai_v{'temp'}{'dist'} > $config{'followDistanceMax'}) {
				if ($ai_v{'temp'}{'dist'} > 15) {
					ai_route(\%{$ai_seq_args[0]{'ai_route_returnHash'}}, $players{$ai_seq_args[0]{'ID'}}{'pos_to'}{'x'}, $players{$ai_seq_args[0]{'ID'}}{'pos_to'}{'y'}, $field{'name'}, 0, 0, 1, 0, $config{'followDistanceMin'});
				} else {
					my $dist = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$players{$ai_seq_args[0]{'ID'}}{'pos_to'}});
					my (%vec, %pos);

					getVector(\%vec, \%{$players{$ai_seq_args[0]{'ID'}}{'pos_to'}}, \%{$chars[$config{'char'}]{'pos_to'}});
					moveAlongVector(\%pos, \%{$chars[$config{'char'}]{'pos_to'}}, \%vec, $dist - $config{'followDistanceMin'});
					sendMove(\$remote_socket, $pos{'x'}, $pos{'y'});
				}
			}
		}
		if ($ai_seq_args[0]{'following'} && %{$players{$ai_seq_args[0]{'ID'}}}) {
			if ($config{'followSitAuto'} && $players{$ai_seq_args[0]{'ID'}}{'sitting'} == 1 && $chars[$config{'char'}]{'sitting'} == 0) {
				sit();
			}

			my $dx = $ai_seq_args[0]{'last_pos_to'}{'x'} - $players{$ai_seq_args[0]{'ID'}}{'pos_to'}{'x'};
			my $dy = $ai_seq_args[0]{'last_pos_to'}{'y'} - $players{$ai_seq_args[0]{'ID'}}{'pos_to'}{'y'};
			$ai_seq_args[0]{'last_pos_to'}{'x'} = $players{$ai_seq_args[0]{'ID'}}{'pos_to'}{'x'};
			$ai_seq_args[0]{'last_pos_to'}{'y'} = $players{$ai_seq_args[0]{'ID'}}{'pos_to'}{'y'};
			if ($dx != 0 || $dy != 0) {
				lookAtPosition($players{$ai_seq_args[0]{'ID'}}{'pos_to'}, int(rand(3))) if ($config{'followFaceDirection'});
			}
		}
	}

	if ($ai_seq[0] eq "follow" && $ai_seq_args[0]{'following'} && ($players{$ai_seq_args[0]{'ID'}}{'dead'} || $players_old{$ai_seq_args[0]{'ID'}}{'dead'})) {
		message "Master died.  I'll wait here.\n", "party";
		undef $ai_seq_args[0]{'following'};
	} elsif ($ai_seq[0] eq "follow" && $ai_seq_args[0]{'following'} && !%{$players{$ai_seq_args[0]{'ID'}}}) {
		message "I lost my master\n";
		if ($config{'followBot'}) {
			message "Trying to get him back\n", "party";
			sendMessage(\$remote_socket, "pm", "move $chars[$config{'char'}]{'pos_to'}{'x'} $chars[$config{'char'}]{'pos_to'}{'y'}", $config{followTarget});
		}

		undef $ai_seq_args[0]{'following'};
		if ($players_old{$ai_seq_args[0]{'ID'}}{'disconnected'}) {
			message "My master disconnected\n";

		} elsif ($players_old{$ai_seq_args[0]{'ID'}}{'teleported'}) {
			message "My master teleported\n", "party", 1;

		} elsif ($players_old{$ai_seq_args[0]{'ID'}}{'disappeared'}) {
			message "Trying to find lost master\n", "party", 1;

			undef $ai_seq_args[0]{'ai_follow_lost_char_last_pos'};
			undef $ai_seq_args[0]{'follow_lost_portal_tried'};
			$ai_seq_args[0]{'ai_follow_lost'} = 1;
			$ai_seq_args[0]{'ai_follow_lost_end'}{'timeout'} = $timeout{'ai_follow_lost_end'}{'timeout'};
			$ai_seq_args[0]{'ai_follow_lost_end'}{'time'} = time;
			getVector(\%{$ai_seq_args[0]{'ai_follow_lost_vec'}}, \%{$players_old{$ai_seq_args[0]{'ID'}}{'pos_to'}}, \%{$chars[$config{'char'}]{'pos_to'}});

			#check if player went through portal
			$ai_v{'temp'}{'first'} = 1;
			undef $ai_v{'temp'}{'foundID'};
			undef $ai_v{'temp'}{'smallDist'};
			foreach (@portalsID) {
				$ai_v{'temp'}{'dist'} = distance(\%{$players_old{$ai_seq_args[0]{'ID'}}{'pos_to'}}, \%{$portals{$_}{'pos'}});
				if ($ai_v{'temp'}{'dist'} <= 7 && ($ai_v{'temp'}{'first'} || $ai_v{'temp'}{'dist'} < $ai_v{'temp'}{'smallDist'})) {
					$ai_v{'temp'}{'smallDist'} = $ai_v{'temp'}{'dist'};
					$ai_v{'temp'}{'foundID'} = $_;
					undef $ai_v{'temp'}{'first'};
				}
			}
			$ai_seq_args[0]{'follow_lost_portalID'} = $ai_v{'temp'}{'foundID'};
		} else {
				message "Don't know what happened to Master\n", "party", 1;
		}
	}



	##### FOLLOW-LOST #####


	if ($ai_seq[0] eq "follow" && $ai_seq_args[0]{'ai_follow_lost'}) {
		if ($ai_seq_args[0]{'ai_follow_lost_char_last_pos'}{'x'} == $chars[$config{'char'}]{'pos_to'}{'x'} && $ai_seq_args[0]{'ai_follow_lost_char_last_pos'}{'y'} == $chars[$config{'char'}]{'pos_to'}{'y'}) {
			$ai_seq_args[0]{'lost_stuck'}++;
		} else {
			undef $ai_seq_args[0]{'lost_stuck'};
		}
		%{$ai_seq_args[0]{'ai_follow_lost_char_last_pos'}} = %{$chars[$config{'char'}]{'pos_to'}};

		if (timeOut(\%{$ai_seq_args[0]{'ai_follow_lost_end'}})) {
			undef $ai_seq_args[0]{'ai_follow_lost'};
			message "Couldn't find master, giving up\n", "party";

		} elsif ($players_old{$ai_seq_args[0]{'ID'}}{'disconnected'}) {
			undef $ai_seq_args[0]{'ai_follow_lost'};
			message "My master disconnected\n", "party";

		} elsif ($players_old{$ai_seq_args[0]{'ID'}}{'teleported'}) {
			undef $ai_seq_args[0]{'ai_follow_lost'};
			message "My master teleported\n", "party";

		} elsif (%{$players{$ai_seq_args[0]{'ID'}}}) {
			$ai_seq_args[0]{'following'} = 1;
			undef $ai_seq_args[0]{'ai_follow_lost'};
			message "Found my master!\n", "party"

		} elsif ($ai_seq_args[0]{'lost_stuck'}) {
			if ($ai_seq_args[0]{'follow_lost_portalID'} eq "") {
				moveAlongVector(\%{$ai_v{'temp'}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[0]{'ai_follow_lost_vec'}}, $config{'followLostStep'} / ($ai_seq_args[0]{'lost_stuck'} + 1));
				move($ai_v{'temp'}{'pos'}{'x'}, $ai_v{'temp'}{'pos'}{'y'});
			}
		} else {
			if ($ai_seq_args[0]{'follow_lost_portalID'} ne "") {
				if (%{$portals{$ai_seq_args[0]{'follow_lost_portalID'}}} && !$ai_seq_args[0]{'follow_lost_portal_tried'}) {
					$ai_seq_args[0]{'follow_lost_portal_tried'} = 1;
					%{$ai_v{'temp'}{'pos'}} = %{$portals{$ai_seq_args[0]{'follow_lost_portalID'}}{'pos'}};
					ai_route(\%{$ai_v{'temp'}{'returnHash'}}, $ai_v{'temp'}{'pos'}{'x'}, $ai_v{'temp'}{'pos'}{'y'}, $field{'name'}, 0, 0, 1);
				}
			} else {
				moveAlongVector(\%{$ai_v{'temp'}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[0]{'ai_follow_lost_vec'}}, $config{'followLostStep'});
				move($ai_v{'temp'}{'pos'}{'x'}, $ai_v{'temp'}{'pos'}{'y'});
			}
		}
	}

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

	if (!$ai_v{'sitAuto_forceStop'} && ($ai_seq[0] eq "" || $ai_seq[0] eq "follow" || $ai_seq[0] eq "route" || $ai_seq[0] eq "route_getRoute" || $ai_seq[0] eq "route_getMapRoute") && binFind(\@ai_seq, "attack") eq "" && !ai_getAggressives()
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


	if (($ai_seq[0] eq "" || $ai_seq[0] eq "route" || $ai_seq[0] eq "route_getRoute" || $ai_seq[0] eq "route_getMapRoute" || $ai_seq[0] eq "follow" 
		|| $ai_seq[0] eq "sitAuto" || $ai_seq[0] eq "take" || $ai_seq[0] eq "items_gather" || $ai_seq[0] eq "items_take")
		&& !($config{'itemsTakeAuto'} >= 2 && ($ai_seq[0] eq "take" || $ai_seq[0] eq "items_take"))
		&& !($config{'itemsGatherAuto'} >= 2 && ($ai_seq[0] eq "take" || $ai_seq[0] eq "items_gather"))
		&& timeOut(\%{$timeout{'ai_attack_auto'}})) {
		undef @{$ai_v{'ai_attack_agMonsters'}};
		undef @{$ai_v{'ai_attack_cleanMonsters'}};
		undef @{$ai_v{'ai_attack_partyMonsters'}};
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
				if ((($config{'attackAuto_party'}
					&& $ai_seq[0] ne "take" && $ai_seq[0] ne "items_take"
					&& ($monsters{$_}{'dmgToParty'} > 0 || $monsters{$_}{'dmgFromParty'} > 0))
					|| ($config{'attackAuto_followTarget'} && $ai_v{'temp'}{'ai_follow_following'} 
					&& ($monsters{$_}{'dmgToPlayer'}{$ai_v{'temp'}{'ai_follow_ID'}} > 0 || $monsters{$_}{'missedToPlayer'}{$ai_v{'temp'}{'ai_follow_ID'}} > 0 || $monsters{$_}{'dmgFromPlayer'}{$ai_v{'temp'}{'ai_follow_ID'}} > 0)))
					&& !($ai_v{'temp'}{'ai_route_index'} ne "" && !$ai_v{'temp'}{'ai_route_attackOnRoute'})
					&& $monsters{$_}{'attack_failed'} == 0 && ($mon_control{lc($monsters{$_}{'name'})}{'attack_auto'} >= 1 || $mon_control{lc($monsters{$_}{'name'})}{'attack_auto'} eq "")) {
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
			$ai_v{'temp'}{'first'} = 1;

			# Look for the closest aggressive monster to attack
			foreach (@{$ai_v{'ai_attack_agMonsters'}}) {
				# Don't attack monsters near portals
				next if (positionNearPortal(\%{$monsters{$_}{'pos_to'}}, 4));

				$ai_v{'temp'}{'dist'} = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$monsters{$_}{'pos_to'}});
				if (($ai_v{'temp'}{'first'} || $ai_v{'temp'}{'dist'} < $ai_v{'temp'}{'distSmall'}) && !$monsters{$_}{'state'}) {
					$ai_v{'temp'}{'distSmall'} = $ai_v{'temp'}{'dist'};
					$ai_v{'temp'}{'foundID'} = $_;
					undef $ai_v{'temp'}{'first'};
				}
			}

			if (!$ai_v{'temp'}{'foundID'}) {
				# There are no aggressive monsters; look for the closest monster that a party member is attacking
				undef $ai_v{'temp'}{'distSmall'};
				undef $ai_v{'temp'}{'foundID'};
				$ai_v{'temp'}{'first'} = 1;
				foreach (@{$ai_v{'ai_attack_partyMonsters'}}) {
					$ai_v{'temp'}{'dist'} = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$monsters{$_}{'pos_to'}});
					if (($ai_v{'temp'}{'first'} || $ai_v{'temp'}{'dist'} < $ai_v{'temp'}{'distSmall'}) && !$monsters{$_}{'ignore'} && !$monsters{$_}{'state'}) {
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
				undef $ai_v{'temp'}{'distSmall'};
				undef $ai_v{'temp'}{'foundID'};
				$ai_v{'temp'}{'first'} = 1;
				foreach (@{$ai_v{'ai_attack_cleanMonsters'}}) {
					$ai_v{'temp'}{'dist'} = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$monsters{$_}{'pos_to'}});
					if (($ai_v{'temp'}{'first'} || $ai_v{'temp'}{'dist'} < $ai_v{'temp'}{'distSmall'})
					 && !$monsters{$_}{'ignore'} && !$monsters{$_}{'state'}
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
			attack($ai_v{'temp'}{'foundID'});
		} else {
			$timeout{'ai_attack_auto'}{'time'} = time;
		}
	}




	##### ATTACK #####


	if ($ai_seq[0] eq "attack" && $ai_seq_args[0]{'suspended'}) {
		$ai_seq_args[0]{'ai_attack_giveup'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		undef $ai_seq_args[0]{'suspended'};
	}
	if ($ai_seq[0] eq "attack" && timeOut(\%{$ai_seq_args[0]{'ai_attack_giveup'}})) {
		$monsters{$ai_seq_args[0]{'ID'}}{'attack_failed'}++;
		shift @ai_seq;
		shift @ai_seq_args;
		message "Can't reach or damage target, dropping target\n",,1;

	} elsif ($ai_seq[0] eq "attack" && !%{$monsters{$ai_seq_args[0]{'ID'}}}) {
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
		$ai_v{'temp'}{'ai_follow_index'} = binFind(\@ai_seq, "follow");
		if ($ai_v{'temp'}{'ai_follow_index'} ne "") {
			$ai_v{'temp'}{'ai_follow_following'} = $ai_seq_args[$ai_v{'temp'}{'ai_follow_index'}]{'following'};
			$ai_v{'temp'}{'ai_follow_ID'} = $ai_seq_args[$ai_v{'temp'}{'ai_follow_index'}]{'ID'};
		} else {
			undef $ai_v{'temp'}{'ai_follow_following'};
		}

		$ai_v{'ai_attack_cleanMonster'} = (
				  !($monsters{$ai_seq_args[0]{'ID'}}{'dmgFromYou'} == 0 && ($monsters{$ai_seq_args[0]{'ID'}}{'dmgTo'} > 0 || $monsters{$ai_seq_args[0]{'ID'}}{'dmgFrom'} > 0 || %{$monsters{$ai_seq_args[0]{'ID'}}{'missedFromPlayer'}} || %{$monsters{$ai_seq_args[0]{'ID'}}{'missedToPlayer'}} || %{$monsters{$ai_seq_args[0]{'ID'}}{'castOnByPlayer'}}))
				|| ($config{'attackAuto_party'} && ($monsters{$ai_seq_args[0]{'ID'}}{'dmgFromParty'} > 0 || $monsters{$ai_seq_args[0]{'ID'}}{'dmgToParty'} > 0))
				|| ($config{'attackAuto_followTarget'} && $ai_v{'temp'}{'ai_follow_following'} && ($monsters{$ai_seq_args[0]{'ID'}}{'dmgToPlayer'}{$ai_v{'temp'}{'ai_follow_ID'}} > 0 || $monsters{$ai_seq_args[0]{'ID'}}{'missedToPlayer'}{$ai_v{'temp'}{'ai_follow_ID'}} > 0 || $monsters{$ai_seq_args[0]{'ID'}}{'dmgFromPlayer'}{$ai_v{'temp'}{'ai_follow_ID'}} > 0))
				|| ($monsters{$ai_seq_args[0]{'ID'}}{'dmgToYou'} > 0 || $monsters{$ai_seq_args[0]{'ID'}}{'missedYou'} > 0)
			);
		$ai_v{'ai_attack_cleanMonster'} = 0 if ($monsters{$ai_seq_args[0]{'ID'}}{'attackedByPlayer'});

		$ai_v{'ai_attack_monsterDist'} = distance(\%{$chars[$config{'char'}]{'pos_to'}}, \%{$monsters{$ai_seq_args[0]{'ID'}}{'pos_to'}});

		if ($ai_seq_args[0]{'dmgToYou_last'} != $monsters{$ai_seq_args[0]{'ID'}}{'dmgToYou'}
			|| $ai_seq_args[0]{'missedYou_last'} != $monsters{$ai_seq_args[0]{'ID'}}{'missedYou'}
			|| $ai_seq_args[0]{'dmgFromYou_last'} != $monsters{$ai_seq_args[0]{'ID'}}{'dmgFromYou'}) {
				$ai_seq_args[0]{'ai_attack_giveup'}{'time'} = time;
		}
		$ai_seq_args[0]{'dmgToYou_last'} = $monsters{$ai_seq_args[0]{'ID'}}{'dmgToYou'};
		$ai_seq_args[0]{'missedYou_last'} = $monsters{$ai_seq_args[0]{'ID'}}{'missedYou'};
		$ai_seq_args[0]{'dmgFromYou_last'} = $monsters{$ai_seq_args[0]{'ID'}}{'dmgFromYou'};
		$ai_seq_args[0]{'missedFromYou_last'} = $monsters{$ai_seq_args[0]{'ID'}}{'missedFromYou'};
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
					&& (!$config{"attackSkillSlot_$i"."_monsters"} || existsInList($config{"attackSkillSlot_$i"."_monsters"}, $monsters{$ai_seq_args[0]{'ID'}}{'name'}))) {
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

		} elsif (!$ai_v{'ai_attack_cleanMonster'}) {
			# Drop target if it's already attacked by someone else
			message "Dropping target - you will not kill steal others\n", 1;
			$monsters{$ai_seq_args[0]{'ID'}}{'ignore'} = 1;
			sendAttackStop(\$remote_socket);
			shift @ai_seq;
			shift @ai_seq_args;

		} elsif ($ai_v{'ai_attack_monsterDist'} > $ai_seq_args[0]{'attackMethod'}{'distance'}) {
			# Move to target
			if (%{$ai_seq_args[0]{'char_pos_last'}} && %{$ai_seq_args[0]{'attackMethod_last'}}
				&& $ai_seq_args[0]{'attackMethod_last'}{'distance'} == $ai_seq_args[0]{'attackMethod'}{'distance'}
				&& $ai_seq_args[0]{'char_pos_last'}{'x'} == $chars[$config{'char'}]{'pos_to'}{'x'}
				&& $ai_seq_args[0]{'char_pos_last'}{'y'} == $chars[$config{'char'}]{'pos_to'}{'y'}) {
				$ai_seq_args[0]{'distanceDivide'}++;
			} else {
				$ai_seq_args[0]{'distanceDivide'} = 1;
			}
			if (int($ai_seq_args[0]{'attackMethod'}{'distance'} / $ai_seq_args[0]{'distanceDivide'}) == 0
				|| ($config{'attackMaxRouteDistance'} && $ai_seq_args[0]{'ai_route_returnHash'}{'solutionLength'} > $config{'attackMaxRouteDistance'})
				|| ($config{'attackMaxRouteTime'} && $ai_seq_args[0]{'ai_route_returnHash'}{'solutionTime'} > $config{'attackMaxRouteTime'})) {
				$monsters{$ai_seq_args[0]{'ID'}}{'attack_failed'}++;
				shift @ai_seq;
				shift @ai_seq_args;
				message "Dropping target - couldn't reach target\n",,1;
			} else {
				getVector(\%{$ai_v{'temp'}{'vec'}}, \%{$monsters{$ai_seq_args[0]{'ID'}}{'pos_to'}}, \%{$chars[$config{'char'}]{'pos_to'}});
				moveAlongVector(\%{$ai_v{'temp'}{'pos'}}, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_v{'temp'}{'vec'}},
				                $ai_v{'ai_attack_monsterDist'} - ($ai_seq_args[0]{'attackMethod'}{'distance'} / $ai_seq_args[0]{'distanceDivide'}) + 1);

				%{$ai_seq_args[0]{'char_pos_last'}} = %{$chars[$config{'char'}]{'pos_to'}};
				%{$ai_seq_args[0]{'attackMethod_last'}} = %{$ai_seq_args[0]{'attackMethod'}};

				ai_setSuspend(0);
				if (@{$field{'field'}} > 1) {
					ai_route(\%{$ai_seq_args[0]{'ai_route_returnHash'}}, $ai_v{'temp'}{'pos'}{'x'}, $ai_v{'temp'}{'pos'}{'y'}, $field{'name'}, $config{'attackMaxRouteDistance'}, $config{'attackMaxRouteTime'}, 0, 0, 0, 0, $ai_seq_args[0]{'ID'});
				} else {
					move($ai_v{'temp'}{'pos'}{'x'}, $ai_v{'temp'}{'pos'}{'y'}, 0, $ai_seq_args[0]{'ID'});
				}
			}

		} elsif ((($config{'tankMode'} && $monsters{$ai_seq_args[0]{'ID'}}{'dmgFromYou'} == 0)
		        || !$config{'tankMode'})) {
			# Attack the target. In case of tanking, only attack if it hasn't been hit once.

			if ($ai_seq_args[0]{'attackMethod'}{'type'} eq "weapon" && timeOut(\%{$timeout{'ai_attack'}})) {
				if ($config{'tankMode'}) {
					sendAttack(\$remote_socket, $ai_seq_args[0]{'ID'}, 0);
				} else {
					sendAttack(\$remote_socket, $ai_seq_args[0]{'ID'}, 7);
				}
				$timeout{'ai_attack'}{'time'} = time;
				undef %{$ai_seq_args[0]{'attackMethod'}};
			} elsif ($ai_seq_args[0]{'attackMethod'}{'type'} eq "skill") {
				$ai_v{'ai_attack_method_skillSlot'} = $ai_seq_args[0]{'attackMethod'}{'skillSlot'};
				$ai_v{'ai_attack_ID'} = $ai_seq_args[0]{'ID'};
				undef %{$ai_seq_args[0]{'attackMethod'}};
				ai_setSuspend(0);
				if (!ai_getSkillUseType($skills_rlut{lc($config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"})})) {
					ai_skillUse($chars[$config{'char'}]{'skills'}{$skills_rlut{lc($config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"})}}{'ID'}, $config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_lvl"}, $config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_maxCastTime"}, $config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_minCastTime"}, $ai_v{'ai_attack_ID'});
				} else {
					ai_skillUse($chars[$config{'char'}]{'skills'}{$skills_rlut{lc($config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"})}}{'ID'}, $config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_lvl"}, $config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_maxCastTime"}, $config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_minCastTime"}, $monsters{$ai_v{'ai_attack_ID'}}{'pos_to'}{'x'}, $monsters{$ai_v{'ai_attack_ID'}}{'pos_to'}{'y'});
				}
				debug qq~Auto-skill on monster: $skills_lut{$skills_rlut{lc($config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"})}} (lvl $config{"attackSkillSlot_$ai_v{'ai_attack_method_skillSlot'}"."_lvl"})\n~, "ai";
			}
			
		} elsif ($config{'tankMode'}) {
			if ($ai_seq_args[0]{'dmgTo_last'} != $monsters{$ai_seq_args[0]{'ID'}}{'dmgTo'}) {
				$ai_seq_args[0]{'ai_attack_giveup'}{'time'} = time;
			}
			$ai_seq_args[0]{'dmgTo_last'} = $monsters{$ai_seq_args[0]{'ID'}}{'dmgTo'};
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

			shift @ai_seq;
			shift @ai_seq_args;
			if ($ai_seq[0] eq "route") {
				shift @ai_seq;
				shift @ai_seq_args;
			}
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
		if ($chars[$config{'char'}]{'sitting'}) {
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



	##### ROUTE #####
	#There are three important things that need to be done here:
	#
	#First, calculate the map route to the desired map using the map router (a Perl function that uses 
	#A* pathfinding on the portals), and step through the map solution to get to the map.  The map router returns
	#just an array of portals, so that alone won't do the job.
	#
	#Second, for each portal step we need to use the position router (a C function that uses 
	#A* on the map XY data) to get the position solution to the next portal, then step through that
	#
	#Third, if we are in the desired map and the way is clear, calculate the final route using the position router
	#and step through it.
	#
	#Sometimes we may be in the desired map, but the way to the desired position is blocked by water.
	#If we're in the desired map and the position routing fails, kore calculates a map route to an entrance
	#that can reach the desired location - the map routing function makes sure chosen portals are reachable
	#from our current and desired positions.
	#
	#See also: http://www.gamedev.net/reference/programming/features/motionplanning/

	ROUTE: {

	#The position solution array is an array of XY positions from the current position to the desired position.
	#It's filled by the position router
	#
	#The solution ready flag indicates that we are on the desired map, and the way to the desired position is clear,
	#so the current position solution array is the final solution to be stepped through
	#
	#If we have a solution, and our stepping index is at the end of the solution, and the solution ready flag is set,
	#then we are done
	if ($ai_seq[0] eq "route" && @{$ai_seq_args[0]{'solution'}} && $ai_seq_args[0]{'index'} == @{$ai_seq_args[0]{'solution'}} - 1 && $ai_seq_args[0]{'solutionReady'}) {
		debug "Route success\n", "route";
		shift @ai_seq;
		shift @ai_seq_args;
	} elsif ($ai_seq[0] eq "route" && $ai_seq_args[0]{'failed'}) {
		debug "Route failed\n", "route";
		shift @ai_seq;
		shift @ai_seq_args;
		aiRemove("move");
		aiRemove("route");
		aiRemove("route_getRoute");
		aiRemove("route_getMapRoute");

	#We're about to enter the main function, but first we gotta check a timeout.
	#If we're talking to an NPC, we do one NPC talk-step each time this function runs, then wait a second or so.
	#Its not safe to flood the NPC with requests.  Here we check that npc talk timeout, if all is good, then enter
	} elsif ($ai_seq[0] eq "route" && timeOut(\%{$timeout{'ai_route_npcTalk'}})) {
		#if we don't know the current map name, bail out and try again later.
		last ROUTE if (!$field{'name'});
		#When we request a map solution, we give a reference to our array to the map router, exit the function
		#and by the time we get back the map solution should be ready (due to the AI queue).
		#
		#If we requested a map solution and the solution came back empty, we've failed.
		#That "NPC talk - route failed" is a mistake I think, it should just be "route failed"
		if ($ai_seq_args[0]{'waitingForMapSolution'}) {
			undef $ai_seq_args[0]{'waitingForMapSolution'};
			if (!@{$ai_seq_args[0]{'mapSolution'}}) {
				debug "NPC talk - route failed\n", "route";
				$ai_seq_args[0]{'failed'} = 1;
				last ROUTE;
			}
			$ai_seq_args[0]{'mapIndex'} = -1;
		}
		#If we were waiting for a position solution (not map solution) last time we exited the function...
		if ($ai_seq_args[0]{'waitingForSolution'}) {
			undef $ai_seq_args[0]{'waitingForSolution'};

			#The distFromGoal is a feature so that Kore will stay a certain distance from the
			#desired position.  If you set Kore to follow, you don't want Kore to follow directly behind you
			#but rather stay a certain distance back

			#Here we are checking if the current position solution is the final solution, we don't want to
			#"follow behind" when the position solution is to get from portal A to portal B (from a map
			#solution)
			#
			#We are at a final solution if the current map name is the destination map, and there is either no
			#map solution or we're at the last step of the map solution.
			if ($ai_seq_args[0]{'distFromGoal'} && $field{'name'} && $ai_seq_args[0]{'dest_map'} eq $field{'name'} 
			    && (!@{$ai_seq_args[0]{'mapSolution'}} || $ai_seq_args[0]{'mapIndex'} == @{$ai_seq_args[0]{'mapSolution'}} - 1)) {
				#We achieve this follow behind thing by popping off the last steps from the position solution
				for ($i = 0; $i < $ai_seq_args[0]{'distFromGoal'}; $i++) {
					pop @{$ai_seq_args[0]{'solution'}};
				}

				#Store the REAL desired position values, and replace them with the "follow behind" desired
				#position.  This is to satisfy some "are we done?" checks
				if (@{$ai_seq_args[0]{'solution'}}) {
					$ai_seq_args[0]{'dest_x_original'} = $ai_seq_args[0]{'dest_x'};
					$ai_seq_args[0]{'dest_y_original'} = $ai_seq_args[0]{'dest_y'};
					$ai_seq_args[0]{'dest_x'} = $ai_seq_args[0]{'solution'}[@{$ai_seq_args[0]{'solution'}}-1]{'x'};
					$ai_seq_args[0]{'dest_y'} = $ai_seq_args[0]{'solution'}[@{$ai_seq_args[0]{'solution'}}-1]{'y'};
				}
			}

			#Get length and time it took to get this position solution.  This is stored in a return hash,
			#and returned to functions that call ai_route.  This should really be a += not =, cuz there can
			#be multiple position solutions calculated before we come to the final solution.
			$ai_seq_args[0]{'returnHash'}{'solutionLength'} = @{$ai_seq_args[0]{'solution'}};
			$ai_seq_args[0]{'returnHash'}{'solutionTime'} = time - $ai_seq_args[0]{'time_getRoute'};

			#check if the solution length exceeds some user set length
			if ($ai_seq_args[0]{'maxRouteDistance'} && @{$ai_seq_args[0]{'solution'}} > $ai_seq_args[0]{'maxRouteDistance'}) {
				debug "Solution length - route failed\n", "route";
				$ai_seq_args[0]{'failed'} = 1;
				last ROUTE;
			}

			#If we're on the desired map, and the solution failed, there may be water or a wall blocking the
			#way.  So we may have to either use portals in this map to get to the position (ie. prontera
			#sewers), or take some long route from map to map to get there. We need to do a more extensive
			#search.
			#
			#This extensive search "checkInnerPortals" means "consult the map router", it should actually
			#be the only type of search, but at the time of writing (before the DLL) it was slow, so it's 
			#a variable set by the caller.
			#
			#So, if we require a more extensive search, and we haven't already tried....
			if (!@{$ai_seq_args[0]{'solution'}} && !@{$ai_seq_args[0]{'mapSolution'}} && $ai_seq_args[0]{'dest_map'} eq $field{'name'} && $ai_seq_args[0]{'checkInnerPortals'} && !$ai_seq_args[0]{'checkInnerPortals_done'}) {
				$ai_seq_args[0]{'checkInnerPortals_done'} = 1;
				debug "Route Logic - check inner portals done\n", "route";
				undef $ai_seq_args[0]{'solutionReady'};

				#Fill some vars, call the map router, and exit the function. We are now waiting for a
				#map solution
				$ai_seq_args[0]{'temp'}{'pos'}{'x'} = $ai_seq_args[0]{'dest_x'};
				$ai_seq_args[0]{'temp'}{'pos'}{'y'} = $ai_seq_args[0]{'dest_y'};
				$ai_seq_args[0]{'waitingForMapSolution'} = 1;
				ai_mapRoute_getRoute(\@{$ai_seq_args[0]{'mapSolution'}}, \%field, \%{$chars[$config{'char'}]{'pos_to'}}, \%field, \%{$ai_seq_args[0]{'temp'}{'pos'}}, $ai_seq_args[0]{'maxRouteTime'});
				last ROUTE;

			#If we already did an extensive search, and there's no solution, then we've failed
			} elsif (!@{$ai_seq_args[0]{'solution'}}) {
				debug "No solution - route failed\n", "route";
				$ai_seq_args[0]{'failed'} = 1;
				last ROUTE;
			}
		}

		#If we have a map solution, and the map changed to correct next map, then clear the position solution
		#so we can calculate the next position solution (ie. from portal A to portal B) of the map solution
		#We increase the map
		if (@{$ai_seq_args[0]{'mapSolution'}} && $ai_seq_args[0]{'mapChanged'} && $field{'name'} eq $ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'}]{'dest'}{'map'}) {
			debug "Route logic - map changed\n", "route";
			undef $ai_seq_args[0]{'mapChanged'};
			undef @{$ai_seq_args[0]{'solution'}};
			undef %{$ai_seq_args[0]{'last_pos'}};
			undef $ai_seq_args[0]{'index'};
			undef $ai_seq_args[0]{'npc'};
			undef $ai_seq_args[0]{'divideIndex'};
		}

		#If there's no position solution currently calculated...
		if (!@{$ai_seq_args[0]{'solution'}}) {
			#Check if we are on the final position solution - we're on the desired map, and there is either 
			#no map solution, or we're at the last step of the map solution.
			#
			#This sets the solution ready flag, which is checked at the beginning of the function
			if ($ai_seq_args[0]{'dest_map'} eq $field{'name'}
				&& (!@{$ai_seq_args[0]{'mapSolution'}} || $ai_seq_args[0]{'mapIndex'} == @{$ai_seq_args[0]{'mapSolution'}} - 1)) {
				$ai_seq_args[0]{'temp'}{'dest'}{'x'} = $ai_seq_args[0]{'dest_x'};
				$ai_seq_args[0]{'temp'}{'dest'}{'y'} = $ai_seq_args[0]{'dest_y'};
				$ai_seq_args[0]{'solutionReady'} = 1;
				undef @{$ai_seq_args[0]{'mapSolution'}};
				undef $ai_seq_args[0]{'mapIndex'};
				debug "Route logic - solution ready\n", "route";
			} else {
				#We're not on the final solution, that means we need a map solution to step through.
				#If we don't have a map solution...
				if (!(@{$ai_seq_args[0]{'mapSolution'}})) {
					#Get the field data if we don't have it
					if (!%{$ai_seq_args[0]{'dest_field'}}) {
						getField("$Settings::def_field/$ai_seq_args[0]{'dest_map'}.fld", \%{$ai_seq_args[0]{'dest_field'}});
					}
					#Fill some vars, call the map router, and exit this function
					$ai_seq_args[0]{'temp'}{'pos'}{'x'} = $ai_seq_args[0]{'dest_x'};
					$ai_seq_args[0]{'temp'}{'pos'}{'y'} = $ai_seq_args[0]{'dest_y'};
					$ai_seq_args[0]{'waitingForMapSolution'} = 1;
					debug "Route logic - waiting for map solution\n", "route";
					ai_mapRoute_getRoute(\@{$ai_seq_args[0]{'mapSolution'}}, \%field, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[0]{'dest_field'}}, \%{$ai_seq_args[0]{'temp'}{'pos'}}, $ai_seq_args[0]{'maxRouteTime'});
					last ROUTE;
				}

				#If we're here then we have a map solution ready.  The position solution is clear, that
				#usually means the map changed.
				#
				#If the current map is the next map in the map solution...
				if ($field{'name'} eq $ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'} + 1]{'source'}{'map'}) {
					#Take a step in the map solution
					$ai_seq_args[0]{'mapIndex'}++;
					#Fill our destination position for the position router
					%{$ai_seq_args[0]{'temp'}{'dest'}} = %{$ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'}]{'source'}{'pos'}};
				} else {
					#We're not at the next map, so don't take a step in the map solution.
					#This should only happen the first time we get the map solution.
					#Fill our destination for the position router
					%{$ai_seq_args[0]{'temp'}{'dest'}} = %{$ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'}]{'source'}{'pos'}};
				}
			}

			#Safety check, something is screwed up?
			if ($ai_seq_args[0]{'temp'}{'dest'}{'x'} eq "") {
				debug "No destination - route failed\n", "route";
				$ai_seq_args[0]{'failed'} = 1;
				last ROUTE;
			}

			#Call the position router, exit the function.  We're now waiting for a position solution
			$ai_seq_args[0]{'waitingForSolution'} = 1;
			$ai_seq_args[0]{'time_getRoute'} = time;
			debug "Route logic - waiting for solution\n", "route";
			ai_route_getRoute(\@{$ai_seq_args[0]{'solution'}}, \%field, \%{$chars[$config{'char'}]{'pos_to'}}, \%{$ai_seq_args[0]{'temp'}{'dest'}}, $ai_seq_args[0]{'maxRouteTime'});
			last ROUTE;
		}

		#If we have a map solution, are currently at the end of a position solution, and an NPC is specified
		#in the map step...
		#
		#Note that when we've completed the NPC talk steps, we do nothing until the map changes,
		#that clears the position solution, and thus we can move on to the next map step.
		if (@{$ai_seq_args[0]{'mapSolution'}} && @{$ai_seq_args[0]{'solution'}} && $ai_seq_args[0]{'index'} == @{$ai_seq_args[0]{'solution'}} - 1
		    && %{$ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'}]{'npc'}}) {
			#safety check
			if ($ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'}]{'npc'}{'steps'}[$ai_seq_args[0]{'npc'}{'step'}] ne "") {
				#Do one of the following, increase the talk step, exit the function and wait a few seconds
				#We'll come right back to this block after those seconds are up.
				#
				#Talk to the NPC if we haven't already
				if (!$ai_seq_args[0]{'npc'}{'sentTalk'}) {
					sendTalk(\$remote_socket, pack("L1",$ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'}]{'npc'}{'ID'}));
					$ai_seq_args[0]{'npc'}{'sentTalk'} = 1;
				#If the next step is a "continue" command, execute it
				} elsif ($ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'}]{'npc'}{'steps'}[$ai_seq_args[0]{'npc'}{'step'}] =~ /c/i) {
					sendTalkContinue(\$remote_socket, pack("L1",$ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'}]{'npc'}{'ID'}));
					$ai_seq_args[0]{'npc'}{'step'}++;
				#If the next step is a "cancel" command, execute it
				} elsif ($ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'}]{'npc'}{'steps'}[$ai_seq_args[0]{'npc'}{'step'}] =~ /n/i) {
					sendTalkCancel(\$remote_socket, pack("L1",$ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'}]{'npc'}{'ID'}));
					$ai_seq_args[0]{'npc'}{'step'}++;
				#If the next step is a "response" command, execute it
				} else {
					($ai_v{'temp'}{'arg'}) = $ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'}]{'npc'}{'steps'}[$ai_seq_args[0]{'npc'}{'step'}] =~ /r(\d+)/i;
					if ($ai_v{'temp'}{'arg'} ne "") {
						$ai_v{'temp'}{'arg'}++;
						sendTalkResponse(\$remote_socket, pack("L1",$ai_seq_args[0]{'mapSolution'}[$ai_seq_args[0]{'mapIndex'}]{'npc'}{'ID'}), $ai_v{'temp'}{'arg'});
					}
					$ai_seq_args[0]{'npc'}{'step'}++;
				}
				$timeout{'ai_route_npcTalk'}{'time'} = time;
				last ROUTE;
			}
		}

		#If the map has changed, and the event wasn't caught (and cleared) by any of the preceeding functions,
		#then the map change was a bad thing.  Just give up.
		if ($ai_seq_args[0]{'mapChanged'}) {
			debug "Map changed - route failed\n", "route";
			$ai_seq_args[0]{'failed'} = 1;
			last ROUTE;

		#Here we check if we've changed positions, and we're off course
		#
		#If we've tried to move (almost always yes)...
		} elsif (%{$ai_seq_args[0]{'last_pos'}}
			#and our current position is not the required position by the step
			&& $chars[$config{'char'}]{'pos_to'}{'x'} != $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'x'}
			&& $chars[$config{'char'}]{'pos_to'}{'y'} != $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'y'}
			#and our current position has changed from the last time we were here
			&& $ai_seq_args[0]{'last_pos'}{'x'} != $chars[$config{'char'}]{'pos_to'}{'x'}
			&& $ai_seq_args[0]{'last_pos'}{'y'} != $chars[$config{'char'}]{'pos_to'}{'y'}) {

			#Then something has taken us off course, the solution is no good anymore.
			#Reset the solution, it will be recalculated next time we enter the function
			#
			#The "follow behind" feature may have altered our destination, if it did, get back the original
			if ($ai_seq_args[0]{'dest_x_original'} ne "") {
				$ai_seq_args[0]{'dest_x'} = $ai_seq_args[0]{'dest_x_original'};
				$ai_seq_args[0]{'dest_y'} = $ai_seq_args[0]{'dest_y_original'};
			}
			debug "Route logic - last pos\n", "route";
			undef @{$ai_seq_args[0]{'solution'}};
			undef %{$ai_seq_args[0]{'last_pos'}};
			undef $ai_seq_args[0]{'index'};
			undef $ai_seq_args[0]{'npc'};
			undef $ai_seq_args[0]{'divideIndex'};
	
		} else {
			#We're set to take a step in the current position solution
			#We actually skip several steps at a time since the server does its own pathfinding.
			#Sometimes we may skip too many steps, and the server says "thats too far, i won't move u"
			#So we decrease the number of steps skipped until the server finally moves us.
			#
			#If we've tried to move and our position still isn't at the next step
			if ($ai_seq_args[0]{'divideIndex'} && $chars[$config{'char'}]{'pos_to'}{'x'} != $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'x'}
				&& $chars[$config{'char'}]{'pos_to'}{'y'} != $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'y'}) {

				#we're stuck!
				debug "Route logic - stuck\n", "route";
				$ai_v{'temp'}{'index_old'} = $ai_seq_args[0]{'index'};
				$ai_seq_args[0]{'index'} -= int($config{'route_step'} / $ai_seq_args[0]{'divideIndex'});
				$ai_seq_args[0]{'index'} = 0 if ($ai_seq_args[0]{'index'} < 0);
				$ai_v{'temp'}{'index'} = $ai_seq_args[0]{'index'};
				undef $ai_v{'temp'}{'done'};

				#decrease the skip amount by a factor, make sure the new skip amount isn't the same as the
				#skip amount that didn't work
				do {
					$ai_seq_args[0]{'divideIndex'}++;
					$ai_v{'temp'}{'index'} = $ai_seq_args[0]{'index'};
					$ai_v{'temp'}{'index'} += int($config{'route_step'} / $ai_seq_args[0]{'divideIndex'});
					$ai_v{'temp'}{'index'} = @{$ai_seq_args[0]{'solution'}} - 1 if ($ai_v{'temp'}{'index'} >= @{$ai_seq_args[0]{'solution'}});
					$ai_v{'temp'}{'done'} = 1 if (int($config{'route_step'} / $ai_seq_args[0]{'divideIndex'}) == 0);
				} while ($ai_v{'temp'}{'index'} >= $ai_v{'temp'}{'index_old'} && !$ai_v{'temp'}{'done'});
			} else {
				$ai_seq_args[0]{'divideIndex'} = 1;
				debug "Route logic - divide index = 1\n", "route";
				$pos_x = int($chars[$config{'char'}]{'pos_to'}{'x'}) if ($chars[$config{'char'}]{'pos_to'}{'x'} ne "");
				$pos_y = int($chars[$config{'char'}]{'pos_to'}{'y'}) if ($chars[$config{'char'}]{'pos_to'}{'y'} ne "");
				#if kore is stuck
				if (($old_pos_x == $pos_x) && ($old_pos_y == $pos_y)) {
					$route_stuck++;
				} else {
					$route_stuck = 0;
					$old_pos_x = $pos_x;
					$old_pos_y = $pos_y;
				}
				if ($route_stuck >= 50) {
					ClearRouteAI("Route failed, clearing route AI to unstuck ...\n");
					last ROUTE;
				}
				if ($route_stuck >= 80) {
					$route_stuck = 0;
					Unstuck("Route failed, trying to unstuck ...\n");
					last ROUTE;
				}	
				if ($totalStuckCount >= 10) {
					RespawnUnstuck();
					last ROUTE;
				}		
			}

			#We've tried all possible skip amounts, and the server won't move us.  Fail.
			if (int($config{'route_step'} / $ai_seq_args[0]{'divideIndex'}) == 0) {
				debug "Route step - route failed\n", "route";
				$ai_seq_args[0]{'failed'} = 1;
				last ROUTE;
			}

			#Save current position for the next time we enter this function
			%{$ai_seq_args[0]{'last_pos'}} = %{$chars[$config{'char'}]{'pos_to'}};

			#Increase the step by the skip amount, and make sure that the position at the step is
			#different from our current position (should never happen really)
			do {
				$ai_seq_args[0]{'index'} += int($config{'route_step'} / $ai_seq_args[0]{'divideIndex'});
				$ai_seq_args[0]{'index'} = @{$ai_seq_args[0]{'solution'}} - 1 if ($ai_seq_args[0]{'index'} >= @{$ai_seq_args[0]{'solution'}});
			} while ($ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'x'} == $chars[$config{'char'}]{'pos_to'}{'x'}
				&& $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'y'} == $chars[$config{'char'}]{'pos_to'}{'y'}
				&& $ai_seq_args[0]{'index'} != @{$ai_seq_args[0]{'solution'}} - 1);

			#If the avoid portals flag is set, don't move to any position that is within a distance of a portal
			#If a portal is within distance, the route will fail.
			#This is an ugly hack.  The map data should be dynamic and have an array of portals "painted" out
			#BEFORE doing A*
			if ($ai_seq_args[0]{'avoidPortals'}) {
				$ai_v{'temp'}{'first'} = 1;
				undef $ai_v{'temp'}{'foundID'};
				undef $ai_v{'temp'}{'smallDist'};
				foreach (@portalsID) {
					$ai_v{'temp'}{'dist'} = distance(\%{$ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]}, \%{$portals{$_}{'pos'}});
					if ($ai_v{'temp'}{'dist'} <= 7 && ($ai_v{'temp'}{'first'} || $ai_v{'temp'}{'dist'} < $ai_v{'temp'}{'smallDist'})) {
						$ai_v{'temp'}{'smallDist'} = $ai_v{'temp'}{'dist'};
						$ai_v{'temp'}{'foundID'} = $_;
						undef $ai_v{'temp'}{'first'};
						debug "Route logic - portal found\n", "route";
					}
				}
				if ($ai_v{'temp'}{'foundID'}) {
					debug "A portal is near - route failed\n", "route";
					$ai_seq_args[0]{'failed'} = 1;
					last ROUTE;
				}
			}
			#if the step position doesn't equal our current position, then move there
			if ($ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'x'} != $chars[$config{'char'}]{'pos_to'}{'x'}
			 || $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'y'} != $chars[$config{'char'}]{'pos_to'}{'y'}) {
				move($ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'x'}, $ai_seq_args[0]{'solution'}[$ai_seq_args[0]{'index'}]{'y'}, 1, $ai_seq_args[0]{'attackID'});
			}
		}
	}
	} #END OF ROUTE BLOCK


	##### ROUTE_GETROUTE #####

	if ($ai_seq[0] eq "route_getRoute" && $ai_seq_args[0]{'suspended'}) {
		$ai_seq_args[0]{'time_giveup'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		undef $ai_seq_args[0]{'suspended'};
	}
	if ($ai_seq[0] eq "route_getRoute" && ($ai_seq_args[0]{'done'} || $ai_seq_args[0]{'mapChanged'}
		|| ($ai_seq_args[0]{'time_giveup'}{'timeout'} && timeOut(\%{$ai_seq_args[0]{'time_giveup'}})))) {
		$timeout{'ai_route_calcRoute_cont'}{'time'} -= $timeout{'ai_route_calcRoute_cont'}{'timeout'};
		ai_route_getRoute_destroy(\%{$ai_seq_args[0]});
		shift @ai_seq;
		shift @ai_seq_args;

	} elsif ($ai_seq[0] eq "route_getRoute" && timeOut(\%{$timeout{'ai_route_calcRoute_cont'}})) {
		if (!$ai_seq_args[0]{'init'}) {
			undef @{$ai_v{'temp'}{'subSuc'}};
			undef @{$ai_v{'temp'}{'subSuc2'}};
			if (ai_route_getMap(\%{$ai_seq_args[0]}, $ai_seq_args[0]{'start'}{'x'}, $ai_seq_args[0]{'start'}{'y'})) {
				ai_route_getSuccessors(\%{$ai_seq_args[0]}, \%{$ai_seq_args[0]{'start'}}, \@{$ai_v{'temp'}{'subSuc'}},0);
				ai_route_getDiagSuccessors(\%{$ai_seq_args[0]}, \%{$ai_seq_args[0]{'start'}}, \@{$ai_v{'temp'}{'subSuc'}},0);
				foreach (@{$ai_v{'temp'}{'subSuc'}}) {
					ai_route_getSuccessors(\%{$ai_seq_args[0]}, \%{$_}, \@{$ai_v{'temp'}{'subSuc2'}},0);
					ai_route_getDiagSuccessors(\%{$ai_seq_args[0]}, \%{$_}, \@{$ai_v{'temp'}{'subSuc2'}},0);
				}
				if (@{$ai_v{'temp'}{'subSuc'}}) {
					%{$ai_seq_args[0]{'start'}} = %{$ai_v{'temp'}{'subSuc'}[0]};
				} elsif (@{$ai_v{'temp'}{'subSuc2'}}) {
					%{$ai_seq_args[0]{'start'}} = %{$ai_v{'temp'}{'subSuc2'}[0]};
				}
			}
			undef @{$ai_v{'temp'}{'subSuc'}};
			undef @{$ai_v{'temp'}{'subSuc2'}};
			if (ai_route_getMap(\%{$ai_seq_args[0]}, $ai_seq_args[0]{'dest'}{'x'}, $ai_seq_args[0]{'dest'}{'y'})) {
				ai_route_getSuccessors(\%{$ai_seq_args[0]}, \%{$ai_seq_args[0]{'dest'}}, \@{$ai_v{'temp'}{'subSuc'}},0);
				ai_route_getDiagSuccessors(\%{$ai_seq_args[0]}, \%{$ai_seq_args[0]{'dest'}}, \@{$ai_v{'temp'}{'subSuc'}},0);
				foreach (@{$ai_v{'temp'}{'subSuc'}}) {
					ai_route_getSuccessors(\%{$ai_seq_args[0]}, \%{$_}, \@{$ai_v{'temp'}{'subSuc2'}},0);
					ai_route_getDiagSuccessors(\%{$ai_seq_args[0]}, \%{$_}, \@{$ai_v{'temp'}{'subSuc2'}},0);
				}
				if (@{$ai_v{'temp'}{'subSuc'}}) {
					%{$ai_seq_args[0]{'dest'}} = %{$ai_v{'temp'}{'subSuc'}[0]};
				} elsif (@{$ai_v{'temp'}{'subSuc2'}}) {
					%{$ai_seq_args[0]{'dest'}} = %{$ai_v{'temp'}{'subSuc2'}[0]};
				}
			}
			$ai_seq_args[0]{'timeout'} = $timeout{'ai_route_calcRoute'}{'timeout'}*1000;
		}
		$ai_seq_args[0]{'init'} = 1;
		ai_route_searchStep(\%{$ai_seq_args[0]});
		$timeout{'ai_route_calcRoute_cont'}{'time'} = time;
		ai_setSuspend(0);
	}

	##### ROUTE_GETMAPROUTE #####

	ROUTE_GETMAPROUTE: {

	if ($ai_seq[0] eq "route_getMapRoute" && $ai_seq_args[0]{'suspended'}) {
		$ai_seq_args[0]{'time_giveup'}{'time'} += time - $ai_seq_args[0]{'suspended'};
		undef $ai_seq_args[0]{'suspended'};
	}
	if ($ai_seq[0] eq "route_getMapRoute" && ($ai_seq_args[0]{'done'} || $ai_seq_args[0]{'mapChanged'}
		|| ($ai_seq_args[0]{'time_giveup'}{'timeout'} && timeOut(\%{$ai_seq_args[0]{'time_giveup'}})))) {
		$timeout{'ai_route_calcRoute_cont'}{'time'} -= $timeout{'ai_route_calcRoute_cont'}{'timeout'};
		shift @ai_seq;
		shift @ai_seq_args;

	} elsif ($ai_seq[0] eq "route_getMapRoute" && timeOut(\%{$timeout{'ai_route_calcRoute_cont'}})) {
		if (!%{$ai_seq_args[0]{'start'}}) {
			%{$ai_seq_args[0]{'start'}{'dest'}{'pos'}} = %{$ai_seq_args[0]{'r_start_pos'}};
			$ai_seq_args[0]{'start'}{'dest'}{'map'} = $ai_seq_args[0]{'r_start_field'}{'name'};
			$ai_seq_args[0]{'start'}{'dest'}{'field'} = $ai_seq_args[0]{'r_start_field'};
			%{$ai_seq_args[0]{'dest'}{'source'}{'pos'}} = %{$ai_seq_args[0]{'r_dest_pos'}};
			$ai_seq_args[0]{'dest'}{'source'}{'map'} = $ai_seq_args[0]{'r_dest_field'}{'name'};
			$ai_seq_args[0]{'dest'}{'source'}{'field'} = $ai_seq_args[0]{'r_dest_field'};
			push @{$ai_seq_args[0]{'openList'}}, \%{$ai_seq_args[0]{'start'}};
		}
		$timeout{'ai_route_calcRoute'}{'time'} = time;
		while (!$ai_seq_args[0]{'done'} && !timeOut(\%{$timeout{'ai_route_calcRoute'}})) {
			ai_mapRoute_searchStep(\%{$ai_seq_args[0]});
			last ROUTE_GETMAPROUTE if ($ai_seq[0] ne "route_getMapRoute");
		}

		if ($ai_seq_args[0]{'done'}) {
			@{$ai_seq_args[0]{'returnArray'}} = @{$ai_seq_args[0]{'solutionList'}};
		}
		$timeout{'ai_route_calcRoute_cont'}{'time'} = time;
		ai_setSuspend(0);
	}

	} #End of block ROUTE_GETMAPROUTE


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


	if (($ai_seq[0] eq "" || $ai_seq[0] eq "follow" || $ai_seq[0] eq "route" || $ai_seq[0] eq "route_getRoute" || $ai_seq[0] eq "route_getMapRoute")
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
			# We couldn't move within ai_move_giveup seconds.
			# Abort move commands.
			shift @ai_seq;
			shift @ai_seq_args;

		} elsif ($chars[$config{'char'}]{'sitting'}) {
			# Stand if we're sitting
			ai_setSuspend(0);
			stand();

		} elsif ($ai_seq_args[0]{'stage'} eq '') {
			sendMove(\$remote_socket, int($ai_seq_args[0]{'move_to'}{'x'}), int($ai_seq_args[0]{'move_to'}{'y'}));
			$ai_seq_args[0]{'ai_move_giveup'}{'time'} = time;
			$ai_seq_args[0]{'ai_move_time_last'} = $chars[$config{'char'}]{'time_move'};
			$ai_seq_args[0]{'stage'} = 'Sent Move Request';

		} elsif ($ai_seq_args[0]{'ai_move_time_last'} eq $chars[$config{'char'}]{'time_move'}) {
			# We haven't moved yet, send move request again
			sendMove(\$remote_socket, int($ai_seq_args[0]{'move_to'}{'x'}), int($ai_seq_args[0]{'move_to'}{'y'}));

		} elsif ($ai_seq_args[0]{'move_to'}{'x'} eq $chars[$config{'char'}]{'pos_to'}{'x'}
		      && $ai_seq_args[0]{'move_to'}{'y'} eq $chars[$config{'char'}]{'pos_to'}{'y'}) {
			# We've arrived at our destination. Remove the move AI sequence.
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
	debug "Packet Switch SENT_BY_CLIENT: $switch\n" if ($config{'debugPacket_ro_sent'} && !existsInList($config{'debugPacket_exclude'}, $switch));

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
		message "Map loaded\n";

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
	debug "Packet Switch: $switch\n", "parseMsg" if ($config{'debugPacket_received'} && !existsInList($config{'debugPacket_exclude'}, $switch));

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
			$encryptKey1 = unpack("L1", substr($msg, 6, 4));
			$encryptKey2 = unpack("L1", substr($msg, 10, 4));
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
			writeDataFileIntact($Settings::config_file, \%config);
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
			killConnection(\$remote_socket);
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
			error("Critical Error: Account has been disabled by evil Gravity\n", "connection");
			$quit = 1;
		} elsif ($type == 5) {
			error("Version $config{'version'} failed...trying to find version\n", "connection");
			$config{'version'}++;
			if (!$versionSearch) {
				$config{'version'} = 0;
				$versionSearch = 1;
			}
		} elsif ($type == 6) {
			error("The server is temporarily blocking your connection\n", "connection");
		}
		if ($type != 5 && $versionSearch) {
			$versionSearch = 0;
			writeDataFileIntact($Settings::config_file, \%config);
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
						error "Sanity Checking FAILED: Invalid username detected.\n";
						killConnection(\$remote_socket);
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
		killConnection(\$remote_socket);

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
		killConnection(\$remote_socket) if (!$config{'XKore'});
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

				debug "Monster Exists: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'})\n", "parseMsg";

				my $prevState = $monsters{$ID}{'state'};
				$monsters{$ID}{'state'} = unpack("S*", substr($msg, 8, 2)); 
				$monsters{$ID}{'state'} = 0 if ($monsters{$ID}{'state'} == 5); 
				my $mon = "Monster $monsters{$ID}{name} $monsters{$ID}{nameID} ($monsters{$ID}{binID})"; 
				if (!$monsters{$ID}{'state'}) {
					message "$mon is free.\n" if ($prevState);

				} elsif ($monsters{$ID}{'state'} == 1) {
					message "$mon is stoned.\n";
					$monsters{$ID}{'ignore'} = 1;

				} elsif ($monsters{$ID}{'state'} == 2) {
					message "$mon is frozen.\n";
					$monsters{$ID}{'ignore'} = 1;

				} elsif ($monsters{$ID}{'state'} == 3) {
					message "$mon is stunned.\n";
					$monsters{$ID}{'ignore'} = 1;

				} elsif ($monsters{$ID}{'state'} == 4) {
					message "$mon is asleep.\n";
					$monsters{$ID}{'ignore'} = 1;

				} else {
					message "$mon is disabled.\n";
					$monsters{$ID}{'ignore'} = 1;
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
			debug "Player Exists: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg";

		} elsif ($type == 45) {
			if (!%{$portals{$ID}}) {
				$portals{$ID}{'appear_time'} = time;
				$nameID = unpack("L1", $ID);
				$exists = portalExists($field{'name'}, \%coords);
				$display = ($exists ne "")
					? "$portals_lut{$exists}{'source'}{'map'} -> $portals_lut{$exists}{'dest'}{'map'}"
					: "Unknown ".$nameID;
				binAdd(\@portalsID, $ID);
				$portals{$ID}{'source'}{'map'} = $field{'name'};
				$portals{$ID}{'type'} = $type;
				$portals{$ID}{'nameID'} = $nameID;
				$portals{$ID}{'name'} = $display;
				$portals{$ID}{'binID'} = binFind(\@portalsID, $ID);
			}
			%{$portals{$ID}{'pos'}} = %coords;
			message "Portal Exists: $portals{$ID}{'name'} - ($portals{$ID}{'binID'})\n";

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
			message "NPC Exists: $npcs{$ID}{'name'} (ID $npcs{$ID}{'nameID'}) - ($npcs{$ID}{'binID'})\n";

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
		killConnection(\$remote_socket);

		if ($type == 2) {
			error("Critical Error: Dual login prohibited - Someone trying to login!\n", "connection");
			if ($config{'dcOnDualLogin'} == 1) {
				message "Disconnect immediately!\n", "connection";
				$quit = 1;
			} elsif ($config{'dcOnDualLogin'} >= 2) {
				message "Disconnect for $config{'dcOnDualLogin'} seconds...\n", "connection";
				$timeout_ex{'master'}{'timeout'} = $config{'dcOnDualLogin'};
			}

		} elsif ($type == 3) {
			error("Error: Out of sync with server\n", "connection");
		} elsif ($type == 6) {
			error("Critical Error: You must pay to play this account!\n", "connection");
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
		debug "You move to: $coordsTo{'x'}, $coordsTo{'y'}\n", "parseMsg";
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
				message(sprintf("[%3d|%3d]",percent_hp(\%{$chars[$config{'char'}]}),percent_sp(\%{$chars[$config{'char'}]}))
					."Attack : $monsters{$ID2}{'name'} ($monsters{$ID2}{'binID'}) - Dmg: $dmgdisplay\n",
					($damage > 0)? "attackMon" : "attackMonMiss");

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

				message(sprintf("[%3d|%3d]",percent_hp(\%{$chars[$config{'char'}]}),percent_sp(\%{$chars[$config{'char'}]}))
					."Get Dmg : $monsters{$ID1}{'name'} $monsters{$ID1}{'nameID'} ($monsters{$ID1}{'binID'}) attacks You: $dmgdisplay\n",
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

		$ai_cmdQue[$ai_cmdQue]{'type'} = "c";
		$ai_cmdQue[$ai_cmdQue]{'ID'} = $ID;
		$ai_cmdQue[$ai_cmdQue]{'user'} = $chatMsgUser;
		$ai_cmdQue[$ai_cmdQue]{'msg'} = $chatMsg;
		$ai_cmdQue[$ai_cmdQue]{'time'} = time;
		$ai_cmdQue++;
		message "$chat\n";
#Solos Start

#auto-emote
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
#auto-response
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
#Solos End

	} elsif ($switch eq "008E") {
		$chat = substr($msg, 4, $msg_size - 4);
		$chat =~ s/\000//g;
		($chatMsgUser, $chatMsg) = $chat =~ /([\s\S]*?) : ([\s\S]*)/;
		chatLog("c", $chat."\n") if ($config{'logChat'});
		if ($config{'relay'}) {
			sendMessage(\$remote_socket, "pm", $chat, $config{'relay_user'});
		}
		$ai_cmdQue[$ai_cmdQue]{'type'} = "c";
		$ai_cmdQue[$ai_cmdQue]{'user'} = $chatMsgUser;
		$ai_cmdQue[$ai_cmdQue]{'msg'} = $chatMsg;
		$ai_cmdQue[$ai_cmdQue]{'time'} = time;
		$ai_cmdQue++;
		message "$chat\n";
#Solos Start
# this is self talk portion
#Solos End
	} elsif ($switch eq "008F") {

	} elsif ($switch eq "0091") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		initMapChangeVars();
		for ($i = 0; $i < @ai_seq; $i++) {
			ai_setMapChanged($i);
		}
		($map_name) = substr($msg, 2, 16) =~ /([\s\S]*?)\000/;
		($ai_v{'temp'}{'map'}) = $map_name =~ /([\s\S]*)\./;
		if ($ai_v{'temp'}{'map'} ne $field{'name'}) {
			getField("$Settings::def_field/$ai_v{'temp'}{'map'}.fld", \%field);
		}
		$coords{'x'} = unpack("S1", substr($msg, 18, 2));
		$coords{'y'} = unpack("S1", substr($msg, 20, 2));
		%{$chars[$config{'char'}]{'pos'}} = %coords;
		%{$chars[$config{'char'}]{'pos_to'}} = %coords;
		message "Map Change: $map_name\n";
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
		killConnection(\$remote_socket) if (!$config{'XKore'});

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

	} elsif ($switch eq "0096") {

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

		$ai_cmdQue[$ai_cmdQue]{'type'} = "pm";
		$ai_cmdQue[$ai_cmdQue]{'user'} = $privMsgUser;
		$ai_cmdQue[$ai_cmdQue]{'msg'} = $privMsg;
		$ai_cmdQue[$ai_cmdQue]{'time'} = time;
		$ai_cmdQue++;
		message "(From: $privMsgUser) : $privMsg\n", "pm";

		avoidGM_talk($privMsgUser, $privMsg);
		avoidList_talk($privMsgUser, $privMsg);

		Plugins::callHook('packet_privMsg', {
			'privMsgUser' => $privMsgUser,
			'privMsg' => $privMsg
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
		message "$chat\n";
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
		message "Item Exists: $items{$ID}{'name'} ($items{$ID}{'binID'}) x $items{$ID}{'amount'}\n", "drop";

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
		message "Item Appeared: $items{$ID}{'name'} ($items{$ID}{'binID'}) x $items{$ID}{'amount'}\n", "drop";

	} elsif ($switch eq "00A0") {
		$conState = 5 if ($conState != 4 && $config{'XKore'});
		$index = unpack("S1",substr($msg, 2, 2));
		$amount = unpack("S1",substr($msg, 4, 2));
		$ID = unpack("S1",substr($msg, 6, 2));
		$type = unpack("C1",substr($msg, 21, 1));
		$type_equip = unpack("C1",substr($msg, 19, 1));
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
				$chars[$config{'char'}]{'inventory'}[$invIndex]{'type_equip'} = $itemSlots_lut{$ID};
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
		message "Storage opened\n";

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
			message "Inventory Item Removed: $chars[$config{'char'}]{'inventory'}[$invIndex]{'name'} ($invIndex) x $amount\n";
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
		message "$npcs{$ID}{'name'} : $talk{'msg'}\n";

	} elsif ($switch eq "00B5") {
		$ID = substr($msg, 2, 4);
		message "$npcs{$ID}{'name'} : Type 'talk cont' to continue talking\n";

	} elsif ($switch eq "00B6") {
		$ID = substr($msg, 2, 4);
		undef %talk;
		message "$npcs{$ID}{'name'} : Done talking\n";

	} elsif ($switch eq "00B7") {
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

		message("----------Responses-----------\n", "list");
		message("#  Response\n", "list");
		for (my $i = 0; $i < @{$talk{'responses'}}; $i++) {
			message(swrite(
				"@< @<<<<<<<<<<<<<<<<<<<<<<",
				[$i, $talk{'responses'}[$i]]),
				"list");
		}
		message("-------------------------------\n", "list");
		message("$npcs{$ID}{'name'} : Type 'talk resp' and choose a response.\n", "input");

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
			message "$chars[$config{'char'}]{'name'} : $emotions_lut{$type}\n";
			chatLog("e", "$chars[$config{'char'}]{'name'} : $emotions_lut{$type}\n") if (existsInList($config{'logEmoticons'}, $type) || $config{'logEmoticons'} eq "all");
		} elsif (%{$players{$ID}}) {
			message "$players{$ID}{'name'} : $emotions_lut{$type}\n";
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
		message "There are currently $users users online\n";

	} elsif ($switch eq "00C4") {
		my $ID = substr($msg, 2, 4);
		undef %talk;
		$talk{'buyOrSell'} = 1;
		$talk{'ID'} = $ID;
		message "$npcs{$ID}{'name'} : Type 'store' to start buying, or type 'sell' to start selling\n";

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
			if (!%{$chars[$config{'char'}]{'party'}{'users'}{$ID}}) {
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
			binAdd(\@partyUsersID, $ID);
			if ($ID eq $accountID) {
				message "You joined party '$name'\n";
			} else {
				message "$partyUser joined your party '$name'\n";
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
		$ai_cmdQue[$ai_cmdQue]{'type'} = "p";
		$ai_cmdQue[$ai_cmdQue]{'user'} = $chatMsgUser;
		$ai_cmdQue[$ai_cmdQue]{'msg'} = $chatMsg;
		$ai_cmdQue[$ai_cmdQue]{'time'} = time;
		$ai_cmdQue++;
		message "%$chat\n";

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
    my $disp = "$source $uses $skillsID_lut{$skillID}" . (($level == 65535)? "" : " (lvl $level)") . (($damage == 35536)? "" : " on $target - Dmg: $damage") . "\n";

    my $domain;
    $domain = "skill" if (($source eq "You") || ($target eq "You"));
    
    if ($damage == 0) {
      $domain = "attackMonMiss" if (($source eq "You") && ($target ne "Self"));
      $domain = "attackedMiss" if (($source ne "You") && ($target eq "You"));
    }
    elsif ($damage != 35536) {
      $domain = "attackMon" if (($source eq "You") && ($target ne "Self"));
      $domain = "attacked" if (($source ne "You") && ($target eq "You"));
    }
    
    message $disp, $domain;
    
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
		my $ID = substr($msg, 2, 4);
		my $param1 = unpack("S1", substr($msg, 6, 2));
		my $param2 = unpack("S1", substr($msg, 8, 2));
		my $param3 = unpack("S1", substr($msg, 10, 2));

		# character looks
		if ($ID eq $accountID) {
			if ($param2 == 0x0001) {
				# poison
				# if you've got detoxify, use it ;)
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
				
		} elsif (%{$monsters{$ID}}) {
			my $prevState = $monsters{$ID}{'state'};
			$monsters{$ID}{'state'} = unpack("S*", substr($msg, 6, 2)); 
			$monsters{$ID}{'state'} = 0 if ($monsters{$ID}{'state'} == 5); 
			my $mon = "Monster $monsters{$ID}{name} $monsters{$ID}{nameID} ($monsters{$ID}{binID})"; 
			if (!$monsters{$ID}{'state'}) {
				message "$mon is free.\n" if ($prevState);

			} elsif ($monsters{$ID}{'state'} == 1) {
				message "$mon is stoned.\n";
				$monsters{$ID}{'ignore'} = 1;

			} elsif ($monsters{$ID}{'state'} == 2) {
				message "$mon is frozen.\n";
				$monsters{$ID}{'ignore'} = 1;

			} elsif ($monsters{$ID}{'state'} == 3) {
				message "$mon is stunned.\n";
				$monsters{$ID}{'ignore'} = 1;

			} elsif ($monsters{$ID}{'state'} == 4) {
				message "$mon is asleep.\n";
				$monsters{$ID}{'ignore'} = 1;

			} else {
				message "$mon is disabled.\n";
				$monsters{$ID}{'ignore'} = 1;
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
  
		message "$source $uses $skillsID_lut{$skillID} on $target$extra\n", (($source eq "You") || ($target eq "You"))? "skill" : "";
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
		#area effect spell
		$ID = substr($msg, 2, 4);
		$SourceID = substr($msg, 6, 4);
		$x = unpack("S1",substr($msg, 10, 2));
		$y = unpack("S1",substr($msg, 12, 2));
		$spells{$ID}{'sourceID'} = $SourceID;
		$spells{$ID}{'pos'}{'x'} = $x;
		$spells{$ID}{'pos'}{'y'} = $y;
		$binID = binAdd(\@spellsID, $ID);
		$spells{$ID}{'binID'} = $binID;

	} elsif ($switch eq "0120") {
		#The area effect spell with ID dissappears
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
			message "Please equip arrow first\n";
			undef $chars[$config{'char'}]{'arrow'};
			quit() if ($config{'dcOnEmptyArrow'});
		} elsif ($type == 3) {
			print "Arrow equipped\n" if ($config{'debug'}); 
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
		message "$sourceDisplay $skillsID_lut{$skillID} on $targetDisplay\n";

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
		# 0148 ID:l type:w
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
		$ai_cmdQue[$ai_cmdQue]{'type'} = "g";
		$ai_cmdQue[$ai_cmdQue]{'ID'} = $ID;
		$ai_cmdQue[$ai_cmdQue]{'user'} = $chatMsgUser;
		$ai_cmdQue[$ai_cmdQue]{'msg'} = $chatMsg;
		$ai_cmdQue[$ai_cmdQue]{'time'} = time;
		$ai_cmdQue++;
		message "[Guild] $chat\n", "guildchat";

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
		#pet

	} elsif ($switch eq "01B3") {
		#NPC image 
		my $npc_image = substr($msg, 2,64); 
		($npc_image) = $npc_image =~ /(\S+)/; 
		debug "NPC image: $npc_image\n", "parseMsg";

	} elsif ($switch eq "01B6") {
		#Guild Info 
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
				debug "Monster Exists: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'})\n", "parseMsg";
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
			debug "Player Exists: $players{$ID}{'name'} ($players{$ID}{'binID'}) $sex_lut{$players{$ID}{'sex'}} $jobs_lut{$players{$ID}{'jobID'}}\n", "parseMsg";

		} elsif ($type == 45) {
			if (!%{$portals{$ID}}) {
				$portals{$ID}{'appear_time'} = time;
				$nameID = unpack("L1", $ID);
				$exists = portalExists($field{'name'}, \%coords);
				$display = ($exists ne "") 
					? "$portals_lut{$exists}{'source'}{'map'} -> $portals_lut{$exists}{'dest'}{'map'}"
					: "Unknown ".$nameID;
				binAdd(\@portalsID, $ID);
				$portals{$ID}{'source'}{'map'} = $field{'name'};
				$portals{$ID}{'type'} = $type;
				$portals{$ID}{'nameID'} = $nameID;
				$portals{$ID}{'name'} = $display;
				$portals{$ID}{'binID'} = binFind(\@portalsID, $ID);
			}
			%{$portals{$ID}{'pos'}} = %coords;
			message "Portal Exists: $portals{$ID}{'name'} - ($portals{$ID}{'binID'})\n";

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
			message "NPC Exists: $npcs{$ID}{'name'} (ID $npcs{$ID}{'nameID'}) - ($npcs{$ID}{'binID'})\n";

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
	my %args;
	$args{'name'} = $name; 
	unshift @ai_seq, "follow";
	unshift @ai_seq_args, \%args;
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

sub ai_mapRoute_getRoute {

	my %args;

	##VARS

	$args{'g_normal'} = 1;

	###
	
	my ($returnArray, $r_start_field, $r_start_pos, $r_dest_field, $r_dest_pos, $time_giveup) = @_;
	$args{'returnArray'} = $returnArray;
	$args{'r_start_field'} = $r_start_field;
	$args{'r_start_pos'} = $r_start_pos;
	$args{'r_dest_field'} = $r_dest_field;
	$args{'r_dest_pos'} = $r_dest_pos;
	$args{'time_giveup'}{'timeout'} = $time_giveup;
	$args{'time_giveup'}{'time'} = time;
	unshift @ai_seq, "route_getMapRoute";
	unshift @ai_seq_args, \%args;
}

sub ai_mapRoute_getSuccessors {
	my ($r_args, $r_array, $r_cur) = @_;
	my $ok;
	foreach (keys %portals_lut) {
		if ($portals_lut{$_}{'source'}{'map'} eq $$r_cur{'dest'}{'map'}

			&& !($$r_cur{'source'}{'map'} eq $portals_lut{$_}{'dest'}{'map'}
			&& $$r_cur{'source'}{'pos'}{'x'} == $portals_lut{$_}{'dest'}{'pos'}{'x'}
			&& $$r_cur{'source'}{'pos'}{'y'} == $portals_lut{$_}{'dest'}{'pos'}{'y'})

			&& !(%{$$r_cur{'parent'}} && $$r_cur{'parent'}{'source'}{'map'} eq $portals_lut{$_}{'dest'}{'map'}
			&& $$r_cur{'parent'}{'source'}{'pos'}{'x'} == $portals_lut{$_}{'dest'}{'pos'}{'x'}
			&& $$r_cur{'parent'}{'source'}{'pos'}{'y'} == $portals_lut{$_}{'dest'}{'pos'}{'y'})) {
			undef $ok;
			if (!%{$$r_cur{'parent'}}) {
				if (!$$r_args{'solutions'}{$$r_args{'start'}{'dest'}{'field'}.\%{$$r_args{'start'}{'dest'}{'pos'}}.\%{$portals_lut{$_}{'source'}{'pos'}}}{'solutionTried'}) {
					$$r_args{'solutions'}{$$r_args{'start'}{'dest'}{'field'}.\%{$$r_args{'start'}{'dest'}{'pos'}}.\%{$portals_lut{$_}{'source'}{'pos'}}}{'solutionTried'} = 1;
					$timeout{'ai_route_calcRoute'}{'time'} -= $timeout{'ai_route_calcRoute'}{'timeout'};
					$$r_args{'waitingForSolution'} = 1;
					ai_route_getRoute(\@{$$r_args{'solutions'}{$$r_args{'start'}{'dest'}{'field'}.\%{$$r_args{'start'}{'dest'}{'pos'}}.\%{$portals_lut{$_}{'source'}{'pos'}}}{'solution'}}, 
							$$r_args{'start'}{'dest'}{'field'}, \%{$$r_args{'start'}{'dest'}{'pos'}}, \%{$portals_lut{$_}{'source'}{'pos'}});
					last;
				}
				$ok = 1 if (@{$$r_args{'solutions'}{$$r_args{'start'}{'dest'}{'field'}.\%{$$r_args{'start'}{'dest'}{'pos'}}.\%{$portals_lut{$_}{'source'}{'pos'}}}{'solution'}});
			} elsif ($portals_los{$$r_cur{'dest'}{'ID'}}{$portals_lut{$_}{'source'}{'ID'}} ne "0"
				&& $portals_los{$portals_lut{$_}{'source'}{'ID'}}{$$r_cur{'dest'}{'ID'}} ne "0") {
				$ok = 1;
			}
			if ($$r_args{'dest'}{'source'}{'pos'}{'x'} ne "" && $portals_lut{$_}{'dest'}{'map'} eq $$r_args{'dest'}{'source'}{'map'}) {
				if (!$$r_args{'solutions'}{$$r_args{'dest'}{'source'}{'field'}.\%{$portals_lut{$_}{'dest'}{'pos'}}.\%{$$r_args{'dest'}{'source'}{'pos'}}}{'solutionTried'}) {
					$$r_args{'solutions'}{$$r_args{'dest'}{'source'}{'field'}.\%{$portals_lut{$_}{'dest'}{'pos'}}.\%{$$r_args{'dest'}{'source'}{'pos'}}}{'solutionTried'} = 1;
					$timeout{'ai_route_calcRoute'}{'time'} -= $timeout{'ai_route_calcRoute'}{'timeout'};
					$$r_args{'waitingForSolution'} = 1;
					ai_route_getRoute(\@{$$r_args{'solutions'}{$$r_args{'dest'}{'source'}{'field'}.\%{$portals_lut{$_}{'dest'}{'pos'}}.\%{$$r_args{'dest'}{'source'}{'pos'}}}{'solution'}}, 
							$$r_args{'dest'}{'source'}{'field'}, \%{$portals_lut{$_}{'dest'}{'pos'}}, \%{$$r_args{'dest'}{'source'}{'pos'}});
					last;
				}
			}
			push @{$r_array}, \%{$portals_lut{$_}} if $ok;
		}
	}
}

sub ai_mapRoute_searchStep {
	my $r_args = shift;
	my @successors;
	my $r_cur, $r_suc;
	my $i;

	###check if failed
	if (!@{$$r_args{'openList'}}) {
		#failed!
		$$r_args{'done'} = 1;
		return;
	}
	
	$r_cur = shift @{$$r_args{'openList'}};

	###check if finished
	if ($$r_args{'dest'}{'source'}{'map'} eq $$r_cur{'dest'}{'map'}
		&& (@{$$r_args{'solutions'}{$$r_args{'dest'}{'source'}{'field'}.\%{$$r_cur{'dest'}{'pos'}}.\%{$$r_args{'dest'}{'source'}{'pos'}}}{'solution'}}
		|| $$r_args{'dest'}{'source'}{'pos'}{'x'} eq "")) {
		do {
			unshift @{$$r_args{'solutionList'}}, {%{$r_cur}};
			$r_cur = $$r_cur{'parent'} if (%{$$r_cur{'parent'}});
		} while ($r_cur != \%{$$r_args{'start'}});
		$$r_args{'done'} = 1;
		return;
	}

	ai_mapRoute_getSuccessors($r_args, \@successors, $r_cur);
	if ($$r_args{'waitingForSolution'}) {
		undef $$r_args{'waitingForSolution'};
		unshift @{$$r_args{'openList'}}, $r_cur;
		return;
	}

	$newg = $$r_cur{'g'} + $$r_args{'g_normal'};
	foreach $r_suc (@successors) {
		undef $found;
		undef $openFound;
		undef $closedFound;
		for($i = 0; $i < @{$$r_args{'openList'}}; $i++) {
			if ($$r_suc{'dest'}{'map'} eq $$r_args{'openList'}[$i]{'dest'}{'map'}
				&& $$r_suc{'dest'}{'pos'}{'x'} == $$r_args{'openList'}[$i]{'dest'}{'pos'}{'x'}
				&& $$r_suc{'dest'}{'pos'}{'y'} == $$r_args{'openList'}[$i]{'dest'}{'pos'}{'y'}) {
				if ($newg >= $$r_args{'openList'}[$i]{'g'}) {
					$found = 1;
					}
				$openFound = $i;
				last;
			}
		}
		next if ($found);
		
		undef $found;
		for($i = 0; $i < @{$$r_args{'closedList'}}; $i++) {
			if ($$r_suc{'dest'}{'map'} eq $$r_args{'closedList'}[$i]{'dest'}{'map'}
				&& $$r_suc{'dest'}{'pos'}{'x'} == $$r_args{'closedList'}[$i]{'dest'}{'pos'}{'x'}
				&& $$r_suc{'dest'}{'pos'}{'y'} == $$r_args{'closedList'}[$i]{'dest'}{'pos'}{'y'}) {
				if ($newg >= $$r_args{'closedList'}[$i]{'g'}) {
					$found = 1;
				}
				$closedFound = $i;
				last;
			}
		}
		next if ($found);
		if ($openFound ne "") {
			binRemoveAndShiftByIndex(\@{$$r_args{'openList'}}, $openFound);
		}
		if ($closedFound ne "") {
			binRemoveAndShiftByIndex(\@{$$r_args{'closedList'}}, $closedFound);
		}
		$$r_suc{'g'} = $newg;
		$$r_suc{'h'} = 0;
		$$r_suc{'f'} = $$r_suc{'g'} + $$r_suc{'h'};
		$$r_suc{'parent'} = $r_cur;
		minHeapAdd(\@{$$r_args{'openList'}}, $r_suc, "f");
	}
	push @{$$r_args{'closedList'}}, $r_cur;
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
	my ($r_ret, $x, $y, $map, $maxRouteDistance, $maxRouteTime, $attackOnRoute, $avoidPortals, $distFromGoal, $checkInnerPortals, $attackID) = @_;
	my %args;
#Solos Start
	my $pos_x;
	my $pos_y;
	$pos_x = int($chars[$config{'char'}]{'pos_to'}{'x'}) if ($chars[$config{'char'}]{'pos_to'}{'x'} ne "");
	$pos_y = int($chars[$config{'char'}]{'pos_to'}{'y'}) if ($chars[$config{'char'}]{'pos_to'}{'y'} ne "");
#Solos End
	$x = int($x) if ($x ne "");
	$y = int($y) if ($y ne "");
	$args{'returnHash'} = $r_ret;
	$args{'dest_x'} = $x;
	$args{'dest_y'} = $y;
	$args{'dest_map'} = $map;
	$args{'maxRouteDistance'} = $maxRouteDistance;
	$args{'maxRouteTime'} = $maxRouteTime;
	$args{'attackOnRoute'} = $attackOnRoute;
	$args{'avoidPortals'} = $avoidPortals;
	$args{'distFromGoal'} = $distFromGoal;
	$args{'checkInnerPortals'} = $checkInnerPortals;
	$args{'attackID'} = $attackID;
	undef %{$args{'returnHash'}};
	unshift @ai_seq, "route";
	unshift @ai_seq_args, \%args;
	debug "On route to: $maps_lut{$map.'.rsw'}($map): $x, $y\n", "route";
#Solos Start
#if kore is stuck
	if (($old_x == $x) && ($old_y == $y)) {
		$calcTo_SameSpot++;
	} else {
		$calcTo_SameSpot = 0;
		$old_x = $x;
		$old_y = $y;
	}
	if ($calcTo_SameSpot >= 10) {
		$calcTo_SameSpot = 0;
		Unstuck("Cannot find destination, trying to unstuck ...\n");
	}

	if (($old_pos_x == $pos_x) && ($old_pos_y == $pos_y)) {
		$calcFrom_SameSpot++;
	} else {
		$calcFrom_SameSpot = 0;
		$old_pos_x = $pos_x;
		$old_pos_y = $pos_y;
	}
	if ($calcFrom_SameSpot >= 10) {
		$calcFrom_SameSpot = 0;
		Unstuck("Invalid original position, trying to unstuck ...\n");
	}	

	if ($totalStuckCount >= 10) {
		RespawnUnstuck();
	}	
#Solos End
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
	my ($returnArray, $r_field, $r_start, $r_dest, $time_giveup) = @_;
	$args{'returnArray'} = $returnArray;
	$args{'field'} = $r_field;
	%{$args{'start'}} = %{$r_start};
	%{$args{'dest'}} = %{$r_dest};
	$args{'time_giveup'}{'timeout'} = $time_giveup;
	$args{'time_giveup'}{'time'} = time;
	$args{'destroyFunction'} = \&ai_route_getRoute_destroy;
	undef @{$args{'returnArray'}};
	unshift @ai_seq, "route_getRoute";
	unshift @ai_seq_args, \%args;
}

sub ai_route_getRoute_destroy {
	my $r_args = shift;
	if (!$buildType) {
		$CalcPath_destroy->Call($$r_args{'session'}) if ($$r_args{'session'} ne "");;
	} elsif ($buildType == 1) {
		Tools::CalcPath_destroy($$r_args{'session'}) if ($$r_args{'session'} ne "");;
	}
}

sub ai_route_searchStep {
	my $r_args = shift;
	my $ret;

	if (!$$r_args{'initialized'}) {
		#####
		my $SOLUTION_MAX = 5000;
		$$r_args{'solution'} = "\0" x ($SOLUTION_MAX*4+4);
		#####
		my $weights = join '', map chr $_, (255, 8, 7, 6, 5, 4, 3, 2, 1);
		$weights .= chr(1) x (256 - length($weights));
		if (!$buildType) {
			$$r_args{'session'} = $CalcPath_init->Call($$r_args{'solution'},
				$$r_args{'field'}{'dstMap'}, $weights, $$r_args{'field'}{'width'}, $$r_args{'field'}{'height'}, 
				pack("S*",$$r_args{'start'}{'x'}, $$r_args{'start'}{'y'}), pack("S*",$$r_args{'dest'}{'x'}, $$r_args{'dest'}{'y'}), $$r_args{'timeout'});
		} elsif ($buildType == 1) {
			$$r_args{'session'} = Tools::CalcPath_init(
				$$r_args{'solution'},
				$$r_args{'field'}{'dstMap'},
				$weights,
				$$r_args{'field'}{'width'},
				$$r_args{'field'}{'height'}, 
				pack("S*",$$r_args{'start'}{'x'}, $$r_args{'start'}{'y'}), 
				pack("S*",$$r_args{'dest'}{'x'}, $$r_args{'dest'}{'y'}),
				$$r_args{'timeout'});
		}
	}
	if ($$r_args{'session'} < 0) {
		$$r_args{'done'} = 1;
		return;
	}
	$$r_args{'initialized'} = 1;
	if (!$buildType) {
		$ret = $CalcPath_pathStep->Call($$r_args{'session'});
	} elsif ($buildType == 1) {
		$ret = Tools::CalcPath_pathStep($$r_args{'session'});
	}
	if (!$ret) {
		my $size = unpack("L",substr($$r_args{'solution'},0,4));
		my $j = 0;
		my $i;
		for ($i = ($size-1)*4+4; $i >= 4;$i-=4) {
			$$r_args{'returnArray'}[$j]{'x'} = unpack("S",substr($$r_args{'solution'}, $i, 2));
			$$r_args{'returnArray'}[$j]{'y'} = unpack("S",substr($$r_args{'solution'}, $i+2, 2));
			$j++;
		}
		$$r_args{'done'} = 1;
	}
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
	$ai_v{'portalTrace_mapChanged'} = 1;
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

sub attack {
	my $ID = shift;
	my %args;
	$args{'ai_attack_giveup'}{'time'} = time;
	$args{'ai_attack_giveup'}{'timeout'} = $timeout{'ai_attack_giveup'}{'timeout'};
	$args{'ID'} = $ID;
	%{$args{'pos_to'}} = %{$monsters{$ID}{'pos_to'}};
	%{$args{'pos'}} = %{$monsters{$ID}{'pos'}};
	unshift @ai_seq, "attack";
	unshift @ai_seq_args, \%args;
	message "Attacking: $monsters{$ID}{'name'} ($monsters{$ID}{'binID'}) [$monsters{$ID}{'nameID'}]\n";

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

				$Req = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"autoSwitch_$i"."_RightHand"}) if ($config{"autoSwitch_$i"."_RightHand"});
				$Leq = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"autoSwitch_$i"."_LeftHand"}) if ($config{"autoSwitch_$i"."_LeftHand"});
				$arrow = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{"autoSwitch_$i"."_Arrow"}) if ($config{"autoSwitch_$i"."_Arrow"});

				if ($Leq ne "" && !$chars[$config{'char'}]{'inventory'}[$Leq]{'equipped'}) { 
					$Ldef = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "equipped",32);
					sendUnequip(\$remote_socket,$chars[$config{'char'}]{'inventory'}[$Ldef]{'index'}) if($Ldef ne "");
					message "Auto Equiping [L] :".$config{"autoSwitch_$i"."_LeftHand"}." ($Leq)\n", "equip";
					sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$Leq]{'index'},$chars[$config{'char'}]{'inventory'}[$Leq]{'type_equip'}); 
				}
				if ($Req ne "" && !$chars[$config{'char'}]{'inventory'}[$Req]{'equipped'} || $config{"autoSwitch_$i"."_RightHand"} eq "[NONE]") {
					$Rdef = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "equipped",34);
					$Rdef = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "equipped",2) if($Rdef eq "");
					#Debug for 2hand Quicken and Bare Hand attack with 2hand weapon
					if(((binFind(\@skillsST,$skillsST_lut{2}) eq "" && binFind(\@skillsST,$skillsST_lut{23}) eq "" && binFind(\@skillsST,$skillsST_lut{68}) eq "") 
						|| $config{"autoSwitch_$i"."_RightHand"} eq "[NONE]" )
						&& $Rdef ne ""){
						sendUnequip(\$remote_socket,$chars[$config{'char'}]{'inventory'}[$Rdef]{'index'});
					}
					if ($Req eq $Leq) {
						for ($j=0; $j < @{$chars[$config{'char'}]{'inventory'}};$j++) {
							next if (!%{$chars[$config{'char'}]{'inventory'}[$j]});
							if ($chars[$config{'char'}]{'inventory'}[$j]{'name'} eq $config{"autoSwitch_$i"."_RightHand"} && $j != $Leq) {
								$Req = $j;
								last;
							}
						}
					}
					if ($config{"autoSwitch_$i"."_RightHand"} ne "[NONE]") {
						message "Auto Equiping [R] :".$config{"autoSwitch_$i"."_RightHand"}."($Req)\n", "equip"; 
						sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$Req]{'index'},$chars[$config{'char'}]{'inventory'}[$Req]{'type_equip'});
					}
				}
				if ($arrow ne "" && !$chars[$config{'char'}]{'inventory'}[$arrow]{'equipped'}) { 
					message "Auto Equiping [A] :".$config{"autoSwitch_$i"."_Arrow"}."\n", "equip";
					sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$arrow]{'index'},0); 
				}
				if ($config{"autoSwitch_$i"."_Distance"} && $config{"autoSwitch_$i"."_Distance"} != $config{'attackDistance'}) { 
					$ai_v{'attackDistance'} = $config{'attackDistance'};
					$config{'attackDistance'} = $config{"autoSwitch_$i"."_Distance"};
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
		if ($config{'autoSwitch_default_LeftHand'}) { 
			$Leq = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{'autoSwitch_default_LeftHand'});
			if($Leq ne "" && !$chars[$config{'char'}]{'inventory'}[$Leq]{'equipped'}) {
				$Ldef = findIndex(\@{$chars[$config{'char'}]{'inventory'}}, "equipped",32);
				sendUnequip(\$remote_socket,$chars[$config{'char'}]{'inventory'}[$Ldef]{'index'}) if($Ldef ne "" && $chars[$config{'char'}]{'inventory'}[$Ldef]{'equipped'});
				message "Auto equiping default [L] :".$config{'autoSwitch_default_LeftHand'}."\n", "equip";
				sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$Leq]{'index'},$chars[$config{'char'}]{'inventory'}[$Leq]{'type_equip'});
			}
		}
		if ($config{'autoSwitch_default_RightHand'}) { 
			$Req = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{'autoSwitch_default_RightHand'}); 
			if($Req ne "" && !$chars[$config{'char'}]{'inventory'}[$Req]{'equipped'}) {
				message "Auto equiping default [R] :".$config{'autoSwitch_default_RightHand'}."\n", "equip"; 
				sendEquip(\$remote_socket, $chars[$config{'char'}]{'inventory'}[$Req]{'index'},$chars[$config{'char'}]{'inventory'}[$Req]{'type_equip'});
			}
		}
		if ($config{'autoSwitch_default_Arrow'}) { 
			$arrow = findIndexString_lc(\@{$chars[$config{'char'}]{'inventory'}}, "name", $config{'autoSwitch_default_Arrow'}); 
			if($arrow ne "" && !$chars[$config{'char'}]{'inventory'}[$arrow]{'equipped'}) {
				message "Auto equiping default [A] :".$config{'autoSwitch_default_Arrow'}."\n", "equip"; 
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
#Solos Start
	my $pos_x;
	my $pos_y;
	$pos_x = int($chars[$config{'char'}]{'pos_to'}{'x'}) if ($chars[$config{'char'}]{'pos_to'}{'x'} ne "");
	$pos_y = int($chars[$config{'char'}]{'pos_to'}{'y'}) if ($chars[$config{'char'}]{'pos_to'}{'y'} ne "");
#Solos End
	$args{'move_to'}{'x'} = $x;
	$args{'move_to'}{'y'} = $y;
	$args{'triggeredByRoute'} = $triggeredByRoute;
	$args{'attackID'} = $attackID;
	$args{'ai_move_giveup'}{'time'} = time;
	$args{'ai_move_giveup'}{'timeout'} = $timeout{'ai_move_giveup'}{'timeout'};
	unshift @ai_seq, "move";
	unshift @ai_seq_args, \%args;
#Solos Start
#if kore is stuck
	if (($move_x == $x) && ($move_y == $y)) {
		$moveTo_SameSpot++;
	} else {
		$moveTo_SameSpot = 0;
		$move_x = $x;
		$move_y = $y;
	}
	if ($moveTo_SameSpot == 20) {
		ClearRouteAI("Keep trying to move to same spot, clearing route AI to unstuck ...\n");
	}
	if ($moveTo_SameSpot >= 50) {
		$moveTo_SameSpot = 0;
		Unstuck("Keep trying to move to same spot, teleporting to unstuck ...\n");
	}

	if (($move_pos_x == $pos_x) && ($move_pos_y == $pos_y)) {
		$moveFrom_SameSpot++;
	} else {
		$moveFrom_SameSpot = 0;
		$move_pos_x = $pos_x;
		$move_pos_y = $pos_y;
	}
	if ($moveFrom_SameSpot == 20) {
		ClearRouteAI("Keep trying to move from same spot, clearing route AI to unstuck ...\n");
	}
	if ($moveFrom_SameSpot >= 50) {
		$moveFrom_SameSpot = 0;
		Unstuck("Keep trying to move from same spot, teleport to unstuck ...\n");
	}											    

	if ($totalStuckCount >= 10) {
		RespawnUnstuck();
	}	
#Solos End
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
	killConnection(\$remote_socket);
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
	debug "Targeting for Pickup: $items{$ID}{'name'} ($items{$ID}{'binID'})\n";
}

#######################################
#######################################
#AI MATH
#######################################
#######################################


sub distance {
	my $r_hash1 = shift;
	my $r_hash2 = shift;
	my %line;
	if ($r_hash2) {
		$line{'x'} = abs($$r_hash1{'x'} - $$r_hash2{'x'});
		$line{'y'} = abs($$r_hash1{'y'} - $$r_hash2{'y'});
	} else {
		%line = %{$r_hash1};
	}
	return sqrt($line{'x'} ** 2 + $line{'y'} ** 2);
}

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
#CONFIG MODIFIERS
#######################################
#######################################

sub auth {
	my $user = shift;
	my $flag = shift;
	if ($flag) {
		warning "Authorized user '$user' for admin\n";
	} else {
		message "Revoked admin privilages for user '$user'\n";
	}	
	$overallAuth{$user} = $flag;
	writeDataFile("control/overallAuth.txt", \%overallAuth);
}

sub configModify {
	my $key = shift;
	my $val = shift;
	my $quiet = shift;
	message("Config '$key' set to $val\n") unless ($quiet);
	$config{$key} = $val;
	writeDataFileIntact($Settings::config_file, \%config);
}

sub setTimeout {
	my $timeout = shift;
	my $time = shift;
	$timeout{$timeout}{'timeout'} = $time;
	message "Timeout '$timeout' set to $time\n";
	writeDataFileIntact2("control/timeouts.txt", \%timeout);
}


#######################################
#######################################
#OUTGOING PACKET FUNCTIONS
#######################################
#######################################

sub decrypt {
	my $r_msg = shift;
	my $themsg = shift;
	my @mask;
	my $i;
	my ($temp, $msg_temp, $len_add, $len_total, $loopin, $len, $val);
	if ($config{'encrypt'} == 1) {
		undef $$r_msg;
		undef $len_add;
		undef $msg_temp;
		for ($i = 0; $i < 13;$i++) {
			$mask[$i] = 0;
		}
		$len = unpack("S1",substr($themsg,0,2));
		$val = unpack("S1",substr($themsg,2,2));
		{
			use integer;
			$temp = ($val * $val * 1391);
		}
		$temp = ~(~($temp));
		$temp = $temp % 13;
		$mask[$temp] = 1;
		{
			use integer;
			$temp = $val * 1397;
		}
		$temp = ~(~($temp));
		$temp = $temp % 13;
		$mask[$temp] = 1;
		for($loopin = 0; ($loopin + 4) < $len; $loopin++) {
 			if (!($mask[$loopin % 13])) {
  				$msg_temp .= substr($themsg,$loopin + 4,1);
			}
		}
		if (($len - 4) % 8 != 0) {
			$len_add = 8 - (($len - 4) % 8);
		}
		$len_total = $len + $len_add;
		$$r_msg = $msg_temp.substr($themsg, $len_total, length($themsg) - $len_total);
	} elsif ($config{'encrypt'} >= 2) {
		undef $$r_msg;
		undef $len_add;
		undef $msg_temp;
		for ($i = 0; $i < 17;$i++) {
			$mask[$i] = 0;
		}
		$len = unpack("S1",substr($themsg,0,2));
		$val = unpack("S1",substr($themsg,2,2));
		{
			use integer;
			$temp = ($val * $val * 34953);
		}
		$temp = ~(~($temp));
		$temp = $temp % 17;
		$mask[$temp] = 1;
		{
			use integer;
			$temp = $val * 2341;
		}
		$temp = ~(~($temp));
		$temp = $temp % 17;
		$mask[$temp] = 1;
		for($loopin = 0; ($loopin + 4) < $len; $loopin++) {
 			if (!($mask[$loopin % 17])) {
  				$msg_temp .= substr($themsg,$loopin + 4,1);
			}
		}
		if (($len - 4) % 8 != 0) {
			$len_add = 8 - (($len - 4) % 8);
		}
		$len_total = $len + $len_add;
		$$r_msg = $msg_temp.substr($themsg, $len_total, length($themsg) - $len_total);
	} else {
		$$r_msg = $themsg;
	}
}

sub encrypt {
	my $r_msg = shift;
	my $themsg = shift;
	my @mask;
	my $newmsg;
	my ($in, $out);
	if ($config{'encrypt'} == 1 && $conState >= 5) {
		$out = 0;
		undef $newmsg;
		for ($i = 0; $i < 13;$i++) {
			$mask[$i] = 0;
		}
		{
			use integer;
			$temp = ($encryptVal * $encryptVal * 1391);
		}
		$temp = ~(~($temp));
		$temp = $temp % 13;
		$mask[$temp] = 1;
		{
			use integer;
			$temp = $encryptVal * 1397;
		}
		$temp = ~(~($temp));
		$temp = $temp % 13;
		$mask[$temp] = 1;
		for($in = 0; $in < length($themsg); $in++) {
			if ($mask[$out % 13]) {
				$newmsg .= pack("C1", int(rand() * 255) & 0xFF);
				$out++;
			}
			$newmsg .= substr($themsg, $in, 1);
			$out++;
		}
		$out += 4;
		$newmsg = pack("S2", $out, $encryptVal) . $newmsg;
		while ((length($newmsg) - 4) % 8 != 0) {
			$newmsg .= pack("C1", (rand() * 255) & 0xFF);
		}
	} elsif ($config{'encrypt'} >= 2 && $conState >= 5) {
		$out = 0;
		undef $newmsg;
		for ($i = 0; $i < 17;$i++) {
			$mask[$i] = 0;
		}
		{
			use integer;
			$temp = ($encryptVal * $encryptVal * 34953);
		}
		$temp = ~(~($temp));
		$temp = $temp % 17;
		$mask[$temp] = 1;
		{
			use integer;
			$temp = $encryptVal * 2341;
		}
		$temp = ~(~($temp));
		$temp = $temp % 17;
		$mask[$temp] = 1;
		for($in = 0; $in < length($themsg); $in++) {
			if ($mask[$out % 17]) {
				$newmsg .= pack("C1", int(rand() * 255) & 0xFF);
				$out++;
			}
			$newmsg .= substr($themsg, $in, 1);
			$out++;
		}
		$out += 4;
		$newmsg = pack("S2", $out, $encryptVal) . $newmsg;
		while ((length($newmsg) - 4) % 8 != 0) {
			$newmsg .= pack("C1", (rand() * 255) & 0xFF);
		}
	} else {
		$newmsg = $themsg;
	}

	$$r_msg = $newmsg;
}

sub injectMessage {
	my $message = shift;
	my $name = "|";
	my $msg .= $name . " : " . $message . chr(0);
	encrypt(\$msg, $msg);
	$msg = pack("C*",0x09, 0x01) . pack("S*", length($name) + length($message) + 12) . pack("C*",0,0,0,0) . $msg;
	encrypt(\$msg, $msg);
	sendToClientByInject(\$remote_socket, $msg);
}

sub injectAdminMessage {
	my $message = shift;
	$msg = pack("C*",0x9A, 0x00) . pack("S*", length($message)+5) . $message .chr(0);
	encrypt(\$msg, $msg);
	sendToClientByInject(\$remote_socket, $msg);
}

sub sendAddSkillPoint {
	my $r_socket = shift;
	my $skillID = shift;
	my $msg = pack("C*", 0x12, 0x01) . pack("S*", $skillID);
	sendMsgToServer($r_socket, $msg);
}

sub sendAddStatusPoint {
	my $r_socket = shift;
	my $statusID = shift;
	my $msg = pack("C*", 0xBB, 0) . pack("S*", $statusID) . pack("C*", 0x01);
	sendMsgToServer($r_socket, $msg);
}

sub sendAlignment {
	my $r_socket = shift;
	my $ID = shift;
	my $alignment = shift;
	my $msg = pack("C*", 0x49, 0x01) . $ID . pack("C*", $alignment);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Alignment: ".getHex($ID).", $alignment\n", "sendPacket", 2;
}

sub sendAttack {
	my $r_socket = shift;
	my $monID = shift;
	my $flag = shift;
	my $msg = pack("C*", 0x89, 0x00) . $monID . pack("C*", $flag);
	sendMsgToServer($r_socket, $msg);
	debug "Sent attack: ".getHex($monID)."\n", "sendPacket", 2;
}

sub sendAttackStop {
	my $r_socket = shift;
	#my $msg = pack("C*", 0x18, 0x01);
	# Apparently this packet is wrong. The server disconnects us if we do this.
	# Sending a move command to the current position seems to be able to emulate
	# what this function is supposed to do.
	sendMove ($r_socket, $chars[$config{'char'}]{'pos_to'}{'x'}, $chars[$config{'char'}]{'pos_to'}{'y'});
	debug "Sent stop attack\n", "sendPacket";
}

sub sendBuy {
	my $r_socket = shift;
	my $ID = shift;
	my $amount = shift;
	my $msg = pack("C*", 0xC8, 0x00, 0x08, 0x00) . pack("S*", $amount, $ID);
	sendMsgToServer($r_socket, $msg);
	debug "Sent buy: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendBuyVender {
	my $r_socket = shift;
	my $venderID = shift;
	my $ID = shift;
	my $amount = shift;
	my $msg = pack("C*", 0x34, 0x01, 0x0C, 0x00) . $venderID . pack("S*", $amount, $ID);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Vender Buy: ".getHex($ID)."\n", "sendPacket";
}

sub sendCartAdd {
	my $r_socket = shift;
	my $index = shift;
	my $amount = shift;
	my $msg = pack("C*", 0x26, 0x01) . pack("S*", $index) . pack("L*", $amount);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Cart Add: $index x $amount\n", "sendPacket", 2;
}

sub sendCartGet {
	my $r_socket = shift;
	my $index = shift;
	my $amount = shift;
	my $msg = pack("C*", 0x27, 0x01) . pack("S*", $index) . pack("L*", $amount);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Cart Get: $index x $amount\n", "sendPacket", 2;
}

sub sendCharLogin {
	my $r_socket = shift;
	my $char = shift;
	my $msg = pack("C*", 0x66,0) . pack("C*",$char);
	sendMsgToServer($r_socket, $msg);
}

sub sendChat {
	my $r_socket = shift;
	my $message = shift;
	my $msg = pack("C*",0x8C, 0x00) . pack("S*", length($chars[$config{'char'}]{'name'}) + length($message) + 8) . 
		$chars[$config{'char'}]{'name'} . " : " . $message . chr(0);
	sendMsgToServer($r_socket, $msg);
}

sub sendChatRoomBestow {
	my $r_socket = shift;
	my $name = shift;
	$name = substr($name, 0, 24) if (length($name) > 24);
	$name = $name . chr(0) x (24 - length($name));
	my $msg = pack("C*", 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00).$name;
	sendMsgToServer($r_socket, $msg);
	debug "Sent Chat Room Bestow: $name\n", "sendPacket", 2;
}

sub sendChatRoomChange {
	my $r_socket = shift;
	my $title = shift;
	my $limit = shift;
	my $public = shift;
	my $password = shift;
	$password = substr($password, 0, 8) if (length($password) > 8);
	$password = $password . chr(0) x (8 - length($password));
	my $msg = pack("C*", 0xDE, 0x00).pack("S*", length($title) + 15, $limit).pack("C*",$public).$password.$title;
	sendMsgToServer($r_socket, $msg);
	debug "Sent Change Chat Room: $title, $limit, $public, $password\n", "sendPacket", 2;
}

sub sendChatRoomCreate {
	my $r_socket = shift;
	my $title = shift;
	my $limit = shift;
	my $public = shift;
	my $password = shift;
	$password = substr($password, 0, 8) if (length($password) > 8);
	$password = $password . chr(0) x (8 - length($password));
	my $msg = pack("C*", 0xD5, 0x00).pack("S*", length($title) + 15, $limit).pack("C*",$public).$password.$title;
	sendMsgToServer($r_socket, $msg);
	debug "Sent Create Chat Room: $title, $limit, $public, $password\n", "sendPacket", 2;
}

sub sendChatRoomJoin {
	my $r_socket = shift;
	my $ID = shift;
	my $password = shift;
	$password = substr($password, 0, 8) if (length($password) > 8);
	$password = $password . chr(0) x (8 - length($password));
	my $msg = pack("C*", 0xD9, 0x00).$ID.$password;
	sendMsgToServer($r_socket, $msg);
	debug "Sent Join Chat Room: ".getHex($ID)." $password\n", "sendPacket", 2;
}

sub sendChatRoomKick {
	my $r_socket = shift;
	my $name = shift;
	$name = substr($name, 0, 24) if (length($name) > 24);
	$name = $name . chr(0) x (24 - length($name));
	my $msg = pack("C*", 0xE2, 0x00).$name;
	sendMsgToServer($r_socket, $msg);
	debug "Sent Chat Room Kick: $name\n", "sendPacket", 2;
}

sub sendChatRoomLeave {
	my $r_socket = shift;
	my $msg = pack("C*", 0xE3, 0x00);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Leave Chat Room\n", "sendPacket", 2;
}

sub sendCloseShop {
	my $r_socket = shift;
	my $msg = pack("C*", 0x2E, 0x01);
	sendMsgToServer($r_socket, $msg);
	debug "Shop Closed: $index x $amount\n", "sendPacket", 2;
	$shopstarted = 0;
	$timeout{'ai_shop'}{'time'} = time;
}

sub sendCurrentDealCancel {
	my $r_socket = shift;
	my $msg = pack("C*", 0xED, 0x00);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Cancel Current Deal\n", "sendPacket", 2;
}

sub sendDeal {
	my $r_socket = shift;
	my $ID = shift;
	my $msg = pack("C*", 0xE4, 0x00) . $ID;
	sendMsgToServer($r_socket, $msg);
	debug "Sent Initiate Deal: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendDealAccept {
	my $r_socket = shift;
	my $msg = pack("C*", 0xE6, 0x00, 0x03);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Accept Deal\n", "sendPacket", 2;
}

sub sendDealAddItem {
	my $r_socket = shift;
	my $index = shift;
	my $amount = shift;
	my $msg = pack("C*", 0xE8, 0x00) . pack("S*", $index) . pack("L*",$amount);	
	sendMsgToServer($r_socket, $msg);
	debug "Sent Deal Add Item: $index, $amount\n", "sendPacket", 2;
}

sub sendDealCancel {
	my $r_socket = shift;
	my $msg = pack("C*", 0xE6, 0x00, 0x04);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Cancel Deal\n", "sendPacket", 2;
}

sub sendDealFinalize {
	my $r_socket = shift;
	my $msg = pack("C*", 0xEB, 0x00);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Deal OK\n", "sendPacket", 2;
}

sub sendDealOK {
	my $r_socket = shift;
	my $msg = pack("C*", 0xEB, 0x00);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Deal OK\n", "sendPacket", 2;
}

sub sendDealTrade {
	my $r_socket = shift;
	my $msg = pack("C*", 0xEF, 0x00);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Deal Trade\n", "sendPacket", 2;
}

sub sendDrop {
	my $r_socket = shift;
	my $index = shift;
	my $amount = shift;
	my $msg = pack("C*", 0xA2, 0x00) . pack("S*", $index, $amount);
	sendMsgToServer($r_socket, $msg);
	debug "Sent drop: $index x $amount\n", "sendPacket", 2;
}

sub sendEmotion {
	my $r_socket = shift;
	my $ID = shift;
	my $msg = pack("C*", 0xBF, 0x00).pack("C1",$ID);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Emotion\n", "sendPacket", 2;
}

sub sendEnteringVender {
	my $r_socket = shift;
	my $ID = shift;
	my $msg = pack("C*", 0x30, 0x01) . $ID;
	sendMsgToServer($r_socket, $msg);
	debug "Sent Entering Vender: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendEquip{
	my $r_socket = shift;
	my $index = shift;
	my $type = shift;
	my $msg = pack("C*", 0xA9, 0x00) . pack("S*", $index) .  pack("S*", $type);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Equip: $index\n" , 2;
}

sub sendGameLogin {
	my $r_socket = shift;
	my $accountID = shift;
	my $sessionID = shift;
	my $sex = shift;
	my $msg = pack("C*", 0x65,0) . $accountID . $sessionID . pack("C*", 0,0,0,0,0,0,$sex);
	sendMsgToServer($r_socket, $msg);
}

sub sendGetPlayerInfo {
	my $r_socket = shift;
	my $ID = shift;
	my $msg = pack("C*", 0x94, 0x00) . $ID;
	sendMsgToServer($r_socket, $msg);
	debug "Sent get player info: ID - ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendGetStoreList {
	my $r_socket = shift;
	my $ID = shift;
	my $msg = pack("C*", 0xC5, 0x00) . $ID . pack("C*",0x00);
	sendMsgToServer($r_socket, $msg);
	debug "Sent get store list: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendGetSellList {
	my $r_socket = shift;
	my $ID = shift;
	my $msg = pack("C*", 0xC5, 0x00) . $ID . pack("C*",0x01);
	sendMsgToServer($r_socket, $msg);
	debug "Sent sell to NPC: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendGuildAlly{
	my $r_socket = shift;
	my $ID = shift;
	my $flag = shift;
	my $msg = pack("C*", 0x72, 0x01).$ID.pack("L1", $flag);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Ally Guild : ".getHex($ID).", $flag\n", "sendPacket", 2;
}

sub sendGuildChat {
	my $r_socket = shift;
	my $message = shift;
	my $msg = pack("C*",0x7E, 0x01) . pack("S*",length($chars[$config{'char'}]{'name'}) + length($message) + 8) .
	$chars[$config{'char'}]{'name'} . " : " . $message . chr(0);
	sendMsgToServer($r_socket, $msg);
}

sub sendGuildInfoRequest {
	my $r_socket = shift;
	my $msg = pack("C*", 0x4d, 0x01);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Guild Information Request\n", "sendPacket";
}

sub sendGuildJoin{
	my $r_socket = shift;
	my $ID = shift;
	my $flag = shift;
	my $msg = pack("C*", 0x6B, 0x01).$ID.pack("L1", $flag);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Join Guild : ".getHex($ID).", $flag\n", "sendPacket";
}

sub sendGuildMemberNameRequest {
	my $r_socket = shift;
	my $ID = shift;
	my $msg = pack("C*", 0x93, 0x01) . $ID;
	sendMsgToServer($r_socket, $msg);
	debug "Sent Guild Member Name Request : ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendGuildRequest {
	my $r_socket = shift;
	my $page = shift;
	my $msg = pack("C*", 0x4f, 0x01).pack("L1", $page);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Guild Request Page : ".$page."\n", "sendPacket";
}

sub sendIdentify {
	my $r_socket = shift;
	my $index = shift;
	my $msg = pack("C*", 0x78, 0x01) . pack("S*", $index);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Identify: $index\n", "sendPacket", 2;
}

sub sendIgnore {
	my $r_socket = shift;
	my $name = shift;
	my $flag = shift;
	$name = substr($name, 0, 24) if (length($name) > 24);
	$name = $name . chr(0) x (24 - length($name));
	my $msg = pack("C*", 0xCF, 0x00).$name.pack("C*", $flag);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Ignore: $name, $flag\n", "sendPacket", 2;
}

sub sendIgnoreAll { 
	my $r_socket = shift; 
	my $flag = shift; 
	my $msg = pack("C*", 0xD0, 0x00).pack("C*", $flag); 
	sendMsgToServer($r_socket, $msg); 
	debug "Sent Ignore All: $flag\n", "sendPacket", 2;
}

#sendGetIgnoreList - chobit 20021223 
sub sendIgnoreListGet {  
	my $r_socket = shift;  
	my $flag = shift;  
	my $msg = pack("C*", 0xD3, 0x00);  
	sendMsgToServer($r_socket, $msg); 
	debug "Sent get Ignore List: $flag\n", "sendPacket", 2;
}

sub sendItemUse {
	my $r_socket = shift;
	my $ID = shift;
	my $targetID = shift;
	my $msg = pack("C*", 0xA7, 0x00).pack("S*",$ID).$targetID;
	sendMsgToServer($r_socket, $msg);
	debug "Item Use: $ID\n", "sendPacket", 2;
}

sub sendLook {
	my $r_socket = shift;
	my $body = shift;
	my $head = shift;
	my $msg = pack("C*", 0x9B, 0x00, $head, 0x00, $body);
	sendMsgToServer($r_socket, $msg);
	debug "Sent look: $body $head\n", "sendPacket", 2;
	$chars[$config{'char'}]{'look'}{'head'} = $head;
	$chars[$config{'char'}]{'look'}{'body'} = $body;
}

sub sendMapLoaded {
	my $r_socket = shift;
	my $msg = pack("C*", 0x7D,0x00);
	debug "Sending Map Loaded\n", "sendPacket";
	sendMsgToServer($r_socket, $msg);
}

sub sendMapLogin {
	my $r_socket = shift;
	my $accountID = shift;
	my $charID = shift;
	my $sessionID = shift;
	my $sex = shift;
	my $msg = pack("C*", 0x72,0) . $accountID . $charID . $sessionID . pack("L1", getTickCount()) . pack("C*",$sex);
	sendMsgToServer($r_socket, $msg);
}

sub sendMasterCodeRequest {
	my $r_socket = shift;
	my $type = shift;
	my $msg = "";
	if ($type == 1) {
		 $msg = pack("C*", 0x04, 0x02, 0x7B, 0x8A, 0xA8, 0x90, 0x2F, 0xD8, 0xE8, 0x30, 0xF8, 0xA5, 0x25, 0x7A, 0x0D, 0x3B, 0xCE, 0x52);
	} elsif ($type == 2) {
		 $msg = pack("C*", 0x04, 0x02, 0x27, 0x6A, 0x2C, 0xCE, 0xAF, 0x88, 0x01, 0x87, 0xCB, 0xB1, 0xFC, 0xD5, 0x90, 0xC4, 0xED, 0xD2);
	}
	$msg .= pack("C*", 0xDB, 0x01);
	sendMsgToServer($r_socket, $msg);
}

sub sendMasterLogin {
	my $r_socket = shift;
	my $username = shift;
	my $password = shift;
	my $msg = pack("C*", 0x64,0,$config{'version'},0,0,0) . $username . chr(0) x (24 - length($username)) . 
			$password . chr(0) x (24 - length($password)) . pack("C*", $config{"master_version_$config{'master'}"});
	sendMsgToServer($r_socket, $msg);
}

sub sendMasterSecureLogin {
	my $r_socket = shift;
	my $username = shift;
	my $password = shift; 
	my $salt = shift;
	my $version = shift;
	my $master_version = shift;
	my $type =  shift;
	my $account = shift;
	my $md5 = Digest::MD5->new;
	my ($msg);

	if ($type % 2 == 1) {
		$salt = $salt . $password;
	} else {
		$salt = $password . $salt;
	}
	$md5->add($salt);
	if ($type < 3 ) {
		$msg = pack("C*", 0xDD, 0x01) . pack("L1", $version) . $username . chr(0) x (24 - length($username)) .
					 $md5->digest . pack("C*", $master_version);
	}else{
		$account = ($account>0) ? $account -1 : 0;
		$msg = pack("C*", 0xFA, 0x01) . pack("L1", $version) . $username . chr(0) x (24 - length($username)) .
					 $md5->digest . pack("C*", $master_version). pack("C1", $account);
	}
	sendMsgToServer($r_socket, $msg);
}

sub sendMemo {
	my $r_socket = shift;
	my $msg = pack("C*", 0x1D, 0x01);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Memo\n", "sendPacket", 2;
}

sub sendMove {
	my $r_socket = shift;
	my $x = shift;
	my $y = shift;
	my $msg = pack("C*", 0x85, 0x00) . getCoordString($x, $y);
	sendMsgToServer($r_socket, $msg);
	debug "Sent move to: $x, $y\n", "sendPacket", 2;
}

sub sendOpenShop {
	my $r_socket = shift;
	my ($i, $index, $totalitem, $items_selling, $citem, $oldid);
	my %itemtosell;
	my @itemtosellorder;

	$shopstarted = 0;
	if ($chars[$config{'char'}]{'skills'}{'MC_VENDING'}{'lv'}) {
		if ($shop{'shop_title'} eq "") {
			error "Cannot open shop: you must specify a title for your shop.\n";
			return 0;
		}

		$i = 0;
		$items_selling = 0;
		while ($shop{"name_$i"} ne "" && $items_selling < $chars[$config{'char'}]{'skills'}{'MC_VENDING'}{'lv'} + 2) {
			for ($index = 0; $index < @{$cart{'inventory'}}; $index++) {
				next if (!%{$cart{'inventory'}[$index]});
				if ($cart{'inventory'}[$index]{'name'} eq $shop{"name_$i"}) {
					$citem = $index;
					foreach (keys %itemtosell) {
						if ($_ eq $index) {
							$oldid = $_;
							$citem = -1;
						}
					}

					if ($citem >- 1) {
						$itemtosell{$index}{'index'} = $index;

						# Calculate amount
						if ($shop{"quantity_$i"} > 0 && $cart{'inventory'}[$index]{'amount'} >= $shop{"quantity_$i"}) {
							$itemtosell{$index}{'amount'} = $shop{"quantity_$i"};
						} elsif ($shop{"quantity_$i"} > 0 && $cart{'inventory'}[$index]{'amount'} < $shop{"quantity_$i"}) {
							$itemtosell{$index}{'amount'} = $cart{'inventory'}[$index]{'amount'};
						} else {
							$itemtosell{$index}{'amount'} = $cart{'inventory'}[$index]{'amount'};
						}

						# Calculate price
						if ($shop{"price_$i"} > 10000000) {
							$itemtosell{$index}{'price'} = 10000000;
						} elsif ($shop{"price_$i"} > 0) {
							$itemtosell{$index}{'price'} = $shop{"price_$i"};
						} else {
							$itemtosell{$index}{'price'} = 1;
						}
						$items_selling++;
						$itemtosellorder[$items_selling] = $index;
						last;
					}
				}
			}
			$i++;
		}

		if (!$items_selling) {
			error "Cannot open shop: no items to sell.\n";
			return 0;
		}

		my $length = 0x55 + 0x08 * $items_selling;
		my $msg = pack("C*", 0xB2, 0x01) . pack("S*", $length) . 
		$shop{'shop_title'} . chr(0) x (80 - length($shop{'shop_title'})) .  pack("C*", 0x01);

		if ($config{'shop_random'}) {
			@itemtosellorder = keys %itemtosell;
		}
		foreach (@itemtosellorder) {
			next if (!defined $itemtosell{$_});
			$msg .= pack("S1",$itemtosell{$_}{'index'}) . pack("S1", $itemtosell{$_}{'amount'}) . pack("L1", $itemtosell{$_}{'price'});
		}
		message "$length : ".length($msg)."; $items_selling\n";
		if(length($msg) == $length) {
			sendMsgToServer($r_socket, $msg);
			message "Shop opened ($shop{'shop_title'}) with $items_selling items.\n", "success";
			$shopstarted = 1;
			return 1;
		} else {
			error "Unknown error while opening shop.\n";
			return 0;
		}
	} else {
		error "Cannot open shop: you don't have the Vending skill.\n";
		return 0;
	}
}

sub sendOpenWarp {
	my ($r_socket, $map) = @_;
	my $msg = pack("C*", 0x1b, 0x01, 0x1b, 0x00) . $map .
		chr(0) x (16 - length($map));
	sendMsgToServer($r_socket, $msg);
}

sub sendPartyChat {
	my $r_socket = shift;
	my $message = shift;
	my $msg = pack("C*",0x08, 0x01) . pack("S*",length($chars[$config{'char'}]{'name'}) + length($message) + 8) . 
		$chars[$config{'char'}]{'name'} . " : " . $message . chr(0);
	sendMsgToServer($r_socket, $msg);
}

sub sendPartyJoin {
	my $r_socket = shift;
	my $ID = shift;
	my $flag = shift;
	my $msg = pack("C*", 0xFF, 0x00).$ID.pack("L", $flag);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Join Party: ".getHex($ID).", $flag\n", "sendPacket", 2;
}

sub sendPartyJoinRequest {
	my $r_socket = shift;
	my $ID = shift;
	my $msg = pack("C*", 0xFC, 0x00).$ID;
	sendMsgToServer($r_socket, $msg);
	debug "Sent Request Join Party: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendPartyKick {
	my $r_socket = shift;
	my $ID = shift;
	my $name = shift;
	$name = substr($name, 0, 24) if (length($name) > 24);
	$name = $name . chr(0) x (24 - length($name));
	my $msg = pack("C*", 0x03, 0x01).$ID.$name;
	sendMsgToServer($r_socket, $msg);
	debug "Sent Kick Party: ".getHex($ID).", $name\n", "sendPacket", 2;
}

sub sendPartyLeave {
	my $r_socket = shift;
	my $msg = pack("C*", 0x00, 0x01);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Leave Party: $name\n", "sendPacket", 2;
}

sub sendPartyOrganize {
	my $r_socket = shift;
	my $name = shift;
	$name = substr($name, 0, 24) if (length($name) > 24);
	$name = $name . chr(0) x (24 - length($name));
	my $msg = pack("C*", 0xF9, 0x00).$name;
	sendMsgToServer($r_socket, $msg);
	debug "Sent Organize Party: $name\n", "sendPacket", 2;
}

sub sendPartyShareEXP {
	my $r_socket = shift;
	my $flag = shift;
	my $msg = pack("C*", 0x02, 0x01).pack("L", $flag);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Party Share: $flag\n", "sendPacket", 2;
}

sub sendQuit {
	my $r_socket = shift;
	my $msg = pack("C*", 0x8A, 0x01, 0x00, 0x00);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Quit\n", "sendPacket", 2;
}

sub sendRaw {
	my $r_socket = shift;
	my $raw = shift;
	my @raw;
	my $msg;
	@raw = split / /, $raw;
	foreach (@raw) {
		$msg .= pack("C", hex($_));
	}
	sendMsgToServer($r_socket, $msg);
	debug "Sent Raw Packet: @raw\n", "sendPacket", 2;
}

sub sendRespawn {
	my $r_socket = shift;
	my $msg = pack("C*", 0xB2, 0x00, 0x00);
	sendMsgToServer($r_socket, $msg);
  debug "Sent Respawn\n", "sendPacket", 2;
}

sub sendPrivateMsg {
	my $r_socket = shift;
	my $user = shift;
	my $message = shift;
	my $msg = pack("C*",0x96, 0x00) . pack("S*",length($message) + 29) . $user . chr(0) x (24 - length($user)) .
			$message . chr(0);
	sendMsgToServer($r_socket, $msg);
}

sub sendSell {
	my $r_socket = shift;
	my $index = shift;
	my $amount = shift;
	my $msg = pack("C*", 0xC9, 0x00, 0x08, 0x00) . pack("S*", $index, $amount);
	sendMsgToServer($r_socket, $msg);
	debug "Sent sell: $index x $amount\n", "sendPacket", 2;
	
}

sub sendSit {
	my $r_socket = shift;
	my $msg = pack("C*", 0x89,0x00, 0x00, 0x00, 0x00, 0x00, 0x02);
	sendMsgToServer($r_socket, $msg);
	debug "Sitting\n", "sendPacket", 2;
}

sub sendSkillUse {
	my $r_socket = shift;
	my $ID = shift;
	my $lv = shift;
	my $targetID = shift;
	my $msg = pack("C*", 0x13, 0x01).pack("S*",$lv,$ID).$targetID;
	sendMsgToServer($r_socket, $msg);
	debug "Skill Use: $ID\n", "sendPacket", 2;
}

sub sendSkillUseLoc {
	my $r_socket = shift;
	my $ID = shift;
	my $lv = shift;
	my $x = shift;
	my $y = shift;
	my $msg = pack("C*", 0x16, 0x01).pack("S*",$lv,$ID,$x,$y);
	sendMsgToServer($r_socket, $msg);
	debug "Skill Use Loc: $ID\n", "sendPacket", 2;
}

sub sendStorageAdd {
	my $r_socket = shift;
	my $index = shift;
	my $amount = shift;
	my $msg = pack("C*", 0xF3, 0x00) . pack("S*", $index) . pack("L*", $amount);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Storage Add: $index x $amount\n", "sendPacket", 2;
}

sub sendStorageClose {
	my $r_socket = shift;
	my $msg = pack("C*", 0xF7, 0x00);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Storage Done\n", "sendPacket", 2;
}

sub sendStorageGet {
	my $r_socket = shift;
	my $index = shift;
	my $amount = shift;
	my $msg = pack("C*", 0xF5, 0x00) . pack("S*", $index) . pack("L*", $amount);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Storage Get: $index x $amount\n", "sendPacket", 2;
}

sub sendStand {
	my $r_socket = shift;
	my $msg = pack("C*", 0x89,0x00, 0x00, 0x00, 0x00, 0x00, 0x03);
	sendMsgToServer($r_socket, $msg);
	debug "Standing\n", "sendPacket", 2;
}

sub sendSync {
	my $r_socket = shift;
	my $time = shift;
	my $msg = pack("C*", 0x7E, 0x00) . pack("L1", $time);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Sync: $time\n", "sendPacket", 2;
}

sub sendSyncInject {
	my $r_socket = shift;
	$$r_socket->send("K".pack("S", 0)) if $$r_socket && $$r_socket->connected();
}

sub sendTake {
	my $r_socket = shift;
	my $itemID = shift;
	my $msg = pack("C*", 0x9F, 0x00) . $itemID;
	sendMsgToServer($r_socket, $msg);
	debug "Sent take\n", "sendPacket", 2;
}

sub sendTalk {
	my $r_socket = shift;
	my $ID = shift;
	my $msg = pack("C*", 0x90, 0x00) . $ID . pack("C*",0x01);
	sendMsgToServer($r_socket, $msg);
	debug "Sent talk: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendTalkCancel {
	my $r_socket = shift;
	my $ID = shift;
	my $msg = pack("C*", 0x46, 0x01) . $ID;
	sendMsgToServer($r_socket, $msg);
	debug "Sent talk cancel: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendTalkContinue {
	my $r_socket = shift;
	my $ID = shift;
	my $msg = pack("C*", 0xB9, 0x00) . $ID;
	sendMsgToServer($r_socket, $msg);
	debug "Sent talk continue: ".getHex($ID)."\n", "sendPacket", 2;
}

sub sendTalkResponse {
	my $r_socket = shift;
	my $ID = shift;
	my $response = shift;
	my $msg = pack("C*", 0xB8, 0x00) . $ID. pack("C1",$response);
	sendMsgToServer($r_socket, $msg);
	debug "Sent talk respond: ".getHex($ID).", $response\n", "sendPacket", 2;
}

sub sendTalkNumber {
	my $r_socket = shift;
	my $ID = shift;
	my $number = shift;
	my $msg = pack("C*", 0x43, 0x01, 0x4B, 0xE3, 0x8E, 0x06) .
			pack("L1", $number);
	sendMsgToServer($r_socket, $msg);
	debug "Sent talk number: ".getHex($ID).", $number\n", "sendPacket", 2;
}

sub sendTeleport {
	my $r_socket = shift;
	my $location = shift;
	$location = substr($location, 0, 16) if (length($location) > 16);
	$location .= chr(0) x (16 - length($location));
	my $msg = pack("C*", 0x1B, 0x01, 0x1A, 0x00) . $location;
	sendMsgToServer($r_socket, $msg);
	debug "Sent Teleport: $location\n", "sendPacket", 2;
}

sub sendToClientByInject {
	my $r_socket = shift;
	my $msg = shift;
	$$r_socket->send("R".pack("S", length($msg)).$msg) if $$r_socket && $$r_socket->connected();
}

sub sendToServerByInject {
	my $r_socket = shift;
	my $msg = shift;
	$$r_socket->send("S".pack("S", length($msg)).$msg) if $$r_socket && $$r_socket->connected();
}

sub sendMsgToServer {
	my $r_socket = shift;
	my $msg = shift;
	return if (!$$r_socket || !$$r_socket->connected());
	encrypt(\$msg, $msg);
	if ($config{'XKore'}) {
		sendToServerByInject(\$remote_socket, $msg);
	} else {
		$$r_socket->send($msg) if ($$r_socket && $$r_socket->connected());
	}

	my $switch = uc(unpack("H2", substr($msg, 1, 1))) . uc(unpack("H2", substr($msg, 0, 1)));
	debug "Packet Switch SENT: $switch\n", "sendPacket" if ($config{'debugPacket_sent'} && !existsInList($config{'debugPacket_exclude'}, $switch));
}

sub sendUnequip{
	my $r_socket = shift;
	my $index = shift;
	my $msg = pack("C*", 0xAB, 0x00) . pack("S*", $index);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Unequip: $index\n", "sendPacket", 2;
}

sub sendWho {
	my $r_socket = shift;
	my $msg = pack("C*", 0xC1, 0x00);
	sendMsgToServer($r_socket, $msg);
	debug "Sent Who\n", "sendPacket", 2;
}




#######################################
#######################################
#CONNECTION FUNCTIONS
#######################################
#######################################


sub connection {
	my $r_socket = shift;
	my $host = shift;
	my $port = shift;
	message("Connecting ($host:$port)... ", "connection");
	$$r_socket = IO::Socket::INET->new(
			PeerAddr	=> $host,
			PeerPort	=> $port,
			Proto		=> 'tcp',
			Timeout		=> 4);
	($$r_socket && inet_aton($$r_socket->peerhost()) eq inet_aton($host)) ?
		message("connected\n", "connection") :
		error("couldn't connect\n", "connection");
}

sub dataWaiting {
	my $r_fh = shift;
	my $bits;
	vec($bits,fileno($$r_fh),1)=1;
	# The timeout was 0.005
	return (select($bits,$bits,$bits,0) > 1);
}

sub killConnection {
	return if ($config{'XKore'});
	my $r_socket = shift;
	sendQuit(\$remote_socket) if ($conState == 5 && $remote_socket && $remote_socket->connected());
	if ($$r_socket && $$r_socket->connected()) {
		message("Disconnecting (".$$r_socket->peerhost().":".$$r_socket->peerport().")... ", "connection");
		close($$r_socket);
		!$$r_socket->connected() ?
			message("disconnected\n", "connection") :
			error("couldn't disconnect\n", "connection");
	}
}




#######################################
#######################################
#FILE PARSING AND WRITING
#######################################
#######################################

sub addParseFiles {
	my $file = shift;
	my $hash = shift;
	my $function = shift;
	$parseFiles[$parseFiles]{'file'} = $file;
	$parseFiles[$parseFiles]{'hash'} = $hash;
	$parseFiles[$parseFiles]{'function'} = $function;
	$parseFiles++;
}

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
	message "Message Dumped into DUMP.txt!\n";
}

sub getField {
	my $file = shift;
	my $r_hash = shift;
	undef %{$r_hash};
	unless (-e $file) {
		warn "\n!!Could not load field - you must install the kore-field pack!!\n\n";
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

sub load {
	my $r_array = shift;

	Plugins::callHook('preloadfiles', {files => $r_array});
	foreach (@{$r_array}) {
		if (-e $$_{'file'}) {
			message("Loading $$_{'file'}...\n", "load");
		} else {
			error("Error: Couldn't load $$_{'file'}\n", "load");
		}
		&{$$_{'function'}}("$$_{'file'}", $$_{'hash'});
	}
	Plugins::callHook('postloadfiles', {files => $r_array});
}

sub parseReload {
	my $temp = shift;
	my @temp;
	my %temp;
	my $temp2;
	my $qm;
	my $except;
	my $found;
	while ($temp =~ /(\w+)/g) {
		$temp2 = $1;
		$qm = quotemeta $temp2;
		if ($temp2 eq "all") {
			foreach (@parseFiles) {
				$temp{$$_{'file'}} = $_;
			}
		} elsif ($temp2 eq "plugins") {
			message("Reloading all plugins...\n", "load");
			Plugins::unloadAll();
			Plugins::loadAll();
		} elsif ($temp2 =~ /\bexcept\b/i || $temp2 =~ /\bbut\b/i) {
			$except = 1;
		} else {
			if ($except) {
				foreach (@parseFiles) {
					delete $temp{$$_{'file'}} if $$_{'file'} =~ /$qm/i;
				}
			} else {
				foreach (@parseFiles) {
					$temp{$$_{'file'}} = $_ if $$_{'file'} =~ /$qm/i;
				}
			}
		}
	}
	foreach my $f (keys %temp) {
		$temp[@temp] = $temp{$f};
	}
	load(\@temp);
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
			useTeleport(1) if ($teleport);
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
				$monsters{$ID1}{'dmgToParty'} += $damage;
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
			if ($players{$playersID[$i]}{'name'} eq $config{"avoid_ignore_$j"})
			{
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
			killConnection(\$remote_socket);
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
		if ($chatMsgUser eq $config{"avoid_ignore_$j"})
		{
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
		killConnection(\$remote_socket);
		return 1;
	}
	return 0;
}

sub avoidList_near() {
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
				killConnection(\$remote_socket);
				return 1;
			}
			$j++;
		}
	}
	return 0;
}

sub avoidList_talk($$) {
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
			killConnection(\$remote_socket);
		}
		$j++;
	}
}

sub compilePortals {
	undef %mapPortals;
	foreach (keys %portals_lut) {
		%{$mapPortals{$portals_lut{$_}{'source'}{'map'}}{$_}{'pos'}} = %{$portals_lut{$_}{'source'}{'pos'}};
	}
	my $l = 0;
	foreach my $map (keys %mapPortals) {
		foreach my $portal (keys %{$mapPortals{$map}}) {
			foreach (keys %{$mapPortals{$map}}) {
				next if ($_ eq $portal);
				if ($portals_los{$portal}{$_} eq "" && $portals_los{$_}{$portal} eq "") {
					if ($field{'name'} ne $map) {
						message "Processing map $map\n", "system";
						getField("$Settings::def_field/$map.fld", \%field);
					}
					message "Calculating portal route $portal -> $_\n", "system";
					ai_route_getRoute(\@solution, \%field, \%{$mapPortals{$map}{$portal}{'pos'}}, \%{$mapPortals{$map}{$_}{'pos'}});
					compilePortals_getRoute();
					$portals_los{$portal}{$_} = (@solution) ? 1 : 0;
				}
			}
		}
	}

	writePortalsLOS("tables/portalsLOS.txt", \%portals_los);

	message "Wrote portals Line of Sight table to 'tables/portalsLOS.txt'\n", "system";

}

sub compilePortals_check {
	my $r_return = shift;
	my %mapPortals;
	undef $$r_return;
	foreach (keys %portals_lut) {
		%{$mapPortals{$portals_lut{$_}{'source'}{'map'}}{$_}{'pos'}} = %{$portals_lut{$_}{'source'}{'pos'}};
	}
	foreach my $map (keys %mapPortals) {
		foreach my $portal (keys %{$mapPortals{$map}}) {
			foreach (keys %{$mapPortals{$map}}) {
				next if ($_ eq $portal);
				if ($portals_los{$portal}{$_} eq "" && $portals_los{$_}{$portal} eq "") {
					$$r_return = 1;
					return;
				}
			}
		}
	}
}

sub compilePortals_getRoute {	
	if ($ai_seq[0] eq "route_getRoute") {
		if (!$ai_seq_args[0]{'init'}) {
			undef @{$ai_v{'temp'}{'subSuc'}};
			undef @{$ai_v{'temp'}{'subSuc2'}};
			if (ai_route_getMap(\%{$ai_seq_args[0]}, $ai_seq_args[0]{'start'}{'x'}, $ai_seq_args[0]{'start'}{'y'})) {
				ai_route_getSuccessors(\%{$ai_seq_args[0]}, \%{$ai_seq_args[0]{'start'}}, \@{$ai_v{'temp'}{'subSuc'}},0);
				ai_route_getDiagSuccessors(\%{$ai_seq_args[0]}, \%{$ai_seq_args[0]{'start'}}, \@{$ai_v{'temp'}{'subSuc'}},0);
				foreach (@{$ai_v{'temp'}{'subSuc'}}) {
					ai_route_getSuccessors(\%{$ai_seq_args[0]}, \%{$_}, \@{$ai_v{'temp'}{'subSuc2'}},0);
					ai_route_getDiagSuccessors(\%{$ai_seq_args[0]}, \%{$_}, \@{$ai_v{'temp'}{'subSuc2'}},0);
				}
				if (@{$ai_v{'temp'}{'subSuc'}}) {
					%{$ai_seq_args[0]{'start'}} = %{$ai_v{'temp'}{'subSuc'}[0]};
				} elsif (@{$ai_v{'temp'}{'subSuc2'}}) {
					%{$ai_seq_args[0]{'start'}} = %{$ai_v{'temp'}{'subSuc2'}[0]};
				}
			}
			undef @{$ai_v{'temp'}{'subSuc'}};
			undef @{$ai_v{'temp'}{'subSuc2'}};
			if (ai_route_getMap(\%{$ai_seq_args[0]}, $ai_seq_args[0]{'dest'}{'x'}, $ai_seq_args[0]{'dest'}{'y'})) {
				ai_route_getSuccessors(\%{$ai_seq_args[0]}, \%{$ai_seq_args[0]{'dest'}}, \@{$ai_v{'temp'}{'subSuc'}},0);
				ai_route_getDiagSuccessors(\%{$ai_seq_args[0]}, \%{$ai_seq_args[0]{'dest'}}, \@{$ai_v{'temp'}{'subSuc'}},0);
				foreach (@{$ai_v{'temp'}{'subSuc'}}) {
					ai_route_getSuccessors(\%{$ai_seq_args[0]}, \%{$_}, \@{$ai_v{'temp'}{'subSuc2'}},0);
					ai_route_getDiagSuccessors(\%{$ai_seq_args[0]}, \%{$_}, \@{$ai_v{'temp'}{'subSuc2'}},0);
				}
				if (@{$ai_v{'temp'}{'subSuc'}}) {
					%{$ai_seq_args[0]{'dest'}} = %{$ai_v{'temp'}{'subSuc'}[0]};
				} elsif (@{$ai_v{'temp'}{'subSuc2'}}) {
					%{$ai_seq_args[0]{'dest'}} = %{$ai_v{'temp'}{'subSuc2'}[0]};
				}
			}
			$ai_seq_args[0]{'timeout'} = 90000;
		}
		$ai_seq_args[0]{'init'} = 1;
		ai_route_searchStep(\%{$ai_seq_args[0]});
		ai_route_getRoute_destroy(\%{$ai_seq_args[0]});
		shift @ai_seq;
		shift @ai_seq_args;
	}
}

sub getCoordString {
	my $x = shift;
	my $y = shift;
	return pack("C*", int($x / 4), ($x % 4) * 64 + int($y / 16), ($y % 16) * 16);
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

sub portalExists {
	my ($map, $r_pos) = @_;
	foreach (keys %portals_lut) {
		if ($portals_lut{$_}{'source'}{'map'} eq $map && $portals_lut{$_}{'source'}{'pos'}{'x'} == $$r_pos{'x'}
			&& $portals_lut{$_}{'source'}{'pos'}{'y'} == $$r_pos{'y'}) {
			return $_;
		}
	}
}

sub printItemDesc {
	my $itemID = shift;
	message("===============Item Description===============\n", "info");
	message("Item: $items_lut{$itemID}\n\n", "info");
	message($itemsDesc_lut{$itemID}, "info");
	message("==============================================\n", "info");
}

sub vocalString {
        my $letter_length = shift;
        return if ($letter_length <= 0);
        my $r_string = shift;
        my $test;
        my $i;
        my $password;
        my @cons = ("b", "c", "d", "g", "h", "j", "k", "l", "m", "n", "p", "r", "s", "t", "v", "w", "y", "z", "tr", "cl", "cr", "br", "fr", "th", "dr", "ch", "st", "sp", "sw", "pr", "sh", "gr", "tw", "wr", "ck");
        my @vowels = ("a", "e", "i", "o", "u" , "a", "e" ,"i","o","u","a","e","i","o", "ea" , "ou" , "ie" , "ai" , "ee" ,"au", "oo");
        my %badend = ( "tr" => 1, "cr" => 1, "br" => 1, "fr" => 1, "dr" => 1, "sp" => 1, "sw" => 1, "pr" =>1, "gr" => 1, "tw" => 1, "wr" => 1, "cl" => 1);
        for (;;) {
                $password = "";
                for($i = 0; $i < $letter_length; $i++){
                        $password .= $cons[rand(@cons - 1)] . $vowels[rand(@vowels - 1)];
                }
                $password = substr($password, 0, $letter_length);
                ($test) = ($password =~ /(..)\z/);
                last if ($badend{$test} != 1);
        }
        $$r_string = $password;
        return $$r_string;
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

sub printStat {
	my $dmgpsec_string = sprintf("%.2f", $dmgpsec);
	my $totalelasped_string = sprintf("%.2f", $totalelasped);
	my $elasped_string = sprintf("%.2f", $elasped);

	message(swrite(
		"Total Damage: @>>>>>>>>>>>>> Dmg/sec: @<<<<<<<<<<<<<<",
		[$totaldmg, $dmgpsec_string],
		"Total Time spent (sec): @>>>>>>>>",
		[$totalelasped_string],
		"Last Monster took (sec): @>>>>>>>",
		[$elasped_string]),
		"info");
	message("----------------------------\n", "info");
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
	my $target = $targetID eq $sourceID ? 'self' : getActorName($targetID);

	return ($source, $uses, $target);
}

sub ClearRouteAI {
	my $msg = shift;
	message $msg;
	chatLog("k", $msg);
	aiRemove("move");
	aiRemove("route");
	aiRemove("route_getRoute");
	aiRemove("route_getMapRoute");
	ai_clientSuspend(0, 5);
}

sub Unstuck {
	my $msg = shift;

	$totalStuckCount++;
	$old_x = 0;
	$old_y = 0;
	$old_pos_x = 0;
	$old_pos_y = 0;
	$move_x = 0;
	$move_y = 0;
	$move_pos_x = 0;
	$move_pos_y = 0;
	message $msg;
	chatLog("k", $msg);
	aiRemove("move");
	aiRemove("route");
	aiRemove("route_getRoute");
	aiRemove("route_getMapRoute");
	useTeleport(1);
	ai_clientSuspend(0, 5);
}

sub RespawnUnstuck {
	$totalStuckCount = 0;
	$calcTo_SameSpot = 0;
	$calcFrom_SameSpot = 0;
	$moveTo_SameSpot = 0;
	$moveFrom_SameSpot = 0;
	$route_stuck = 0;
	$old_x = 0;
	$old_y = 0;
	$old_pos_x = 0;
	$old_pos_y = 0;
	$move_x = 0;
	$move_y = 0;
	$move_pos_x = 0;
	$move_pos_y = 0;
	warning "Cannot calculate route, respawning to saveMap ...\n";
	chatLog("k", "Cannot calculate route, respawning to saveMap ...\n"); 
	aiRemove("move");
	aiRemove("route");
	aiRemove("route_getRoute");
	aiRemove("route_getMapRoute");
	useTeleport(2);
	ai_clientSuspend(0, 5);
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

return 1;
