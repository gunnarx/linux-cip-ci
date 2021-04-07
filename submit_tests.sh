#!/bin/bash -x
# Copyright (C) 2019, Renesas Electronics Europe GmbH, Chris Paterson
# <chris.paterson2@renesas.com>
#
# Copyright (C) 2019 GENIVI Alliance
# Gunnar Andersson, <gandersson@genivi.org>
# Modifications to include build-id in test definition and a few
# other tweaks.  (Because we have system images as the test 
# than only the kernel)
#
# This script scans the OUTPUT_DIR for any built Kernels/systems
# and creates/submits the relevant test jobs to the CIP LAVA master.
#
# Script specific dependencies:
# lavacli pwd sed date
#
# The following must be set by CI or scripts before this script is called, for
# lavacli to work:
# $CIP_LAVA_LAB_USER
# $CIP_LAVA_LAB_TOKEN
#
# Other global variables
# $TEST_TIMEOUT: Length of time in minutes to wait for test completion. If
#                unset a default of 30 minutes is used.
# $SUBMIT_ONLY: Set to 'true' if you don't want to wait to see if submitted LAVA
#               jobs complete. If this is not set a default of 'false' is used.
#
################################################################################

set -e

################################################################################
WORK_DIR=`pwd`
OUTPUT_DIR="$WORK_DIR/output"
TEMPLATE_DIR="$WORK_DIR/lava_templates"

################################################################################

# input parameters are:
# ./gocd_submit_android_test.sh aasigdp_vts_test_with_flashing aasig-docker 38   
# these are forwarded to this script submit_tests "$1" "$2" "$3" "$4"
# so....
# $1 = template name
# $2 = pipline name
# $3 = pipeline counter

# For us, source is always a local file URL
URL_UP="sftp:///docs.projects.genivi.org/artifacts"
# This is the location that the GoCD job will place the files at -- must match!j
# build_result /artifacts/${GO_PIPELINE_NAME}_${GO_PIPELINE_COUNTER}
SFTP_PATH="/media/genivi_sftp/artifacts/$2_$3"
URL_DOWN="file://$SFTP_PATH"

env
LAVACLI_ARGS="--uri https://$CIP_LAVA_LAB_USER:$CIP_LAVA_LAB_TOKEN@lava.genivi.org/RPC2"
INDEX="0"
if [ -z "$TEST_TIMEOUT" ]; then TEST_TIMEOUT=30; fi
if [ -z "$SUBMIT_ONLY" ]; then SUBMIT_ONLY=false; fi
################################################################################

set_up () {
	TMP_DIR="$(mktemp -d)"
}

clean_up () {
  if [ -z "$lavacli_job_numbers" ] ; then
    for n in cat $lavacli_job_numbers ; then
      echo "Cancelling job number $n..."
      echo "+ lavacli $LAVACLI_ARGS jobs cancel $1"
      ret=$(lavacli $LAVACLI_ARGS jobs cancel $1)
      echo "... retval=$ret"
  fi
  #rm -rf $TMP_DIR
}

get_template () {
	TEMPLATE="${TEMPLATE_DIR}/${DEVICE}_${1}.yaml"
}

create_job () {
	local testname="$1"
	get_template $testname

	local url_down="$URL_DOWN/$pipeline_id"
	local dtb_url="$url_down/$(basename $DTB)"
	local kernel_url="$url_down/$(basename $KERNEL)"
	if [ ! -z "$MODULES" ]; then
		local modules_url="$url_down/$(basename $MODULES)"
	fi
	local rootfs_url="$url_down/rootfs.tar.bz2"
    local android_results_path="$SFTP_PATH/build_result"
	# FIXME:
	local android_vts_zip="android-vts-10.0_r29.zip"

	if $USE_DTB; then
		local job_name="${VERSION}_${ARCH}_${CONFIG}_${DTB_NAME}_${testname}"
	else
		local job_name="${VERSION}_${ARCH}_${CONFIG}_${testname}"
	fi

	local job_definition="$TMP_DIR/${INDEX}_${job_name}.yaml"
	INDEX=$((INDEX+1))

	cp $TEMPLATE $job_definition

	sed -i "s|JOB_NAME|$job_name|g" $job_definition
	if [ ! -z "$MODULES" ]; then
		sed -i "/DTB_URL/ a \    modules:\n      url: $modules_url\n      compression: gz" $job_definition
	fi
	if $USE_DTB; then
		sed -i "s|DTB_URL|$dtb_url|g" $job_definition
	fi
	sed -i "s|KERNEL_URL|$kernel_url|g" $job_definition
	sed -i "s|ROOTFS_URL|$rootfs_url|g" $job_definition
	sed -i "s|ARTIFACTS_PATH|$android_results_path|g" $job_definition
	sed -i "s|ANDROID_VTS_ZIP|$android_vts_zip|g" $job_definition
}

# Parameters:  $1 = path to root file system tarball
#	sed -i "s|ROOTFS_LOCATION|$build_id/rootfs.tar.bz2|g" $job_definition

upload_binaries () {
	# Note: If there are multiple jobs in the same pipeline building the
	# same SHA, same ARCH and same CONFIG _name_, then binaries will be
	# overwritten.
    local ROOTFS="$1"
    local KERNEL="$2"
    local DTB="$3"
    if [ ! -f "$ROOTFS" ] ; then
      echo "upload_binaries: Specified root file system tarball does not exist!"
      echo "($ROOTFS)"
      echo "Stopping."
      exit 2
    fi

    cat <<END_OF_COMMANDS | sftp -i /var/go/.ssh/id_rsa go_artifact_upload@docs.projects.genivi.org:artifacts
mkdir $GO_PIPELINE_NAME
mkdir $GO_PIPELINE_NAME/$GO_PIPELINE_COUNTER
cd $GO_PIPELINE_NAME/$GO_PIPELINE_COUNTER
put "$ROOTFS" rootfs.tar.bz2
put "$KERNEL" kernel.bin
put "$DTB" this.dtb
END_OF_COMMANDS

}

print_kernel_info () {
	echo "Job Found"
	echo "----------"
	echo "Version: $VERSION"
	echo "Arch: $ARCH"
	echo "Config: $CONFIG"
	echo "Device: $DEVICE"
	echo "Kernel: $KERNEL_NAME"
	echo "DTB: $DTB_NAME"
	echo "Modules: $MODULES_NAME"
	echo "----------"
}

# JOBS_FILE should be structured with space separated values as below, one job
# per line:
# VERSION ARCH CONFIG KERNEL DEVICE_TREE MODULES
# MODULES is optional
find_jobs () {
	# Make sure there is at least one job file
	if [ `find "$OUTPUT_DIR" -maxdepth 1 -name "*.jobs" -printf '.' |  wc -c` -eq 0 ]; then
		echo "No jobs found"
		clean_up
		# Quit cleanly as technically there is nothing wrong, it's just
		# that either no builds were successful or none that wanted
		# testing.
		exit 0
	fi

	# Process job files
	for jobfile in $OUTPUT_DIR/*.jobs; do
		# Filter out commented lines and empty lines...
		sed '/^#./d' < $jobfile | \
		while read version pipeline_id arch config device kernel device_tree modules; do
			VERSION=$version
			ARCH=$arch
			CONFIG=$config
			DEVICE=$device
			KERNEL=$kernel
			DTB=$device_tree
			MODULES=$modules
            echo "MODULES is $modules"

			if [ "$DTB" == "N/A" ]; then
				USE_DTB=false
			else
				USE_DTB=true
			fi

			# Get filename from path
			KERNEL_NAME=`echo "$KERNEL" | sed "s/.*\///"`
			MODULES_NAME=`echo "$MODULES" | sed "s/.*\///"`
			if $USE_DTB; then
				DTB_NAME=`echo "$DTB" | sed "s/.*\///"`
			fi

			print_kernel_info
			create_job $1
		done
	done
}

submit_job() {
	# TODO: Add yaml validation
        # Make sure yaml file exists
	if [ -f "$1" ]; then
		echo "Submitting $1 to LAVA master..."
		# Catch error that occurs if invalid yaml file is submitted
        ret=$(lavacli $LAVACLI_ARGS jobs submit $1)
        rv=$?

        if [[ $ret != [0-9]* || $rv -ne 0 ]]
        then
          echo "Something went wrong with job submission. LAVA returned:"
          echo "${ret}, rv=$rv"
          exit 4
        else
			echo "Job submitted successfully as job number #${ret}."
			local lavacli_output=$TMP_DIR/lavacli_output
			export lavacli_job_numbers=$TMP_DIR/lavacli_job_numbers
            echo ${ret} >>$lavacli_job_numbers
			lavacli $LAVACLI_ARGS jobs show ${ret} \
				> $lavacli_output

			local status=`cat $lavacli_output \
				| grep "state" \
				| cut -d ":" -f 2 \
				| awk '{$1=$1};1'`
			STATUS[${ret}]=$status

			local device_type=`cat $lavacli_output \
				| grep "device-type" \
				| cut -d ":" -f 2 \
				| awk '{$1=$1};1'`
			DEVICE_TYPE[${ret}]=$device_type

			local device=`cat $lavacli_output \
				| grep "device      :" \
				| cut -d ":" -f 2 \
				| awk '{$1=$1};1'`
			DEVICE[${ret}]=$device

			local test=`cat $lavacli_output \
				| grep "description" \
				| rev | cut -d "_" -f 1 | rev`
			TEST[${ret}]=$test

			JOBS+=(${ret})
		fi
	fi
}


submit_jobs () {
	for JOB in $TMP_DIR/*.yaml; do
		submit_job $JOB
	done
}

check_if_all_finished() {
        for i in "${JOBS[@]}"
        do
                if [ "${STATUS[$i]}" != "Finished" ]; then
                        return 1
                fi
        done
        return 0
}

print_current_status () {
	echo "------------------------------"
	echo "Current job status:"
	echo "------------------------------"
	for i in "${JOBS[@]}"; do
		echo "Job #$i: ${STATUS[$i]}"
		echo "  Device Type: ${DEVICE_TYPE[$i]}"
		echo "  Device: ${DEVICE[$i]}"
		echo "  Test: ${TEST[$i]}"
	done
}

check_status () {
	# Current time + timeout time
	local end_time=`date +%s -d "+ $TEST_TIMEOUT min"`
	local error=false

	if [ ${#JOBS[@]} -ne 0 ]
	then
		print_current_status

		while true
		do
			# Get latest status
			for i in "${JOBS[@]}"
			do
				if [ "${STATUS[$i]}" != "Finished" ]
				then
					local lavacli_output=$TMP_DIR/lavacli_output
					echo lavacli $LAVACLI_ARGS jobs show $i \
						> $lavacli_output

					local status=`cat $lavacli_output \
						| grep "state" \
						| cut -d ":" -f 2 \
						| awk '{$1=$1};1'`
echo DEBUG: lavacli_output is:
echo ==========================
cat $lavacli_output
echo ==========================

					local device_type=`cat $lavacli_output \
						| grep "device-type" \
						| cut -d ":" -f 2 \
						| awk '{$1=$1};1'`
					DEVICE_TYPE[$i]=$device_type

					local device=`cat $lavacli_output \
						| grep "device      :" \
						| cut -d ":" -f 2 \
						| awk '{$1=$1};1'`
					DEVICE[$i]=$device

					if [ "${STATUS[$i]}" != "$status" ]; then
						STATUS[$i]=$status

						# Something has changed
						print_current_status
					else
						STATUS[$i]=$status
					fi
                else
                  echo "Status is not Finished, it is: ${STATUS[$i]}"
                fi
			done

			if check_if_all_finished; then
				break
			fi

			# Check timeout
			local now=$(date +%s)
			if [ $now -ge $end_time ]; then
				echo "Timed out waiting for test jobs to complete"
				error=true
				break
			fi

			# Small wait to avoid spamming the server too hard
			sleep 10
		done

		if check_if_all_finished; then
			# Print job outcome
			for i in "${JOBS[@]}"
			do
				local ret=`echo lavacli $LAVACLI_ARGS \
					jobs show $i \
					| grep Health \
					| cut -d ":" -f 2 \
					| awk '{$1=$1};1'`
				echo "Job #$i completed. Job health: $ret"

				if [ ${ret} != "Complete" ]; then
					error=true
				fi
			done
		fi
	fi

	if $error; then
		echo "*** Errors during testing"
		echo "*** Check this URL for details https://lava.genivi.org/scheduler/job/$i"
		clean_up
		exit 1
	fi

	echo "All testing completed"
}


trap clean_up SIGHUP SIGINT SIGTERM
set_up
# Base name of template (excluding other variable things like ARCH/CONFIG/DEVICE/...)
# e.g. for r8a7796-m3ulcb_genivi_image_test.yaml, TEMPLATE_IDENTIFIER is: genivi_image_test
TEMPLATE_IDENTIFIER="$1"
find_jobs $TEMPLATE_IDENTIFIER
# NOTE - this variant of the script requires the root filesystem tarball path
# to be specified as first parameter:

# Upload done by stage in go.cd pipeline instead
#upload_binaries "$2" "$3" "$4"
submit_jobs
if ! $SUBMIT_ONLY; then
	check_status
fi

clean_up
