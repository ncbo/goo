# Recorded A/B: fork vs vanilla+goo SPARQL output (review D9 / H-2 / T-11)

**Claim being proven.** The de-fork (vanilla `sparql-client` 3.2.2 + goo bolt-ons) produces
byte-identical SPARQL wire output to the NCBO fork for the characterized query/write shapes.

**Method.** The characterization suites hard-code golden strings. The A/B is the fact that the
*same* golden strings pass against **both** implementations:

- **Fork side** — commit `90c3f25` ("Phase 0 SPARQL characterization baseline") pins
  `sparql-client` to the fork (`github.com/ncbo/sparql-client.git`, branch `development`,
  revision `2ac20b217bb7ad2b11305befe0ee77d75e44eac5`) and contains both characterization suites.
  At this commit goo still routes everything through the fork's DSL/serialization, so a green run
  here is the fork's own output matching the goldens.
- **Vanilla+goo side** — every subsequent commit (the union-with-bind extraction, the 3.2.2 swap,
  and the ncbo re-implementation branches `chore/sparql-client-defork` /
  `feat/sparql-observability`) keeps the same goldens green against vanilla+goo.

## Recorded run (2026-07-02)

Fork side, executed in a worktree at `90c3f25` (ruby 3.2.10; loaded gem verified as
`https://github.com/ncbo/sparql-client.git (at development@2ac20b2)`):

```
$ bundle exec ruby -Itest -Ilib -e 'require "./test/test_sparql_query_characterization";
                                    require "./test/test_sparql_write_characterization"'
17 tests, 21 assertions, 0 failures, 0 errors, 0 skips
```

Vanilla+goo side, same day, branch `chore/sparql-client-defork` (`dc4827c`), vanilla
`sparql-client 3.2.2` from rubygems — both suites green inside the full run
(`207 runs, 3182 assertions, 0 failures`), and again on `feat/sparql-observability`
(`236 tests, 3248 assertions, 0 failures`).

## Golden-string drift check

`git diff 90c3f25 chore/sparql-client-defork -- test/test_sparql_query_characterization.rb
test/test_sparql_write_characterization.rb` shows **additions only** — no pre-existing golden
string was modified between the fork-pinned baseline and the current branches. Therefore every
shape asserted at the baseline is proven fork-identical end-to-end.

Shapes added *after* the baseline are regression locks asserted against vanilla+goo only:

- `test_filter_and_include_order_filter_before_union_bind` — its constituents (FILTER form,
  BIND-branch OPTIONAL) are baseline shapes; the combined ordering was locked during migration.
- `test_include_direct_uses_bind_on_graphdb` / `test_include_direct_uses_filter_on_allegrograph`
  (review T-12) — golden strings identical to the baseline-proven 4store/virtuoso strings; they
  lock the backend→branch dispatch, not new output shapes.

## Reproduce

```bash
git worktree add /tmp/goo-ab 90c3f25 && cd /tmp/goo-ab
bundle check || bundle install          # resolves the fork pin from Gemfile.lock
GOO_BACKEND_NAME=4store GOO_HOST=localhost GOO_PORT=9000 REDIS_HOST=localhost \
  SEARCH_SERVER_URL=http://localhost:8983/solr \
  bundle exec ruby -Itest -Ilib -e 'require "./test/test_sparql_query_characterization";
                                    require "./test/test_sparql_write_characterization"'
# expect: 17 tests, 0 failures — against the FORK
```

(The suites are offline by construction — they intercept `SolutionMapper#map_each_solutions` —
but loading the test harness requires the docker fs stack (redis/solr) to be reachable.)

**Caveat.** This branch lineage (`feature/sparql-client-defork` in the alexskr checkout) is the
only place the fork-pinned baseline exists — the ncbo re-implementation lands tests+swap in a
single commit. Keep `90c3f25` reachable (this doc + a tag would suffice) until the de-fork has
shipped and soaked.
