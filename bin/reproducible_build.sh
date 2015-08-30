#!/bin/bash

# Copyright 2014-2015 Holger Levsen <holger@layer-acht.org>
#         © 2015 Mattia Rizzolo <mattia@mapreri.org>
# released under the GPLv=2

DEBUG=false
. /srv/jenkins/bin/common-functions.sh
common_init "$@"

# common code defining db access
. /srv/jenkins/bin/reproducible_common.sh

set -e

# sleep 1-12 secs to randomize start times
delay_start() {
	/bin/sleep $(echo "scale=1 ; $(shuf -i 1-120 -n 1)/10" | bc )
}

create_results_dirs() {
	mkdir -vp $BASE/dbd/${SUITE}/${ARCH}
	mkdir -vp $BASE/dbdtxt/${SUITE}/${ARCH}
	mkdir -vp $BASE/logs/${SUITE}/${ARCH}
	mkdir -vp $BASE/logdiffs/${SUITE}/${ARCH}
	mkdir -vp $BASE/rbuild/${SUITE}/${ARCH}
	mkdir -vp $BASE/buildinfo/${SUITE}/${ARCH}
}

handle_race_condition() {
	echo | tee -a $BUILDLOG
	local msg="Warning, package ${SRCPACKAGE} in ${SUITE} on ${ARCH} is probably already building elsewhere, exiting.\n"
	msg="${msg}Please check $BUILD_URL and https://reproducible.debian.net/$SUITE/$ARCH/${SRCPACKAGE} for a different build.\n"
	case $1 in
		"db")
			msg="${msg}The race condition was caught while marking the build attempt in the database.\n"
			;;
		"init")
			msg="${msg}The race condition was caught while writing the lockfile.\n"
			;;
		"lockfile")
			msg="${msg}The race condition was caught while checking the lockfile for pid correctness.\n"
			;;
	esac
	printf "$msg" | tee -a $BUILDLOG
	printf "$(date) - $msg" >> /var/log/jenkins/reproducible-race-conditions.log
	echo "$(date) - Terminating this build quickly and nicely..." | tee -a $RBUILDLOG
	if [ $SAVE_ARTIFACTS -eq 1 ] ; then
		SAVE_ARTIFACTS=0
		if [ ! -z "$NOTIFY" ] ; then NOTIFY="failure" ; fi
	fi
	exit 0
}

check_for_race_conditions() {
	if [ $$ -ne $(cat "$LOCKFILE") ] ; then
		BAD_LOCKFILE=true
		handle_race_condition lockfile
	fi
}

save_artifacts() {
		local random=$(head /dev/urandom | tr -cd '[:alnum:]'| head -c5)
		local ARTIFACTS="artifacts/r00t-me/${SRCPACKAGE}_${SUITE}_tmp-${random}"
		local URL="$REPRODUCIBLE_URL/$ARTIFACTS/"
		local HEADER="$BASE/$ARTIFACTS/.HEADER.html"
		mkdir -p $BASE/$ARTIFACTS
		cp -r $TMPDIR/* $BASE/$ARTIFACTS/
		echo | tee -a ${RBUILDLOG}
		local msg="Artifacts from this build are preserved. They will be available for 72h only, so download them now if you want them.\n"
		msg="${msg}WARNING: You shouldn't trust packages you downloaded from this host, they can contain malware or the worst of your fears, packaged nicely in debian format.\n"
		msg="${msg}If you are not afraid facing your fears while helping the world by investigating reproducible build issues, you can download the artifacts from the following location: $URL\n"
		printf "$msg" | tee -a $BUILDLOG
		echo "<p>" > $HEADER
		printf "$msg" | sed 's#$#<br />#g' >> $HEADER
		echo "Package page: <a href=\"$REPRODUCIBLE_URL/${SUITE}/${ARCH}/${SRCPACKAGE}\">$REPRODUCIBLE_URL/${SUITE}/${ARCH}/${SRCPACKAGE}</a><br />" >> $HEADER
		echo "</p>" >> $HEADER
		chmod 644 $HEADER
		echo | tee -a ${RBUILDLOG}
		# irc message
		if [ ! -z "$NOTIFY" ] ; then
			local MESSAGE="$URL published"
			if [ "$NOTIFY" = "diffoscope" ] ; then
				MESSAGE="$MESSAGE, $DIFFOSCOPE had troubles with these..."
			fi
			irc_message "$MESSAGE"
		fi
}

cleanup_all() {
	if [ $SAVE_ARTIFACTS -eq 1 ] ; then save_artifacts ; fi
	if [ "$NOTIFY" = "failure" ] ; then
		echo "No artifacts were saved for this build." | tee -a ${RBUILDLOG}
		irc_message "Check $REPRODUCIBLE_URL/$SUITE/$ARCH/$SRCPACKAGE and $BUILD_URL to find out why no artifacts were saved (final status $STATUS)"
	elif [ ! -z "$NOTIFY" ] && [ $SAVE_ARTIFACTS -eq 0 ] ; then
		irc_message "$REPRODUCIBLE_URL/$SUITE/$ARCH/$SRCPACKAGE done: $STATUS"
	fi
	gzip -9fvn $RBUILDLOG
	if [ "$MODE" = "legacy" ] || [ "$MODE" = "ng" ] ; then
		# XXX quite ugly: this is just needed to get the correct value of the
		# compressed files in the html. It's cheap and quite safe so, *shrugs*...
		gen_package_html $SRCPACKAGE
	fi
	cd
	rm -r $TMPDIR
	if ! $BAD_LOCKFILE ; then rm -f $LOCKFILE ; fi
}

update_db_and_html() {
	# everything passed at this function is saved as a status of this package in the db
	STATUS="$@"
	if [ -z "$VERSION" ] ; then
		VERSION="None"
	fi
	local OLD_STATUS=$(sqlite3 -init $INIT ${PACKAGES_DB} "SELECT status FROM results WHERE package_id='${SRCPKGID}'")
	# notification for changing status
	if [ "${OLD_STATUS}" = "reproducible" ] && [ "$STATUS" != "depwait" ] ; then
		if [ "$STATUS" = "unreproducible" ] || ( [ "$STATUS" = "FTBFS" ] && [ "$SUITE" = "testing" ] ) ; then
			MESSAGE="${REPRODUCIBLE_URL}/${SUITE}/${ARCH}/${SRCPACKAGE} : reproducible ➤ ${STATUS}"
			echo "\n$MESSAGE" | tee -a ${RBUILDLOG}
			irc_message "$MESSAGE"
			# disable ("regular") irc notification unless it's due to diffoscope problems
			if [ ! -z "$NOTIFY" ] && [ "$NOTIFY" != "diffoscope" ] ; then
				NOTIFY=""
			fi
		fi
	fi
	if [ "$OLD_STATUS" != "$STATUS" ] && [ "$NOTIFY_MAINTAINER" -eq 1 ] && \
			[ "$OLD_STATUS" != "depwait" ] && [ "$STATUS" != "depwait" ] && \
			[ "$OLD_STATUS" != "404" ] && [ "$STATUS" != "404" ]; then
		echo "More information on $REPRODUCIBLE_URL/$SUITE/$ARCH/$SRCPACKAGE, feel free to reply to this email to get more help." | \
			mail -s "$SRCPACKAGE changed in $SUITE: $OLD_STATUS -> $STATUS" \
				-a "From: Reproducible builds folks <reproducible-builds@lists.alioth.debian.org>" \
				"$SRCPACKAGE@packages.debian.org"
	fi
	sqlite3 -init $INIT ${PACKAGES_DB} "REPLACE INTO results (package_id, version, status, build_date, build_duration, builder) VALUES ('$SRCPKGID', '$VERSION', '$STATUS', '$DATE', '$DURATION', '$BUILDER')"
	if [ ! -z "$DURATION" ] ; then  # this happens when not 404 and not_for_us
		sqlite3 -init $INIT ${PACKAGES_DB} "INSERT INTO stats_build (name, version, suite, architecture, status, build_date, build_duration, builder) VALUES ('$SRCPACKAGE', '$VERSION', '$SUITE', '$ARCH', '$STATUS', '$DATE', '$DURATION', '$BUILDER')"
	fi
	# unmark build since it's properly finished
	sqlite3 -init $INIT ${PACKAGES_DB} "DELETE FROM schedule WHERE package_id='$SRCPKGID';"
	gen_package_html $SRCPACKAGE
	echo
	echo "Successfully updated the database and updated $REPRODUCIBLE_URL/rb-pkg/${SUITE}/${ARCH}/$SRCPACKAGE.html"
	echo
}

update_rbuildlog() {
	chmod 644 $RBUILDLOG
	mv $RBUILDLOG $BASE/rbuild/${SUITE}/${ARCH}/${SRCPACKAGE}_${EVERSION}.rbuild.log
	RBUILDLOG=$BASE/rbuild/${SUITE}/${ARCH}/${SRCPACKAGE}_${EVERSION}.rbuild.log
}

diff_copy_buildlogs() {
	local DIFF="$BASE/logdiffs/$SUITE/$ARCH/${SRCPACKAGE}_${EVERSION}.diff"
	if [ -f b1/build.log ] ; then
		if [ -f b2/build.log ] ; then
			printf "Diff of the two buildlogs:\n\n--\n" | tee -a $DIFF
			diff -u b1/build.log b2/build.log | tee -a $DIFF
			if [ ${PIPESTATUS[0]} -eq 0 ] ; then
				echo "The two build logs are identical! \o/" | tee -a $DIFF
			fi
			echo -e "\nCompressing the 2nd log..."
			gzip -9vn $DIFF
			gzip -9cvn b2/build.log > $BASE/logs/$SUITE/$ARCH/${SRCPACKAGE}_${EVERSION}.build2.log.gz
			chmod 644 $BASE/logs/$SUITE/$ARCH/${SRCPACKAGE}_${EVERSION}.build2.log.gz
		elif [ $FTBFS -eq 0 ] ; then
			echo "Warning: No second build log, what happened?" | tee -a $RBUILDLOG
		fi
		echo "Compressing the 1st log..."
		gzip -9cvn b1/build.log > $BASE/logs/$SUITE/$ARCH/${SRCPACKAGE}_${EVERSION}.build1.log.gz
		chmod 644 $BASE/logs/$SUITE/$ARCH/${SRCPACKAGE}_${EVERSION}.build1.log.gz
	else
		echo "Error: No first build log, not even looking for the second" | tee -a $RBUILDLOG
	fi
}

handle_404() {
	echo "Warning: Download of ${SRCPACKAGE} sources from ${SUITE} failed." | tee -a ${RBUILDLOG}
	ls -l ${SRCPACKAGE}* | tee -a ${RBUILDLOG}
	echo "Warning: Maybe there was a network problem, or ${SRCPACKAGE} is not a source package in ${SUITE}, or it was removed or renamed. Please investigate." | tee -a ${RBUILDLOG}
	DURATION=''
	EVERSION="None"
	update_rbuildlog
	update_db_and_html "404"
	if [ $SAVE_ARTIFACTS -eq 1 ] ; then SAVE_ARTIFACTS=0 ; fi
	if [ ! -z "$NOTIFY" ] ; then NOTIFY="failure" ; fi
	exit 0 # RBUILDLOG and SAVE_ARTIFACTS and NOTIFY are used in cleanup_all called at exit
}

handle_depwait() {
	echo "Downloading the build dependencies failed" | tee -a "$RBUILDLOG"
	echo "Maybe there was a network problem, or the build dependencies are currently uninstallable; consider filing a bug in the last case." | tee -a "$RBUILDLOG"
	echo "Network problems are automatically rescheduled after some hours." | tee -a "$RBUILDLOG"
	calculate_build_duration
	update_db_and_html "depwait"
	if [ $SAVE_ARTIFACTS -eq 1 ] ; then SAVE_ARTIFACTS=0 ; fi
	if [ -n "$NOTIFY" ] ; then NOTIFY="depwait" ; fi
}

handle_not_for_us() {
	# a list of valid architecture for this package should be passed to this function
	echo "Package ${SRCPACKAGE} (${VERSION}) shall only be build on \"$(echo "$@" | xargs echo )\" and thus was skipped." | tee -a ${RBUILDLOG}
	DURATION=''
	update_rbuildlog
	update_db_and_html "not for us"
	if [ $SAVE_ARTIFACTS -eq 1 ] ; then SAVE_ARTIFACTS=0 ; fi
	if [ ! -z "$NOTIFY" ] ; then NOTIFY="failure" ; fi
	exit 0 # RBUILDLOG and SAVE_ARTIFACTS and NOTIFY are used in cleanup_all called at exit
}

handle_ftbfs() {
	local BUILD
	echo "${SRCPACKAGE} failed to build from source."
	for BUILD in "1" "2"; do
		if zgrep -F "E: pbuilder-satisfydepends failed." "$BASE/logs/$SUITE/$ARCH/${SRCPACKAGE}_${EVERSION}.build${BUILD}.log.gz" ; then
			handle_depwait
			return
		fi
	done
	calculate_build_duration
	update_db_and_html "FTBFS"
	if [ $SAVE_ARTIFACTS -eq 1 ] ; then SAVE_ARTIFACTS=0 ; fi
	if [ ! -z "$NOTIFY" ] ; then NOTIFY="failure" ; fi
}

handle_ftbr() {
	# a ftbr explaination message could be passed
	local FTBRmessage="$@"
	echo | tee -a ${RBUILDLOG}
	echo "$(date) - ${SRCPACKAGE} failed to build reproducibly in ${SUITE} on ${ARCH}." | tee -a ${RBUILDLOG}
	cp b1/${BUILDINFO} $BASE/buildinfo/${SUITE}/${ARCH}/ > /dev/null 2>&1 || true  # will fail if there is no .buildinfo
	if [ ! -z "$FTRmessage" ] ; then
		echo "$(date) - ${FTBRmessage}." | tee -a ${RBUILDLOG}
	fi
	if [ -f ./${DBDREPORT} ] ; then
		mv ./${DBDREPORT} $BASE/dbd/${SUITE}/${ARCH}/
	else
		echo "$(date) - $DIFFOSCOPE produced no output (which is strange)." | tee -a $RBUILDLOG
	fi
	if [ -f ./$DBDTXT ] ; then
		mv ./$DBDTXT $BASE/dbdtxt/$SUITE/$ARCH/
		gzip -9n $BASE/dbdtxt/$SUITE/$ARCH/$DBDTXT
	fi
	calculate_build_duration
	update_db_and_html "unreproducible"
}

handle_reproducible() {
	if [ ! -f ./${DBDREPORT} ] && [ -f b1/${BUILDINFO} ] ; then
		cp b1/${BUILDINFO} $BASE/buildinfo/${SUITE}/${ARCH}/ > /dev/null 2>&1
		figlet ${SRCPACKAGE}
		echo | tee -a ${RBUILDLOG}
		echo "$DIFFOSCOPE found no differences in the changes files, and a .buildinfo file also exists." | tee -a ${RBUILDLOG}
		echo "${SRCPACKAGE} from $SUITE built successfully and reproducibly on ${ARCH}." | tee -a ${RBUILDLOG}
		calculate_build_duration
		update_db_and_html "reproducible"
	elif [ -f ./$DBDREPORT ] ; then
		echo "Debbindiff says the build is reproducible, but there is a diffoscope file. Please investigate" | tee -a $RBUILDLOG
		handle_ftbr
	elif [ ! -f b1/$BUILDINFO ] ; then
		echo "Debbindiff says the build is reproducible, but there is no .buildinfo file. Please investigate" | tee -a $RBUILDLOG
		handle_ftbr
	fi
}

dbd_timeout() {
	local msg="$DIFFOSCOPE was killed after running into timeout after $1"
	if [ ! -s ./${DBDREPORT} ] ; then
		echo "$(date) - $DIFFOSCOPE produced no output and was killed after running into timeout after ${1}..." >> ${DBDREPORT}
	else
		msg="$msg, but there is still $REPRODUCIBLE_URL/dbd/$SUITE/$ARCH/$DDBREPORT"
	fi
	SAVE_ARTIFACTS=1
	NOTIFY="diffoscope"
	handle_ftbr "$msg"
}

call_diffoscope_on_changes_files() {
	local TMPLOG=(mktemp --tmpdir=$TMPDIR)
	echo | tee -a ${RBUILDLOG}
	local TIMEOUT="30m"
	DBDSUITE=$SUITE
	if [ "$SUITE" = "experimental" ] ; then
		# there is no extra debbindiff-schroot for experimental because we specical case ghc enough already ;)
		DBDSUITE="unstable"
	fi
	# TEMP is recognized by python's tempfile module to create temp stuff inside
	local TEMP=$(mktemp --tmpdir=$TMPDIR -d dbd-tmp-XXXXXXX)
	DIFFOSCOPE="$(schroot --directory /tmp -c source:jenkins-reproducible-${DBDSUITE}-debbindiff debbindiff -- --version 2>&1)"
	echo "$(date) - $DIFFOSCOPE will be used to compare the two builds:" | tee -a ${RBUILDLOG}
	set +e
	set -x
	( timeout $TIMEOUT schroot \
		--directory $TMPDIR \
		-c source:jenkins-reproducible-${DBDSUITE}-debbindiff \
		-- sh -c "export TMPDIR=$TEMP ; debbindiff \
			--html $TMPDIR/${DBDREPORT} \
			--text $TMPDIR/$DBDTXT \
			$TMPDIR/b1/${SRCPACKAGE}_${EVERSION}_${ARCH}.changes \
			$TMPDIR/b2/${SRCPACKAGE}_${EVERSION}_${ARCH}.changes" \
	2>&1 ) >> $TMPLOG
	RESULT=$?
	if ! "$DEBUG" ; then set +x ; fi
	set -e
	cat $TMPLOG | tee -a $RBUILDLOG  # print dbd output
	rm $TMPLOG
	echo | tee -a ${RBUILDLOG}
	case $RESULT in
		0)
			handle_reproducible
			;;
		1)
			handle_ftbr "$DIFFOSCOPE found issues, please investigate $REPRODUCIBLE_URL/dbd/${SUITE}/${ARCH}/${DBDREPORT}"
			;;
		2)
			SAVE_ARTIFACTS=1
			NOTIFY="diffoscope"
			handle_ftbr "$DIFFOSCOPE had trouble comparing the two builds. Please investigate $REPRODUCIBLE_URL/rbuild/${SUITE}/${ARCH}/${SRCPACKAGE}_${EVERSION}.rbuild.log"
			;;
		124)
			dbd_timeout $TIMEOUT
			;;
		*)
			handle_ftbr "Something weird happened when running $DIFFOSCOPE (which exited with $RESULT) and I don't know how to handle it"
			irc_message "Something weird happened when running $DIFFOSCOPE (which exited with $RESULT) and I don't know how to handle it. Check $BUILDLOG and $REPRODUCIBLE_URL/$SUITE/$ARCH/$SRCPACKAGE and investigate manually"
			;;
	esac
	print_out_duration
}

choose_package () {
	local RESULT=$(sqlite3 -init $INIT ${PACKAGES_DB} "
		SELECT s.suite, s.id, s.name, sch.date_scheduled, sch.save_artifacts, sch.notify, s.notify_maintainer, sch.builder
		FROM schedule AS sch JOIN sources AS s ON sch.package_id=s.id
		WHERE sch.date_build_started = ''
		AND s.architecture='$ARCH'
		ORDER BY date_scheduled LIMIT 1")
	SUITE=$(echo $RESULT|cut -d "|" -f1)
	SRCPKGID=$(echo $RESULT|cut -d "|" -f2)
	SRCPACKAGE=$(echo $RESULT|cut -d "|" -f3)
	# force debug mode for certain packages
	case $SRCPACKAGE in
			ruby-patron|xxxxxxx)
			export DEBUG=true
			set -x
			irc_message "$BUILD_URL/console available to debug $SRCPACKAGE build in $SUITE/$ARCH"
			;;
		*)	;;
	esac
	SCHEDULED_DATE=$(echo $RESULT|cut -d "|" -f4)
	SAVE_ARTIFACTS=$(echo $RESULT|cut -d "|" -f5)
	NOTIFY=$(echo $RESULT|cut -d "|" -f6)
	NOTIFY_MAINTAINER=$(echo $RESULT|cut -d "|" -f7)
	local DEBUG_URL=$(echo $RESULT|cut -d "|" -f8)
	if [ "$DEBUG_URL" = "TBD" ] ; then
		irc_message "The build of $SRCPACKAGE/$SUITE/$ARCH is starting at ${BUILD_URL}consoleFull"
	fi
	if [ -z "$RESULT" ] ; then
		echo "No packages scheduled, sleeping 30m."
		sleep 30m
		exit 0
	fi
}

init() {
	delay_start
	if [ $SAVE_ARTIFACTS -eq 1 ] ; then
		local ANNOUNCE="Artifacts will be preserved."
	fi
	create_results_dirs
	echo "============================================================================="
	echo "Trying to reproducibly build ${SRCPACKAGE} in ${SUITE} on ${ARCH} now. $ANNOUNCE"
	echo "============================================================================="
	# mark build attempt
	if [ -z "$(sqlite3 -init $INIT ${PACKAGES_DB} "SELECT date_build_started FROM schedule WHERE package_id = '$SRCPKGID'")" ] ; then
		sqlite3 -init $INIT ${PACKAGES_DB} "UPDATE schedule SET date_build_started='$DATE', builder='$BUILDER' WHERE package_id = '$SRCPKGID'"
	else
		BAD_LOCKFILE=true
		handle_race_condition db
	fi
	if [ ! -f "$LOCKFILE" ] ; then
		echo $$ > "$LOCKFILE"
	else
		BAD_LOCKFILE=true
		handle_race_condition init
	fi
	echo "Starting to build ${SRCPACKAGE}/${SUITE}/${ARCH} on $DATE" | tee ${RBUILDLOG}
	echo "The jenkins build log is/was available at ${BUILD_URL}console" | tee -a ${RBUILDLOG}
}

get_source_package() {
	local RESULT
	schroot --directory $PWD -c source:jenkins-reproducible-$SUITE apt-get -- --download-only --only-source source ${SRCPACKAGE} 2>&1 | tee -a ${RBUILDLOG}
	RESULT=$?
	if [ $RESULT != 0 ] || [ "$(ls ${SRCPACKAGE}_*.dsc 2> /dev/null)" = "" ] ; then
		# sometimes apt-get cannot download a package for whatever reason.
		# if so, wait some time and try again. only if that fails, give up.
		echo "Download of ${SRCPACKAGE} sources from ${SUITE} failed." | tee -a ${RBUILDLOG}
		ls -l ${SRCPACKAGE}* | tee -a ${RBUILDLOG}
		echo "Sleeping 5m before re-trying..." | tee -a ${RBUILDLOG}
		sleep 5m
		schroot --directory $PWD -c source:jenkins-reproducible-$SUITE apt-get -- --download-only --only-source source ${SRCPACKAGE} 2>&1 | tee -a ${RBUILDLOG}
		RESULT=$?
	fi
	if [ $RESULT != 0 ] || [ "$(ls ${SRCPACKAGE}_*.dsc 2> /dev/null)" = "" ] ; then
		if [ "$MODE" = "legacy" ] || [ "$MODE" = "ng" ] ; then
			handle_404
		else
			exit 404	# FIXME: this is unhandled atm
		fi
	fi
	VERSION="$(grep '^Version: ' ${SRCPACKAGE}_*.dsc| head -1 | egrep -v '(GnuPG v|GnuPG/MacGPG2)' | cut -d ' ' -f2-)"
	EVERSION="$(echo $VERSION | cut -d ':' -f2)"  # EPOCH_FREE_VERSION was too long
	DBDREPORT="${SRCPACKAGE}_${EVERSION}.debbindiff.html"
	DBDTXT="${SRCPACKAGE}_${EVERSION}.debbindiff.txt"
	BUILDINFO="${SRCPACKAGE}_${EVERSION}_${ARCH}.buildinfo"
}

check_suitability() {
	# check whether the package is not for us...
	local SUITABLE=false
	local ARCHITECTURES=$(grep "^Architecture: " ${SRCPACKAGE}_*.dsc| cut -d " " -f2- | sed -s "s# #\n#g" | sort -u)
	for arch in ${ARCHITECTURES} ; do
		if [ "$arch" = "any" ] || [ "$arch" = "$ARCH" ] || [ "$arch" = "linux-any" ] || [ "$arch" = "linux-$ARCH" ] || [ "$arch" = "any-ARCH" ] || [ "$arch" = "all" ] ; then
			SUITABLE=true
			break
		fi
		# special case arm…
		if [ "$ARCH" = "armhf" ] && [ "$arch" = "any-arm" ] ; then
			SUITABLE=true
			break
		fi

	done
	if ! $SUITABLE ; then handle_not_for_us $ARCHITECTURES ; fi
}

first_build() {
	set -x
	local TMPCFG=$(mktemp -t pbuilderrc_XXXX --tmpdir=$TMPDIR)
	cat > "$TMPCFG" << EOF
BUILDUSERID=1111
BUILDUSERNAME=pbuilder1
export DEB_BUILD_OPTIONS="parallel=$NUM_CPU"
export TZ="/usr/share/zoneinfo/Etc/GMT+12"
EOF
	# remember to change the sudoers setting if you change the following command
	( sudo timeout -k 12.1h 12h /usr/bin/ionice -c 3 /usr/bin/nice \
	  /usr/sbin/pbuilder --build \
		--configfile $TMPCFG \
		--debbuildopts "-b" \
		--basetgz /var/cache/pbuilder/$SUITE-reproducible-base.tgz \
		--buildresult b1 \
		--logfile b1/build.log \
		${SRCPACKAGE}_${EVERSION}.dsc
	) 2>&1 | tee -a $RBUILDLOG
	if ! "$DEBUG" ; then set +x ; fi
	rm $TMPCFG
}

second_build() {
	set -x
	local TMPCFG=$(mktemp -t pbuilderrc_XXXX --tmpdir=$TMPDIR)
	cat > "$TMPCFG" << EOF
BUILDUSERID=2222
BUILDUSERNAME=pbuilder2
export DEB_BUILD_OPTIONS="parallel=$(echo $NUM_CPU-1|bc)"
export TZ="/usr/share/zoneinfo/Etc/GMT-14"
export LANG="fr_CH.UTF-8"
export LC_ALL="fr_CH.UTF-8"
umask 0002
EOF
	# remember to change the sudoers setting if you change the following command
	sudo timeout -k 12.1h 12h /usr/bin/ionice -c 3 /usr/bin/nice \
		/usr/bin/linux64 --uname-2.6 \
		/usr/bin/unshare --uts -- \
		/usr/sbin/pbuilder --build \
			--configfile $TMPCFG \
			--hookdir /etc/pbuilder/rebuild-hooks \
			--debbuildopts "-b" \
			--basetgz /var/cache/pbuilder/$SUITE-reproducible-base.tgz \
			--buildresult b2 \
			--logfile b2/build.log \
			${SRCPACKAGE}_${EVERSION}.dsc || true  # exit with 1 when ftbfs
	if ! "$DEBUG" ; then set +x ; fi
}

check_buildinfo() {
	local TMPFILE1=$(mktemp --tmpdir=$TMPDIR)
	local TMPFILE2=$(mktemp --tmpdir=$TMPDIR)
	grep-dctrl -s Build-Environment -n ${SRCPACKAGE} ./b1/$BUILDINFO > $TMPFILE1
	grep-dctrl -s Build-Environment -n ${SRCPACKAGE} ./b2/$BUILDINFO > $TMPFILE2
	set +e
	diff $TMPFILE1 $TMPFILE2
	RESULT=$?
	set -e
	if [ $RESULT -eq 1 ] ; then
		printf "$(date) - $BUILDINFO in ${SUITE} on ${ARCH} varies, probably due to mirror update. Doing the first build again, please check ${BUILD_URL}console for now..." >> /var/log/jenkins/reproducible-hit-mirror-update.log
		echo
		echo "============================================================================="
		echo ".buildinfo's Build-Environment varies, probably due to mirror update."
		echo "Doing the first build again."
		echo "Building ${SRCPACKAGE}/${VERSION} in ${SUITE} on ${ARCH} now."
		echo "============================================================================="
		echo
		first_build
		grep-dctrl -s Build-Environment -n ${SRCPACKAGE} ./b1/$BUILDINFO > $TMPFILE1
		set +e
		diff $TMPFILE1 $TMPFILE2
		RESULT=$?
		set -e
		if [ $RESULT -eq 1 ] ; then
			irc_message "$REPRODUCIBLE_URL/$SUITE/$ARCH/$SRCPACKAGE had different packages installed in the 1st+2nd build, and then also in the 2nd+3rd builds. Please investigate, this should not happen."
		fi
	fi
	rm $TMPFILE1 $TMPFILE2
}

build_rebuild() {
	FTBFS=1
	mkdir b1 b2
	if [ "$MODE" = "legacy" ] ; then
		first_build
	else
		ssh -p $PORT1 $NODE1 /srv/jenkins/bin/reproducible_build.sh 1 ${SRCPACKAGE} ${SUITE} ${TMPDIR}
		rsync -e "ssh -p $PORT1" -r $NODE1:$PWD/b1 .
		ssh -p $PORT1 $NODE1 "rm -r $PWD/b1"
	fi
	if [ -f b1/${SRCPACKAGE}_${EVERSION}_${ARCH}.changes ] ; then
		# the first build did not FTBFS, try rebuild it.
		check_for_race_conditions
		echo "============================================================================="
		echo "Re-building ${SRCPACKAGE}/${VERSION} in ${SUITE} on ${ARCH} now."
		echo "============================================================================="
		if [ "$MODE" = "legacy" ] ; then
			second_build
		else
			ssh -p $PORT2 $NODE2 /srv/jenkins/bin/reproducible_build.sh 2 ${SRCPACKAGE} ${SUITE} ${TMPDIR}
			rsync -e "ssh -p $PORT2" -r $NODE2:$PWD/b2 .
			ssh -p $PORT2 $NODE2 "rm -r $PWD/b2"
		fi
		if [ -f b2/${SRCPACKAGE}_${EVERSION}_${ARCH}.changes ] ; then
			# both builds were fine, i.e., they did not FTBFS.
			FTBFS=0
			cat b1/${SRCPACKAGE}_${EVERSION}_${ARCH}.changes | tee -a ${RBUILDLOG}
		else
			echo "The second build failed, even though the first build was successful." | tee -a ${RBUILDLOG}
		fi
		rm $TMPCFG
	fi
}

#
# below is what controls the world
#

TMPDIR=$(mktemp --tmpdir=/srv/reproducible-results -d)  # where everything actually happens
trap cleanup_all INT TERM EXIT
cd $TMPDIR

DATE=$(date +'%Y-%m-%d %H:%M')
START=$(date +'%s')
RBUILDLOG=$(mktemp --tmpdir=$TMPDIR)
BAD_LOCKFILE=false
BUILDER="${JOB_NAME#reproducible_builder_}/${BUILD_ID}"
ARCH="$(dpkg --print-architecture)"

# determine mode
if [ "$1" = "" ] ; then
	MODE="legacy"
elif [ "$1" = "1" ] || [ "$1" = "2" ] ; then
	MODE="$1"
	SRCPACKAGE="$2"
	SUITE="$3"
	SAVE_ARTIFACTS=0
	TMPDIR="$4" ; mkdir $TMPDIR ; cd $$TMPDIR
	get_source_package
	mkdir b$MODE
	if [ "$MODE" = "1" ] ; then
		first_build
	else
		second_build
	fi
	exit 0
elif [ "$2" != "" ] ; then
	MODE="ng"
	NODE1="$(echo $1 | cut -d ':' -f1).debian.net"
	NODE2="$(echo $2 | cut -d ':' -f1).debian.net"
	PORT1="$(echo $1 | cut -d ':' -f2)"
	PORT2="$(echo $2 | cut -d ':' -f2)"
	# if no port is given, assume 22
	if [ "$NODE1" = "${PORT1}.debian.net" ] ; then PORT1 = 22 ; fi
	if [ "$NODE2" = "${PORT2}.debian.net" ] ; then PORT2 = 22 ; fi
	# overwrite ARCH for remote builds
	for i in $ARCHS ; do
		# try to match ARCH in nodenames
		if [[ "$NODE1" =~ .*-$i.* ]] ; then
			ARCH=$i
		fi
	done
	if [ -z "$ARCH" ] ; then
		echo "Error: could not detect architecture, exiting."
		exit 1
	fi
fi

choose_package  # defines SUITE, PKGID, SRCPACKAGE, SCHEDULED_DATE, SAVE_ARTIFACTS, NOTIFY

# used to catch race conditions when the same package is being built by two parallel jobs
LOCKFILE="/tmp/reproducible-lockfile-${SUITE}-${ARCH}-${SRCPACKAGE}"

init
get_source_package

cat ${SRCPACKAGE}_${EVERSION}.dsc | tee -a ${RBUILDLOG}

check_for_race_conditions
check_suitability
check_for_race_conditions
build_rebuild  # defines FTBFS redefines RBUILDLOG
if [ $FTBFS -eq 0 ] ; then
	check_buildinfo
fi
cleanup_pkg_files
diff_copy_buildlogs
update_rbuildlog
if [ $FTBFS -eq 1 ] ; then
	handle_ftbfs
elif [ $FTBFS -eq 0 ] ; then
	call_diffoscope_on_changes_files  # defines DIFFOSCOPE, update_db_and_html defines STATUS
fi

check_for_race_conditions
cd ..
cleanup_all
trap - INT TERM EXIT

