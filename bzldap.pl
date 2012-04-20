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

use Digest;

use Net::LDAP;

use DBI;

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

=item --defaultpass=<password>

Default password to set in Bugzilla for the created users. Should not be
very important as the authentication will be made against LDAP/AD (unless
you want to authenticate against the Bugzilla database and only sync it with
your LDAP server).

=item --passcrypt=<password-algorythm>

Password algorythm to use. by default SHA-256 (default for bugzilla 4.x).

=item --dbhost=<database-host>

Name of the host the database server is running on. default is 'localhost'

=item --dbport=<port-number>

Port number the database server is connected to.

=item --dbuser=<user-name>

Name of the user to connect to the database server.

=item --dbpass=<password>

Password to use to connect to the database.

=item --dbname=<database-name>

The name of the database used by the bugzilla instance. By default; 'bugzilla'

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
	'defaultpass' => {
		DEFAULT  => 'password',
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'passcrypt' => {
		DEFAULT  => 'SHA-256',
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'dbhost' => {
		DEFAULT  => 'localhost',
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'dbport' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'dbuser' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'dbpass' => {
		DEFAULT  => undef,
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'dbname' => {
		DEFAULT  => 'bugzilla',
		ARGS     => '=s',
		ARGCOUNT => AppConfig::ARGCOUNT_ONE,
	},
	'verbose' => {
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

###############################################################################
# LDAP dump:
###############################################################################

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

if($cfg->get('allattr')) {
	$mesg = $ldap->search(
		base   => $cfg->get("basedn"),
		filter => $cfg->get("ldapfilter"),
		sizelimit => 0,
	);
}
else {
	$mesg = $ldap->search(
		base   => $cfg->get("basedn"),
		filter => $cfg->get("ldapfilter"),
		sizelimit => 0,
		attrs => $attrlist,
	);
}

_check_ldap_answer($mesg);

if($mesg->count() > 0) {
	$logger->info("Search returned: ", $mesg->count(), " matches");
}
else {
	$logger->logdie("Search returned no result.");
}

#
# If we just want to dump the LDAP result:
#
if($cfg->get('dumponly')) {
	foreach my $ldapuser ($mesg->entries) {
		$logger->info(
			"*********************" . 
			$ldapuser->get_value($cfg->get("ldapuid")) . 
			"******************************"
		);
		$ldapuser->dump;
	}
	$logger->info("***************************************************************");
	exit;
}

#
# Connect to the Bugzilla database server:
#
$logger->info("Connecting to Bugzilla database server.");
$logger->info("   Server host...: " . $cfg->get("dbhost"));
$logger->info("   Server port...: " . $cfg->get("dbport"));
$logger->info("   User name.....: " . $cfg->get("dbuser"));
$logger->info("   Database name.: " . $cfg->get("dbname"));

my $datasource = 
	"dbi:mysql:" .
	"database=" . $cfg->get("dbname") .
	";host=" . $cfg->get("dbhost") .
	";port=" . $cfg->get("dbport")
;

my $dbh = DBI->connect(
	$datasource,
	$cfg->get("dbuser"),
	$cfg->get("dbpass"),
) or $logger->logdie("Database connection failed: " . $DBI::errstr);

my $findsth = $dbh->prepare(
	"SELECT * FROM profiles WHERE login_name=?"
) or $logger->logdie("Prepare failed: " . $DBI::errstr);

my $verifsth = $dbh->prepare(
	"SELECT * FROM profiles WHERE extern_id=?"
) or $logger->logdie("Prepare failed: " . $DBI::errstr);

#
# Generate the default password once for all, then prepare the insert
# statement.
#
my $hasher = new Digest($cfg->get("passcrypt"));

$hasher->add($cfg->get("defaultpass"), "$salt");

my $encryptedpass = 
	"$salt" .
	$hasher->b64digest .
	"{" . $cfg->get("passcrypt") . "}";

my $insertsth = $dbh->prepare(
	"INSERT INTO profiles VALUES ('', ?, '$encryptedpass', ?, '', 0, 1, ?);"
);

#
# For each LDAP user, look for a user in Bugzilla with the same Email address.
#
$logger->info("Looking for LDAP user in Bugzilla'a database.");

my $added=0;
my $skipped=0;

foreach my $ldapuser ($mesg->entries) {
	my $usermail = $ldapuser->get_value($cfg->get("ldapmail"));
	my $userid   = $ldapuser->get_value($cfg->get("ldapuid"));
	my $username = $ldapuser->get_value($cfg->get("ldapname"));
	
	$logger->debug("Looking for: $usermail");
	$findsth->execute($usermail) or $logger->logdie("Select failed: " . $DBI::errstr);
	my $userh = $findsth->fetchall_hashref('login_name');
	
	if($userh && keys %{$userh}) {
		$cfg->get("reportall") && $logger->info("Already defined: $usermail ($userid / $username)");
		$skipped++;
	}
	else {
		#
		# Verify a user with the saem extern_id does not already exist before creating
		#
		$verifsth->execute($userid) or $logger->logdie("Select failed: " . $DBI::errstr);
		my $verifh = $verifsth->fetchall_hashref('extern_id');
		if($verifh && keys %{$verifh}) {
			$logger->error("User with external ID '$userid' already defined in the database.");
			$logger->error("   This user should be: '$userid' '$usermail' '$username'");
			$logger->error("   But is defined as..: '$userid'" . 
				" '" . $verifh->{$userid}->{'login_name'} . "'" .
				" '" . $verifh->{$userid}->{'realname'} . "'"
			);
			$skipped++;
		}
		else {
			$logger->info("Creating new user: $usermail ($userid / $username)");
			$cfg->get("norun") || $insertsth->execute("$usermail", "$username", "$userid") or $logger->logdie("Insert failed: " . $DBI::errstr);
			$added++;
		}
	}
}

#
# Unbind, disconnect and say goodbye...
#
$dbh->disconnect();
$ldap->unbind();

$logger->info("Added $added new users");
$logger->info("Skipped $skipped already defined users");



