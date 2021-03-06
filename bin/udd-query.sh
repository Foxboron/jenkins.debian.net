#!/bin/bash

# Copyright 2012-2014 Holger Levsen <holger@layer-acht.org>
# multiarch_versionskew UDD query by Stuart Prescott <stuart@debian.org>
# orphaned_without_o_bug by Johannes Schauer <j.schauer@email.de>
# released under the GPLv=2

DEBUG=false
. /srv/jenkins/bin/common-functions.sh
common_init "$@"

udd_query() {
	#
	# Actually query UDD and save result in $UDD file
	#
	echo "$(date -u) - querying UDD using ${SQL_QUERY}"
	echo
	PGPASSWORD=udd-mirror \
		psql -U udd-mirror \
		-h udd-mirror.debian.net -p 5432 \
		-t \
		udd -c"${SQL_QUERY}" > $UDD
}

multiarch_versionskew() {
	if [ -z "$1" ] ; then
		echo "Warning: no distro supplied, assuming sid."
		DISTR=sid
	else
		DISTRO=$1
	fi
	#
	# SQL query for detecting multi-arch version skew
	#
	SQL_QUERY="SELECT DISTINCT source FROM
		(SELECT DISTINCT source, package, version
			FROM packages WHERE
				release='$DISTRO' AND
				multi_arch='same' AND
					architecture IN ('amd64', 'arm64', 'armel', 'armhf', 'i386',
					'kfreebsd-amd64', 'kfreebsd-i386', 'mips', 'mipsel',
					'mips64el', 'powerpc', 'ppc64el', 's390x')
				ORDER BY source) AS all_versions
				GROUP BY source, package
				HAVING count(*) > 1
			ORDER BY source ;"

	udd_query
	local PKGS=($(< "$UDD"))
	if [ ${#PKGS[@]} -gt 0 ] ; then
		if [ "$DISTRO" != "sid" ] ; then
			echo "Warning: multi-arch version skew in $DISTRO detected."
		else
			# multiarch version skew in sid is inevitable
			echo "Multi-arch version skew in $DISTRO detected."
		fi
		echo
		printf  "         Package          |           Tracker\n"
		printf -- "--------------------------------------------------------------------------\n"
		for pkg in "${PKGS[@]}" ; do
			printf "%25s | %s\n" "$pkg" "https://tracker.debian.org/$pkg"
		# TODO: show versions (per arch) too
		done
	fi
}

orphaned_without_o_bug() {
	WNPPRM=$(mktemp)
	SORTED_UDD=$(mktemp)

	SQL_QUERY="
		SELECT DISTINCT s.source
		FROM sources AS s
		JOIN (
				SELECT source, max(version) AS version
				FROM sources
				WHERE release IN ('sid','experimental')
				GROUP BY source
			) AS foo ON foo.source=s.source AND foo.version=s.version
		WHERE s.maintainer_email = 'packages@qa.debian.org';"

	udd_query
	cat $UDD | tr -d ' ' | sort | uniq > "$SORTED_UDD"
	curl --silent https://qa.debian.org/data/bts/wnpp_rm \
		| cut -d ' ' -f 1 | tr -d ':' | sort | uniq > "$WNPPRM"
	RES=$(comm -23 "$SORTED_UDD" "$WNPPRM")

	if [ -n "$RES" ] ; then
		echo "Warning: The following packages are maintained by packages@qa.debian.org"
		echo "but are missing a wnpp bug according to https://qa.debian.org/data/bts/wnpp_rm"
		echo
		for i in $RES ; do
			echo "https://tracker.debian.org/$i"
		done
	fi

	rm -f "$WNPPRM" "$SORTED_UDD"
}

#
# main
#
UDD=$(mktemp)
function rmtmpfile { rm -f "$UDD"; }
trap rmtmpfile exit
case $1 in
	orphaned_without_o_bug)
			orphaned_without_o_bug
			;;
	multiarch_versionskew)
			multiarch_versionskew $2
			;;
	*)
			echo "unknown query requested, exiting... please provide patches :)"
			;;
esac
echo
