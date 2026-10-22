# iOS Launch Performance Analysis Guide

## Overview

Analyze iOS app launch performance using sample logs from Xcode Organizer. Identify bottlenecks and provide actionable recommendations.

## Log Interpretation

**Sample Count Conversion:** `sampleCount × 10 = milliseconds`

**Callstack Reading:** Top = earliest (entry point), Bottom = where time is spent. High sampleCounts at bottom indicate bottlenecks.

**Reading APIs and Leaf Nodes:** Always examine both the API-level calls (higher in the stack — what initiated the work) and the leaf nodes (bottom of the stack — where time is actually spent). The APIs tell you *what* the app is trying to do; the leaf nodes tell you *how* it's blocking. Don't assume a method name like `accquireLockAndPerformAction:` in user code means an actual lock is being taken — method names in user code can be misleading. A real lock or blocking primitive will show up in Apple/system code at the leaf nodes of the callstack (e.g., `os_unfair_lock_lock`, `pthread_mutex_lock`, `__ulock_wait`). Always look at the leaf nodes to confirm actual blocking.

**Launch Details Field:** "X ms spent in this code path during a Y ms launch"

### Multi-Branch Callstacks

Launch logs can contain callstacks that branch into multiple code paths. This happens when the sampler captures time spent in different operations during the same launch.

**Data Structure:**
- The `sampledExecutionTree` is a nested array of frame objects
- Each frame has a `childrenCount` field — when this is >1, the callstack forks into multiple branches
- Each branch has its own `sampleCount` indicating how many samples went through that path
- The `rawFrame` string is prefixed with a branch number (e.g., `"1 "`, `"2 "`) to indicate which branch the frame belongs to

**How to Read Branches:**
- A frame with `childrenCount: 2` and `sampleCount: 39` that forks into a branch with `sampleCount: 29` and another with `sampleCount: 10` means 29 samples went through one code path and 10 through another
- Both branches contribute to the total launch duration
- Analyze each branch independently to understand what work is happening on each path
- **Always focus on the heaviest branch** (highest sample count) — this is where the most time is being spent and should be the basis for the issue you call out

### Unsymbolicated Frames

When the callstack contains unsymbolicated frames (e.g., raw addresses, `???`, or unnamed frames), we cannot determine exactly what code is running. In this case:

1. **Look at the APIs above** (what initiated the work) and the **leaf nodes below** (where time is actually spent) to piece together what's happening. The symbolicated frames surrounding the unsymbolicated ones often tell the full story.
2. **Confirm actual blocking from leaf nodes.** Only identify a lock or blocking primitive if it appears in Apple/system code at the leaf of the callstack.
3. **Ask the developer to help explain** what the app was trying to do. Describe what the callstack *does* show — the APIs and leaf nodes — and ask the developer to fill in the gaps.

**Reporting Threshold:** Only call out frames that account for **20% or more** of total samples. Anything below 20% of total samples is not significant enough to flag as a problem.

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
| **Swizzling** | `method_exchangeImplementations`, `method_setImplementation`, `class_replaceMethod`, `objc_msgSend` (unusual depth) | Variable |

**XPC-Backed Framework APIs:** When you see `xpc_connection_send_message_reply_sync` in a callstack, don't call out XPC itself as the problem. The real issue is the *framework API* higher in the callstack that uses XPC internally. These are the known APIs that perform synchronous XPC on the main thread:

| Framework | Class | Problematic Methods |
|-----------|-------|---------------------|
| **Photos** | `PHAsset`, `PHFetchResult` | `fetch*`, `enumerate*` methods |
| **CoreLocation** | `CLLocationManager` | `authorizationStatus`, `monitoredRegions`, `accuracyAuthorization`, `locationServicesEnabled` |
| **AVFoundation** | `AVAsset` | `tracksWithMediaType:` |
| **AVFAudio** | `AVAudioSession` | `setActive:withOptions:error:`, `category`, `setCategory:*`, `currentRoute`, `outputVolume`, `isPiPAvailable` |
| **StoreKit** | `SKPaymentQueue` | `storefront` |

When reporting, call out the framework API (e.g., "PHAsset.fetchAssets on main thread") not the underlying XPC primitive.

**Semaphore-Backed Framework APIs:** Similarly, some framework APIs use semaphores or dispatch primitives internally:

| Framework | Class | Problematic Methods |
|-----------|-------|---------------------|
| **StoreKit** | `SKPaymentQueue` | `canMakePayments` |
| **CoreTelephony** | `CTCellularPlanProvisioning` | `supportsCellularPlan` |


## Common Bottleneck Patterns

Use this to identify *what* is causing the anti-pattern when you see blocking primitives.

| Category | Look For In Callstack | Common Culprits |
|----------|----------------------|-----------------|
| **Database** | `CoreData`, `SQLite`, `NSPersistentStore`, `executeFetchRequest`, `NSMigrationManager` | Core Data stack init, sync queries in viewDidLoad, schema migration |
| **Network** | `URLSession`, `NSURLConnection`, `CFNetwork` | Sync URL requests, config fetching blocking UI |
| **File I/O** | `NSFileManager`, `contentsOfFile`, `NSData(contentsOf:)`, `PropertyListSerialization` | Large file reads, plist parsing, bundle resource loading |
| **Image/Assets** | `UIImage`, `CGImage`, `ImageIO`, `CGContextDrawImage`, `CUICatalog`, `_UIAssetManager` | Sync image decoding, asset catalog init, icon/splash resource conflicts |
| **Third-Party SDKs** | Analytics (AppsFlyer, Firebase), Crash reporters, Ad SDKs | Sync init on main thread during launch |
| **Framework Init** | `CallKit`, `CoreLocation`, `AVFoundation`, `AVFAudio`, `PhotoKit`, `StoreKit`, `WebKit` | These APIs often use XPC or semaphores internally — see XPC-Backed and Semaphore-Backed tables above. Call out the framework API, not the underlying primitive. |
| **Social Frameworks** | `SLRequest`, `ACAccountStore`, `Social.framework` | Account validation, social login sync checks |
| **Swift Runtime** | `swift_getTypeByMangledName`, `__swift_instantiate`, `protocol witness` | Complex generics, heavy protocol conformance |
| **Swizzling** | `method_exchangeImplementations`, `method_setImplementation`, `class_replaceMethod` | Swizzling frameworks you don't own (UIKit, Foundation, etc.). This is a deliberate tradeoff — either do it and accept the slowdown, or don't do it at all. There is no fix; swizzling external frameworks will always carry a performance cost. |
| **Memory** | `malloc`, `swift_allocObject`, `_objc_rootAlloc`, `vm_allocate` | Large object creation, excessive allocations during launch |
| **UI Setup** | `UIFont`, `UIStoryboard`, `loadNibNamed`, `viewDidLoad` | Some UI setup during launch is normal and expected. Only flag if more than 20ms is spent — custom fonts, storyboard parsing, heavy view init |
| **Keychain/Security** | `SecItem`, `Keychain`, `Security.framework` | Sync keychain reads during launch |
| **UserDefaults** | `NSUserDefaults`, `standardUserDefaults`, `synchronize` | Excessive defaults reads, large stored objects |
| **String Init** | `String.init<A>`, `String.init(describing:)`, `String.init(stringInterpolation:)` | Third-party code spending 100s of ms in string initialization — excessive string construction, heavy interpolation, or repeated conversions during launch |

**Threading Red Flags:**
- Main thread 100% busy while background threads idle → move work off main
- Sequential operations that could be parallel → use `DispatchGroup` or `async let`
- `dispatch_sync` to main from main → deadlock risk, remove

**When to Recommend Moving Work Off Main Thread:** Don't blindly suggest moving everything to a background queue. Only recommend it when one of these conditions is true:
1. **The main thread can make progress on other work during that time** — there is useful work (e.g., UI setup, layout) the main thread could be doing instead of waiting on this operation.
2. **The user is not waiting on the results** — the work's output isn't needed for what's being displayed. In this case, also question whether the work is avoidable entirely during launch.

**Swizzling:** If a callstack shows method swizzling of frameworks the app doesn't own (UIKit, Foundation, etc.), flag it clearly but don't suggest a "fix." Swizzling external frameworks is inherently slow. The developer chose to do it, and the only options are to accept the performance cost or stop swizzling. Frame this as a tradeoff, not a bug.

**Question Non-Essential Launch Work:** The only work that *must* happen before launch completes is work required to present the first frame. When a callstack contains any of the following, explicitly question whether this work needs to happen during launch at all:

- **Analytics / Telemetry** — AppsFlyer, Firebase Analytics, Adjust, Mixpanel, custom telemetry, event logging
- **Crash Reporters** — Crashlytics, Sentry, Bugsnag, PLCrashReporter
- **Logging** — os_log setup, custom log frameworks, remote logging init
- **Instrumentation** — performance monitoring SDKs, tracing, metric collection
- **Swizzling / Method Swapping** — any runtime method replacement
- **Ad SDKs** — AdMob, AppLovin, Unity Ads, mediation layers
- **Attribution** — install attribution, deep link resolution
- **Feature Flags / Remote Config** — LaunchDarkly, Firebase Remote Config, Optimizely

None of these contribute to showing the user their first screen. In the analysis, always ask: *"Does this work need to happen before the first frame is presented?"* If the answer is no, recommend deferring it until after launch completes.

## Output Template

The goal is to identify the **single root cause** of the launch issue, not to list multiple issues. Cascading effects, symptoms, and related signatures are all part of the same problem — don't split them into separate issues. Provide one clear problem statement and multiple recommendations for addressing it.

```markdown
# [App Name] v[Version] Launch Analysis

## The Issue

**Impact:** [Xms (Y% of launch)]

**Problem:** [One or two sentences describing the root cause and why it's problematic.]

[If non-essential work: **"Does this need to happen before the first frame? [Explanation of why this work is not required for first frame presentation and should be deferred.]"**]

**Callstack:**
TopLevelMethod()
  → MiddleMethod()
  → BlockingOperation() [X samples = Yms]

**Location:** `[FileName.swift]` - [methodName] method

## Recommendations

1. [Specific action to take]
2. [Another approach or complementary fix]
3. [Additional option if applicable]

---

## Signatures Without Sample Data

[Only include if applicable]

| Signature | Count | Likely Cause |
|-----------|-------|--------------|
| [MethodName] | [X] | [Brief hypothesis] |

Profile these locally with Instruments.
```

## Writing Guidelines

### Do
- Identify the single root cause — don't split cascading effects or symptoms into separate issues
- Lead with impact (milliseconds and percentage)
- Provide multiple recommendations for addressing the one issue
- Include specific file/method locations
- Simplify callstacks to critical path only (3-5 levels max)
- Use `→` for callstack flow instead of tree characters

### Don't
- List multiple issues when they share a root cause (e.g., swizzling + cache flushing + sync init are one issue, not three)
- Repeat the same information multiple ways
- Use emojis or status badges
- Include "AI Recommendations" or similar meta-labels
- Add timeline estimates ("fix in 2 weeks")
- Include signature IDs or internal tracking numbers
- Add "Technical Considerations" that repeat previous content
- Use tree/box-drawing characters (`├─ └─`)

### Callstack Format

**Before (verbose):**
```
LogonPresentationViewController.viewDidLoad() (LogonPresentationViewController.swift:273)
├─ LogonPresentationViewController.configureUI() (LogonPresentationViewController.swift:1076)
├─ LogonPresentationViewController.loadLogoAnimationView() (LogonPresentationViewController.swift:1175)
├─ LogoAnimationView.init(with:) (LogoAnimationView.swift:147)
└─ LogoAnimationView.updateLogoImageName(with:) + 516 (LogoAnimationView.swift:0)
```

**After (clean):**
```
LogonPresentationViewController.viewDidLoad()
  → configureUI()
  → loadLogoAnimationView()
  → LogoAnimationView.updateLogoImageName(with:) [X samples = Yms]
```

### Issue Description Format

**Before (verbose):**
```markdown
**ANTI-PATTERN VIOLATION: Launch-Critical Third-Party SDK Initialization**
├─ Problem: Synchronous initialization of analytics SDK during critical app launch phase
├─ Impact: 700ms main thread blocking (13-14% of launch time)
├─ Root Cause: AppsFlyerLib using dispatch_group_wait on main thread during initialization
├─ Solution: Move AppsFlyerLib initialization to background queue or defer until after launch
├─ Alternative: Use lazy loading pattern for analytics tracking
└─ Examine your code: AWEExternalRouterAFInitTask.execute method in MusicallyCore

**MAIN ISSUE: Dispatch Group Synchronous Wait**
├─ Problem: _dispatch_group_wait_slow blocking main thread until background operations complete
├─ Solution: Replace synchronous wait with asynchronous completion handlers
...
```

**After (clean):**
```markdown
## The Issue

**Impact:** 700ms (13-14% of launch)

**Problem:** Third-party analytics SDK (AppsFlyerLib) uses synchronous dispatch_group_wait during launch.

**Does this need to happen before the first frame?** Attribution and analytics tracking are not required to present the first screen. Defer this initialization until after launch completes.

**Callstack:**
AWEExternalRouterAFInitTask.execute()
  → AppsFlyerLib.init
  → dispatch_group_wait_slow

**Location:** `AWEExternalRouterAFInitTask` - execute() method

## Recommendations

1. Defer AppsFlyerLib initialization to a background queue or after first screen display.
2. If attribution data is needed early, use an async initialization path with a completion handler.
```

## Common Fixes Reference

| Problem | Fix |
|---------|-----|
| Sync image loading | Background queue + placeholder |
| Sync file I/O | `DispatchQueue.global().async` |
| Sync network | Async API with completion handler |
| dispatch_group_wait | Completion handlers or async/await |
| Sleep on main thread | Remove or use `DispatchQueue.main.asyncAfter` |
| Heavy init in viewDidLoad | Move to viewDidAppear or background |
| Third-party SDK blocking | Defer init until after launch |
| dlopen on main thread | Background loading or static linking |
| Swizzling external frameworks | No fix — accept the cost or remove the swizzling |

## Example Output

```markdown
# Chase v4.541 Launch Analysis

## The Issue

**Impact:** 2.7-4.0s (25-37% of launch)

**Problem:** Synchronous image processing in `LogoAnimationView` blocks the main thread during viewDidLoad, preventing the first frame from being presented.

**Callstack:**
LogonPresentationViewController.viewDidLoad()
  → configureUI()
  → loadLogoAnimationView()
  → LogoAnimationView.updateLogoImageName(with:) [275-401 samples]

**Location:** `LogoAnimationView.swift` - updateLogoImageName(with:) method

## Recommendations

1. Move image processing to a background queue and display a placeholder immediately while the actual logo loads asynchronously.
2. Pre-cache the processed logo image so subsequent launches don't pay this cost.
3. Consider whether the logo animation is needed at all on the launch-critical path — a static image would eliminate this entirely.

---

## Signatures Without Sample Data

| Signature | Count | Likely Cause |
|-----------|-------|--------------|
| AppDelegate.init() | 40,286 | Initialization overhead |
| JPThemeManager.createAndCachePrototypeForType | 49,451 | Theme caching |
| __swift_instantiateConcreteTypeFromMangledName | 33,697 | Swift runtime type resolution |

Profile these locally with Instruments.
```
