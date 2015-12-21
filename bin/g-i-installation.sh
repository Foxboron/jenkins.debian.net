#!/bin/bash

# Copyright 2012-2015 Holger Levsen <holger@layer-acht.org>
# released under the GPLv=2

DEBUG=false
. /srv/jenkins/bin/common-functions.sh
common_init "$@"

# $1 = disksize in GB
# $2 = wget url/jigdo url
# $3 = d-i lang setting (default is 'en')
# $4 = d-i locale setting (default is 'en_us')

if [ "$1" = "" ] || [ "$2" = "" ] ; then
	echo "need two params"
	echo '# $1 = disksize in GB'
	echo '# $2 = wget url/jigdo url'
	exit 1
fi

#
# init
#
DISPLAY=localhost:$EXECUTOR_NUMBER
NAME=$(echo $JOB_NAME | cut -d "_" -f2-)
VG=jenkins01
LV=/dev/${VG}/$NAME
DISKSIZE_IN_GB=$1
URL=$2
# $3 and $4 are used below for language setting
RAMSIZE=1024
if [ "$(basename $URL)" = "netboot.tar.gz" ] ; then
	# URL is for a PXE netboot installer, rather than a CD .iso
	NETBOOT=$(pwd)/$(basename $URL)
elif [ "$(basename $URL)" != "amd64" ] ; then
	IMAGE=$(pwd)/$(basename $URL)
	IMAGE_MNT="/media/cd-$NAME.iso"
else
	KERNEL=linux
	INITRD=initrd.gz
fi

echo "Testing $NAME with $URL"
echo

#
# define workspace + results
#
rm -rf results screenshot.png screenshot-thumb.png
mkdir -p results
if [ -z "$WORKSPACE" ] ; then
	WORKSPACE=$(pwd)
fi
RESULTS=$WORKSPACE/results
mkdir -p $RESULTS
GOCR=$(mktemp)

#
# set main counter
#
NR=0

#
# language
#
if [ -z "$3" ] || [ -z "$4" ] ; then
	DI_LANG="en"
	DI_LOCALE="en_US"
else
	DI_LANG=$3
	DI_LOCALE=$4
fi

#
# video
#
VIDEOSIZE=1024x768
VIDEOBGCOLOR=gray10
FRAMERATE=24		# this is the input framerate
CONVERTOPTS="-gravity center -background $VIDEOBGCOLOR -extent $VIDEOSIZE"

#
# Debian Edu -test images usually show a screen with known problems
# if in EDUTESTMODE we'll acknowledge these
#
EDUTESTMODE=false
if [[ "$NAME" =~ ^debian-edu_.*-test.*$ ]] ; then
	EDUTESTMODE=true
fi

fetch_if_newer() {
	url="$2"
	file="$1"
	echo "Downloading $url"
	curlopts="-L -s -S"
	if [ -f "$file" ] ; then
		ls -l $file
		echo "File exists, will only re-download if a newer one is available..."
		curlopts="$curlopts -z $file"
	fi
	curl $curlopts -o $file $url
}

cleanup_all() {
	set +x
	set +e
	echo
	#
	# kill qemu
	#
	# use SIGINT for 10 seconds to encourage graceful shutdown
	for i in $(seq 1 10); do
		QEMU_PID=$(ps fax | grep [q]emu-system | grep "vnc=$DISPLAY " 2>/dev/null | awk '{print $1}')
		[ -z "$QEMU_PID" ] && break
		sudo kill -INT $QEMU_PID
		sleep 1
	done
	# force exit with SIGKILL if still running now
	QEMU_PID=$(ps fax | grep [q]emu-system | grep "vnc=$DISPLAY " 2>/dev/null | awk '{print $1}')
	[ -z "$QEMU_PID" ] || sudo kill -KILL $QEMU_PID
	sleep 0.3s
	#
	# save logs if there are any
	#
	case $NAME in
		*_rescue*|*_presentation)	;;
		*)		if [ $NR -gt 200 ] ; then
					save_logs
				else
					echo "Not trying to get logs."
				fi
				;;
	esac
	#
	# remove lvm volume
	#
	case $NAME in
	#	*debian-edu_jessie*_main-server)	echo "Warning: not deleting lvm volume $LV"
	#				;;
		*) 	sudo lvremove -f $LV
		;;
	esac
	rm -f $QEMU_LAUNCHER
	#
	# cleanup image mount
	#
	( sudo umount -l $IMAGE_MNT && rmdir $IMAGE_MNT ) 2> /dev/null &
	cd $RESULTS
	echo -n "Last screenshot: "
	(ls -t1 snapshot_??????.png || true ) | tail -1
	#
	# create video
	#
	echo "$(date -u) - Creating video now. This may take a while.'"
	TMPFILE=$(mktemp)
	avconv -r $FRAMERATE -i snapshot_%06d.png g-i-installation-$NAME.webm > $TMPFILE 2>&1 || cat $TMPFILE
	rm snapshot_??????.png $TMPFILE
	# rename .bak files back to .png
	if find . -name "*.png.bak" > /dev/null ; then
		for i in $(find * -name "*.png.bak") ; do
			mv $i $(echo $i | sed -s 's#.png.bak#.png#')
		done
	fi
	echo
	# finally
	if [ -f "$GOCR" ] ; then
		echo "Results of running /usr/bin/gocr on last screenshot:"
		echo
		cat $GOCR
		echo
	fi
}

show_preseed() {
	qemu_url="$1"
	jenkins_url="$(echo $qemu_url|sed -s 's#10\.0\.2\.1#127.0.0.1#g')"
	outside_url="$(echo $qemu_url|sed -s 's#10\.0\.2\.1#jenkins.debian.net#g')"
	echo "Preseeding from $outside_url:"
	echo
	curl -s "$jenkins_url" | grep -v ^# | grep -v "^$"
}

bootstrap_system() {
	cd $WORKSPACE
	echo "Creating throw-away logical volume with ${DISKSIZE_IN_GB} GiB now."
	# the --virtualsize option will not be needed once wheezy is not tested anymore
	sudo lvcreate --virtualsize ${DISKSIZE_IN_GB}G -L${DISKSIZE_IN_GB}G -n $NAME $VG
	echo "Creating raw disk image with ${DISKSIZE_IN_GB} GiB now."
	sudo qemu-img create -f raw $LV ${DISKSIZE_IN_GB}G
	echo "Doing g-i installation test for $NAME now."
	# qemu related variables (incl kernel+initrd) - display first, as we grep for this in the process list
	QEMU_OPTS="-display vnc=$DISPLAY -enable-kvm -cpu host"
	QEMU_WEBSERVER=http://10.0.2.1/
	QEMU_NET_OPTS="-net nic,vlan=0 -net user,vlan=0,host=10.0.2.1,dhcpstart=10.0.2.2,dns=10.0.2.254"
	# preseeding related variables
	PRESEEDCFG="preseed.cfg"
	PRESEED_PATH=d-i-preseed-cfgs
	PRESEED_URL="$QEMU_WEBSERVER/$PRESEED_PATH/${NAME}_$PRESEEDCFG"
	#
	# boot configuration
	#
	if [ -n "$NETBOOT" ]; then
		ARCH="$(ls debian-installer/)"
		GRUB_CFG="debian-installer/$ARCH/grub.cfg"
		case $NAME in
			*_kfreebsd*)	# boot the fourth menu option (Automated Install) after 3 seconds
					sed -i 's#^set default=.*#set default=3#' $GRUB_CFG
					sed -i 's#^set timeout=.*#set timeout=2#' $GRUB_CFG
					# prepend additional options
					OPTION="preseed/url" ; VALUE="$PRESEED_URL"
					sed -i "s#kfreebsd .*#set kFreeBSD.$OPTION='$VALUE'\n	\\0#" $GRUB_CFG
					# redirect d-i syslog to virtual serial port
					OPTION="preseed/early_command" ; VALUE="sed -ie s/ttyv3/cuau0/ /etc/inittab ; kill -HUP 1"
					sed -i "s#kfreebsd .*#set kFreeBSD.$OPTION='$VALUE'\n	\\0#" $GRUB_CFG
					# enable kernel logging to virtual serial port
					KERNEL_FLAGS="-D"
					sed -i "s#kfreebsd .*#\0 $KERNEL_FLAGS#" $GRUB_CFG
					;;
			*)		;;
		esac
		QEMU_NET_OPTS="$QEMU_NET_OPTS,bootfile=grub2pxe,tftp=."
	elif [ -n "$IMAGE" ] ; then
		QEMU_OPTS="$QEMU_OPTS -cdrom $IMAGE -boot d"
	        case $NAME in
			*_kfreebsd*)	;;
			*_hurd*)	QEMU_OPTS="$QEMU_OPTS -vga std"
					gzip -cd $IMAGE_MNT/boot/kernel/gnumach.gz > $WORKSPACE/gnumach
					;;
			*)		QEMU_OPTS="$QEMU_OPTS -vga std" # try to workaround lp#1318119
					QEMU_KERNEL="--kernel $IMAGE_MNT/install.amd/vmlinuz --initrd $IMAGE_MNT/install.amd/gtk/initrd.gz"
					;;
		esac
	else
		QEMU_KERNEL="--kernel $KERNEL --initrd $INITRD"
	fi
	QEMU_OPTS="$QEMU_OPTS -drive file=$LV,index=0,media=disk,cache=unsafe -serial file:$RESULTS/serial.log -m $RAMSIZE $QEMU_NET_OPTS"
	INST_LOCALE="locale=$DI_LOCALE"
	INST_KEYMAP="keymap=us"	# always us!
	INST_VIDEO="video=vesa:ywrap,mtrr vga=788"
	EXTRA_APPEND=""
	case $NAME in
		*_sid_daily*)
			EXTRA_APPEND="mirror/suite=sid"
			;;
		*)	;;
	esac
	case $NAME in
		debian_*_xfce)
			EXTRA_APPEND="$EXTRA_APPEND desktop=xfce"
			;;
		debian_*_lxde)
			EXTRA_APPEND="$EXTRA_APPEND desktop=lxde"
			;;
		debian_*_kde)
			EXTRA_APPEND="$EXTRA_APPEND desktop=kde"
			;;
		debian_*_rescue*)
			EXTRA_APPEND="$EXTRA_APPEND rescue/enable=true"
			;;
		debian-edu_*ltsp-server|debian-edu_*combi-server)
			QEMU_OPTS="$QEMU_OPTS -net nic,vlan=1 -net user,vlan=1 -soundhw es1370"
			EXTRA_APPEND="$EXTRA_APPEND netcfg/choose_interface=auto"
			;;
		*)	;;
	esac
	case $NAME in
		*_dark_theme)
			EXTRA_APPEND="$EXTRA_APPEND theme=dark"
			;;
		debian-edu_*_gnome)
			EXTRA_APPEND="$EXTRA_APPEND desktop=gnome"
			GUITERMINAL=xterm
			;;
		debian-edu_*_lxde)
			EXTRA_APPEND="$EXTRA_APPEND desktop=lxde"
			GUITERMINAL=xterm
			;;
		debian-edu_*_xfce)
			EXTRA_APPEND="$EXTRA_APPEND desktop=xfce"
			GUITERMINAL=xterm
			;;
		debian-edu_*)
			EXTRA_APPEND="$EXTRA_APPEND desktop=kde"
			GUITERMINAL=konsole
			;;
		*)	;;
	esac
	case $NAME in
		debian-edu_*)
			EXTRA_APPEND="$EXTRA_APPEND DEBCONF_DEBUG=developer"
			;;
		*_brltty)
			EXTRA_APPEND="$EXTRA_APPEND brltty=tt,ttyS0,en"
			;;
		*_speakup)
			EXTRA_APPEND="$EXTRA_APPEND speakup.synth=soft"
			QEMU_OPTS="$QEMU_OPTS -soundhw ac97"
			;;
		*_presentation)
			EXTRA_APPEND="$EXTRA_APPEND url=hands.com classes=jenkins.debian.org;talks/fosdem07"
			;;
		*)
		;;
	esac
	case $NAME in
	    debian-edu_*)
		# Debian Edu and tasksel do not work the expected way
		# with priority=critical, so do not set it.
		;;
	    *)
		EXTRA_APPEND="$EXTRA_APPEND priority=critical"
		;;
	esac
	case $NAME in
		*_presentation)
			APPEND="auto=true $EXTRA_APPEND $INST_LOCALE $INST_KEYMAP $INST_VIDEO -- quiet"
			;;
		*)
			APPEND="auto=true $EXTRA_APPEND $INST_LOCALE $INST_KEYMAP url=$PRESEED_URL $INST_VIDEO -- quiet"
			;;
	esac
	show_preseed $QEMU_WEBSERVER/$PRESEED_PATH/${NAME}_$PRESEEDCFG
	echo
	echo "Starting QEMU now:"
	QEMU_LAUNCHER=$(mktemp)
	echo "cd $WORKSPACE" > $QEMU_LAUNCHER
	echo -n "sudo qemu-system-x86_64 $QEMU_OPTS " >> $QEMU_LAUNCHER
	if [ -n "$QEMU_KERNEL" ]; then
		echo -n "$QEMU_KERNEL " >> $QEMU_LAUNCHER
	else
	        case $NAME in
			*_kfreebsd*)	;;
			*_hurd*)	# Hurd needs multiboot options jenkins can't escape correctly
					echo -n '--kernel '$WORKSPACE'/gnumach --initrd "'$IMAGE_MNT'/boot/initrd.gz \$(ramdisk-create),'$IMAGE_MNT'/boot/kernel/ext2fs.static --multiboot-command-line=\${kernel-command-line} --host-priv-port=\${host-port} --device-master-port=\${device-port} --exec-server-task=\${exec-task} -T typed gunzip:device:rd0 \$(task-create) \$(task-resume),'$IMAGE_MNT'/boot/kernel/ld.so.1 /hurd/exec \$(exec-task=task-create)" ' >> $QEMU_LAUNCHER
					APPEND="console=com0 $APPEND"
					;;
			*)		;;
		esac
	fi
	case $NAME in
		*_kfreebsd*)	# not supported for the --append option
				;;
		*)		echo "--append \"$APPEND\"" >> $QEMU_LAUNCHER
				;;
	esac
	set -x
	(bash -x $QEMU_LAUNCHER && touch $RESULTS/qemu_quit ) &
	set +x
}

boot_system() {
	cd $WORKSPACE
	echo "Booting system installed with g-i installation test for $NAME."
	# qemu related variables (incl kernel+initrd) - display first, as we grep for this in the process list
	QEMU_OPTS="-display vnc=$DISPLAY"
	case $NAME in
		# nested KVM runs gnumach horribly slowly
		*_hurd*)	;;
		*)		QEMU_OPTS="$QEMU_OPTS -enable-kvm -cpu host" ;;
	esac
	echo "Checking $LV:"
	FILE=$(sudo file -Ls $LV)
	if [ $(echo $FILE | grep -E '(x86 boot sector|DOS/MBR boot sector)' | wc -l) -eq 0 ] ; then
		echo "ERROR: no x86 boot sector found in $LV - its filetype is $FILE."
		exit 1
	fi
	QEMU_OPTS="$QEMU_OPTS -drive file=$LV,index=0,media=disk,cache=unsafe -m $RAMSIZE"
	QEMU_OPTS="$QEMU_OPTS -net nic,vlan=0 -net user,vlan=0,host=10.0.2.1,dhcpstart=10.0.2.2,dns=10.0.2.254"
	case $NAME in
		debian-edu_*ltsp-server|debian-edu_*combi-server)
				QEMU_OPTS="$QEMU_OPTS -net nic,vlan=1 -net user,vlan=1"
				;;
		*)
				;;
	esac
	echo
	echo "Starting QEMU_ now:"
	set -x
	(sudo qemu-system-x86_64 \
		$QEMU_OPTS && touch $RESULTS/qemu_quit ) &
	set +x
}

backup_screenshot() {
	# after createing the video all .png files are deleted, so we make sure to keep them...
	cp snapshot_${PRINTF_NR}.png snapshot_${PRINTF_NR}.png.bak
}

publish_screenshot() {
	# make screenshots available for the live screenshot plugin
	ln -f $PWD/snapshot_${PRINTF_NR}.png $WORKSPACE/screenshot.png
	convert $WORKSPACE/screenshot.png -adaptive-resize 128x96 $WORKSPACE/screenshot-thumb.new
}

do_and_report() {
	echo "$(date -u) $PRINTF_NR / $TOKEN - sending '$@'"
	# Workaround #758881: vncdo type command sending "e" chars sometimes not
	# received, sometimes received as if "e" key was kept pressed.
	if [ "$1" = "type" ]; then
		typestr=$2
		for i in $(seq 0 $(( ${#typestr} - 1 ))); do
			vncdo -s $DISPLAY --delay=100 key ${typestr:$i:1}
		done
	else
		vncdo -s $DISPLAY "$@"
	fi
	backup_screenshot
	publish_screenshot
}

rescue_boot() {
	# boot in rescue mode
	let MY_NR=NR-TRIGGER_NR
	TOKEN=$(printf "%04d" $MY_NR)
	case $TOKEN in
		0010)	do_and_report key tab
			;;
		0020)	do_and_report key enter
			;;
		0100)	do_and_report key tab
			;;
		0110)	do_and_report key enter
			;;
		0150)	do_and_report type df
			;;
		0160)	do_and_report key enter
			;;
		0170)	do_and_report type exit
			;;
		0200)	do_and_report key enter
			;;
		0210)	do_and_report key down
			;;
		0220)	do_and_report key enter
			;;
		*)	;;
	esac
}

presentation_boot() {
	# boot in presentation mode
	let MY_NR=NR-TRIGGER_NR
	TOKEN=$(printf "%04d" $MY_NR)
	case $TOKEN in
		[01][123456789]00)	do_and_report key enter
			;;
		*)	;;
	esac
}

post_install_boot() {
	# normal boot after installation
	let MY_NR=NR-TRIGGER_NR
	TOKEN=$(printf "%04d" $MY_NR)
	#
	# login as jenkins or root
	#
	case $NAME in
		debian_*)	case $TOKEN in
					0050)	do_and_report type jenkins
						;;
					0060)	do_and_report key enter
						;;
					0070)	do_and_report type insecure
						;;
					0080)	do_and_report key enter
						;;
					*)	;;
				esac
				;;
				# debian-edu installations differ too much, login individually
				*)	;;
	esac
	#
	# actions depending on the type of installation
	#
	case $NAME in
		debian_*xfce)	case $TOKEN in
					0200)	do_and_report key enter
						;;
					0210)	do_and_report key alt-f2
						;;
					0220)	do_and_report type "iceweasel"
						;;
					0230)	do_and_report key space
						;;
					0240)	do_and_report type "www"
						;;
					0250)	do_and_report type "."
						;;
					0260)	do_and_report type "debian"
						;;
					0270)	do_and_report type "."
						;;
					0280)	do_and_report type "org"
						;;
					0290)	do_and_report key enter
						;;
					0400)	do_and_report key alt-f2
						;;
					0410)	do_and_report type xterm
						;;
					0420)	do_and_report key enter
						;;
					0430)	do_and_report type apt-get
						;;
					0440)	do_and_report key space
						;;
					0450)	do_and_report type moo
						;;
					0500)	do_and_report key enter
						;;
					0510)	do_and_report type "su"
						;;
					0520)	do_and_report key enter
						;;
					0530)	do_and_report type r00tme
						;;
					0540)	do_and_report key enter
						;;
					0550)	do_and_report type "poweroff"
						;;
					0560)	do_and_report key enter
						;;
					*)	;;
				esac
				;;
		debian_*lxde)	case $TOKEN in
					0200)	do_and_report key alt-f2
						;;
					0220)	do_and_report type "iceweasel"
						;;
					0230)	do_and_report key space
						;;
					0240)	do_and_report type "www"
						;;
					0250)	do_and_report type "."
						;;
					0260)	do_and_report type "debian"
						;;
					0270)	do_and_report type "."
						;;
					0280)	do_and_report type "org"
						;;
					0290)	do_and_report key enter
						;;
					0400)	do_and_report key alt-f2
						;;
					0410)	do_and_report type lxterminal
						;;
					0420)	do_and_report key enter
						;;
					0430)	do_and_report type apt-get
						;;
					0440)	do_and_report key space
						;;
					0450)	do_and_report type moo
						;;
					0520)	do_and_report key enter
						;;
					0530)	do_and_report type "su"
						;;
					0540)	do_and_report key enter
						;;
					0550)	do_and_report type r00tme
						;;
					0560)	do_and_report key enter
						;;
					0570)	do_and_report type "poweroff"
						;;
					0580)	do_and_report key enter
						;;
					*)	;;
				esac
				;;
		debian_*kde)	case $TOKEN in
					0300)	do_and_report key tab
						;;
					0310)	do_and_report key enter
						;;
					0400)	do_and_report key alt-f2
						;;
					0410)	do_and_report type "konqueror"
						;;
					0420)	do_and_report key space
						;;
					0430)	do_and_report type "www"
						;;
					0440)	do_and_report type "."
						;;
					0450)	do_and_report type "debian"
						;;
					0460)	do_and_report type "."
						;;
					0470)	do_and_report type "org"
						;;
					0480)	do_and_report key enter
						;;
					0600)	do_and_report key alt-f2
						;;
					0610)	do_and_report type konsole
						;;
					0620)	do_and_report key enter
						;;
					0700)	do_and_report type apt-get
						;;
					0710)	do_and_report key space
						;;
					0720)	do_and_report type moo
						;;
					0730)	do_and_report key enter
						;;
					0740)	do_and_report type "su"
						;;
					0750)	do_and_report key enter
						;;
					0760)	do_and_report type r00tme
						;;
					0770)	do_and_report key enter
						;;
					0780)	do_and_report type "poweroff"
						;;
					0790)	do_and_report key enter
						;;
					*)	;;
				esac
				;;
		debian_*gnome*)	case $TOKEN in
					0150)	do_and_report move 530 420 click 1
						;;
					0200)	do_and_report key alt-f2
						;;
					0210)	do_and_report type "iceweasel"
						;;
					0230)	do_and_report key space
						;;
					0240)	do_and_report type "www"
						;;
					0250)	do_and_report type "."
						;;
					0260)	do_and_report type "debian"
						;;
					0270)	do_and_report type "."
						;;
					0280)	do_and_report type "org"
						;;
					0290)	do_and_report key enter
						;;
					0400)	do_and_report key alt-f2
						;;
					0410)	do_and_report type gnome
						;;
					0420)	do_and_report type "-"
						;;
					0430)	do_and_report type terminal
						;;
					0440)	do_and_report key enter
						;;
					0450)	do_and_report type apt-get
						;;
					0460)	do_and_report key space
						;;
					0470)	do_and_report type moo
						;;
					0520)	do_and_report key enter
						;;
					0530)	do_and_report type "su"
						;;
					0540)	do_and_report key enter
						;;
					0550)	do_and_report type r00tme
						;;
					0560)	do_and_report key enter
						;;
					0570)	do_and_report type "poweroff"
						;;
					0580)	do_and_report key enter
						;;
					*)	;;
				esac
				;;
		debian-edu*minimal)	case $TOKEN in
						# debian-edu installations report error found during installation, go forward in text mode
						0180)	! $EDUTESTMODE || do_and_report key tab
							;;
						0220)	! $EDUTESTMODE || do_and_report key enter
							;;
						0250)	do_and_report type jenkins
							;;
						0260)	do_and_report key enter
							;;
						0270)	do_and_report type insecure
							;;
						0280)	do_and_report key enter
							;;
						0300)	do_and_report type ps
							;;
						0310)	do_and_report key space
							;;
						0320)	do_and_report type fax
							;;
						0330)	do_and_report key enter
							;;
						0340)	do_and_report type df
							;;
						0350)	do_and_report key enter
							;;
						0360)	do_and_report type apt-get
							;;
						0370)	do_and_report key space
							;;
						0380)	do_and_report type moo
							;;
						0400)	do_and_report key enter
							;;
						0420)	do_and_report type "su"
							;;
						0430)	do_and_report key enter
							;;
						0440)	do_and_report type r00tme
							;;
						0450)	do_and_report key enter
							;;
						0460)	do_and_report type poweroff
							;;
						0470)	do_and_report key enter
							;;
						*)	;;
					esac
					;;
		debian-edu*main-server)	case $TOKEN in
						# debian-edu installations report error found during installation, go forward, in text mode
						0200)	! $EDUTESTMODE || do_and_report key tab
							;;
						0250)	! $EDUTESTMODE || do_and_report key enter
							;;
						0350)	do_and_report type root
							;;
						0400)	do_and_report key enter
							;;
						0410)	do_and_report type r00tme
							;;
						0420)	do_and_report key enter
							;;
						0550)	do_and_report type ps
							;;
						0560)	do_and_report key space
							;;
						0570)	do_and_report type fax
							;;
						0580)	do_and_report key enter
							;;
						0590)	do_and_report type df
							;;
						0600)	do_and_report key enter
							;;
						0610)	do_and_report type apt-get 	# apt-get moo
							;;
						0620)	do_and_report key space
							;;
						0630)	do_and_report type moo
							;;
						0640)	do_and_report key enter
							;;
						0650)	do_and_report type ip
							;;
						0660)	do_and_report key space
							;;
						0670)	do_and_report type a
							;;
						0680)	do_and_report key enter
							;;
						0690)	do_and_report type ping
							;;
						0700)	do_and_report key space
							;;
						0710)	do_and_report type '-'
							;;
						0720)	do_and_report type 'c'
							;;
						0730)	do_and_report key space
							;;
						0740)	do_and_report type '2'
							;;
						0750)	do_and_report key space
							;;
						0760)	do_and_report type '8.8.8.8'
							;;
						0770)	do_and_report key enter
							;;
						0800)	do_and_report type route
							;;
						0810)	do_and_report key space
							;;
						0820)	do_and_report type '-'
							;;
						0830)	do_and_report type 'n'
							;;
						0840)	do_and_report key enter
							;;
						0850)	do_and_report type apt-get 	# apt-get install w3m
							;;
						0860)	do_and_report key space
							;;
						0870)	do_and_report type '-y'
							;;
						0880)	do_and_report key space
							;;
						0890)	do_and_report type install
							;;
						0900)	do_and_report key space
							;;
						0910)	do_and_report type w3m
							;;
						0920)	do_and_report key enter
							;;
						1000)	do_and_report type w3m 		# check nagios
							;;
						1010)	do_and_report key space
							;;
						1020)	do_and_report type 'https;'
							;;
						1030)	do_and_report type '//www'
							;;
						1040)	do_and_report type '/nagios'
							;;
						1050)	do_and_report key enter
							;;
						1090)	do_and_report type q
							;;
						1100)	do_and_report key enter
							;;
						1010)	do_and_report type w3m		# check cups
							;;
						1120)	do_and_report key space
							;;
						1130)	do_and_report type 'https;'
							;;
						1150)	do_and_report type '//www'
							;;
						1170)	do_and_report type ';631'
							;;
						1180)	do_and_report key enter
							;;
						1250)	do_and_report type q
							;;
						1270)	do_and_report key enter
							;;
						1330)	do_and_report type poweroff	# poweroff
							;;
						1340)	do_and_report key enter
							;;
						*)	;;
					esac
					;;
		debian-edu*ltsp-server|debian-edu*-combi-server) case $TOKEN in
						# debian-edu installations report error found during installation, go forward
						0100)	! $EDUTESTMODE || do_and_report move 760 560 click 1
							;;
						0300)	do_and_report type jenkins
							;;
						0350)	do_and_report key enter
							;;
						0360)	do_and_report type insecure
							;;
						0370)	do_and_report key enter
							;;
						0400)	do_and_report key tab
							;;
						0410)	do_and_report key enter
							;;
						0500)	do_and_report key alt-f2
							;;
						0510)	do_and_report type "iceweasel"
							;;
						0520)	do_and_report key space
						       ;;
						0530)	do_and_report type "www"
						       ;;
						0540)	do_and_report type "."
						       ;;
						0550)	do_and_report type "debian"
						       ;;
						0560)	do_and_report type "."
						       ;;
						0570)	do_and_report type "org"
						       ;;
						0580)	do_and_report key enter
						       ;;
						0700)	do_and_report key alt-f2
						       ;;
						0710)	do_and_report type $GUITERMINAL
						       ;;
						0720)	do_and_report key enter
						       ;;
						0800)	do_and_report type apt-get
						       ;;
						0810)	do_and_report key space
						       ;;
						0820)	do_and_report type moo
						       ;;
						0830)	do_and_report key enter
						       ;;
						0840)	do_and_report type "su"
						       ;;
						0850)	do_and_report key enter
						       ;;
						0860)	do_and_report type r00tme
						       ;;
						0870)	do_and_report key enter
						       ;;
						0880)	do_and_report type "poweroff"
						       ;;
						0890)	do_and_report key enter
							;;
						*)	;;
					esac
					;;
		debian-edu*workstation)	case $TOKEN in
						# debian-edu installations report error found during installation, go forward
						0100)	! $EDUTESTMODE || do_and_report move 760 560 click 1
							;;
						0150)	do_and_report type jenkins
							;;
						0160)	do_and_report key enter
							;;
						0170)	do_and_report type insecure
							;;
						0180)	do_and_report key enter
							;;
						*)	;;
					esac
					;;
		debian-edu*standalone*)	case $TOKEN in
					# debian-edu installations report error found during installation, go forward
						0100)	! $EDUTESTMODE || do_and_report move 760 560 click 1
							;;
						0110)	do_and_report type jenkins
							;;
						0120)	do_and_report key enter
							;;
						0130)	do_and_report type insecure
							;;
						0140)	do_and_report key enter
							;;
						0200)	do_and_report key tab
							;;
						0300)	do_and_report key enter
							;;
						0350)	do_and_report key alt-f2
							;;
						0410)	do_and_report type "iceweasel"
							;;
						0420)	do_and_report key space
							;;
						0430)	do_and_report type "www"
							;;
						0440)	do_and_report type "."
							;;
						0450)	do_and_report type "debian"
							;;
						0460)	do_and_report type "."
							;;
						0470)	do_and_report type "org"
							;;
						0480)	do_and_report key enter
							;;
						0600)	do_and_report key alt-f2
							;;
						0610)	do_and_report type $GUITERMINAL
							;;
						0620)	do_and_report key enter
							;;
						0700)	do_and_report type apt-get
							;;
						0710)	do_and_report key space
							;;
						0720)	do_and_report type moo
							;;
						0730)	do_and_report key enter
							;;
						0740)	do_and_report type "su"
							;;
						0750)	do_and_report key enter
							;;
						0760)	do_and_report type r00tme
							;;
						0770)	do_and_report key enter
							;;
						0780)	do_and_report type "poweroff"
							;;
						0790)	do_and_report key enter
							;;
						*)	;;
					esac
					;;
		*)		;;
	esac
}


monitor_system() {
	MODE=$1
	# if TRIGGER_MODE is set to a number, triggered mode will be entered in that many steps - else an image match needs to happen
	TRIGGER_MODE=$2
	TRIGGER_NR=0
	# use default valule for timeout if none given
	if [ -z "$3" ] ; then
		TIMEOUT=600
	else
		TIMEOUT=$3
	fi
	if [ -z "$4" ] ; then
		PIXELDIFF=100
	else
		PIXELDIFF=$4
	fi
	cd $RESULTS
	sleep 4	# chosen by fair dice roll
	hourlimit=16 # hours
	echo "Taking screenshots every 2 seconds now, until qemu ends for whatever reasons or $hourlimit hours have passed or if the test seems to hang."
	echo
	timelimit=$(( $hourlimit * 60 * 60 / 2 ))
	let MAX_RUNS=NR+$timelimit
	while [ $NR -lt $MAX_RUNS ] ; do
		#
		# break if qemu-system has finished
		#
		if ! ps fax | grep [q]emu-system | grep "vnc=$DISPLAY " >/dev/null; then
			touch $RESULTS/qemu_quit
			break
		fi
		PRINTF_NR=$(printf "%06d" $NR)
		vncsnapshot -quiet -allowblank -compresslevel 0 $DISPLAY snapshot_${PRINTF_NR}.jpg 2>/dev/null || true
		if [ -f snapshot_${PRINTF_NR}.jpg ]; then
			convert $CONVERTOPTS snapshot_${PRINTF_NR}.jpg snapshot_${PRINTF_NR}.png
			rm snapshot_${PRINTF_NR}.jpg
		else
			echo "$(date -u) $PRINTF_NR          - could not take vncsnapshot from $DISPLAY - using a blank fake one instead"
			convert -size $VIDEOSIZE xc:#000000 -depth 8 snapshot_${PRINTF_NR}.png
		fi
		# every 100 ticks take a screenshot and analyse it
		if [ $(($NR % 100)) -eq 0 ] ; then
			# press ctrl-key regularily to avoid screensaver kicking in
			vncdo -s $DISPLAY key ctrl || true
			# publish it
			publish_screenshot
			#
			# search for known text using ocr of screenshot and break out of this loop if certain content is found
			#
			# gocr likes black background
			convert -fill black -opaque $VIDEOBGCOLOR snapshot_${PRINTF_NR}.png $GOCR.png
			gocr $GOCR.png > $GOCR
			LAST_LINE=$(tail -1 $GOCR |cut -d "]" -f2- || true)
			STACK_LINE=$(egrep "(Call Trace|end trace)" $GOCR || true)
			INVALID_SIG_LINE=$(grep "Invalid Release signature" $GOCR || true)
			CDROM_PROBLEM=$(grep "There was a problem reading data from the CD-ROM" $GOCR || true)
			INSTALL_PROBLEM=$(egrep "(nstallation step fail|he failing step i)"  $GOCR || true)
			ROOT_PROBLEM=$(egrep "(Giue root password for maintenance|or type Control-D to continue)"  $GOCR || true)
			BUILD_LTSP_PROBLEM=$(grep "The failing step is: Build LTSP chroot" $GOCR || true)
			echo >> $GOCR
			rm $GOCR.png
			if [[ "$LAST_LINE" =~ .*Power\ down.* ]] ||
			    [[ "$LAST_LINE" =~ .*System\ halted.* ]] ||
			    [[ "$LAST_LINE" =~ .*Reached\ target\ Shutdown.* ]] ||
			    [[ "$LAST_LINE" =~ .*Cannot\ .inalize\ remaining\ .ile\ systems.* ]]; then
				echo "QEMU was powered down." >> $GOCR
				break
			elif [ ! -z "$STACK_LINE" ] ; then
				echo "INFO: got a stack-trace, probably on power-down." >> $GOCR
				break
			elif [ ! -z "$INVALID_SIG_LINE" ] ; then
				echo "ERROR: Invalid Release signature found, aborting." >> $GOCR
				exit 1
			elif [ ! -z "$CDROM_PROBLEM" ] ; then
				echo "ERROR: Loading installer components from CDROM failed, aborting." >> $GOCR
				exit 1
			elif [ ! -z "$INSTALL_PROBLEM" ] ; then
				echo "ERROR: An installation step failed." >> $GOCR
				exit 1
			elif [ ! -z "$ROOT_PROBLEM" ] ; then
				echo "ERROR: System is hanging at boot and waiting for root maintenance." >> $GOCR
				exit 1
			elif [ ! -z "$BUILD_LTSP_PROBLEM" ] ; then
				echo "ERROR: The failing step is: Build LTSP chroot." >> $GOCR
				exit 1
			fi
		elif [ $(($NR % 30)) -eq 0 ] ; then
			# give signal we are still running
			echo "$(date -u) $PRINTF_NR / $TOKEN"
			publish_screenshot
		fi
		# in install mode, every 300 ticks preserve an screenshot as artefact
		if [ "$MODE" = "install" ] && [ $(($NR % 300)) -eq 0 ] ; then
			backup_screenshot
		fi
		# every 100 screenshots, starting from the $TIMEOUTth one...
		if [ $(($NR % 100)) -eq 0 ] && [ $NR -gt $TIMEOUT ] ; then
			# from help let: "Exit Status: If the last ARG evaluates to 0, let returns 1; let returns 0 otherwise."
			let OLD=NR-$TIMEOUT
			PRINTF_OLD=$(printf "%06d" $OLD)
			# test if this screenshot is basically the same as the one $TIMEOUT screenshots ago
			# $PIXELDIFF pixels difference between to images is tolerated, to ignore updating clocks
			PIXEL=$(compare -metric AE snapshot_${PRINTF_NR}.png snapshot_${PRINTF_OLD}.png /dev/null 2>&1 || true )
			# usually this returns an integer, but not always....
			if [[ "$PIXEL" =~ ^[0-9]+$ ]] ; then
				echo "$PIXEL pixel difference between snapshot_${PRINTF_NR}.png and snapshot_${PRINTF_OLD}.png"
				if [ $PIXEL -lt $PIXELDIFF ] ; then
				    SAME=Y
				    for INTER in $(seq $OLD 10 $NR); do
					PRINTF_INTER=$(printf "%06d" $INTER)
					PIXEL=$(compare -metric AE snapshot_${PRINTF_NR}.png snapshot_${PRINTF_INTER}.png /dev/null 2>&1 || true )
					if [[ "$PIXEL" =~ ^[0-9]+$ ]] ; then
						if [ $PIXEL -ge $PIXELDIFF ] ; then
							echo "but $PIXEL difference between snapshot_${PRINTF_NR}.png and snapshot_${PRINTF_INTER}.png"
							SAME=N
							break
						fi
					else
						echo "but snapshot_${PRINTF_NR}.png and snapshot_${PRINTF_INTER}.png have different sizes."
						SAME=N
						break
					fi
				    done
				    if [ $SAME = Y ]
				    then
					# unless TRIGGER_MODE is empty, matching images means its over
					if [ ! -z "$TRIGGER_MODE" ] ; then
						echo "Warning: snapshot_${PRINTF_NR}.png snapshot_${PRINTF_OLD}.png match or almost match, ending installation."
						ls -la snapshot_${PRINTF_NR}.png snapshot_${PRINTF_OLD}.png
						echo "System in $MODE mode is hanging."
						if [ "$MODE" = "install" ] ; then
							# hanging install = broken install
							backup_screenshot
							exit 1
						fi
						break
					else
						# this is only reached once in rescue mode
						# and the next matching screenshots will cause a failure...
						TRIGGER_MODE="already_matched"
						# really kick off trigger:
						let TRIGGER_NR=NR
					fi
				    fi
				fi
			else
				echo "snapshot_${PRINTF_NR}.png and snapshot_${PRINTF_OLD}.png have different sizes."
			fi
		fi
		# let's drive this further (once/if triggered)
		if [ $TRIGGER_NR -ne 0 ] && [ $TRIGGER_NR -ne $NR ] ; then
			case $MODE in
				rescue)		rescue_boot
						;;
				presentation)	presentation_boot
						;;
				post_install)	post_install_boot
						;;
				*)		;;
			esac
		fi
		# if TRIGGER_MODE matches NR, we are triggered too
		if [ ! -z "$TRIGGER_MODE" ] && [ "$TRIGGER_MODE" = "$NR" ] ; then
			let TRIGGER_NR=NR
		fi
		let NR=NR+1
		sleep 2
	done
	if [ $NR -eq $MAX_RUNS ] ; then
		echo "Warning: running for ${hourlimit}h, forcing termination."
	fi
	if [ -f "$RESULTS/qemu_quit" ] ; then
		rm $RESULTS/qemu_quit
	fi
	if [ ! -f snapshot_${PRINTF_NR}.png ] ; then
		let NR=NR-1
		PRINTF_NR=$(printf "%06d" $NR)
	fi
	backup_screenshot
	publish_screenshot
}

save_logs() {
	#
	# get logs and other files from the installed system
	#
	cd $WORKSPACE
	SYSTEM_MNT=/media/$NAME
	sudo mkdir -p $SYSTEM_MNT
	FAILURE=false
	# workaround problem in guestmount in wheezy: -o uid doesnt work:
	# "sudo guestmount -o uid=$(id -u) -o gid=$(id -g)" would be nicer, but it doesnt work: as root, the files seem to belong to jenkins, but as jenkins they cannot be accessed
	sudo guestmount -a $LV -i --ro $SYSTEM_MNT || { echo "Warning: cannot mount filesystems from $LV" ; export FAILURE=true ; }
	#
	# copy logs (and continue if some logs cannot be copied)
	#
	sudo cp -rv $SYSTEM_MNT/var/log $SYSTEM_MNT/etc/fstab $RESULTS/ || { echo "Warning: cannot get logs from installed system." ; echo "Did the installation finish correctly?" ; export FAILURE=true ; }
	#
	# get list of installed packages
	#
	case $NAME in
		*_kfreebsd*|*_hurd*)
			;;
		*)
			sudo chroot $SYSTEM_MNT dpkg -l > $RESULTS/dpkg-l || { echo "Warning: cannot run dpkg inside the installed system, did the installation finish correctly?" ; export FAILURE=true ; }
			#
			# check for must installed packages
			#
			case $NAME in
				*_brltty)
					grep brltty $RESULTS/dpkg-l || { echo "Warning: package brltty not installed." ; export FAILURE=true ; }
					;;
				*_speakup)
					grep espeakup $RESULTS/dpkg-l || { echo "Warning: package espeakup not installed." ; export FAILURE=true ; }
					;;
				*)
				;;
			esac
			;;
	esac

	#
	# only on combi-servers and ltsp-servers:
	#	mount /opt
	#	copy LTSP logs and package list
	#	unmount /opt
	#
	case $NAME in debian-edu_*ltsp-server|debian-edu_*combi-server)	mkdir -p $RESULTS/log/opt
						if [ -d $SYSTEM_MNT/opt/ltsp/amd64 ] ; then
							LTSPARCH="amd64"
						elif [ -d $SYSTEM_MNT/opt/ltsp/i386 ] ; then
							LTSPARCH="i386"
						else
							echo "Warning: no LTSP chroot found."
						fi
						if [ ! -z "$LTSPARCH" ] ; then
							sudo cp -rv $SYSTEM_MNT/opt/ltsp/$LTSPARCH/var/log $RESULTS/log/opt/
							sudo chroot $SYSTEM_MNT/opt/ltsp/$LTSPARCH dpkg -l > $RESULTS/log/opt/dpkg-l || { echo "Warning: cannot run dpkg inside the ltsp chroot." ; sudo ls -la $SYSTEM_MNT/opt/ltsp/$LTSPARCH ; export FAILURE=true ; }
						fi
						;;
		*)				;;
	esac
	#
	# umount guests (debian-edu uses many mountpoints...)
	#
	#for MP in var/log var/ usr/ boot/ opt/ home/ debianedufreespace/ skole/tjener/home0 var/opt/ltsp/swapfiles skole/backup/ var/spool/squid3/ ; do
	#	sudo umount -l $SYSTEM_MNT/$MP 2>/dev/null || true
	#done
	sudo umount -l $SYSTEM_MNT || { echo "Warning: cannot un-mount $SYSTEM_MNT" ; export FAILURE=true ; }
	#
	# make sure we can read everything after installation
	#
	sudo chown -R jenkins:jenkins $RESULTS/log/
	#
	# finally delete the mountpoint again
	#
	sudo rmdir $SYSTEM_MNT
	#
	# cry out lout, if...
	#
	if $FAILURE ; then
		figlet "failure"
	fi
}

trap cleanup_all INT TERM EXIT

#
# install image preparation
#
if [ ! -z "$NETBOOT" ] ; then
	#
	# if there is a netboot installer tarball...
	#
	fetch_if_newer "$NETBOOT" "$URL"
	sha256sum "$NETBOOT"
	# try to extract, otherwise clean up and abort
	if ! tar -zxvf "$NETBOOT" ; then
		echo "tarball seems corrupt;  deleting it"
		rm -f "$NETBOOT"
		exit 1
	fi
elif [ ! -z "$IMAGE" ] ; then
	#
	# if there is a CD image...
	#
	fetch_if_newer "$IMAGE" "$URL"
	# is this really an .iso?
	if [ $(file "$IMAGE" | grep -cE '(ISO 9660|DOS/MBR boot sector)') -eq 1 ] ; then
		# yes, so let's md5sum and mount it
		md5sum $IMAGE
		sudo mkdir -p $IMAGE_MNT
		grep -q $IMAGE_MNT /proc/mounts && sudo umount -l $IMAGE_MNT
		sleep 1
		sudo mount -o loop,ro $IMAGE $IMAGE_MNT
	else
		# something went wrong
		figlet "no .iso"
		echo "ERROR: no valid .iso found"
		if [ $(file "$IMAGE" | grep -c "HTML document") -eq 1 ] ; then
			mv "$IMAGE" "$IMAGE.html"
			lynx --dump "$IMAGE.html"
			rm "$IMAGE.html"
		fi
		exit 1
	fi
else
	#
	# else netboot gtk
	#
	fetch_if_newer "$KERNEL" "$URL/$KERNEL"
	fetch_if_newer "$INITRD" "$URL/$INITRD"
fi

#
# run g-i
#
bootstrap_system
set +x
case $NAME in
	*_rescue*)	 			monitor_system rescue
						;;
	*_presentation)	 			monitor_system presentation 10
						;;
	debian-edu_*ltsp-server|debian-edu_*combi-server)	monitor_system install wait4match 3000 100 1200
						;;
	debian-edu_*wheezy*standalone*)		monitor_system install wait4match 1200 100
						;;
	*)					monitor_system install wait4match
						;;
esac
#
# boot up installed system
#
let NR=NR+1
case $NAME in
	*_rescue*|*_presentation)	# so there are some artifacts to publish
			mkdir -p $RESULTS/log/installer
			touch $RESULTS/log/dummy $RESULTS/log/installer/dummy
			;;
	*)		#
			# kill qemu and image
			#
			set -x
			TOKILL=$(ps fax | grep [q]emu-system | grep "vnc=$DISPLAY " 2>/dev/null | awk '{print $1}')
			if [ ! -z "$TOKILL" ] ; then
				sudo kill -9 "$TOKILL" || true
			fi
			set +x
			if [ ! -z "$IMAGE" ] ; then
				sudo umount -l $IMAGE_MNT || true
			fi
			echo "Sleeping 15 seconds."
			sleep 15
			boot_system
			case $NAME in
				debian-edu_*test*server)	let START_TRIGGER=NR+600
								;;
				*_kfreebsd*)			let START_TRIGGER=NR+200
								;;
				*)				let START_TRIGGER=NR+80
								;;
			esac
			monitor_system post_install $START_TRIGGER 600 1000
esac
cleanup_all

# don't cleanup twice
trap - INT TERM EXIT

