#/bin/bash
#
# Copyright (C) 2019, Renesas Electronics Europe GmbH, Chris Paterson
# <chris.paterson2@renesas.com>
#
# This script takes a given architecture and configuration and installs the
# required compiler and builds the Kernel with it, ready for testing.
#
# Compiler installation influenced from the work done by Hiramatsu-san at:
# https://github.com/mhiramat/linux-cross
#
# Script specific dependencies:
# wget uname nproc make tar pwd sed
#
################################################################################

set -ex

################################################################################
WORK_DIR=`pwd`
GCC_VER="8.1.0"
COMPILER_BASE_URL="https://cdn.kernel.org/pub/tools/crosstool/files/bin"
COMPILER_INSTALL_DIR="$WORK_DIR/gcc"
TMP_DIR="$WORK_DIR/tmp"
MODULE_INSTALL_DIR="$TMP_DIR/modules"
OUTPUT_DIR="$WORK_DIR/output"
JOBS_LIST="$OUTPUT_DIR/$CI_JOB_NAME.jobs"
################################################################################
CPUS=`nproc`
HOST_ARCH=`uname -m`
if [ -z "$BUILD_ONLY" ]; then BUILD_ONLY=false; fi
################################################################################

set_up () {
	mkdir -p $TMP_DIR
	mkdir -p $COMPILER_INSTALL_DIR
	mkdir -p $MODULE_INSTALL_DIR
	mkdir -p $OUTPUT_DIR
}

clean_up () {
	rm -rf $TMP_DIR
	rm -rf $MODULE_INSTALL_DIR
}

clean_build () {
	make mrproper
}

configure_special_cases () {
	case "$CONFIG" in
		"shmobile_defconfig")
			# This config prefers uImage
			BUILD_FLAGS="$BUILD_FLAGS LOADADDR=0x40008000"
			IMAGE_TYPE="uImage"
			;;
		"renesas_shmobile_defconfig")
			# This config prefers uImage
			BUILD_FLAGS="$BUILD_FLAGS LOADADDR=0x40008000"
			IMAGE_TYPE="uImage"
			;;
		"siemens_am335x-dxr2_defconfig")
			# Install power management firmware
			wget -q http://arago-project.org/git/projects/?p=am33x-cm3.git\;a=blob_plain\;f=bin/am335x-pm-firmware.bin\;hb=HEAD -O firmware/am335x-pm-firmware.bin
			echo "CONFIG_EXTRA_FIRMWARE_DIR=\"firmware\"" >> arch/$BUILD_ARCH/configs/$CONFIG
			;;
		"siemens_am335x-draco_defconfig")
			# Install power management firmware
			wget -q http://arago-project.org/git/projects/?p=am33x-cm3.git\;a=blob_plain\;f=bin/am335x-pm-firmware.bin\;hb=HEAD -O firmware/am335x-pm-firmware.bin
			echo "CONFIG_EXTRA_FIRMWARE_DIR=\"firmware\"" >> arch/$BUILD_ARCH/configs/$CONFIG
			;;
		"siemens_am335x-etamin_defconfig")
			# Install power management firmware
			wget -q http://arago-project.org/git/projects/?p=am33x-cm3.git\;a=blob_plain\;f=bin/am335x-pm-firmware.bin\;hb=HEAD -O firmware/am335x-pm-firmware.bin
			echo "CONFIG_EXTRA_FIRMWARE_DIR=\"firmware\"" >> arch/$BUILD_ARCH/configs/$CONFIG
			;;
	esac
}

configure_kernel () {
	if [ -z "$CONFIG" ]; then
		echo "No config provided. Using \"defconfig\"."
		CONFIG="defconfig"
	fi

	case "$CONFIG_LOC" in
		"")
			echo "No config location provided. Assuming \"intree\"..."
			# Fall-through to "intree"
			;&

		"intree")
			configure_special_cases
			;;

		"cip-kernel-config")
			# Update repo
			cd /opt/cip-kernel-config
			git fetch origin
			git reset --hard origin/master
			cd -

			# Check provided config is there
			local ver=`make kernelversion | sed -e 's/\.[^\.]*$//'`
			if [ ! $(find /opt/cip-kernel-config/$ver -name "$CONFIG") ]; then
				echo "Error: Provided configuration not present	in cip-kernel-configs"
				clean_up
				exit 1
			fi

			# Copy config
			cp /opt/cip-kernel-config/$ver/$BUILD_ARCH/$CONFIG arch/$BUILD_ARCH/configs/

			configure_special_cases
			;;

		"url")
			# Download config
			if [ -z $CONFIG_URL ]; then
				echo "No config URL provided"
				clean_up
				exit 1
			fi

			wget -q -P arch/$BUILD_ARCH/configs/ $CONFIG_URL/$CONFIG
			if [ $? -ne 0 ]; then
				echo "Error: Config file download failure"
				clean_up
				exit 1
			fi

			# Configure special cases. Obviously this is on the luck
			# that the config names match up.
			# TODO: Add another way to configure BUILD_FLAGS etc.,
			# probably by board rather than config.
			configure_special_cases
			;;
	esac

	make $BUILD_FLAGS $CONFIG

	get_kernel_name
}

get_kernel_name () {
	# Work out Kernel version
	local sha=`git log --pretty=format:"%h" -1`
	local version=`make kernelversion`

	# Check for local version
	for localversionfile in localversion*; do
		if [ -f "$localversionfile" ]; then
			local localversion=`cat $localversionfile`
			version=${version}${localversion}
		fi
	done
	version=${version}_${sha}

	# Define Kernel image name
	KERNEL_NAME=$IMAGE_TYPE_$CONFIG_$version
}

build_modules () {
	# Make sure install environment is clean
	rm -rf $TMP_DIR/modules.tar.gz
	rm -rf $MODULE_INSTALL_DIR

	make $BUILD_FLAGS modules
	make $BUILD_FLAGS modules_install INSTALL_MOD_PATH=$MODULE_INSTALL_DIR

	# Package up for distribution
	tar -C ${MODULE_INSTALL_DIR} -czf $TMP_DIR/modules.tar.gz lib
}

build_dtbs () {
	make $BUILD_FLAGS dtbs
}

build_kernel () {
	make $BUILD_FLAGS $IMAGE_TYPE

	if grep -qc "CONFIG_MODULES=y" .config; then
		build_modules
	fi

	if $BUILD_DTBS; then
		build_dtbs
	fi
}

# TODO: Make sure docker image installs the compilers as well
install_compiler () {
	local ext=".tar.gz"
	local url="https://cdn.kernel.org/pub/tools/crosstool/files/bin"
	local gcc_file="$HOST_ARCH-gcc-$GCC_VER-nolibc-$GCC_NAME$ext"

	wget -q -P $TMP_DIR/ $url/$HOST_ARCH/$GCC_VER/$gcc_file
	if [ $? -ne 0 ]; then
		echo "Error: Compiler download failure"
		clean_up
		exit 1
	fi

	tar xf $TMP_DIR/$gcc_file -C $COMPILER_INSTALL_DIR
}

configure_compiler () {
	local compiler_exec=($COMPILER_INSTALL_DIR/gcc-*/${GCC_NAME}/bin/${GCC_NAME}-gcc)
	[[ -x $compiler_exec ]] || install_compiler

	BUILD_FLAGS="-j$CPUS ARCH=$BUILD_ARCH CROSS_COMPILE=${compiler_exec%gcc}"
}

configure_arch () {
	case "$BUILD_ARCH" in
		"arm")
			GCC_NAME="arm-linux-gnueabi"
			IMAGE_TYPE="zImage"
			BUILD_DTBS=true
			;;
		"arm64")
			GCC_NAME="aarch64-linux"
			IMAGE_TYPE="Image"
			BUILD_DTBS=true
			;;
		"x86")
			GCC_NAME="i386-linux"
			IMAGE_TYPE="bzImage"
			BUILD_DTBS=false
			;;
		"")
			echo "Error: No target architecture provided"
			clean_up
			exit 1
			;;
		*)
			echo "Error: Target architecture not supported"
			clean_up
			exit 1
			;;
	esac
}

configure_build () {
	configure_arch
	configure_compiler
	configure_kernel
}


# Parameters
# $1 - Version
# $2 - Architecture
# $3 - Kernel configuration
# $4 - Device to be tested (device-type as defined in LAVA)
# $5 - Kernel to be tested
# $6 - Device tree to be tested
# $7 - Kernel modules to be tested
add_test_job () {
	# Check if modules file actually exists
	if [ -f $OUTPUT_DIR/$7 ]; then
		echo $1 $2 $3 $4 $5 $6 $7 >> $JOBS_LIST
	else
		echo $1 $2 $3 $4 $5 $6 >> $JOBS_LIST
	fi
}

# Note: If there are multiple jobs in the same pipeline building the same SHA,
# same ARCH and same CONFIG _name_, AWS binaries will be overwritten by
# submit_tests.sh.
copy_output () {
	local bin_dir=$KERNEL_NAME/$BUILD_ARCH/$CONFIG

	# Kernel
	mkdir -p $OUTPUT_DIR/$bin_dir/kernel
	cp arch/$BUILD_ARCH/boot/$IMAGE_TYPE $OUTPUT_DIR/$bin_dir/kernel

	# TODO: Copy Kernel configuration

	# Modules
	if [ -f "$TMP_DIR/modules.tar.gz" ]; then
		mkdir -p $OUTPUT_DIR/$bin_dir/modules
		cp $TMP_DIR/modules.tar.gz $OUTPUT_DIR/$bin_dir/modules
	fi

	if $BUILD_ONLY; then
		# Copy any/all device trees
		if [ ! -z "$DTBS" ]; then
			# Convert $DTBS into an array
			local dtbs=($DTBS)
			mkdir -p $OUTPUT_DIR/$bin_dir/dtb

			for i in "${!dtbs[@]}"; do
				cp ${dtbs[$i]} $OUTPUT_DIR/$bin_dir/dtb
			done
		fi

		# Return successful as we're happy to build without testing.
		return 0
	fi

	if [ $BUILD_ARCH == "x86" ]; then
		# Convert $DEVICES into an array
		devices=($DEVICES)

		# Add job for each device
		for i in "${!devices[@]}"; do
			add_test_job \
				$KERNEL_NAME \
				$BUILD_ARCH \
				$CONFIG \
				${devices[$i]} \
				$bin_dir/kernel/$IMAGE_TYPE \
				"N/A" \
				$bin_dir/modules/modules.tar.gz
		done
	else
		# Device tree
		if [ -z "$DTBS" ]; then
			echo "No device trees defined, so cannot test."
			return 1
		fi

		if [ -z "$DEVICES" ]; then
			echo "No devices defined, so cannot test."
			return 1
		fi

		mkdir -p $OUTPUT_DIR/$bin_dir/dtb

		# Convert $DTBS into an array
		dtbs=($DTBS)

		# Convert $DEVICES into an array
		devices=($DEVICES)

		# Check there is a dtb for each defined device
		if [ "${#devices[@]}" -ne "${#dtbs[@]}" ]; then
			echo "Number of devices does not equal the number of dtbs."
			clean_up
			exit 1
		fi

		# Add job for each device/dtb combo
		for i in "${!dtbs[@]}"; do
			local dtb_name=`echo "${dtbs[$i]}" | sed "s/.*\///"`
			cp ${dtbs[$i]} $OUTPUT_DIR/$bin_dir/dtb

			add_test_job \
				$KERNEL_NAME \
				$BUILD_ARCH \
				$CONFIG \
				${devices[$i]} \
				$bin_dir/kernel/$IMAGE_TYPE \
				$bin_dir/dtb/$dtb_name \
				$bin_dir/modules/modules.tar.gz
		done
	fi
}


trap clean_up SIGHUP SIGINT SIGTERM
set_up

# TODO: Add support for multiple Kernel configs (it is quicker to build them in
# the same job, rather than build from scratch each time).
################################################################################
# Run the below for each configuration you want to build
configure_build
build_kernel
copy_output
################################################################################

clean_up
