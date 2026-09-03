#!/usr/bin/env bash
# Applies "Invert if" twice to each shape below with ./ols, compiles after each step, and checks
# the second application gives the shape back. A `do` body comes back as a block, so those shapes
# carry their own expected text.
set -u
cd "$(dirname "$0")/.."
OLS=${OLS:-./ols}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src"
fail=0
cases=()
onces=()
absents=()

# shape NAME PATTERN: the source on stdin; PATTERN names the line holding the `if`.
shape() { cat > "$work/src/$1.odin"; cases+=("$1|$2"); }
# expect NAME: the text expected after two inversions, when it differs from the shape.
expect() { cat > "$work/src/$1.expected"; }
# once NAME PATTERN TITLE: apply TITLE once to the shape and compile.
once() { onces+=("$1|$2|$3"); }
# absent NAME PATTERN TITLE: TITLE is not offered on the shape.
absent() { absents+=("$1|$2|$3"); }

compiles() {
	local out
	if ! out=$(odin check "$1" -no-entry-point 2>&1); then
		echo "FAIL $2: does not compile"
		echo "$out"
		cat "$1/main.odin"
		fail=1
		return 1
	fi
}

# Copies shape NAME into package DIR and prints FILE:LINE:COL of the `if` on the PATTERN line.
target() {
	local name=$1 dir=$work/$2 pattern=$3
	mkdir -p "$dir"
	cp "$work/src/$name.odin" "$dir/main.odin"
	local line col
	line=$(grep -n -m1 -F "$pattern" "$dir/main.odin" | cut -d: -f1)
	col=$(awk -v n="$line" 'NR==n{print index($0, "if ")}' "$dir/main.odin")
	echo "$dir/main.odin:$line:$col"
}

apply() {
	if ! $OLS query actions "$1" --root "$(dirname "$1")" --apply "$2" >/dev/null 2>"$work/err"; then
		echo "FAIL $3: cannot apply $2"
		cat "$work/err"
		fail=1
		return 1
	fi
}

shape plain 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	x := 1
	if x > 0 {
		foo()
	}
}
EOF

shape spaces 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
    x := 1
    if x > 0 {
        foo()
    }
}
EOF

shape do_body 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	x := 1
	if x > 0 do foo()
}
EOF
expect do_body <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	x := 1
	if x > 0 {
		foo()
	}
}
EOF

shape else_do 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}
bar :: proc() {}

main :: proc() {
	x := 1
	if x > 0 {
		foo()
	} else do bar()
}
EOF
expect else_do <<'EOF'
package smoke

foo :: proc() {}
bar :: proc() {}

main :: proc() {
	x := 1
	if x > 0 {
		foo()
	} else {
		bar()
	}
}
EOF

shape chain_with_else 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}
bar :: proc() {}
baz :: proc() {}

main :: proc() {
	x := 1
	if x > 0 {
		foo()
	} else if x < 0 {
		bar()
	} else {
		baz()
	}
}
EOF

shape chain_without_else 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}
bar :: proc() {}

main :: proc() {
	x := 1
	if x > 0 {
		foo()
	} else if x < 0 {
		bar()
	}
}
EOF

shape comments 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}
bar :: proc() {}

main :: proc() {
	x := 1
	if x > 0 {
		// leading
		foo() // trailing
		bar()
		// end of block
	} else {
		// only a comment
	}
}
EOF

shape multi_line_call 'if x > 0' <<'EOF'
package smoke

foo :: proc(a, b: int) {}

main :: proc() {
	x := 1
	if x > 0 {
		foo(
			x,
			x + 1,
		)
	}
}
EOF

shape nested_if 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	x := 1
	if x > 0 {
		if x > 1 {
			foo()
		}
	}
}
EOF

shape init 'if v, ok' <<'EOF'
package smoke

foo :: proc(v: int) {}

main :: proc() {
	m := map[string]int{}
	k := "k"
	if v, ok := m[k]; ok {
		foo(v)
	}
}
EOF

shape label 'lbl: if' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	x := 1
	lbl: if x > 0 {
		foo()
		break lbl
	}
}
EOF

shape cond_not 'if !x' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	x := true
	if !x {
		foo()
	}
}
EOF

shape cond_and 'if a && b' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	a, b := true, false
	if a && b {
		foo()
	}
}
EOF

shape cond_or 'if a || b' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	a, b := true, false
	if a || b {
		foo()
	}
}
EOF

shape cond_not_and 'if !(a && b)' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	a, b := true, false
	if !(a && b) {
		foo()
	}
}
EOF

shape cond_in 'if x in set' <<'EOF'
package smoke

foo :: proc() {}

Flag :: enum {
	A,
	B,
}

main :: proc() {
	x := Flag.A
	set := bit_set[Flag]{.A}
	if x in set {
		foo()
	}
}
EOF

shape cond_lt 'if a < b' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	a, b := 1, 2
	if a < b {
		foo()
	}
}
EOF

shape cond_call 'if cond()' <<'EOF'
package smoke

foo :: proc() {}
cond :: proc() -> bool { return true }

main :: proc() {
	if cond() {
		foo()
	}
}
EOF

shape cond_paren_eq 'if (a == b)' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	a, b := 1, 2
	if (a == b) {
		foo()
	}
}
EOF

shape cond_nil 'if p == nil' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	p: ^int
	if p == nil {
		foo()
	}
}
EOF

shape cond_ident 'if ok {' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	ok := true
	if ok {
		foo()
	}
}
EOF

shape in_for 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	for x in 0 ..< 3 {
		if x > 0 {
			foo()
			continue
		}
		foo()
	}
}
EOF
once in_for 'if x > 0' 'Invert if (early continue)'

shape in_for_last 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	for x in 0 ..< 3 {
		foo()
		if x > 0 {
			foo()
		}
	}
}
EOF
once in_for_last 'if x > 0' 'Invert if (early continue)'

shape in_case 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	x := 1
	switch x {
	case 1:
		if x > 0 {
			foo()
			break
		}
		foo()
	case:
		foo()
	}
}
EOF
once in_case 'if x > 0' 'Invert if (early break)'

shape in_case_last 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	x := 1
	switch x {
	case 1:
		if x > 0 {
			foo()
		}
	case:
		foo()
	}
}
EOF
once in_case_last 'if x > 0' 'Invert if (early break)'

shape case_fallthrough 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	x := 1
	switch x {
	case 1:
		if x > 0 {
			foo()
		}
		fallthrough
	case:
		foo()
	}
}
EOF
absent case_fallthrough 'if x > 0' 'Invert if (early break)'

shape in_when 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	x := 1
	when ODIN_OS == .Darwin {
		if x > 0 {
			foo()
		}
	}
}
EOF

shape with_defer 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}
bar :: proc() {}

main :: proc() {
	x := 1
	if x > 0 {
		defer bar()
		foo()
	}
}
EOF
once with_defer 'if x > 0' 'Invert if (early return)'

shape early_return_shape2 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}
bar :: proc() {}

main :: proc() {
	x := 1
	if x > 0 {
		foo()
		return
	}
	bar()

	// between
	bar()
}
EOF
once early_return_shape2 'if x > 0' 'Invert if (early return)'

shape proc_with_results 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() -> int {
	x := 1
	if x > 0 {
		foo()
	}
	return x
}
EOF
absent proc_with_results 'if x > 0' 'Invert if (early return)'

shape in_for_not_last 'if x > 0' <<'EOF'
package smoke

foo :: proc() {}

main :: proc() {
	for x in 0 ..< 3 {
		if x > 0 {
			foo()
		}
		foo()
	}
}
EOF
absent in_for_not_last 'if x > 0' 'Invert if (early continue)'

for case in "${cases[@]}"; do
	name=${case%%|*}
	pattern=${case#*|}
	at=$(target "$name" "$name" "$pattern")
	dir=$(dirname "$at")
	compiles "$dir" "$name original" || continue
	apply "$at" "Invert if" "$name first" || continue
	compiles "$dir" "$name after first inversion" || continue
	apply "$at" "Invert if" "$name second" || continue
	compiles "$dir" "$name after second inversion" || continue
	expected=$work/src/$name.expected
	[ -f "$expected" ] || expected=$work/src/$name.odin
	if ! diff -u "$expected" "$dir/main.odin"; then
		echo "FAIL $name: round trip differs"
		fail=1
	fi
done

for entry in "${onces[@]}"; do
	IFS='|' read -r name pattern title <<< "$entry"
	at=$(target "$name" "${name}_once" "$pattern")
	apply "$at" "$title" "$name" || continue
	compiles "$(dirname "$at")" "$name after $title"
done

for entry in "${absents[@]}"; do
	IFS='|' read -r name pattern title <<< "$entry"
	at=$(target "$name" "${name}_absent" "$pattern")
	if $OLS query actions "$at" --root "$(dirname "$at")" 2>/dev/null | grep -qF "$title"; then
		echo "FAIL $name: $title offered"
		fail=1
	fi
done

if [ $fail -ne 0 ]; then
	echo "smoke failed"
	exit 1
fi
echo "smoke passed: ${#cases[@]} shapes"
