# TigerBeetle: Engineering Philosophies, Theories, and Practices

A deep research report on the unconventional and often counterintuitive philosophies that drive TigerBeetle's engineering culture.

---

## 1. Biodigital Jazz

Perhaps the most surprising philosophical pillar: TigerBeetle views software engineering as an art form, not just a science. Joran Dirk Greef (CEO/founder) borrows the term "Biodigital Jazz" from *Tron: Legacy* to describe their ethos.

> "Biodigital Jazz: The secret behind everything we do at TigerBeetle."
> — Joran Dirk Greef

The idea is that great systems emerge at the intersection of engineering rigor and artistic sensibility — "the intertwining of human and digital elements" with an "improvisational spirit within technology's confines." Their coding style guide opens with quotes from Steve Jobs, Edsger Dijkstra, and *Let Over Lambda*, framing code not as mechanical output but as craft:

> "The design is not just what it looks like and feels like. The design is how it works." — Steve Jobs

> "Simplicity and elegance are unpopular because they require hard work and discipline to achieve." — Edsger Dijkstra

TigerBeetle describes their coding style as "a collective give-and-take at the intersection of engineering and art," balancing numbers and human intuition, reason and experience, first principles and knowledge, and precision and poetry.

This isn't just branding. It shapes concrete decisions — from insisting on character-aligned variable names for visual symmetry, to the 70-line function limit ("art is born of constraints"), to naming things with domain depth rather than mechanical labels.

---

## 2. NASA's Power of Ten

TigerBeetle explicitly models its engineering discipline on Gerard J. Holzmann's *Power of Ten Rules for Safety-Critical Code*, originally written for NASA/JPL. From their docs:

> "NASA's Power of Ten — Rules for Developing Safety Critical Code will change the way you code forever."

The adopted rules include:

| NASA Rule | TigerBeetle Implementation |
|---|---|
| No recursion | Strictly enforced — all executions must be bounded |
| All loops must have fixed upper bounds | Every loop and queue has an explicit maximum |
| No dynamic memory allocation after init | All memory allocated at startup, zero malloc/free at runtime |
| Check all return values | Assertions on every function's arguments and returns |
| Minimize preprocessor/macro use | Zig's comptime instead of macros |
| Restrict pointer use | Explicit pointer rules, no aliasing |
| Compile with all warnings as errors | Zig's safety features plus 10,000+ assertions |

The philosophy is that financial data deserves the same rigor as spacecraft avionics. Money, like a satellite, cannot be retrieved once lost.

---

## 3. Determinism as the Meta-Principle

Above all other principles sits determinism. From their ARCHITECTURE.md:

> "A meta principle above 'static allocation' is determinism. Determinism means that given the same input the software gives the same logical result and arrives at it using the same physical path."

This isn't just about testing — it's an architectural worldview. Every design decision is evaluated against whether it preserves determinism:

- **Single-threaded event loop** — eliminates OS scheduler non-determinism
- **Static memory allocation** — eliminates allocator non-determinism
- **No garbage collector** — eliminates GC pause non-determinism
- **Explicit fault models** — no undefined behavior from unhandled errors
- **Controlled time** — cluster constructs its own fault-tolerant "cluster time" rather than trusting system clocks

The payoff:

> "Determinism supercharges randomized testing. Any test failure can be reliably reproduced by sharing a seed that led to the failure."

Amplify Partners (their investor) puts it starkly:

> "The future of databases is deterministic."

And from the VOPR simulator: "Time itself becomes deterministic — a while true loop."

---

## 4. Zero Dependencies

TigerBeetle has a hard zero-dependency policy. The only external dependency is the Zig compiler toolchain itself. Everything else — the consensus protocol, storage engine, networking, serialization, even build scripts — is written from scratch.

From TigerStyle:

> "Dependencies, in general, inevitably lead to supply chain attacks, safety and performance risk, and slow install times."

They quote John Carmack to justify this:

> "The right tool for the job is often the tool you are already using — adding new tools has a higher cost than many people appreciate."

This extends even to scripting: they write build scripts in Zig rather than shell, because:
- Cross-platform and portable
- Type safety
- Higher team success probability
- Reduces dimensionality as the team grows
- May be slower individually; faster for the team long-term

The philosophy: for foundational infrastructure, every dependency is a liability that compounds. The cost of writing it yourself is paid once; the cost of a dependency is paid forever.

---

## 5. Static Memory Allocation ("Hard Mode")

One of TigerBeetle's most radical positions: **no memory allocation after startup**. Zero. Not "minimize allocation" — *none*.

From TigerStyle:

> "All memory must be statically allocated at startup. No memory may be dynamically allocated (or freed and reallocated) after initialization."

From their performance docs:

> "TigerBeetle allocates all the memory statically: it never runs out of memory, it never stalls due to a GC pause or mutex contention, and it never fragments the memory."

How it works in practice (from ARCHITECTURE.md):

> "When TigerBeetle starts, for every 'object type' in the system it computes the worst-case upper bound for the number of objects needed, based on CLI arguments."

> "Static allocation is a forcing function to ensure that everything has a limit."

This eliminates entire classes of bugs: use-after-free, double-free, memory fragmentation, OOM crashes during operation, allocation failure handling. Amplify Partners called them "fanatical about static memory allocation" and noted:

> "Not using dynamic memory allocation is 'hard mode' in Rust... but a breeze in Zig."

The deeper insight is that static allocation doesn't just eliminate bugs — it forces better designs. When you can't allocate on the fly, you must think through all resource requirements upfront, which naturally produces simpler, more predictable systems.

---

## 6. Crash Over Corrupt

TigerBeetle maintains **10,000+ assertions in production builds**. They are never disabled, never compiled out. The philosophy:

> "The only correct response to corrupt code is to crash."

> "Assertions downgrade catastrophic correctness bugs into liveness bugs."

The reasoning: in a replicated consensus system, a crash is a *recoverable* event — the other replicas continue serving, and the crashed node recovers from its peers. Silent data corruption, however, compounds and propagates. A crash stops the bleeding; silence lets it spread.

They cite research:

> "Almost all (92%) of the catastrophic system failures are the result of incorrect handling of non-fatal errors explicitly signaled in software."

The implication: the error-handling code is where the real bugs hide, and assertions catch them before they compound into data loss.

---

## 7. Paired Assertions ("It Takes Two to Contract")

Beyond just having many assertions, TigerBeetle mandates a specific pattern: **assertion pairs**. Every property must be checked at two different code paths.

> "Contracts always involve two parties... you do one check at the call site, and one check at the definition site."

> "An assertion pair forms an airlock — to reason about the correctness of a particular function call, you don't need to keep both the definition and the call site in mind."

The reasoning is subtle: if you assert a property only once, and the assertion itself has a bug, you'll never know. But if you assert the same property from two different angles using different local variables:

> "Repeating an assertion using a slightly different vocabulary of local variables maximizes the chance that at least one instance is not buggy."

Example: assert data validity before writing to disk AND assert it again after reading from disk. Two independent checks, two independent code paths, two chances to catch corruption.

The golden rule:

> "Assert the positive space that you do expect AND assert the negative space that you do not expect."

Minimum density: **two assertions per function**, averaging across the codebase.

---

## 8. Mechanical Sympathy and Back-of-Envelope Design

TigerBeetle believes the biggest performance wins happen at design time, not during profiling:

> "The best time to solve performance... is in the design phase, precisely when we can't measure."

> "The best 1000x wins come in design, not profiling phase. Can't measure what doesn't exist yet."

They practice "mechanical sympathy" — working with the grain of the hardware, like a carpenter works with wood grain. Concretely, this means **back-of-envelope sketches** before writing code:

> Analyze four resources: **network, disk, memory, CPU**. Sketch their two characteristics: **bandwidth, latency**. Aim for "roughly right" (90% of global maximum).

Resource optimization order: optimize the slowest resources first (network > disk > memory > CPU), but compensate for frequency — a memory cache miss that happens millions of times may matter more than a rare disk fsync.

Their CPU philosophy is vivid:

> "Treat CPU as a 100m sprinter: predictable, consistent. Avoid zigzagging; give large work chunks."

---

## 9. "Do Less, Go Faster"

TigerBeetle's 1000x performance claim comes not from clever optimization but from removing unnecessary work:

> "It's embarrassingly simple... you just do less, and that's how you go faster, because you're doing so much less."

> "We didn't do anything special."
> — Joran Dirk Greef

The concrete example: packing 8,190 debits/credits into a single 1MiB query via one database roundtrip. General-purpose databases pay costs that a specialized system can skip entirely:

- **Zero serialization**: fixed schema means no parsing/encoding overhead
- **Zero copy**: data structures in memory match on-disk format
- **Zero deserialization**: read directly from the buffer
- **Direct I/O**: bypass the OS page cache entirely
- **No SQL parsing**: purpose-built API, no query planner needed

> "All the parameters of the design have been inverted. Spinning disk dominated 30 years ago; today it's memory bandwidth. Redesigning from scratch with current constraints yields dramatic improvements."

---

## 10. The Near-Byzantine Storage Fault Model

Most databases assume disks are reliable but may crash. TigerBeetle assumes disks are *adversaries*:

> "Expect the disk to be almost an active adversary."

They use a "near-Byzantine" model — somewhere between crash-stop (disk either works or doesn't) and full Byzantine (disk lies actively). Concretely, they handle:

- **Bit rot**: silent data corruption (citing real-world rates: 0.031% of SSDs/year, 1.4% of enterprise HDDs/year)
- **Misdirected writes**: data written to the wrong offset
- **Phantom writes**: writes the disk reports as complete but never persisted
- **Read faults**: stale or garbage data returned on read

> "TigerBeetle assumes that its disk will fail."

This drove their **Protocol Aware Recovery** approach: the consensus protocol and storage engine are *not* decoupled (unlike traditional designs). They must communicate directly so the consensus layer can heal corrupted storage, and the storage layer can inform consensus about what's trustworthy.

> "The consensus protocol and storage engine cannot remain decoupled. They must communicate directly to recover properly from storage faults."

---

## 11. Accounting as a Primitive

TigerBeetle's deepest design conviction is that financial transactions aren't just *a* use case for databases — they're *the original* use case:

> "Accounting is the language of business."
> — Joran Dirk Greef

They reference Jim Gray's 1985 work defining transactions as "business transactions derived from the real world," with debit/credit as the canonical model:

> "Debit/credit is the lingua franca of what it means to transact."

> "Money cannot be created or destroyed, but is transferred from one account to another, so that the sum of all debits and credits remains equal."

The insight: every fintech company is unknowingly rebuilding a debit/credit database on top of general-purpose SQL:

> "Every single FinTech... they're all reinventing these debit/credit databases."

TigerBeetle argues this should be a database primitive, not an application-layer abstraction. And the double-entry model extends beyond banking — to inventory management, API rate limiting, kilowatt-hour tracking, ad impression budgets, anything that needs "conservation of quantity."

---

## 12. Why Zig (Not Rust, Not C)

TigerBeetle chose Zig deliberately over the two obvious alternatives. From their ARCHITECTURE.md:

> "Zig is a DSL for machine code. Its comptime features makes it very easy to directly express what you want the computer to do."

> "The primary benefit of Zig is the favorable ratio of expressivity to language complexity."

> "Zig lends itself to low-abstraction first-order code that does the work directly. This makes it easy to author and debug performance-oriented code."

**Why not Rust?** Rust's ownership model is designed for fearless *concurrency*. TigerBeetle doesn't want concurrency — it wants a single-threaded event loop. Zig's static allocation is natural; in Rust, avoiding dynamic allocation is "hard mode."

**Why not C?** Zig provides memory safety guarantees, undefined behavior elimination, and comptime generics (crucial for swapping I/O backends between production and simulation) without C's footgun density.

From the Safety docs:

> "TigerBeetle is written in Zig — a modern systems programming language that removes many instances of undefined behavior, provides spatial memory safety and encourages simple code."

They also committed financially: TigerBeetle and Synadia jointly pledged $512,000 to the Zig Software Foundation, signaling deep conviction in the language's future.

---

## 13. Viewstamped Replication (Not Raft, Not Paxos)

TigerBeetle uses Viewstamped Replication (VR) — a lesser-known consensus protocol developed independently from Paxos at roughly the same time. Most modern systems use Raft (a simplification of Paxos). TigerBeetle rejected both:

> "While Paxos originally is only a consensus algorithm, VR directly deals with a replicated log."

VR was chosen because it provides exactly the primitives TigerBeetle needs — replicated log management — without the additional complexity of mapping Paxos onto a log abstraction. It's also reportedly simpler to implement correctly.

The key innovation is their extension: VR alone doesn't handle storage faults. TigerBeetle integrates Protocol Aware Recovery (from a 2018 paper that Joran considers a watershed moment for database design) directly into the consensus protocol, enabling the cluster to self-heal from disk corruption:

> "fsyncgate and protocol-aware recovery in case of failures are two events from 2018 that mark the start of a new era in database development."

---

## 14. Zero Technical Debt

TigerBeetle enforces a strict zero technical debt policy:

> "You shall not pass!" — their policy on letting issues slip

The reasoning is economic: problems solved in the design phase are exponentially cheaper than production fixes. Cutting corners creates cascading costs; solid fundamentals build momentum.

This manifests in code review: every function must meet all TigerStyle requirements before merging. There is no "we'll clean it up later." The PR either meets the bar or it doesn't merge.

---

## 15. Control Plane / Data Plane Separation

TigerBeetle maintains a clear separation between the control plane (which makes decisions) and the data plane (which moves data):

> "Clear delineation enables high assertion safety without performance loss."

The control plane can be assertion-heavy, safety-first, relatively slow. The data plane is optimized for throughput. Batching is the bridge — amortize the cost of control-plane safety checks across large batches of data-plane operations.

This resolves the usual tension between safety and performance: you don't sacrifice assertions for speed, because assertions live in the control plane while hot loops live in the data plane.

---

## 16. Bounded Everything

Every resource in TigerBeetle has an explicit upper bound:

> "Put a limit on everything because, in reality, this is what we expect — everything has a limit."

- Every loop has a maximum iteration count
- Every queue has a maximum depth
- Every buffer has a maximum size
- Every timeout has a maximum duration

No infinite loops. No unbounded queues. No "grow as needed." This prevents tail latency spikes, ensures termination, and makes resource usage fully predictable.

Combined with static allocation, this means TigerBeetle's resource footprint is completely known at startup. It will never surprise you with unexpected memory growth or runaway CPU usage.

---

## 17. The VOPR Philosophy: "Born to Run in a Flight Simulator"

The VOPR (Viewstamped Operation Replicator) isn't just a test tool — it's a design philosophy:

> "The database was born to run in a flight simulator. It's deterministic."
> — Joran Dirk Greef

The analogy: just as aircraft are tested in simulators before carrying passengers, databases should be tested in simulators before carrying financial data. The VOPR runs the **exact same production code** in a simulated environment with fault injection.

> "DST is one of the most profoundly transformative pieces of technology developed over the past decade."

> "Unlike formal proofs and model checking, the simulation testing exercises a specific implementation."

The VOPR enabled TigerBeetle to become Jepsen-passing in 3.5 years — a timeline that normally takes a decade or more. Jepsen's independent analysis confirmed:

> "TigerBeetle exhibits a refreshing dedication to correctness... Most of our findings involved crashes or performance degradation, rather than safety errors."

---

## 18. Simplicity Through Constraints

A recurring theme: constraints produce simplicity, not complexity.

- **70-line function limit** — forces thoughtful decomposition
- **100-column line limit** — "nothing hidden by horizontal scrollbar"
- **Static allocation** — forces upfront design of all resource patterns
- **No recursion** — forces iterative thinking about bounded problems
- **Single-threaded** — forces elimination of concurrency bugs by design
- **Fixed schema** — forces elimination of serialization overhead

> "Art is born of constraints."

Each constraint removes a dimension of complexity. The system becomes more predictable, more testable, and — counterintuitively — more performant precisely because it's more constrained.

---

## 19. "The Database Was Born to Run in a Flight Simulator"

Joran's formulation of how TigerBeetle approaches testing vs. "testing in production":

> "We've got 30 years of hardware and software research advance; how you could build a database today, a lot has changed."

Rather than relying on years of production hardening (the traditional database approach), TigerBeetle front-loads correctness through simulation:

- **1,024 CPU cores** running the VOPR 24/7/365
- **~2 millennia** of simulated runtime per day
- Every network, storage, and process fault injected at 1000x speed
- Both **safety mode** (can the system do the wrong thing?) and **liveness mode** (can the system get stuck?)

The VOPR found bugs that years of production use might never surface — including the "resonance bug" where replicas could enter a synchronized failure pattern that prevented progress.

---

## 20. Naming as Domain Understanding

TigerBeetle treats naming as a signal of engineering depth:

> "There are only two hard things in Computer Science: cache invalidation, naming things, and off-by-one errors." — Phil Karlton

Their naming rules reveal a philosophy:

- **`allocator: Allocator`** is boring but acceptable
- **`gpa: Allocator`** and **`arena: Allocator`** are excellent — they tell you whether deinit is needed
- Names should "infuse domain knowledge"
- Units and qualifiers go last: `latency_ms_max` not `max_latency_ms` — so related variables align visually
- Character-aligned names for related pairs: `source` and `target` over `src` and `dest`

The deeper point: naming quality reflects understanding quality. If you can't name something well, you don't understand it well enough to implement it correctly.

---

## 21. Error Handling: No Exceptions, Complete Coverage

From TigerStyle:

> "All errors must be handled."

They cite a study finding that 92% of catastrophic system failures come from incorrect handling of non-fatal errors. Their response: make error handling as rigorous as the happy path.

Zig enforces this at the language level — unused error returns are compile errors. Combined with TigerBeetle's assertion pairs, every error path is tested as thoroughly as the success path.

No exceptions. No "this can't happen." No swallowed errors. Every branch is accounted for.

---

## 22. Influences and Intellectual Lineage

TigerBeetle draws from a specific intellectual tradition:

| Influence | What They Took |
|---|---|
| **NASA/JPL** (Holzmann's Power of Ten) | Bounded loops, no recursion, static allocation, assertions |
| **FoundationDB** | Deterministic simulation testing concept |
| **Jim Gray** (1985 transaction processing) | Debit/credit as the canonical transaction model |
| **Protocol Aware Recovery** (2018 paper) | Integrating consensus with storage fault handling |
| **fsyncgate** (2018) | Distrust of buffered I/O, Direct I/O by default |
| **John Carmack** | Minimal tooling philosophy |
| **Edsger Dijkstra** | Simplicity requires discipline |
| **Tron: Legacy** | "Biodigital Jazz" — engineering as art |
| **WarGames** | VOPR naming (from WOPR) |
| **Tolkien** | Humility about one's role in a larger system |

---

## Summary: The TigerBeetle Worldview

TigerBeetle's philosophies form a coherent system, not a collection of independent rules:

1. **Financial data is sacred** — treat it with aerospace-level rigor
2. **Determinism is the meta-principle** — everything else serves determinism
3. **Constraints produce simplicity** — static allocation, bounded everything, no recursion, fixed schema
4. **Crash, never corrupt** — 10,000+ production assertions, prefer halting over silent data loss
5. **Design for the hardware you have** — mechanical sympathy, back-of-envelope sketches, not benchmarks
6. **Do less to go faster** — remove abstractions, skip serialization, bypass the page cache
7. **Own everything** — zero dependencies, write it yourself, understand every layer
8. **Test like NASA flies** — simulation before production, not production as testing
9. **Code is craft** — biodigital jazz, naming as understanding, visual symmetry, 70-line functions
10. **Zero technical debt** — no shortcuts, no "we'll fix it later," solve problems when discovered

---

*Sources: [TigerStyle (TIGER_STYLE.md)](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md), [Safety Docs](https://docs.tigerbeetle.com/concepts/safety/), [ARCHITECTURE.md](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md), [Amplify Partners Analysis](https://www.amplifypartners.com/blog-posts/why-tigerbeetle-is-the-most-interesting-database-in-the-world), [Changelog Podcast #635](https://changelog.com/podcast/635), [InfoQ Presentation](https://www.infoq.com/presentations/tigerbeetle/), [Jepsen Analysis](https://jepsen.io/analyses/tigerbeetle-0.16.11), [It Takes Two to Contract](https://tigerbeetle.com/blog/2023-12-27-it-takes-two-to-contract), [DST Primer](https://www.amplifypartners.com/blog-posts/a-dst-primer-for-unit-test-maxxers), [Rediscovering Transaction Processing](https://tigerbeetle.com/blog/2024-07-23-rediscovering-transaction-processing-from-history-and-first-principles/)*
