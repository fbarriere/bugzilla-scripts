#!/bin/env perl
###########################################################################
=pod

=head1 NAME change_user.pl

=head1 SYNOPSIS

change_user.pl [options...]

=head1 DESCRIPTION

This script can report components that feature specific assignee or CC_list
member. It can also replace them (assignee and CC_list member) or remove
them (only in the CC_list case).

The first purpose of this script is to replace employees who left the company
in bulk (many components being assigned to a single key employee).

=cut
###########################################################################


use strict;
use English;

select STDOUT;
$| = 1;

#
# Used packages:
#
use Cwd;

use Log::Log4perl;
use Log::Log4perl::Layout;

use AppConfig;
use Pod::Usage;
use Data::Dumper;

use Net::LDAP;

use Bugzilla;
use Bugzilla::User;
use Bugzilla::Component;

###############################################################################
# Constants:
###############################################################################

my $tool_name = "change_user.pl";

#
# Logging setup:
#
my %default_log_config = (
	'log4perl.rootLogger'                                   => "INFO, ScreenOnly",
	'log4perl.appender.ScreenOnly'                          => "Log::Log4perl::Appender::Screen",
	'log4perl.appender.ScreenOnly.layout'                   => "PatternLayout",
	'log4perl.appender.ScreenOnly.layout.ConversionPattern' => "[%p] %m%n",
	'log4perl.appender.ScreenOnly.stderr'                   => 0,
);

my $log_config_source = Log::Log4perl->init((-f "./.chuserlogrc") ? "./.chuserlogrc" : \%default_log_config);
my $logger = Log::Log4perl::get_logger($tool_name);

###############################################################################
# Command line switches:
###############################################################################

#####
=pod

=head1 OPTIONS AND ARGUMENTS

=over 4

=item --assignee_from=<original-assignee>

The Email address to search for in the assignee field.
If not assigne_to address is provided, the matches are reported and nothing
is changed in the Bugzilla database.

=item --assignee_to=<substitute-assignee>

This second address will be used to set/change the assignee field.
If only a single address is provided, the matches are reported and nothing
is changed in the Bugzilla database.

=item --component=<component-name>

Limit the changes to the named component.

=item --cclist_from=<original-cclist-member>

The Email address to search for in the cc_list field.
If no cclist_to address is provided, it is removed from the cc_list where
found.

=item --cclist_to=<substitue-cclist-member>

This second address is provided, it is used to replace the first one in the list.
When replacing an address, the script makes sure the new address is not already
in the list.

=item --noupdate

Do not update fields. Just report what should be done.

=item --help

Print this help document.

=item --verbose

Increase verbosity...

=cut
#####

my %config_cfg = (
	'assignee_from' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'assignee_to' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'cclist_from' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'cclist_to' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'component' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'verbose' => {
		DEFAULT  => 0,
		ARGS     => '+',
		ARGCOUNT => AppConfig::ARGCOUNT_NONE,
	},
	'quiet' => {
		DEFAULT  => 0,
		ARGS     => '+',
		ARGCOUNT => AppConfig::ARGCOUNT_NONE,
	},
	'noupdate' => {
		DEFAULT  => 0,
		ARGCOUNT => AppConfig::ARGCOUNT_NONE,
	},
	'cfgfile' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'help' => {
		DEFAULT  => 0,
		ARGCOUNT => AppConfig::ARGCOUNT_NONE,
	},
);

$logger->debug("ARGS: " . join("|", @ARGV));

my $cfg = AppConfig->new({
	CASE     => 1,
	CREATE   => 1,
	PEDANTIC => 1,
});
$cfg->define(%config_cfg);

unless($cfg->args(\@ARGV) == 1) {
	pod2usage({
		-message => "\n",
		-exitval => -1,
		-output  => \*STDERR,
	});
}

if($cfg->get("help")) {
	pod2usage({
		-message => "\n",
		-exitval => -1,
		-output  => \*STDERR,
	});
}

if($cfg->get("cfgfile")) {
		$logger->info("Loading parameters from file: " . $cfg->get("cfgfile"));
		$cfg->file($cfg->get("cfgfile"));
}

#
# Update log level:
#
my $verbose_level;

if($cfg->get("verbose")) {
	$verbose_level = $cfg->get("verbose");
	$logger->info("Increasing verbosity by: $verbose_level");
	while($verbose_level > 0) {
		$logger->more_logging();
		$verbose_level--;
	}
}
$verbose_level = $cfg->get("verbose");

my $quiet_level;

if($cfg->get("quiet")) {
	$quiet_level = $cfg->get("quiet");
	$logger->info("Decreasing verbosity by: $quiet_level");
	while($quiet_level > 0) {
		$logger->less_logging();
		$quiet_level--;
	}
}
$quiet_level = $cfg->get("quiet");

###############################################################################
# Run:
###############################################################################

#
# Try find each user provided in the switches in the Bugzilla database in order
# to avoid further problems when setting the fields ("user does not exist" error).
#

my $assignee_from;
if ( $cfg->get("assignee_from") ) {
	$logger->info("Checking user: " . $cfg->get("assignee_from"));
	$assignee_from = Bugzilla::Object::match("Bugzilla::User", {login_name => $cfg->get("assignee_from")} );
	if ( @{$assignee_from} > 0 and $assignee_from->[0] ) {
		$assignee_from = $assignee_from->[0];
		$logger->info("Found user: " . $assignee_from->login);
	}
	else {
		$logger->logdie("Invalid Bugzilla user: " . $cfg->get("assignee_from"));
	}
}

my $assignee_to;
if ( $cfg->get("assignee_to") ) {
	$logger->info("Checking user: " . $cfg->get("assignee_to"));
	$assignee_to = Bugzilla::Object::match("Bugzilla::User", {login_name => $cfg->get("assignee_to")} );
	if ( @{$assignee_to} > 0 and $assignee_to->[0] ) {
		$assignee_to = $assignee_to->[0];
		$logger->info("Found user: " . $assignee_to->login);
	}
	else {
		$logger->logdie("Invalid Bugzilla user: " . $cfg->get("assignee_to"));
	}
}

my $cclist_from;
if ( $cfg->get("cclist_from") ) {
	$logger->info("Checking user: " . $cfg->get("cclist_from"));
	$cclist_from = Bugzilla::Object::match("Bugzilla::User", {login_name => $cfg->get("cclist_from")} );
	if ( @{$cclist_from} > 0 and $cclist_from->[0] ) {
		$cclist_from = $cclist_from->[0];
		$logger->info("Found user: " . $cclist_from->login);
	}
	else {
		$logger->logdie("Invalid Bugzilla user: " . $cfg->get("cclist_from"));
	}
}

my $cclist_to;
if ( $cfg->get("cclist_to") ) {
	$logger->info("Checking user: " . $cfg->get("cclist_to"));
	$cclist_to = Bugzilla::Object::match("Bugzilla::User", {login_name => $cfg->get("cclist_to")} );
	if ( @{$cclist_to} > 0 and $cclist_to->[0] ) {
		$cclist_to = $cclist_to->[0];
		$logger->info("Found user: " . $cclist_to->login);
	}
	else {
		$logger->logdie("Invalid Bugzilla user: " . $cfg->get("cclist_to"));
	}
}

#
# List all the components to then loop over tham and change or report users in
# assignee and cc_list fields.
#
# TODO:
#   - Add a project filter to only run on a specific project.
#
my @components = Bugzilla::Component->get_all();

$logger->info("Found " . scalar(@components) . " components");

my $only_component = $cfg->get("component");

#
# Loop over the components, report (and change) the following:
#   - When an assignee has been provided (switch) and matches the current assignee.
#   - If a substitue assignee has been provided, replace the current assignee.
#   - If a cclist has been provided and a member of the current cc_list matches.
#
# Warnning: make both sides of the comparison lower-case only, as the addresses
# are not case sensitive...
#
foreach my $component ( @components ) {
	next if ( $only_component and $only_component ne $component->name);
	if ( $assignee_from and lc($assignee_from->login) eq lc($component->default_assignee->login) ) {
		$logger->info("   Changing assignee for component: " . $component->product()->name . "/" . $component->name);
		$logger->info("      From........................: " . $component->default_assignee->login);
		if ( $assignee_to ) {
			$logger->info("      To..........................: " . $assignee_to->login);
			unless ( $cfg->get("noupdate") ) {
				$component->set_default_assignee( $assignee_to->login );
				$component->update();
			}
		}
	}

	my $old_cclist = join( ", ", map { $_->login; } @{$component->initial_cc} );
	my @new_cclist;
	my $changed = 0;
	
	foreach my $member ( @{$component->initial_cc} ) {
    	if ( $cclist_from and ( lc($cclist_from->login) eq lc($member->login) ) ) {
			$changed++;
			$logger->debug("Removing member " . $member->login);
		}
		else {
			unless ( grep { $member->login eq $_ } @new_cclist ) {
				push (@new_cclist, $member->login );
			}
		}
    }
	if ( $cclist_to ) {
		unless ( grep { $cclist_to->login eq $_ } @new_cclist ) {
			$logger->debug("Adding to cc_list: " . $cclist_to->login );
			$changed++;
			push (@new_cclist, $cclist_to->login );
		}
	}
	
	if ( $changed ) {
		$logger->info("   Changing cc_list for component.: " . $component->product()->name . "/" . $component->name);
		$logger->info("      Old CC_list.................: " . $old_cclist);
		$logger->info("      New CC_list.................: " . join(", ", @new_cclist) );

		unless ( $cfg->get("noupdate") ) {
			$component->set_cc_list(\@new_cclist);
			$component->update();
		}
	}
}
