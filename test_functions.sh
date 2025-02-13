#!/bin/bash -e

###############################################################################
## This script is a collection of functions that are used in the test        ##
## scripts of my Rust projects.                                              ##
###############################################################################

##########
# General functions
##########

# Prints an error message to stderr and exits the script
# Usage: throw <message...>
# Parameters:
#   $1..n: The error message to print
function throw {
    >&2 echo "$*"
    exit 1
}

# Asserts that the given parameters variables are not empty
# Usage: assert_has_parameters <function> <parameter_names...>
# Parameters:
#   $1: The name of the function that is calling this function
#   $2..n: The names of the parameter variables to check
function assert_has_parameters {
    local function_name="$1"
    [[ -n "${function_name}" ]] || throw "Function assert_has_parameters missing function_name parameter" # Can't call ourselves here
    shift 1

    for param in "$@"; do
        if [[ -z "${!param}" ]]; then
            throw "Function ${function_name} missing parameter: ${param}"
        fi
    done
}

# Handles test output. Output is forked to a file and the most recent line is shown in the terminal.
# Usage: <other_command> | handle_output <file>
# Parameters:
#   $1: The file to write the output to
#   stdin: The output to handle
function handle_output {
    local tmp_file="$1"
    assert_has_parameters handle_output "tmp_file"

    rm -f "${tmp_file}" # Clear output from previous runs
    while IFS='' read -r line; do
        echo "${line}" >> "${tmp_file}"

        echo -en "\033[2K\r" # Clear the line
        echo -n "$(cut -c "1-$(tput cols)" <<< "> ${line}")" # Print as much of the line as fits in the terminal
    done
    echo -en "\033[2K\r";
    tput init # Reset any coloring
}

# Runs a command and shows a preview of the output in a single self-overwriting line, only showing the full output if
# the command fails.
# Usage: try_silent <command...>
# Parameters:
#   $1..n: The command to run, including any arguments
# Returns: 1 if the command failed, 0 otherwise
function try_silent {
    echo "Running $*"
    tmp_file="$(mktemp)"

    # unbuffer: Tell the program to print its output as if it wasn't piped. Usually, programs disable colouring when
    # piped, but we want to keep it, since we are showing the output in the terminal.
    unbuffer "$@" 2>&1 | handle_output "${tmp_file}"

    # Check if the command failed. Other means of checking the result would instead check the result of handle_output
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        cat "${tmp_file}"
        return 1
    fi
}

# Reads the minimum supported Rust version from a Cargo.toml file
# Usage: read_msrv <toml_file>
# Parameters:
#   $1: The Cargo.toml file to read the MSRV from
# Returns: 1 if the MSRV could not be read, 0 otherwise
function read_msrv {
    local toml_file="$1"
    assert_has_parameters read_msrv "toml_file"

    local msrv
    msrv=$(sed -n -r -e 's/^rust-version = "(.*)"$/\1/p' "${toml_file}")
    if [[ -z "${msrv}" ]]; then
        return 1
    fi
    echo "${msrv}"
}

# Creates a directory structure for independent tests and changes into it
# Usage: create_test_dir <base_dir> <out_dir_name> <additional_files...>
# Parameters:
#   $1: The base directory to take the test files from
#   $2: The name of the test directory to create
#   $3..n: Additional files or directories from base_dir that should be symlink-copied to the test directory.
#          Without this, only "Cargo.toml", "src", and "tests" will be symlinked
function create_and_cd_test_dir {
    local base_dir="$1"
    local out_dir_name="$2"
    assert_has_parameters create_and_cd_test_dir "base_dir" "out_dir_name"

    shift 2
    local files=("Cargo.toml" "src" "tests" "$@")

    local target_dir="${base_dir}/target/${out_dir_name}"
    mkdir -p "${target_dir}"

    for file in "${files[@]}"; do
        local out_file="${target_dir}/${file}"
        rm -rf "${out_file}" # Remove any existing files
        mkdir -p "$(dirname "${out_file}")" # Allowing for nested directories
        ln -s "../../${file}" "${out_file}"
    done

    cd "${target_dir}"
}

# Runs the tests for the root directory of the project
# Usage: run_base_tests
function run_base_tests {
    try_silent rustup update
    try_silent cargo update
    try_silent cargo +stable test
    try_silent cargo +nightly test
    try_silent cargo +nightly doc --no-deps
    try_silent cargo +nightly clippy -- -D warnings
    try_silent cargo +stable fmt --check
}

##########
# Procedural macro specific functions
##########

# Asserts that a directory has no git changes. If there are changes, the script will exit.
# Usage: assert_no_change <directory>
# Parameters:
#   $1: The directory to check for changes
function assert_no_change {
    local dir="$1"
    assert_has_parameters assert_no_change "dir"

    if ! git diff-files --quiet --ignore-cr-at-eol "${dir}"; then
        throw "Changes in ${dir} detected, aborting"
    fi
    if [[ -n "$(git ls-files --exclude-standard --others "${dir}")" ]]; then
        throw "Untracked files in ${dir} detected, aborting"
    fi
}

function compare_files {
    local a="$1"
    local b="$2"
    assert_has_parameters compare_files "a" "b"

    if [[ ! -f "${a}" ]]; then
        >&2 echo "File ${a} missing"
        return 1
    elif [[ ! -f "${b}" ]]; then
        >&2 echo "File ${b} missing"
        return 1
    elif ! cmp -s "${a}" "${b}"; then
        >&2 echo "File ${a} and ${b} differ"
        return 1
    fi
}

# Runs the error message tests
# Usage: run_error_message_tests <fail_dir> [<overwrite>]
# Parameters:
#   $1: The directory containing the error message tests
#   $2: If 1, the tests will be run in overwrite mode. Defaults to 0
function run_error_message_tests {
    local fail_dir="$1"
    local overwrite="${2:-0}"
    assert_has_parameters run_error_message_tests "fail_dir"

    local error=0

    # Check that stable and nightly fail tests are the same
    local stable_dirs=()
    local test_files=()
    while IFS= read -r -d $'\0' stable_dir; do
        local nightly_dir="${stable_dir%/stable}/nightly"
        if [[ ! -d "${nightly_dir}" ]]; then
            >&2 echo "No nightly directory for ${stable_dir}"
            error=1
            continue
        fi
        stable_dirs+=("${stable_dir}")

        while IFS= read -r -d $'\0' file; do
            relative_file="${file#"${stable_dir}"/}"
            compare_files "${stable_dir}/${relative_file}" "${nightly_dir}/${relative_file}" || error=1
            test_files+=("${relative_file}")
        done < <(find "${stable_dir}" -type f -name '*.rs' -print0)
    done < <(find "${fail_dir}" -type d -name stable -print0)

    while IFS= read -r -d $'\0' nightly_dir; do
        stable_dir="${nightly_dir%/nightly}/stable"
        if [[ ! -d "${stable_dir}" ]]; then
            >&2 echo "No stable directory for ${nightly_dir}"
            error=1
            continue
        fi
        while IFS= read -r -d $'\0' file; do
            relative_file="${file#"${nightly_dir}"/}"
            compare_files "${nightly_dir}/${relative_file}" "${stable_dir}/${relative_file}" || error=1
        done < <(find "${nightly_dir}" -type f -name '*.rs' -print0)
    done < <(find "${fail_dir}" -type d -name nightly -print0)

    if [[ ${error} -eq 1 ]]; then
        exit 1
    fi

    # Run the tests
    if [[ ${overwrite} -eq 1 ]]; then
        echo "Trybuild overwrite mode enabled"
        export TRYBUILD=overwrite

        # "overwrite" will (as the name implies) overwrite any incorrect output files in the error_message_tests.
        # There is however the problem that the stable and nightly versions might have different outputs. If they
        # are simply run one after the other, then the second one will overwrite the first one. To avoid this, we
        # use git to check if the files have changed after every step.
        assert_no_change "${fail_dir}/**/*.stderr" # Check for initial changes that would skew the later checks

        try_silent cargo +stable test error_message_tests -- --ignored
        assert_no_change "${fail_dir}/**/*.stderr"

        try_silent cargo +nightly test error_message_tests -- --ignored
        assert_no_change "${fail_dir}/**/*.stderr"
    else
        unset TRYBUILD # Remove TRYBUILD flag if it was set
        try_silent cargo +stable test error_message_tests -- --ignored
        try_silent cargo +nightly test error_message_tests -- --ignored
    fi

    # Check that the stable and nightly distinction is actually used
    for stable_dir in "${stable_dirs[@]}"; do
        local nightly_dir="${stable_dir}/../nightly"
        for file in "${test_files[@]}"; do
            stderr_file="${file%.rs}.stderr"
            if [[ ! -f "${stable_dir}/${stderr_file}" ]]; then
                >&2 echo "File ${stderr_file} missing in ${stable_dir}"
                error=1
                continue
            fi
            if [[ ! -f "${nightly_dir}/${stderr_file}" ]]; then
                >&2 echo "File ${stderr_file} missing in ${nightly_dir}"
                error=1
                continue
            fi
            # Compare the contents of the stderr files, but ignore the path differences between stable and nightly
            if cmp -s "${stable_dir}/${stderr_file}" <(sed -e 's/nightly/stable/g' "${nightly_dir}/${stderr_file}"); then
                >&2 echo "File ${stable_dir}/${stderr_file} is the same between stable and nightly"
                error=1
            fi
        done
    done

    if [[ ${error} -eq 1 ]]; then
        exit 1
    fi
}