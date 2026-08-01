# Code Review: sparql-client de-fork (goo)

**Scope.** Independent review of the migration that drops goo's dependency on the NCBO hard
fork of `sparql-client` (pinned `github: 'ncbo/sparql-client', branch: 'development'`) in favor of
vanilla `sparql-client` 3.2.2 (`ruby-rdf/sparql-client`) plus goo-owned bolt-ons. The effort spans
two concerns:

- **Caching de-fork** (production-critical) — vanilla 3.2.2 + goo bolt-ons + Redis read-through
  cache. Canonical branch: **`feature/sparql-client-defork`** (this branch; query-logging removed).
- **Observability** (optional, disable-able) — query logger, cache hit-rate, query counter, per-test
  reporting. Lives on the separate `feat/sparql-observability` stack.

**Branch note.** This document lives on `feature/sparql-client-defork` (caching-only). Its
`file:line` references to `lib/goo/sparql/cache.rb`, `ext/query_extensions.rb`,
`ext/virtuoso_compat.rb`, and `query_builder.rb` are accurate on this branch (byte-identical to the
tree the review was run against). References to the observability weave in `client.rb`/`goo.rb` and
to `lib/goo/sparql/query_logger.rb` are against the `feat/sparql-observability` stack, where that
code lives — those files are not present (or differ) on this branch. The review was executed against
the observability-inclusive tree so that both concerns could be exercised together.

**Method.** Diffed the fork against the locally-installed vanilla 3.2.2 gem
(`~/.rbenv/versions/3.2.10/.../gems/sparql-client-3.2.2`) to enumerate every NCBO delta; mapped
each delta to its goo re-home; read both branch diffs; ran the offline characterization tests and
the live cache/observability tests (4store on `localhost:9000`, redis on `:6379`) with SimpleCov.

**Bottom line.** The migration is well-engineered and, in the parts that matter for production
reads/writes, faithful and *better factored* than the fork. The cache read-through, the
invalidate-after-write change, the form-urlencoded transport, and the backend quirks are all
re-homed cleanly via subclass + `Module#prepend` + a `QueryElement`, leaving the gem vanilla and
upstream-pullable. **It is close to landable but not yet there.** The single most important issue is
that **the cache is load-bearing, not optional** — a production trace shows one
`classes/{cls}#tree` request fanning out to ~2000 Redis reads behind a single SPARQL query, so a
Redis outage is a first-class failure mode that the current code handles the worst possible way
(see [§2A](#2a-caching-is-load-bearing--the-central-operational-risk) / **H-3**). Beyond that there
is one genuine fidelity divergence in *what* gets cached (**H-1**), a couple of correctness nuances
around the invalidation race and ungraphed updates, material **test gaps** (no offline coverage of
reload/bypass/redis-down/large-entry/multi-graph paths), and **zero performance comparison** against
the fork. None are data-corruption blockers, and the migration is not a regression over the fork —
but because **caching is already ON in prod/stage** (the consuming apps set `use_cache=true`;
goo's bundled cache-off default is not what runs), the Redis-down behavior is a live production risk
*today*, and the de-fork is the right moment to address it. **[§0](#0-decisions-to-make) is the
decision register** (the judgment calls needing sign-off); the prioritized checklist at the end says
what to close before shipping. **Update (D13):** shipping has since been resequenced — the de-fork
lands **parity-pure first** (Ship 1); the H-3/§2A resilience work is an immediate fast-follow on its
own branch (Ship 2). See D13.

---

## 0. Decisions to make

Most of §8's checklist is "just implement it." The items below are the genuine **judgment calls** —
real trade-offs with no single right answer — that need an owner's sign-off. Everything else has a
clear recommended default. IDs (D1–D12) are referenced from the findings and the checklist.

**Status: all decisions D1–D13 (and D6a) are made** (rows marked DECIDED below; **D13 — ship
sequencing — added in the reviewer response**) — the register is now
a spec, and the §8 checklist is pure implementation. Several carry explicit **follow-ups** to confirm
during/after rollout: D3 (downstream raw-CONSTRUCT check), D4 (re-evaluate retry-vs-no-retry once the
new failure metric exists), D7 (threading model — **closed: unicorn**, process-per-worker; defer safe), D8 (confirm no legitimate
ungraphed-cacheable-update caller).

**Blocking — decide before the de-fork ships** (caching is already ON in prod/stage, so the
resilience calls are live, not hypothetical):

| ID | Decision | Options | Recommended / Decision | Refs |
|---|---|---|---|---|
| **D1** | When the **Redis breaker is open**, what do cache-dependent reads do? | — **DECIDED: fail fast → `503` + alert** | Sheds load; protects the triplestore from the ~2000× amplification. Those endpoints are down during a Redis outage, but the backend and other tenants survive. Implement per H-3/§2A. | H-3, §2A |
| **D2** | **Client-side breaker + bulkhead on the SPARQL endpoint?** | — **DECIDED: yes — reads + writes, now** | Client-side (latency/timeout/5xx-driven, *not* the 4store status scraper), both paths. First read-path protection any backend gets and the backstop against brownout thread-pool exhaustion. Tighten `read_timeout` (§7.3). | H-3, §2A, §7.3 |
| **D3** | **Cache scope** | — **DECIDED: match the fork — JSON SELECT/ASK solutions only** | Minimize change now: add a guard so non-solution results (CONSTRUCT/DESCRIBE/graph) aren't cached + a test (T-7). goo core issues no CONSTRUCT/DESCRIBE (all SELECT, Accept JSON), so it's behavior-preserving for goo's own queries. **Follow-up:** confirm no downstream caller (OLD/cron/annotator) relies on caching a raw CONSTRUCT — moot for correctness (the fork didn't cache them either). | H-1, T-7 |
| **D4** | **Invalidation-failure handling** | — **DECIDED: bounded backoff + jitter retry** (closest to original, minus the 15s stall) | Replace fixed `sleep(5)×3` with capped exponential backoff + jitter (sub-second). **Must add logging + a metric** — the current code logs *nothing* on failure, and the de-fork even dropped the fork's `puts "warning: error in cache invalidation"` ([cache.rb:109-127](lib/goo/sparql/cache.rb#L109)), so this is also fixing an observability regression. **Follow-up:** once the metric shows how often invalidation fails, evaluate whether *don't-retry-inline* is better. | M-5, N-3 |
| **D5** | **Where caching is enabled + is `use_cache` authoritative** | — **DECIDED: goo default OFF; app opt-in via `OP_USE_CACHE`; flag made authoritative** | Make `use_cache` the single source of truth regardless of `add_redis_backend`/`add_sparql_backend` order; new consumers aren't silently load-bearing. | §6 |

**Decide soon (rollout) — not strictly merge-blocking:**

| ID | Decision | Options | Recommended | Refs |
|---|---|---|---|---|
| **D6** | **Cache bounding / eviction** | — **DECIDED: `maxmemory` + `allkeys-lru` (in use)** | Keep it — it's safe *with the current per-read `SISMEMBER`* (an LRU-evicted graph-set reads as stale → conservative miss, never a stale hit). Two follow-ups: (i) it makes the §2A "drop SISMEMBER / write-time eviction" optimization **unsafe** — keep the fail-safe check; (ii) **DECIDED: cache and query-log go on separate Redis *instances*** (see **D6a**) | §7.2, §2A |
| **D6a** | **Cache vs query-log Redis isolation** | — **DECIDED: separate instances** | Needed because `allkeys-lru` is per-*instance*, so a single instance (even split into DBs) lets cache and logs evict each other. **Requires a goo change:** today both are wired to one `@@redis_client` ([goo.rb:193/276/289](lib/goo.rb#L193)); add a distinct log-Redis handle and point `QueryLogger.new(redis:)` at it, leaving the cache on the primary. Consuming apps then configure two endpoints | §6, §7.2 |
| **D7** | **Connection model** for the shared Redis + the shared-client `@op` | — **DECIDED: defer to fast-follow** | Ship the de-fork on the current single shared Redis connection; add `ConnectionPool`/Semian shortly after. **Caveat:** urgency depends on the server threading model — *process-per-worker, single-threaded* (Unicorn/Passenger) → the single connection is per-process and defer is safe; *threaded* (Puma threads>1) → the shared connection under ~2000 ops/request is a real hazard, revisit **before** relying on the breaker. Confirm which OntoPortal/BioPortal runs. `@op` race is likely benign (query/update are separate client instances). **Follow-up CLOSED:** ontologies_api runs **unicorn** (+ unicorn-worker-killer) — process-per-worker, single-threaded — so deferring is safe per this row's own gate. | M-4 |
| **D8** | **Ungraphed update under caching** | — **DECIDED: match the fork — raise** | Restore the fork's `raise "Unsupported cacheable query"` when caching is on and an update has no graph (goo can't know what to invalidate → would otherwise leave stale cache). Near-zero practical impact — goo's write helpers always pass a graph — so it's faithful *and* safe. Lock with T-13. **Follow-up:** investigate whether raising is the right long-term behavior or whether some caller legitimately needs ungraphed cacheable updates. | M-2, T-13 |

**Process / roadmap:**

| ID | Decision | Options | Recommended / Decision | Refs |
|---|---|---|---|---|
| **D9** | **Parity proof as a merge gate?** | — **DECIDED: require the recorded A/B once** | One-shot A/B diffing fork vs vanilla+goo `to_s` for the §3 shapes; commit the recorded result and gate merge on it. Implements T-11. **Update: largely in hand** — the A/B already exists in git history (see the H-2 update: `90c3f25` characterization baseline green against the fork-backed tree; identical goldens green after the `47dcdb9` swap); **DONE — recorded in [docs/sparql-defork-ab-record.md](sparql-defork-ab-record.md)** (fork @ `2ac20b2`: 17 tests, 0 failures; goldens drift-checked baseline→HEAD). | H-2, T-11 |
| **D10** | **`Marshal.load` trust boundary** | — **DECIDED: accept + document + verify** | Keep Marshal; document the trust assumption (Redis single-tenant, network-isolated, authed) and verify the deployment matches (bind/auth/DB). No serialization rewrite in this migration. | §7.1 |
| **D11** | **Rollout/rollback shape** | — **DECIDED: caching branch first, observability fast-follow** | Ship `chore/sparql-client-defork` first (smaller blast radius, cleaner rollback); verify the `use_cache=false` kill switch (D5) first; merge `feat/sparql-observability` shortly after. **Refined by D13** (resilience becomes its own Ship 2 between the two). | §6 |
| **D12** | **Tree N+1 roadmap** | — **DECIDED: file as durable follow-up** | Accept the cache-dependence for this migration (matches current behavior); track the tree-fetch batching separately (checklist #16). **Update:** phase 1 landed — ncbo/ontologies_linked_data#297 batched `hasChildren` (store-bound SPARQL dropped) **but production Redis ops stayed high post-deploy**: the dominant Redis traffic was never the per-node probes and remains **unattributed**. See revised checklist #16/#17. | §2A |
| **D13** | **Ship sequencing — does §8's Must #1 gate the de-fork merge?** *(added in reviewer response)* | — **DECIDED: resequence into three ships** | **Ship 1 (de-fork, parity-pure):** vanilla 3.2.2 + bolt-ons + D3 (fork cache scope) + D8 (restore raise) + D5 (kill-switch authoritative) + §3 tests + D9 recorded A/B — behavior-identical to the fork, smallest reviewable diff, rollback = re-pin the fork. **Ship 2 (resilience; immediate fast-follow, own branch + review):** D1/D2 breaker + bulkhead, D4 retry/logging, §7.3 timeout tightening, T-6 failure-injection tests. **Ship 3:** observability (per D11). Rationale: gating the critical migration on a *new* resilience subsystem contradicts D11's small-blast-radius intent, and Ship 1's Redis-down behavior is **unchanged from the fork** (the fork also let Redis errors propagate out of `#query`) — so Ship 1 does not worsen production; it defers fixing an *inherited* risk by one ship, in exchange for a migration that can be verified as a pure port. | D11, H-3, §8 |

The hard cluster **D1 + D2 + D7** — the coupled "what happens when a dependency is down, and what
keeps the request-thread pool from melting" question — is decided: fail-fast `503` at the Redis
breaker (D1), a client-side breaker + bulkhead on the SPARQL endpoint covering reads and writes (D2),
and a `ConnectionPool`-wrapped Redis deferred to a fast-follow (D7, gated on the threading model). All
thirteen decisions are now settled; the remaining work is **implementation** (§8, resequenced per
D13) plus the rollout follow-ups noted above (D7's threading-model check is closed: unicorn).

---

## 1. Fork → goo feature mapping

Vanilla baseline: `sparql-client` 3.2.2. The fork's diff against vanilla is, by line count,
**mostly cosmetic** (`when`-clause re-indentation in `client.rb`/`query.rb`); the semantic delta is
small and fully enumerated below. `repository.rb` and `version.rb` are **byte-identical** to
vanilla in the fork; `update.rb` differs only in `InsertData#to_s`.

| # | Fork feature | Fork location | goo re-home | Faithful? | Risks / divergences |
|---|---|---|---|---|---|
| 1 | `Cache` class (Redis read-through, graph-set invalidation, MD5 key, 50 MB guard) | `lib/sparql/client/cache.rb` | `Goo::SPARQL::Cache` — [lib/goo/sparql/cache.rb](lib/goo/sparql/cache.rb) | **Yes, key/format verbatim** | `generate_cache_key` copied exactly (cache.rb:70-76). See §2 for the `store`/`get` refactor. |
| 2 | Cache read-through on `#query`; write via `:cache_key` side-channel in `parse_response` | `client.rb` `#query`, `#parse_response` (RESULT_JSON branch only) | `Goo::SPARQL::Client#query` — [client.rb:32-54](lib/goo/sparql/client.rb#L32) | **Behavior changed (improvement + divergence)** | goo stores `super`'s return value directly (no side-channel). **Divergence: goo caches *any* cacheable result; the fork cached *only* `RESULT_JSON` responses.** See finding **H-1**. |
| 3 | Invalidate graph on `#update` | `client.rb` `#update` — **before** the write; raises `"Unsupported cacheable query"` if `graph` nil | `Goo::SPARQL::Client#update` — [client.rb:58-68](lib/goo/sparql/client.rb#L58) — **after** the write | **Intentionally changed** | After-write closes the fork's stale-repopulation race but does not fully eliminate cache-aside races (**M-1**); goo also drops the nil-graph raise and silently skips invalidation (**M-2**). |
| 4 | Form-urlencoded POST transport for protocol 1.1 | `client.rb` `#make_post_request` (rewrites the 1.1 branch) | `#make_post_request` — [client.rb:74-81](lib/goo/sparql/client.rb#L74) (calls `super`, then `set_form_data`) | **Yes** | goo lets vanilla build the request then overrides body+Content-Type via `set_form_data`; net wire output matches. Slightly redundant work; correct. |
| 5 | xsd:string forcing for 4store/Virtuoso | `client.rb` class `serialize_patterns`; `query.rb` instance `serialize_patterns` | `Ext::SerializeXsdString` prepended on `SPARQL::Client.singleton_class` — [virtuoso_compat.rb:15-26](lib/goo/sparql/ext/virtuoso_compat.rb#L15); also re-implemented inside `UnionWithBind#serialize_triples` | **Equivalent in practice** | **Divergence in mechanism:** fork forced xsd:string only in *pattern* position; goo forces it in `serialize_value` (broader surface). Harmless for goo's queries (literals only appear as pattern objects) but wider. Pinned by [test_sparql_write_characterization.rb:62](test/test_sparql_write_characterization.rb#L62). |
| 6 | Empty-binding tolerance (`return nil if value == {}`) | `client.rb` `parse_json_value` | `Ext::EmptyBindingTolerance` prepend — [virtuoso_compat.rb:31-37](lib/goo/sparql/ext/virtuoso_compat.rb#L31) | **Yes, verbatim guard** | **Not directly tested** (no fixture feeding `{}` through `parse_json_value`). |
| 7 | INSERT vs INSERT DATA toggle (`use_insert_data`) | `update.rb` `InsertData#to_s` | `Ext::InsertDataToggle` prepend — [virtuoso_compat.rb:43-50](lib/goo/sparql/ext/virtuoso_compat.rb#L43) | **Yes** | Implemented as `super.sub(/\AINSERT DATA\b/, 'INSERT ')` rather than re-emitting; cleaner. Pinned by [test_sparql_write_characterization.rb:39-49](test/test_sparql_write_characterization.rb#L39). |
| 8 | Multiple `FROM`, nested-UNION inside WHERE | `query.rb` `#to_s` (buffer surgery) | `Ext::QuerySerialization#to_s` prepend — [query_extensions.rb:80-173](lib/goo/sparql/ext/query_extensions.rb#L80) | **Yes** | Wholesale `to_s` override (faithful copy of vanilla + 2 deltas). Pinned by characterization tests. **Fragility:** copies vanilla's `to_s`, so a future vanilla `to_s` change is silently shadowed (**M-3**). |
| 9 | union-with-bind DSL (`optional_union_with_bind_as`, `add_union_with_bind`, `unions_with_bind` render branch) | `query.rb` | `Ext::UnionWithBind < QueryElement` — [query_extensions.rb:23-66](lib/goo/sparql/ext/query_extensions.rb#L23); built by `QueryBuilder#union_bind_in_where` — [query_builder.rb:75-104](lib/goo/sparql/query_builder.rb#L75) | **Yes (golden-locked)** | Re-architected from a gem DSL into a goo `QueryElement` pushed via `options[:goo_union_with_bind]`. Output pinned by [test_sparql_query_characterization.rb:77-158](test/test_sparql_query_characterization.rb#L77) (BIND + FILTER branches). Parity rests on the golden strings being fork-derived — see **H-2**. |
| 10 | `Logging` class (Redis log store, user counts, KEYS-scan retention) | `lib/sparql/client/logging.rb` | `Goo::SPARQL::QueryLogger` — [query_logger.rb](lib/goo/sparql/query_logger.rb) | **Reimplemented, not ported** | New ZSET-based design (O(log N), no Marshal-of-JSON, disjoint keyspace). Better. Backward-compat shim for `get_logs`/`queries_last_n_seconds`/`users_query_count` (**see L-2/L-3**). |
| 11 | `RESULT_PLAIN` const + `parse_plain_bindings` | `client.rb` | **Dropped** | **Correctly dropped** | Dead in the fork (the `RESULT_PLAIN` branch is commented out). Not re-homing dead code is right. |
| 12 | `attr_reader :cache`, `:logger`; `redis_cache=`, `logger=` setters | `client.rb` | `attr_reader :cache, :query_logger`; `redis_cache=`, `query_logger=` — [client.rb:12-26](lib/goo/sparql/client.rb#L12) | **Yes** | Renamed `logger` → `query_logger`; `Goo.logger` alias preserves the downstream name (**L-2/L-3**). |

**Inventory completeness.** The fork's semantic delta against vanilla 3.2.2 is exactly items
1–12. Everything else in the fork diff is whitespace/`when`-indentation. All twelve are accounted
for (re-homed, reimplemented, or deliberately dropped).

---

## 2. Findings by severity

### Blocker
*None as a de-fork **regression*** — the migration introduces no new data-corruption or crash path
versus the fork, and the offline + live tests pass. **But note the operating reality:** goo *ships*
with `use_cache=false`, yet the consuming apps (ontologies_api/OntoPortal) run `Goo.use_cache=true`
in **staging (in-repo config) and production** (deployment-managed config; independently evidenced
by the §2A trace — ~2000 cache reads per request only happen with caching on), so **the
environments that matter run with caching ON** (dev boxes vary per developer and are immaterial). That
means the Redis-down failure modes in **H-3 / M-5** are *current production behavior*, not something
gated behind a future "enable caching" step. They are inherited from the fork (same fail-closed
behavior), so not a regression — but they are live risk that this migration should be the occasion
to fix, and they are the reason this review treats H-3 as the top priority despite there being no
formal "blocker."

### High

**H-1 — Cache scope is wider than the fork (`store` caches more than JSON SELECTs).**
[client.rb:51](lib/goo/sparql/client.rb#L51) calls `@cache.store(query, options, result)` for **every**
cacheable query (`cacheable?` = "is a `SPARQL::Client::Query` *or* `options[:graphs]` present", with
redis on — [cache.rb:80-84](lib/goo/sparql/cache.rb#L80)). The fork only ever wrote the cache from the
**`RESULT_JSON`** branch of `parse_response`; CONSTRUCT/DESCRIBE/RDF/CSV/TSV responses were never
cached. In goo's standard config every client sends `Accept: application/sparql-results+json`
([goo.rb:125](lib/goo.rb#L125)), so for ordinary SELECTs the two are equivalent — **but** any code
path that issues a CONSTRUCT/DESCRIBE or overrides `content_type` will now Marshal and cache an
`RDF::Graph`/statement set the fork left uncached. Risk: larger/odd cache entries, and Marshal
round-trip behavior on graph objects that was never exercised before.
*Action:* **DECIDED (D3): match the fork.** Gate `store` to the JSON/solutions case (SELECT/ASK
results — `RDF::Query::Solutions`/boolean), so CONSTRUCT/DESCRIBE/graph results are not cached, and
add **T-7** to lock it. Confirmed low-risk: goo core issues no CONSTRUCT/DESCRIBE (all model queries
are SELECT with `Accept: application/sparql-results+json`), so this is behavior-preserving for goo's
own queries. Open follow-up: confirm no downstream caller (OLD/cron/annotator) issues a raw CONSTRUCT
through the query client — moot for correctness, since the fork didn't cache those either.

**H-2 — The "byte-identical" claim is golden-string self-consistency, not a proven A/B against the fork.**
[test_sparql_query_characterization.rb](test/test_sparql_query_characterization.rb) and
[test_sparql_write_characterization.rb](test/test_sparql_write_characterization.rb) assert
hard-coded `expected` strings against the *new* implementation. They are strong regression locks
going forward, and the tell-tale quirks in the expecteds (double spaces: `UNION  `,
`FILTER(...)  `; `BIND( "name" as ?attributeProperty)`) strongly suggest they were captured from
real fork output. But nothing in the suite *runs both implementations and diffs them*, so the
parity claim is asserted, not demonstrated. For production-critical wire output this should be
proven once.
*Action:* add a one-shot A/B test (or a documented manual run) that builds the same query objects
against `ncbo/sparql-client@development` and against vanilla+goo and asserts `select.to_s`
equality for the shapes in §3. Keep it as a CI guard behind an env flag, or at minimum record the
A/B run output in the proposal doc.
**UPDATE (reviewer response):** the A/B *was* demonstrated — it is encoded in git history rather
than in a script. On `feature/sparql-client-defork`, commit `90c3f25` (the characterization
baseline) predates the swap (`47dcdb9`) and was green **against the fork-backed implementation**;
the identical golden strings pass after the swap. So D9 is satisfiable cheaply: check out
`90c3f25` (fork pin), run both characterization suites, and record the output alongside this doc.
Do it before this branch lineage is discarded — the ncbo re-implementation lands tests+swap in a
single commit, so the in-history proof exists only on this branch.

**H-3 — The cache is load-bearing, so a Redis outage is a first-class failure mode — and it is currently handled the worst possible way.**
Production traces (NewRelic) show a single `ontologies/{ID}/classes/{cls}#tree` request issuing
**~1 SPARQL query + ~2000 Redis `GET` + ~2000 `SISMEMBER`** — i.e. ~2000 cached reads the
triplestore never sees. The cache is not an optional speed-up; it is structurally required.
Combined with **M-5** (cache `get`/`store` have no rescue, so a Redis blip propagates out of
`#query`) this is the dominant operational risk in the whole migration. The naive "make it fail
open" fix is *wrong here* — failing open amplifies one request into ~2000 SPARQL queries and melts
the backend for all tenants. This needs a deliberate resilience design, not a one-line rescue.
**See the dedicated treatment in [§2A](#2a-caching-is-load-bearing--the-central-operational-risk).**
**Policy DECIDED (D1/D2):** fail fast → `503` + alert at the Redis breaker, plus a client-side
breaker + bulkhead on the SPARQL endpoint (reads + writes). Remaining work is implementation, not a
further decision.

### Medium

**M-1 — Invalidate-after-write reduces but does not eliminate the cache-aside race.**
The code comment ([client.rb:56-57](lib/goo/sparql/client.rb#L56)) and `cache.rb` header claim the
after-write ordering *fixes* the fork's stale-repopulation race. It closes the fork's specific
window (invalidate → [concurrent read repopulates old] → commit), which was real. But the classic
cache-aside race survives in **both** orderings: a slow reader that fetched the *pre-write* result
from the store can `store` it into Redis *after* the writer's invalidate, leaving a stale entry
until the next write to that graph. The client is shared across request threads, so this is
reachable in production. Don't overstate the guarantee.
*Action:* reword the claim to "narrows the window"; if true correctness is needed, add
versioned keys or an invalidation epoch. At minimum document the residual window. (Low likelihood,
self-heals on next write, but worth stating honestly for critical infra.)

**M-2 — Ungraphed update under caching silently skips invalidation (fork raised).**
Fork `#update`: `raise "Unsupported cacheable query" if query.options[:graph].nil?` when redis is on
and not bypassed. goo ([client.rb:63-66](lib/goo/sparql/client.rb#L63)) instead does
`@cache.invalidate(graph.to_s) if graph` — i.e. an update with no graph runs and **invalidates
nothing**, which can leave stale cache for graphs that update touched. In practice goo's write
helpers (`put_triples`/`append_triples*`/`delete_graph`, [client.rb:279-305](lib/goo/sparql/client.rb#L279))
always pass a graph and *also* invalidate via the query client, so the exposure is small. But the
fork's loud failure was a safety net that's now gone.
*Action:* **DECIDED (D8): restore the fork's `raise`** ("Unsupported cacheable query") when caching
is on and an update has no graph. Faithful to the fork and safe (goo always passes a graph, so it
effectively never fires). Lock with T-13. **Follow-up:** confirm no caller legitimately needs an
ungraphed cacheable update before treating the raise as permanent.

**M-3 — `QuerySerialization#to_s` is a wholesale copy of vanilla `to_s`; upstream drift is shadowed.**
[query_extensions.rb:80-173](lib/goo/sparql/ext/query_extensions.rb#L80) reproduces vanilla's entire
`to_s` (group_by, order_by validation, offset/limit, prefixes) to inject two deltas. A future
`sparql-client` that fixes/extends `to_s` will be silently overridden because goo's `prepend`
defines `to_s` without calling `super`. This is the one place the "easily pull upstream fixes"
architecture goal leaks.
*Action:* add a guard test that fails if vanilla's `to_s` source changes (e.g. assert a checksum of
`SPARQL::Client::Query.instance_method(:to_s).source_location` region, or pin the gem version and
re-review on bump). Long-term, push the multiple-FROM + nested-UNION deltas upstream (both are
generic, non-NCBO improvements) and delete the override.

**M-4 — Thread-safety of the shared client and the single Redis connection (inherited, unaddressed).**
`Goo.sparql_query_client(:main)` returns one shared `Goo::SPARQL::Client` reused across all request
threads. Vanilla mutates instance state per call — `@op`, `@alt_endpoint` (set in `#query`/`#update`,
read in `#make_post_request`/`set_url_default_graph`). Concurrent query+update on the same client
can interleave `@op`, producing a malformed request. Separately, `@@redis_client = Redis.new(...)`
([goo.rb:193](lib/goo.rb#L193)) is a **single connection** shared by every thread; redis-rb is not
safe for concurrent use of one connection. Both predate this work (the fork had them), and the
de-fork's own additions are thread-correct (it uses `Thread.current[:goo_last_response_bytes]`,
[client.rb:46/87](lib/goo/sparql/client.rb#L46)). The `@op` race is likely benign in practice —
`Goo.sparql_query_client` and `sparql_update_client` are **separate client instances**, so a given
client only ever sets one `@op` value. The real exposure is the **single shared Redis connection**;
under a *threaded* app server and the §2A ~2000-ops/request profile it's a throughput bottleneck and
a concurrency hazard.
*Action:* **DECIDED (D7): defer `ConnectionPool` to a fast-follow.** Safe to defer **if** the app
runs process-per-worker, single-threaded (each process owns its connection); **revisit before
relying on the breaker if threaded** (Puma threads>1). Confirm the deployment threading model. Not a
defork regression.

**M-5 — Cache failure handling is mechanically wrong (the implementation side of H-3).**
These are the concrete code defects; the *policy* of what to do on Redis failure is **H-3 / §2A**.
- `cache_invalidate_graph` ([cache.rb:109-127](lib/goo/sparql/cache.rb#L109)) retries up to 3× with
  **fixed `sleep(5)`** — a write racing a Redis blip blocks a request thread up to 15 s, then gives
  up **silently, with no log at all**. This is also an **observability regression**: the fork logged
  del failures (`puts "warning: error in cache invalidation ..."`), and the de-fork port dropped
  that line — so there is currently *zero* signal on how often invalidation fails. Fixed-interval
  retry across many threads also *synchronizes* the retries → a retry storm when Redis recovers
  (thundering herd). `sleep(5)` in a request path is dangerous under load.
- `get`/`store` ([cache.rb:31-64](lib/goo/sparql/cache.rb#L31)) have **no** rescue at all: if Redis is
  down, `@redis_cache.get`/`sadd`/`set` raise straight out of `#query`. The QueryLogger degrades
  gracefully (`with_redis`, [query_logger.rb:200-204](lib/goo/sparql/query_logger.rb#L200)); the
  cache does not. So *observability* is safe to fail but *caching* is not — exactly backwards for a
  load-bearing dependency.
*Action:* (1) **DECIDED (D4):** replace fixed `sleep(5)` retry with **capped exponential backoff +
jitter**, and **restore logging + add a failure metric** (fixing the dropped-`puts` regression) —
then re-evaluate *don't-retry-inline* once the metric shows real failure frequency. (2) Route
`get`/`store` failures through a circuit breaker (H-3/§2A — **DECIDED: fail-fast `503`**), not a bare
`rescue → fall through`, because bare fall-through is the backend-melting path. (3) Log at *state
transitions*, never per-op (a per-op warning on a 2000-op request is its own firehose).

### Low

**L-1 — Observability is *near*-zero overhead when off, not literally zero.** Even fully disabled,
`#query` allocates a bytes proc and writes `Thread.current[:goo_last_response_bytes] = nil` per
query ([client.rb:46-48](lib/goo/sparql/client.rb#L46)), `#response` writes the thread-local on
every response ([client.rb:85-89](lib/goo/sparql/client.rb#L87)), and `tick_query_count` does two
nil checks. Negligible, but the "zero code-path impact" framing is slightly optimistic. The
caching-only branch avoids all of it (no logger code at all — verified).

**L-2 — `Goo.logger.info` arity changed.** Fork `Logging#info(query, id:, cached:, user:,
execution_time:)`; goo `QueryLogger#info(message, cached:, user:)`
([query_logger.rb:128](lib/goo/sparql/query_logger.rb#L128)). Any downstream caller passing the old
`id:`/`execution_time:` kwargs raises `ArgumentError`. Comment says the AgroPortal controller
doesn't call it, but verify across ontologies_api/ncbo_cron/annotator.

**L-3 — `get_logs` payload shape changed.** Fork entries decoded from `Marshal.load`→`JSON.parse`
had keys `id/timestamp/query/cached/user/execution_time`; goo returns `JSON.parse` with additional
`rows`/`bytes` ([query_logger.rb:147-159](lib/goo/sparql/query_logger.rb#L147)). Superset, so likely
compatible, but confirm the Admin::LoggingController doesn't assume an exact key set.

**L-4 — Double invalidation on writes.** `#update` invalidates after write *and* the write helpers
(`put_triples` etc.) invalidate again via the query client ([client.rb:282/288/297/303](lib/goo/sparql/client.rb#L282)).
Harmless and arguably defensive (update-client cache vs query-client cache may differ), but it's
redundant work worth a comment.

### Nit

- **N-1 — Dangling doc reference.** `cache.rb`, `query_extensions.rb`, `virtuoso_compat.rb`,
  and several tests cite `docs/sparql-client-defork-proposal.md`, which is **not committed** in
  either branch. Either add the doc or drop the references.
- **N-2 — `RSPARQL = SPARQL` top-level constant** ([client.rb:5](lib/goo/sparql/client.rb#L5)) leaks a
  global alias; scope it or comment why it's needed (avoids `Goo::SPARQL` vs `::SPARQL` ambiguity).
- **N-3 — `cache_invalidate_graph` retry counter is dead.** `attempts` is incremented but the
  `rescue` re-runs the whole `begin` block via `retry`; with a hard Redis outage this is 3×
  `sleep(5)` then silent success-path exit. The structure reads like it intends bounded retry but
  the bound is on a variable that resets per `graph`. Simplify.

---

## 2A. Caching is load-bearing — the central operational risk

This deserves its own section because it reframes the resilience findings (**H-3 / M-5**) and the
memory/timeout dimensions (§7.2–7.3): in this system the SPARQL cache is **not an optional
optimization — it is structurally required for the backend to survive normal load.**

### The evidence

A production NewRelic trace of `ontologies/{ID}/classes/{cls}#tree` shows a single request issuing
roughly **1 SPARQL query, ~2000 Redis `GET`, and ~2000 Redis `SISMEMBER`.** That maps directly onto
`Cache#get` ([cache.rb:43-51](lib/goo/sparql/cache.rb#L43)), which does **1 `GET` + 1 `SISMEMBER`
per FROM-graph** for every `#query`:

```ruby
data = @redis_cache.get(keys[:query])            # 1 GET
keys[:graphs].each do |g|
  unless @redis_cache.sismember(g, keys[:query]) # 1 SISMEMBER per graph
    @redis_cache.del(keys[:query]); return nil   # lazy stale-eviction
  end
end
```

So that one tree request is **~2000 cached single-graph reads** served entirely from Redis, plus
one real store round-trip. Without the cache, that endpoint is ~2000 SPARQL queries.

### Three consequences

**(a) Load amplification makes "fail open" dangerous.** My original M-5 advice — "on Redis error,
log and fall through to the store" — is correct for a *nice-to-have* cache but wrong here. Falling
through turns one request into ~2000 SPARQL queries; under concurrency that melts 4store/Virtuoso,
taking down **every** tenant — a strictly worse outage than the one Redis caused. The right posture
for a load-bearing cache is usually to **fail fast and shed load** (return `503` quickly) so the
backend survives, *not* to flood it. **DECIDED (D1): fail fast → `503` + alert** — not fall-through.
The code must make this explicit, because today it does neither cleanly.

**(b) Redis failure needs a circuit breaker, not per-request retries.** During a sustained outage
you do not want every request to try Redis, fail, and then either stall (current `sleep(5)×3`) or
flood the backend (naive fall-through). A **circuit breaker** trips after *K* consecutive failures
and then fails *immediately* for a cool-down window, then half-opens to probe recovery. What the
open breaker *does* is the policy decision in (a):

  - **Fail fast / load-shed — ✅ DECIDED (D1)** — return `503` for cache-dependent reads. Safest for
    the backend; contains blast radius to the requests that needed the cache.
  - ~~Local in-process fallback~~ — considered, not chosen (cold/unshared).
  - ~~Bounded fall-through~~ — considered, not chosen (would still pressure the store).

  **Alert when the breaker opens** — a load-bearing cache going down is page-worthy, not a silent
  degrade.

**(c) Retry/backoff mechanics (replacing `sleep(5)×3`).** Where retries *are* appropriate (transient
blips, not sustained outages gated by the breaker), use **capped exponential backoff with jitter**
instead of a fixed interval, so retries back off quickly *and* desynchronize across threads
(the AWS "Exponential Backoff and Jitter" model):

  - Full jitter: `sleep = rand(0, min(cap, base * 2**attempt))`
  - Decorrelated jitter: `sleep = min(cap, rand(base, prev_sleep * 3))`

  With `base≈50ms, cap≈1s`, worst-case total retry time is sub-second and spread out, vs 15 s and
  synchronized today. **For the invalidation path specifically, prefer not retrying inline at all:**
  a missed invalidation just leaves a stale entry that self-heals on the next write, so log + emit a
  metric (and optionally enqueue a deferred re-invalidation) rather than block the writer thread.

### Circuit breaker, in brief (for whoever implements this)

A small state machine wrapping each call to a dependency, so you stop calling something that's
failing instead of piling on:

- **Closed** (normal): calls pass through; failures are counted. Trip to Open after *K* consecutive
  failures (or failure-rate over a minimum volume).
- **Open** (tripped): calls are **not attempted** — they return immediately via the fallback policy
  (the §2A(a) decision: fail-fast `503` / local LRU / bounded fall-through). A cool-down timer runs.
- **Half-open** (probing): after cool-down, a *few* trial calls go through. Success → Closed; failure
  → Open (restart, ideally with backoff). The small trial count is also what prevents a
  thundering-herd rush back onto the dependency the instant it recovers.

Implementation essentials, and the easy mistakes:

- **Only infra errors count as failures** — `Redis::CannotConnectError`/`TimeoutError`, or a SPARQL
  timeout/5xx. A normal **cache miss** (`get` → `nil`) is *not* a failure; tripping on misses is a bug.
- **Per-call timeout must be short**, or the breaker can't detect failure fast. `Redis.new(timeout:
  300)` ([goo.rb:193](lib/goo.rb#L193)) and the SPARQL `read_timeout: 10000` ([goo.rb:126](lib/goo.rb#L126))
  both need tightening for a breaker to mean anything (see §7.3).
- **Alert when it opens** — a load-bearing dependency tripping is page-worthy, not a silent degrade.
- **Pair with a bulkhead** — cap concurrent calls to the dependency so a *slow* (not yet dead) Redis
  or triplestore can't tie up the whole request-thread pool while each call waits out its timeout.
- **Don't hand-roll it.** Ruby has battle-tested options: **Semian** (Shopify; circuit breaker +
  bulkhead purpose-built to protect an app from a slow/down Redis/MySQL/HTTP backend), **Stoplight**,
  **Circuitbox**. The breaker is per-process, which is fine.

### The breaker is needed on the SPARQL endpoint too, not just Redis — ✅ DECIDED (D2): yes, reads + writes

The cache and the triplestore are **two dependencies in series** (cache → store), and the store is
the one that actually melts under the §2A amplification. So the protection belongs on **both**
(DECIDED: add a client-side breaker + bulkhead on the SPARQL endpoint now, covering reads *and*
writes):

- The triplestore (4store/Virtuoso/AllegroGraph/GraphDB) can be slow or down independently of Redis.
  With `read_timeout: 10000` and **no bulkhead**, a backend brownout means every request thread piles
  into the store and blocks ~10 s each → thread-pool exhaustion and a full app stall, even for
  requests that wouldn't have touched the slow query.
- A backend breaker + bulkhead is precisely the **backstop that makes "bounded fall-through" safe**:
  if Redis is down and you choose to fall through to the store, the store-side bulkhead caps
  concurrency and the breaker trips before the ~2000×-amplified load collapses it. Without it,
  "bounded fall-through" has nothing actually bounding it.
- **goo's only existing backpressure is 4store-specific and effectively dormant — it is *not* a
  foundation to build on.** `status` + `status_based_sleep_time` ([client.rb:98-118](lib/goo/sparql/client.rb#L98),
  [client.rb:317-338](lib/goo/sparql/client.rb#L317)) work by **scraping 4store's `/status/` HTML
  page** (`"Running queries</th><td>"` / `"Outstanding queries</th><td>"` — 4store runs 16 queries
  concurrently and queues the overflow as "outstanding") and `raise`-ing when `outstanding > 50`.
  This only exists on 4store: AllegroGraph/Virtuoso/GraphDB serve no such page, so the parse returns
  `nil` and the method would actually **raise** against them, not degrade. It also has **no in-tree
  callers** (only its own `self.status`), so it's dormant in goo (presumably driven from downstream
  bulk-load code), and it covers writes only. **Takeaway:** you can't generalize a backend-specific
  status-page scraper. A backend-agnostic breaker must be **client-side** — driven by what the
  client *observes* on each call (latency, timeouts, connection errors, 5xx), not by polling a
  backend status endpoint that exists only on 4store. Build that for the shared client and apply it
  to the hot read path, which today has no protection at all.
- **Caveat:** the store is the source of truth, so an *open* store breaker has no deeper fallback —
  "fail fast" there means the request genuinely can't be served (`503`/`504`). That's still better
  than a thread-pool-exhausting stall that takes down unrelated requests; the point of the store
  breaker is to **shed load and protect the store from total collapse**, not to provide an
  alternative answer. The durable fix for needing it less is still the tree N+1 (below).

### Cheaper structural fixes worth pursuing in parallel

- **Kill the `SISMEMBER` storm — but only the safe way.**
  1. **Pipeline `GET` + `SISMEMBER`** per query (redis `pipelined`/`MULTI`, or a small Lua
     get-and-validate) → one RTT instead of two, and removes the GET↔membership race. **Safe under
     `allkeys-lru`; this is the recommended win.**
  2. **~~Move eviction to write-time and drop the per-read `SISMEMBER`~~ — do NOT do this under
     `allkeys-lru` (D6).** The tempting idea: on `invalidate`, `SSCAN` the `sparql:graph:<g>` set and
     `UNLINK` the member entry keys + the set, so reads need only the `GET`. It eliminates the ~2000
     `SISMEMBER`s — **but it is unsafe with LRU eviction:** the per-read `SISMEMBER` is also the
     fail-safe that catches entries orphaned when LRU evicts a graph-set (an absent set reads as
     stale → miss). Without it, an LRU-evicted set means its entries can never be invalidated and are
     served **stale indefinitely**. Only viable if the graph-sets are protected from eviction
     (separate no-eviction Redis/DB, or `volatile-lru` with TTLs only on entry keys) *and/or* a
     fallback staleness check is retained. Given `allkeys-lru` is in use, prefer option 1 and leave
     the `SISMEMBER` in place.
- **Attack the N+1 at the source (long-term).** ~2000 cacheable sub-queries for one tree is an N+1
  pattern the cache is papering over. Batching the per-node fetches (fewer, larger queries) both
  removes the load-bearing dependency *and* shrinks Redis traffic — the only thing that makes the
  system safe to run with a *degraded* cache. The existing query-count instrumentation
  (`Goo.count_sparql_queries`, the `ncbo-sparql-query-count` header) is the right tool to find and
  regression-guard these hotspots.
  **UPDATE:** phase 1 landed — ncbo/ontologies_linked_data#297 batched `hasChildren` and cut
  store-bound queries, **but production Redis ops stayed high post-deploy**. So the dominant Redis
  traffic was never the per-node `LIMIT 1` probes; the residual amplification comes from other,
  **unattributed** reads (candidates, all left as #297 follow-ups: per-ancestor `bring(parents:)` in
  `traverse_path_to_root`, the bulk roots load, per-node attribute loads). Attribute before sizing
  further work: reproduce one tree request (large ontology, staging) with `OP_QUERIES_LOGGING=1` —
  the query logger records **cache hits too** (`cached: true` entries carry the full SPARQL text),
  so `Goo.query_logger.all` enumerates exactly which queries compose the ~2000 reads. See
  checklist #16/#17.

### Net

The de-fork did not *create* this coupling (the fork cached the same way), but it is the moment to
treat it as a designed property: **put a circuit breaker + bulkhead on *both* dependencies — Redis
(fail-fast load-shed + alert when open) and the SPARQL endpoint (shed load / `503` to protect the
store, generalizing the ad-hoc write-only `status` backpressure to reads), fix the retry mechanics,
pipeline/relocate the membership check, and file the tree N+1 as the durable fix.** Until that is
done, caching's production risk is *not* contained — which is the gap between "observability can be
turned off safely" and "caching can be turned off safely."

---

## 3. Test-gap list (specific, with suggested tests)

The **offline** characterization suite is good for query/write *shape*; the **live** suite
(`test_cache.rb`) covers the happy-path cache lifecycle. The gaps below are mostly in cache edge
behavior and backend-quirk parsing — exactly the risky parts.

| ID | Gap | Suggested test (offline unless noted) |
|---|---|---|
| **T-1** | `reload_cache` option never exercised ([cache.rb:38-41](lib/goo/sparql/cache.rb#L38) uncovered) | Unit test on `Cache`: seed an entry, call `get(q, reload_cache: true)`, assert `nil` returned and key deleted. |
| **T-2** | `bypass_cache` not tested at the cache seam | `Cache#get` with `query.options[:bypass_cache]=true` returns nil even with a live entry; `store` still writes (confirm intended). |
| **T-3** | 50 MB large-entry skip ([cache.rb:103](lib/goo/sparql/cache.rb#L103)) untested | Stub `Marshal.dump` to report >50 MB (or build a big value); assert `store` writes neither the entry nor the graph-set members. |
| **T-4** | Stale-entry eviction (graph-set membership miss → del + miss) only implicitly hit | Directly: set entry key but `srem` it from one graph set, assert `get` deletes the key and returns nil ([cache.rb:46-51](lib/goo/sparql/cache.rb#L46)). |
| **T-5** | Multi-graph key (`from` as Array; sorted+`uniq`) untested | Assert `generate_cache_key("q", [g2, g1, g1])` → `query` is `sparql:<g1>:<g2>:<md5>` and `graphs` has both `sparql:graph:` members. Pin the exact string. |
| **T-6** | **Redis-down behavior untested** (H-3/M-5) | Inject a redis double whose `get`/`set` raise; assert `#query` behaves per the chosen Redis-down policy (§2A: fail-fast `503` / breaker-open, *not* an unbounded store flood) and `#update` still commits. Add a breaker-state test (opens after K failures, half-opens after cool-down). Highest-value missing test. |
| **T-7** | Cache scope vs fork (H-1) | Issue a CONSTRUCT/DESCRIBE (or a `content_type`-overridden) query with caching on; assert/lock whether it is cached. Encodes the §2 H-1 decision. |
| **T-8** | Empty-binding tolerance (item 6) untested | Feed a JSON fixture with a `{}` binding through `parse_json_value`/`parse_json_bindings`; assert no raise and `nil` column. |
| **T-9** | xsd:string forcing only tested via `serialize_patterns`, not via the prepended `serialize_value` path (item 5) | Assert `SPARQL::Client.serialize_value(RDF::Literal.new("hi", datatype: RDF::XSD.string))` (with goo's `original_datatype`) is typed, and a plain literal is not — locks the broader surface. |
| **T-10** | Invalidation **failure** path (M-5 `sleep`/retry) untested | Redis `del` raises once then succeeds; assert it retries; raises always → assert it gives up without propagating and (after fix) logs. |
| **T-11** | A/B parity vs the fork (H-2) | One-shot test/script diffing fork vs vanilla+goo `to_s` for the §3 shapes; gate behind env flag. |
| **T-12** | Multi-backend quirk matrix | The query characterization covers 4store/virtuoso/allegrograph/graphdb for the simple shape but the BIND-vs-FILTER branch only 4store+virtuoso; add graphdb (BIND branch, [query_builder.rb:77](lib/goo/sparql/query_builder.rb#L77)) and allegrograph (FILTER branch) include-cases. |
| **T-13** | `update` with nil graph under caching (M-2) | Assert current behavior (no raise, no invalidate) so the divergence from the fork is a conscious lock, not a silent drift. |

**Structural gap:** `Goo::SPARQL::Cache` and the form-urlencoded transport (`make_post_request`) have
**no isolated unit tests** — both are only reached through `test_cache.rb`, which needs a live
triplestore *and* redis. The `cache.rb` 90.8% line coverage (§4) therefore overstates confidence:
the lines run, but the edge branches have no assertions and none of it runs in CI without a backend.
T-14…T-24 close that; most are **[pure]** (no deps) or **[redis]** (a redis or fake, no triplestore),
so they'd give the load-bearing cache a fast, backend-free unit suite.

| ID | Gap | Suggested test |
|---|---|---|
| **T-14** | **[redis]** `Cache` get-hit / get-miss / store round-trip not unit-tested (only via full stack) | Against a redis (or fake): `store` then `get` returns an equal value and creates the `sadd` graph-set members; missing key → nil. The basic contract. |
| **T-15** | **[redis]** `Cache` **inert when redis is nil** (the `use_cache=false` production "off" path) | With `redis_cache=nil`: `get`→nil, `store`/`invalidate` are no-ops and raise nothing. |
| **T-16** | **[redis]** `Cache#invalidate` mechanics | scalar vs Array of graphs; `sparql:graph:` prefix normalization ([cache.rb:117](lib/goo/sparql/cache.rb#L117)); deletes the set; a subsequent read over that graph is treated stale. |
| **T-17** | **[pure]** Marshal round-trip fidelity | An `RDF::Query::Solutions` survives `Marshal.dump`/`load` with `variable_names` intact (that is what gets cached). |
| **T-18** | **[pure]** `make_post_request` form-urlencoding (transport re-home, fork item #4) | Build (don't send) the request for a client with `Content-Type: application/x-www-form-urlencoded`; assert the body is form-encoded under the `@op` key and the header is set. |
| **T-19** | **[pure]** `QuerySerialization` CONSTRUCT form ([query_extensions.rb:97-99](lib/goo/sparql/ext/query_extensions.rb#L97)) | Golden string for a CONSTRUCT query; currently uncovered. |
| **T-20** | **[pure]** `QuerySerialization` nested where-unions ([query_extensions.rb:115-119](lib/goo/sparql/ext/query_extensions.rb#L115)) | Golden string for a query with `options[:unions]` (the `WHERE { P { u0 } UNION { u1 } }` nesting); uncovered. |
| **T-21** | **[pure]** `QuerySerialization` order_by variants + arg validation ([query_extensions.rb:131-162](lib/goo/sparql/ext/query_extensions.rb#L131)) | Golden strings for `order_by` given a Hash, `[var,:desc]` Array, bare Symbol, and String; assert the `ArgumentError` raises for malformed input. Also cover `group_by` and `prefixes`. |
| **T-22** | **[pure]** `UnionWithBind#empty?` (line 30) and the `a`-for-`rdf:type` path in `serialize_triples` | `empty?` true for nil/empty binding, false otherwise; a triple whose predicate is `RDF.type` renders as `a`. |
| **T-23** | **[redis]** `QueryLogger` failure + trim | redis error during `record` degrades to a file warn and never raises ([query_logger.rb:200-204](lib/goo/sparql/query_logger.rb#L200), line 203 uncovered); `trim` evicts oldest past `max_logs`; `recent(seconds)` returns only in-window entries newest-first. |
| **T-24** | **[redis]** Config wiring: `use_cache=` toggle + kill-switch authority (D5) | `Goo.use_cache=true/false` sets/nils `redis_cache` on all three clients; after the D5 fix, `add_redis_backend` *before* `add_sparql_backend` must not leave caching silently on. |

---

## 4. Code coverage (de-fork / observability files)

Merged across the offline characterization tests + live `test_cache.rb`, `test_query_logger.rb`,
`test_query_count.rb` (4store + redis; SimpleCov, max-per-line across run groups). 52 tests, 117
assertions, 0 failures.

| File | Line coverage | Notable uncovered |
|---|---|---|
| [lib/goo/sparql/cache.rb](lib/goo/sparql/cache.rb) | **90.8%** (59/65) | `reload_cache` path (39-40); invalidate retry/`sleep` rescue (120-123). |
| [lib/goo/sparql/query_logger.rb](lib/goo/sparql/query_logger.rb) | **98.9%** (94/95) | only the `with_redis` rescue (203). |
| [lib/goo/sparql/ext/virtuoso_compat.rb](lib/goo/sparql/ext/virtuoso_compat.rb) | **100%** (22/22) | — |
| [lib/goo/sparql/ext/query_extensions.rb](lib/goo/sparql/ext/query_extensions.rb) | **71.3%** (62/87) | `UnionWithBind#empty?` (30); `QuerySerialization` construct branch (97-99), nested-UNION (115-119), order_by Hash/Array/Symbol/String branches (131-162). The order_by/union shapes are under-locked. |
| [lib/goo/sparql/query_builder.rb](lib/goo/sparql/query_builder.rb) | **79.8%** (206/258) | aggregate vars, nested order_by remapping (308-323), regex/bound filter ops. Mostly pre-existing logic. |
| [lib/goo/sparql/client.rb](lib/goo/sparql/client.rb) | **55.1%** (119/216) | The **de-fork-relevant methods are covered** (`#query`/`#update`/`#make_post_request`/`#response`, ~lines 32-89). The uncovered remainder (99-369) is the pre-existing bulk-load machinery (`bnodes_filter_file`, `append_*`, `status`, `params_for_backend`) not touched by this work and not exercised by these tests. |

**Reading:** the *new caching + logging surface* is well covered (cache 91%, logger 99%, quirks
100%) except the edge branches called out in §3. The low client.rb number is an artifact of legacy
data-load code dominating the file, not of the de-fork code being untested. The `query_extensions`
gap is real — the golden suite should add the construct/nested-union/order-by shapes.

*Reproduce:*
```
cd <goo>; COVERAGE=true bundle exec ruby -Itest -Ilib -e \
  '%w[test_sparql_query_characterization test_sparql_write_characterization \
      test_cache test_query_logger test_query_count].each{|f| require File.expand_path("test/#{f}.rb")}'
```
(Note: `ruby a.rb b.rb` runs only `a.rb`; use the require-loader above or rake to load all files —
this caught an undercount during review.)

---

## 5. Recommended benchmark plan

There is **no** performance comparison between the fork and vanilla+goo. For critical infra,
reassure on three axes, preferring **deterministic** metrics (stable across laptop vs CI) over wall
time.

**Harness.** A `test/bench/` script that, for a fixed corpus and a fixed list of representative
queries (simple SELECT, include-direct, include-inverse, nested join, count, paged), runs each
shape N times under: (a) caching off, (b) cold cache, (c) warm cache; against both gem versions
(swap the Gemfile pin). Use `benchmark-ips` for throughput and `memory_profiler`/`ObjectSpace` for
allocations.

**Measure (deterministic first):**
1. **Generated SPARQL equality** — already the strongest signal; fold the §3 A/B (T-11) in here.
2. **Allocations per query** for `select...to_s` and for a full `#query` cold path
   (`memory_profiler`); compare fork vs goo. Stable, machine-independent. The `QuerySerialization`
   wholesale `to_s` and the `UnionWithBind` object should be checked for allocation regressions.
3. **Store-bound query count** per high-level operation — already instrumented via
   `Goo.count_sparql_queries` ([goo.rb:249](lib/goo.rb#L249)) and asserted in
   [test_query_count.rb](test/test_query_count.rb). Add a baseline assertion for the common OLD
   operations so a fan-out regression trips CI.
4. **Cache op micro-bench** — `get` hit, `get` miss, `store`, `invalidate(graph)` in isolation
   against a local redis (ips + allocations). Confirms the read-through seam isn't adding latency
   vs the fork's inline path.

**Wall time (secondary, report with variance):** median + p95 of `#query` warm-hit vs cold-miss vs
caching-off, same machine, same redis, many iterations.

**Pass bar:** allocations and query counts within noise (±, define) of the fork; generated SPARQL
identical; warm-hit latency ≤ cold-miss by a wide margin (sanity that caching helps).

---

## 6. Caching ↔ observability separation, kill-switch & rollback

**Separation: clean.** Verified on `chore/sparql-client-defork`: its `client.rb#query` is a
6-line cache-only method with **no** logger references, and `sparql.rb` does **not** require
`query_logger`. The observability branch adds the `@query_logger.around(...)` wrapping and the
require. So **caching can run with observability code entirely absent** (ship the caching branch
alone) or **present-but-off** (observability branch with logging disabled → `around` is
`return yield unless @enabled`, [query_logger.rb:50](lib/goo/sparql/query_logger.rb#L50)). The
key *names* are disjoint (`sparql:*` cache vs `goo:qlog:*` logs), so they don't collide — but they
currently share one Redis instance under `allkeys-lru` (D6), which is global and ignores prefixes,
so log volume *can* evict cache entries and vice versa. ("Disjoint keyspaces" prevents *collisions*,
not *cross-eviction*.) **DECIDED (D6a): move cache and logs onto separate Redis instances** — the
real isolation boundary, since `maxmemory`/eviction is per-instance (separate DBs would not fix it);
needs the small goo wiring change noted in D6a/§7.2. Caveat L-1: "off" is *near*-zero, not literally
zero, on the observability branch.

**Caching kill-switch: present, runtime, but with an ordering footgun.**
- `Goo.use_cache = false` re-runs `set_sparql_cache`, which nils `redis_cache` on all three clients
  ([goo.rb:286-300](lib/goo.rb#L286)). The `Cache` is then inert (`get`→nil, `store`/`invalidate`
  no-ops). So caching is **disable-able at runtime without a deploy**, provided you can call the
  setter (a console/initializer toggle) — good rollback posture for a caching bug.
- **Footgun (inherited, not a regression):** `add_sparql_backend` passes `redis_cache:
  @@redis_client` at construction ([goo.rb:123-140](lib/goo.rb#L123)) and does **not** consult
  `@@use_cache`. The flag is only honored by `set_sparql_cache`, which runs on `use_cache=` and
  `add_redis_backend`. In the **standard** config order (`add_sparql_backend` *before*
  `add_redis_backend` — confirmed in `config.rb` `connect_goo`), `@@redis_client` is nil at
  construction and `set_sparql_cache` later nils them with `use_cache` defaulting false → so goo's
  *bundled* default lands cache-off. **But that default is not what runs:** the consuming apps
  (ontologies_api/OntoPortal) call `Goo.use_cache=true` in their prod/stage configs, so all real
  environments are cache-ON via the runtime setter (which *does* honor the flag correctly). The
  footgun is narrower but still real: if a host ever calls `add_redis_backend` *before*
  `add_sparql_backend` and never touches `use_cache`, the clients are built with a live redis handle
  and nothing nils them → **caching silently ON regardless of `use_cache`** (and conversely, the
  flag can't be trusted as the single source of truth). Recommend `set_sparql_cache` be called at
  the end of `add_sparql_backend` (or `add_sparql_backend` respect `@@use_cache`) so the flag is
  authoritative irrespective of call order.

**Rollback story:** strong. Three levels: (1) `Goo.use_cache=false` at runtime; (2) deploy the
caching branch without observability; (3) revert the Gemfile pin back to the fork — the bolt-ons
are additive and the fork is still present locally. Recommend an env-driven default
(`OP_USE_CACHE`) so production can flip caching without code, mirroring `OP_QUERIES_LOGGING`
([config.rb](lib/goo/config/config.rb)).

---

## 7. Suggested additional review dimensions

1. **Marshal trust boundary (security, inherited).** `Marshal.load` on cache entries
   ([cache.rb:53](lib/goo/sparql/cache.rb#L53)) is an RCE sink if the Redis instance is writable by
   an untrusted party or shared with other apps. The fork did this too, so it's **inherited, not a
   regression** — but the de-fork is the moment to record the assumption "Redis is a trusted,
   single-tenant, network-isolated store" in the proposal and verify deployment matches (auth,
   bind address, separate DB index from the logger). Cache-key construction is MD5 of query text +
   sorted graphs ([cache.rb:70-76](lib/goo/sparql/cache.rb#L70)); collision risk is negligible and
   keys aren't attacker-controlled in normal operation.
2. **Memory footprint & eviction (D6 — `maxmemory` + `allkeys-lru`, in use).** The bound is in place
   (the code has no TTL — the fork's `expire` is commented out, preserved as commented in goo,
   [cache.rb:101-107](lib/goo/sparql/cache.rb#L101) — but the Redis-level policy covers it). Three
   properties to keep in mind, given the cache is load-bearing:
   - **Correctness under LRU is fine — because of the per-read `SISMEMBER`.** If LRU evicts a
     `sparql:graph:<g>` set, the next read's `sismember` returns false → the entry is dropped and
     recomputed (a conservative miss), never a stale hit ([cache.rb:46-51](lib/goo/sparql/cache.rb#L46)).
     This is *the* reason the §2A "drop SISMEMBER, evict at write-time" optimization is unsafe here:
     without the check, an entry orphaned by an LRU-evicted set would be served stale forever. Keep
     the check (pipelining `GET`+`SISMEMBER` is still safe and worthwhile; dropping it is not).
   - **Cache and query-log share one Redis today, so LRU evicts them against each other — DECIDED:
     split onto separate instances (D6a).** Both the cache and `QueryLogger` are wired to the same
     `@@redis_client` ([goo.rb:276/289](lib/goo.rb#L276)), and `allkeys-lru` is global — it ignores
     key prefixes *and* database numbers, so log volume can evict cache entries and vice versa (this
     is why the "disjoint keyspaces ⇒ no interference" note in §6 was wrong). **Separate DBs on one
     instance would not fix it** — `maxmemory`/eviction is per-instance — so the fix is separate
     *instances*. Implementation: add a distinct log-Redis handle (a second `add_redis_backend`-style
     endpoint) and point `QueryLogger.new(redis:)` ([goo.rb:276](lib/goo.rb#L276)) at it, leaving the
     cache on the primary `@@redis_client`; consuming apps configure two endpoints.
   - **Size `maxmemory` generously** — aggressive eviction of hot tree keys turns straight into a
     backend-load spike (§2A).
3. **Connection/timeout posture.** Clients set `read_timeout: 10000` ([goo.rb:126](lib/goo.rb#L126))
   and `Redis.new(timeout: 300)` ([goo.rb:193](lib/goo.rb#L193)) — a 300 s Redis timeout combined
   with the M-5 `sleep(5)×3` means a Redis stall can tie up a request thread for minutes, and a 10 s
   store timeout × the whole thread pool is an app-wide stall during a backend brownout. Both
   timeouts are also what let the §2A breakers (Redis *and* SPARQL endpoint) detect failure *fast*
   instead of hanging — a breaker can't trip quicker than the call's own timeout. Tighten both, and
   pair the store timeout with a concurrency bulkhead.
4. **Monitoring hooks.** `QueryLogger#cache_hit_rate` ([query_logger.rb:67](lib/goo/sparql/query_logger.rb#L67))
   and the `ncbo-sparql-query-count` response header ([goo.rb:578](lib/goo.rb#L578)) are good
   building blocks — wire them to whatever production uses (statsd/Prometheus) so the cache's
   effectiveness and any query-count regressions are observable post-rollout.
5. **Gem-pin hygiene.** `Gemfile` pins `sparql-client '3.2.2'` (exact). Good for reproducibility;
   add a comment that the bolt-ons assume 3.2.2's `to_s`/`make_post_request`/`parse_*` internals
   (M-3) so a bump triggers re-review.
6. **Downstream API contract test.** ontologies_api/ncbo_cron/annotator/OLD consume `Goo.logger.*`,
   `Goo.sparql_query_client`, `cache.invalidate`, and the write helpers. A thin contract test in
   goo asserting those method signatures exist would catch L-2/L-3 breakage before downstream
   CI does.

---

## 8. Prioritized "what to do before this can land"

**UPDATE (D13 — sequencing revision):** item 1 below is **no longer a de-fork merge gate** — it is
**Ship 2**, an immediate fast-follow on its own branch with its own review and failure-injection
tests (T-6). The de-fork (Ship 1) gates on items 2–7: the fidelity / kill-switch / test set that
keeps it a verifiable, parity-pure port. Rationale in D13.

**Must (caching is already ON in prod/stage, so these gate *shipping the de-fork*, not "enabling caching"):**
1. **[Ship 2 per D13 — no longer a de-fork merge gate] H-3 / §2A — Implement the dependency-down policy** (top item — caching is load-bearing *and
   already on in every real environment*, so a Redis outage is a live failure mode today). **Policy
   DECIDED (D1/D2)** — a **circuit breaker + bulkhead on *both* dependencies**; what remains is
   implementation:
   - **Redis (D1)** — **fail fast → `503` + alert** when the breaker opens (no fall-through). Route
     `Cache#get`/`#store` failures through it. Replace `sleep(5)×3` with **capped exponential backoff
     + jitter (D4)** and **restore invalidation-failure logging + a metric** (the fork's `puts` was
     dropped; there's zero signal today) — then re-evaluate don't-retry-inline once metrics exist.
   - **SPARQL endpoint (D2)** — a backend breaker + concurrency bulkhead on **reads + writes** so a
     slow/down store sheds load (`503`/`504`) instead of exhausting the request-thread pool. Must be
     **client-side** (latency/timeout/5xx-driven) — *not* an extension of the existing
     `status`/`status_based_sleep_time` 4store status-page scraper
     ([client.rb:98-118/317-338](lib/goo/sparql/client.rb#L98)), which is 4store-only, write-only,
     and dormant. The hot read path has no protection today. Tighten `read_timeout`/Redis `timeout`
     (§7.3) so failures register fast. Prefer a vetted lib (Semian/Stoplight/Circuitbox).

   Add T-6 (dependency-down behavior + breaker-state for both Redis and the store).
2. **H-1 / T-7 (D3 DECIDED: match the fork)** — gate `store` to JSON SELECT/ASK solutions so
   CONSTRUCT/DESCRIBE/graph results aren't cached; add T-7 to lock it. Behavior-preserving for goo's
   own queries (no CONSTRUCT/DESCRIBE in core). Follow-up: confirm no downstream raw-CONSTRUCT caller.
3. **Kill-switch hardening (§6 / D5 DECIDED)** — keep goo default OFF, make `@@use_cache`
   authoritative regardless of `add_redis_backend`/`add_sparql_backend` order, add the `OP_USE_CACHE`
   env opt-in in the consuming app.
4. **D8 (DECIDED: restore the fork's raise)** — raise "Unsupported cacheable query" when caching is
   on and an update has no graph; lock with T-13. (Follow-up: confirm no legitimate ungraphed-update
   caller.)

**Should (before merge):**
5. **H-2 / T-11** — Prove parity once: A/B `to_s` diff vs the fork for the §3 shapes; record it.
   (**DONE:** recorded in docs/sparql-defork-ab-record.md — fork-side run at `90c3f25` green
   against `ncbo/sparql-client@2ac20b2`, goldens drift-checked baseline→HEAD, reproduce steps
   included.)
6. **Add an isolated `Cache` unit suite** (structural gap — the load-bearing class has no
   backend-free tests today). Start with the five highest-value: T-4 (stale eviction — the
   `allkeys-lru` fail-safe), T-6 (redis-down degradation), T-5 (key-format, pure), T-8 (empty
   binding, pure), T-7 (cache scope). Then the rest of the pure/[redis] set: T-1/T-2/T-3/T-14/T-15/
   T-16/T-17 (cache), T-18 (transport), T-19–T-22 (serialization shapes), T-23 (logger), T-24
   (config toggle/footgun), T-13 (nil-graph update).
7. **M-1 wording** — soften the "fixes the race" claim to "narrows the window"; document the
   residual.

**Fast-follow (post-ship, per decisions):**
8. **M-4 / D7 — `ConnectionPool`-wrapped Redis** (deferred). Add shortly after ship. **Gate:** if the
   app servers are *threaded* (Puma threads>1), do this **before** relying on the breaker — the
   single shared connection under ~2000 ops/request is unsafe. If process-per-worker single-threaded,
   lower urgency. Confirm the threading model.
9. **D3 follow-up** — confirm no downstream caller (OLD/cron/annotator) issues a raw CONSTRUCT through
   the query client; **D8 follow-up** — confirm no legitimate ungraphed-cacheable-update caller;
   **D4 follow-up** — once the invalidation-failure metric exists, re-evaluate don't-retry-inline.

**Nice (follow-up):**
10. **M-3** — guard test for vanilla `to_s` drift; start upstreaming the multiple-FROM + nested-UNION
    deltas so the override can eventually be deleted.
11. **N-1** — commit or remove the referenced `docs/sparql-client-defork-proposal.md`.
12. **D6a / §7.2 — put cache and query-log on separate Redis *instances*** (decided). Requires a goo
    wiring change: today both use one `@@redis_client` ([goo.rb:193/276/289](lib/goo.rb#L193)); add a
    distinct log-Redis handle and point `QueryLogger.new(redis:)` at it. (Separate DBs won't do —
    `maxmemory`/`allkeys-lru` is per-instance.) Size the cache `maxmemory` generously (§2A).
13. **L-2/L-3 / §7.6** — downstream API contract test for `Goo.logger.*` and the public client
    surface.
14. **Benchmark harness (§5)** — allocations + query-count + cache-op micro-bench vs the fork.
15. **§2A — Kill the `SISMEMBER` storm the *safe* way**: pipeline `GET`+`SISMEMBER` into one RTT.
    Do **not** drop the `SISMEMBER` / move to write-time-only eviction under `allkeys-lru` (D6) — it
    reintroduces stale reads when LRU evicts a graph-set.
16. **§2A — Tree N+1, phase 2: attribute the residual Redis amplification.** Phase 1 landed
    (ncbo/ontologies_linked_data#297 batched `hasChildren`; store-bound SPARQL down) but **Redis
    ops stayed high post-deploy** — the dominant cached reads are unattributed. Reproduce one tree
    request (large ontology, staging) with `OP_QUERIES_LOGGING=1`, rank the `cached: true` entries
    from `Goo.query_logger.all`, then batch the top offenders (candidates: `traverse_path_to_root`
    per-ancestor `bring`, roots load, per-node attribute loads). Only this makes the system safe to
    run with a degraded cache — the durable fix.
17. **Per-request cache-hit visibility (instrument for #16).** `ncbo-sparql-query-count` counts
    store-bound queries only and `tick_cache_hit` is a global tally; add a thread-local per-request
    hit counter + an `ncbo-sparql-cache-hits` response header so per-endpoint Redis amplification
    (≈ hits×2 + misses) is visible on every response without NewRelic. ~10 lines on the existing
    client seam.

---

*Reviewed against vanilla `sparql-client` 3.2.2, fork `ncbo/sparql-client@remove-dead-unions-with-bind`
(version 3.2.2), goo branches `chore/sparql-client-defork` and `feat/sparql-observability`.
Tests run on ruby 3.2.10, 4store @ localhost:9000, redis @ localhost:6379.*
