
# Bugzilla admin scripts

Here are some scripts I wrote to help me manage Bugzilla instances.
They are written in Perl and run from the Bugzilla install root as they
rely upon the Bugzilla libraries.

In most cases they must be run with "-I . -I./lib" to load the Bugzilla libraries
and dependencies.

## Scripts, purpose, description

- bzldap.pl: This script fetches users from a LDAP (or ActiveDirectory) server
and create (or update) the internal Bugzilla users database. The LDAP informations
are provided on the command line (including the users search filter, in LDAP
format), but can also be provided through a config file (the script uses the AppConfig
Perl module and can read switch from a file).

- change_user.pl: This script is used to modify the default assignee or CC_list
member for all the components on a Bugzilla instance. This script can be usefull
to update a database after someone left...
