#!/bin/bash -e

start_time=$(date +%s)

source "$(realpath "$(dirname "$0")")/test_functions.sh"

# Check for required commands
# Note that we don't check for coreutils commands, since without those we wouldn't even have echo etc., so the check
# and error reporting would be ungodly.
for cmd in rustup cargo tput git cmp; do
    require_cmd "${cmd}"
done

# Check if all required parameter variables are set
# Can't use a loop here because shellcheck needs to know about this too

# The base directory of the crate
[[ -v base_dir ]] || throw "test.sh parameter variable base_dir is not set"

# Optional: Overrides for dependencies in MSRV builds
[[ -v msrv_overrides ]] || msrv_overrides=""

# Optional: Whether the crate is a procedural macro crate. Defaults to 0 (no)
[[ -v is_proc_macro ]] || is_proc_macro=0

########
# setup
########
echo "Setup"

overwrite=0
if [[ "$1" == "overwrite" ]]; then
    overwrite=1
elif [[ -n "$1" ]]; then
    throw "Usage: $0 [overwrite]"
fi

cd "${base_dir}"

export RUSTFLAGS="-D warnings"
export RUSTDOCFLAGS="-D warnings"
mkdir -p target/cov/{stable,nightly}

export TRY_SILENT_LOG_FILE="${base_dir}/target/test.log"

try_silent rustup update
try_silent rustup install stable
try_silent rustup install nightly
try_silent rustup component add --toolchain stable rustfmt llvm-tools-preview
try_silent rustup component add --toolchain nightly clippy llvm-tools-preview
try_silent cargo install cargo-llvm-cov

########
# main tests
########
echo "Base Tests"
export CARGO_TARGET_DIR="${base_dir}/target"

try_silent cargo update --workspace
try_silent cargo +stable llvm-cov test --workspace --no-clean --lcov --output-path target/cov/stable/lcov.info
try_silent cargo +nightly llvm-cov test --workspace --no-clean --lcov --output-path target/cov/nightly/lcov.info
try_silent cargo +nightly doc --no-deps --workspace
try_silent cargo +nightly clippy --workspace -- -D warnings
try_silent cargo +stable fmt --check --all # Note: I'm expecting --all to be renamed to --workspace in the future

if [[ "${is_proc_macro}" -eq 1 ]]; then
    echo "Error Message Tests"
    run_error_message_tests "tests/fail" "${overwrite}"
fi

########
# minimum supported rust version
########
echo "Minimum Supported Rust Version Tests"

MSRV=$(read_msrv "${base_dir}/Cargo.toml")
echo "    Minimum supported Rust version: ${MSRV}"

create_and_cd_test_dir "${base_dir}" "msrv_${MSRV}"

try_silent rustup install "${MSRV}"
try_silent cargo "+${MSRV}" update --workspace
for override in ${msrv_overrides}; do
    try_silent cargo "+${MSRV}" update -p "${override%@*}" --precise "${override#*@}"
done
try_silent cargo "+${MSRV}" test --workspace

########
# minimal versions
########
echo "Minimal Versions Tests"

create_and_cd_test_dir "${base_dir}" "min_versions"
try_silent cargo +nightly -Z minimal-versions update

try_silent cargo +stable test --workspace
try_silent cargo +nightly test --workspace

########
end_time=$(date +%s)
elapsed_time=$((end_time - start_time))
echo "All tests passed in ${elapsed_time} seconds!"
