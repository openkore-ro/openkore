#########################################################################
#  OpenKore - WxWidgets Interface
#  Map viewer control
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
package Interface::Wx::MapViewer;

use strict;
use Wx ':everything';
use Wx::Event qw(EVT_PAINT);
use File::Spec;
use base qw(Wx::Panel);

our %addedHandlers;

sub new {
	my $class = shift;
	my $self = $class->SUPER::new(@_);
	$self->SetBackgroundColour(new Wx::Colour(0, 0, 0));
	EVT_PAINT($self, sub { $self->onPaint(); });
	return $self;
}

sub xpmmake {
	my $field = shift;
	my $data = "/* XPM */\n" .
		"static char * my_xpm[] = {\n" .
		"\"$field->{width} $field->{height} 2 1\",\n" .
		"\" \tc #000000\",\n" .
		"\".\tc #FFFFFF\",\n";
	for (my $y = $field->{height} - 1; $y >= 0; $y--) {
		$data .= "\"";
		for (my $x = 0; $x < $field->{width}; $x++) {
			$data .= (substr($field->{rawMap}, $y * $field->{width} + $x, 1) eq "\0") ?
				'.' : ' ';
		}
		$data .= "\",\n";
	}
	$data .= "};\n";
	return $data;
}

sub set {
	my ($self, $map, $x, $y, $field) = @_;

	$self->{field}{width} = $field->{width} if ($field && $field->{width});
	$self->{field}{height} = $field->{height} if ($field && $field->{height});

	if (!$self->{selfDot}) {
		return unless (-f "map/kore.png");
		Wx::Image::AddHandler(new Wx::PNGHandler()) unless $addedHandlers{png};
		$addedHandlers{png} = 1;
		my $image = Wx::Image->newNameMIME("map/kore.png", 'image/png');
		my $bitmap = new Wx::Bitmap($image);
		return unless $bitmap->Ok();
		$self->{selfDot} = $bitmap;
	}

	if ($map && $map ne $self->{field}{name}) {
		# Map changed
		undef $self->{bitmap};
		my ($file, $mime, $delete);

		if (-f "map/$map.jpg") {
			Wx::Image::AddHandler(new Wx::JPEGHandler()) unless $addedHandlers{jpg};
			$addedHandlers{jpg} = 1;
			$file = "map/$map.jpg";
			$mime = 'image/jpeg';
		} elsif (-f "map/$map.png") {
			Wx::Image::AddHandler(new Wx::JPEGHandler()) unless $addedHandlers{png};
			$addedHandlers{png} = 1;
			$file = "map/$map.png";
			$mime = 'image/png';
		} else {
			Wx::Image::AddHandler(new Wx::XPMHandler()) unless $addedHandlers{xpm};
			$addedHandlers{xpm} = 1;
			$file = File::Spec->tmpdir() . "/map.xpm";
			if (open(F, ">", $file)) {
				binmode F;
				print F xpmmake($field);
				close F;
				$mime = 'image/xpm';
				$delete = 1;
			} else {
				undef $file;
			}
		}
		return unless $file;


		$self->{field}{name} = $map;
		$self->{field}{x} = $x;
		$self->{field}{y} = $y;

		my $image = Wx::Image->newNameMIME($file, $mime);
		unlink $file if $delete;
		my $bitmap = new Wx::Bitmap($image);
		return unless $bitmap->Ok();
		$self->{bitmap} = $bitmap;
		$self->SetSizeHints($bitmap->GetWidth(), $bitmap->GetHeight());
		$self->Refresh();

	} elsif ($x ne $self->{field}{x} || $y ne $self->{field}{y}) {
		# Position changed
		$self->{field}{x} = $x;
		$self->{field}{y} = $y;
		$self->Refresh();
	}
}

sub onPaint {
	my $self = shift;
	my $dc = new Wx::PaintDC($self);
	return unless ($self->{bitmap} && $self->{selfDot});

	my ($x, $y, $xscale, $yscale);
	$xscale = $self->{bitmap}->GetWidth() / $self->{field}{width};
	$yscale = $self->{bitmap}->GetHeight() / $self->{field}{height};

	$dc->DrawBitmap($self->{bitmap}, 0, 0, 1);
	$dc->DrawBitmap($self->{selfDot},
		$self->{field}{x} * $xscale - ($self->{selfDot}->GetHeight() / 2),
		($self->{field}{height} - $self->{field}{y}) * $yscale - ($self->{selfDot}->GetHeight() / 2),
		1);
}

return 1;
