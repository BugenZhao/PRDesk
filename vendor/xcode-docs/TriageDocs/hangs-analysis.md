# iOS Hang Performance Analysis Guide

## Overview

Analyze iOS app hang performance using sample logs from Xcode Organizer. Identify main thread blocking and provide actionable recommendations.

**What is a Hang?** A hang occurs when the main thread runloop doesn't turn for >250ms. Users cannot interact with the app during a hang. Xcode Organizer reports hangs of ≥1 second.

## Log Interpretation

**Sample Count Conversion:** `sampleCount × 10 = milliseconds`

**Callstack Reading:** Top = earliest, Bottom = where time is spent. High sampleCounts at bottom indicate where the hang occurs.

**Reading APIs and Leaf Nodes:** Always examine both the API-level calls (higher in the stack — what initiated the work) and the leaf nodes (bottom of the stack — where time is actually spent). The APIs tell you *what* the app is trying to do; the leaf nodes tell you *how* it's blocking. Don't assume a method name like `accquireLockAndPerformAction:` in user code means an actual lock is being taken — method names in user code can be misleading. A real lock or blocking primitive will show up in Apple/system code at the leaf nodes of the callstack (e.g., `os_unfair_lock_lock`, `pthread_mutex_lock`, `__ulock_wait`). Always look at the leaf nodes to confirm actual blocking.

**Hang Details Field:** "X ms spent in this code path during a Y ms hang"

### Multi-Branch Callstacks

Hang logs often contain callstacks that branch into multiple code paths. This happens when the sampler captures time spent in different operations during the same hang.

**Data Structure:**
- The `sampledExecutionTree` is a nested array of frame objects
- Each frame has a `childrenCount` field — when this is >1, the callstack forks into multiple branches
- Each branch has its own `sampleCount` indicating how many samples went through that path
- The `rawFrame` string is prefixed with a branch number (e.g., `"1 "`, `"2 "`) to indicate which branch the frame belongs to

**How to Read Branches:**
- A frame with `childrenCount: 2` and `sampleCount: 39` that forks into a branch with `sampleCount: 29` and another with `sampleCount: 10` means 29 samples went through one code path and 10 through another
- Both branches contribute to the total hang duration
- Analyze each branch independently to understand what work is happening on each path
- **Always focus on the heaviest branch** (highest sample count) — this is where the most time is being spent and should be the basis for the issue you call out. Don't report an issue found in a lighter branch as the primary problem.

## Anti-Patterns to Detect

Scan callstacks for these blocking primitives on main thread:

| Category | Primitives | Typical Impact |
|----------|-----------|----------------|
| **Conditional Waiting** | `pthread_cond_wait`, `dispatch_group_wait_slow`, `dispatch_semaphore_wait_slow` | 50-200ms+ |
| **Lock Contention** | `pthread_mutex_lock`, `os_unfair_lock_lock` | 10-100ms+ |
| **Sync XPC** | `xpc_connection_send_message_reply_sync` | See "XPC-Backed Framework APIs" below |
| **File I/O** | `read`, `write`, `open`, `stat`, `pread` | 20-200ms+ |
| **Sleep** | `[NSThread sleepForTimeInterval:]`, `usleep`, `sleep` | Exact duration |
| **Dynamic Loading** | `dlopen`, `dlsym` | 50-300ms+ |

**XPC-Backed Framework APIs:** When you see `xpc_connection_send_message_reply_sync` in a callstack, don't call out XPC itself as the problem. The real issue is the *framework API* higher in the callstack that uses XPC internally. These are the known APIs that perform synchronous XPC on the main thread:

| Framework | Class | Problematic Methods |
|-----------|-------|---------------------|
| **Photos** | `PHAsset`, `PHFetchResult` | `fetch*`, `enumerate*` methods |
| **CoreLocation** | `CLLocationManager` | `authorizationStatus`, `monitoredRegions`, `accuracyAuthorization`, `locationServicesEnabled` |
| **AVFoundation** | `AVAsset` | `tracksWithMediaType:` |
| **AVFAudio** | `AVAudioSession` | `setActive:withOptions:error:`, `category`, `setCategory:*`, `currentRoute`, `outputVolume`, `isPiPAvailable` |
| **StoreKit** | `SKPaymentQueue` | `storefront` |

When reporting, call out the framework API (e.g., "PHAsset.fetchAssets on main thread") not the underlying XPC primitive.


## Common Bottleneck Patterns

Use this to identify *what* is causing the anti-pattern when you see blocking primitives.

| Category | Look For In Callstack | Common Culprits |
|----------|----------------------|-----------------|
| **Database** | `CoreData`, `SQLite`, `NSPersistentStore`, `executeFetchRequest`, `Realm` | Sync fetch in UI callback, write transaction on main thread |
| **Network** | `URLSession`, `NSURLConnection`, `CFNetwork` | Sync URL request, API call blocking UI update |
| **File I/O** | `NSFileManager`, `contentsOfFile`, `NSData(contentsOf:)`, `PropertyListSerialization` | Large file read during scroll, sync document parsing |
| **Image/Assets** | `UIImage`, `CGImage`, `ImageIO`, `CGContextDrawImage` | Sync image decode in cellForRowAt, no caching |
| **Third-Party SDKs** | Analytics, Crash reporters, Ad SDKs | Sync callback on main thread |
| **Framework Init** | `CallKit`, `CoreLocation`, `AVFoundation`, `AVFAudio`, `PhotoKit`, `StoreKit`, `Contacts` | Sync location/auth status checks, AVAudioSession category setup, PHAsset fetches, SKPaymentQueue.storefront — these use XPC internally and block the main thread |
| **Social Frameworks** | `SLRequest`, `ACAccountStore`, `Social.framework` | Account validation blocking UI |
| **Swift Runtime** | `swift_getTypeByMangledName`, `__swift_instantiate`, `protocol witness` | Complex generics during user interaction |
| **Memory** | `malloc`, `swift_allocObject`, `vm_allocate` | Large allocation during scroll/gesture |
| **UI Setup** | `UIFont`, `UIStoryboard`, `loadNibNamed` | Heavy view init in willAppear/didAppear |
| **Keychain** | `SecItem`, `Keychain`, `Security.framework` | Sync keychain read during interaction |
| **UserDefaults** | `NSUserDefaults`, `synchronize` | Large defaults read, excessive access |
| **Protocol Conformance** | `conformsToProtocol:`, `conforms(to:)` | Repeated protocol conformance checks. This requires taking the Objective-C runtime lock and traversing the class hierarchy, which is expensive. Recommend using `respondsToSelector:` to check for specific methods instead, or caching the result of `conformsToProtocol:` rather than calling it repeatedly. |

**Threading Issues:**

| Pattern | Symptoms | Solution |
|---------|----------|----------|
| **Priority Inversion** | Main thread waiting for low-priority background thread | Use QoS propagation, avoid shared locks |
| **Serial Queue Bottleneck** | Main thread blocked on serial queue completion | Use concurrent queues or async patterns |
| **Deadlock** | Two threads each waiting for locks held by the other | Establish lock ordering or eliminate locks |

**First-Party (Apple) Framework Blocking:** When a hang callstack bottoms out in a blocking primitive (e.g., `dispatch_semaphore_wait_slow`, `pthread_cond_wait`, `__ulock_wait`), the key is to identify *who is calling it* — walk up the callstack to find the caller that initiated the blocking operation. If the caller is a first-party Apple framework with no third-party code above it, the developer cannot fix this directly — recommend filing a bug report (Feedback Assistant) with the sample log attached. If the caller is a third-party frame, call that out as the source of the problem.

**User Interaction Patterns:**

| Context | Common Problems |
|---------|-----------------|
| **Scrolling** | Sync cell config in `cellForRowAt`, image loading without cache, DB queries in cell prep |
| **Gestures** | Heavy computation in tap handlers, sync operations in gesture callbacks |
| **View Lifecycle** | Excessive work in `viewWillAppear`/`viewDidAppear`, sync data load in view setup |

**Unsymbolicated Frames:** When the callstack contains unsymbolicated frames (e.g., raw addresses, `???`, or unnamed frames), we cannot determine exactly what code is running. In this case:

1. **Look at the APIs above** (what initiated the work) and the **leaf nodes below** (where time is actually spent) to piece together what's happening. The symbolicated frames surrounding the unsymbolicated ones often tell the full story. For example, if you see a user-code method above and `CGImageSourceCreateThumbnailAtIndex` at the leaf, you know thumbnail generation is where the time is going — the unsymbolicated frames in between are implementation details.
2. **Confirm actual blocking from leaf nodes.** Only identify a lock or blocking primitive if it appears in Apple/system code at the leaf of the callstack. Method names in user code (e.g., `accquireLockAndPerformAction:`) are not reliable indicators of actual locks.
3. **Ask the developer to help explain** what the app was trying to do. Describe what the callstack *does* show — the APIs and leaf nodes — and ask the developer to fill in the gaps for the unsymbolicated frames based on that context.

## Output Template

```markdown
# [App Name] v[Version] Hang Analysis

**Hang Duration:** [X-Y seconds]

## Summary

| # | Issue | Impact |
|---|-------|--------|
| 1 | [Brief title] | [Xms (Y% of hang)] |
| 2 | [Brief title] | [Xms (Y% of hang)] |

---

### 1. [Issue Title]
**Impact:** [Xms (Y% of hang)]

**Problem:** [One sentence describing what's blocking the main thread and why.]

**Callstack:**
TopLevelMethod()
  → MiddleMethod()
  → BlockingOperation() [X samples = Yms]

**Fix:** [One or two sentences with specific action to take.]

**Location:** `[FileName.swift]` - [methodName] method

---

### 2. [Issue Title]
**Impact:** [Xms (Y% of hang)]

**Problem:** [One sentence describing what's blocking the main thread and why.]

**Callstack:**
TopLevelMethod()
  → MiddleMethod()
  → BlockingOperation() [X samples = Yms]

**Fix:** [One or two sentences with specific action to take.]

**Location:** `[FileName.swift]` - [methodName] method
```

## Writing Guidelines

### Do
- Lead with impact (milliseconds and percentage of hang)
- Use one sentence for problem, one for fix
- Include specific file/method locations
- Simplify callstacks to critical path only (3-5 levels max)
- Use `→` for callstack flow instead of tree characters
- Note the user interaction context (scroll, tap, view appear, etc.)

### Don't
- Repeat the same information multiple ways
- Use emojis or status badges
- Include "AI Recommendations" or similar meta-labels
- Add timeline estimates
- Use tree/box-drawing characters (`├─ └─`)
- Include methodology or process details

## Common Fixes Reference

| Problem | Fix |
|---------|-----|
| Sync image loading in cells | Background decode + `UIImageView` placeholder |
| Sync file I/O | `DispatchQueue.global().async` |
| Sync network | Async API with completion handler |
| dispatch_group_wait on main | Completion handlers or async/await |
| Sleep on main thread | Remove entirely or use `asyncAfter` |
| Heavy work in viewWillAppear | Move to viewDidAppear or background |
| DB query in cellForRowAt | Prefetch data, use `NSFetchedResultsController` |
| Lock contention | Reduce lock scope, use concurrent queues |
| Protocol conformance checks | Use `respondsToSelector:` instead, or cache the result |
| Priority inversion | Use proper QoS, avoid cross-thread locks |

## Example Output

```markdown
# MyApp v2.1.0 Hang Analysis

**Hang Duration:** 1.2-2.8 seconds

## Summary

| # | Issue | Impact |
|---|-------|--------|
| 1 | Synchronous image decode | 1.1s (78% of hang) |
| 2 | Database query on main thread | 250ms (18% of hang) |

---

### 1. Synchronous Image Decode
**Impact:** 1.1s (78% of hang)

**Problem:** Large image decoded synchronously on main thread during table view scroll.

**Callstack:**
UITableViewDelegate.tableView(_:cellForRowAt:)
  → PhotoCell.configure(with:)
  → UIImage(contentsOfFile:) [110 samples = 1100ms]

**Fix:** Decode images on background queue. Use thumbnail for cell display, load full image async when needed.

**Location:** `PhotoCell.swift` - configure(with:) method

---

### 2. Database Query on Main Thread
**Impact:** 250ms (18% of hang)

**Problem:** Core Data fetch request executed synchronously during cell configuration.

**Callstack:**
PhotoCell.configure(with:)
  → DataManager.fetchMetadata(for:)
  → NSManagedObjectContext.fetch() [25 samples = 250ms]

**Fix:** Prefetch metadata before displaying cells. Use `NSFetchedResultsController` for table data.

**Location:** `DataManager.swift` - fetchMetadata(for:) method
```
