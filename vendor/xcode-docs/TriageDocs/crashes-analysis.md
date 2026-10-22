# Apple Platform Crash Analysis Guide

## Overview

Analyze app crashes across Apple platforms (iOS, watchOS, macOS, tvOS, visionOS) using crash logs from Xcode Organizer. Identify root causes from exception types, callstacks, and thread state, and provide actionable recommendations.

**What is a Crash?** A crash is an abnormal process termination. The system captures the exception type, faulting thread, register state, and all thread backtraces at the moment of termination. Unlike performance telemetry (sampled over time), a crash log is a single snapshot of the moment of failure.

**Platform Differences:** The crash log format is the same across all Apple platforms. Key differences:

| Platform | Architecture | Common Platform-Specific Crashes |
|----------|-------------|----------------------------------|
| **iOS / iPadOS** | ARM64 | Background task terminations (`FRONTBOARD`, `ASSERTIOND`), memory pressure jetsams |
| **watchOS** | ARM64_32 | Tight memory limits, WatchConnectivity races, complication update deadlines |
| **macOS** | ARM64 / x86_64 | `SIGKILL` from hardened runtime violations, sandboxing `EXC_GUARD`, Rosetta translation issues (x86_64 on ARM) |
| **tvOS** | ARM64 | Memory jetsams (limited RAM), background execution restrictions |
| **visionOS** | ARM64 | Spatial computing framework crashes, scene lifecycle issues |

**Architecture Notes:**
- ARM64_32 (watchOS) uses 32-bit pointers in a 64-bit register file — fault addresses will be 32-bit
- x86_64 crash logs on macOS show different register names (`rax`, `rbx`, etc.) instead of ARM's `x0`-`x28`
- Universal binaries may crash in only one architecture slice — check the `Code Type` header field

## Crash Log Structure

A crash log has these sections, in order:

| Section | What It Contains |
|---------|-----------------|
| **Header** | Process name, bundle ID, version, hardware model, OS version, date/time |
| **Exception Info** | Exception type, subtype, termination reason, faulting address, VM region info |
| **Thread Backtraces** | Per-thread callstacks; crashed thread is marked explicitly |
| **Register State** | CPU register values at the moment of the crash (crashed thread only) — ARM64 (`x0`-`x28`) or x86_64 (`rax`, `rbx`, etc.) |
| **Binary Images** | Address ranges mapped to library names and UUIDs |

**How to Read Crash Callstacks:**
- Find the **crashed thread** (marked `Thread N Crashed:`)
- Read bottom-to-top: bottom frames are dispatch/pthread boilerplate; the interesting frames are near the top
- Frame 0 is where the crash occurred; frames above it show the call chain that led there
- Use the **Binary Images** section to map hex addresses to library names when frames are unsymbolicated

**Symbolication:** Many frames will be unsymbolicated (showing `0x... + offset` instead of function names). Frames in system libraries (UIKit, Foundation, libdispatch) can be identified by library name even without symbols. Frames in app code require the app's dSYM to symbolicate. When frames are unsymbolicated, describe what the surrounding symbolicated frames reveal and ask the developer to symbolicate.

**Identifying the Faulting Code:**
- Check the exception address and VM region info to understand *what* memory was accessed
- On ARM64: `x0`-`x3` hold method arguments; on x86_64: `rdi`, `rsi`, `rdx`, `rcx`
- A fault address near `0x0` (e.g., `0x4`, `0x8`) typically indicates a NULL pointer dereference with a small struct offset
- On watchOS (ARM64_32), fault addresses are 32-bit — a small address like `0x4` is still a NULL deref
- Cross-reference the crashed thread's callstack with other threads to identify potential races

## Exception Types

### EXC_BAD_ACCESS

Memory access violation — the most common crash type. The subtype tells you what happened:

| Subtype | Signal | Meaning |
|---------|--------|---------|
| `KERN_INVALID_ADDRESS` | SIGSEGV | Accessed unmapped memory (NULL deref, use-after-free, wild pointer) |
| `KERN_PROTECTION_FAILURE` | SIGBUS | Accessed mapped memory without permission (write to read-only, file-backed page unavailable) |
| `KERN_MEMORY_ERROR` | SIGBUS | Memory system error (often file-backed mapping failure) |
| `EXC_ARM_DA_ALIGN` | SIGBUS | Unaligned memory access |

**KERN_PROTECTION_FAILURE with mapped files:** Common on iOS/watchOS when accessing Class A (Complete Protection) files while the device is locked. Less common on macOS where file protection classes don't apply the same way. Check the VM region info for file mapping details.

### EXC_BAD_INSTRUCTION (SIGILL)

Invalid CPU instruction executed. Causes: compiler-inserted traps (Swift precondition failures, force-unwrap nil), memory corruption flipping instruction bits, or hardware issues (historically iPhone 6s).

### EXC_BREAKPOINT (SIGTRAP)

Software breakpoint hit. Common in: `__builtin_trap()` from assertion failures, Swift runtime traps (nil unwrap, array bounds), Objective-C `doesNotRecognizeSelector:`. Check the **termination reason** and **application-specific information** for context.

### EXC_CRASH (SIGABRT / SIGKILL / SIGQUIT)

| Signal | Meaning |
|--------|---------|
| **SIGABRT** | Process called `abort()` — check termination reason for the specific assertion or exception |
| **SIGKILL** | Killed by the system — check termination reason: `ASSERTIOND`, `SPRINGBOARD`, `CODESIGNING`, `LIBSYSTEM`, `FRONTBOARD` (scene lifecycle). On macOS: also `CODE_SIGNING` (hardened runtime), sandbox violations |
| **SIGQUIT** | Quit signal without handler — often XPC or keyboard extensions |

### EXC_GUARD

Kernel fault for protected resource misuse. Decode the exception code:

| Guard Type | Value | Meaning |
|------------|-------|---------|
| `GUARD_TYPE_MACH_PORT` | 0x1 | Mach port violation (over-deallocation, wrong right type, moving immovable port) |
| `GUARD_TYPE_FD` | 0x2 | File descriptor violation |
| `GUARD_TYPE_VN` | 0x4 | Vnode violation |
| `GUARD_TYPE_VIRT_MEMORY` | 0x5 | VM violation |

## Common Crash Patterns

| Pattern | What to Look For | Root Cause |
|---------|-----------------|------------|
| **NULL deref** | `KERN_INVALID_ADDRESS at 0x0`-`0x1000`, fault in `objc_msgSend` or property access | Messaging nil where non-nil expected, uninitialized pointer |
| **Use-after-free** | `KERN_INVALID_ADDRESS` at large/random address, crash in `objc_release`, `objc_retain`, `objc_msgSend` | Object deallocated while still referenced |
| **Data race on collection** | Crash in `mdict_rehashd`, `__NSArrayM objectAtIndex:`, `CFBasicHashAddValue` | Concurrent read/write on NSMutable* without synchronization |
| **Non-atomic property race** | Crash in property getter/setter, `objc_retain`/`objc_release` on wrong thread | Non-atomic property accessed from multiple threads |
| **UTF8String use-after-free** | Crash accessing `const char*` from `[NSString UTF8String]` | Buffer lifetime tied to autoreleased object, not the original string |
| **Weak ivar cleanup** | `weak_clear_no_lock` at crash site | Object with weak ivar freed without clearing weak refs |
| **CFNotificationCenter observer** | Crash in `objc_msgSend`/`objc_retain` inside notification callback | Raw pointer observer deallocated before notification fires |
| **Swift force-unwrap nil** | `EXC_BREAKPOINT` or `EXC_BAD_INSTRUCTION` in Swift runtime | Force-unwrapping Optional that is nil |
| **Code signing** | `EXC_BAD_ACCESS (SIGKILL - CODESIGNING)` in `vm_fault_enter` | Code signature validation failure on a mapped page |
| **Stack overflow** | `KERN_PROTECTION_FAILURE` with fault address near stack guard page, deep recursion in callstack | Unbounded recursion or excessive stack allocation |

## Multi-Thread Analysis

Crashes often involve more than just the crashed thread. Always check:

1. **Crashed thread** — where the fault occurred
2. **Other threads accessing shared state** — look for threads in the same framework/class at the same time (data race indicator)
3. **Thread 0 (main thread)** — what the app was doing when the crash happened (user context)
4. **Threads in same library** — multiple threads in the same framework may indicate a concurrency issue in that framework

**Data Race Detection:** If the crashed thread shows `objc_release`/`objc_retain`/`objc_msgSend` and another thread shows access to the same object or collection, suspect a data race.

## Output Template

```markdown
# [App Name] v[Version] Crash Analysis

**Exception:** [EXC_TYPE (SIGNAL)] — [SUBTYPE]
**Crashed Thread:** [N]
**Device/OS:** [Hardware Model], [Platform] [OS Version]

## Root Cause: [Title]

**Problem:** [What happened and why — one or two sentences.]

**Crashed Thread Callstack:**
FrameAtCrashSite()
  → CallingMethod()
  → EntryPoint()

[If multi-thread race: **Other Threads Involved:**]
Thread N:
  → [relevant frames showing concurrent access]

**Recommendations:**

1. [Primary fix]
2. [Secondary fix or diagnostic step]

**Investigate in your code:** [Specific class/method]
```

### Single Root Cause Principle

Don't split symptoms into separate issues. For example:
- Crash in `objc_msgSend` + another thread mutating the same dictionary = **one issue** (unsynchronized dictionary access), not two
- `KERN_INVALID_ADDRESS` in a callback + observer deallocation on another thread = **one issue** (observer lifetime management), not two

## Writing Guidelines

### Do
- Lead with the exception type and subtype — this frames the entire analysis
- Identify the crashed thread and read its callstack carefully
- Cross-reference other threads for concurrency issues
- Include specific class/method names from symbolicated frames
- Note what's unsymbolicated and ask the developer to fill gaps
- Reference the fault address and what it implies (NULL deref, wild pointer, etc.)

### Don't
- Speculate about unsymbolicated frames beyond what surrounding context reveals
- Repeat exception info that's already in the header
- Use emojis or status badges
- Include "AI Recommendations" or similar meta-labels
- Use tree/box-drawing characters
- Diagnose hardware issues from a single crash — need volume data

## Crash Classifications

Each crash can be classified into a known type based on its crash log signature. Classification drives the analysis — different crash types have different investigation techniques, root cause patterns, and fix strategies. Below are the classifications most relevant to 3rd party app analysis.

### Use-After-Free (UAF)

A UAF occurs when memory is freed but the pointer to it is subsequently dereferenced.

**Crash Log Signature:**
- `EXC_BAD_ACCESS (SIGSEGV)` — `KERN_INVALID_ADDRESS` at a large/random address
- Crash in `objc_release`, `objc_retain`, `objc_msgSend`, or `objc_destructInstance`
- Fault address in freed heap zone or containing zone poisoning patterns

**Common Code Patterns in 3rd Party Apps:**

| Pattern | Description |
|---------|-------------|
| Callback deletion | Event handler frees object; caller still uses it afterward |
| Autorelease pool drainage | Object autoreleased, pool drained, pointer still live |
| `__unsafe_unretained` | No ARC retention; object may be freed while referenced |
| Block capture | `__unsafe_unretained`/raw pointer captured in block; object freed before block runs |
| Toll-free bridging | `CFRelease` on bridged object while an ObjC reference is held |
| `performSelector:withObject:afterDelay:` | Target may be freed before the selector fires |
| NSNotificationCenter | Observer not removed before dealloc |
| `realloc` failure | `ptr = realloc(ptr, newsize)` — if it fails, the original pointer is freed |
| Container modification | Iterator invalidated during traversal |

**Investigation Steps:**
1. Trace the pointer timeline: allocation → assignments/copies → free → use-after-free
2. For callbacks/handlers: determine if the callback is synchronous (inline) or asynchronous (dispatched/deferred)
3. Check if the pointer is NULLed after the free
4. Check for aliases — other pointers to the same object
5. Verify if the free path cancels all pending callbacks (e.g., timer invalidation, `removeObserver` before free)

**Safe Patterns (Not a UAF):**
- Pointer NULLed immediately after free
- ObjC ARC `__strong` keeps object alive (not `__unsafe_unretained`)
- ObjC block captures `__weak` with nil check before use
- All ops serialized under a single mutex or serial queue
- Free path cancels all pending async callbacks

**Recommended Fixes:**
- Use `__weak` instead of `__unsafe_unretained`; nil-check before use
- Remove observers/delegates in `dealloc` or `deinit`
- Cancel timers and pending `performSelector:` calls before deallocation
- Use RAII/smart pointers in C++ code to manage lifetimes correctly
- Enable Zombies (`NSZombieEnabled`) during debugging to identify the freed object

### Data Race (Sentinel Value 0x400000000000bad0)

A data race crash with the sentinel fault address `0x400000000000bad0` is injected by the Objective-C runtime to deliberately crash when concurrent threads access a strong object pointer without synchronization. This is not a "torn pointer" — ARM64 aligned 8-byte stores are hardware-atomic. The sentinel is deliberately injected.

**Crash Log Signature:**
- `EXC_BAD_ACCESS (SIGSEGV)` with `FAR: 0x400000000000bad0`
- Crash in `objc_retain_x8`, `objc_release`, or `objc_msgSend`
- Another thread visible in the crash log accessing the same object/property

**Three Distinct Patterns:**

**Pattern 1: Getter/Setter Race (~60%)**
One thread calls a getter while another calls a setter on the same `@property(nonatomic, strong)` property.
- *Crash thread:* `objc_retain_x8` inside property getter
- *Racing thread:* setter or method writing to the same property
- *Fix:* Change property from `nonatomic` to `atomic`, or synchronize with a serial queue

**Pattern 2: Dealloc-on-Wrong-Thread Race (~30%)**
Main thread accesses object properties while a background thread deallocates the same object via a cleanup chain.
- *Crash thread:* main thread accessing properties
- *Racing thread:* background thread in `dealloc`/`.cxx_destruct`/`CVPixelBufferRelease`
- *Fix:* Fix nested block retain chains; dispatch final operations to main queue; ensure UI object deallocation on main thread

**Pattern 3: Semaphore Timeout Race (~10%)**
Main thread accesses `__block` variables after a semaphore times out, while an async callback is still modifying them.
- *Crash thread:* accessing shared variables after `dispatch_semaphore_wait` timeout
- *Racing thread:* async callback still modifying the same variables
- *Fix:* Add completion tracking — only access shared variables if `waitResult == 0 && callbackCompleted`

**Investigation Steps:**
1. Verify `FAR = 0x400000000000bad0` across all crash logs
2. Identify which specific property/object caused the crash via disassembly
3. Find the racing thread and determine the pattern (getter/setter, dealloc, or semaphore)
4. For Pattern 1: verify both threads access the same memory offset on the same object instance
5. For Pattern 2: trace object lifecycle through nested completion blocks

### Race Condition

Race conditions arise when two or more threads access the same memory location concurrently, at least one access is a write, and there is no happens-before ordering.

**Crash Log Signature:**
- `EXC_BAD_ACCESS` with crash in collection methods (`mdict_rehashd`, `__NSArrayM objectAtIndex:`, `CFBasicHashAddValue`)
- Crash in `objc_retain`/`objc_release` with another thread accessing the same data
- No `0x400000000000bad0` sentinel (that's a data race — related but distinct)

**Critical Patterns for 3rd Party Apps:**

| Pattern | Description |
|---------|-------------|
| Unprotected shared variable | Global or heap variable read/written by multiple threads without mutex |
| Check-then-act | `if (ptr != NULL) use(ptr)` where `ptr` freed between check and use |
| Read-modify-write | `counter++` without atomic operation or lock |
| Non-atomic property access | Non-atomic property accessed from multiple threads |
| Mutable collection concurrent access | `NSMutableDictionary`/`NSMutableArray` mutated while being read |

**Synchronization Primitives to Check:**
- `pthread_mutex_lock`/`unlock` — verify proper pairing
- `dispatch_sync`/`dispatch_async` (GCD) — enforce queue isolation
- `os_unfair_lock` — non-recursive, cannot check ownership
- `@synchronized` (Objective-C) — reentrant but coarse-grained
- `std::mutex`, `std::atomic` (C++) — standard library equivalents
- `_Atomic` / `__atomic_load` / `__atomic_store` — atomic operations

**Recommended Fixes:**
- Synchronize mutable collection access with serial queue or lock; return immutable copies from getters
- Use `_Atomic` or `std::atomic` for simple counters and flags
- Protect check-then-act sequences under the same lock
- Use GCD serial queues for all access to shared state

### Double Free

A double free occurs when the same memory address is freed twice without an intervening reallocation, corrupting heap metadata.

**Crash Log Signature:**
- `EXC_BAD_ACCESS` or `SIGABRT` from heap corruption detection
- Crash in `free()`, `objc_release`, or allocator internals
- malloc zone errors: "pointer being freed was not allocated"

**Common Code Patterns:**

| Pattern | Description |
|---------|-------------|
| Direct double free | `free(ptr); ... free(ptr);` with no reassignment between calls |
| Error path double free | Normal cleanup frees `ptr`; error handler also frees `ptr` |
| Ownership confusion | Caller frees a buffer; callee also frees the same buffer |
| Conditional double free | `free(ptr)` inside an `if`-branch; unconditional `free(ptr)` follows |
| Aliased double free | `ptr2 = ptr; free(ptr); free(ptr2);` |
| Race-induced | Two threads independently free the same pointer due to missing synchronization |

**Recommended Fixes:**
- NULL the pointer immediately after `free()` — `free(NULL)` is a safe no-op
- Establish clear ownership contracts — only one party frees
- Audit error paths for asymmetric cleanup (the most common source)
- Use smart pointers (`std::unique_ptr`, `std::shared_ptr`) in C++ to manage ownership

### Out-of-Bounds Write (Buffer Overflow)

Data is written beyond allocated memory bounds, corrupting adjacent memory.

**Crash Log Signature:**
- `EXC_BAD_ACCESS` — `KERN_INVALID_ADDRESS` at address near but outside a valid allocation
- Crash in `memcpy`, `memmove`, `strcpy`, or similar memory operations
- Heap corruption detected on a subsequent allocation/free
- `EXC_BREAKPOINT (SIGTRAP)` with ESR `0xf2005519` if caught by `-fbounds-safety` instrumentation

**Common Code Patterns:**

| Pattern | Description |
|---------|-------------|
| Stack buffer overflow | `char buf[256]; strcpy(buf, user_input);` |
| Heap buffer overflow | `malloc(size); memcpy(ptr, src, larger_size);` |
| Off-by-one | `for(i=0; i<=len; i++)` — includes one extra element |
| Integer overflow in size | `malloc(n * sizeof(T))` wraps to small value, subsequent write overflows |
| Unbounded loop | `while(*src) *dst++ = *src++;` — no length check |
| Unguarded array index | `arr[attacker_count].field = value;` — no bounds check |

**Investigation Steps:**
1. Identify the buffer allocation — record size in bytes
2. Identify the write operation — record offset and length in bytes
3. Calculate whether the write can exceed the allocation bounds
4. Check for size validation before the write
5. Trace size values back to their source — is the size externally controlled?

**Recommended Fixes:**
- Use bounded string functions (`strlcpy`, `snprintf`) instead of unbounded ones (`strcpy`, `sprintf`)
- Always use `<` instead of `<=` for array access loop bounds
- Use destination buffer size, not source size, for copy operations
- Validate all externally-provided sizes and indices before use
- Use `__builtin_mul_overflow` for size calculations to detect overflow

### Integer Overflow / Underflow

**Overflow:** Arithmetic operations produce results outside the representable range, wrapping around. Used in allocation sizes, bounds checks, or copy lengths.

**Underflow:** Unsigned subtraction wraps below zero, producing a huge positive value.

**Crash Log Signature:**
- Often manifests as a secondary crash — OOB write, heap corruption, or massive allocation failure
- `EXC_BAD_ACCESS` from writing to an undersized buffer allocated via an overflowed size
- `SIGABRT` from failed `malloc()` of an impossibly large size (underflow)

**Common Code Patterns:**

| Pattern | Trigger | Result |
|---------|---------|--------|
| `count * sizeof(T)` | Large `count` | Wraps to small value → undersized allocation |
| `header_len + data_len` | Large values | Wraps to small value |
| `(size_t)negative_int` | Negative `int` cast | Becomes huge `size_t` |
| `wLength - 1` (unsigned) | `wLength == 0` | Wraps to `UINT_MAX` |
| `total - header` (unsigned) | `header > total` | Wraps to huge positive |

**Recommended Fixes:**
- Use `__builtin_mul_overflow`, `__builtin_add_overflow`, `__builtin_sub_overflow` for checked arithmetic
- Add explicit pre-checks: `if (a > SIZE_MAX / b)` before `a * b`
- Use saturation arithmetic: `result = (a > b) ? (a - b) : 0`
- Validate unsigned values are non-zero before subtracting 1
- Avoid mixing signed and unsigned types in comparisons

### Type Confusion

Data is created as one type but accessed as a different, incompatible type, leading to memory corruption from field accesses at wrong offsets.

**Crash Log Signature:**
- `EXC_BAD_ACCESS` at unexpected offsets within objects
- `doesNotRecognizeSelector:` when an object is not the expected class
- Crash in vtable dispatch when C++ object is the wrong derived type

**Common Code Patterns in 3rd Party Apps:**

| Pattern | Description |
|---------|-------------|
| Wrong toll-free bridge | Casting `CFDataRef` as `NSString*` (only documented pairs are valid) |
| `id` type erasure | Erases type info like `void*`; casting to wrong concrete class |
| `NSCoding` deserialization | Deserialized object may not match expected class |
| `__bridge_transfer` misuse | Wrong bridge cast direction corrupts reference count |
| `static_cast` downcast (C++) | Downcast without `dynamic_cast` validation |
| Union misuse | Writing one union member, reading another |

**Recommended Fixes:**
- Use `isKindOfClass:` / `conformsToProtocol:` checks before casting in Objective-C
- Use `dynamic_cast` with nullptr check in C++ (instead of `static_cast`)
- Use `NSSecureCoding` with explicit class check in `initWithCoder:`
- Only toll-free bridge between documented compatible pairs
- Validate type tags before accessing union/variant members

### Recursion (Stack Overflow)

Excessive recursion causing the call stack to exceed the thread's stack space.

**Crash Log Signature:**
- `EXC_BAD_ACCESS (SIGSEGV)` — `KERN_PROTECTION_FAILURE`
- Fault address in the `STACK GUARD` region (verify via VM Region Info)
- `___chkstk_darwin` at Frame 0
- `RECURSION LEVEL` markers in the stack trace
- Exception message: "Thread stack size exceeded due to excessive recursion"

**Identification — All Four Must Be Present:**
1. Exception message about excessive recursion
2. Fault address in `STACK GUARD` region (not just any `KERN_PROTECTION_FAILURE`)
3. `___chkstk_darwin` at crash point
4. Recursion level markers or repeating call patterns in the stack trace

**Common Root Cause Patterns:**

| Pattern | Description |
|---------|-------------|
| Circular data references | e.g., `aria-labelledby` forming cycles in accessibility tree |
| Missing base case | Recursion never terminates for certain inputs |
| Mutual recursion | `functionA()` calls `functionB()` which calls `functionA()` |
| Deeply nested input | JSON/XML parsing of deeply nested structures |

**Key Analysis Insight:** The root cause is at the *top* of the stack (where recursion began), not the *bottom* (where the crash occurred).

**Recommended Fixes:**
- Add recursion depth limits: `if (depth > MAX_DEPTH) return;`
- Add cycle detection with a visited set
- Convert to iterative algorithm with explicit stack
- Validate input depth before recursive processing
- Prevent circular references at creation time

**Not a Recursion Crash If:**
- Fault address is NOT in the STACK GUARD region (even with `KERN_PROTECTION_FAILURE`)
- No repeating call pattern — may be large stack frames from local variables instead
- Recursion depth bounded by input size — legitimate deep recursion, not an infinite loop bug

### Infrastructure Framework Crashes

Crashes in infrastructure frameworks (libobjc, Foundation, CoreFoundation, libdispatch) where the crash location is NOT where the bug resides. The bug is in the *calling* code.

**Critical Principle:** Focus analysis on the calling framework's code, not the infrastructure crash location. Infrastructure code is well-tested — if it crashes, the calling code likely passed invalid parameters, violated API contracts, created data races, or managed object lifecycles incorrectly.

**Common Patterns:**

| Crash Location | Root Cause in App Code |
|----------------|----------------------|
| `objc_msgSend` + 8 | App passed a freed/deallocated object as message receiver |
| `objc_loadWeak` / `objc_loadWeakRetained` | Weak reference to freed memory not zeroed — observer not unregistered before dealloc |
| `doesNotRecognizeSelector:` | Use-after-free (over-released object), wrong type cast, or missing `respondsToSelector:` check |
| KVO `removeObserver:forKeyPath:` | Observer not properly registered/unregistered, cleanup order issue |
| `NSHashTable` weak ref crash | Hash table resize racing with iteration, concurrent access |

**Investigation Steps:**
1. Find the first non-infrastructure frame in the stack — that's the investigation target
2. Determine what object or data the app passed to the infrastructure API
3. Why was the object or data invalid? Freed too early? Never allocated? Wrong type?
4. What API contract was violated?

### WebKit Diagnostic (CRASH_WITH_INFO)

WebKit-specific crashes that encode diagnostic values into CPU registers before deliberately triggering a crash. Relevant for 3rd party apps using `WKWebView`.

**Crash Log Signature:**
- `EXC_BREAKPOINT (SIGTRAP)` with ESR `0xf200c471` (ARM64)
- Frame 0 in `JavaScriptCore` — `WTFCrashWithInfoImpl`
- Frame 1 in WebKit/WebCore — the actual crash location

**3rd Party App Relevance:** If a crash occurs inside WebKit while the app uses `WKWebView`, decode the diagnostic registers to understand the failure:
- `x16` (ARM64) / `r11` (x86_64) = first diagnostic value (often an error code)
- `x17` / `r10` = second diagnostic value (often a message name)

Common scenarios: XPC connection invalid destination, IPC protocol violation, resource exhaustion.

**Recommended Action:** File a Feedback Assistant report with the crash log. These crashes are inside WebKit's code — the 3rd party app should check for patterns that trigger the issue (e.g., rapid web view creation/destruction, complex JavaScript execution).

### Bounds Safety

Runtime bounds checking from `-fbounds-safety` compiler instrumentation. These crashes are triggered by system frameworks compiled with bounds checking.

**Crash Log Signature:**
- `EXC_BREAKPOINT (SIGTRAP)` with ESR `0xf2005519` (ARM64)
- Crash at a trap instruction (`brk #0x5519`)
- Centralized trap pattern: Frame 0 is misleading (shared trap location); begin analysis at Frame 1

**3rd Party App Relevance:** These crashes typically occur inside Apple system frameworks when the app passes invalid data that causes an out-of-bounds access within the framework. The app should validate the data it passes to system APIs.

**Distinguishing from Other Traps (ARM64):**

| ESR Value | Instruction | Source |
|-----------|-------------|--------|
| `0xf2005519` | `brk #0x5519` | Bounds safety (`-fbounds-safety`) |
| `0xf200c471` | `brk #0xc471` | WebKit `CRASH_WITH_INFO` |
| `0xf2000001` | `brk #0x1` | C++ assertion / `__builtin_trap` |
| `0xf2000000` | `brk #0x0` | ASAN-enabled WebKit |

## Common Fixes Reference

| Problem | Fix |
|---------|-----|
| Data race on mutable collection | Synchronize with serial queue or lock; return immutable copies from getters |
| Non-atomic property race | Mark property `atomic`, or use lock/serial queue for all access |
| Getter/setter race (0x400000000000bad0) | Change `@property(nonatomic)` to `@property(atomic)`, or use queue synchronization for read-modify-write |
| Dealloc-on-wrong-thread race | Fix nested block retain chains; dispatch final operations to main queue |
| Semaphore timeout race | Add completion tracking — only access shared variables if callback completed |
| UTF8String use-after-free | Copy the C string immediately with `strcpy()`, or keep the NSString alive |
| Use-after-free (general) | Use `__weak` instead of `__unsafe_unretained`; remove observers in dealloc; cancel pending selectors |
| Double free | NULL pointer after free; establish clear ownership; audit error paths for asymmetric cleanup |
| Weak ivar not cleared | Call `objc_destroyWeak()` before dealloc, or use `__weak` keyword instead of manual weak refs |
| CFNotificationCenter observer dangling | Pass `_CFNotificationObserverIsObjC` flag, or remove observer before dealloc |
| Force-unwrap nil | Use `guard let` / `if let`, or fix the upstream code that produces nil |
| File unavailable when locked | Use a less restrictive data protection class, or handle the error gracefully |
| Mach port over-deallocation | Audit port lifecycle — use `portleakwatch` for diagnostics |
| Stack overflow / recursion | Add recursion depth limit, add cycle detection, convert to iterative algorithm |
| Buffer overflow / OOB write | Use bounded functions (`strlcpy`, `snprintf`); validate sizes; use `<` not `<=` in loops |
| Integer overflow in size calc | Use `__builtin_mul_overflow`; pre-check `if (a > SIZE_MAX / b)` |
| Integer underflow | Check for zero before subtracting; use saturation: `(a > b) ? (a - b) : 0` |
| Type confusion | Use `isKindOfClass:` / `dynamic_cast` before casting; use `NSSecureCoding` |
| Infrastructure crash | Focus on calling code, not infrastructure — check object lifecycle, API contracts, threading |

## Example Output

```markdown
# ResearchWatch v7.1.1 Crash Analysis

**Exception:** EXC_BAD_ACCESS (SIGSEGV) — KERN_INVALID_ADDRESS at 0x0000000000000004
**Crashed Thread:** 14
**Device/OS:** Watch5,10, watchOS 10.6.1

## Root Cause: NULL Pointer Dereference in WatchConnectivity Dispatch

**Problem:** Thread 14 crashed in libdispatch attempting to read memory at address 0x4, which is a NULL pointer dereference with a small struct offset. The dispatch call originated from WatchConnectivity framework code. Multiple other threads (4, 8, 9, 11, 12, 13) are also blocked inside WatchConnectivity at the same offset, suggesting a shared resource issue or race condition within WatchConnectivity session handling.

**Crashed Thread Callstack:**
libdispatch.dylib + 105024 [crash site — NULL deref]
  → WatchConnectivity + 80372
  → libdispatch work queue

**Other Threads Involved:**
Threads 4, 8, 9, 11-13 all show identical stacks blocked in WatchConnectivity + 80396 via libobjc `objc_msgSend` → `libsystem_platform`, indicating contention or waiting on the same resource.

Thread 1 shows `WatchSettingsCache.watchSettingsMessageReceived(_:)` processing an incoming application context message at the same time.

**Recommendations:**

1. The crash is inside Apple's WatchConnectivity framework, not in app code. File a Feedback Assistant report with this crash log attached.
2. Review `WatchMessageReliabilityController` and `WatchConnectivityControllerWatch` for patterns that could trigger rapid concurrent WatchConnectivity calls — serializing session delegate callbacks may reduce the likelihood of hitting this framework bug.
3. Ensure `WCSession` delegate methods are not re-entering WatchConnectivity APIs synchronously from within callbacks.

**Investigate in your code:** `WatchMessageReliabilityController.handleMessage(_:replyHandler:)` and `WatchConnectivityControllerWatch.init(factory:delegate:)`
```
