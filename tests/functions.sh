#
# Copyright (C) 2007 Karel Zak <kzak@redhat.com>
#
# This file is part of util-linux-ng.
#
# This file is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This file is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#

TS_OUTDIR="output"
TS_DIFFDIR="diff"
TS_EXPECTEDDIR="expected"
TS_INPUTDIR="input"
TS_VERBOSE="no"

. ./commands.sh

function ts_skip {
	echo " IGNORE ($1)"
	if [ -n "$2" -a -b "$2" ]; then
		ts_device_deinit "$2"
	fi
	exit 0
}

function ts_skip_nonroot {
	if [ $UID -ne 0 ]; then
		ts_skip "not root permissions"
	fi
}

function ts_failed {
	if [ x"$1" == x"" ]; then
		echo " FAILED ($TS_NS)"
	else
		echo " FAILED ($1)"
	fi
	exit 1
}

function ts_ok {
	if [ x"$1" == x"" ]; then
		echo " OK"
	else
		echo " OK ($1)"
	fi
	exit 0
}

function ts_log {
	echo "$1" >> $TS_OUTPUT
	[ "$TS_VERBOSE" == "yes" ] && echo "$1"
}

function ts_has_option {
	NAME="$1"
	ALL="$2"
	echo -n $ALL | sed 's/ //g' | $AWK 'BEGIN { FS="="; RS="--" } /('$NAME'$|'$NAME'=)/ { print "yes" }'
}

function ts_init {
	local is_fake

	export LANG="en_US.UTF-8":

	TS_VERBOSE=$( ts_has_option "verbose" "$*")
	is_fake=$( ts_has_option "fake" "$*")

	TS_SCRIPT="$0"
	TS_SUBDIR=$(dirname $TS_SCRIPT)
	TS_TESTNAME=$(basename $TS_SCRIPT)
	TS_COMPONENT=$(basename $TS_SUBDIR)

	TS_NS="$TS_COMPONENT/$TS_TESTNAME"
	TS_SELF="$TS_SUBDIR"

	TS_OUTPUT="$TS_OUTDIR/$TS_NS"
	TS_DIFF="$TS_DIFFDIR/$TS_NS"
	TS_EXPECTED="$TS_EXPECTEDDIR/$TS_NS"
	TS_MOUNTPOINT="$(pwd)/$TS_OUTDIR/${TS_NS}_mnt"

	TS_HAS_VOLUMEID="no"

	BLKID_FILE="$TS_OUTDIR/${TS_NS}.blkidtab"

	[ ! -d "$(dirname $TS_OUTPUT)" ] && mkdir -p $(dirname $TS_OUTPUT)
	[ ! -d "$(dirname $TS_DIFF)" ] && mkdir -p $(dirname $TS_DIFF)

	declare -a TS_SUID_PROGS
	declare -a TS_SUID_USER
	declare -a TS_SUID_GROUP

	export BLKID_FILE

	if [ -x $TS_CMD_MOUNT ]; then
		ldd $TS_CMD_MOUNT | grep -q 'libvolume_id' &> /dev/null
		if [ "$?" == "0" ]; then
			TS_HAS_VOLUMEID="yes"
		fi
	fi

	rm -f $TS_OUTPUT
	touch $TS_OUTPUT

	printf "%15s: %-25s ..." "$TS_COMPONENT" "$TS_DESC"

	if [ "$TS_VERBOSE" == "yes" ]; then
		echo
		echo "     script: $TS_SCRIPT"
		echo "    top dir: $TS_TOPDIR"
		echo "    sub dir: $TS_SUBDIR"
		echo "       self: $TS_SELF"
		echo "  test name: $TS_TESTNAME"
		echo "  test desc: $TS_DESC"
		echo "  component: $TS_COMPONENT"
		echo "  namespace: $TS_NS"
		echo "    verbose: $TS_VERBOSE"
		echo "     output: $TS_OUTPUT"
		echo "   expected: $TS_EXPECTED"
		echo " mountpoint: $TS_MOUNTPOINT"
		echo
	fi

	[ "$is_fake" == "yes" ] && ts_skip "fake mode"

}

function ts_init_suid {
	PROG="$1"
	ct=${#TS_SUID_PROGS[*]}

	# Save info about original setting
	TS_SUID_PROGS[$ct]=$PROG
	TS_SUID_USER[$ct]=$(stat --printf="%U" $PROG)
	TS_SUID_GROUP[$ct]=$(stat --printf="%G" $PROG)

	chown root.root $PROG &> /dev/null
	chmod u+s $PROG &> /dev/null
}

function ts_finalize {
	local res=0

	for idx in $(seq 0 $((${#TS_SUID_PROGS[*]} - 1))); do
		PROG=${TS_SUID_PROGS[$idx]}
		chmod a-s $PROG &> /dev/null
		chown ${TS_SUID_USER[$idx]}.${TS_SUID_GROUP[$idx]} $PROG &> /dev/null
	done

	if [ -s $TS_EXPECTED ]; then
		if [ -s $TS_OUTPUT ]; then
			diff -u $TS_EXPECTED $TS_OUTPUT > $TS_DIFF
			if [ -s $TS_DIFF ]; then
				res=1
			fi
		else
			res=1
		fi
	else
		echo " IGNORE (expected output undefined)"
		exit 0
	fi
	if [ $res -eq 0 ]; then
		ts_ok $1
	else
		ts_failed $1
	fi
}

function ts_die {
	ts_log "$1"
	if [ -n "$2" ] && [ -b "$2" ]; then
		ts_device_deinit "$2"
		ts_fstab_clean		# for sure... 
	fi
	ts_finalize
}

function ts_device_init {
	local IMAGE="$TS_OUTDIR/${TS_NS}.img"
	local DEV=""

	dd if=/dev/zero of="$IMAGE" bs=1M count=5 &> /dev/null

	DEV=$($TS_CMD_LOSETUP -s -f "$IMAGE")

	if [ -z "$DEV" ]; then
		ts_device_deinit $DEV
		return 1		# error
	fi

	echo $DEV
	return 0			# succes
}



function ts_device_deinit {
	local DEV="$1"

	if [ -b "$DEV" ]; then
		$TS_CMD_UMOUNT "$DEV" &> /dev/null
		$TS_CMD_LOSETUP -d "$DEV" &> /dev/null
	fi
}

function ts_udev_dev_support {
	if [ "$TS_HAS_VOLUMEID" == "yes" ] && [ ! -L "/dev/disk/$1/$2" ]; then
		return 1
	fi
	return 0
}

function ts_uuid_by_devname {
	local DEV="$1"
	local UUID=""
	if [ -x "$TS_ECMD_BLKID" ]; then
		UUID=$($TS_ECMD_BLKID -c /dev/null -w /dev/null -s "UUID" $DEV | sed 's/.*UUID="//g; s/"//g')
	elif [ -x "$TS_ECMD_VOLID" ]; then
		UUID=$($TS_ECMD_VOLID -u $DEV)
	fi
	echo $UUID
}

function ts_label_by_devname {
	local DEV="$1"
	local TYPE=""
	if [ -x "$TS_ECMD_BLKID" ]; then
		LABEL=$($TS_ECMD_BLKID -c /dev/null -w /dev/null -s "LABEL" $DEV | sed 's/.*LABEL="//g; s/"//g')
	elif [ -x "$TS_ECMD_VOLID" ]; then
		LABEL=$($TS_ECMD_VOLID -l $DEV)
	fi
	echo $LABEL
}

function ts_fstype_by_devname {
	local DEV="$1"
	local TYPE=""
	if [ -x "$TS_ECMD_BLKID" ]; then
		TYPE=$($TS_ECMD_BLKID -c /dev/null -w /dev/null -s "TYPE" $DEV | sed 's/.*TYPE="//g; s/"//g')
	elif [ -x "$TS_ECMD_VOLID" ]; then
		TYPE=$($TS_ECMD_VOLID -t $DEV)
	fi
	echo $TYPE
}

function ts_device_has {
	local TAG="$1"
	local VAL="$2"
	local DEV="$3"
	local vl=""

	case $TAG in
		"TYPE") vl=$(ts_fstype_by_devname $DEV);;
		"LABEL") vl=$(ts_label_by_devname $DEV);;
		"UUID") vl=$(ts_uuid_by_devname $DEV);;
		*) return 1;;
	esac

	if [ "$vl" == "$VAL" ]; then
		return 0
	fi
	return 1
}

function ts_device_has_uuid {
	ts_uuid_by_devname "$1" | egrep -q '^[0-9a-z]{8}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{12}$'
	return $?
}

function ts_is_mounted {
	local DEV=$1

	grep -q $DEV /proc/mounts && return 0

	if [ "${DEV#/dev/loop/}" != "$DEV" ]; then
		return grep -q "/dev/loop${DEV#/dev/loop/}" /proc/mounts
	fi
	return 1
}

function ts_swapoff {
	local DEV="$1"

	# swapoff doesn't exist in build tree
	if [ ! -x "$TS_CMD_SWAPOFF" ]; then
		ln -sf $TS_CMD_SWAPON $TS_CMD_SWAPOFF
		REMSWAPOFF="true"
	fi
	$TS_CMD_SWAPOFF $DEV 2>&1 >> $TS_OUTPUT
	if [ -n "$REMSWAPOFF" ]; then
		rm -f $TS_CMD_SWAPOFF
	fi
}

function ts_fstab_open {
	echo "# <!-- util-linux-ng test entry" >> /etc/fstab
}

function ts_fstab_close {
	echo "# -->" >> /etc/fstab
}

function ts_fstab_addline {
	local SPEC="$1"
	local MNT=${2:-"$TS_MOUNTPOINT"}
	local FS=${3:-"auto"}
	local OPT=${4:-"defaults"}

	echo "$SPEC   $MNT   $FS   $OPT   0   0" >> /etc/fstab
}

function ts_fstab_add {
	ts_fstab_open
	ts_fstab_addline $*
	ts_fstab_close
}

function ts_fstab_clean {
	sed --in-place "
/# <!-- util-linux-ng/!b
:a
/# -->/!{
  N
  ba
}
s/# <!-- util-linux-ng.*-->//;
/^$/d" /etc/fstab
}

