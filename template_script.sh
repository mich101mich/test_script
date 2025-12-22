#!/bin/bash -e

base_dir="$(realpath "$(dirname "$0")")"
sub_directories="" # fill with a space-separated list of subdirectories if needed
is_proc_macro=0 # set to 1 if crate is a procedural macro crate

export base_dir sub_directories is_proc_macro

"${base_dir}/submodules/test_script/test.sh" "$@"
