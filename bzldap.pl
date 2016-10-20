#!/bin/env perl
###########################################################################
=pod

=head1 NAME bzldap.pl

=head1 SYNOPSIS

bzldap.pl --ldapserver=<server-url> [options...]

=head1 DESCRIPTION

This script dumps users from a LDAP (or ActiveDirectory) server and
creates the corresponding users into a bugzilla database.
The script does not rely on any Bugzilla Perl module, it uses a straight
connection to the database (so if the bugzilla DB changes, the script fails).

The LDAP filter and BaseDN must be provided on the command line (or through
the config file). The filter should be carrefully generated in order to exclude
the accounts that do not correspond to real persons or disabled accounts in the
source LDAP.

There is no comparison or update of the Bugzilla database against the LDAP source,
the script is just used to create the users.
It does not disable users that are not defined in LDAP (compared to the other
scripts with more or less the same purpose), as I consider having users only
defined in Bugzilla a usual pattern (the admin user, some specific users for
Web services purpose, etc).

The script has been developed and tested with bugzilla 4.0.2. It is not supposed
to work with older version of Bugzilla.

ToDo: add a switch (and corresponding code) to disable users. Fetch the list
from LDAP using the proper filter and disable them. Could be usefull to update
the Bugzilla database compared to a master LDAP/AD (resigned employees).

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
use Net::LDAP::Control::Paged;
use Net::LDAP::Constant qw( LDAP_CONTROL_PAGED );

use Bugzilla;
use Bugzilla::User;

###############################################################################
# Constants:
###############################################################################

my $tool_name = "bzldap.pl";

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

my $salt = "aBcDeFgH";

###############################################################################
# Command line switches:
###############################################################################

#####
=pod

=head1 OPTIONS AND ARGUMENTS

=over 4

=item --ldapserver=<server-url>

The URL (or IP) of the LDAP/AD server to dump.

=item --ldapport=<port-number>

The port of the LDAP/AD server. 389 by default.

=item --binduser=<user-name>

The name of the user to use to bind to the server.
If unset, the bind will be anonymous.

=item --bindpass=<password>

The password for the bind. Necessary is a user name has been
provided (so the bind is not anonymous).

=item --basedn=<base-dn>

Base DN for the search. the search is done according to the
LDAP filter and down through the tree.

=item --ldapfilter=<filter-string>

The LDAP filter to apply in order to sort/reduce the search
base. Can be usefull to only search among real users, or
only among active users.
The format is the LDAP filter format as defined in the RFC...

=item --ldapuid=<uid-attribute>

The name of the UID attribute in the LDAP schema. By default 'uid',
should be sAMAccountName for ActiveDirectory.

=item --ldapmail=<email-attribute>

The name of the LDAP aatribute that stores the Email address.
Default is 'email'.

=item --ldapname=<name-attribute>

The name of the LDAP attribute used to store the full name.
Default value is 'sn'.

=item --cfgfile=<configfile>

Load command line switches from a config file. The format is the format used
by AppConfig (<switch-name> = <value>, one per line, without the double dash).

=item --dumponly

Only execute the LDAP search and dump the result. usefull to debug your
LDAP connection or schema without changing anything to your Bugzilla
database.

=item --allattr

Load all the LDAP attributes. By default only the LDAP attributes that are
necessary are loaded during the LDAP search. With this switch, all the LDAP
attributes (you can see) are loaded. Can be usefull with the --dumponly
switch to debug LDAP queries (filter and basedn).

=item --reportall

Report all the users processed, those already in Bugzilla and those added.
Without this option, only the added users are reported.

=item --norun

Simulate the run, and do not insert the new users in the database.

=item --noupdate

Do not update users description that mismatch between LDAP and Bugzilla.
Just report them as errors.

=item --help

Print this help document.

=item --verbose

Increase verbosity...

=cut
#####

my %config_cfg = (
	'ldapserver' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'ldapport' => {
		DEFAULT  => 389,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'binduser' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'bindpass' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'basedn' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'ldapfilter' => {
		DEFAULT  => "(&(objectClass=top)(objectClass=person))",
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'ldapuid' => {
		DEFAULT  => 'uid',
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'ldapmail' => {
		DEFAULT  => 'email',
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'ldapname' => {
		DEFAULT  => 'sn',
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
	'dumponly' => {
		DEFAULT  => 0,
		ARGCOUNT => AppConfig::ARGCOUNT_NONE,
	},
	'allattr' => {
		DEFAULT  => 0,
		ARGCOUNT => AppConfig::ARGCOUNT_NONE,
	},
	'reportall' => {
		DEFAULT  => 0,
		ARGCOUNT => AppConfig::ARGCOUNT_NONE,
	},
	'norun' => {
		DEFAULT  => 0,
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
	'localuser' => {
		DEFAULT => undef,
		ARGS    => '=s@',
		ARGCOUNT => AppConfig::ARGCOUNT_LIST,
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

if($cfg->get("cfgfile")) {
		$logger->info("Loading parameters from file: " . $cfg->get("cfgfile"));
		$cfg->file($cfg->get("cfgfile"));
}

unless($cfg->get("ldapserver")) {
	pod2usage({
		-message => "\n",
		-exitval => -1,
		-output  => \*STDERR,
	});
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
# Utilities:
###############################################################################

sub _check_ldap_answer {
	my ($answer) = @_;

	unless($answer) {
		$logger->logdie("UNKNWON ERROR");
	}

	if($answer->is_error()) {
		$logger->logdie("LDAP FAILURE: ", $answer->error_text());
	}
}

sub lookup_update {
	my ($ldapuser, $added, $skipped, $invalids) = @_;

	#
	# For each LDAP user, look for a user in Bugzilla with the same Email address.
	# extern_id

	my $usermail = $ldapuser->get_value($cfg->get("ldapmail"));
	my $userid   = $ldapuser->get_value($cfg->get("ldapuid"));
	my $username = $ldapuser->get_value($cfg->get("ldapname"));
	
	$logger->debug("Looking for: '$usermail'");

	my $bzuser = Bugzilla::Object::match("Bugzilla::User", {login_name => "$usermail"});
	scalar(@{$bzuser}) <= 1 or $logger->logdie("Error, more than 1 user match: \n" . dumper($bzuser));

	$logger->debug("Found: \n" . Dumper($bzuser));

	if($bzuser && scalar(@{$bzuser}) > 0) {
		$cfg->get("reportall") && $logger->info("Already defined: $usermail ($userid / $username)");
		${$skipped}++;
	}
	else {
		$bzuser = Bugzilla::Object::match("Bugzilla::User", {'extern_id' => "$userid"});
		scalar(@{$bzuser}) <= 1 or $logger->logdie("Error, more than 1 user match: \n" . dumper($bzuser));

		if($bzuser && scalar(@{$bzuser}) > 0) {
			$logger->debug("Found: \n" . Dumper($bzuser));
			$logger->error("External user already defined with different ID.");
			$logger->error("   In LDAP: id=$userid, mail=$usermail, name=$username");
			$logger->error("   In BZ  : id=" . $bzuser->[0]->login . ", mail=" . $bzuser->[0]->email . ", name=" . $bzuser->[0]->name);

			unless($cfg->get("norun") || $cfg->get("noupdate")) {
				$logger->info("Updating user '$username'");
				$bzuser->[0]->set_login("$usermail");
				$bzuser->[0]->set_name("$username");
				$bzuser->[0]->update();
			}
		}
		else {
			$logger->warn("Creating new user: $usermail ($userid / $username)");
			unless($cfg->get("norun")) {
				if ( $usermail =~ /^[\w\.\-]+@[\w\.\-]+$/ ) {
					my $nu = Bugzilla::User->create({
						login_name    => "$usermail",
						realname      => "$username",
						cryptpassword => '*',
						extern_id     => "$userid",
					});
					if ( not $nu ) {
						 $logger->error("failed to create user: '$userid/$usermail'");
					}
					else {
						$nu->update();
					}
				}
				else {
					$logger->error("Invalid user name/mail: '$usermail'");
					push(@{$invalids}, $usermail);
				}
			}
			${$added}++;
		}
	}
}

###############################################################################
# LDAP dump:
###############################################################################

Bugzilla->usage_mode(Bugzilla::Constants::USAGE_MODE_CMDLINE);

$logger->info(
	"Connecting to: " .
	$cfg->get("ldapserver") .
	" (" .
	$cfg->get("ldapport") .
	")"
);

my $ldap = Net::LDAP->new(
	$cfg->get("ldapserver"),
	port => $cfg->get("ldapport"),
) or $logger->logdie("$@");

#
# LDAP bind: named or anonymous bind.
#
# \TODO: not tested with anonymous bind.
#
my $mesg;

if($cfg->get("binduser")) {
	$logger->info("Connecting to LDAP/AD server as: " . $cfg->get("binduser"));
	$mesg = $ldap->bind(
		$cfg->get("binduser"),
		password => $cfg->get("bindpass")
	);
}
else {
	$logger->info("Connecting to LDAP/AD server anonymously");
	$mesg = $ldap->bind();
}

_check_ldap_answer($mesg);

#
# Search:
#

$logger->info("Searching for users, using the following attributes:");
$logger->info("   UID...........: " . $cfg->get("ldapuid"));
$logger->info("   NAME..........: " . $cfg->get("ldapname"));
$logger->info("   EMAIL.........: " . $cfg->get("ldapmail"));

$logger->info("Using the filter.: " . $cfg->get("ldapfilter"));
$logger->info("Using the basedn.: " . $cfg->get("basedn"));

my $attrlist = [
	$cfg->get("ldapuid"),
	$cfg->get("ldapname"),
	$cfg->get("ldapmail"),
];

my $page = Net::LDAP::Control::Paged->new(size => 999);
my $cookie;
my @processed=();
my $added=0;
my $skipped=0;
my @invalidusers = ();

while (1) {
	if($cfg->get('allattr')) {
		$mesg = $ldap->search(
			base   => $cfg->get("basedn"),
			filter => $cfg->get("ldapfilter"),
			control => [$page]
		);
	}
	else {
		$mesg = $ldap->search(
			base   => $cfg->get("basedn"),
			filter => $cfg->get("ldapfilter"),
			attrs => $attrlist,
			control => [$page]
		);
	}

	_check_ldap_answer($mesg);

	while (my $adentry = $mesg->pop_entry()) {
		push(@processed, lc($adentry->get_value($cfg->get("ldapmail")));

		if($cfg->get('dumponly')) {
			$logger->info(
				"*********************" .
				$adentry->get_value($cfg->get("ldapuid")) .
				"******************************"
			);
			$adentry->dump;
			$logger->info("***************************************************************");
		}
		else {
			lookup_update($adentry, \$added, \$skipped, \@invalidusers)
		}
	}

	my ($resp) = $mesg->control(LDAP_CONTROL_PAGED) or last;
	$cookie    = $resp->cookie or last;
	# Paging Control
	$page->cookie($cookie);
}

if ($cookie) {
	# Abnormal exit, so let the server know we do not want any more
	$page->cookie($cookie);
	$page->size(0);
	$ldap->search(control => [$page]);
	$logger->logdie("abnormal exit");
}

#
# Unbind, disconnect and say goodbye...
#
$ldap->unbind();

$logger->info("Checking Bugzilla users database (find disabled users)");

my $localusers = lc($cfg->get("localuser"));

foreach my $bu (Bugzilla::User->get_all()) {
	my $username = lc($bu->email());
	if(not grep(/^$username/, @processed)) {
		if(grep(/^$username/, @$localusers)) {
			$logger->info("Skipping local-only user: '$username'.");
		}
		elsif($bu->disabledtext()) {
			$logger->info("User '$username', already disabled");
		}
		else {
			$logger->warn("User '$username' not found; Disable it.");
		}
	}
}

$logger->info("Processed " . scalar(@processed) . " users");
$logger->info("Added $added new users");
$logger->info("Skipped $skipped already defined users");
$logger->info("Dropped " . scalar(@invalidusers) . " invalid users");
foreach my $invalid ( @invalidusers ) {
	$logger->info("   Invalid address: '$invalid'");
}
