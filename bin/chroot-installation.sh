#!/bin/bash

# Copyright 2012-2015 Holger Levsen <holger@layer-acht.org>
# released under the GPLv=2

DEBUG=true
. /srv/jenkins/bin/common-functions.sh
common_init "$@"
set -e

# $1 = base distro
# $2 = extra component
# $3 = upgrade distro

if [ "$1" = "" ] ; then
	echo "need at least one distribution to act on"
	echo '# $1 = base distro'
	echo '# $2 = component to test (gnome, kde, xfce, lxce)'
	echo '# $3 = upgrade distro'
	exit 1
fi

SLEEP=$(shuf -i 1-10 -n 1)
echo "Sleeping $SLEEP seconds to randomize start times and parallel runs."
sleep $SLEEP

export CHROOT_TARGET=$(mktemp -d -p /chroots/ chroot-installation-$1.XXXXXXXXX)
export TMPFILE=$(mktemp -u)
export CTMPFILE=$CHROOT_TARGET/$TMPFILE
export TMPLOG=$(mktemp)

cleanup_all() {
	echo "Doing cleanup now."
	set -x
	# test if $CHROOT_TARGET starts with /chroots/
	if [ "${CHROOT_TARGET:0:9}" != "/chroots/" ] ; then
		echo "HALP. CHROOT_TARGET = $CHROOT_TARGET"
		exit 1
	fi
	sudo umount -l $CHROOT_TARGET/proc || fuser -mv $CHROOT_TARGET/proc
	sudo rm -rf --one-file-system $CHROOT_TARGET || fuser -mv $CHROOT_TARGET
	rm -f $TMPLOG
	echo "\$1 = $1"
	if [ "$1" != "fine" ] ; then
		exit 1
	else
		echo "Exiting cleanly."
	fi
}

execute_ctmpfile() {
	echo "echo xxxxxSUCCESSxxxxx" >> $CTMPFILE
	set -x
	chmod +x $CTMPFILE
	set -o pipefail		# see eg http://petereisentraut.blogspot.com/2010/11/pipefail.html
	(sudo chroot $CHROOT_TARGET $TMPFILE 2>&1 | tee $TMPLOG) || true
	RESULT=$(grep "xxxxxSUCCESSxxxxx" $TMPLOG || true)
	if [ -z "$RESULT" ] ; then
		RESULT=$(egrep "Failed to fetch.*(Unable to connect to|Connection failed|Size mismatch|Cannot initiate the connection to|Bad Gateway)" $TMPLOG || true)
		if [ ! -z "$RESULT" ] ; then
			echo
			echo "$(date -u) - Warning: Network problem detected."
			echo "$(date -u) - trying to workaround temporarily failure fetching packages, sleeping 5min before trying again..."
			sleep 5m
			echo
			sudo chroot $CHROOT_TARGET $TMPFILE
		else
			echo "Failed to run $TMPFILE in $CHROOT_TARGET."
			exit 1
		fi
	fi
	rm $CTMPFILE
	set +o pipefail
	set +x
}

prepare_bootstrap() {
	cat >> $CTMPFILE <<-EOF
$SCRIPT_HEADER
set -x
mount /proc -t proc /proc
echo -e '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
echo 'Acquire::http::Proxy "http://localhost:3128";' > /etc/apt/apt.conf.d/80proxy
cat > /etc/apt/apt.conf.d/80debug << APTEOF
# solution calculation
Debug::pkgDepCache::Marker "true";
Debug::pkgDepCache::AutoInstall "true";
Debug::pkgProblemResolver "true";
# installation order
Debug::pkgPackageManager "true";
APTEOF
echo "deb-src $MIRROR $1 main" > /etc/apt/sources.list.d/$1-src.list
apt-get update
set +x
EOF
}

prepare_install_packages() {
	cat >> $CTMPFILE <<-EOF
$SCRIPT_HEADER
set -x
apt-get -y install $@
apt-get clean
set +x
EOF
}

prepare_install_binary_packages() {
	# install all binary packages build from these source packages
	cat >> $CTMPFILE <<-EOF
$SCRIPT_HEADER
set -x
apt-get install -y dctrl-tools
PACKAGES=""
for PKG in $@ ; do
	PACKAGES="\$PACKAGES \$(grep-dctrl -S \$PKG /var/lib/apt/lists/*Packages | sed -n -e "s#^Package: ##p" | xargs -r echo)"
done
apt-get install -y \$PACKAGES
apt-get clean
set +x
EOF
}

prepare_install_build_depends() {
	cat >> $CTMPFILE <<-EOF
$SCRIPT_HEADER
set -x
apt-get -y install build-essential
apt-get clean
EOF
for PACKAGE in $@ ; do
	echo apt-get -y build-dep $PACKAGE >> $CTMPFILE
	echo apt-get clean >> $CTMPFILE
done
echo "set +x" >> $CTMPFILE
}

prepare_upgrade2() {
	# support _aptdpkg_first type upgrade jobs...
	if [ "${JOB_NAME: -14}" = "_aptdpkg_first" ] ; then
		APTDPKGFIRST="apt-get -y install dpkg apt"
	else
		APTDPKGFIRST=""
	fi
	cat >> $CTMPFILE <<-EOF
echo "deb $MIRROR $1 main" > /etc/apt/sources.list.d/$1.list
$SCRIPT_HEADER
set -x
apt-get update
$APTDPKGFIRST
apt-get -y upgrade
apt-get clean
apt-get -yf dist-upgrade
apt-get clean
apt-get -yf dist-upgrade
apt-get clean
apt-get --dry-run autoremove
set +x
EOF
}

bootstrap() {
	mkdir -p "$CHROOT_TARGET/etc/dpkg/dpkg.cfg.d"
	echo force-unsafe-io > "$CHROOT_TARGET/etc/dpkg/dpkg.cfg.d/02dpkg-unsafe-io"

	echo "Bootstraping $1 into $CHROOT_TARGET now."
	set -x
	sudo debootstrap $1 $CHROOT_TARGET $MIRROR
	set +x
	prepare_bootstrap $1
	execute_ctmpfile 
}

install_packages() {
	echo "Installing extra packages for $1 now."
	shift
	prepare_install_packages $@
	execute_ctmpfile 
}

install_binary_packages() {
	echo "Installing extra packages for $1 now, based on a list of source packages."
	shift
	# install all binary packages build from these source packages
	prepare_install_binary_packages $@
	execute_ctmpfile
}


install_build_depends() {
	echo "Installing build depends for $1 now."
	shift
	prepare_install_build_depends $@
	execute_ctmpfile
}

upgrade2() {
	echo "Upgrading to $1 now."
	prepare_upgrade2 $1
	execute_ctmpfile 
}

trap cleanup_all INT TERM EXIT

case $1 in
	squeeze)	DISTRO="squeeze"
			SPECIFIC="openoffice.org virtualbox-ose mplayer chromium-browser"
			;;
	wheezy)		DISTRO="wheezy"
			SPECIFIC="libreoffice virtualbox mplayer chromium"
			;;
	jessie)		DISTRO="jessie"
			SPECIFIC="libreoffice virt-manager mplayer2 chromium"
			;;
	stretch)	DISTRO="stretch"
			SPECIFIC="libreoffice virt-manager mplayer chromium"
			;;
	sid)		DISTRO="sid"
			SPECIFIC="libreoffice virt-manager mplayer chromium"
			;;
	*)		echo "unsupported distro."
			exit 1
			;;
esac
bootstrap $DISTRO

if [ "$2" != "" ] ; then
	FULL_DESKTOP="$SPECIFIC desktop-base gnome kde-plasma-desktop kde-full kde-standard xfce4 lxde vlc evince iceweasel cups build-essential devscripts wine texlive-full asciidoc vim emacs"
	case $2 in
		none)		;;
		gnome)		install_packages gnome gnome desktop-base
				;;
		kde)		install_packages kde kde-plasma-desktop desktop-base
				;;
		kde-full)	install_packages kde kde-full kde-standard desktop-base
				;;
		cinnamon)	install_packages cinnamon cinnamon-core cinnamon-desktop-environment desktop-base
				;;
		xfce)		install_packages xfce xfce4 desktop-base
				;;
		lxde)		install_packages lxde lxde desktop-base
				;;
		qt4)		install_binary_packages qt4 qt4-x11 qtwebkit
				;;
		qt5)		install_binary_packages qt5 qtbase-opensource-src qtchooser qtimageformats-opensource-src qtx11extras-opensource-src qtscript-opensource-src qtxmlpatterns-opensource-src qtdeclarative-opensource-src qtconnectivity-opensource-src qtsensors-opensource-src qt3d-opensource-src qtlocation-opensource-src qtwebkit-opensource-src qtquick1-opensource-src qtwebkit-examples-opensource-src qttools-opensource-src qtdoc-opensource-src qtgraphicaleffects-opensource-src qtquickcontrols-opensource-src qtserialport-opensource-src qtsvg-opensource-src qtmultimedia-opensource-src qtenginio-opensource-src qtwebsockets-opensource-src qttranslations-opensource-src qtcreator
				;;
		full_desktop)	install_packages full_desktop $FULL_DESKTOP
				;;
		haskell)	install_packages haskell 'haskell-platform.*' 'libghc-.*'
				;;
		developer)	install_build_depends developer $FULL_DESKTOP
				;;
		education*)	install_packages "Debian Edu task" $2
				;;
		*)		echo "unsupported component."
				exit 1
				;;
	esac
fi

if [ "$3" != "" ] ; then
	case $3 in
		squeeze|wheezy|jessie|stretch|sid)	upgrade2 $3;;
		*)		echo "unsupported distro." ; exit 1 ;;
	esac
fi

echo "Debug: Removing trap."
trap - INT TERM EXIT
echo "Debug: Cleanup fine"
cleanup_all fine

