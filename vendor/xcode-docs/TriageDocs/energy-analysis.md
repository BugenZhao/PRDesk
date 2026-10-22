#iOS Energy Performance Analysis Guide

## Overview

Analyze iOS app CPU performance using energy logs from Xcode Organizer. Identify high CPU consumption patterns and provide actionable recommendations.

**Why It Matters:** High CPU usage drains battery, reduces device performance, causes thermal throttling, and degrades user experience. Target: Minimal CPU during idle, burst work completed quickly.

## Telemetry Interpretation

**Key Metrics:**
- **Sample Percentage:** Proportion of samples in specific code paths
- **Thread Distribution:** Which threads consume CPU and how much

**Sample Reading:** Samples are captured at 1ms intervals during high CPU periods. Higher sample percentages in a code path indicate more time spent there. Use percentage of total samples for the tree, not raw sample counts (sample counts are not visible in the Organizer UI).

**Callstack Reading:** Top = entry point, Bottom = where CPU is consumed. High sample percentages at bottom functions indicate where optimization is needed. Always express impact as percentage of total samples, never as raw sample counts.

**Reading APIs and Leaf Nodes:** Always examine both the API-level calls (higher in the stack — what initiated the work) and the leaf nodes (bottom of the stack — where CPU time is actually consumed). The APIs tell you *what* the app is trying to do; the leaf nodes tell you *where* the CPU cycles go. Walk up the callstack from the leaf to identify WHO is causing the CPU usage — the root cause is the code decision, not the CPU-intensive primitive.

### Multi-Branch Callstacks

Energy logs can contain callstacks that branch into multiple code paths. This happens when the sampler captures time spent in different operations during the same high-CPU period.

**Data Structure:**
- The `sampledExecutionTree` is a nested array of frame objects
- Each frame has a `childrenCount` field — when this is >1, the callstack forks into multiple branches
- Each branch has its own sample percentage indicating how much CPU went through that path

**How to Read Branches:**
- Analyze each branch independently to understand what work is happening on each path
- **Always focus on the heaviest branch** (highest sample percentage) — this is where the most CPU time is being spent and should be the basis for the root cause you identify
- Lighter branches may be secondary effects of the same root cause — don't split them into separate issues

### Unsymbolicated Frames

When the callstack contains unsymbolicated frames (e.g., raw addresses, `???`, or unnamed frames), we cannot determine exactly what code is running. In this case:

1. **Look at the APIs above** (what initiated the work) and the **leaf nodes below** (where CPU time is actually spent) to piece together what's happening. The symbolicated frames surrounding the unsymbolicated ones often tell the full story.
2. **Ask the developer to help explain** what the app was trying to do. Describe what the callstack *does* show — the APIs and leaf nodes — and ask the developer to fill in the gaps.

## Anti-Patterns to Detect

Scan callstacks for these CPU-intensive patterns:

| Category | Callstack Indicators | Typical Impact |
|----------|---------------------|----------------|
| **Excessive Allocations** | Repeated `malloc`, `swift_allocObject`, `_objc_rootAlloc` in tight loops | 15-40% CPU |
| **Image Processing** | `CGContextDrawImage`, `vImageScale`, `CGImageCreate` without caching | 25-60% CPU |
| **JSON/XML Parsing** | `JSONDecoder`, `xmlParseDocument`, `NSJSONSerialization` on main thread | 10-30% CPU |
| **Layout Recalculation** | Repeated `layoutSubviews`, `setNeedsLayout`, `systemLayoutSizeFitting` | 15-35% CPU |
| **String Operations** | Excessive `NSString` copying, concatenation, case conversion in loops | 5-20% CPU |
| **Collection Iteration** | Inefficient `filter`, `map`, `reduce` on large collections | 10-30% CPU |
| **Software Cryptography** | `mbedtls`, `CC_SHA256`, `CCCrypt`, `EVP_Cipher`, OpenSSL/BoringSSL symbols instead of `CommonCrypto`/`CryptoKit` | 15-40% CPU |
| **Type Casting** | Repeated `swift_dynamicCast`, `as?` checks in hot paths | 5-15% CPU |

## Common Bottleneck Patterns

Use this to identify *what* is causing CPU overhead when you see high sample counts.

| Category | Look For In Callstack | Common Culprits |
|----------|----------------------|-----------------|
| **Image Operations** | `UIImage`, `CGImage`, `ImageIO`, `vImage`, `CoreImage` | Repeated decode, no caching, sync processing, oversized images |
| **Data Parsing** | `JSONDecoder`, `PropertyListSerialization`, `XMLParser` | Large payloads on main thread, repeated parsing, inefficient models |
| **Database** | `CoreData`, `SQLite`, `NSPersistentStore`, `Realm` | Missing indexes, inefficient queries, sync operations on main |
| **Collections** | `NSArray`, `NSDictionary`, `filter`, `map`, `compactMap` | Nested iterations, copying large collections, inefficient algorithms |
| **Rendering** | `CALayer`, `drawRect`, `layoutSubviews`, `UIView` | Overdraw, excessive layer count, complex shadows/masks, repeated layout |
| **String Processing** | `NSString`, `String`, `NSAttributedString` | Excessive copying, repeated formatting, case conversion in loops |
| **Memory Management** | `malloc`, `free`, `swift_allocObject`, `objc_release` | Allocation churn, large allocations in loops, autorelease pool issues |
| **Network** | `URLSession`, `NSURLConnection`, JSON parsing after network | Parsing on main thread, inefficient deserialization |
| **File System** | `stat`, `lstat`, `open`, `read`, `NSFileManager` | Repeated metadata checks, directory enumeration, sync I/O |
| **Cryptography** | `mbedtls`, `CC_SHA256`, `CCCrypt`, `EVP_Cipher`, `SecKey`, OpenSSL/BoringSSL symbols | Third-party software crypto instead of hardware-accelerated CryptoKit/CommonCrypto, large payload hashing in loops |
| **Type Operations** | `swift_dynamicCast`, `type(of:)`, `Mirror` | Type checking in loops, excessive reflection |
| **Dispatch Overhead** | `dispatch_sync`, `dispatch_async`, excessive queue hopping | Queue contention, over-dispatching, sync dispatch on main |

**User Interaction Context:**

| Context | Common Problems |
|---------|-----------------|
| **Scrolling** | Image decode in cell config, heavy view setup, layout recalculation, sync data fetching |
| **App Launch** | Excessive initialization on main thread, synchronous setup, large data loads |
| **Background** | Inefficient background tasks, unnecessary CPU during idle |

## Output Template

The analysis should identify a single root cause for the dominant CPU consumption pattern. If multiple callstack paths point to the same underlying problem (e.g., image decoding without caching causing both allocation overhead and rendering delays), present it as one issue with multiple recommendations — not separate issues.

```markdown
# [App Name] v[Version] Energy/CPU Analysis

## Root Cause: [Title describing the core CPU problem]
**Impact:** [X% of CPU samples]

**Problem:** [What's consuming CPU and why.]

**Callstack:**
TopLevelMethod()
  → MiddleMethod()
  → CPUIntensiveOperation() [Y% of samples]

**Recommendations:**

1. [Primary fix — the most impactful change]

2. [Secondary recommendation if applicable]

3. [Additional optimization if applicable]

**Investigate in your code:** [Specific class/method to look at]
```

### Single Root Cause Principle

Don't split cascading effects into separate issues. For example:
- Image decode on main thread causing both `CGImageCreate` CPU AND `swift_allocObject` allocation overhead = **one issue** (synchronous image processing), not two
- Missing database indexes causing both CPU-intensive sorting AND spill file I/O = **one issue** (missing indexes), not two
- Repeated layout invalidation causing both `layoutSubviews` CPU AND `swift_allocObject` for view creation = **one issue** (layout churn), not two

Walk up the callstack to identify WHO is causing the CPU usage. The root cause is the code decision, not the CPU-intensive primitive.

## Writing Guidelines

### Do
- Lead with impact (percentage of total samples)
- Use one sentence for problem, one for fix
- Include specific file/method locations when visible
- Simplify callstacks to critical path only (3-5 levels max)
- Use `→` for callstack flow instead of tree characters
- Note the user interaction context (scroll, launch, background, etc.)
- Quantify with percentage of total samples (not raw sample counts)

### Don't
- Repeat the same information multiple ways
- Use emojis or status badges
- Include "AI Recommendations" or similar meta-labels
- Add timeline estimates
- Use tree/box-drawing characters (`├─ └─`)
- Include methodology or process details
- Recommend profiling tools (these are production logs)
- Reference raw sample counts (not visible in Organizer UI — use % of total samples only)

## Common Fixes Reference

| Problem | Fix |
|---------|-----|
| Image decode in cells | Background decode + cache, use thumbnails, `prepareForDisplay()` |
| Excessive allocations | Object pooling, reduce copies, reuse instances |
| JSON parsing on main | Background parsing with completion handler |
| Repeated layout | Cache layout calculations, reduce invalidation triggers |
| Collection iteration | Use efficient algorithms, avoid nested loops, batch operations |
| String copying | Use `NSMutableString`, reduce conversions, cache results |
| Type casting in loops | Cache type checks, use concrete types, avoid reflection |
| Software cryptography | Use `CryptoKit` or `CommonCrypto` for hardware acceleration, batch hashing, avoid re-encrypting cached data |

## Example Output

```markdown
# TikTok v42.5.0 Energy/CPU Analysis

## Root Cause: Synchronous Image Processing During Scroll
**Impact:** 75% of total samples

**Problem:** Feed cells decode and process images synchronously on the main thread during scroll, with no caching of decoded results. Each cell configuration triggers a full image decode (`CGImageCreate`), which also drives excessive object allocations (`swift_allocObject`) as new image buffers are created per cell. Repeated `stat` syscalls checking cached file existence compound the overhead.

**Callstack:**
UITableView.cellForRowAt()
  → FeedCell.configure()
  → UIImage(contentsOfFile:) → CGImageCreate() [28% of samples]
  → swift_allocObject() [47% of samples]

**Recommendations:**

1. Decode images on a background queue and cache decoded results. Use thumbnail sizes matching the feed cell dimensions rather than full-resolution images:

```swift
DispatchQueue.global(qos: .userInitiated).async {
    let thumbnail = image.preparingThumbnail(of: cellSize)
    DispatchQueue.main.async { cell.imageView.image = thumbnail }
}
```

2. Reuse cell subviews instead of recreating them in `configure()`. Pool objects that are allocated on every cell bind.

3. Cache file existence results in `CacheManager.validateCache()` to eliminate repeated `stat` syscalls per scroll.

**Investigate in your code:** `FeedCell.configure()`, `FeedCell.loadImage()`, and `CacheManager.validateCache()`
```
