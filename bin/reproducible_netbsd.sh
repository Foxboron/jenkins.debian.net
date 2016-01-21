#!/bin/bash

# Copyright 2014-2016 Holger Levsen <holger@layer-acht.org>
# released under the GPLv=2

DEBUG=false
. /srv/jenkins/bin/common-functions.sh
common_init "$@"

# common code defining db access
. /srv/jenkins/bin/reproducible_common.sh

set -e

# build for these architectures
MACHINES="sparc64 amd64"

cleanup_tmpdirs() {
	cd
	rm -r $TMPDIR
	rm -r $TMPBUILDDIR
}

create_results_dirs() {
	mkdir -p $BASE/netbsd/dbd
}

save_netbsd_results() {
	local RUN=$1
	local MACHINE=$2
	mkdir -p $TMPDIR/$RUN/${MACHINE}
	cp -pr obj/releasedir/${MACHINE} $TMPDIR/$RUN/
	find $TMPDIR/$RUN/ -name MD5 -o -name SHA512 | xargs -r rm -v
}

#
# main
#
TMPBUILDDIR=$(mktemp --tmpdir=/srv/workspace/chroots/ -d -t rbuild-netbsd-build-XXXXXXXX)  # used to build on tmpfs
TMPDIR=$(mktemp --tmpdir=/srv/reproducible-results -d -t rbuild-netbsd-results-XXXXXXXX)  # accessable in schroots, used to compare results
DATE=$(date -u +'%Y-%m-%d')
START=$(date +'%s')
trap cleanup_tmpdirs INT TERM EXIT

cd $TMPBUILDDIR
echo "============================================================================="
echo "$(date -u) - Cloning the NetBSD git repository (which is synced with the NetBSD CVS repository)"
echo "============================================================================="
git clone --depth 1 https://github.com/jsonn/src
mv src netbsd
cd netbsd
NETBSD="$(git log -1)"
NETBSD_VERSION=$(git describe --always)
echo "This is netbsd $NETBSD_VERSION."
echo
git log -1

# from $src/share/mk/bsd.README:
# MKREPRO         If "yes", create reproducable builds. This enables
#                 different switches to make two builds from the same source tree
#                 result in the same build results.
export MKREPRO="yes"
MK_TIMESTAMP=$(git log -1 --pretty=%ct)

echo "============================================================================="
echo "$(date -u) - Building NetBSD ${NETBSD_VERSION} - first build run."
echo "============================================================================="
export TZ="/usr/share/zoneinfo/Etc/GMT+12"
# actually build everything
for MACHINE in $MACHINES ; do
	ionice -c 3 \
		./build.sh -j $NUM_CPU -V MKREPRO_TIMESTAMP=$MK_TIMESTAMP -U -u -m ${MACHINE} release
	# save results in b1
	save_netbsd_results b1 ${MACHINE}
	# cleanup and explicitly delete old tooldir to force re-creation for the next $MACHINE type
	./build.sh -U -m ${MACHINE} cleandir
	rm obj/tooldir.* -rf
	echo "${MACHINE} done, first time."
done

echo "============================================================================="
echo "$(date -u) - Building NetBSD ${NETBSD_VERSION} - cleaning up between builds."
echo "============================================================================="
rm obj/releasedir -r
rm obj/destdir.* -r
# we keep the toolchain(s)

echo "============================================================================="
echo "$(date -u) - Building NetBSD - second build run."
echo "============================================================================="
export TZ="/usr/share/zoneinfo/Etc/GMT-14"
export LANG="fr_CH.UTF-8"
export LC_ALL="fr_CH.UTF-8"
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/i/capture/the/path"
export CAPTURE_ENVIRONMENT="I capture the environment"
umask 0002
# use allmost all cores for second build
NEW_NUM_CPU=$(echo $NUM_CPU-1|bc)
for MACHINE in $MACHINES ; do
	ionice -c 3 \
		linux64 --uname-2.6 \
		./build.sh -j $NEW_NUM_CPU -V MKREPRO_TIMESTAMP=$MK_TIMESTAMP -U -u -m ${MACHINE} release
	# save results in b2
	save_netbsd_results b2 ${MACHINE}
	# cleanup and explicitly delete old tooldir to force re-creation for the next $MACHINE type
	./build.sh -U -m ${MACHINE} cleandir
	rm obj/tooldir.* -r
	echo "${MACHINE} done, second time."
done

# reset environment to default values again
export LANG="en_GB.UTF-8"
unset LC_ALL
export TZ="/usr/share/zoneinfo/UTC"
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:"
umask 0022

# clean up builddir to save space on tmpfs
rm -r $TMPBUILDDIR/netbsd

# run diffoscope on the results
TIMEOUT="30m"
DIFFOSCOPE="$(schroot --directory /tmp -c source:jenkins-reproducible-${DBDSUITE}-diffoscope diffoscope -- --version 2>&1)"
echo "============================================================================="
echo "$(date -u) - Running $DIFFOSCOPE on NetBSD build results..."
echo "============================================================================="
FILES_HTML=$(mktemp --tmpdir=$TMPDIR)
GOOD_FILES_HTML=$(mktemp --tmpdir=$TMPDIR)
BAD_FILES_HTML=$(mktemp --tmpdir=$TMPDIR)
GOOD_SECTION_HTML=$(mktemp --tmpdir=$TMPDIR)
BAD_SECTION_HTML=$(mktemp --tmpdir=$TMPDIR)
GOOD_FILES=0
ALL_FILES=0
SIZE=""
create_results_dirs
cd $TMPDIR/b1
tree .
for i in * ; do
	cd $i
	for j in $(find * -type f |sort -u ) ; do
		let ALL_FILES+=1
		call_diffoscope $i $j
		get_filesize $j
		if [ -f $TMPDIR/$i/$j.html ] ; then
			mkdir -p $BASE/netbsd/dbd/$i/$(dirname $j)
			mv $TMPDIR/$i/$j.html $BASE/netbsd/dbd/$i/$j.html
			echo "         <tr><td><a href=\"dbd/$i/$j.html\"><img src=\"/userContent/static/weather-showers-scattered.png\" alt=\"unreproducible icon\" /> $j</a> ($SIZE) is unreproducible.</td></tr>" >> $BAD_FILES_HTML
		else
			SHASUM=$(sha256sum $j|cut -d " " -f1)
			echo "         <tr><td><img src=\"/userContent/static/weather-clear.png\" alt=\"reproducible icon\" /> $j ($SHASUM, $SIZE) is reproducible.</td></tr>" >> $GOOD_FILES_HTML
			let GOOD_FILES+=1
			rm -f $BASE/netbsd/dbd/$i/$j.html # cleanup from previous (unreproducible) tests - if needed
		fi
	done
	cd ..
	if [ -s $GOOD_FILES_HTML ] ; then
		echo "       <table><tr><th>Reproducible artifacts for <code>$i</code></th></tr>" >> $GOOD_SECTION_HTML
		cat $GOOD_FILES_HTML >> $GOOD_SECTION_HTML
		echo "       </table>" >> $GOOD_SECTION_HTML
		rm $GOOD_FILES_HTML
	fi
	if [ -s $BAD_FILES_HTML ] ; then
		echo "       <table><tr><th>Unreproducible artifacts for <code>$i</code></th></tr>" >> $BAD_SECTION_HTML
		cat $BAD_FILES_HTML >> $BAD_SECTION_HTML
		echo "       </table>" >> $BAD_SECTION_HTML
		rm $BAD_FILES_HTML
	fi
done
GOOD_PERCENT=$(echo "scale=1 ; ($GOOD_FILES*100/$ALL_FILES)" | bc)
# are we there yet?
if [ "$GOOD_PERCENT" = "100.0" ] ; then
	MAGIC_SIGN="!"
else
	MAGIC_SIGN="?"
fi

#
#  finally create the webpage
#
cd $TMPDIR ; mkdir netbsd
PAGE=netbsd/netbsd.html
cat > $PAGE <<- EOF
<!DOCTYPE html>
<html lang="en-US">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width">
    <title>Reproducible NetBSD $MAGIC_SIGN</title>
    <link rel='stylesheet' href='global.css' type='text/css' media='all' />
  </head>
  <body>
    <div id="logo">
      <img src="NetBSD-smaller.png" />
      <h1>Reproducible NetBSD $MAGIC_SIGN</h1>
    </div>
    <div class="content">
      <div class="page-content">
EOF
write_page_intro NetBSD
write_page "       <p>$GOOD_FILES ($GOOD_PERCENT%) out of $ALL_FILES built NetBSD files were reproducible in our test setup"
if [ "$GOOD_PERCENT" = "100.0" ] ; then
	write_page "!"
else
	write_page "."
fi
write_page "        These tests were last run on $DATE for version ${NETBSD_VERSION} with MKREPRO=yes and MKREPRO_TIMESTAMP=$MK_TIMESTAMP and were compared using ${DIFFOSCOPE}.</p>"
write_explaination_table NetBSD
cat $BAD_SECTION_HTML >> $PAGE
cat $GOOD_SECTION_HTML >> $PAGE
write_page "     <p><pre>"
echo -n "$NETBSD" >> $PAGE
write_page "     </pre></p>"
write_page "    </div></div>"
write_page_footer NetBSD
publish_page
rm -f $FILES_HTML $GOOD_FILES_HTML $BAD_FILES_HTML $GOOD_SECTION_HTML $BAD_SECTION_HTML

# the end
calculate_build_duration
print_out_duration
irc_message "$REPRODUCIBLE_URL/netbsd/ has been updated. ($GOOD_PERCENT% reproducible)"
echo "============================================================================="

# remove everything, we don't need it anymore...
cleanup_tmpdirs
trap - INT TERM EXIT
