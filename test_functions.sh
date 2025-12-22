#!/bin/bash -e

###############################################################################
## This script is a collection of functions that are used in the test        ##
## scripts of my Rust projects.                                              ##
###############################################################################

##########
# General functions
##########

# Prints a message to stderr
# Usage: echo_err <message...>
# Parameters:
#   $1..n: The message to print
function echo_err {
    echo "$*" >&2
}

# Prints an error message to stderr and exits the script
# Usage: throw <message...>
# Parameters:
#   $1..n: The error message to print
function throw {
    echo_err "$*"
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

# Asserts that a command is available in the system
# Usage: require_cmd <command>
# Parameters:
#   $1: The command to check
function require_cmd() {
    local cmd="$1"
    assert_has_parameters require_cmd "cmd"
    command -v "${cmd}" &>/dev/null || throw "test_script/test.sh requires command '${cmd}'. Please install it."
}

# Sets the length of a string by truncating or padding it with spaces
# Usage: set_string_length <string> <length>
# Parameters:
#   $1: The string to set the length of
#   $2: The desired length of the string
function set_string_length {
    local string="$1"
    local length="$2"
    assert_has_parameters set_string_length "string" "length"

    string="${string:0:${length}}" # Truncate the string if it is too long
    printf "%-${length}s" "${string}" # Pad the string if it is too short to clear any previous output
}

# Handles test output. Output is forked to a file and the most recent line is shown in the terminal.
# Usage: <other_command> | handle_output <file>
# Parameters:
#   $1: The file to write the output to
#   stdin: The output to handle
function handle_output {
    local tmp_file="$1"
    assert_has_parameters handle_output "tmp_file"

    while IFS='' read -r line; do
        echo "${line}" >> "${tmp_file}"

        echo -n "$(set_string_length "    > ${line}" "$(tput cols)")" # re-read tput every time in case of a resize
        echo -en "\r" # Return to the beginning of the line
    done
    echo -en "\033[2K\r"; # Clear the line
    tput init # Reset any coloring
}

# Runs a command and shows a preview of the output in a single self-overwriting line, only showing the full output if
# the command fails.
# Usage: try_silent <command...>
# Parameters:
#   $1..n: The command to run, including any arguments
# Returns: 1 if the command failed, 0 otherwise
function try_silent {
    echo "    Running $*"

    local tmp_file="${TRY_SILENT_LOG_FILE:?}"
    mkdir -p "$(dirname "${tmp_file}")"
    {
        echo "################################################################################"
        echo "### Log for $*"
        echo "### This file is meant to be output to a terminal, so it still contains escape"
        echo "### sequences for coloring. If you want to read the log, use"
        echo "###     tail -n +7 \"${tmp_file}\""
        echo "################################################################################"
    } > "${tmp_file}"

    CARGO_TERM_COLOR=always "$@" 2>&1 | handle_output "${tmp_file}"

    # Check if the command failed. Other means of checking the result would instead check the result of handle_output
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        tail -n +7 "${tmp_file}"
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
        throw "Failed to read MSRV from ${toml_file}"
    fi
    echo "${msrv}"
}

# Creates a directory structure for independent tests and changes into it
# Usage: create_test_dir <base_dir> <out_dir_name> <additional_files...>
# Parameters:
#   $1: The base directory to take the test files from
#   $2: The name of the test directory to create
function create_and_cd_test_dir {
    local base_dir="$1"
    local out_dir_name="$2"
    assert_has_parameters create_and_cd_test_dir "base_dir" "out_dir_name"

    local target_dir="${base_dir}/target/${out_dir_name}"
    mkdir -p "${target_dir}"

    local out_file
    while IFS= read -r -d $'\0' file; do
        out_file="$(basename "${file}")"
        if [[ "${out_file}" == "target" || "${out_file}" == "Cargo.lock" ]]; then
            continue # Not sharing these files is exactly why we're creating a separate test dir
        fi
        out_file="${target_dir}/${out_file}"
        rm -f "${out_file}" # Remove any existing files
        ln -s "${file}" "${out_file}"
    done < <(find "${base_dir}" -maxdepth 1 -print0)

    cd "${target_dir}"
    export CARGO_TARGET_DIR="${target_dir}/target"
}

##########
# Procedural macro specific functions
##########

# Asserts that a directory has no git changes. If there are changes, the script will ask the user to resolve them and exit if they don't.
# Usage: assert_no_change <directory> [<is_nightly>]
# Parameters:
#   $1: The directory to check for changes
#   $2: Whether this is a nightly run. Defaults to no
# Returns: 1 if there were changes, 0 otherwise
function assert_no_change {
    local dir="$1" is_nightly="$2"
    assert_has_parameters assert_no_change "dir" # Nightly is optional

    error=0
    while IFS= read -r -d $'\0' file; do
        [[ $file != *.stderr ]] && continue # Ignore non-stderr files

        error=1

        if [[ ! $is_nightly || $file == */nightly/* ]]; then
            echo_err "Unstaged change in ${file} detected"
            continue # Not the nightly run or already in nightly folder, so just print error
        fi

        echo_err "File ${file} changed by nightly tests, splitting into stable/nightly variants"

        # This file was changed by nightly but not by stable (since we asserted no changes after stable)
        # So we need to split it into stable/nightly variants
        local base_dir filename
        base_dir="$(dirname "${file}")"
        filename="$(basename "${file}")"

        # Create stable/nightly folders if they don't exist
        mkdir -p "${base_dir}/stable" "${base_dir}/nightly"

        # Copy .rs file to stable and nightly
        local rs_file="${file%.stderr}.rs"
        cp "${rs_file}" "${base_dir}/stable/"
        mv "${rs_file}" "${base_dir}/nightly/"

        # Copy stderr files to their respective folders, adjusting paths
        sed -e "s|${base_dir}/|${base_dir}/nightly/|g" "${file}" > "${base_dir}/nightly/${filename}"
        git checkout -- "${file}" # Get the original stderr file for stable
        sed -e "s|${base_dir}/|${base_dir}/stable/|g" "${file}" > "${base_dir}/stable/${filename}"
        rm "${file}"
    done < <(git ls-files --exclude-standard --modified --others -z -- "${dir}")

    [[ ${error} -eq 0 ]] || return 1
    return 0
}

function compare_files {
    local a="$1"
    local b="$2"
    assert_has_parameters compare_files "a" "b"

    if [[ ! -f "${a}" ]]; then
        echo_err "File ${a} missing"
        return 1
    elif [[ ! -f "${b}" ]]; then
        echo_err "File ${b} missing"
        return 1
    elif ! cmp -s "${a}" "${b}"; then
        echo_err "File ${a} and ${b} differ"
        return 1
    fi
}

# Internal function. See run_error_message_tests for details.
function _internal_run_error_message_tests {
    local fail_dir="$1"
    local overwrite="$2"
    local error=0

    # Check that stable and nightly fail tests are the same
    local stable_dirs=()
    local test_files=()
    while IFS= read -r -d $'\0' stable_dir; do
        local nightly_dir="${stable_dir%/stable}/nightly"
        if [[ ! -d "${nightly_dir}" ]]; then
            echo_err "No nightly directory for ${stable_dir}"
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
            echo_err "No stable directory for ${nightly_dir}"
            error=1
            continue
        fi
        while IFS= read -r -d $'\0' file; do
            relative_file="${file#"${nightly_dir}"/}"
            compare_files "${nightly_dir}/${relative_file}" "${stable_dir}/${relative_file}" || error=1
        done < <(find "${nightly_dir}" -type f -name '*.rs' -print0)
    done < <(find "${fail_dir}" -type d -name nightly -print0)

    [[ ${error} -eq 0 ]] || return 1

    mkdir -p target/cov/{err_stable,err_nightly}

    # Run the tests
    if [[ ${overwrite} -eq 1 ]]; then
        echo "    Trybuild overwrite mode enabled"
        export TRYBUILD=overwrite

        # "overwrite" will (as the name implies) overwrite any incorrect output files in the error_message_tests.
        # First verify that there are no previous changes

        assert_no_change "${fail_dir}" || return 1

        # Run stable tests
        try_silent cargo +stable llvm-cov test error_message_tests --workspace --lcov --output-path target/cov/err_stable/lcov.info -- --ignored || exit 1

        assert_no_change "${fail_dir}" || return 1

        # Run nightly tests
        try_silent cargo +nightly llvm-cov test error_message_tests --workspace --lcov --output-path target/cov/err_nightly/lcov.info -- --ignored || exit 1

        assert_no_change "${fail_dir}" "nightly" || return 1
    else
        unset TRYBUILD # Remove TRYBUILD flag if it was set
        try_silent cargo +stable llvm-cov test error_message_tests --workspace --lcov --output-path target/cov/err_stable/lcov.info -- --ignored || exit 1
        try_silent cargo +nightly llvm-cov test error_message_tests --workspace --lcov --output-path target/cov/err_nightly/lcov.info -- --ignored || exit 1
    fi

    # Check that the stable and nightly distinction is actually used
    for stable_dir in "${stable_dirs[@]}"; do
        local base_dir="${stable_dir}/.."
        local nightly_dir="${base_dir}/nightly"
        for file in "${test_files[@]}"; do
            stderr_file="${file%.rs}.stderr"
            if [[ ! -f "${stable_dir}/${stderr_file}" ]]; then
                echo_err "File ${stderr_file} missing in ${stable_dir}"
                error=1
                continue
            fi
            if [[ ! -f "${nightly_dir}/${stderr_file}" ]]; then
                echo_err "File ${stderr_file} missing in ${nightly_dir}"
                error=1
                continue
            fi
            # Compare the contents of the stderr files, but ignore the path differences between stable and nightly
            if cmp -s "${stable_dir}/${stderr_file}" <(sed -e 's/nightly/stable/g' "${nightly_dir}/${stderr_file}"); then
                if [[ ${overwrite} -eq 1 ]]; then
                    echo_err "File ${stable_dir}/${stderr_file} is the same between stable and nightly, overwriting to unify"
                    mv "${stable_dir}/${file}" "${base_dir}/${file}"
                    sed -e 's|/stable/|/|g' "${stable_dir}/${stderr_file}" > "${base_dir}/${stderr_file}"
                    rm "${stable_dir}/${stderr_file}" "${nightly_dir}/${file}" "${nightly_dir}/${stderr_file}"
                else
                    echo_err "File ${stable_dir}/${stderr_file} is the same between stable and nightly"
                fi

                error=1
            fi
        done
    done

    [[ ${error} -eq 0 ]] || return 1
    return 0
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

    while ! _internal_run_error_message_tests "${fail_dir}" "${overwrite}"; do
        read -r -p "Retry error message tests? [Y/n] " response
        if [[ "$response" == "n" || "$response" == "N" ]]; then
            exit 1
        fi

        echo "Retrying..."
        echo ""
    done
}
