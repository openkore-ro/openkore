#!/usr/bin/env perl
#########################################################################
#  This software is open source, licensed under the GNU General Public
#  License, version 2.
#  Basically, this means that you're allowed to modify and distribute
#  this software. However, if you distribute modified versions, you MUST
#  also distribute the source code.
#  See http://www.gnu.org/licenses/gpl.html for the full license.
#
#
#
#  $Revision$
#  $Id$
#
#########################################################################

use Time::HiRes qw(time usleep);
use Getopt::Long;
use IO::Socket;
use Digest::MD5;
use Carp;
unshift @INC, '.';


require 'functions.pl';
use Globals;
use Modules;
use Input;
use Log;
use Utils;
use Settings;
use Plugins;
use FileParsers;
Modules::register(qw(Globals Modules Input Log Utils Settings Plugins FileParsers));


##### PARSE ARGUMENTS, LOAD PLUGINS, AND START INPUT SERVER #####

srand(time());
Settings::parseArguments();
Log::message("$Settings::versionText\n");

Plugins::loadAll();

Input::start() unless ($Settings::daemon);
Log::message("\n");

Plugins::callHook('start');


##### PARSE CONFIGURATION AND DATA FILES #####

addParseFiles($Settings::config_file, \%config,\&parseDataFile2);
addParseFiles($Settings::items_control_file, \%items_control,\&parseItemsControl);
addParseFiles($Settings::mon_control_file, \%mon_control,\&parseMonControl);
addParseFiles("$Settings::control_folder/overallauth.txt", \%overallAuth, \&parseDataFile);
addParseFiles("$Settings::control_folder/pickupitems.txt", \%itemsPickup, \&parseDataFile_lc);
addParseFiles("$Settings::control_folder/responses.txt", \%responses, \&parseResponses);
addParseFiles("$Settings::control_folder/timeouts.txt", \%timeout, \&parseTimeouts);
addParseFiles($Settings::shop_file, \%shop, \&parseDataFile2);
addParseFiles("$Settings::control_folder/chat_resp.txt", \%chat_resp, \&parseDataFile2);
addParseFiles("$Settings::control_folder/avoid.txt", \%avoid, \&parseDataFile2);
addParseFiles("$Settings::control_folder/consolecolors.txt", \%consoleColors, \&parseSectionedFile);

addParseFiles("$Settings::tables_folder/cities.txt", \%cities_lut, \&parseROLUT);
addParseFiles("$Settings::tables_folder/emotions.txt", \%emotions_lut, \&parseDataFile2);
addParseFiles("$Settings::tables_folder/equiptypes.txt", \%equipTypes_lut, \&parseDataFile2);
addParseFiles("$Settings::tables_folder/items.txt", \%items_lut, \&parseROLUT);
addParseFiles("$Settings::tables_folder/itemsdescriptions.txt", \%itemsDesc_lut, \&parseRODescLUT);
addParseFiles("$Settings::tables_folder/itemslots.txt", \%itemSlots_lut, \&parseROSlotsLUT);
addParseFiles("$Settings::tables_folder/itemtypes.txt", \%itemTypes_lut, \&parseDataFile2);
addParseFiles("$Settings::tables_folder/jobs.txt", \%jobs_lut, \&parseDataFile2);
addParseFiles("$Settings::tables_folder/maps.txt", \%maps_lut, \&parseROLUT);
addParseFiles("$Settings::tables_folder/monsters.txt", \%monsters_lut, \&parseDataFile2);
addParseFiles("$Settings::tables_folder/npcs.txt", \%npcs_lut, \&parseNPCs);
addParseFiles("$Settings::tables_folder/portals.txt", \%portals_lut, \&parsePortals);
addParseFiles("$Settings::tables_folder/portalsLOS.txt", \%portals_los, \&parsePortalsLOS);
addParseFiles("$Settings::tables_folder/sex.txt", \%sex_lut, \&parseDataFile2);
addParseFiles("$Settings::tables_folder/skills.txt", \%skills_lut, \&parseSkillsLUT);
addParseFiles("$Settings::tables_folder/skills.txt", \%skillsID_lut, \&parseSkillsIDLUT);
addParseFiles("$Settings::tables_folder/skills.txt", \%skills_rlut, \&parseSkillsReverseLUT_lc);
addParseFiles("$Settings::tables_folder/skillsdescriptions.txt", \%skillsDesc_lut, \&parseRODescLUT);
addParseFiles("$Settings::tables_folder/skillssp.txt", \%skillsSP_lut, \&parseSkillsSPLUT);
addParseFiles("$Settings::tables_folder/cards.txt", \%cards_lut, \&parseROLUT);
addParseFiles("$Settings::tables_folder/elements.txt", \%elements_lut, \&parseROLUT);
addParseFiles("$Settings::tables_folder/recvpackets.txt", \%rpackets, \&parseDataFile2);

Plugins::callHook('start2');
load(\@parseFiles);
Plugins::callHook('start3');


##### INITIALIZE USAGE OF TOOLS.DLL/TOOLS.SO #####

if ($buildType == 0) {
	# MS Windows
	require Win32::API;
	import Win32::API;
	if ($@) {
		Log::error("Unable to load the Win32::API module. Please install this Perl module first.", "startup");
		Input::stop();
		promptAndExit();
	}

	$CalcPath_init = new Win32::API("Tools", "CalcPath_init", "PPNNPPN", "N");
	if (!$CalcPath_init) {
		Log::error("Could not locate Tools.dll", "startup");
		Input::stop();
		promptAndExit();
	}

	$CalcPath_pathStep = new Win32::API("Tools", "CalcPath_pathStep", "N", "N");
	if (!$CalcPath_pathStep) {
		Log::error("Could not locate Tools.dll", "startup");
		Input::stop();
		promptAndExit();
	}

	$CalcPath_destroy = new Win32::API("Tools", "CalcPath_destroy", "N", "V");
	if (!$CalcPath_destroy) {
		Log::error("Could not locate Tools.dll", "startup");
		Input::stop();
		promptAndExit();
	}
} else {
	# Linux
	if (! -f "Tools.so") {
		# Linux users invoke kore from the console anyway so there's no point in using promptAndExit() here
		Log::error("Could not locate Tools.so. Type 'make' if you haven't done so.\n", "startup");
		exit 1;
	}
	require Tools;
	import Tools;
}

if ($config{'XKore'}) {
	my $cwd = Win32::GetCwd();
	our $injectDLL_file = $cwd."\\Inject.dll";

	our $GetProcByName = new Win32::API("Tools", "GetProcByName", "P", "N");
	if (!$GetProcByName) {
		Log::error("Could not locate Tools.dll", "startup");
		Input::stop();
		promptAndExit();
	}
	undef $cwd;
}

if ($config{'adminPassword'} eq 'x' x 10) {
	Log::message("\nAuto-generating Admin Password due to default...\n");
	configModify("adminPassword", vocalString(8));
}
# This is where we protect the stupid from having a blank admin password
elsif ($config{'adminPassword'} eq '') {
	Log::message("\nAuto-generating Admin Password due to blank...\n");
	configModify("adminPassword", vocalString(8));
}
# This is where we induldge the paranoid and let them have session generated admin passwords
elsif ($config{'secureAdminPassword'} eq '1') {
	Log::message("\nGenerating session Admin Password...\n");
	configModify("adminPassword", vocalString(8));
}

Log::message("\n");

our $injectServer_socket;
if ($config{'XKore'}) {
	$injectServer_socket = IO::Socket::INET->new(
			Listen		=> 5,
			LocalAddr	=> 'localhost',
			LocalPort	=> 2350,
			Proto		=> 'tcp');
	($injectServer_socket) || die "Error creating local inject server: $@";
	Log::message("Local inject server started (".$injectServer_socket->sockhost().":2350)\n");
}

our $remote_socket = IO::Socket::INET->new();


### COMPILE PORTALS ###

Log::message("Checking for new portals... ");
STDOUT->flush;
compilePortals_check(\$found);

if ($found) {
	Log::message("found new portals!\n");

	if ($Input::enabled) {
		Log::message("Compile portals now? (y/n)\n");
		Log::message("Auto-compile in $timeout{'compilePortals_auto'}{'timeout'} seconds...");
		$timeout{'compilePortals_auto'}{'time'} = time;
		undef $msg;
		while (!timeOut(\%{$timeout{'compilePortals_auto'}})) {
			$msg = Input::getInput(0);
			last if $msg;
		}
		if ($msg =~ /y/ || $msg eq "") {
			Log::message("compiling portals\n\n");
			compilePortals();
		} else {
			Log::message("skipping compile\n\n");
		}
	} else {
		Log::message("compiling portals\n\n");
		compilePortals();
	}
} else {
	Log::message("none found\n\n");
}


### PROMPT USERNAME AND PASSWORD IF NECESSARY ###

if (!$config{'XKore'} && !$Settings::daemon) {
	if (!$config{'username'}) {
		Log::message("Enter Username: ");
		STDOUT->flush;
		$msg = Input::getInput(1);
		$config{'username'} = $msg;
		writeDataFileIntact($Settings::config_file, \%config);
	}
	if (!$config{'password'}) {
		Log::message("Enter Password: ");
		STDOUT->flush;
		$msg = Input::getInput(1);
		$config{'password'} = $msg;
		writeDataFileIntact($Settings::config_file, \%config);
	}

	if ($config{'master'} eq "") {
		Log::message("------- Master Servers --------\n", "connection");
		Log::message("#         Name\n", "connection");
		my $i = 0;
		while ($config{"master_name_$i"} ne "") {
			Log::message(swrite(
				"@<<  @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<",
				[$i,   $config{"master_name_$i"}],
				), "connection");
			$i++;
		}
		undef $i;
		Log::message("-------------------------------\n", "connection");

		Log::message("Choose your master server: ");
		STDOUT->flush;
		$msg = Input::getInput(1);
		$config{'master'} = $msg;
		writeDataFileIntact($Settings::config_file, \%config);
	}

} elsif (!$config{'XKore'} && (!$config{'username'} || !$config{'password'})) {
	Log::error("No username of password set.\n", "startup");
	exit;
}

undef $msg;
our $KoreStartTime = time;
our $AI = 1;
our $conState = 1;
our $nextConfChangeTime;
our $bExpSwitch = 2;
our $jExpSwitch = 2;
our $totalBaseExp = 0;
our $totalJobExp = 0;
our $startTime_EXP = time;
our $self_dead_count = 0;

initStatVars();
initRandomRestart();
initConfChange();
$timeout{'injectSync'}{'time'} = time;

Log::message("\n");


##### SETUP ERROR HANDLER #####

sub _errorHandler {
	die @_ if (defined($^S) && $^S);
	no utf8;
	if (defined &Carp::longmess) {
		Log::color("red") if (defined &Log::color);
		Log::message("Program terminated unexpectedly. Error message:\n");
		Log::color("reset") if (defined &Log::color);

		my $msg = Carp::longmess(@_);
		Log::message("\@ai_seq = @ai_seq\n");
		if (open(F, "> errors.txt")) {
			print F "\@ai_seq = @ai_seq\n";
			print F $msg;
			close F;
		}
	} else {
		Log::message("Program terminated unexpectedly.\n");
	}

	Log::message("Press ENTER to exit this program.\n");
	<STDIN>;
};
# $SIG{'__DIE__'} = \&_errorHandler;


##### MAIN LOOP #####

Plugins::callHook('initialized');

while ($quit != 1) {
	my $input;

	usleep($config{'sleepTime'});

	if ($config{'XKore'}) {
		if (timeOut(\%{$timeout{'injectKeepAlive'}})) {
			$conState = 1;
			my $printed = 0;
			my $procID = 0;
			do {
				$procID = $GetProcByName->Call($config{'exeName'});
				if (!$procID && !$printed) {
					Log::message("Error: Could not locate process $config{'exeName'}.\n");
					Log::message("Waiting for you to start the process...\n");
					$printed = 1;
				}

				if (defined($input = Input::getInput(0))) {
				   	if ($input eq 'quit') {
						$quit = 1;
						last;
					} else {
						Log::message("Error: You cannot type anything except 'quit' right now.\n");
					}
				}

				usleep 100000;
			} while (!$procID && !$quit);
			last if ($quit);

			if ($printed == 1) {
				Log::message("Process found\n");
			}
			my $InjectDLL = new Win32::API("Tools", "InjectDLL", "NP", "I");
			my $retVal = $InjectDLL->Call($procID, $injectDLL_file);
			if ($retVal != 1) {
				Log::error("Could not inject DLL", "startup");
				return 1;
			}

			Log::message("Waiting for InjectDLL to connect...\n");
			$remote_socket = $injectServer_socket->accept();
			(inet_aton($remote_socket->peerhost()) eq inet_aton('localhost'))
			|| die "Inject Socket must be connected from localhost";
			Log::message("InjectDLL Socket connected - Ready to start botting\n");
			$timeout{'injectKeepAlive'}{'time'} = time;
		}
		if (timeOut(\%{$timeout{'injectSync'}})) {
			sendSyncInject(\$remote_socket);
			$timeout{'injectSync'}{'time'} = time;
		}
	}

	if (defined($input = Input::getInput(0))) {
		parseInput($input);

	}

	if (!$config{'XKore'} && dataWaiting(\$remote_socket)) {
		$remote_socket->recv($new, $Settings::MAX_READ);
		$msg .= $new;
		$msg_length = length($msg);
		while ($msg ne "") {
			$msg = parseMsg($msg);
			last if ($msg_length == length($msg));
			$msg_length = length($msg);
		}

	} elsif ($config{'XKore'} && dataWaiting(\$remote_socket)) {
		my $injectMsg;
		$remote_socket->recv($injectMsg, $Settings::MAX_READ);
		while ($injectMsg ne "") {
			if (length($injectMsg) < 3) {
				undef $injectMsg;
				break;
			}
			my $type = substr($injectMsg, 0, 1);
			my $len = unpack("S",substr($injectMsg, 1, 2));
			my $newMsg = substr($injectMsg, 3, $len);
			$injectMsg = (length($injectMsg) >= $len+3) ? substr($injectMsg, $len+3, length($injectMsg) - $len - 3) : "";
			if ($type eq "R") {
				$msg .= $newMsg;
				$msg_length = length($msg);
				while ($msg ne "") {
					$msg = parseMsg($msg);
					last if ($msg_length == length($msg));
					$msg_length = length($msg);
				}
			} elsif ($type eq "S") {
				parseSendMsg($newMsg);
			}
			$timeout{'injectKeepAlive'}{'time'} = time;
		}
	}

	$ai_cmdQue_shift = 0;
	do {
		AI(\%{$ai_cmdQue[$ai_cmdQue_shift]}) if ($conState == 5 && timeOut(\%{$timeout{'ai'}}) && $remote_socket && $remote_socket->connected());
		undef %{$ai_cmdQue[$ai_cmdQue_shift++]};
		$ai_cmdQue-- if ($ai_cmdQue > 0);
	} while ($ai_cmdQue > 0);
	checkConnection();

	mainLoop();
}


Plugins::unloadAll();

# Exit X-Kore
eval {
	$remote_socket->send("Z".pack("S", 0));
} if ($config{'XKore'} && $remote_socket && $remote_socket->connected());

Input::stop();
close($remote_socket);
unlink('buffer') if ($config{'XKore'} && -f 'buffer');
killConnection(\$remote_socket);

Log::message("Bye!\n");
Log::message($Settings::versionText);
exit;
