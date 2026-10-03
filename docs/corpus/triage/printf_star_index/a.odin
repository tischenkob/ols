package p

import "core:fmt"
f :: proc() -> string { return fmt.aprintf("%- *[1]s|", "ab", 6) }
