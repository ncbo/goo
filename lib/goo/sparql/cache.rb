require 'digest'

module Goo
  module SPARQL
    # Redis read-through cache for SPARQL SELECT queries, with graph-set invalidation.
    #
    # Ported from the NCBO fork of sparql-client (lib/sparql/client/cache.rb) as part of the
    # de-fork (docs/sparql-client-defork-proposal.md). The cache-key and Redis-key formats are
    # preserved verbatim (test/test_cache.rb asserts "sparql:graph:<g>" sets and
    # "sparql:<sorted-graphs>:<md5(query)>" entries).
    #
    # Differences from the fork (bug fixes, proposal Â§3.1):
    #   * `get` is read-only -- it does NOT smuggle a `:cache_key` back through `options` for a
    #     later `parse_response` to write. The caller stores the result explicitly via `store`,
    #     passing the value it got back from the (vanilla) client.
    #   * Invalidation ordering is the caller's responsibility; Goo::SPARQL::Client invalidates
    #     AFTER the write commits.
    #
    # When `redis_cache` is nil the cache is inert: `get` returns nil, `store`/`invalidate` are
    # no-ops. This is the `Goo.use_cache == false` state.
    class Cache
      attr_accessor :redis_cache

      def initialize(redis_cache: nil)
        @redis_cache = redis_cache if redis_cache
      end

      # @return [Object, nil] the cached value for this query, or nil on miss / disabled /
      #   bypassed. Stale entries (failing graph-set membership) are dropped and treated as a
      #   miss.
      def get(query, options)
        return nil if query.respond_to?(:options) && query.options[:bypass_cache]
        return nil unless cacheable?(query, options)

        keys = query_cache_key(query, options)
        return nil if keys.nil?

        if options[:reload_cache]
          @redis_cache.del(keys[:query])
          return nil
        end

        data = @redis_cache.get(keys[:query])
        return nil unless data

        keys[:graphs].each do |g|
          unless @redis_cache.sismember(g, keys[:query])
            @redis_cache.del(keys[:query])
            return nil
          end
        end

        Marshal.load(data)
      end

      # Write `value` to the cache under this query's graph-set keys.
      def store(query, options, value)
        return unless cacheable?(query, options)

        keys = query_cache_key(query, options)
        return if keys.nil?

        cache_query_response(keys, value)
      end

      def invalidate(graphs)
        cache_invalidate_graph(graphs)
      end

      def self.generate_cache_key(string, from)
        from = from.map { |x| x.to_s }.uniq.sort
        sorted_graphs = from.join ":"
        digest = Digest::MD5.hexdigest(string)
        from = from.map { |x| "sparql:graph:#{x}" }
        { graphs: from, query: "sparql:#{sorted_graphs}:#{digest}" }
      end

      private

      def cacheable?(query, options)
        return false if @redis_cache.nil?

        query.instance_of?(::SPARQL::Client::Query) || options[:graphs]
      end

      def query_cache_key(query, options)
        graphs = options[:graphs] || query.options[:graphs]
        return self.class.generate_cache_key(query.to_s, graphs) if graphs

        cache_key(query)
      end

      def cache_key(query)
        from = query.options[:from]
        return nil if from.nil? || from.empty?

        from = [from] unless from.instance_of?(Array)
        self.class.generate_cache_key(query.to_s, from)
      end

      def cache_query_response(keys, entry)
        data = Marshal.dump(entry)
        return if data.length > 50e6 # avoid large entries (50MB of marshalled object)

        keys[:graphs].each { |g| @redis_cache.sadd(g, keys[:query]) }
        @redis_cache.set(keys[:query], data)
      end

      def cache_invalidate_graph(graphs)
        return if @redis_cache.nil?

        graphs = [graphs] unless graphs.instance_of?(Array)
        graphs.each do |graph|
          attempts = 0
          begin
            graph = graph.to_s
            graph = "sparql:graph:#{graph}" unless graph.start_with?("sparql:graph:")
            @redis_cache.del(graph) if @redis_cache.exists?(graph)
          rescue StandardError
            if attempts < 3
              attempts += 1
              sleep(5)
              retry
            end
          end
        end
      end
    end
  end
end
