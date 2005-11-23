#########################################################################
#  OpenKore - X-Kore
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
package XKore;

use strict;
use base qw(Exporter);
use Exporter;
use IO::Socket::INET;
use Time::HiRes qw(time usleep);
use Win32;

use Globals;
use Log qw(message error);
use WinUtils;
use Network::Send;
use Utils qw(dataWaiting timeOut);


##
# XKore->new()
#
# Initialize X-Kore mode. If an error occurs, this function will return undef,
# and set the error message in $@.
sub new {
	my $class = shift;
	my $port = 2350;
	my %self;

	undef $@;
	$self{server} = new IO::Socket::INET->new(
		Listen		=> 5,
		LocalAddr	=> 'localhost',
		LocalPort	=> $port,
		Proto		=> 'tcp');
	if (!$self{server}) {
		$@ = "Unable to start the X-Kore server.\n" .
			"You can only run one X-Kore session at the same time.\n\n" .
			"And make sure no other servers are running on port $port.";
		return undef;
	}
	
	$self{incomingPackets} = "";
	$self{serverPackets} = "";
	$self{clientPackets} = "";
	
	$packetParser = Network::Receive->create($config{serverType});

	message "X-Kore mode intialized.\n", "startup";

	bless \%self, $class;
	return \%self;
}

##
# $net->version
# Returns: XKore mode
#
sub version {
	return 1;
}

##
# $net->DESTROY()
#
# Shutdown function. Turn everything off.
sub DESTROY {
	my $self = shift;
	
	close($self->{client});
}

######################
## Server Functions ##
######################

##
# $net->serverAlive()
# Returns: a boolean.
#
# Check whether the connection with the server (thru the client) is still alive.
sub serverAlive {
	return $_[0]->{client} && $_[0]->{client}->connected;
}

##
# $net->serverConnect
#
# Not used with XKore mode 1
sub serverConnect {
	return undef;
}

##
# $net->serverPeerHost
#
sub serverPeerHost {
	return undef;
}

##
# $net->serverPeerPort
#
sub serverPeerPort {
	return undef;
}

##
# $net->serverRecv()
# Returns: the messages sent from the server, or undef if there are no pending messages.
sub serverRecv {
	my $self = shift;
	$self->recv();
	
	return undef unless length($self->{serverPackets});

	my $packets = $self->{serverPackets};
	$self->{serverPackets} = "";
	
	return $packets;
}

##
# $net->serverSend(msg)
# msg: A scalar to send to the RO server
#
sub serverSend {
	my $self = shift;
	my $msg = shift;
	$self->{client}->send("S".pack("v", length($msg)).$msg) if ($self->serverAlive);
}

##
# $net->serverDisconnect
#
# This isn't used with XKore mode 1.
sub serverDisconnect {
	return undef;
}

######################
## Client Functions ##
######################

##
# $net->clientAlive()
# Returns: a boolean.
#
# Check whether the connection with the client is still alive.
sub clientAlive {
	return $_[0]->serverAlive();
}

##
# $net->clientConnect
#
# Not used with XKore mode 1
sub clientConnect {
	return undef;
}

##
# $net->clientPeerHost
#
sub clientPeerHost {
	return $_[0]->{client}->peerhost if ($_[0]->clientAlive);
	return undef;
}

##
# $net->clientPeerPort
#
sub clientPeerPort {
	return $_[0]->{client}->peerport if ($_[0]->clientAlive);
	return undef;
}

##
# $net->clientRecv()
# Returns: the message sent from the client (towards the server), or undef if there are no pending messages.
sub clientRecv {
	my $self = shift;
	$self->recv();
	
	return undef unless length($self->{clientPackets});
	
	my $packets = $self->{clientPackets};
	$self->{clientPackets} = "";
	
	return $packets;
}

##
# $net->clientSend(msg)
# msg: A scalar to be sent to the RO client
#
sub clientSend {
	my $self = shift;
	my $msg = shift;
	$self->{client}->send("R".pack("v", length($msg)).$msg) if ($self->clientAlive);
}

sub clientDisconnect {
	return undef;
}

#######################
## Utility Functions ##
#######################

##
# $net->injectSync()
#
# Send a keep-alive packet to the injected DLL.
sub injectSync {
	my $self = shift;
	$self->{client}->send("K" . pack("v", 0)) if ($self->serverAlive);
}

##
# $net->checkConnection()
#
# Handles any connection issues. Based on the current situation, this function may
# re-connect to the RO server, disconnect, do nothing, etc.
#
# This function is meant to be run in the Kore main loop.
sub checkConnection {
	my $self = shift;
	
	return if ($self->serverAlive);
	
	# (Re-)initialize X-Kore if necessary
	$conState = 1;
	my $printed;
	my $pid;
	# Wait until the RO client has started
	while (!($pid = WinUtils::GetProcByName($config{exeName}))) {
		message("Please start the Ragnarok Online client ($config{exeName})\n", "startup") unless $printed;
		$printed = 1;
		$interface->iterate;
		if (defined(my $input = $interface->getInput(0))) {
			if ($input eq "quit") {
				$quit = 1;
				last;
			} else {
				message("Error: You cannot type anything except 'quit' right now.\n");
			}
		}
		usleep 20000;
		last if $quit;
	}
	return if $quit;

	# Inject DLL
	message("Ragnarok Online client found\n", "startup");
	sleep 1 if $printed;
	if (!$self->inject($pid, $config{XKore_bypassBotDetection})) {
		# Failed to inject
		$interface->errorDialog($@);
		exit 1;
	}
	
	# Patch client
	$self->hackClient($pid);

	# Wait until the RO client has connected to us
	$self->waitForClient;
	message("You can login with the Ragnarok Online client now.\n", "startup");
	$timeout{'injectSync'}{'time'} = time;
}

##
# $net->inject(pid)
# pid: a process ID.
# bypassBotDetection: set to 1 if you want Kore to try to bypass the RO client's bot detection. This feature has only been tested with the iRO client, so use with care.
# Returns: 1 on success, 0 on failure.
#
# Inject NetRedirect.dll into an external process. On failure, $@ is set.
#
# This function is meant to be used internally only.
sub inject {
	my ($self, $pid, $bypassBotDetection) = @_;
	my $cwd = Win32::GetCwd();
	my $dll;

	# Patch the client to remove bot detection
	$self->hackClient($pid) if ($bypassBotDetection);

	undef $@;
	foreach ("$cwd\\src\\auto\\XSTools\\win32\\NetRedirect.dll", "$cwd\\NetRedirect.dll", "$cwd\\Inject.dll") {
		if (-f $_) {
			$dll = $_;
			last;
		}
	}

	if (!$dll) {
		$@ = "Cannot find NetRedirect.dll. Please check your installation.";
		return 0;
	}

	if (WinUtils::InjectDLL($pid, $dll)) {
		return 1;
	} else {
		$@ = 'Unable to inject NetRedirect.dll';
		return undef;
	}
}

##
# $net->waitForClient()
# Returns: the socket which connects X-Kore to the client.
#
# Wait until the client has connected the X-Kore server.
#
# This function is meant to be used internally only.
sub waitForClient {
	my $self = shift;

	message "Waiting for the Ragnarok Online client to connect to X-Kore...", "startup";
	$self->{client} = $self->{server}->accept;
	message " ready\n", "startup";
	return $self->{client};
}

##
# $net->recv()
# Returns: Nothing
#
# Receive packets from the client. Then sort them into server-bound or client-bound;
#
# This is meant to be used internally only.
sub recv {
	my $self = shift;
	my $msg;

	return undef unless dataWaiting(\$self->{client});
	undef $@;
	eval {
		$self->{client}->recv($msg, 32 * 1024);
	};
	if (!defined $msg || length($msg) == 0 || $@) {
		delete $self->{client};
		return undef;
	}
	
	$self->{incomingPackets} .= $msg;
	
	while ($self->{incomingPackets} ne "") {
		last if (!length($self->{incomingPackets}));
		
		my $type = substr($self->{incomingPackets}, 0, 1);
		my $len = unpack("v",substr($self->{incomingPackets}, 1, 2));
		
		last if ($len > length($self->{incomingPackets}));
		
		$msg = substr($self->{incomingPackets}, 3, $len);
		$self->{incomingPackets} = (length($self->{incomingPackets}) - $len - 3)?
			substr($self->{incomingPackets}, $len + 3, length($self->{incomingPackets}) - $len - 3)
			: "";
		if ($type eq "R") {
			# Client-bound (or "from server") packets
			$self->{serverPackets} .= $msg;
		} elsif ($type eq "S") {
			# Server-bound (or "to server") packets
			$self->{clientPackets} .= $msg;
		} elsif ($type eq "K") {
			# Keep-alive... useless.
		}
	}
	
	# Check if we need to send our sync
	if (timeOut($timeout{'injectSync'})) {
		$self->injectSync;
		$timeout{'injectSync'}{'time'} = time;
	}
	
	return 1;
}

##
# $net->hackClient(pid)
# pid: Process ID of a running (and official) Ragnarok Online client
#
# Hacks the client (non-nProtect GameGuard version) to remove bot detection.
# If the code is in the RO Client, it should find it fairly quick and patch, but
# if not it will spend a bit of time scanning through Ragnarok's memory. Perhaps
# there should be a config option to disable/enable this?
#
# Code Note: $original is a regexp match, and since 0x7C is '|', its escaped.
sub hackClient {
	my $self = shift;
	my $pid = shift;
	my $handle;

	my $pageSize = WinUtils::SystemInfo_PageSize();
	my $minAddr = WinUtils::SystemInfo_MinAppAddress();
	my $maxAddr = WinUtils::SystemInfo_MaxAppAddress();

	my $patchFind = pack('C*', 0x66, 0xA3) . '....'	# mov word ptr [xxxx], ax
		. pack('C*', 0xA0) . '....'		# mov al, byte ptr [xxxx]
		. pack('C*', 0x3C, 0x0A,		# cmp al, 0A
			0x66, 0x89, 0x0D) . '....';	# mov word ptr [xxxx], cx

	my $original = '\\' . pack('C*', 0x7C, 0x6D);	# jl 6D
							# (to be replaced by)
	my $patched = pack('C*', 0xEB, 0x6D);		# jmp 6D

	my $patchFind2 = pack('C*', 0xA1) . '....'	# mov eax, dword ptr [xxxx]
		. pack('C*', 0x8D, 0x4D, 0xF4,		# lea ecx, dword ptr [ebp+var_0C]
			0x51);				# push ecx
	
	
	$original = $patchFind . $original . $patchFind2;
	
	message "Patching client to remove bot detection...\n", "startup";
	
	# Open Ragnarok's process
	my $hnd = WinUtils::OpenProcess(0x638, $pid);
	
	# Loop through Ragnarok's memory
	for (my $i = $minAddr; $i < $maxAddr; $i += $pageSize) {
		# Ensure we can read/write the memory
		my $oldprot = WinUtils::VirtualProtectEx($hnd, $i, $pageSize, 0x40);
		
		if ($oldprot) {
			# Read the page
			my $data = WinUtils::ReadProcessMemory($hnd, $i, $pageSize);
			
			# Is the patched code in there?
			if ($data =~ m/($original)/) {
				# It is!
				my $matched = $1;
				message "Found detection code, replacing... ", "startup";
				
				# Generate the new code, based on the old.
				$patched = substr($matched, 0, length($patchFind)) . $patched;
				$patched = $patched . substr($matched, length($patchFind) + 2, length($patchFind2));
				
				# Patch the data
				$data =~ s/$original/$patched/;
				
				# Write the new code
				if (WinUtils::WriteProcessMemory($hnd, $i, $data)) {
					message "success.\n", "startup";
				
					# Stop searching, we should be done.
					WinUtils::VirtualProtectEx($hnd, $i, $pageSize, $oldprot);
					last;
				} else {
					error "failed.\n", "startup";
				}
			}
			
		# Undo the protection change
		WinUtils::VirtualProtectEx($hnd, $i, $pageSize, $oldprot);
		}
	}
	
	# Close Ragnarok's process
	WinUtils::CloseProcess($hnd);
		
	message "Client patching finished.\n", "startup";
}

#
# XKore::redirect([enabled])
# enabled: Whether you want to redirect (some) console messages to the RO client.
#
# Enable or disable console message redirection. Or, if $enabled is not given,
# returns whether message redirection is currently enabled.
#sub redirect {
#	my $arg = shift;
#	if ($arg) {
#		$redirect = $arg;
#	} else {
#		return $redirect;
#	}
#}

#sub redirectMessages {
#	my ($type, $domain, $level, $globalVerbosity, $message, $user_data) = @_;
#
#	return if ($type eq "debug" || $level > 0 || $conState != 5 || !$redirect);
#	return if ($domain =~ /^(connection|startup|pm|publicchat|guildchat|selfchat|emotion|drop|inventory|deal)$/);
#	return if ($domain =~ /^(attack|skill|list|info|partychat|npc)/);
#
#	$message =~ s/\n*$//s;
#	$message =~ s/\n/\\n/g;
#	main::sendMessage($net, "k", $message);
#}

return 1;
