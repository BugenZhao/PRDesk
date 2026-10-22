# iOS Disk Writes Performance Analysis Guide

## Overview

Analyze iOS app disk write performance using telemetry from Xcode Organizer. Identify excessive NAND writes and provide actionable recommendations.

**Why It Matters:** Excessive disk writes contribute to NAND wear, reduce device longevity, correlate with battery drain, and impact performance. Target: <1GB/day for typical app usage.

## Telemetry Interpretation

**Key Metrics:**
- **Total Bytes Written:** Volume of disk writes attributed to app
- **Write Signatures:** Specific functions/patterns causing writes
- **Write Frequency:** How often writes occur

**Thresholds:**
- **Normal:** <1GB/day
- **Investigate:** 1-2GB/day
- **Critical:** >2GB/day

## Anti-Patterns to Detect

Scan signatures for these problematic patterns:

| Anti-Pattern | Signatures | Typical Impact |
|--------------|-----------|----------------|
| **SQLite DELETE Mode** | `syncJournal`, `pagerAddPageToRollbackJournal` | 2-5x write amplification |
| **SQLite Spill Files (non-WAL)** | `vdbeSorterListToPMA` + non-WAL DB | 500MB-2GB per query |
| **SQLite Spill Files (WAL)** | `vdbeSorterListToPMA` + WAL DB | 500MB-2GB per query |
| **SQLite Writes (non-WAL)** | `sqlite3_step` with writes on non-WAL DB | Varies by write volume |
| **SQLite Full Vacuum** | `sqlite3Vacuum`, `sqlite3RunVacuum`, `sqlite3_exec` with explicit `VACUUM` on DB without auto-vacuum | Entire DB size |
| **SQLite WAL Checkpoint** | `sqlite3_wal_checkpoint_v2` | 200MB-1GB/day |
| **Disk Cookie Storage** | `DiskCookieStorage::_asyncWriteFileCompletely`, `BinaryCookieStorage` | 100-500MB/day |
| **Serialized Files** | `NSKeyedArchiver`, `writeToFile:atomically:`, `_writeJSONString` | 1-3GB/day |
| **Excessive File Ops** | `NSFileManager` `remove`/`create`/`move`/`copy` methods | 100MB-1GB/day |

## Common Bottleneck Patterns

| Category | Look For In Signatures | Common Culprits |
|----------|----------------------|-----------------|
| **SQLite Journaling** | `syncJournal`, `pagerAddPage`, `walFrames` | DELETE mode instead of WAL |
| **SQLite Temp Files** | `vdbeSorter`, `sqlite3PagerWrite` | Missing indexes, large sorts |
| **SQLite Writes (non-WAL)** | `sqlite3_step` with writes on non-WAL DB | Database not configured for WAL mode |
| **SQLite Writes (WAL)** | `sqlite3_step` with writes on WAL DB | Normal, but watch for spills |
| **SQLite Maintenance** | `sqlite3Vacuum`, `sqlite3RunVacuum`, `sqlite3_exec` with `VACUUM` | Full vacuum instead of incremental; no auto-vacuum configured |
| **SQLite Checkpoints** | `sqlite3_wal_checkpoint_v2` | Aggressive explicit checkpoints instead of letting SQLite manage |
| **SQLite Virtual Tables** | `sqlite3VTabSavepoint` | FTS or other virtual table savepoint handling — ask what's stored in FTS and how often it changes |
| **Cookie Storage** | `DiskCookieStorage`, `BinaryCookieStorage` | Immediate write per cookie change |
| **Plist/JSON/XML** | `writeToFile`, `NSKeyedArchiver`, `_writeJSONString`, `xmlFileClose` | Atomic full-file writes for small changes |
| **Core Data** | `NSSQLiteConnection`, `_executeFetchRequest` | Frequent saves, missing indexes |
| **File Ops Churn** | `NSFileManager` remove/create/move/copy | Repeated create-delete cycles, copy instead of move |
| **Cache Manifests** | Database writes per cached file | Manifest update per file instead of batch |
| **Temp Files** | `NSTemporaryDirectory`, temp file creation | Unnecessary temp files for in-memory work |

### SQLite Wrapper Detection

When you see `MutablePersistableRecord` or `PersistableRecord` in signatures, the app is using **GRDB** — a Swift SQLite wrapper. All SQLite anti-patterns still apply (WAL mode, missing indexes, vacuum, spills). Call out the GRDB usage so the developer knows to configure their GRDB database connection with WAL mode and proper indexes.

**Index considerations for wrappers (GRDB, Core Data):** These frameworks sit on top of SQLite and implicitly create their own indexes. Developers may not be able to define fully custom indexes — the set of indexes they can create is more limited than raw SQLite. Additionally, custom indexes come at a cost (they add write amplification on every insert/update). Recommend profiling the app before and after adding a custom index to verify it actually improves performance rather than making disk writes worse.

### Virtual Table / FTS Writes

When you see `sqlite3VTabSavepoint` in signatures, a savepoint was issued and a virtual table implementation (commonly **FTS — Full-Text Search**) needs to handle it. The key questions to ask the developer:
1. **What data are you storing in FTS?** — FTS indexes can be expensive to maintain
2. **How often are you changing this data?** — Frequent inserts/updates to FTS-indexed content cause significant write amplification from the FTS index maintenance

### Savepoints vs Transactions

Savepoints result in more disk writes than normal transactions. If you see savepoint-related signatures (`sqlite3VTabSavepoint`, `SAVEPOINT`), recommend using normal transactions (`BEGIN`/`COMMIT`) instead of savepoints unless the app genuinely needs partial rollback within a transaction.

### UPSERT into FTS

If you see `updateOrInsert` (or similar upsert patterns) writing into FTS storage repeatedly, this is a costly pattern. Every upsert into an FTS table triggers full index maintenance — rebuilding posting lists, updating the inverted index, etc.

**Better approach:** Don't insert directly into the FTS table. Instead:
1. Store the data in a **normal table**
2. Use a **contentless FTS index** (`content=""`) that only stores the posting lists
3. The contentless FTS index is cheaper to maintain and avoids duplicating the full content in both the regular table and the FTS table

## Output Template

The analysis should identify a single root cause for the dominant write pattern. If multiple signatures point to the same underlying problem (e.g., DELETE mode journaling causes both journal writes and amplified transaction writes), present it as one issue with multiple recommendations — not separate issues.

```markdown
# [App Name] v[Version] Disk Writes Analysis

**Estimated Daily Writes:** [X GB/day]

## Root Cause: [Title describing the core write problem]
**Impact:** [X MB/day (Y% of total writes)]

**Problem:** [What's causing the excessive writes and why.]

**Signatures:** `[signature1]`, `[signature2]`

**Recommendations:**

1. [Primary fix — the most impactful change]

```swift
// Before
[problematic code]

// After
[fixed code]
```

2. [Secondary recommendation if applicable]

3. [Additional optimization if applicable]

**Investigate in your code:** [Specific class/method to look at]
```

### Single Root Cause Principle

Don't split cascading effects into separate issues. For example:
- SQLite DELETE mode journaling causing `syncJournal` writes AND `pagerAddPageToRollbackJournal` writes = **one issue** (non-WAL journaling), not two
- Missing indexes causing spill files AND increased checkpoint writes = **one issue** (missing indexes), not two
- Cookie writes from analytics SDK causing `DiskCookieStorage` AND `BinaryCookieStorage` signatures = **one issue** (disk cookies from analytics), not two

Walk up the callstack from the write signature to identify WHO is causing it. The root cause is the code decision, not the write primitive.

### Reading Disk Write Signatures

Disk write telemetry differs from launch/hang/energy callstacks — instead of sampled execution trees, you get **write signatures**: the specific function call paths that triggered disk writes.

**How to Read Signatures:**
- Each signature represents a code path that performed disk writes
- The signature shows the call chain from top-level entry point down to the write operation
- Higher in the signature = what initiated the write; lower = the actual I/O primitive
- Multiple signatures can point to the same root cause (e.g., `syncJournal` and `pagerAddPageToRollbackJournal` both indicate non-WAL journaling)

**Identifying the Caller:**
- Don't stop at the write primitive (`sqlite3_step`, `writeToFile:atomically:`, etc.) — walk up to find the app code or SDK that triggered the write
- If the caller is a third-party SDK, call that out as the source
- If the caller is app code, identify the specific class/method making the decision to write

**Unsymbolicated Frames:** When signatures contain unsymbolicated frames (raw addresses, `???`), use the symbolicated frames above and below to infer what's happening. Describe what the signature *does* show and ask the developer to fill in the gaps.

## Writing Guidelines

### Do
- Lead with impact (MB or GB per day, percentage of total)
- Include specific signature names from telemetry
- Provide code snippets for SQLite/database fixes (PRAGMA statements are specific)
- Use one sentence for problem, one for fix
- Include specific file/method locations

### Don't
- Repeat the same information multiple ways
- Use emojis or status badges
- Include "AI Recommendations" or similar meta-labels
- Use tree/box-drawing characters (`├─ └─`)
- Include methodology or process details

## Common Fixes Reference

| Problem | Fix |
|---------|-----|
| SQLite DELETE mode | `PRAGMA journal_mode=WAL` at connection time |
| SQLite spill files | Add indexes on ORDER BY, JOIN, WHERE columns |
| SQLite full vacuum | `PRAGMA auto_vacuum=incremental` + periodic `PRAGMA incremental_vacuum` |
| Disk cookie writes | Use `URLSessionConfiguration.ephemeral` for non-essential requests |
| Plist/JSON full writes | Migrate to SwiftData, Core Data, or SQLite for frequently updated data |
| Atomic file writes | Use UserDefaults for simple settings, batch updates |
| Cache manifest per-file | Batch manifest updates, not per-file |
| NSFileManager churn | Use `moveItem` instead of `copyItem` when source isn't needed; check existence before creating |
| WAL checkpoint overhead | Let SQLite auto-checkpoint; use `SQLITE_CHECKPOINT_PASSIVE` if explicit checkpoint needed |
| Savepoint overhead | Use normal transactions (`BEGIN`/`COMMIT`) instead of savepoints |
| FTS upsert churn | Use a normal table + contentless FTS index (`content=""`) instead of inserting directly into FTS |

## SQLite Quick Reference

```sql
-- Enable WAL mode (do at connection time)
PRAGMA journal_mode=WAL;

-- Enable incremental vacuum (do at DB creation)
PRAGMA auto_vacuum=incremental;

-- Run incremental vacuum (periodic maintenance)
PRAGMA incremental_vacuum;

-- Check for missing indexes
EXPLAIN QUERY PLAN SELECT * FROM table WHERE column = ? ORDER BY other;
-- If output shows "SCAN TABLE" instead of "USING INDEX", add index:
CREATE INDEX idx_table_column ON table(column);
CREATE INDEX idx_table_other ON table(other DESC);
```

## Example Output

```markdown
# SocialApp v3.2.0 Disk Writes Analysis

**Estimated Daily Writes:** 2.8 GB/day

## Root Cause: SQLite Database Not Using WAL Mode
**Impact:** 2.0 GB/day (71% of total writes)

**Problem:** The app's SQLite database uses DELETE journaling mode, which writes every transaction twice (once to the rollback journal, once to the database). This causes 2-3x write amplification. The same database also lacks indexes on frequently queried columns, causing SQLite to create temporary spill files for sorting — compounding the write volume further because spills in DELETE mode are also journal-amplified.

**Signatures:** `syncJournal`, `pagerAddPageToRollbackJournal`, `vdbeSorterListToPMA`

**Recommendations:**

1. Switch to WAL mode at database connection time — this alone should cut write volume roughly in half:

```swift
sqlite3_open(dbPath, &db)
sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
```

2. Add indexes on columns used in ORDER BY and WHERE clauses to eliminate spill files:

```sql
CREATE INDEX idx_messages_conversation_timestamp
  ON messages(conversation_id, timestamp DESC);
CREATE INDEX idx_users_last_active
  ON users(last_active DESC);
```

3. Switch from full `VACUUM` to incremental vacuum to avoid periodic full-database rewrites:

```sql
PRAGMA auto_vacuum=incremental;
PRAGMA incremental_vacuum;
```

**Investigate in your code:** Database initialization in `DatabaseManager.swift` and schema setup in `DatabaseSchema.swift`
```
