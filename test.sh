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

# Optional: Disable coverage
[[ -v disable_coverage ]] || disable_coverage=0

########
# setup
########
echo "Setup"

frozen=0
if [[ "$1" == "frozen" ]]; then
    frozen=1
elif [[ -n "$1" ]]; then
    throw "Usage: $0 [frozen]"
fi

cd "${base_dir}"

export CARGO_BUILD_WARNINGS="deny"
export RUSTDOCFLAGS="-D warnings"
mkdir -p target/cov/nightly

export TRY_SILENT_LOG_FILE="${base_dir}/target/test.log"

function coverage() {
    # structure: try_silent cargo (+stable|+nightly) test ...
    if [[ "$2" != "try_silent" || "$3" != "cargo" || "$5" != "test" ]]; then
        throw "Coverage function should be called as: coverage <name> try_silent cargo +<toolchain> test ..."
    fi
    output_path="target/cov/$1/lcov.info"
    toolchain="$4"
    shift 5
    if [[ "$disable_coverage" -ne 1 ]]; then
        try_silent cargo "$toolchain" llvm-cov test --lcov --output-path "$output_path" "$@"
    else
        try_silent cargo "$toolchain" test "$@"
    fi
}

try_silent rustup update
try_silent rustup install stable
try_silent rustup install nightly
# Tools: We run fmt on stable, clippy on nightly, llvm-cov on both.
#        rust-src is required because compiler errors change with it, and we want consistent errors.
if [[ "${disable_coverage}" -ne 1 ]]; then
    try_silent rustup component add --toolchain stable rustfmt rust-src llvm-tools-preview
    try_silent rustup component add --toolchain nightly clippy rust-src llvm-tools-preview
    try_silent cargo install cargo-llvm-cov
else
    try_silent rustup component add --toolchain stable rustfmt rust-src
    try_silent rustup component add --toolchain nightly clippy rust-src
fi

########
# main tests
########
echo "Base Tests"
export CARGO_TARGET_DIR="${base_dir}/target"

try_silent cargo update
try_silent cargo +stable test --workspace
coverage nightly try_silent cargo +nightly test --workspace
try_silent cargo +nightly doc --no-deps --workspace
try_silent cargo +nightly clippy --workspace -- -D warnings
try_silent cargo +stable fmt --check --all # Note: I'm expecting --all to be renamed to --workspace in the future

if [[ "${is_proc_macro}" -eq 1 ]]; then
    echo "Error Message Tests"
    run_error_message_tests "${frozen}"
fi

########
# minimum supported rust version
########
echo "Minimum Supported Rust Version Tests"

export RUSTFLAGS="-D warnings" # CARGO_BUILD_WARNINGS doesn't exist on MSRV
MSRV=$(read_msrv "${base_dir}/Cargo.toml")
echo "    Minimum supported Rust version: ${MSRV}"

create_and_cd_test_dir "${base_dir}" "msrv_${MSRV}"

try_silent rustup install "${MSRV}"
try_silent cargo "+${MSRV}" update
for override in ${msrv_overrides}; do
    try_silent cargo "+${MSRV}" update -p "${override%@*}" --precise "${override#*@}"
done
try_silent cargo "+${MSRV}" test --workspace
unset RUSTFLAGS

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

if [[ "${disable_coverage}" -ne 1 ]]; then
    lcov_args=()
    for lcov in target/cov/*/lcov.info; do
        [[ -f "${lcov}" ]] || continue
        lcov_args+=("--add-tracefile" "${lcov}")
    done

    if [[ ${#lcov_args[@]} -gt 0 ]]; then
        lcov "${lcov_args[@]}" --output-file target/lcov.info
    else
        echo "No lcov files found, skipping combined report generation"
    fi
fi
