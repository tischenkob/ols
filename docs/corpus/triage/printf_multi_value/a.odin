package p

import "core:fmt"
two :: proc() -> (f32, int) { return 1, 2 }
f :: proc() { fmt.printfln("%v %v", two()) }
