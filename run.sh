#!/bin/bash
###############################################################################
# Generic wrapper for Bugzilla Perl scripts.
###############################################################################
#

BZCLI_ROOT=`dirname $0`
BZROOT="$1"
shift
SCRIPT="$1"
shift

fatal() {
        echo "$@"
        exit 255
}

echo "Root: $BZCLI_ROOT"

if [ "x$BZROOT" = "x" ]
then
    fatal "The Bugzilla path must be the first argument of the command line"
fi

if ! [ -d "$BZROOT" ]
then
        fatal "Bugzilla root does not exist: '$BZROOT'"
fi

if [ "x$SCRIPT" = "x" ]
then
        fatal "The script name must be the second argument of the command line"
fi

if ! [ -f "$SCRIPT" ]
then
        fatal "Bugzilla script does not exist: '$SCRIPT'"
fi

CFGFILE=`echo $SCRIPT | /bin/sed -e 's/\.pl/\.cfg/'`
EXTRAARGS=""

if [ -f $CFGFILE ]
then
	EXTRAARGS="--cfgfile=${CFGFILE}"
echo "***** Using config file: $CFGFILE *****"
fi

if [ -f "$BZROOT/index.cgi" ]
then
        PERLEXEC=`/bin/cat "$BZROOT/index.cgi" | /usr/bin/head -1 | /bin/sed -e 's/^#\!\s*//' | /bin/sed -e 's/\/perl\s\s*\-wT\s*/\/perl/'`
        if [ "x$PERLEXEC" = "x" ] || ! [ -x "$PERLEXEC" ]
        then
                fatal "Failed to determine perl exec: '$PERLEXEC'"
        fi
        echo "Perl exec: '$PERLEXEC'"

else
        fatal "Can't find 'index.cgi' in Bugzilla install (needed to determine perl exec)."
fi

echo "***** Running script: $SCRIPT *****"

${PERLEXEC} \
	-I$BZROOT \
	-I$BZROOT/lib \
	${BZCLI_ROOT}/${SCRIPT} \
		${EXTRAARGS} \
		$*


