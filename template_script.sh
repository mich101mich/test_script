#!/bin/bash -e

BASE_DIR="$(realpath "$(dirname "$0")")"

source "${BASE_DIR}/submodules/test_script/test_functions.sh"

########
# setup
########

OVERWRITE=0
if [[ "$1" == "overwrite" ]]; then
    OVERWRITE=1
elif [[ -n "$1" ]]; then
    throw "Usage: $0 [overwrite]"
fi

MSRV=$(read_msrv "${BASE_DIR}/Cargo.toml") || throw "Failed to read MSRV"
echo "Minimum supported Rust version: ${MSRV}"

export RUSTFLAGS="-D warnings"
export RUSTDOCFLAGS="-D warnings"

########
# main tests
########
cd "${BASE_DIR}"

run_base_tests

run_error_message_tests "tests/fail" "${OVERWRITE}"

########
# minimum supported rust version
########
create_and_cd_test_dir "${BASE_DIR}" "msrv_${MSRV}"

try_silent rustup install "${MSRV}"
try_silent cargo "+${MSRV}" test --tests # only run --tests, which excludes the doctests from Readme.md

########
# minimum versions
########
create_and_cd_test_dir "${BASE_DIR}" "min_versions"
try_silent cargo +nightly -Z minimal-versions update

try_silent cargo +stable test
try_silent cargo +nightly test

########
echo "All tests passed!"
