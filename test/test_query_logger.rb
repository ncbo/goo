require_relative 'test_case'
require_relative 'models'

# Tests for Goo::SPARQL::QueryLogger (lib/goo/sparql/query_logger.rb) and its wiring into
# Goo::SPARQL::Client. The storage/query API is exercised directly against the live redis
# (Goo.redis_client) -- no triplestore needed -- and a small integration check confirms that an
# enabled logger records what goo actually sends.
class TestQueryLogger < Goo::TestCase

  def before_all
    GooTestData.create_test_case_data
  end

  def after_all
    GooTestData.delete_test_case_data
    Goo.enable_query_logging(enabled: false)
  end

  def setup
    @redis = Goo.redis_client
    clear_qlog
  end

  def teardown
    Goo.enable_query_logging(enabled: false)
    clear_qlog
  end

  def clear_qlog
    keys = @redis.keys("#{Goo::SPARQL::QueryLogger::KEY}:*")
    @redis.del(*keys) unless keys.empty?
  end

  # --- disabled logger is a passthrough --------------------------------------------------

  def test_disabled_logger_is_passthrough
    logger = Goo::SPARQL::QueryLogger.new # no redis, no file
    refute logger.enabled
    sentinel = Object.new
    assert_same sentinel, logger.around("SELECT *", cached: false) { sentinel }
    assert_empty logger.all
    assert_equal 0, @redis.keys("#{Goo::SPARQL::QueryLogger::KEY}:*").length
  end

  # --- recording: query text, timing, rows, cached --------------------------------------

  def test_around_records_entry
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis)
    result = logger.around("SELECT ?s WHERE { ?s ?p ?o }", cached: false, user: "alice") do
      [1, 2, 3] # stands in for a solutions array (responds to :size)
    end
    assert_equal [1, 2, 3], result

    logs = logger.all
    assert_equal 1, logs.length
    entry = logs.first
    assert_equal "SELECT ?s WHERE { ?s ?p ?o }", entry["query"]
    refute entry["cached"]
    assert_equal 3, entry["rows"]
    assert_equal "alice", entry["user"]
    refute_nil entry["execution_time"]
    refute_nil entry["timestamp"]
  end

  def test_cached_flag_recorded
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis)
    logger.around("SELECT 1", cached: true) { "x" }
    assert logger.all.first["cached"]
  end

  # --- time-window queries ---------------------------------------------------------------

  def test_recent_window
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis)
    logger.around("SELECT now", cached: false) { [] }
    assert_equal 1, logger.recent(60).length      # inside the window
    assert_empty logger.recent(-1)                 # window in the past -> nothing
  end

  def test_all_is_newest_first
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis)
    logger.around("q1", cached: false) { [] }
    logger.around("q2", cached: false) { [] }
    assert_equal %w[q2 q1], logger.all.map { |e| e["query"] }
  end

  # --- ring-buffer trim ------------------------------------------------------------------

  def test_trim_enforces_max_logs
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis, max_logs: 5)
    20.times { |i| logger.around("q#{i}", cached: false) { [] } }
    assert_equal 5, logger.all(limit: 100).length
    # the survivors are the newest
    assert_equal "q19", logger.all(limit: 100).first["query"]
  end

  # --- keyspace isolation from the cache -------------------------------------------------

  def test_only_touches_qlog_keyspace
    # Shared redis may already hold cache (sparql:*) keys from other suites; assert logging adds
    # NONE of its own -- only goo:qlog:* keys -- rather than that none exist at all.
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis)
    before = @redis.keys("sparql:*").length
    logger.around("SELECT iso", cached: false) { [] }
    assert_equal before, @redis.keys("sparql:*").length,
                 "logging must not write cache (sparql:*) keys"
    refute_empty @redis.keys("#{Goo::SPARQL::QueryLogger::KEY}:*")
  end

  def test_clear
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis)
    logger.around("SELECT clr", cached: false) { [] }
    refute_empty logger.all
    logger.clear
    assert_empty logger.all
  end

  # --- cache hit rate --------------------------------------------------------------------

  def test_cache_hit_rate_empty
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis)
    assert_equal({ hits: 0, misses: 0, total: 0, rate: 0.0 }, logger.cache_hit_rate)
  end

  def test_cache_hit_rate_counts_only_eligible
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis)
    3.times { logger.around("q", cached: true,  count_cache: true) { [] } }   # hits
    1.times { logger.around("q", cached: false, count_cache: true) { [] } }   # miss
    # caching-off reads and writes pass count_cache:false -> must NOT move the ratio
    5.times { logger.around("q", cached: false, count_cache: false) { [] } }
    logger.around("update", cached: false) { [] }

    stats = logger.cache_hit_rate
    assert_equal 3, stats[:hits]
    assert_equal 1, stats[:misses]
    assert_equal 4, stats[:total]
    assert_in_delta 0.75, stats[:rate], 0.0001
  end

  def test_cache_hit_rate_survives_trim
    # per-query logs roll off the ring buffer, but the lifetime tally must not.
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis, max_logs: 5)
    20.times { logger.around("q", cached: true, count_cache: true) { [] } }
    assert_equal 5, logger.all(limit: 100).length      # logs trimmed
    assert_equal 20, logger.cache_hit_rate[:hits]      # tally intact
  end

  def test_clear_resets_hit_rate
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis)
    logger.around("q", cached: true, count_cache: true) { [] }
    refute_equal 0, logger.cache_hit_rate[:total]
    logger.clear
    assert_equal 0, logger.cache_hit_rate[:total]
  end

  # --- backward-compat shim (AgroPortal Admin::LoggingController) ------------------------

  def test_get_logs_returns_all_uncapped
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis, max_logs: 1000)
    150.times { |i| logger.around("q#{i}", cached: false) { [] } }
    # get_logs must NOT cap at all's default 100 -- the controller paginates the full set.
    assert_equal 150, logger.get_logs.length
    assert_equal "q149", logger.get_logs.first["query"]
  end

  def test_queries_last_n_seconds_aliases_recent
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis)
    logger.around("q", cached: false) { [] }
    assert_equal 1, logger.queries_last_n_seconds(60).length
    assert_empty logger.queries_last_n_seconds(-1)
  end

  def test_users_query_count
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis)
    3.times { logger.around("q", cached: false, user: "alice") { [] } }
    1.times { logger.around("q", cached: false, user: "bob") { [] } }
    logger.around("q", cached: false) { [] } # nil user -> not counted
    counts = logger.users_query_count
    assert_equal({ "alice" => 3, "bob" => 1 }, counts.to_h { |c| [c[:user], c[:count]] })
    assert_equal "alice", counts.first[:user] # sorted by count desc
  end

  def test_info_records_free_text_entry
    logger = Goo::SPARQL::QueryLogger.new(redis: @redis)
    logger.info("Test log")
    assert(logger.get_logs.any? { |e| e["query"].include?("Test log") })
  end

  def test_goo_logger_aliases_query_logger
    Goo.enable_query_logging(enabled: true)
    assert_same Goo.query_logger, Goo.logger
  end

  # --- integration: enabling logging records what goo sends ------------------------------

  def test_enable_query_logging_records_real_query
    Goo.enable_query_logging(enabled: true)
    assert Goo.query_logger.enabled
    University.where.include(:name).all
    logs = Goo.query_logger.all
    refute_empty logs, "an enabled logger should record the SELECT goo issued"
    assert(logs.any? { |e| e["query"].to_s.include?("SELECT") })
    refute_nil logs.first["execution_time"]
  end

  # --- D6a: the log Redis is separate from the cache Redis -------------------------------
  # maxmemory/allkeys-lru is per-INSTANCE and ignores key prefixes and db numbers, so disjoint
  # goo:qlog:* vs sparql:* keys stop collisions but not cross-eviction. The log therefore gets
  # its own handle, falling back to the cache Redis only when none is configured.

  def test_log_redis_defaults_to_the_cache_redis
    assert_same Goo.redis_client, Goo.log_redis_client,
                "unconfigured, the log must fall back to the cache Redis"
  end

  def test_add_log_redis_backend_points_the_logger_at_its_own_instance
    # Same server here (the suite has one Redis), but a distinct client object -- enough to prove
    # the logger is wired to log_redis_client rather than @@redis_client.
    Goo.add_log_redis_backend(host: Goo.settings.goo_redis_host, port: Goo.settings.goo_redis_port)
    refute_same Goo.redis_client, Goo.log_redis_client
    Goo.enable_query_logging(enabled: true)
    assert_same Goo.log_redis_client, Goo.query_logger.redis,
                "the logger must write to the log Redis, not the cache Redis"
  ensure
    reset_log_redis_backend
  end

  def test_adding_the_cache_redis_later_keeps_the_log_handle
    Goo.add_log_redis_backend(host: Goo.settings.goo_redis_host, port: Goo.settings.goo_redis_port)
    dedicated = Goo.log_redis_client
    Goo.add_redis_backend(host: Goo.settings.goo_redis_host, port: Goo.settings.goo_redis_port)
    assert_same dedicated, Goo.log_redis_client,
                "configuring the cache Redis must not steal the log's dedicated handle"
  ensure
    reset_log_redis_backend
  end

  # Drop the dedicated handle so later tests see the default fallback again.
  def reset_log_redis_backend
    Goo.class_variable_set(:@@log_redis_client, nil)
    Goo.set_query_logging
  end
end
