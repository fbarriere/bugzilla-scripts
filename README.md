
# Bugzilla admin scripts

Here are some scripts I wrote to help me manage Bugzilla instances.
They are written in Perl and run from the Bugzilla install root as they
rely upon the Bugzilla libraries.

In most cases they must be run with "-I . -I./lib" to load the Bugzilla libraries
and dependencies.

A special wrapper script (run.sh) has been written to set the library path and
start the Perl scripts. The first argument is the full/absolute path to the
Bugzilla installation, and the second argument is the name of the script to run.
The rest of the command line is just passed to the script. If a configuration
file with the same prefix as the script, and the .cfg suffix exist, it is passed
as the --cfgfile argument to the script (as the scripts use AppConfig, so can
load arguments from a config file).

#Scripts, purpose, description

## bzldap.pl: users database update from LDAP

This script fetches users from a LDAP (or ActiveDirectory) server
and create (or update) the internal Bugzilla users database. The LDAP informations
(including the users search filter, in LDAP format) are provided through config
files. There should be one LDAP config file per LDAP/AD server to contact.

This script does, in order:
- Loop through all the LDAP/AD users that are returned using the search filter,
updates those that already exist but have changed, add new users.
- Repeats this for each LDAP/AD configuration
- Loops through all the users in the Buzilla database, for each user not found
in LDAP, disable the account by setting the "disabledtext" attribute.
- Does not disable users that are responsible (Default assignee or QA contact)
for some components (reports the list of components they are responsible for).

## re_enable_users.pl: 

This script just loops over all the users in the Bugzilla database and removes
any "disabledtext" attribute, so re-enables all users.

## change_user.pl: change assignee or CC users

This script is used to modify the default assignee or CC_list
member for all the components on a Bugzilla instance. This script can be usefull
to update a database after someone left...
