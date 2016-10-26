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
use POSIX qw(strftime);

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

=item --cfgfile=<configfile>

Load command line switches from a config file. The format is the format used
by AppConfig (<switch-name> = <value>, one per line, without the double dash).

=item --ldapcfg=<configfile>

Load LDAP settings from the config file. There must one per LDAP server.

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

my %ldap_cfg = (
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
	'uacfield' => {
		DEFAULT  => 'userAccountControl',
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'pagesize' => {
		DEFAULT  => 500,
		ARGS     => '=i',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
);

my %config_cfg = (
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
	'ldapcfg' => {
		DEFAULT  => undef,
		ARGS     => '=s@',
		ARGCOUNT => AppConfig::ARGCOUNT_LIST,
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

unless($cfg->get("ldapcfg")) {
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
	my ($ldapuser, $added, $skipped, $invalids, $ldapcfg) = @_;

	#
	# For each LDAP user, look for a user in Bugzilla with the same Email address.
	# extern_id

	my $usermail = $ldapuser->get_value($ldapcfg->get("ldapmail"));
	my $userid   = $ldapuser->get_value($ldapcfg->get("ldapuid"));
	my $username = $ldapuser->get_value($ldapcfg->get("ldapname"));
	my $uacvalue = $ldapuser->get_value($ldapcfg->get("uacfield"));
	my $uacmask  = 2;
	
	my $account_disable = $uacvalue & $uacmask;
	
	$logger->debug("Looking for: '$usermail' ($userid) ($account_disable)");

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
			$logger->warn("User $usermail, is disabled") if $account_disable;
			
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
						${$added}++;
					}
				}
				else {
					$logger->error("Invalid user name/mail: '$usermail'");
					push(@{$invalids}, $usermail);
				}
			}
		}
	}
}

sub ldap_connect {
	my ($server, $port, $user, $password) = @_;
	
	$logger->info("Connecting to: server '$server' ($port)");
	
	my $ldap = Net::LDAP->new($server, port => $port) or $logger->logdie("$@");
	
	#
	# LDAP bind: named or anonymous bind.
	#
	# \TODO: not tested with anonymous bind.
	#
	my $mesg;
	
	if($user) {
		$logger->info("Connecting to LDAP/AD server as: '$user'");
		$mesg = $ldap->bind($user, password => $password);
	}
	else {
		$logger->info("Connecting to LDAP/AD server anonymously");
		$mesg = $ldap->bind();
	}
	
	_check_ldap_answer($mesg);
		
	return $ldap;
}

###############################################################################
# LDAP dump:
###############################################################################

Bugzilla->usage_mode(Bugzilla::Constants::USAGE_MODE_CMDLINE);

my @processed    = ();
my @invalidusers = ();
my $added        = 0;
my $skipped      = 0;

foreach my $ldapcfgname ( @{$cfg->get("ldapcfg")} ) {
	
	my $ldapcfg = AppConfig->new({
		CASE     => 1,
		CREATE   => 1,
		PEDANTIC => 1,
	});
	$ldapcfg->define(%ldap_cfg);

	$logger->info("Loading LDAP configuration from file: '$ldapcfgname'");
	$ldapcfg->file($ldapcfgname);
	
	my $ldapconn = ldap_connect(
		$ldapcfg->get("ldapserver"),
		$ldapcfg->get("ldapport"),
		$ldapcfg->get("binduser"),
		$ldapcfg->get("bindpass"),
	);

	#
	# Search:
	#

	$logger->info("Searching for users, using the following attributes:");
	$logger->info("   UID...........: " . $ldapcfg->get("ldapuid"));
	$logger->info("   NAME..........: " . $ldapcfg->get("ldapname"));
	$logger->info("   EMAIL.........: " . $ldapcfg->get("ldapmail"));

	$logger->info("Using the filter.: " . $ldapcfg->get("ldapfilter"));
	$logger->info("Using the basedn.: " . $ldapcfg->get("basedn"));

	my $attrlist = [
		$ldapcfg->get("ldapuid"),
		$ldapcfg->get("ldapname"),
		$ldapcfg->get("ldapmail"),
		$ldapcfg->get("uacfield"),
	];

	my $page = Net::LDAP::Control::Paged->new(size => $ldapcfg->get("pagesize"));
	my $cookie;
	
	while (1) {
		my $mesg;
		if($cfg->get('allattr')) {
			$mesg = $ldapconn->search(
				base   => $ldapcfg->get("basedn"),
				filter => $ldapcfg->get("ldapfilter"),
				control => [$page]
			);
		}
		else {
			$mesg = $ldapconn->search(
				base   => $ldapcfg->get("basedn"),
				filter => $ldapcfg->get("ldapfilter"),
				attrs => $attrlist,
				control => [$page]
			);
		}
	
		_check_ldap_answer($mesg);
	
		while (my $adentry = $mesg->pop_entry()) {
			push(@processed, lc($adentry->get_value($ldapcfg->get("ldapmail"))));
	
			if($cfg->get('dumponly')) {
				$logger->info(
					"*********************" .
					$adentry->get_value($ldapcfg->get("ldapuid")) .
					"******************************"
				);
				$adentry->dump;
				$logger->info("***************************************************************");
			}
			else {
				lookup_update($adentry, \$added, \$skipped, \@invalidusers, $ldapcfg)
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
		$ldapconn->search(control => [$page]);
		$logger->logdie("abnormal exit");
	}

	#
	# Unbind, disconnect and say goodbye...
	#
	$ldapconn->unbind();

}

$logger->info("Checking Bugzilla users database (find disabled users)");

my $localusers = $cfg->get("localuser");
my $timestamp  = strftime "%c", localtime;
my @disabled   = ();

foreach my $bu (Bugzilla::User->get_all()) {
	my $username = lc($bu->email());
	if(not grep(/^$username/, @processed)) {
		if(grep(/^$username/, @$localusers)) {
			$logger->info("Skipping local-only user: '$username'.");
		}
		elsif($bu->disabledtext()) {
			$logger->debug("User '$username', already disabled");
		}
		else {
			my $responsabilities = $bu->product_responsibilities();
			if( @{$responsabilities} ) {
				foreach my $component ( @{$responsabilities->[0]->{'components'}} ) {
					$logger->error("User '$username' is responsible for: " . 
						$component->product()->classification()->name() . 
						"/" . 
						$component->product()->name() . 
						"/" . 
						$component->name() );
				}
			}
			else {
				$logger->warn("Disabling user: '$username'");
				push(@disabled, $username);
				unless($cfg->get("norun")) {
					$bu->set_disabledtext("Disabled as not found in reference AD. $timestamp");
					$bu->update();
				}
			}
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
$logger->info("Disabled " . scalar(@disabled) . " users");
foreach my $disabled (@disabled) {
	$logger->info("   $disabled");
}
