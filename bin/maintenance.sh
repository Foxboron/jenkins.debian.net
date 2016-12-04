#!/bin/bash

# Copyright 2012-2015 Holger Levsen <holger@layer-acht.org>
# released under the GPLv=2

DEBUG=false
. /srv/jenkins/bin/common-functions.sh
common_init "$@"

check_for_mounted_chroots() {
	CHROOT_PATTERN="/chroots/${1}-*"
	OUTPUT=$(mktemp)
	ls $CHROOT_PATTERN 2>/dev/null > $OUTPUT || true
	if [ -s $OUTPUT ] ; then
		figlet "Warning:"
		echo
		echo "Probably manual cleanup needed:"
		echo
		echo "$ ls -la $CHROOT_PATTERN"
		# List the processes using the partition
		echo
		fuser -mv $CHROOT_PATTERN
		cat $OUTPUT
		rm $OUTPUT
		exit 1
	fi
	rm $OUTPUT
}

chroot_checks() {
	check_for_mounted_chroots $1
	report_disk_usage /chroots
	report_disk_usage /schroots
	echo "WARNING: should remove directories in /(s)chroots which are older than a month."
}

compress_old_jenkins_logs() {
	local COMPRESSED
	# compress logs to save space
	COMPRESSED=$(find /var/lib/jenkins/jobs/*/builds/ -maxdepth 2 -mindepth 2 -mtime +1 -name log -exec gzip -9 -v {} \;)
	if [ ! -z "$COMPRESSED" ] ; then
		echo "Logs have been compressed:"
		echo
		echo "$COMPRESSED"
		echo
	fi
}

remove_old_rebootstrap_logs() {
	local OLDSTUFF
	# delete old html logs to save space
	OLDSTUFF=$(find /var/lib/jenkins/jobs/rebootstrap_* -maxdepth 3 -mtime +7 -name log_content.html  -exec rm -v {} \;)
	if [ ! -z "$OLDSTUFF" ] ; then
		echo "Old html logs have been deleted:"
		echo
		echo "$OLDSTUFF"
		echo
	fi
}

report_old_directories() {
	# find and warn about old temp directories
	if [ -z "$3" ] ; then
		OLDSTUFF=$(find $1/* -maxdepth 0 -type d -mtime +$2 -exec ls -lad {} \;)
	elif [ -z "$4" ] ; then
		# if $3 is given, ignore it
		OLDSTUFF=$(find $1/* -maxdepth 0 -type d -mtime +$2 ! -path "$3*" -exec ls -lad {} \;)
	else
		# if $3 + $4 are given, ignore them
		OLDSTUFF=$(find $1/* -maxdepth 0 -type d -mtime +$2 ! -path "$3*" ! -path "$4*" -exec ls -lad {} \;)
	fi
	if [ ! -z "$OLDSTUFF" ] ; then
		echo "Warning: old temp directories found in $1"
		echo
		echo "$OLDSTUFF"
		echo "Please cleanup manually."
		echo
	fi
}

report_disk_usage() {
	if [ -z "$WATCHED_JOBS" ] ; then
		echo "File system usage for all ${1} jobs:"
	else
		echo "File system usage for all ${1} jobs (including those currently running):"
	fi
	du -schx /var/lib/jenkins/jobs/${1}* |grep total |sed -s "s#total#${1} jobs#"
	echo
	if [ ! -z "$WATCHED_JOBS" ] ; then
		TMPFILE=$(mktemp)
		for JOB in $(cat $WATCHED_JOBS) ; do
			du -shx --exclude='*/archive/*' $JOB | grep G >> $TMPFILE || true
		done
		if [ -s $TMPFILE ] ; then
			echo
			echo "${1} jobs with filesystem usage over 1G, excluding their archives and those currently running:"
			cat $TMPFILE
			echo
		fi
		rm $TMPFILE
	fi
}

report_filetype_usage() {
	OUTPUT=$(mktemp)
	for JOB in $(cat $WATCHED_JOBS) ; do
		if [ "$2" != "bak" ] && [ "$2" != "png" ] ; then
			find /var/lib/jenkins/jobs/$JOB -type f -name "*.${2}" ! -path "*/archive/*" 2>/dev/null|xargs -r du -sch |grep total |sed -s "s#total#$JOB .$2 files#" >> $OUTPUT
		else
			# find archived .bak + .png files too
			find /var/lib/jenkins/jobs/$JOB -type f -name "*.${2}" 2>/dev/null|xargs -r du -sch |grep total |sed -s "s#total#$JOB .$2 files#" >> $OUTPUT
		fi
	done
	if [ -s $OUTPUT ] ; then
		echo "File system use in $1 for $2 files:"
		cat $OUTPUT
		if [ "$3" = "warn" ] ; then
			echo "Warning: there are $2 files and there should not be any."
		fi
		echo
	fi
	rm $OUTPUT
}

report_squid_usage() {
	REPORT=/var/www/calamaris/calamaris.txt
	if [ -z $1 ] ; then
		cat $REPORT
	else
		head -31 $REPORT
	fi
}

wait4idle() {
	echo "Waiting until no $1.sh process runs.... $(date)"
	while [ $(ps fax | grep -c $1.sh) -gt 1 ] ; do
		sleep 30
	done
	echo "Done waiting: $(date)"
}

general_maintenance() {
	uptime

	echo
	# ignore unreadable /media fuse mountpoints from guestmount
	df -h 2>/dev/null || true

	echo
	for DIR in /var/cache/apt/archives/ /var/spool/squid3/ /var/cache/pbuilder/build/ /var/lib/jenkins/jobs/ /chroots /schroots ; do
		sudo du -shx $DIR 2>/dev/null
	done
	JOB_PREFIXES=$(ls -1 /var/lib/jenkins/jobs/|cut -d "_" -f1|sort -f -u)
	for PREFIX in $JOB_PREFIXES ; do
		report_disk_usage $PREFIX
	done

	echo
	vnstat

	(df 2>/dev/null || true ) | grep tmpfs > /dev/null || ( echo ; echo "Warning: no tmpfs mounts in use. Please investigate the host system." ; exit 1 )
}

#
# if $1 is empty, we do general maintenance, else for some subgroup of all jobs
#
if [ -z $1 ] ; then
	general_maintenance
	compress_old_jenkins_logs
	report_squid_usage brief
else
	case $1 in
		chroot-installation*)		wait4idle $1
						report_disk_usage $1
						chroot_checks $1
						;;
		g-i-installation)		ACTIVE_JOBS=$(mktemp)
						WATCHED_JOBS=$(mktemp)
						RUNNING=$(mktemp)
						ps fax > $RUNNING
						cd /var/lib/jenkins/jobs
						for GIJ in g-i-installation_* ; do
							if grep -q "$GIJ/workspace" $RUNNING ; then
								echo "$GIJ" >> $ACTIVE_JOBS
								echo "Ignoring $GIJ job as it's currently running."
							else
								echo "$GIJ" >> $WATCHED_JOBS
							fi
						done
						echo
						report_disk_usage $1
						report_filetype_usage $1 png warn
						report_filetype_usage $1 bak warn
						report_filetype_usage $1 raw warn
						report_filetype_usage $1 iso warn
						echo "WARNING: there is no check / handling on stale lvm volumes"
						rm $ACTIVE_JOBS $WATCHED_JOBS $RUNNING
						;;
		d-i)				report_old_directories /srv/d-i 7 /srv/d-i/workspace /srv/d-i/isos
						;;
		squid)				report_squid_usage
						;;
		rebootstrap)			remove_old_rebootstrap_logs
						;;
		*)				;;
	esac
fi

echo
echo "No (big) problems found, all seems good."
figlet "Ok."
