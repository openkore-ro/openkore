package Utils::Downloader;

use strict;
use Time::HiRes qw(time);
use Net::HTTP::NB;
use Utils qw(dataWaiting);
use constant MAX_RETRIES => 3;


sub new {
	my ($class, $host, $file) = @_;
	my %self;

	$self{host} = $host;
	$self{file} = $file;
	$self{stage} = 'Connect';
	$self{retry} = 0;

	bless \%self, $class;
	return \%self;
}

# Returns: whether checking is done
sub iterate {
	my $self = shift;

	if (defined $self->{data} || $self->{retry} >= MAX_RETRIES) {
		return 1;

	} if ($self->{stage} eq 'Connect') {
		$self->{http} = new Net::HTTP::NB(
			Host => $self->{host},
			KeepAlive => 1
		);
		if (!$self->{http}) {
			$self->{retry}++;
		} else {
			$self->{stage} = 'Request';
			delete $self->{headers};
			$self->{buf} = '';
		}

	} elsif ($self->{stage} eq 'Request') {
		undef $@;
		eval {
			$self->{http}->write_request(GET => $self->{file});
			$self->{stage} = 'Read Headers';
			$self->{checkStart} = time;
		};
		if ($@) {
			undef $@;
			$self->{retry}++;
			$self->{stage} = 'Connect';
		}

	} elsif ($self->{stage} eq 'Read Headers') {
		if (dataWaiting(\$self->{http})) {
			undef $@;
			eval {
				my ($code, $mess, %headers) = $self->{http}->read_response_headers;
				$self->{headers} = \%headers;
				if ($code == 200 && $mess eq 'OK') {
					$self->{stage} = 'Receive';
					$self->{checkStart} = time;
				} else {
					# HTTP error
					$self->{retry} = MAX_RETRIES;
					return 1;
				}
			};
			if ($@) {
				# Server does not speak HTTP properly
				undef $@;
				$self->{retry} = MAX_RETRIES;
				return 1;
			}

		} elsif (time - $self->{checkStart} > 60) {
			$self->{retry}++;
			$self->{stage} = 'Connect';
		}

	} elsif ($self->{stage} eq 'Receive') {
		my $buf;
		my $n;

		$n = $self->{http}->read_entity_body($buf, 1024 * 4);
		if ($n > 0) {
			# We have data
			$self->{buf} .= $buf;
			$self->{checkStart} = time;

		} elsif ($n == 0) {
			# EOF
			$self->{data} = $self->{buf};
			delete $self->{buf};
			return 1;

		} elsif (!defined $n) {
			# Error
			$self->{retry}++;
			$self->{stage} = 'Connect';

		} elsif (time - $self->{checkStart} > 60) {
			# Timeout
			$self->{retry}++;
			$self->{stage} = 'Connect';
		}
	}

	return 0;
}

sub data {
	return shift->{data};
}

sub progress {
	my $self = shift;
	if ($self->{headers} && $self->{headers}{'Content-Length'}) {
		return length($self->{buf}) / $self->{headers}{'Content-Length'};
	} else {
		return;
	}
}

1;
