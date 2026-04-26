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

    local error=0
    while IFS= read -r -d $'\0' file; do
        [[ $file != *.rs ]] && continue # Ignore non-test files

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

        # The file used to be valid for stable, and was now modified to fit nightly, so we already have both versions.
        cp "${file}" "${base_dir}/nightly/${filename}"
        git checkout -- "${file}" # Get the original file back for stable
        mv "${file}" "${base_dir}/stable/${filename}"

        # If a file contains the filename, it will now have a different path
        sed -i -e "s|${filename}|nightly/${filename}|g" "${base_dir}/nightly/${filename}"
        sed -i -e "s|${filename}|stable/${filename}|g" "${base_dir}/stable/${filename}"

    done < <(git ls-files --exclude-standard --modified --others -z -- "${dir}")

    return $error
}

# Internal function. See run_error_message_tests for details.
function _internal_run_error_message_tests {
    local frozen="$1"
    local error=0

    mkdir -p target/cov/{err_stable,err_nightly}

    # Run the tests
    if [[ $frozen -eq 1 ]]; then
        echo "    err_span_check frozen mode enabled"
        export ERR_SPAN_CHECK="frozen"
        coverage err_stable try_silent cargo +stable test error_message_tests --workspace -- --ignored || exit 1

        coverage err_nightly try_silent cargo +nightly test error_message_tests --workspace -- --ignored || exit 1
    else
        assert_no_change "tests/fail" || return 1

        # Run stable tests
        coverage err_stable try_silent cargo +stable test error_message_tests --workspace -- --ignored || return 1

        assert_no_change "tests/fail" || return 1

        # Run nightly tests
        coverage err_nightly try_silent cargo +nightly test error_message_tests --workspace -- --ignored || return 1

        assert_no_change "tests/fail" "nightly" || return 1
    fi

    # Check that the stable and nightly distinction is actually used
    while IFS= read -r -d $'\0' stable_dir; do
        local base_dir="${stable_dir%/stable}"
        local nightly_dir="${base_dir}/nightly"

        while IFS= read -r -d $'\0' path; do
            relative_path="${path#"${stable_dir}"/}"

            cmp -s "${stable_dir}/${relative_path}" "${nightly_dir}/${relative_path}" || continue # Files are different, so they stay

            error=1

            if [[ $frozen -eq 1 ]]; then
                echo_err "File ${stable_dir}/${relative_path} is the same between stable and nightly"
            else
                echo_err "File ${stable_dir}/${relative_path} is the same between stable and nightly, overwriting to unify"
                mkdir -p "$(dirname "${base_dir}/${relative_path}")" # in case there are sub-folders within stable
                mv "${stable_dir}/${relative_path}" "${base_dir}/${relative_path}"
                rm "${nightly_dir}/${relative_path}"
            fi

        done < <(find "${stable_dir}" -type f -name '*.rs' -print0)

    done < <(find "tests/fail" -type d -name stable -print0)

    return $error
}

# Runs the error message tests
# Usage: run_error_message_tests [<frozen>]
# Parameters:
#   $1: If 1, the tests will be run in frozen mode. Defaults to 0
function run_error_message_tests {
    local frozen="${1:-0}"

    if [[ $frozen -eq 1 ]]; then
        # In frozen mode, we only run the tests once, because
        # a) frozen does not auto-update, so you generally don't need to retry it,
        # b) frozen is used by CI, which can't ask for user input
        _internal_run_error_message_tests 1
        return 0
    fi

    while ! _internal_run_error_message_tests; do
        read -r -p "Retry error message tests? [Y/n] " response
        if [[ "$response" == "n" || "$response" == "N" ]]; then
            exit 1
        fi

        echo "Retrying..."
        echo ""
    done
}
