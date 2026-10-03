package p

import "core:sync"
m: sync.Mutex
f :: proc() { sync.mutex_guard(&m) }
