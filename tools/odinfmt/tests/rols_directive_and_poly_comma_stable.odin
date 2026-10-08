package odinfmt_test

import "base:intrinsics"

single_value :: proc(a: []u8, i: int) -> bool {
	#no_bounds_check return a[i] != 0
}

several_values :: proc(a: []u8, i: int) -> (u8, bool) {
	#no_bounds_check return a[i], true
}

call_value :: proc(a: []u8, i: int) -> int {
	#no_bounds_check return int(a[i])
}

type_assert :: proc(a: any) -> int {
	#no_type_assert return a.(int)
}

lookup :: proc(key: string) -> (int, bool) #optional_ok

unchecked :: proc(a: []u8) -> u8 #no_bounds_check

Typed_Array :: struct(
	$T: typeid,
) where intrinsics.type_is_numeric(T) ||
	intrinsics.type_is_string(T) ||
	intrinsics.type_is_boolean(T) {
	x: int,
}
