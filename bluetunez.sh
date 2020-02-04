#!/bin/bash

set -e
# set -x

HOSTNAME=bluetunez
FRIENDLY=BlueTuneZ
# RPI_MODEL=
# DAC_MODEL=
RPI_MODEL=raspberrypi
DAC_MODEL=hifiberry-dacplus


###############################################################
###                                                         ###
###   !!! YOU SHOULD NOT NEED TO EDIT BELOW THIS LINE !!!   ###
###                                                         ###
###############################################################


# default configuration options
OPT_WITHOUT_NETWORKING=true
OPT_WITHOUT_HDMI=true
OPT_QUIET=true

usage() {
	echo
	echo "usage: $0 --rpi=... --dac=... [--with-net] [--with-hdmi] [-v|--verbose]"
	echo
	echo "  --rpi       : the raspberrypi board to use (required)"
	echo "  --dac       : the audio dac to use (required)"
	echo "  --with-net  : enable networking support and run dhcp on eth0 (optional; disabled by default)"
	echo "  --with-hdmi : enable hdmi display (optional; disabled by default)"
	echo "  --verbose   : enable boot console logging (optional; disabled by default)"
	echo
	echo "example: $0 --rpi=raspberrypi --dac=hifiberry-dacplus"
	echo
	exit 0
}

# do we have the required args?
for arg in "$@"; do
	case "$arg" in
		--rpi=*)
		RPI_MODEL="${arg:6}"
		;;
		--dac=*)
		DAC_MODEL="${arg:6}"
		;;
		--with-net*)
		OPT_WITHOUT_NETWORKING=false
		;;
		--with-hdmi)
		OPT_WITHOUT_HDMI=false
		;;
		-v|--verbose)
		OPT_QUIET=false
		;;
		-h|--help|--usage)
		usage
		;;
	esac
done
([ -z "$RPI_MODEL" ] || [ -z "$DAC_MODEL" ]) && usage


###############################################################
# 
# global vars
#

export HOSTNAME FRIENDLY RPI_MODEL DAC_MODEL

export BTZ_BASEDIR=$(dirname $(realpath $0))
export BR2_BASEDIR=$BTZ_BASEDIR/buildroot
export BR2_SDCARD_IMG=$BR2_BASEDIR/output/images/sdcard.img

export PROGRAM=bluetunez
export PROGRAM_DIR=$BTZ_BASEDIR/$PROGRAM

export BR2_RPI_DEFCONFIG=$BR2_BASEDIR/configs/${RPI_MODEL}_defconfig
export BR2_DEFCONFIG=$BR2_BASEDIR/configs/${PROGRAM}_defconfig
export BR2_CONFIG=$BR2_BASEDIR/.config
export BR2_CONFIG_D=$PROGRAM_DIR/buildroot

export BUSYBOX_CONFIG=$PROGRAM_DIR/busybox.config
export BUSYBOX_CONFIG_D=$PROGRAM_DIR/busybox

export LINUX_CONFIG=$PROGRAM_DIR/linux.config
export LINUX_CONFIG_D=$PROGRAM_DIR/linux

function _merge() {
	local a=$1
	local b=$2
	local key=
	local val=
	# 1) sed      : strip comments + lines starting with a space + append empty newline at eof
	# 2) envsubst : substitute exported vars
	# 3) while    : loop over key=val pairs (splitting on '=' via IFS env var)
	# sed -e '/^[# ]/d' -e '$a\' $b \
	sed -e '/^[# ]/d;$a\' $b \
		| envsubst \
		| while IFS='=' read key val; do

			# escape backslashes to not interfere with sed
			val=$(echo $val | sed -e 's/\//\\\//g')

			# source: https://stackoverflow.com/a/15966279
			# 
			# matches:
			#  - # $key is not set
			#  - $key=...
			#
			# sets:
			#  - $key=$val
			#
			# appends '\n$key=$val' to last line if not found
			#
			sed -i -e "/^\(# $key is not set\|$key=\).*$/{s//$key=$val/;h};\${x;/./{x;q0};x;s/.*/\0\n$key=$val/}" $a

		done
}


function _bootstrap() {

	if [ -d $BR2_BASEDIR ]; then
		echo "Abort - attempting to bootstrap with an existing buildroot folder !!!"
		exit 1
	fi

	local VERSIONS_URL=https://buildroot.org/download.html
	local GIT_URL=git://git.buildroot.net/buildroot
	local VERSION_LTS=
	local VERSION_STABLE=
		
	# FIXME eval is evil !
	eval $(wget -O - $VERSIONS_URL 2>/dev/null \
		| awk "/Latest (stable|long term support) release: <b>[^>]+<\/b>/ { print }" \
		| sed -e 's/long term support/lts/' \
		| sed -e 's/.*\(lts\|stable\) release: <b>\([^<]*\)<\/b>.*/VERSION_\U\1=\2/g')
	
	if [ -z VERSION_LTS ] || [ -z VERSION_STABLE ]; then
		echo "Error getting the latest Buildroot version numbers from $VERSIONS_URL"
		exit 1
	fi

	# TODO mgb: add more cli args
	# 
	# --buildroot-dir=/path/to/buildroot : ...
	# --buildroot-stable                 : uses latest stable version (default)
	# --buildroot-lts	                 : uses latest long term support version
	# --buildroot-git				     : uses latest development version
	# --buildroot=xxxx.xx.x              : uses version xxxx.xx.xx (must be a valid git tag) 

	local GIT_TAG=$VERSION_STABLE
	git clone $GIT_URL $BR2_BASEDIR
	git -C $BR2_BASEDIR checkout $GIT_TAG
}


function _make() {
	make -C $BR2_BASEDIR $@
}


function _make_defconfig() {
	[ -f $BR2_CONFIG ] && rm -f $BR2_CONFIG
	_make ${1}_defconfig
	_merge $BR2_CONFIG $BR2_CONFIG_D/cache.config
}


function _configure() {

	# establish the rpi defconfig
	_make_defconfig ${RPI_MODEL}


	###############################################################
	#
	# Linux
	#

	# copy the default linux config from the source tree
	_make linux-extract
	local LINUX_DEFCONFIG=$(grep BR2_LINUX_KERNEL_DEFCONFIG $BR2_RPI_DEFCONFIG | sed -e "s/BR2_LINUX_KERNEL_DEFCONFIG=\"\(.*\)\"/\1/")	
	find $BR2_BASEDIR/output/build/linux-custom/arch/ -iname ${LINUX_DEFCONFIG}_defconfig -exec cp {} $LINUX_CONFIG \;
	
	# merge our customizations
	                           _merge $LINUX_CONFIG $LINUX_CONFIG_D/default.config
	$OPT_WITHOUT_NETWORKING && _merge $LINUX_CONFIG $LINUX_CONFIG_D/without-networking.config
	$OPT_WITHOUT_HDMI       && _merge $LINUX_CONFIG $LINUX_CONFIG_D/without-hdmi.config
	$OPT_QUIET              && _merge $LINUX_CONFIG $LINUX_CONFIG_D/quiet.config


	###############################################################
	# 
	# Busybox
	#

	# copy the default config from the package source tree
	_make busybox-extract
	find $BR2_BASEDIR/package/busybox -iname busybox.config -exec cp {} $BUSYBOX_CONFIG \;

	# apply our customizations
	                           _merge $BUSYBOX_CONFIG $BUSYBOX_CONFIG_D/default.config
	$OPT_WITHOUT_NETWORKING && _merge $BUSYBOX_CONFIG $BUSYBOX_CONFIG_D/without-networking.config


	###############################################################
	# 
	# Buildroot
	#

	# copy the default rpi config
	cp $BR2_RPI_DEFCONFIG $BR2_DEFCONFIG

	# export args placeholder for merge
	                     BTZ_ROOTFS_POST_SCRIPT_ARGS="--overlay=$DAC_MODEL"
	$OPT_WITHOUT_HDMI && BTZ_ROOTFS_POST_SCRIPT_ARGS="$BTZ_ROOTFS_POST_SCRIPT_ARGS --without-hdmi"
	$OPT_QUIET        && BTZ_ROOTFS_POST_SCRIPT_ARGS="$BTZ_ROOTFS_POST_SCRIPT_ARGS --quiet"
	              export BTZ_ROOTFS_POST_SCRIPT_ARGS

	# apply our customizations
	                           _merge $BR2_DEFCONFIG $BR2_CONFIG_D/default.config
	$OPT_WITHOUT_NETWORKING && _merge $BR2_DEFCONFIG $BR2_CONFIG_D/without-networking.config
	$OPT_WITHOUT_HDMI       && _merge $BR2_DEFCONFIG $BR2_CONFIG_D/without-hdmi.config

	# establish our generated "program" config
	_make_defconfig ${PROGRAM}


	###############################################################
	# 
	# SD Card
	#

	# we have to run the post scripts from our "program" directory to make use of our custom genimage.cfg
	cp "$BR2_BASEDIR/board/$RPI_MODEL/post-build.sh" "$PROGRAM_DIR/post-build.sh"
	cp "$BR2_BASEDIR/board/$RPI_MODEL/post-image.sh" "$PROGRAM_DIR/rpi-post-image.sh"
	# we include the rpi-firmware/overlays/ directory in the genimage.cfg
	# these are filtered by our post-image.sh script based on --overlay command line arguments
	sed -e "s/^\(\s*\)\"zImage\"/\1\"rpi-firmware\/overlays\",\n\1\"zImage\"/" \
		"$BR2_BASEDIR/board/$RPI_MODEL/genimage-${RPI_MODEL}.cfg" \
		> "$PROGRAM_DIR/genimage-${PROGRAM}.cfg"
}


function _install() {
	local dev=$1
	echo
	echo "Installing to device $dev ..."
	echo
	sudo dd if=$BR2_SDCARD_IMG of=$dev bs=1M conv=sync
}


###############################################################
# 
# main()
#

OPT_DO_BOOTSTRAP=false
OPT_DO_CONFIGURE=false
OPT_DO_MAKE=false
OPT_DO_CLEAN=false
OPT_DO_DISTCLEAN=false
OPT_DO_INSTALL=false
OPT_DO_INSTALL_DEV=

for arg in "$@"; do
	case "$arg" in
		--bootstrap)
		OPT_DO_BOOTSTRAP=true
		;;
		--configure)
		OPT_DO_CONFIGURE=true
		;;
		--make)
		OPT_DO_MAKE=true
		;;
		--clean)
		OPT_DO_CLEAN=true
		;;
		--distclean)
		OPT_DO_DISTCLEAN=true
		;;
		--install=*)
		OPT_DO_INSTALL=true
		OPT_DO_INSTALL_DEV="${arg:10}"
		;;
	esac
done

# use --install but missing sdcard.img? 
# add --make
$OPT_DO_INSTALL && ($OPT_DO_DISTCLEAN || $OPT_DO_CLEAN || [ ! -f $BR2_SDCARD_IMG ]) && OPT_DO_MAKE=true

# use --make but missing .config? 
# add --configure
$OPT_DO_MAKE && ($OPT_DO_DISTCLEAN || $OPT_DO_CLEAN || [ ! -f $BR2_CONFIG ]) && OPT_DO_CONFIGURE=true

# use --configure but missing the buildroot dir? 
# add --bootstrap
$OPT_DO_CONFIGURE && [ ! -d $BR2_BASEDIR ] && OPT_DO_BOOTSTRAP=true

# ignore double cleans
$OPT_DO_DISTCLEAN && OPT_DO_CLEAN=false

# ignore cleans if bootstraping
$OPT_DO_BOOTSTRAP && OPT_DO_CLEAN=false
$OPT_DO_BOOTSTRAP && OPT_DO_DISTCLEAN=false

($OPT_DO_BOOTSTRAP || $OPT_DO_DISTCLEAN || $OPT_DO_CLEAN || $OPT_DO_CONFIGURE || $OPT_DO_MAKE ||  $OPT_DO_INSTALL) && (

	                             CLI_ARGS="--rpi=$RPI_MODEL --dac=$DAC_MODEL"
	! $OPT_WITHOUT_NETWORKING && CLI_ARGS="$CLI_ARGS --with-networking"
	! $OPT_WITHOUT_HDMI       && CLI_ARGS="$CLI_ARGS --with-hdmi"
	! $OPT_QUIET              && CLI_ARGS="$CLI_ARGS --verbose"
	$OPT_DO_BOOTSTRAP         && CLI_ARGS="$CLI_ARGS --bootstrap"
	$OPT_DO_DISTCLEAN         && CLI_ARGS="$CLI_ARGS --distclean"
	$OPT_DO_CLEAN             && CLI_ARGS="$CLI_ARGS --clean"
	$OPT_DO_CONFIGURE         && CLI_ARGS="$CLI_ARGS --configure"
	$OPT_DO_MAKE              && CLI_ARGS="$CLI_ARGS --make"
	$OPT_DO_INSTALL           && CLI_ARGS="$CLI_ARGS --install=$OPT_DO_INSTALL_DEV"

	echo 
	echo "$FRIENDLY"
	echo 
	echo "$0 $CLI_ARGS"
	echo

	$OPT_DO_BOOTSTRAP && _bootstrap
	$OPT_DO_CLEAN     && _make clean
	$OPT_DO_DISTCLEAN && _make distclean
	$OPT_DO_CONFIGURE && _configure
	$OPT_DO_MAKE      && _make
	$OPT_DO_INSTALL   && _install $OPT_DO_INSTALL_DEV

	echo
	echo "$FRIENDLY"
	echo
	echo "$0 $CLI_ARGS"
	echo
	echo "Took 0s"
	echo

	exit 0

) || usage
