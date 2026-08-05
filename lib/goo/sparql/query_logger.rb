require 'json'
require 'benchmark'
require 'securerandom'
require 'logger'
require 'time' # Time#iso8601, used by #record; do not rely on a dependency loading it for us

module Goo
  module SPARQL
    # Records what goo sends to the triple store: the generated SPARQL, how long it took, the
    # result size (rows + response bytes), whether it was a cache hit, and which user issued it.
    #
    # Goo-owned bolt-on, attached to Goo::SPARQL::Client like Goo::SPARQL::Cache. INERT until
    # enabled: with no redis and no file the #around helper is a passthrough, so logging adds
    # nothing but a nil check when off. Wired by Goo.set_query_logging.
    #
    # Storage (when a redis handle is given): each entry is JSON at goo:qlog:entry:<id>, indexed
    # in the sorted set goo:qlog:index scored by epoch-microseconds (µs keeps the score an exact
    # integer in a ZSET double and is fine enough that real queries never share a score, so
    # insertion order is preserved). That gives O(log N) time-window
    # queries (#recent) and a cheap ring-buffer trim -- no KEYS scans, no timestamp-from-key
    # regex, no Marshal-of-JSON (the rough edges of the old fork logger).
    #
    # The goo:qlog:* keyspace is disjoint from the cache's sparql:*, which prevents key
    # COLLISIONS but not cross-EVICTION: maxmemory/allkeys-lru is per-instance and ignores both
    # key prefixes and db numbers, so on a shared Redis log volume evicts cache entries and vice
    # versa. Hence Goo.add_log_redis_backend (de-fork review D6a) -- point the logger at its own
    # instance before enabling logging anywhere the cache is load-bearing. Sharing the cache
    # Redis is the fallback, and is only safe while logging is off.
    class QueryLogger
      KEY = 'goo:qlog'.freeze
      INDEX = "#{KEY}:index".freeze
      USERS = "#{KEY}:users".freeze       # ZSET user-id -> query count
      USER_EXPIRY = 2_592_000             # 30 days (matches the fork's per-user retention)
      CACHE_HITS = "#{KEY}:cache:hits".freeze     # lifetime read-through cache hit/miss tallies
      CACHE_MISSES = "#{KEY}:cache:misses".freeze

      attr_accessor :redis, :file_logger, :enabled

      # @param max_logs [Integer] ring-buffer depth. Must exceed the query count of whatever
      #   request you are trying to explain, or that request trims away its own entries: one
      #   class-tree request is ~2000 reads (review §2A), which the original 1000 could not hold.
      #   Tunable via Goo.enable_query_logging / OP_QUERIES_LOGGING_MAX_LOGS.
      # @param ttl [Integer] per-entry expiry in seconds; the index is bounded by max_logs.
      def initialize(redis: nil, file: nil, max_logs: 10_000, ttl: 86_400)
        @redis = redis
        @file_logger = file ? ::Logger.new(file) : nil
        @max_logs = max_logs
        @ttl = ttl
        @enabled = !@redis.nil? || !@file_logger.nil?
      end

      # Wrap a query/update execution: time it, record query/rows/bytes/cached, return the
      # block's value unchanged. Passthrough when disabled.
      #
      # @param bytes [Proc, Integer, nil] response size, or a proc evaluated AFTER the block
      #   (the byte count is only known once the response has been read -- see Client#response).
      # @param count_cache [Boolean] whether this entry counts toward the cache hit-rate tally.
      #   The caller (Client#query) sets this true only for cache-ELIGIBLE reads -- i.e. caching
      #   is actually on -- so the rate measures cache effectiveness, not whether caching is
      #   enabled. Writes and caching-off queries pass false and don't move the ratio.
      def around(query, cached:, user: nil, bytes: nil, count_cache: false)
        return yield unless @enabled

        result = nil
        elapsed = Benchmark.realtime { result = yield }
        record(query: query.to_s,
               cached: cached,
               user: resolve_user(user),
               rows: (result.respond_to?(:size) ? result.size : nil),
               bytes: (bytes.respond_to?(:call) ? bytes.call : bytes),
               execution_time: elapsed.round(4),
               # folded into #record's pipeline rather than a second round-trip
               cache_stat: (count_cache ? cached : nil))
        result
      end

      # Lifetime read-through cache hit rate. Counters survive the per-query ring-buffer trim, so
      # this is an all-time tally (since the last #clear), not a windowed rate.
      # @return [Hash] { hits:, misses:, total:, rate: } (rate in 0.0..1.0, 0.0 when no reads)
      def cache_hit_rate
        return { hits: 0, misses: 0, total: 0, rate: 0.0 } unless @redis

        hits = @redis.get(CACHE_HITS).to_i
        misses = @redis.get(CACHE_MISSES).to_i
        total = hits + misses
        { hits: hits, misses: misses, total: total,
          rate: total.zero? ? 0.0 : (hits.to_f / total).round(4) }
      end

      # Entries logged within the last `seconds`, newest first.
      def recent(seconds)
        return [] unless @redis

        floor = ((Time.now.to_f - seconds) * 1_000_000).to_i
        fetch(@redis.zrevrangebyscore(INDEX, '+inf', floor))
      end

      # The most recent `limit` entries, newest first.
      def all(limit: 100)
        return [] unless @redis

        fetch(@redis.zrevrange(INDEX, 0, limit - 1))
      end

      # Drop all logged entries (test/dev helper).
      def clear
        return unless @redis

        ids = @redis.zrange(INDEX, 0, -1)
        @redis.del(*ids.map { |i| entry_key(i) }) unless ids.empty?
        @redis.del(INDEX, USERS, CACHE_HITS, CACHE_MISSES)
      end

      # --- backward-compatibility shim --------------------------------------------------------
      # AgroPortal's ontologies_api Admin::LoggingController calls the fork-era API
      # (Goo.logger.get_logs / queries_last_n_seconds / users_query_count). Keep those names
      # working against this logger so the de-forked goo is a drop-in there. `Goo.logger` itself
      # is aliased to `Goo.query_logger` in lib/goo.rb.

      # ALL entries newest-first (the controller paginates them itself, so this must NOT cap --
      # unlike #all, whose default limit would truncate pagination past the first page).
      def get_logs
        return [] unless @redis

        fetch(@redis.zrevrange(INDEX, 0, -1))
      end

      alias queries_last_n_seconds recent

      # [{ user:, count: }] sorted by count desc -- the shape the controller replies with.
      def users_query_count
        return [] unless @redis

        @redis.zrevrange(USERS, 0, -1, with_scores: true).map do |user, count|
          { user: user, count: count.to_i }
        end
      end

      # Record a free-text entry (fork-era Goo.logger.info("...")). Used by AgroPortal's logging
      # tests; the controller itself doesn't call it.
      def info(message, cached: nil, user: nil)
        return unless @enabled

        record(query: message.to_s, cached: cached, user: resolve_user(user),
               rows: nil, bytes: nil, execution_time: 0)
        nil
      end
      # --- end shim ---------------------------------------------------------------------------

      private

      def entry_key(id)
        "#{KEY}:entry:#{id}"
      end

      def resolve_user(user)
        user || Thread.current[:remote_user]&.id&.to_s
      end

      # One logged query = ONE Redis round-trip. Every write for the entry (the JSON blob, the
      # index score, the per-user tally and its rolling TTL, the cache hit/miss counter) plus the
      # ZCARD that drives the ring-buffer trim goes out in a single pipeline. Unbatched this was
      # ~6 sequential round-trips per query, which is not affordable on a path that already runs
      # thousands of Redis ops per request (de-fork review section 2A).
      #
      # @param cache_stat [Boolean, nil] true/false to tally a cache hit/miss, nil to tally
      #   neither (writes, and reads issued while caching is off -- see #around's count_cache).
      def record(cache_stat: nil, **entry)
        id = SecureRandom.uuid
        now = Time.now
        entry = entry.merge(id: id, timestamp: now.iso8601)

        @file_logger&.info(format('SPARQL %ss cached=%s rows=%s bytes=%s :: %s',
                                  entry[:execution_time], entry[:cached],
                                  entry[:rows], entry[:bytes], entry[:query]))
        return unless @redis

        user = entry[:user]
        with_redis do
          results = @redis.pipelined do |p|
            p.set(entry_key(id), entry.to_json, ex: @ttl)
            p.zadd(INDEX, (now.to_f * 1_000_000).to_i, id)
            # Per-user query counter (backs #users_query_count). A single ZSET keyed by user id,
            # carrying a rolling 30-day TTL refreshed on each query (the fork TTL'd each user key
            # individually -- one set is simpler and close enough for an active-user metric).
            unless user.nil?
              p.zincrby(USERS, 1, user.to_s)
              p.expire(USERS, USER_EXPIRY)
            end
            p.incr(cache_stat ? CACHE_HITS : CACHE_MISSES) unless cache_stat.nil?
            p.zcard(INDEX) # last => drives trim below without a second round-trip
          end
          trim(results.last.to_i)
        end
      end

      # Ring-buffer trim, given the index cardinality already read by #record's pipeline. Costs
      # nothing on the common path (under @max_logs); when over, one ZRANGE plus one pipelined
      # ZREM+DEL.
      def trim(card)
        excess = card - @max_logs
        return if excess <= 0

        old = @redis.zrange(INDEX, 0, excess - 1)
        return if old.empty?

        @redis.pipelined do |p|
          p.zrem(INDEX, old)
          p.del(*old.map { |i| entry_key(i) })
        end
      end

      # `ids` arrive already newest-first (callers use zrev*); preserve that order.
      def fetch(ids)
        return [] if ids.empty?

        @redis.mget(*ids.map { |i| entry_key(i) }).compact.map { |j| JSON.parse(j) }
      end

      # Logging must never break a query: a redis hiccup degrades to file-only / no-op.
      def with_redis
        yield
      rescue StandardError => e
        @file_logger&.warn("query log redis write failed: #{e.class}: #{e.message}")
      end
    end
  end
end
