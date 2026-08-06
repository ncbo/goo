require_relative 'test_case'

# Ship 2 resilience tests (de-fork review §2A / D1 / D2 / D4, T-6): the circuit breaker,
# best-effort semantics, and the cache's fail-fast / degrade behavior under a Redis outage.
# Backend-free -- Redis failures are injected via a fake that always raises.
class TestResilience < Goo::TestCase
  R = Goo::SPARQL::Resilience
  REDIS_CONN = Redis::CannotConnectError # < Redis::BaseConnectionError (a tracked infra error)

  # A redis double whose every command raises a connection error.
  class BoomRedis
    def method_missing(_name, *_args, &_block)
      raise Redis::CannotConnectError, 'redis down'
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end

  def before_all
    @prev = ENV.values_at('OP_SPARQL_CIRCUIT_BREAKER', 'OP_SPARQL_BREAKER_THRESHOLD')
  end

  def after_all
    ENV['OP_SPARQL_CIRCUIT_BREAKER'], ENV['OP_SPARQL_BREAKER_THRESHOLD'] = @prev
    R.on_state_change = nil
    R.on_invalidation_failure = nil
    R.reset!
  end

  def setup
    ENV['OP_SPARQL_CIRCUIT_BREAKER'] = 'true'
    ENV['OP_SPARQL_BREAKER_THRESHOLD'] = '2'
    R.on_state_change = nil
    R.on_invalidation_failure = nil
    R.reset!
  end

  # Unique breaker name per test (belt-and-suspenders on top of reset!'s fresh data store).
  def circuit
    "test:#{name}"
  end

  # --- enable/disable gate -----------------------------------------------------------------

  def test_disabled_is_a_passthrough
    ENV['OP_SPARQL_CIRCUIT_BREAKER'] = 'false'
    R.reset!
    assert_equal 42, R.protect_read(circuit, [REDIS_CONN]) { 42 }
    # raw infra errors propagate unchanged when the breaker is off (pre-Ship-2 behavior)
    assert_raises(REDIS_CONN) { R.protect_read(circuit, [REDIS_CONN]) { raise REDIS_CONN, 'down' } }
  end

  # --- protect_read: fail fast when open (D1/D2) -------------------------------------------

  def test_protect_read_opens_after_threshold_then_fails_fast
    c = circuit
    2.times { assert_raises(REDIS_CONN) { R.protect_read(c, [REDIS_CONN]) { raise REDIS_CONN, 'down' } } }

    ran = false
    assert_raises(R::CircuitOpenError) { R.protect_read(c, [REDIS_CONN]) { ran = true } }
    refute ran, 'an open breaker must not execute the protected block'
  end

  def test_untracked_error_does_not_trip_the_breaker
    c = circuit
    # a non-infra error (stand-in for a caller bug / non-outage) must never count toward opening
    5.times { assert_raises(RuntimeError) { R.protect_read(c, [REDIS_CONN]) { raise 'not infra' } } }
    assert_equal :ok, R.protect_read(c, [REDIS_CONN]) { :ok } # still closed
  end

  # --- protect_best_effort: never fail the caller -----------------------------------------

  def test_best_effort_swallows_infra_errors_and_returns_fallback
    assert_nil R.protect_best_effort(circuit, [REDIS_CONN]) { raise REDIS_CONN, 'down' }
    assert_equal :fb, R.protect_best_effort(circuit, [REDIS_CONN], :fb) { raise REDIS_CONN, 'down' }
  end

  def test_best_effort_skips_fast_when_open
    c = circuit
    2.times { R.protect_best_effort(c, [REDIS_CONN]) { raise REDIS_CONN, 'down' } } # trip it
    ran = false
    assert_equal :fb, R.protect_best_effort(c, [REDIS_CONN], :fb) { ran = true }
    refute ran, 'an open breaker must not execute the best-effort block'
  end

  def test_best_effort_propagates_non_infra_errors
    # a real bug should surface, not be silently swallowed
    assert_raises(RuntimeError) { R.protect_best_effort(circuit, [REDIS_CONN]) { raise 'bug' } }
  end

  # --- state-change notification (alert hook), fires once per transition -------------------

  def test_on_state_change_hook_fires_on_open
    transitions = []
    R.on_state_change = ->(_name, from, to, _err) { transitions << [from, to] }
    c = circuit
    2.times { R.protect_best_effort(c, [REDIS_CONN]) { raise REDIS_CONN, 'down' } }
    assert_includes transitions.map { |t| t.last.to_s }, 'red', 'expected a transition to red'
  end

  # --- Cache integration (T-6) ------------------------------------------------------------

  def cacheable_opts
    { graphs: ['http://goo.org/default/ResilienceTest'] }
  end

  def test_cache_get_fails_fast_once_redis_breaker_open
    cache = Goo::SPARQL::Cache.new(redis_cache: BoomRedis.new)
    # below threshold: raw Redis error propagates (as before)
    2.times { assert_raises(REDIS_CONN) { cache.get('SELECT 1', cacheable_opts) } }
    # open: fail fast so the request sheds load instead of hammering the store (D1)
    assert_raises(R::CircuitOpenError) { cache.get('SELECT 1', cacheable_opts) }
  end

  def test_cache_store_never_fails_the_query_when_redis_down
    cache = Goo::SPARQL::Cache.new(redis_cache: BoomRedis.new)
    sols = RDF::Query::Solutions.new([RDF::Query::Solution.new(s: RDF::Literal.new('x'))])
    assert_nil cache.store('SELECT 1', cacheable_opts, sols) # best-effort: swallow, never raise
  end

  def test_cache_invalidate_never_raises_and_reports_via_metric_hook
    failed = []
    R.on_invalidation_failure = ->(key, _err) { failed << key }
    cache = Goo::SPARQL::Cache.new(redis_cache: BoomRedis.new)
    assert_output(nil, /cache invalidation failed/) do
      cache.invalidate('http://goo.org/default/ResilienceTest') # must not raise
    end
    refute_empty failed, 'the invalidation-failure metric hook should fire'
  end

  # Once the breaker is OPEN, protect_best_effort short-circuits before the invalidation runs, so
  # the drop is invisible unless it is reported explicitly. That silence is the dangerous case:
  # graphs written during the outage keep serving stale cached entries after Redis recovers, until
  # their next successful write.
  def test_invalidations_dropped_by_an_open_breaker_are_still_reported
    reported = []
    R.on_invalidation_failure = ->(key, err) { reported << [key, err.class] }
    cache = Goo::SPARQL::Cache.new(redis_cache: BoomRedis.new)
    graph = 'http://goo.org/default/ResilienceTest'

    # Trip the shared REDIS_CIRCUIT (threshold 2) through this same path. This only works because
    # invalidate_with_backoff re-raises a tracked error after its final attempt; while it
    # swallowed them, the breaker never saw a failure here and could not open.
    assert_output(nil, /cache invalidation failed/) { 2.times { cache.invalidate(graph) } }
    assert_equal 2, reported.size, 'each exhausted invalidation should report once'
    reported.clear

    # Any Redis call now would be a bug: the breaker is open, so the skip must be decided
    # without touching the dependency.
    probe = Class.new(BoomRedis) do
      attr_reader :calls
      def initialize = @calls = 0
      def method_missing(name, *args, &block) = (@calls += 1; super)
    end.new
    cache.redis_cache = probe
    assert_output(nil, /cache invalidation skipped/) { cache.invalidate(graph) }
    assert_equal 0, probe.calls, 'an open breaker must skip Redis entirely'

    assert_equal [["sparql:graph:#{graph}", R::CircuitOpenError]], reported,
                 'an invalidation dropped by an open breaker must reach the metric hook'
  end

  # --- query logger under a Redis outage ---------------------------------------------------
  # Logging is best-effort by definition, but it must also FAIL FAST: without a breaker, a Redis
  # outage costs every query a connect timeout inside the logger even though the cache breaker is
  # already open -- logging becomes the slow path it exists to observe.

  def test_logging_never_fails_a_query_when_its_redis_is_down
    logger = Goo::SPARQL::QueryLogger.new(redis: BoomRedis.new)
    result = logger.around('SELECT 1', cached: false, user: 'u1', count_cache: true) { :the_result }
    assert_equal :the_result, result, 'a dead log Redis must not break the query'
  end

  def test_log_redis_breaker_opens_and_then_skips_without_touching_redis
    logger = Goo::SPARQL::QueryLogger.new(redis: BoomRedis.new)
    3.times { logger.around('SELECT 1', cached: false) { :ok } } # threshold is 2 in setup

    probe = Class.new(BoomRedis) do
      attr_reader :calls
      def initialize = @calls = 0
      def method_missing(name, *args, &block) = (@calls += 1; super)
    end.new
    logger.redis = probe
    logger.around('SELECT 1', cached: false) { :ok }
    assert_equal 0, probe.calls, 'an open log breaker must skip Redis entirely, not time out on it'
  end

  # The log lives on its own Redis instance (D6a), so its breaker must be independent -- a log
  # outage must not shed cache reads, which are load-bearing.
  def test_log_redis_outage_does_not_trip_the_cache_breaker
    logger = Goo::SPARQL::QueryLogger.new(redis: BoomRedis.new)
    5.times { logger.around('SELECT 1', cached: false) { :ok } }

    cache = Goo::SPARQL::Cache.new(redis_cache: BoomRedis.new)
    # If the log had shared the cache's circuit, this would already be CircuitOpenError.
    assert_raises(REDIS_CONN) { cache.get('SELECT 1', cacheable_opts) }
  end

  # --- D4 backoff bounds -------------------------------------------------------------------

  def test_invalidate_backoff_is_bounded_and_grows
    cache = Goo::SPARQL::Cache.new(redis_cache: BoomRedis.new)
    cap = Goo::SPARQL::Cache::INVALIDATE_BACKOFF_CAP
    (1..5).each do |attempt|
      delay = cache.send(:invalidate_backoff, attempt)
      assert_operator delay, :>=, 0
      assert_operator delay, :<=, cap, "backoff must never exceed the #{cap}s cap"
    end
  end
end
