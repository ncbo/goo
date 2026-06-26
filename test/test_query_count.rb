require_relative 'test_case'
require_relative 'models'

# Tests for the SPARQL query counter (Goo.count_sparql_queries / Goo.tick_query_count) and the
# assert_*_sparql_queries helpers. The count is the deterministic, environment-independent signal
# for catching query-fan-out / N+1 regressions in goo (see lib/goo.rb).
class TestQueryCount < Goo::TestCase

  def before_all
    GooTestData.create_test_case_data
  end

  def after_all
    GooTestData.delete_test_case_data
  end

  def setup
    Goo.use_cache = false # cache hits don't tick; keep every read store-bound for deterministic counts
  end

  def test_no_queries_counts_zero
    assert_equal 0, Goo.count_sparql_queries { 1 + 1 }
  end

  def test_counts_store_bound_queries
    n = Goo.count_sparql_queries { University.where.all }
    assert n >= 1, "a .all should issue at least one store-bound SPARQL query"
  end

  def test_count_is_deterministic
    a = Goo.count_sparql_queries { University.where(name: "Stanford").include(:name).all }
    b = Goo.count_sparql_queries { University.where(name: "Stanford").include(:name).all }
    assert_equal a, b, "the same operation must issue the same number of queries"
  end

  def test_counts_are_additive
    u = Goo.count_sparql_queries { University.where.all }
    p = Goo.count_sparql_queries { Program.where.all }
    combined = Goo.count_sparql_queries do
      University.where.all
      Program.where.all
    end
    assert_equal u + p, combined
  end

  def test_nested_counts_roll_up
    inner = nil
    outer = Goo.count_sparql_queries do
      inner = Goo.count_sparql_queries { Program.where.all }
    end
    assert inner >= 1
    assert_equal inner, outer, "an inner block's queries must roll up into the enclosing counter"
  end

  def test_cache_hits_are_tallied_separately
    # Run-level tallies are armed by the runner (before_suites); snapshot deltas so we don't
    # depend on other tests. A repeated query with caching on should register a cache hit, not
    # another store-bound query.
    Goo.use_cache = true
    University.where.include(:name).all                 # warm the cache (store-bound miss)
    hits_before  = Goo.cache_hit_total.to_i
    store_before = Goo.query_count_total.to_i
    University.where.include(:name).all                 # identical -> cache hit
    assert Goo.cache_hit_total.to_i > hits_before, "a repeated cached query should tally a hit"
    assert_equal store_before, Goo.query_count_total.to_i, "a cache hit must not tally as store-bound"
  ensure
    Goo.use_cache = false
  end

  def test_tick_is_inert_outside_a_counting_context
    Thread.current[:goo_query_count] = nil
    Goo.tick_query_count # must be a harmless no-op, leaving no counter armed
    assert_nil Thread.current[:goo_query_count]
  end

  def test_assert_max_sparql_queries_passes_under_budget
    assert_max_sparql_queries(50) { University.where.include(:name).all }
  end

  def test_assert_max_sparql_queries_fails_over_budget
    assert_raises(Minitest::Assertion) do
      assert_max_sparql_queries(0) { University.where.all }
    end
  end

  def test_assert_sparql_queries_exact
    n = Goo.count_sparql_queries { University.where.all }
    assert_sparql_queries(n) { University.where.all }
  end

  # Regression: the queries_debug timing path called an undefined process_query_intl (renamed to
  # process_query_init), so enabling QUERIES_DEBUG raised NoMethodError on every query. Guard it.
  def test_queries_debug_timing_path_runs_and_sets_header
    Goo.queries_debug(true)
    app = ->(_env) { University.where.include(:name).all; [200, {}, ["ok"]] }
    status, headers, _ = Goo::Debug.new(app).call({})
    assert_equal 200, status
    refute_nil headers["ncbo-time-goo-process-query"], "debug timing header must be populated"
    assert_equal "1", headers["ncbo-sparql-query-count"]
  ensure
    Goo.queries_debug(false)
  end
end
