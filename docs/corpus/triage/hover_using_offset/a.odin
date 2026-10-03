package p

Base :: struct { magic: int }
Derived :: struct { using base: Base, extra: int }
use :: proc(d: ^Derived) { d.magic = 1 }
