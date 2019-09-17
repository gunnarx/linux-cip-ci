# linux-cip-ci
[![pipeline status](https://gitlab.com/cip-project/cip-testing/linux-cip-ci/badges/master/pipeline.svg)](https://gitlab.com/cip-project/cip-testing/linux-cip-ci/commits/master)

Current DOCKER_IMAGE_TAG version: v2

This project builds the containers and scripts used in the CI testing of the
linux-cip Kernel.

There are two docker containers, "build-image" and "test-image". You can guess
what they are for.

## build-image
Docker container that includes Linux Kernel build dependencies.

Also included is the `build_kernel.sh` script which handles the actual building
of the Kernel for the given architecture and configurations.

### build_kernel.sh
This script starts by installing the relevant gcc compiler for the given
architecture. It then builds the Kernel, device trees and modules as required
for the given configuration.

The GitLab CI configuration then archives the relevant binaries ready for the
test stage to pick up.

**Parameters**  
The following variables should be set in the gitlab-ci.yml job:  
* `BUILD_ARCH`: The architecture to build for. Architectures currently supported
are: arm, arm64, powerpc, x86.
* `CONFIG`: The name of the configuration file to be used. Can be in either
.config or defconfig format.
* `CONFIG_LOC`: Must be one of the following options:
  * `intree`: Configuration is present in the linux-cip Kernel.
  * `cip-kernel-configs`: Configuration is present in the [cip-kernel-configs](https://gitlab.com/cip-project/cip-kernel/cip-kernel-config) repository.
  * `url`: Link to raw defconfig file hosted somewhere public. Should be a link
to the directory where the config is stored, not the actual file.
* `DEVICES`: A list of device-types as defined in LAVA that are to be tested.
This must be set if testing is required.
* `DTBS`: A list of device tree blobs (including extension) that are to be used
in testing. Exactly one `DTB` per device-type in `DEVICES` must be defined.
* `BUILD_ONLY`: Set to 'true' if don't want to test this configuration, only
build. If this is not set a default of 'false' is used.

## test-image
Used to build a container that includes the dependencies required for testing.

Also included is the `submit_tests.sh` script which creates and submits LAVA
test jobs.

### submit_tests.sh
This script starts by searching for Kernels that are in the `$OUTPUT_DIR`
directory. Each Kernel then gets uploaded to an S3 bucket on AWS. The script
then creates LAVA test jobs as required and submits them to the CIP LAVA master.

**Prerequisites**  
The `submit_tests.sh` script relies on the following secret environment
variables being set. This can be done in GitLab in `settings/ci_cd`.
* `CIP_CI_AWS_ID`
* `CIP_CI_AWS_KEY`
* `CIP_LAVA_LAB_USER`
* `CIP_LAVA_LAB_TOKEN`

**Parameters**  
* `TEST_TIMEOUT`: Length of time in minutes to wait for test completion. If
unset a default of 30 minutes is used.
* `SUBMIT_ONLY`: Set to 'true' if you don't want to wait to see if submitted
LAVA jobs complete. If this is not set a default of 'false' is used.

## linux-cip-ci version
Wherever possible when changes are made to the containers and scripts in
linux-cip-ci, care is taken not to break backwards compatibility. Sometimes this
is not possible so a `DOCKER_IMAGE_TAG` variable has been created.

Each time there is a breaking change this variable is incremented in the
.gitlab-ci.yml file in the linux-cip-ci repository.

## Example Use
The below `.gitlab-ci.yml` file shows how linux-cip-ci can be used.

```
variables:
  GIT_STRATEGY: clone
  GIT_DEPTH: "10"
  DOCKER_DRIVER: overlay2
  DOCKER_IMAGE_TAG: v2

arm_renesas_shmobile_defconfig:
  stage: build
  image: registry.gitlab.com/cip-project/cip-testing/linux-cip-ci:build-$DOCKER_IMAGE_TAG
  variables:
    BUILD_ARCH: arm
    CONFIG: renesas_shmobile_defconfig
    CONFIG_LOC: cip-kernel-config
    DEVICES: r8a7743-iwg20d-q7 r8a7745-iwg22d-sodimm r8a77470-iwg23s-sbc
    DTBS: r8a7743-iwg20d-q7-dbcm-ca.dtb r8a7745-iwg22d-sodimm-dbhd-ca.dtb r8a77470-iwg23s-sbc.dtb
  script:
    - /opt/build_kernel.sh
  artifacts:
    name: "$CI_JOB_NAME"
    when: on_success
    paths:
      - output

arm64_renesas_defconfig:
  stage: build
  image: registry.gitlab.com/cip-project/cip-testing/linux-cip-ci:build-$DOCKER_IMAGE_TAG
  variables:
    BUILD_ARCH: arm64
    CONFIG: renesas_defconfig
    CONFIG_LOC: cip-kernel-config
    DEVICES: r8a774c0-ek874 r8a774a1-hihope-rzg2m-ex
    DTBS: r8a774c0-ek874.dtb r8a774a1-hihope-rzg2m-ex.dtb
  script:
    - /opt/build_kernel.sh
  artifacts:
    name: "$CI_JOB_NAME"
    when: on_success
    paths:
      - output

arm64_defconfig:
  stage: build
  image: registry.gitlab.com/cip-project/cip-testing/linux-cip-ci:build-$DOCKER_IMAGE_TAG
  variables:
    BUILD_ARCH: arm64
    CONFIG: defconfig
    CONFIG_LOC: intree
    DEVICES: r8a774c0-ek874 r8a774a1-hihope-rzg2m-ex
    DTBS: r8a774c0-ek874.dtb r8a774a1-hihope-rzg2m-ex.dtb
  script:
    - /opt/build_kernel.sh
  artifacts:
    name: "$CI_JOB_NAME"
    when: on_success
    paths:
      - output

x86_siemens_server_defconfig:
  stage: build
  image: registry.gitlab.com/cip-project/cip-testing/linux-cip-ci:build-$DOCKER_IMAGE_TAG
  variables:
    BUILD_ARCH: x86
    CONFIG: siemens_server_defconfig
    CONFIG_LOC: cip-kernel-config
    BUILD_ONLY: "true"
  script:
    - /opt/build_kernel.sh
  artifacts:
    name: "$CI_JOB_NAME"
    when: on_success
    paths:
      - output

run_tests:
  stage: test
  image: registry.gitlab.com/cip-project/cip-testing/linux-cip-ci:test-$DOCKER_IMAGE_TAG
  variables:
    GIT_STRATEGY: none
    TEST_TIMEOUT: 30
  when: always
  before_script: []
  script:
    - /opt/submit_tests.sh
```
