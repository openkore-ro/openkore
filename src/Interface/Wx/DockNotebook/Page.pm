#########################################################################
#  OpenKore - WxWidgets Interface
#
#  Copyright (c) 2005 OpenKore development team 
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
##
# MODULE DESCRIPTION: Notebook page child used by DockNotebook
#
# This is class is a mostly-private class used by Interface::Wx::DockNotebook.
# The only function you are allowed to use is $page->set().

package Interface::Wx::DockNotebook::Page;

use strict;
use Wx ':everything';
use Wx::Event qw(EVT_CLOSE);
use base qw(Wx::Panel);
use Interface::Wx::TitleBar;


sub new {
	my ($class, $parent, $show_buttons, $title) = @_;
	my $self = $class->SUPER::new($parent, -1);

	my $vbox = $self->{vbox} = new Wx::BoxSizer(wxVERTICAL);
	my $titlebar = new Interface::Wx::TitleBar($self, $title, !$show_buttons);
	$titlebar->onDetach(\&onDetach, $self);
	$titlebar->onClose(\&onClose, $self);
	$self->{title} = $title;
	$self->{show_buttons} = $show_buttons;

	$vbox->Add($titlebar, 0, wxGROW);
	$vbox->SetItemMinSize($titlebar, -1, $titlebar->{size});
	$self->SetSizer($vbox);
	return $self;
}

##
# $page->set(child)
# child: A child control.
#
# Add a child control to this notebook page.
# See $docknotebook->newPage() for information.
sub set {
	my ($self, $child) = @_;
	return if ($self->{child});
	$self->{child} = $child;
	$self->{vbox}->Add($child, 1, wxGROW);
	$self->{vbox}->Layout;
}


###### Private ######

sub getDock {
	my $self = shift;
	my $parent = $self->GetParent;
	$parent = $parent->GetParent if (!$parent->isa("Interface::Wx::DockNotebook"));
	return $parent;
}

sub onDetach {
	my $self = shift;
	my $dock = $self->getDock;

	my $dialog = $self->{dialog} = new Wx::Dialog($self->GetGrandParent, -1, $self->{title},
		wxDefaultPosition, wxDefaultSize, wxDEFAULT_DIALOG_STYLE | wxRESIZE_BORDER);
	$self->{dialog} = $dialog;
	EVT_CLOSE($dialog, sub { $self->onDialogClose($dock); });
	$self->{child}->Reparent($dialog);
	$dialog->Layout;
	$dialog->Show(1);

	$dock->closePage($self);
	push @{$dock->{dialogs}}, $self;

	$self->{child}->Layout;
	$self->{child}->Fit;
	my $size = $self->{child}->GetBestSize;
	my $w = $size->GetWidth;
	my $h = $size->GetHeight;
	$w = 150 if ($w < 150);
	$h = 150 if ($h < 150);
	$dialog->SetClientSize($w, $h);
}

sub onDialogClose {
	my ($self, $dock) = @_;
	$self->{dialog}->Destroy;

	for (my $i = 0; $i < @{$dock->{dialogs}}; $i++) {
		if ($dock->{dialogs}[$i] eq $self) {
			delete $dock->{dialogs}[$i];
			return;
		}
	}
}

sub onClose {
	my $self = shift;
	$self->getDock->closePage($self);
}

1;
