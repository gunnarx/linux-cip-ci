#!/bin/bash -x
#
# Copyright (C) 2021 GENIVI Alliance
# Gunnar Andersson, <gandersson@genivi.org>
#
# The following must be set in CI environment variables for lavacli to work:
# $CIP_LAVA_LAB_USER
# $CIP_LAVA_LAB_TOKEN
# If values are not set, they are read from a credentials file, which
# must then exist.
#
################################################################################
WORK_DIR=`pwd`
OUTPUT_DIR="$WORK_DIR/output"

# Default LAVA_CREDENTIALS_FILE locations
# (Not used if CIP_LAVA_LAB_USER/TOKEN is defined in env)
if [ -z "$LAVA_CREDENTIALS_FILE" ] ; then
  if [ -f "$WORK_DIR/cip_lava_lab_cred" ] ; then
    LAVA_CREDENTIALS_FILE="$WORK_DIR/cip_lava_lab_cred"
  fi
  if [ -f "$HOME/cip_lava_lab_cred" ] ; then
    LAVA_CREDENTIALS_FILE="$HOME/cip_lava_lab_cred"
  fi
fi

warn() {
  cat <<EOT 1>&2
  $@
EOT
}

get_credentials() {
  if [ -z "$CIP_LAVA_LAB_USER" ] ; then
    if [ -z "$LAVA_CREDENTIALS_FILE" ] ; then
      echo "Please specify CIP_LAVA_LAB_USER/TOKEN or LAVA_CREDENTIALS_FILE"
      exit 2
    fi

    if [ ! -f "$LAVA_CREDENTIALS_FILE" ] ; then
      echo "Specified credentials file ($LAVA_CREDENTIALS_FILE) is missing!  Lava interaction will not be possible"
      echo "Stopping..."
      exit 1
    else
      . "$LAVA_CREDENTIALS_FILE"
    fi
  fi

  if [ -z "$CIP_LAVA_LAB_USER" ] ; then
    echo "Bug: CIP_LAVA_LAB_USER is still not specified.  Lava interaction will not be possible"
    echo "Stopping..."
    exit 3
  fi
}

################################################################################

# Just some helpers that will fail gracefully if an environment
# variable is undefined, which it might be sometimes
deref() { eval echo \$$1 ; }
get_value() {
  local concept=$1
  local value=$(deref $2)  # variable name passed in $2
  if [ -z "$value" ] ; then
     warn "Warning, value for variable $2 was not defined -- using default value"
     value="unknown_${concept}"
  fi
  echo "$value"
}

#get_version() {
#  get_value label GO_PIPELINE_NAME
#}

get_pipeline_instance() {
  echo "$(get_value pipe_name GO_PIPELINE_NAME)_$(get_value counter GO_PIPELINE_COUNTER)"
}

get_arch() {
  # Coding the relationship between $TARGET used in our Yocto builds
  # and the CPU architecture
  if [[ "$TARGET" =~ r-car.*3 ]] ; then
    echo "arm64"
  elif [[ "$TARGET" =~ qemuarm64 ]] ; then
    echo "arm64"
  elif [[ "$TARGET" =~ x86.64 ]] ; then
    echo "x86-64"
  elif [[ "$TARGET" =~ x86 ]] ; then
    echo "x86"
  else
    # For now we don't know any other targets...
    echo "UNSUPPORTED_MACHINE"
  fi
}

get_config() {
  # Since we don't care to specify kernel config in our test names we can
  # "misuse" CONFIG for another purpose.  An alternative would be to change
  # submit_tests.sh further but it seems useful to keep changes there to a
  # minimum, if we want to merge some future updates.  We still want a useful
  # value here since CONFIG is included in the Job name and reported in the
  # Lava web interface.  It is therefore one place where we can insert the
  # pipeline identification string instead.
  get_pipeline_instance | sed 's|/|@|'
}

get_device() {
  # Coding the relationship between $TARGET used in our Yocto builds
  # and the expected test target device type:
  if [[ "$TARGET" =~ r-car.*h3 ]] ; then
    echo "r8a7795-h3ulcb"
  elif [[ "$TARGET" =~ r-car.*m3 ]] ; then
    echo "r8a7796-m3ulcb"
  else
    # For now we don't know any other test targets that are hooked up...
    echo "UNSUPPORTED_MACHINE"
  fi
}
get_kernel_name() {
  echo "_"  # Not defined  -> basically it is fixed in test definition template
}
get_device_tree_name() {
  echo "_"  # Not defined  -> basically it is fixed in test definition template
}
get_modules() {
  echo ""     # Not defined, same as above
}
get_jobname() {
  echo "myjob.jobs"
}

mkdir -p "$OUTPUT_DIR"
jobfile="$OUTPUT_DIR/$(get_jobname)"

# (ROOT_FS = "$1" - passed to submit_tests.sh but it is not used in naming of
# the job and therefore not used here)
KERNEL="$2"
DTB="$3"


# Create job file that is consumed by linux-cip-ci/submit_tests.sh
cat <<EOT >$jobfile
# This is a comment
# Format (PIPELINE_ID added by us)
# VERSION PIPELINE_ID ARCH CONFIG DEVICE KERNEL DEVICE_TREE MODULES
$1 $(get_pipeline_instance) $(get_arch) $(get_config) $(get_device) $KERNEL $DTB $(get_modules)
EOT

# Delegate to submit_tests.sh
get_credentials
bash -x submit_tests.sh "$1" "$2" "$3" "$4"


