# De-forking `sparql-client`: a bolt-on architecture for NCBO/OntoPortal

Status: proposal (design only — no code is moved by this document)
Scope: `goo` ↔ `sparql-client`. Development gated on goo's own (live-backend) test suite; the
`ontoportal_testkit` cross-stack harness is a one-time release gate at the final phase (see §5).

> **Superseded in part — read `docs/sparql-defork-review.md` §0.5 for the reconciliation.**
> This is the original design (Jun 22). The de-fork has since been implemented and reviewed, and the
> as-built code + the review's decision register (D1–D12) are now authoritative where they differ.
> Known divergences from this proposal: caching/logging landed as **direct subclass overrides**, not
> prepended `Ext::Caching`/`Ext::Logging` modules (§3.1–3.2); `xsd:string` forcing stayed
> **backend-agnostic** rather than backend-gated (§3.4); invalidation-failure logging was **lost**
> (dropped even the fork's `puts`) rather than improved (§3.1) — being restored per decision D4; the
> generic patches (§3.5/§6) were **not** upstreamed yet; and the "Status (implemented)" notes below
> are stale (see the corrections inline).

## TL;DR

Today `goo` depends on a **hard fork** of `ruby-rdf/sparql-client` 3.2.2 (`Gemfile`:
`gem 'sparql-client', github: 'ncbo/sparql-client', branch: 'ontoportal-lirmm-development'`).
NCBO features are edited directly into the gem's source. The diff against upstream is ~80%
whitespace re-indentation, which buries the real changes and makes every upstream
security/bugfix a lossy manual merge — a past "reset to upstream then re-apply" already
silently dropped the public method `union_with_bind_as` (its corpse is still visible as a
dead `:unions_with_bind` branch in `query.rb`).

**Recommendation:** stop carrying NCBO behavior *inside* the gem. Track upstream as a
(near-)vanilla pinned dependency and re-home every customization in `goo` as a small,
unit-tested **bolt-on**, wired through extension seams that already exist:

- `Goo::SPARQL::Client < SPARQL::Client` is already the composition root.
- Its `query` / `update` are *not* currently overridden — so the subclass (or a prepended
  module) can wrap them with `super` and host caching/logging there, no copy-paste.
- The gem already exposes `pre_http_hook` / `post_http_hook` (vanilla stubs) for wire-level
  metrics.
- The gem already accepts `SPARQL::Client::QueryElement` in `serialize_patterns` — the
  union-with-bind DSL can live there with **zero** gem patches.
- The in-flight `AuthStrategy` work (branch `feature/sparql-backend-auth`) is the exact
  composition template to generalize: a stateless module of pure functions, a little state
  on the client, applied at well-defined seams.

Net effect: the fork shrinks to nothing (or to a thin, readable branch holding only the
handful of *genuinely upstreamable* patches until their PRs merge), and three known
classes of cache bug dissolve as a side effect of moving the logic to the right seam.

---

## 1. Verified inventory (what actually has to move)

Confirmed against current source in both repos. Line numbers are current working-tree.

| # | Concern | Lives in fork | NCBO-only? | goo caller / wiring |
|---|---------|---------------|-----------|---------------------|
| 1 | **Redis read-through cache** | `lib/sparql/client/cache.rb`; wired in `client.rb#query` (336-341), `#update` (378-381, invalidate), `#parse_response` (437-438, write) | yes | constructed with `redis_cache:` in `goo.rb` `add_sparql_backend` (~125-143) |
| 2 | **Query logging** | `lib/sparql/client/logging.rb`; `@logger.log` in `client.rb#query` (337-339, 347-360), `#update` (384-391) | yes | `logger:` passed only to the **query** client in `goo.rb` |
| 3 | **Union-with-bind DSL** | `query.rb`: `optional_union_with_bind_as` (512-519, **live**), `add_union_with_bind` (768-792), consumed in `to_s` (852-858); **dead** `:unions_with_bind` branch (846-850) | yes | only caller: `query_builder.rb#union_bind_in_where` → `@query.optional_union_with_bind_as(*binding_as)` (~98) |
| 4 | **Multiple `FROM`** | `query.rb#from` + `to_s` (819-825) accept an Array | no — generic | used implicitly via `.from(graphs)` in `query_builder.rb` |
| 5 | **Virtuoso/4store `xsd:string` forcing** | `client.rb` class `serialize_patterns` (728-730) + duplicated in `query.rb` instance method (978-980) | backend-specific | implicit; backend known via `Goo.backend_*?` |
| 6 | **Virtuoso `INSERT` vs `INSERT DATA`** | `update.rb` `Update::InsertData#to_s`, `use_insert_data` toggle (197-209) | backend-specific (Virtuoso issue #126) | implicit |
| 7 | **Constructor options** `redis_cache:` / `logger:` | `client.rb#initialize` (101-124) | yes | both passed from `goo.rb` |
| 8 | **HTTP hooks** `pre_http_hook` / `post_http_hook` | `client.rb` (819, 824) | **no — vanilla stubs** | unused today |
| 9 | **`call_query_method`** hardcodes `Query.send` | `client.rb` (308-315) | no — vanilla | the reason decorator/custom-Query is hard (see §3) |

Two corrections to the working assumptions worth nailing down:

- **`optional_union_with_bind_as` is live**, not orphaned. It is called from
  `query_builder.rb` and consumed by `to_s`. The genuinely **dead** code is the
  `:unions_with_bind` branch (`to_s` 846-850) — nothing populates `options[:unions_with_bind]`
  anymore because the public `union_with_bind_as` method that used to feed it was the method
  silently dropped in the past reset. Porting drops that branch; it does not need a home.
- **The goo subclass calls `super` nowhere** and overrides none of `query`/`update`/
  `parse_response`. It only *adds* methods (data loading, `DropGraph`, rapper conversion,
  status throttling). That is precisely why caching/logging ended up in the gem — there was
  no override seam being used. The fix is to start using it.

---

## 2. Target architecture

```
ruby-rdf/sparql-client            (vanilla, pinned by tag — or a thin readable fork branch
   │                               carrying only not-yet-merged upstreamable patches)
   └── SPARQL::Client / Query / Update / InsertData
          ▲ prepend (Query DSL, serialization quirks, InsertData#to_s)
          │
Goo::SPARQL::Client < SPARQL::Client      ← composition root (already exists)
   │  prepend Goo::SPARQL::Ext::Caching   ← wraps #query / #update via super
   │  prepend Goo::SPARQL::Ext::Logging   ← wraps #query / #update via super (outermost)
   │  + existing data-load / status / append methods
   │
   └── uses Goo::SPARQL::AuthStrategy     ← already the template; pure-function module
```

Proposed layout (mirrors the auth module that already exists):

```
lib/goo/sparql/ext/
  caching.rb            # Goo::SPARQL::Ext::Caching — prepended onto Goo::SPARQL::Client
  logging.rb            # Goo::SPARQL::Ext::Logging  — prepended onto Goo::SPARQL::Client
  query_extensions.rb   # union-with-bind as QueryElement builder (+ optional Query DSL sugar)
  virtuoso_compat.rb    # serialize quirk + InsertData toggle, prepended onto gem classes
lib/goo/sparql/auth_strategy.rb   # already exists — the pattern to copy
```

Why these seams and not others — the four candidate techniques, decided per concern:

- **Subclass + `super` (or `prepend` a module that calls `super`)** — for `query`/`update`.
  This is the cleanest because both are public methods on the parent that the subclass does
  *not* currently touch; wrapping them needs **no upstream code copied**. `prepend` (rather
  than writing the body directly in the subclass) keeps each cross-cutting concern in its own
  file, independently testable, and lets ordering be explicit. Ancestry after
  `prepend Caching; prepend Logging` is `Logging → Caching → Goo::SPARQL::Client →
  SPARQL::Client`, so logging is outermost and times the cache lookup + records cache
  hit/miss — exactly what the current logger does.

- **`prepend` onto gem classes** (`SPARQL::Client::Query`, `Update::InsertData`, and the
  `SPARQL::Client` singleton for the class-method `serialize_patterns`) — for the DSL sugar
  and the Virtuoso/4store quirks. The gem *instantiates these classes internally*
  (`call_query_method` does `Query.send(...)` — hardcoded, §9 in the table), so a client
  subclass can't reach them. `prepend`+`super` can, without copy-pasting `to_s`.

- **The gem's `QueryElement` seam** — the *preferred* home for union-with-bind (see §4.3).
  It needs no gem patch at all, which is strictly better than prepending `Query`.

- **`pre_http_hook` / `post_http_hook`** — reserved for *wire-level* metrics (status codes,
  payload sizes, redirects). They only fire on the HTTP path, not the in-process
  `RDF::Queryable` path, and they sit *below* the cache, so they're the wrong seam for the
  cache-aware logging we have. Keep them in the toolkit for future HTTP metrics; don't route
  the existing logger through them.

- **Decorator / `SimpleDelegator` — rejected.** `call_query_method` binds the convenience
  `.execute` to `client.query(self)` where `client = self` at construction time. Wrapping a
  vanilla client in a delegator means `select`/`ask`/… are delegated to the *inner* client,
  so `self` inside `call_query_method` is the inner vanilla client and `.execute` bypasses
  the decorator's caching entirely. Subclass/prepend keep `self` as the goo client, so
  `.execute` routes through the overrides. This is the decisive reason to stay with
  inheritance, not composition-by-wrapping, for the request methods.

- **Refinements — rejected.** Break under `send`/dynamic dispatch (the gem uses `Query.send`
  and define_method heavily), are lexically scoped (awkward for framework-wide behavior), and
  add dispatch cost. Wrong tool for cross-cutting infrastructure.

---

## 3. Per-feature mapping

### 3.1 Caching → `Goo::SPARQL::Ext::Caching` (prepend, wraps `super`)

```ruby
module Goo::SPARQL::Ext::Caching
  def query(query, **options)
    return super unless cache_enabled?(query, options)
    hit = @cache.fetch(query, options)
    return hit if hit
    result = super                       # vanilla gem does HTTP + parse_response
    @cache.store(query, options, result) # cache the *return value of super*
    result
  end

  def update(query, **options)
    result = super                       # do the write FIRST
    @cache.invalidate(query.options[:graph]) if cache_enabled?(query, options)
    result
  end
end
```

Override points: `#query`, `#update`. The cache object itself (`cache.rb`) moves to
`goo` largely intact; only its *wiring* changes.

How this dissolves existing bugs as a structural side effect:

- **`options[:cache_key]` side-channel disappears.** Today `parse_response` (437-438) writes
  the cache using a `cache_key` that `cached_query_response` smuggled into `options` (cache.rb
  115). Because the bolt-on caches the *return value of `super`* directly in `#query`,
  `parse_response` goes back to vanilla and the cross-method side-channel is gone.
- **Invalidate-before-write is fixed.** Today `#update` invalidates at 378-381 *before*
  executing the write. Moving invalidation after `super` makes it invalidate-after-commit —
  the correct order.
- **Silent invalidation failure** (cache.rb `puts "warning: ..."`) becomes a real logged
  event / raise in goo-owned, tested code instead of a swallowed `puts`.
- The **read/write resurrection race** is still a logical concern (the canonical fix is
  tracked in the cache-consistency thread), but extraction removes the structural obstacle —
  read and write now live in one method around a single `super`, so the ordering is reviewable
  and testable rather than scattered across three gem methods.

### 3.2 Logging → `Goo::SPARQL::Ext::Logging` (prepend, outermost)

Same shape, prepended *after* Caching so it wraps it:

```ruby
module Goo::SPARQL::Ext::Logging
  def query(query, **options)
    return super unless @logger&.enabled?
    @logger.around(query, user: options[:user]) { super } # observes cached vs not via result
  end
  # update likewise
end
```

Override points: `#query`, `#update`. `logging.rb` moves to goo. It is opt-in today (only
active when `logger:` is passed — only the query client gets one), so it ships dormant and is
the **lowest-risk first extraction**. Keep `pre/post_http_hook` documented as the place to add
wire-level metrics later; do not fold the cache-aware logger into them.

### 3.3 Union-with-bind DSL → `QueryElement` builder in goo (no gem patch)

The cleanest externalization needs **no gem change at all**. `serialize_patterns` already
handles `when SPARQL::Client::QueryElement then [pattern.to_s]`. So `goo` builds the
`{ … } UNION { … } BIND(… AS ?…)` block as a `QueryElement` (or a tiny goo subclass of it that
emits the string `union_bind_in_where` wants) and adds it through the standard `.where(...)`.

- Override point: none in the gem. The logic moves into
  `lib/goo/sparql/ext/query_extensions.rb` and `query_builder.rb#union_bind_in_where` calls it.
- The current `optional_union_with_bind_as` / `add_union_with_bind` / the `to_s` buffer
  surgery (the fragile `buffer.pop` then re-append) all **leave the gem**.
- The **dead `:unions_with_bind` branch is simply not ported.**
- If a fluent `query.optional_union_with_bind_as(...)` call site is worth preserving for
  ergonomics, add it as thin sugar by `prepend`ing `SPARQL::Client::Query` in
  `query_extensions.rb` — but prefer the QueryElement route as primary, since it keeps the gem
  untouched and the SPARQL-string generation in goo where it can be snapshot-tested.

### 3.4 Virtuoso / 4store quirks → `Goo::SPARQL::Ext::VirtuosoCompat` (prepend gem classes)

Two small, backend-routed prepends. `goo` already knows the backend
(`Goo.backend_4s?`, `backend_vo?`, `backend_gb?`, `backend_ag?` in `goo.rb` 66-80):

- **`xsd:string` forcing** (client.rb 728-730, query.rb 978-980 — currently duplicated):
  `prepend` `serialize_patterns` on the `SPARQL::Client` singleton and on `Query`, call `super`,
  and apply the `^^xsd:string` annotation only when `Goo.backend_4s? || Goo.backend_vo?`. One
  copy of the rule in goo replaces two copies in the fork. *Better still:* contribute a
  `force_typed_string_literals:` option upstream (generically useful for strict stores) and
  drop the prepend once merged.
- **`INSERT` vs `INSERT DATA`** (update.rb 197-209): `prepend`
  `SPARQL::Client::Update::InsertData#to_s`, call `super`, and rewrite only when the Virtuoso
  toggle applies. **First verify the toggle is still needed** — Virtuoso issue #126 may be
  closed; if so this is deletable, not portable.

### 3.5 Multiple `FROM` (#4) and empty-binding tolerance → upstream PRs

These are generic correctness improvements, not NCBO policy. They should be **contributed
upstream** (see §6) and consumed from a vanilla release, not carried as fork edits. Until
merged, they're the kind of patch a *thin* fork branch may hold (cleanly, one commit each).

### 3.6 Auth (already done) — the template, not new work

`feature/sparql-backend-auth` already implements the pattern this whole proposal
generalizes: `AuthStrategy` is a `module_function` utility (no state), the auth dict lives on
the client (`attr_accessor :auth`), and it is applied at exactly three seams
(`headers_for` for the gem's HTTP clients, `apply_to_rest_client` for the bulk-append path,
`apply_to_net_http` for `/status`). No gem edits. Treat it as the reference implementation for
"how an NCBO concern bolts onto a vanilla client." See `docs/sparql_backend_auth.md`.

---

## 4. Why not keep the hard fork — maintainability / perf / idiom

- **Maintainability.** The fork's value-add is invisible: ~80% of its diff is re-indentation,
  so reviewers can't see the 20% that matters, and upstream merges are manual and lossy (it
  already cost a dropped public method). Bolt-ons invert this: each concern is a ~30-line file
  in goo with its own tests, and the dependency diff is *empty* (or a readable one-commit-per-
  patch branch). Upstream security fixes become a version bump.
- **Performance.** No regression. `prepend`+`super` is ordinary method dispatch — one extra
  frame per `query`/`update`, identical to the current in-gem call. The QueryElement route
  produces the same SPARQL string. (Refinements *would* cost dispatch — another reason they're
  out.)
- **Idiom.** Subclass-as-composition-root + `prepend` for cross-cutting concerns + a
  pure-function strategy module is standard Ruby. Soldering app policy into a vendored gem is
  the anti-pattern we're removing.

Explicit recommendation: **do not continue the hard fork.** Move to a pinned vanilla upstream
(`gem 'sparql-client', '~> 3.x'` by released version, or a `:git` tag pin) plus the goo
bolt-ons. If any upstreamable patch is not yet merged, hold it on a **thin** fork branch whose
diff is one clean commit per patch — never the current whitespace-laden branch.

---

## 5. Phased migration plan (smallest safe step first)

### Two gates, not one

The work has **two** validation gates, and they are not the same:

- **Development gate — goo's own suite.** goo's tests already run against a *live* triple
  store and a real Redis (`test/test_case.rb:91` does `add_sparql_backend(:main, query:
  "http://…", …)`), so they are full integration tests of goo + sparql-client + backend, not
  unit mocks. They already cover the moved features: `test/test_cache.rb` (162 lines),
  `test/test_logging.rb` (54 lines), `test/test_where.rb` (673 lines, exercises the query
  builder), and the union-with-bind path is hit by every `.include(...)` test (see §7). This
  is the gate for *developing the bolt-ons* — and it is sufficient for almost all of it.
- **Release gate — cross-stack, once.** `ontoportal_testkit` (goo → ontologies_linked_data →
  ontologies_api, ncbo_annotator, ncbo_cron) is a **final confidence pass before flipping the
  dependency / merging downstream**, to catch call patterns goo's own tests don't exercise.
  It is **not** a per-phase prerequisite and **not** required to start.

There is no separate "sparql-client integration harness" to build: sparql-client is goo's
dependency, so running goo's suite against a real backend *is* the integration test for the
goo + sparql-client pair.

### The development loop (red → green on goo's suite)

The fastest safe way to do the extraction:

1. Branch goo; flip the `Gemfile` to vanilla/near-vanilla upstream sparql-client.
2. Run goo's suite — it goes **red exactly where the fork's behavior is now missing.** That
   red set is the spec for what the bolt-ons must restore.
3. Re-add each behavior as a goo bolt-on (§3) until the suite is green again.
4. Green goo suite ⇒ bolt-ons correct. Run the cross-stack pass once before merging.

Caveat that makes this honest: green proves safety only where the suite *exercises* the moved
behavior. A feature with no test won't turn red when removed, so green is a false negative.
Phase 0 closes that gap (the coverage audit) before the loop is trusted.

### Phases

Each phase is independently shippable and gated on the **development gate** (goo's suite); the
**release gate** (cross-stack) runs once, at phase 7.

0. **Coverage audit + characterization baseline (goo-only, no harness needed).** Confirm
   goo's suite actually exercises each behavior being moved; fill gaps. Known status (§7):
   union-with-bind ✓ covered via `.include`; caching present but **add an explicit
   invalidate-after-write ordering assertion** (currently unverified); Virtuoso/4store quirks
   only fire on those backends, so either ensure the CI backend matrix covers them or add
   SPARQL-string snapshot tests. Add *characterization tests* that snapshot the SPARQL strings
   currently generated (query, update, union-with-bind, insert, serialize quirks). These
   golden files are the contract the migration must preserve.

   *Status (implemented on `feature/sparql-client-defork`):*
   - **Read path — `test/test_sparql_query_characterization.rb`** (13 tests — stale count corrected):
     pins the generated SPARQL for the baseline WHERE shape, union-with-bind on **both**
     branches (BIND for 4store/GraphDB, FILTER otherwise), nested joins, equality + regex
     filters, ORDER BY, COUNT, and paginated id-fetch. Runs **fully offline** — no triple
     store or Redis — by intercepting `Goo::SPARQL::SolutionMapper#map_each_solutions` to
     capture `select.to_s` and skip execution, and flips `Goo.backend_*?` by re-registering
     the `:main` backend with a given `backend_name`.
   - **Write path — `test/test_sparql_write_characterization.rb`** (5 tests / 5 assertions):
     pins the two Virtuoso/4store quirks of §3.4 — `INSERT` vs `INSERT DATA`
     (`use_insert_data` toggle) and `xsd:string` forcing in `serialize_patterns` — built from
     an in-memory model and the gem's `Update`/serialize objects directly (offline).
   - **Cache ordering — IMPLEMENTED** (status corrected; was a "skipped placeholder"). Phase 3 is
     done: `test/test_cache.rb#test_invalidation_happens_after_write` is active and asserts
     write-then-invalidate ordering. (It requires a live backend + Redis, unlike the offline
     characterization tests.)

   Total ~17 offline tests / ~21 assertions, ~25 ms. These are the byte-level contract the
   migration must preserve; rerun them after the dependency flip and they must stay green.

1. **Scaffold, no behavior change.** Create `lib/goo/sparql/ext/` and require it; modules
   empty / no-op. Pure plumbing PR.

2. **Extract logging** (lowest risk — opt-in, dormant by default). Move `logging.rb` to goo,
   prepend `Ext::Logging`, delete `logging.rb` + the `@logger.log` calls from the fork. Verify
   logs identical when `logger:` is set.

3. **Extract caching** (fix bugs *during* extraction). Move `cache.rb` to goo, prepend
   `Ext::Caching` wrapping `super`, restore vanilla `parse_response`/`update` in the fork.
   Land invalidate-after-write and the dropped side-channel as part of this PR; reference the
   cache-consistency thread for the resurrection-race fix and decide it here rather than in the
   fork.

4. **Extract union-with-bind** as a `QueryElement` in goo; repoint
   `query_builder.rb#union_bind_in_where`; delete `optional_union_with_bind_as` /
   `add_union_with_bind` / both `to_s` union branches (including the dead one) from the fork.
   Snapshot tests from phase 0 prove byte-identical SPARQL.

   *Status (done on `feature/sparql-client-defork`, goo side):*
   `Goo::SPARQL::Ext::UnionWithBind` (`lib/goo/sparql/ext/query_extensions.rb`) is a plain
   `QueryElement` built only from vanilla primitives (`SPARQL::Client.serialize_value`,
   `RDF::Query::Variable`). `QueryBuilder#union_bind_in_where` now constructs it and
   `#apply_union_with_bind` pushes it onto the query's filter list (rendered verbatim via
   `map(&:to_s)` — no `FILTER()` wrapper, no trailing ` .`), injected after the real filters
   so ordering matches the old fork DSL. goo no longer calls `optional_union_with_bind_as`.
   Byte-identical output is locked by `test/test_sparql_query_characterization.rb` (BIND +
   FILTER branches, direct/inverse/mixed, plus a filter+include ordering case). The fork's
   now-unused DSL methods are deleted at the gem level later (phase 7 / vanilla flip), not
   here — goo simply stopped depending on them.

5. **Extract Virtuoso/4store quirks** to `Ext::VirtuosoCompat`, routed by `Goo.backend_*?`;
   delete the duplicated serialize logic and the InsertData toggle from the fork. Confirm
   whether the `use_insert_data` toggle is still needed; drop if Virtuoso #126 is fixed.

6. **Upstream PRs** to `ruby-rdf/sparql-client`: multiple `FROM`, empty-binding tolerance,
   optional `xsd:string` forcing flag, and (optionally) an `INSERT` toggle option. Consume
   them from a vanilla release as they merge.

7. **Flip the dependency + cross-stack release gate.** Once the fork holds nothing
   NCBO-specific, change `Gemfile` to a vanilla upstream pin (released version or tag). If PRs
   from step 6 are still open, point at a thin fork branch holding only those clean commits.
   Run the `ontoportal_testkit` cross-stack pass here (the one time it gates), then delete the
   `ontoportal-lirmm-development` fork branch.

Rollback at any phase is a one-line `Gemfile` revert plus reverting the goo PR — because the
fork still exists and is functionally whole until phase 7.

---

## 6. What to push upstream vs keep in goo

| Push upstream (generic) | Keep in goo (NCBO policy) |
|-------------------------|---------------------------|
| Multiple `FROM` support | Redis caching (Ext::Caching) |
| Empty-binding tolerance | Query logging (Ext::Logging) |
| Optional `xsd:string` forcing flag | Union-with-bind query shape |
| Optional `INSERT`/`INSERT DATA` toggle | Backend routing (`backend_*?`) |
| (already upstream) `pre/post_http_hook` | Auth strategy |

---

## 7. Test strategy

The fork ships **no** tests for cache or logging today — but goo's own suite does, and it runs
against a live backend + Redis (§5, "Two gates"). The development gate is goo's suite; the
cross-stack harness is a one-time release gate, not a per-phase prerequisite.

**Coverage audit (what goo's suite already covers vs. gaps to fill in phase 0):**

| Moved behavior | Covered by goo's suite today? | Action |
|----------------|-------------------------------|--------|
| Caching | yes — `test/test_cache.rb` (hit/miss, bypass/reload) | **add invalidate-after-write ordering assertion** (the bug-fix is otherwise untested) |
| Logging | yes — `test/test_logging.rb` (opt-in path) | confirm cached-vs-not + timing assertions; add Redis-absent path |
| Union-with-bind | **yes** — every `.include(...)` in `test_where.rb`/`test_inverse.rb` flows through `query_builder#union_bind_in_where` → `optional_union_with_bind_as` | add SPARQL snapshot to lock byte-output; ensure both BIND (4s/graphdb) and FILTER (other) branches run in the backend matrix |
| Virtuoso/4store quirks | **yes (offline)** — `test/test_sparql_write_characterization.rb` pins `INSERT`/`INSERT DATA` + `xsd:string` forcing | keep; optionally also run the live suite on a Virtuoso/4store matrix entry |

- **Unit (goo-owned), per bolt-on:**
  - Caching: hit, miss-then-store, `bypass_cache`/`reload_cache`, **invalidation ordering**
    (assert write happens before invalidate), invalidation-failure is surfaced not swallowed,
    >50MB payload skipped.
  - Logging: enabled vs disabled (default off), cached-vs-not recorded, timing captured,
    Redis-absent path.
  - Query-extensions: snapshot the generated SPARQL for union-with-bind across
    4store/GraphDB (BIND) vs other (FILTER) branches.
  - VirtuosoCompat: snapshot serialized patterns with/without backend flag; InsertData
    `INSERT` vs `INSERT DATA`.
  - Use the existing `test/test_auth_strategy.rb` as the structural model.
- **Characterization / golden (phase 0):** SPARQL-string snapshots that must stay
  byte-identical across the move — the safety net for "did extraction change the wire output."
- **Cross-stack (release gate, once):** `ontoportal_testkit` exercises goo through
  ontologies_linked_data, ontologies_api, ncbo_annotator, ncbo_cron. It runs at phase 7 before
  the dependency flip, to catch downstream call patterns goo's own suite doesn't — not a
  per-phase blocker.

---

## 8. Relationship to other open threads

- **`ontoportal_testkit` cross-stack harness** — separate task (partly implemented, not yet
  committed). It is this migration's **release gate** (one cross-stack pass at phase 7), *not*
  a prerequisite for the goo-side development work, which is gated on goo's own suite (§5).
  Do not duplicate; reference.
- **Union-with-bind disposition** and **Redis cache consistency** — both fold into this work.
  Resolve them *while extracting* each concern into goo-owned, tested code (§3.1, §3.3) rather
  than patching the fork.
- **Auth** (`docs/sparql_backend_auth.md`) — already shipped pattern; the template here.
- **`append_triples_batch` swallows auth/HTTP failures** — pre-existing bug noted in the auth
  doc; orthogonal to de-forking but lives in the same `Goo::SPARQL::Client` file, so fix it in
  the same neighborhood when convenient.
