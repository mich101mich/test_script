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
# Optional: An array of subdirectories of the crate. Defaults to an empty array
if [[ -v sub_directories ]]; then
    read -r -a sub_directories <<<"${sub_directories}" # Split the string into an array
    for sub_directory in "${sub_directories[@]}"; do
        if [[ ! -d "${base_dir}/${sub_directory}" ]]; then
            throw "Subdirectory ${sub_directory} does not exist"
        elif [[ ! -f "${base_dir}/${sub_directory}/Cargo.toml" ]]; then
            throw "Subdirectory ${sub_directory} does not contain a Cargo.toml file"
        fi
    done
else
    sub_directories=()
fi
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

export RUSTFLAGS="-D warnings"
export RUSTDOCFLAGS="-D warnings"
export CARGO_TARGET_DIR="${base_dir}/target"
mkdir -p "${CARGO_TARGET_DIR}"

try_silent rustup update

########
# main tests
########
for relative_dir in "" "${sub_directories[@]}"; do
    if [[ "$relative_dir" == "" ]]; then
        echo "Base Tests"
    else
        echo "Subdirectory Tests: ${relative_dir}"
    fi
    cd "${base_dir}/${relative_dir}"

    export CARGO_TARGET_DIR="${base_dir}/target/${relative_dir}" # Have all compile output in the root target directory

    try_silent cargo update
    try_silent cargo +stable test
    try_silent cargo +nightly test
    try_silent cargo +nightly doc --no-deps
    try_silent cargo +nightly clippy -- -D warnings
    try_silent cargo +stable fmt --check
done
export CARGO_TARGET_DIR="${base_dir}/target"

cd "${base_dir}"

if [[ "${is_proc_macro}" -eq 1 ]]; then
    echo "Error Message Tests"
    run_error_message_tests "${base_dir}/tests/fail" "${overwrite}"
fi

########
# minimum supported rust version
########
echo "Minimum Supported Rust Version Tests"

MSRV=$(read_msrv "${base_dir}/Cargo.toml")
echo "    Minimum supported Rust version: ${MSRV}"

for sub_directory in "${sub_directories[@]}"; do
    sub_msrv=$(read_msrv "${base_dir}/${sub_directory}/Cargo.toml")
    if [[ "$sub_msrv" != "$MSRV" ]]; then
        throw "Subdirectory ${sub_directory} has a different MSRV (${sub_msrv}) than the base directory (${MSRV})"
    fi
done

create_and_cd_test_dir "${base_dir}" "msrv_${MSRV}" "${sub_directories[@]}"

try_silent rustup install "${MSRV}"
try_silent cargo "+${MSRV}" update
for override in ${msrv_overrides}; do
    try_silent cargo "+${MSRV}" update -p "${override%@*}" --precise "${override#*@}"
done
try_silent cargo "+${MSRV}" test

########
# minimal versions
########
echo "Minimal Versions Tests"

create_and_cd_test_dir "${base_dir}" "min_versions" "${sub_directories[@]}"
try_silent cargo +nightly -Z minimal-versions update

try_silent cargo +stable test
try_silent cargo +nightly test

########
end_time=$(date +%s)
elapsed_time=$((end_time - start_time))
echo "All tests passed in ${elapsed_time} seconds!"
