#!/bin/env perl
###########################################################################
=pod

=head1 NAME re_enable_users.pl

=head1 SYNOPSIS

re_enable_users.pl [options...]

=head1 DESCRIPTION

This script re-enables all the users of a Bugzilla install.

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

use Bugzilla;
use Bugzilla::User;

###############################################################################
# Constants:
###############################################################################

my $tool_name = "re_enable_users.pl";

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

my $log_config_source = Log::Log4perl->init((-f "./.bzldaplogrc") ? "./.bzldaplogrc" : \%default_log_config);
my $logger = Log::Log4perl::get_logger($tool_name);

foreach my $bu (Bugzilla::User->get_all()) {
	if($bu->disabledtext()) {
		$logger->info("Re-enable user: '" . $bu->name() . "'");
		$bu->set_disabledtext();
		$bu->update();
	}
}

