#!/usr/bin/env bash

cd "${0%/*}"

odin run tests.odin -file -collection:src=../../src -out:tests.exe 

if ([ $? -ne 0 ]) 
then 
	exit 1 
fi

# rols: odinfmt exits 1 on a file that does not parse, in stdout, -w and -stdin modes, and ends every error line with a newline
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
odin build main.odin -file -collection:src=../../src -out:"$dir/odinfmt" -o:none || exit 1
fail() {
	echo "FAIL odinfmt $1" >&2
	exit 1
}
printf 'package p\nf :: proc( {\n' >"$dir/bad.odin"
cp "$dir/bad.odin" "$dir/orig.odin"
for mode in stdout write stdin; do
	rc=0
	case $mode in
	stdout) "$dir/odinfmt" "$dir/bad.odin" >"$dir/out" 2>"$dir/err" || rc=$? ;;
	write) "$dir/odinfmt" -w "$dir/bad.odin" >"$dir/out" 2>"$dir/err" || rc=$? ;;
	stdin) "$dir/odinfmt" -stdin <"$dir/bad.odin" >"$dir/out" 2>"$dir/err" || rc=$? ;;
	esac
	[ $rc -eq 1 ] || fail "$mode: exit $rc on a parse error, expected 1"
	[ -s "$dir/out" ] && fail "$mode: wrote to stdout on a parse error"
	[ -s "$dir/err" ] || fail "$mode: printed no error"
	[ -z "$(tail -c1 "$dir/err")" ] || fail "$mode: error output does not end with a newline"
	cmp -s "$dir/bad.odin" "$dir/orig.odin" || fail "$mode: changed the file"
done
echo "odinfmt parse-error exit codes ok"
