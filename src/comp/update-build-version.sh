#!/bin/bash
#set -x

export TMOUT=1

# -------------------------
# GIT

genGITBuildVersion () {
    echo "module BuildVersion(buildVersion, buildVersionNum) where" > BuildVersion.hs.new;
    echo buildVersion = \"$1\" >> BuildVersion.hs.new;
    echo buildVersionNum :: Integer >> BuildVersion.hs.new;
    echo buildVersionNum = 0x$1 >> BuildVersion.hs.new;
    if test -f BuildVersion.hs; then
	if !(diff BuildVersion.hs BuildVersion.hs.new); then
            mv BuildVersion.hs.new BuildVersion.hs;
	else
            echo "BuildVersion.hs up-to-date";
            rm BuildVersion.hs.new;
	fi;
    else
	mv BuildVersion.hs.new BuildVersion.hs;
    fi;
}

# -------------------------

if ( test -f BuildVersion.hs ) && [ "$NOUPDATEBUILDVERSION" = 1 ] ; then
    echo "BuildVersion.hs not modified"
else

    if [ "$NOGIT" = 1 ] ; then
	GITCOMMIT="0000000"
    else
	GITCOMMIT=`git show -s --format=%h HEAD`
    fi
    genGITBuildVersion ${GITCOMMIT}

fi

# -------------------------
