require 'json'
require 'benchmark'
require 'securerandom'
require 'logger'

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
    # regex, no Marshal-of-JSON (the rough edges of the old fork logger). The goo:qlog:* keyspace
    # is disjoint from the cache's sparql:* keys, so log volume never evicts cache memory.
    class QueryLogger
      KEY = 'goo:qlog'.freeze
      INDEX = "#{KEY}:index".freeze
      USERS = "#{KEY}:users".freeze       # ZSET user-id -> query count
      USER_EXPIRY = 2_592_000             # 30 days (matches the fork's per-user retention)
      CACHE_HITS = "#{KEY}:cache:hits".freeze     # lifetime read-through cache hit/miss tallies
      CACHE_MISSES = "#{KEY}:cache:misses".freeze

      attr_accessor :redis, :file_logger, :enabled

      def initialize(redis: nil, file: nil, max_logs: 1000, ttl: 86_400)
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
               execution_time: elapsed.round(4))
        record_cache_stat(cached) if count_cache
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

      def record(**entry)
        id = SecureRandom.uuid
        now = Time.now
        entry = entry.merge(id: id, timestamp: now.iso8601)

        @file_logger&.info(format('SPARQL %ss cached=%s rows=%s bytes=%s :: %s',
                                  entry[:execution_time], entry[:cached],
                                  entry[:rows], entry[:bytes], entry[:query]))
        return unless @redis

        with_redis do
          @redis.set(entry_key(id), entry.to_json, ex: @ttl)
          @redis.zadd(INDEX, (now.to_f * 1_000_000).to_i, id)
          bump_user_count(entry[:user])
          trim
        end
      end

      # Per-user query counter (backs #users_query_count). A single ZSET keyed by user id; the
      # whole set carries a rolling 30-day TTL refreshed on each query (the fork TTL'd each user
      # key individually -- a single set is simpler and close enough for an active-user metric).
      def bump_user_count(user)
        return if user.nil?

        @redis.zincrby(USERS, 1, user.to_s)
        @redis.expire(USERS, USER_EXPIRY)
      end

      def record_cache_stat(hit)
        return unless @redis

        with_redis { @redis.incr(hit ? CACHE_HITS : CACHE_MISSES) }
      end

      def trim
        excess = @redis.zcard(INDEX) - @max_logs
        return if excess <= 0

        old = @redis.zrange(INDEX, 0, excess - 1)
        return if old.empty?

        @redis.zrem(INDEX, old)
        @redis.del(*old.map { |i| entry_key(i) })
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
