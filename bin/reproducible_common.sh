#!/bin/bash

# Copyright 2014-2015 Holger Levsen <holger@layer-acht.org>
#              © 2015 Mattia Rizzolo <mattia@mapreri.org>
# released under the GPLv=2
#
# included by all reproducible_*.sh scripts
#
# define db
PACKAGES_DB=/var/lib/jenkins/reproducible.db
INIT=/var/lib/jenkins/reproducible.init
MAINNODE="jenkins" # host which contains reproducible.db
if [ -f $PACKAGES_DB ] && [ -f $INIT ] ; then
	if [ -f ${PACKAGES_DB}.lock ] ; then
		for i in $(seq 0 200) ; do
			sleep 15
			echo "sleeping 15s, $PACKAGES_DB is locked."
			if [ ! -f ${PACKAGES_DB}.lock ] ; then
				break
			fi
		done
		if [ -f ${PACKAGES_DB}.lock ] ; then
			echo "${PACKAGES_DB}.lock still exist, exiting."
			exit 1
		fi
	fi
elif [ ! -f ${PACKAGES_DB} ] && [ "$HOSTNAME" = "$MAINNODE" ] ; then
	echo "Warning: $PACKAGES_DB doesn't exist, creating it now."
		/srv/jenkins/bin/reproducible_db_maintenance.py
	# 60 seconds timeout when trying to get a lock
	cat > $INIT <<-EOF
.timeout 60000
EOF
fi

# common variables
REPRODUCIBLE_URL=https://reproducible.debian.net
REPRODUCIBLE_DOT_ORG_URL=https://reproducible-builds.org
# shop trailing slash
JENKINS_URL=${JENKINS_URL:0:-1}
DBDSUITE="unstable"

# suites being tested
SUITES="testing unstable experimental"
# architectures being tested
ARCHS="armhf amd64"

# define build nodes in use
BUILD_NODES="profitbricks-build1-amd64.debian.net profitbricks-build2-amd64.debian.net profitbricks-build5-amd64.debian.net profitbricks-build6-amd64.debian.net wbq0-armhf-rb.debian.net cbxi4pro0-armhf-rb.debian.net bpi0-armhf-rb.debian.net hb0-armhf-rb.debian.net" # these also needs to be defined in bin/jenkins_master_wrapper.sh
BUILD_ENV_VARS="ARCH NUM_CPU CPU_MODEL DATETIME KERNEL1 KERNEL2" # these also needs to be defined in bin/reproducible_info.sh

# existing usertags
USERTAGS="toolchain infrastructure timestamps fileordering buildpath username hostname uname randomness buildinfo cpu signatures environment umask ftbfs locale"

# number of cores to be used
NUM_CPU=$(grep -c '^processor' /proc/cpuinfo)

# we only need them for html creation but we cannot declare them in a function
declare -A SPOKENTARGET

BASE="/var/lib/jenkins/userContent/reproducible"
mkdir -p "$BASE"

# to hold reproducible temporary files/directories without polluting /tmp
TEMPDIR="/tmp/reproducible"
mkdir -p "$TEMPDIR"

# create subdirs for suites
for i in $SUITES ; do
	mkdir -p "$BASE/$i"
done

# table names and image names
TABLE[0]=stats_pkg_state
TABLE[1]=stats_builds_per_day
TABLE[2]=stats_builds_age
TABLE[3]=stats_bugs
TABLE[4]=stats_notes
TABLE[5]=stats_issues
TABLE[6]=stats_meta_pkg_state
TABLE[7]=stats_bugs_state

# known package sets
META_PKGSET[1]="essential"
META_PKGSET[2]="required"
META_PKGSET[3]="build-essential"
META_PKGSET[4]="build-essential-depends"
META_PKGSET[5]="popcon_top1337-installed-sources"
META_PKGSET[6]="key_packages"
META_PKGSET[7]="installed_on_debian.org"
META_PKGSET[8]="had_a_DSA"
META_PKGSET[9]="cii-census"
META_PKGSET[10]="gnome"
META_PKGSET[11]="gnome_build-depends"
META_PKGSET[12]="kde"
META_PKGSET[13]="kde_build-depends"
META_PKGSET[14]="xfce"
META_PKGSET[15]="xfce_build-depends"
META_PKGSET[16]="tails"
META_PKGSET[17]="tails_build-depends"
META_PKGSET[18]="grml"
META_PKGSET[19]="grml_build-depends"
META_PKGSET[20]="maint_pkg-perl-maintainers"
META_PKGSET[21]="maint_pkg-java-maintainers"
META_PKGSET[22]="maint_pkg-haskell-maintainers"
META_PKGSET[23]="maint_pkg-ruby-extras-maintainers"
META_PKGSET[24]="maint_pkg-golang-maintainers"
META_PKGSET[25]="maint_pkg-php-pear"
META_PKGSET[26]="maint_pkg-javascript-devel"
META_PKGSET[27]="maint_debian-boot"
META_PKGSET[28]="maint_debian-ocaml"
META_PKGSET[29]="maint_debian-x"
META_PKGSET[30]="maint_lua"

schedule_packages() {
	LC_USER="$REQUESTER" \
	LOCAL_CALL="true" \
	/srv/jenkins/bin/reproducible_remote_scheduler.py \
		--message "$REASON" \
		--no-notify \
		--suite "$SUITE" \
		--architecture "$ARCH" \
		$@
}

write_page() {
	echo "$1" >> $PAGE
}

set_icon() {
	# icons taken from tango-icon-theme (0.8.90-5)
	# licenced under http://creativecommons.org/licenses/publicdomain/
	STATE_TARGET_NAME="$1"
	case "$1" in
		reproducible)		ICON=weather-clear.png
					;;
		unreproducible|FTBR)	ICON=weather-showers-scattered.png
					;;
		FTBFS)			ICON=weather-storm.png
					;;
		depwait)		ICON=weather-snow.png
					;;
		404)			ICON=weather-severe-alert.png
					;;
		not_for_us|"not for us")	ICON=weather-few-clouds-night.png
					STATE_TARGET_NAME="not_for_us"
					;;
		blacklisted)		ICON=error.png
					;;
		*)			ICON=""
	esac
}

write_icon() {
	# ICON and STATE_TARGET_NAME are set by set_icon()
	write_page "<a href=\"/$SUITE/$ARCH/index_${STATE_TARGET_NAME}.html\" target=\"_parent\"><img src=\"/userContent/static/$ICON\" alt=\"${STATE_TARGET_NAME} icon\" /></a>"
}

write_page_header() {
	rm -f $PAGE
	MAINVIEW="dashboard"
	ALLSTATES="reproducible FTBR FTBFS depwait not_for_us 404 blacklisted"
	ALLVIEWS="issues notes no_notes scheduled last_24h last_48h all_abc notify dd-list pkg_sets suite_stats arch repositories dashboard"
	GLOBALVIEWS="issues scheduled notify repositories dashboard"
	SUITEVIEWS="dd-list suite_stats"
	SPOKENTARGET["issues"]="issues"
	SPOKENTARGET["notes"]="packages with notes"
	SPOKENTARGET["no_notes"]="packages without notes"
	SPOKENTARGET["scheduled"]="currently scheduled"
	SPOKENTARGET["last_24h"]="packages tested in the last 24h"
	SPOKENTARGET["last_48h"]="packages tested in the last 48h"
	SPOKENTARGET["all_abc"]="all tested packages (sorted alphabetically)"
	SPOKENTARGET["notify"]="⚑"
	SPOKENTARGET["dd-list"]="maintainers of unreproducible packages"
	SPOKENTARGET["pkg_sets"]="package sets"
	SPOKENTARGET["suite_stats"]="suite: $SUITE"
	SPOKENTARGET["repositories"]="repositories overview"
	SPOKENTARGET["dashboard"]="dashboard"
	write_page "<!DOCTYPE html><html><head>"
	write_page "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\" />"
	write_page "<link href=\"/userContent/static/style.css\" type=\"text/css\" rel=\"stylesheet\" />"
	write_page "<title>$2</title></head>"
	if [ "$1" != "$MAINVIEW" ] ; then
		write_page "<body><header><h2>$2</h2><nav>"
	else
		write_page "<body onload=\"selectSearch()\"><header><h2>$2</h2><nav>"
		write_page "<ul>These pages are showing the <em>prospects</em> of <li><a href=\"https://wiki.debian.org/ReproducibleBuilds\" target=\"_blank\">reproducible builds of Debian packages</a></li>."
		write_page " The results shown were obtained from <a href=\"$JENKINS_URL/view/reproducible\">several jobs</a> running on"
		write_page " <a href=\"$JENKINS_URL/userContent/about.html#_reproducible_builds_jobs\">jenkins.debian.net</a>."
		write_page " Thanks to <a href=\"https://www.profitbricks.co.uk\">Profitbricks</a> for donating the virtual machines this is running on!</ul>"
	fi
	if [ "$1" = "dd-list" ] || [ "$1" = "dashboard" ] ; then
		write_page "<ul>Join <code>#debian-reproducible</code> on OFTC,"
		write_page "   or <a href="mailto:reproducible-builds@lists.alioth.debian.org">send us an email</a>,"
		write_page "   to get support for making sure your packages build reproducibly too. Also, we care about free software in general,"
		write_page "   so if you are an upstream developer or working on another distribution, we'd love to hear from you!"
		write_page "   Besides Debian we are also testing <li><a href=\"/coreboot/\">coreboot</a></li>, <li><a href=\"/openwrt/\">OpenWrt</a></li>, <li><a href=\"netbsd\">NetBSD</a></li>, <li><a href=\"/freebsd/\">FreeBSD</a></li> and <li><a href=\"archlinux\">Archlinux</a></li> now, though not as thoroughly as Debian (yet?) - and there are plans to test <a href=\"$JENKINS_URL/userContent/todo.html#_reproducible_fedora\">Fedora</a> too.</ul>"
		write_page "   <ul>As we think that reproducible builds should become the norm, we have started to write <li><a href=\"https://reproducible-builds.org/howto\">How to make your software reproducible</a></li>. As always we appreciate feedback on this document, just please don't consider it to be finished, comprehensive or correct, yet."
		write_page "      Also aimed at the free software world at large, but released as version 1.0, is the first specication we have written: the <li><a href=\"https://reproducible-builds.org/specs/source-date-epoch/\">SOURCE_DATE_EPOCH specification</a></li>.</ul>"
	fi
	write_page "<ul><li>Have a look at:</li>"
	for MY_STATE in $ALLSTATES ; do
		set_icon $MY_STATE
		write_page "<li>"
		write_icon
		write_page "</li>"
	done
	for TARGET in $ALLVIEWS ; do
		if [ "$TARGET" = "pkg_sets" ] && [ "$SUITE" = "experimental" ] ; then
			# no pkg_sets are tested in experimental
			continue
		fi
		if [ "$TARGET" = "pkg_sets" ] && [ "$ARCH" = "armhf" ] ; then
			# no pkg_sets for armhf _yet_
			continue
		fi
		SPOKEN_TARGET=${SPOKENTARGET[$TARGET]}
		BASEURL="/$SUITE/$ARCH"
		local i
		for i in $GLOBALVIEWS ; do
			if [ "$TARGET" = "$i" ] ; then
				BASEURL=""
			fi
		done
		for i in ${SUITEVIEWS} ; do
			if [ "$TARGET" = "$i" ] ; then
				BASEURL="/$SUITE"
			fi
		done
		if [ "$TARGET" = "suite_stats" ] ; then
			for i in $SUITES ; do
				if [ "$i" != "unstable" ] && [ "$ARCH" = "armhf" ] ; then
					# only unstable is tested on armhf atm
					continue
				fi
				write_page "<li><a href=\"/$i/index_suite_${ARCH}_stats.html\">suite: $i</a></li>"
			done
		elif [ "$TARGET" = "scheduled" ] ; then
			write_page "<li><a href=\"/index_${ARCH}_scheduled.html\">${SPOKEN_TARGET}</a></li>"
		elif [ "$TARGET" = "notify" ] ; then
			write_page "<li><a href=\"$BASEURL/index_${TARGET}.html\" title=\"notify icon\">${SPOKEN_TARGET}</a></li>"
		elif [ "$TARGET" = "arch" ] ; then
			if [ "$ARCH"  = "amd64" ] ; then
				write_page "<li><a href=\"/unstable/index_suite_armhf_stats.html\">arch: armhf</a></li>"
			else
				write_page "<li><a href=\"/unstable/index_suite_amd64_stats.html\">arch: amd64</a></li>"
			fi
		else
			write_page "<li><a href=\"$BASEURL/index_${TARGET}.html\">${SPOKEN_TARGET}</a></li>"
		fi
	done
	write_page "<li><a href=\"https://wiki.debian.org/ReproducibleBuilds\" target=\"_blank\">wiki</a></li>"
	write_page "</ul></nav>"
	if [ "$1" = "$MAINVIEW" ] ; then
		LATEST=$(sqlite3 -init $INIT ${PACKAGES_DB} "SELECT s.name FROM results AS r JOIN sources AS s ON r.package_id = s.id WHERE r.status IN ('unreproducible') AND s.suite = 'unstable' AND s.architecture = 'amd64' AND s.id NOT IN (SELECT package_id FROM notes) ORDER BY build_date DESC LIMIT 23"|sort -R|head -1)
		write_page "<form action=\"https://reproducible.debian.net/redirect\" method=\"GET\">https://reproducible.debian.net/"
		write_page "<input type=\"text\" name=\"SrcPkg\" placeholder=\"Type my friend..\" value=\"$LATEST\" />"
		write_page "<input type=\"submit\" value=\"submit source package name\" />"
		write_page "</form>"
	fi
	write_page "</header>"
}

write_page_intro() {
	write_page "       <p><em>Reproducible builds</em> enable anyone to reproduce bit by bit identical binary packages from a given source, so that anyone can verify that a given binary derived from the source it was said to be derived. There is a lot more information about <a href=\"https://wiki.debian.org/ReproducibleBuilds\">reproducible builds on the Debian wiki</a> and on <a href=\"https://reproducible.debian.net\">https://reproducible.debian.net</a>. The wiki explains in more depth why this is useful, what common issues exist and which workarounds and solutions are known.<br />"
	local BUILD_ENVIRONMENT=" in a Debian environment"
	local BRANCH="master"
	if [ "$1" = "coreboot" ] ; then
		write_page "        <em>Reproducible Coreboot</em> is an effort to apply this to coreboot. Thus each coreboot.rom is build twice (without payloads), with a few varitations added and then those two ROMs are compared using <a href=\"https://tracker.debian.org/diffoscope\">diffoscope</a>. Please note that the toolchain is not varied at all as the rebuild happens on exactly the same system. More variations are expected to be seen in the wild.</p>"
		local PROJECTNAME="$1"
		local PROJECTURL="https://review.coreboot.org/p/coreboot.git"
	elif [ "$1" = "OpenWrt" ] ; then
		write_page "        <em>Reproducible OpenWrt</em> is an effort to apply this to OpenWrt. Thus each OpenWrt target is build twice, with a few varitations added and then the resulting images and packages from the two builds are compared using <a href=\"https://tracker.debian.org/diffoscope\">diffoscope</a>, <em>which currently cannot detect <code>.bin</code> files as squashfs filesystems.</em> Thus the resulting diffoscope output is not nearly as clear as it could be - hopefully this limitation will be overcome soon. Also please note that the toolchain is not varied at all as the rebuild happens on exactly the same system. More variations are expected to be seen in the wild.</p>"
		local PROJECTNAME="openwrt"
		local PROJECTURL="git://git.openwrt.org/openwrt.git"
	elif [ "$1" = "NetBSD" ] ; then
		write_page "        <em>Reproducible NetBSD</em> is an effort to apply this to NetBSD. Thus each NetBSD target is build twice, with a few varitations added and then the resulting files from the two builds are compared using <a href=\"https://tracker.debian.org/diffoscope\">diffoscope</a>. Please note that the toolchain is not varied at all as the rebuild happens on exactly the same system. More variations are expected to be seen in the wild.</p>"
		local PROJECTNAME="netbsd"
		local PROJECTURL="https://github.com/jsonn/src"
	elif [ "$1" = "FreeBSD" ] ; then
		write_page "        <em>Reproducible FreeBSD</em> is an effort to apply this to FreeBSD. Thus FreeBSD is build twice, with a few varitations added and then the resulting filesystems from the two builds are put into a compressed tar archive, which is then compared using <a href=\"https://tracker.debian.org/diffoscope\">diffoscope</a>. Please note that the toolchain is not varied at all as the rebuild happens on exactly the same system. More variations are expected to be seen in the wild.</p>"
		local PROJECTNAME="freebsd"
		local PROJECTURL="https://github.com/freebsd/freebsd.git"
		local BUILD_ENVIRONMENT=", which via ssh triggers a build on a FreeBSD 10.1 system"
		local BRANCH="release/10.2.0"
	elif [ "$1" = "Archlinux" ] ; then
		write_page "        <em>Reproducible $1</em> is an effort to apply this to $1. Thus $1 packages are build twice, with a few varitations added and then the resulting packages from the two builds are then compared using <a href=\"https://tracker.debian.org/diffoscope\">diffoscope</a>. Please note that the toolchain is not varied at all as the rebuild happens on exactly the same system. More variations are expected to be seen in the wild.</p>"
		local PROJECTNAME="Archlinux"
	fi
	if [ "$1" != "Archlinux" ] ; then
		write_page "       <p>There is a weekly run <a href=\"https://jenkins.debian.net/view/reproducible/job/reproducible_$PROJECTNAME/\">jenkins job</a> to test the <code>$BRANCH</code> branch of <a href=\"$PROJECTURL\">$PROJECTNAME.git</a>. Currently this job is triggered more often though, because this is still under development and brand new. The jenkins job is running <a href=\"http://anonscm.debian.org/cgit/qa/jenkins.debian.net.git/tree/bin/reproducible_$PROJECTNAME.sh\">reproducible_$PROJECTNAME.sh</a>$BUILD_ENVIRONMENT and this script is solely responsible for creating this page. Feel invited to join <code>#debian-reproducible</code> (on irc.oftc.net) to request job runs whenever sensible. Patches and other <a href=\"mailto:reproducible-builds@lists.alioth.debian.org\">feedback</a> are very much appreciated - if you want to help, please start by looking at the <a href=\"$JENKINS_URL/userContent/todo.html#_reproducible_$(echo $1|tr '[:upper:]' '[:lower:]')\">ToDo list for $1</a>, you might find something easy to contribute.</p>"
	else
		write_page "       <p>This is brand new and the test setup needs to be explained here.</p>"
	fi
}

write_page_footer() {
	write_page "<hr/><p style=\"font-size:0.9em;\">There is more information <a href=\"$JENKINS_URL/userContent/about.html\">about jenkins.debian.net</a> and about <a href=\"https://wiki.debian.org/ReproducibleBuilds\"> reproducible builds of Debian</a> available elsewhere. Last update: $(date +'%Y-%m-%d %H:%M %Z'). Copyright 2014-2015 <a href=\"mailto:holger@layer-acht.org\">Holger Levsen</a> and others, <a href=\"http://anonscm.debian.org/cgit/qa/jenkins.debian.net.git/\">jenkins.debian.net.git</a> is mostly GPL2 licensed. The weather icons are public domain and have been taken from the <a href="http://tango.freedesktop.org/Tango_Icon_Library" target="_blank">Tango Icon Library</a>."
	if [ "$1" = "coreboot" ] ; then
		write_page "The <a href=\"http://www.coreboot.org\">Coreboot</a> logo is Copyright © 2008 by Konsult Stuge and coresystems GmbH and can be freely used to refer to the Coreboot project."
	elif [ "$1" = "NetBSD" ] ; then
		write_page "NetBSD® is a registered trademark of The NetBSD Foundation, Inc."
	elif [ "$1" = "FreeBSD" ] ; then
		write_page "FreeBSD is a registered trademark of The FreeBSD Foundation. The FreeBSD logo and The Power to Serve are trademarks of The FreeBSD Foundation."
	elif [ "$1" = "Archlinux" ] ; then
		write_page "The <a href=\"https://www.archlinux.org\">Arch Linux</a> name and logo are recognized trademarks. Some rights reserved. The registered trademark Linux® is used pursuant to a sublicense from LMI, the exclusive licensee of Linus Torvalds, owner of the mark on a world-wide basis."
	fi
	write_page "</p></body></html>"
}

write_page_meta_sign() {
	write_page "<p style=\"font-size:0.9em;\">A package name displayed with a bold font is an indication that this package has a note. Visited packages are linked in green, those which have not been visited are linked in blue.</br>"
	write_page "A <code><span class=\"bug\">&#35;</span></code> sign after the name of a package indicates that a bug is filed against it. Likewise, a <code><span class=\"bug-patch\">&#43;</span></code> sign indicates there is a patch available, a <code><span class="bug-pending">P</span></code> means a pending bug while <code><span class=\"bug-done\">&#35;</span></code> indicates a closed bug. In cases of several bugs, the symbol is repeated.</p>"
}

write_explaination_table() {
	write_page "<p style=\"clear:both;\">"
	write_page "<table class=\"main\" id=\"variation\"><tr><th>variation</th><th>first build</th><th>second build</th></tr>"
	if [ "$1" = "debian" ] ; then
		write_page "<tr><td>hostname</td><td>one of: $(for i in $BUILD_NODES ; do echo '<br />&nbsp;&nbsp;' ; echo $i | cut -d '.' -f1 ; done)</td><td>i-capture-the-hostname</td></tr>"
		write_page "<tr><td>domainname</td><td>$(hostname -d)</td><td>i-capture-the-domainname</td></tr>"
	else
		write_page "<tr><td>hostname</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		write_page "<tr><td>domainname</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
	fi
	if [ "$1" != "FreeBSD" ] && [ "$1" != "Archlinux" ]  ; then
		write_page "<tr><td>env CAPTURE_ENVIRONMENT</td><td><em>not set</em></td><td>CAPTURE_ENVIRONMENT=\"I capture the environment\"</td></tr>"
	fi
	write_page "<tr><td>env TZ</td><td>TZ=\"/usr/share/zoneinfo/Etc/GMT+12\"</td><td>TZ=\"/usr/share/zoneinfo/Etc/GMT-14\"</td></tr>"
	if [ "$1" = "Archlinux" ]  ; then
		write_page "<tr><td>env LANG</td><td>LANG<em>not set</em></td><td>LANG=\"fr_CH.UTF-8\"</td></tr>"
	else
		write_page "<tr><td>env LANG</td><td>LANG=\"en_GB.UTF-8\"</td><td>LANG=\"fr_CH.UTF-8\"</td></tr>"
	fi
	write_page "<tr><td>env LC_ALL</td><td><em>not set</em></td><td>LC_ALL=\"fr_CH.UTF-8\"</td></tr>"
	fi
	if [ "$1" != "FreeBSD" ] && [ "$1" != "Archlinux" ]  ; then
		write_page "<tr><td>env PATH</td><td>PATH=\"/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:\"</td><td>PATH=\"/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/i/capture/the/path\"</td></tr>"
	else
		write_page "<tr><td>env PATH</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
	fi
	if [ "$1" = "debian" ] ; then
		write_page "<tr><td>env BUILDUSERID</td><td>BUILDUSERID=\"1111\"</td><td>BUILDUSERID=\"2222\"</td></tr>"
		write_page "<tr><td>env BUILDUSERNAME</td><td>BUILDUSERNAME=\"pbuilder1\"</td><td>BUILDUSERNAME=\"pbuilder2\"</td></tr>"
		write_page "<tr><td>env USER</td><td>USER=\"pbuilder1\"</td><td>USER=\"pbuilder2\"</td></tr>"
		write_page "<tr><td>uid</td><td>uid=1111</td><td>uid=2222</td></tr>"
		write_page "<tr><td>gid</td><td>gid=1111</td><td>gid=2222</td></tr>"
		write_page "<tr><td>env DEB_BUILD_OPTIONS</td><td>DEB_BUILD_OPTIONS=\"parallel=XXX\"<br />&nbsp;&nbsp;XXX for amd64: 16 or 8<br />&nbsp;&nbsp;XXX for armhf: 4 or 2</td><td>DEB_BUILD_OPTIONS=\"parallel=YYY\"<br />&nbsp;&nbsp;YYY for amd64: XXX-1<br />&nbsp;&nbsp;YYY for armhf: 2 or 4 - the opposite of the first build)</td></tr>"
		write_page "<tr><td>UTS namespace</td><td><em>shared with the host</em></td><td><em>modified using</em> /usr/bin/unshare --uts</td></tr>"
	else
		write_page "<tr><td>env USER</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		write_page "<tr><td>uid</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		write_page "<tr><td>gid</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		if [ "$1" != "FreeBSD" ] ; then
			write_page "<tr><td>UTS namespace</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		fi
	fi
	if [ "$1" != "FreeBSD" ] ; then
		if [ "$1" = "debian" ] ; then
			write_page "<tr><td>kernel version, modified using /usr/bin/linux64 --uname-2.6</td></td><td>one of: $(cat /srv/reproducible-results/node-information/* | grep KERNEL1 | cut -d '=' -f2- | sort -u | tr '\n' '\0' | xargs -0 -n1 echo '<br />&nbsp;&nbsp;')</td><td>one of: $(cat /srv/reproducible-results/node-information/* | grep KERNEL2 | cut -d '=' -f2- | sort -u | tr '\n' '\0' | xargs -0 -n1 echo '<br />&nbsp;&nbsp;')</td></tr>"
		elif [ "$1" != "Archlinux" ]  ; then
			write_page "<tr><td>kernel version, modified using /usr/bin/linux64 --uname-2.6</td><td>$(uname -sr)</td><td>$(/usr/bin/linux64 --uname-2.6 uname -sr)</td></tr>"
		else
			write_page "<tr><td>kernel version</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		fi
		write_page "<tr><td>umask</td><td>0022<td>0002</td><tr>"
	else
		write_page "<tr><td>FreeBSD kernel version</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td></tr>"
		write_page "<tr><td>umask</td><td colspan=\"2\"> is not yet varied between rebuilds of $1.</td><tr>"
	fi
	if [ "$1" = "debian" ] ; then
		write_page "<tr><td>CPU type</td><td>one of: $(cat /srv/reproducible-results/node-information/* | grep CPU_MODEL | cut -d '=' -f2- | sort -u | tr '\n' '\0' | xargs -0 -n1 echo '<br />&nbsp;&nbsp;')</td><td>on armhf: sometimes varied (depending on the build job)<br />on amd64: same for both builds (currently, work in progress)</td></tr>"
	else
		write_page "<tr><td>CPU type</td><td>$(cat /proc/cpuinfo|grep 'model name'|head -1|cut -d ":" -f2-)</td><td>same for both builds</td></tr>"
	fi
	write_page "<tr><td>year, month, date</td><td>today ($DATE)</td><td>same for both builds (currently, work in progress)</td></tr>"
	if [ "$1" != "FreeBSD" ] ; then
		write_page "<tr><td>hour, minute</td><td>hour and minute will probably vary between two builds...</td><td>but this is not enforced systematically... (currently, work in progress)</td></tr>"
		if [ "$1" = "debian" ] ; then
		        write_page "<tr><td>filesystem</td><td>tmpfs</td><td><em>temporarily not</em> varied using <a href=\"https://tracker.debian.org/disorderfs\">disorderfs</a> (<a href=\"https://sources.debian.net/src/disorderfs/sid/disorderfs.1.txt/\">manpage</a>)</td></tr>"
		else
			write_page "<tr><td>Filesystem</td><td>tmpfs</td><td>same for both builds (currently, this could be varied using <a href=\"https://tracker.debian.org/disorderfs\">disorderfs</a>)</td></tr>"
		fi
	else
		write_page "<tr><td>hour, minute</td><td>hour and minute will probably vary between two builds...</td><td>but this is not enforced systematically...)</td></tr>"
		write_page "<tr><td>filesystem of the build directory</td><td>ufs</td><td>same for both builds</td></tr>"
	fi
	if [ "$1" = "debian" ] ; then
		write_page "<tr><td><em>everything else...</em></td><td colspan=\"2\">is likely the same. So far, this is just about the <em>prospects</em> of <a href=\"https://wiki.debian.org/ReproducibleBuilds\">reproducible builds of Debian</a> - there will be more variations in the wild.</td></tr>"
	else
		write_page "<tr><td><em>everything else...</em></td><td colspan=\"2\">is likely the same. There will be more variations in the wild.</td></tr>"
	fi
	write_page "</table></p>"
}

publish_page() {
	if [ "$1" = "" ] ; then
		TARGET=$PAGE
	else
		TARGET=$1/$PAGE
	fi
	cp $PAGE $BASE/$TARGET
	rm $PAGE
	echo "Enjoy $REPRODUCIBLE_URL/$TARGET"
}

link_packages() {
	set +x
        local i
	for (( i=1; i<$#+1; i=i+400 )) ; do
		local string='['
		local delimiter=''
		local j
		for (( j=0; j<400; j++)) ; do
			local item=$(( $j+$i ))
			if (( $item < $#+1 )) ; then
				string+="${delimiter}\"${!item}\""
				delimiter=','
			fi
		done
		string+=']'
		cd /srv/jenkins/bin
		DATA=" $(python3 -c "from reproducible_common import link_packages; \
				print(link_packages(${string}, '$SUITE', '$ARCH'))" 2> /dev/null)"
		cd - > /dev/null
		write_page "$DATA"
	done
	if "$DEBUG" ; then set -x ; fi
}

gen_package_html() {
	cd /srv/jenkins/bin
	python3 -c "import reproducible_html_packages as rep
pkg = rep.Package('$1', no_notes=True)
rep.gen_packages_html([pkg], no_clean=True)" || echo "Warning: cannot update html pages for $1"
	cd - > /dev/null
}

calculate_build_duration() {
	END=$(date +'%s')
	DURATION=$(( $END - $START ))
}

print_out_duration() {
	local HOUR=$(echo "$DURATION/3600"|bc)
	local MIN=$(echo "($DURATION-$HOUR*3600)/60"|bc)
	local SEC=$(echo "$DURATION-$HOUR*3600-$MIN*60"|bc)
	echo "$(date) - total duration: ${HOUR}h ${MIN}m ${SEC}s." | tee -a ${RBUILDLOG}
}

irc_message() {
	local MESSAGE="$@"
	kgb-client --conf /srv/jenkins/kgb/debian-reproducible.conf --relay-msg "$MESSAGE" || true # don't fail the whole job
}

call_diffoscope() {
	mkdir -p $TMPDIR/$1/$(dirname $2)
	local TMPLOG=(mktemp --tmpdir=$TMPDIR)
	local msg=""
	set +e
	# remember to also modify the retry diffoscope call 15 lines below
	( timeout $TIMEOUT schroot \
		--directory $TMPDIR \
		-c source:jenkins-reproducible-${DBDSUITE}-diffoscope \
		diffoscope -- \
			--html $TMPDIR/$1/$2.html \
			$TMPDIR/b1/$1/$2 \
			$TMPDIR/b2/$1/$2 2>&1 \
	) 2>&1 >> $TMPLOG
	RESULT=$?
	LOG_RESULT=$(grep '^E: 15binfmt: update-binfmts: unable to open' $TMPLOG || true)
	if [ ! -z "$LOG_RESULT" ] ; then
		rm -f $TMPLOG $TMPDIR/$1/$2.html
		echo "$(date -u) - schroot jenkins-reproducible-${DBDSUITE}-diffoscope not available, will sleep 2min and retry."
		sleep 2m
		# remember to also modify the retry diffoscope call 15 lines above
		( timeout $TIMEOUT schroot \
			--directory $TMPDIR \
			-c source:jenkins-reproducible-${DBDSUITE}-diffoscope \
			diffoscope -- \
				--html $TMPDIR/$1/$2.html \
				$TMPDIR/b1/$1/$2 \
				$TMPDIR/b2/$1/$2 2>&1 \
			) 2>&1 >> $TMPLOG
		RESULT=$?
	fi
	if ! "$DEBUG" ; then set +x ; fi
	set -e
	cat $TMPLOG # print dbd output
	rm -f $TMPLOG
	case $RESULT in
		0)	echo "$(date -u) - $1/$2 is reproducible, yay!"
			;;
		1)
			echo "$(date -u) - $DIFFOSCOPE found issues, please investigate $1/$2"
			;;
		2)
			msg="$(date -u) - $DIFFOSCOPE had trouble comparing the two builds. Please investigate $1/$2"
			;;
		124)
			if [ ! -s $TMPDIR/$1.html ] ; then
				msg="$(date -u) - $DIFFOSCOPE produced no output for $1/$2 and was killed after running into timeout after ${TIMEOUT}..."
			else
				msg="$DIFFOSCOPE was killed after running into timeout after $TIMEOUT, but there is still $TMPDIR/$1/$2.html"
			fi
			;;
		*)
			msg="$(date -u) - Something weird happened when running $DIFFOSCOPE on $1/$2 (which exited with $RESULT) and I don't know how to handle it."
			;;
	esac
	if [ ! -z "$msg" ] ; then
		echo $msg | tee -a $TMPDIR/$1/$2.html
	fi
}

get_filesize() {
		local BYTESIZE="$(du -h -b $1 | cut -f1)"
		# numbers below 16384K are understood and more meaningful than 16M...
		if [ $BYTESIZE -gt 16777216 ] ; then
			SIZE="$(echo $BYTESIZE/1048576|bc)M"
		elif [ $BYTESIZE -gt 1024 ] ; then
			SIZE="$(echo $BYTESIZE/1024|bc)K"
		else
			SIZE="$BYTESIZE bytes"
		fi
}

cleanup_pkg_files() {
	rm -vf $BASE/rbuild/${SUITE}/${ARCH}/${SRCPACKAGE}_*.rbuild.log{,.gz}
	rm -vf $BASE/logs/${SUITE}/${ARCH}/${SRCPACKAGE}_*.build?.log{,.gz}
	rm -vf $BASE/dbd/${SUITE}/${ARCH}/${SRCPACKAGE}_*.debbindiff.html
	rm -vf $BASE/dbdtxt/${SUITE}/${ARCH}/${SRCPACKAGE}_*.debbindiff.txt{,.gz}
	rm -vf $BASE/buildinfo/${SUITE}/${ARCH}/${SRCPACKAGE}_*.buildinfo
	rm -vf $BASE/logdiffs/${SUITE}/${ARCH}/${SRCPACKAGE}_*.diff{,.gz}
}

#
# create the png (and query the db to populate a csv file...)
#
create_png_from_table() {
	echo "Checking whether to update $2..."
	# $1 = id of the stats table
	# $2 = image file name
	# $3 = meta package set, only sensible if $1=6
	echo "${FIELDS[$1]}" > ${TABLE[$1]}.csv
	# prepare query
	WHERE_EXTRA="WHERE suite = '$SUITE'"
	if [ "$ARCH" = "armhf" ] ; then
		# armhf was only build since 2015-08-30
		WHERE2_EXTRA="WHERE s.datum >= '2015-08-30'"
	else
		WHERE2_EXTRA=""
	fi
	if [ $1 -eq 3 ] || [ $1 -eq 4 ] || [ $1 -eq 5 ] ; then
		# TABLE[3+4+5] don't have a suite column:
		WHERE_EXTRA=""
	elif [ $1 -eq 6 ] ; then
		# 6 is special too:
		WHERE_EXTRA="WHERE suite = '$SUITE' and meta_pkg = '$3'"
	fi
	if [ $1 -eq 0 ] || [ $1 -eq 2 ] ; then
		# TABLE[0+2] have a architecture column:
		WHERE_EXTRA="$WHERE_EXTRA AND architecture = \"$ARCH\""
		if [ $1 -eq 2 ] && [ "$ARCH" = "armhf" ] ; then
			# armhf was only build since 2015-08-30
			WHERE_EXTRA="$WHERE_EXTRA AND datum >= '2015-08-30'"
		fi
		# testing/amd64 was only build since...
		# WHERE2_EXTRA="WHERE s.datum >= '2015-03-08'"
		# experimental/amd64 was only build since...
		# WHERE2_EXTRA="WHERE s.datum >= '2015-02-28'"
	fi
	# run query
	if [ $1 -eq 1 ] ; then
		# not sure if it's worth to generate the following query...
		WHERE_EXTRA="AND architecture='$ARCH'"
		sqlite3 -init ${INIT} --nullvalue 0 -csv ${PACKAGES_DB} "SELECT s.datum,
			 COALESCE((SELECT e.reproducible FROM stats_builds_per_day AS e WHERE s.datum=e.datum AND suite='testing' $WHERE_EXTRA),0) AS reproducible_testing,
			 COALESCE((SELECT e.reproducible FROM stats_builds_per_day AS e WHERE s.datum=e.datum AND suite='unstable' $WHERE_EXTRA),0) AS reproducible_unstable,
			 COALESCE((SELECT e.reproducible FROM stats_builds_per_day AS e WHERE s.datum=e.datum AND suite='experimental' $WHERE_EXTRA),0) AS reproducible_experimental,
			 (SELECT e.unreproducible FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='testing' $WHERE_EXTRA) AS unreproducible_testing,
			 (SELECT e.unreproducible FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='unstable' $WHERE_EXTRA) AS unreproducible_unstable,
			 (SELECT e.unreproducible FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='experimental' $WHERE_EXTRA) AS unreproducible_experimental,
			 (SELECT e.FTBFS FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='testing' $WHERE_EXTRA) AS FTBFS_testing,
			 (SELECT e.FTBFS FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='unstable' $WHERE_EXTRA) AS FTBFS_unstable,
			 (SELECT e.FTBFS FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='experimental' $WHERE_EXTRA) AS FTBFS_experimental,
			 (SELECT e.other FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='testing' $WHERE_EXTRA) AS other_testing,
			 (SELECT e.other FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='unstable' $WHERE_EXTRA) AS other_unstable,
			 (SELECT e.other FROM stats_builds_per_day e WHERE s.datum=e.datum AND suite='experimental' $WHERE_EXTRA) AS other_experimental
			 FROM stats_builds_per_day AS s $WHERE2_EXTRA GROUP BY s.datum" >> ${TABLE[$1]}.csv
	elif [ $1 -eq 2 ] ; then
		# just make a graph of the oldest reproducible build (ignore FTBFS and unreproducible)
		sqlite3 -init ${INIT} -csv ${PACKAGES_DB} "SELECT datum, oldest_reproducible FROM ${TABLE[$1]} ${WHERE_EXTRA} ORDER BY datum" >> ${TABLE[$1]}.csv
	elif [ $1 -eq 7 ] ; then
		sqlite3 -init ${INIT} -csv ${PACKAGES_DB} "SELECT datum, $SUM_DONE, $SUM_OPEN from ${TABLE[3]} ORDER BY datum" >> ${TABLE[$1]}.csv
	else
		sqlite3 -init ${INIT} -csv ${PACKAGES_DB} "SELECT ${FIELDS[$1]} from ${TABLE[$1]} ${WHERE_EXTRA} ORDER BY datum" >> ${TABLE[$1]}.csv
	fi
	# this is a gross hack: normally we take the number of colors a table should have...
	#  for the builds_age table we only want one color, but different ones, so this hack:
	COLORS=${COLOR[$1]}
	if [ $1 -eq 2 ] ; then
		case "$SUITE" in
			testing)	COLORS=40 ;;
			unstable)	COLORS=41 ;;
			experimental)	COLORS=42 ;;
		esac
	fi
	local WIDTH=1920
	local HEIGHT=960
	# only generate graph if the query returned data
	if [ $(cat ${TABLE[$1]}.csv | wc -l) -gt 1 ] ; then
		echo "Updating $2..."
		DIR=$(dirname $2)
		mkdir -p $DIR
		echo "Generating $2."
		/srv/jenkins/bin/make_graph.py ${TABLE[$1]}.csv $2 ${COLORS} "${MAINLABEL[$1]}" "${YLABEL[$1]}" $WIDTH $HEIGHT
		mv $2 $BASE/$DIR
		[ "$DIR" = "." ] || rmdir $(dirname $2)
	# create empty dummy png if there havent been any results ever
	elif [ ! -f $BASE/$DIR/$(basename $2) ] ; then
		DIR=$(dirname $2)
		mkdir -p $DIR
		echo "Creating $2 dummy."
		convert -size 1920x960 xc:#aaaaaa -depth 8 $2
		if [ "$3" != "" ] ; then
			local THUMB="${TABLE[1]}_${3}-thumbnail.png"
			convert $2 -adaptive-resize 160x80 ${THUMB}
			mv ${THUMB} $BASE/$DIR
		fi
		mv $2 $BASE/$DIR
		[ "$DIR" = "." ] || rmdir $(dirname $2)
	fi
	rm ${TABLE[$1]}.csv
}

