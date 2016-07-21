#!/bin/env perl
###########################################################################
=pod

=head1 NAME group_membership.pl

=head1 SYNOPSIS

group_membership.pl [options...]

=head1 DESCRIPTION

This script manipulates group memberhsip (add or remove users to/from groups).

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
use Bugzilla::Group;

###############################################################################
# Constants:
###############################################################################

my $tool_name = "group_membership.pl";

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

my $log_config_source = Log::Log4perl->init((-f "./.groupmembershiplogrc") ? "./.groupmembershiplogrc" : \%default_log_config);
my $logger = Log::Log4perl::get_logger($tool_name);

###############################################################################
# Command line switches:
###############################################################################

#####
=pod

=head1 OPTIONS AND ARGUMENTS

=over 4

=item --user=user-email>

The Email address of the user to change group membership.

=item --copy=<example-user-address>

The address of a user to user as example. Copy the group membership of this
example user.

=item --noupdate

Do not update fields. Just report what should be done.

=item --help

Print this help document.

=item --verbose

Increase verbosity...

=cut
#####

my %config_cfg = (
    'user' => {
        DEFAULT  => undef,
        ARGS     => '=s',
        ARGCOUNT => AppConfig::ARGCOUNT_ONE,
    },
    'from' => {
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

my $user;
my $from;

if ( $cfg->get("user") ) {
    $logger->info("Checking user: " . $cfg->get("user"));
    $user = Bugzilla::Object::match("Bugzilla::User", {login_name => $cfg->get("user")} );
	if ( @{$user} > 0 and $user->[0] ) {
		$user = $user->[0];
	}
	else {
		$logger->logdie("Invalid user: " . $cfg->get("user"));
	}
}
else {
    $logger->logdie("You must define a user (--user=<user-address> switch)");
}

if ( $cfg->get("from") ) {
    $logger->info("Checking user: " . $cfg->get("from"));
    $from = Bugzilla::Object::match("Bugzilla::User", {login_name => $cfg->get("from")} );
	if ( @{$from} > 0 and $from->[0] ) {
		$from = $from->[0];
	}
	else {
		$logger->logdie("Invalid user: " . $cfg->get("from"));
	}
}

if ( $cfg->get("from") ) {
    $logger->info("Searching for groups by user: " . $cfg->get("from"));

	my $groups = $from->direct_group_membership();

	foreach my $group ( @{$groups} ) {
		next if $group->name eq "editbugs";
		$logger->info("   Found....................:" . $group->name);
	}
}
