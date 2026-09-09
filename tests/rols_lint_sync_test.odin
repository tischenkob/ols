package tests

import "core:testing"

import test "src:testing"

@(private = "file")
packages := []test.Package {
	{
		pkg = "sync",
		source = `package sync
Mutex :: struct {}
RW_Mutex :: struct {}
Atomic_Int :: struct {}
mutex_lock :: proc(m: ^Mutex) {}
mutex_unlock :: proc(m: ^Mutex) {}
rw_mutex_shared_lock :: proc(m: ^RW_Mutex) {}
rw_mutex_shared_unlock :: proc(m: ^RW_Mutex) {}
lock :: proc(m: ^Mutex) {}
unlock :: proc(m: ^Mutex) {}
atomic_add :: proc(dst: ^int, val: int) -> int { return 0 }
atomic_or :: proc(dst: ^int, val: int) -> int { return 0 }
`,
	},
	{
		pkg = "os",
		source = `package os
read_entire_file :: proc(name: string) -> (data: []byte, ok: bool) { return nil, false }
`,
	},
}

@(private = "file")
source :: proc(main: string) -> test.Source {
	return test.Source{main = main, packages = packages, config = {enable_lint_sync = true}}
}

@(test)
lint_empty_critical_section :: proc(t: ^testing.T) {
	src := source(
		`package test

import "sync"

main :: proc() {
	m: sync.Mutex
	n: sync.Mutex
	sync.mutex_lock(&m)
	sync.mutex_unlock(&m)
	sync.mutex_lock(&m)
	sync.mutex_unlock(&n)
	sync.mutex_lock(&m)
	work()
	sync.mutex_unlock(&m)
}

work :: proc() {}
`,
	)

	test.expect_lint_diagnostics(t, &src, {{7, "empty-critical-section"}})
}

@(test)
lint_defer_lock :: proc(t: ^testing.T) {
	src := source(
		`package test

import "sync"

main :: proc() {
	m: sync.Mutex
	sync.mutex_lock(&m)
	defer sync.mutex_unlock(&m)
	defer sync.rw_mutex_shared_lock(nil)
}
`,
	)

	test.expect_lint_diagnostics(t, &src, {{8, "defer-lock"}})
}

@(test)
lint_atomic_self_assign :: proc(t: ^testing.T) {
	src := source(
		`package test

import "sync"

main :: proc() {
	x: int
	y: int
	x = sync.atomic_add(&x, 1)
	y = sync.atomic_or(&x, 1)
}
`,
	)

	test.expect_lint_diagnostics(t, &src, {{7, "atomic-self-assign"}})
}

@(test)
lint_lock_by_value :: proc(t: ^testing.T) {
	src := source(
		`package test

import "sync"

Holder :: struct {
	mu: sync.Mutex,
}

by_value :: proc(m: sync.Mutex) {}

by_pointer :: proc(m: ^sync.Mutex) {}

main :: proc() {
	h: Holder
	copied := h.mu
	n := h
}
`,
	)

	test.expect_lint_diagnostics(t, &src, {{8, "lock-by-value"}, {14, "lock-by-value"}})
}

@(test)
lint_defer_before_check :: proc(t: ^testing.T) {
	src := source(
		`package test

import "os"

main :: proc() {
	data, ok := os.read_entire_file("a")
	defer delete(data)
	if !ok {
		return
	}

	other, fine := os.read_entire_file("b")
	if !fine {
		return
	}
	defer delete(other)
}

delete :: proc(b: []byte) {}
`,
	)

	test.expect_lint_diagnostics(t, &src, {{6, "defer-before-check"}})
}
