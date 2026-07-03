require 'stoplight'
require 'net/http/persistent'

module Goo
  module SPARQL
    # Circuit breakers for the two dependencies goo hits on the read path -- the Redis cache and
    # the SPARQL endpoint. When a dependency is failing or slow, fail fast rather than (a) waiting
    # out a long per-op timeout on every request or (b) letting a Redis outage amplify one
    # cached-read request into ~2000 store queries and melt the triplestore for every tenant
    # (de-fork review §2A / D1 / D2).
    #
    # Per-process breakers, using Stoplight's default in-memory data store -- we deliberately do
    # NOT back the breaker with Redis, since Redis is one of the things that may be down. goo
    # raises Goo::SPARQL::Resilience::CircuitOpenError when a breaker is open; the web layer maps
    # that to 503/504 + an alert (goo, a library, can't return HTTP itself).
    #
    # OPT-IN: OP_SPARQL_CIRCUIT_BREAKER=true. Off by default, so shipping this changes no runtime
    # behavior until a deployment enables it (mirrors OP_USE_CACHE / OP_QUERIES_LOGGING).
    #
    # NOT a bulkhead: under process-per-worker servers (unicorn) there is no in-process
    # concurrency to cap -- the per-op timeout (lib/goo.rb) is what frees a stuck worker. A
    # concurrency bulkhead is a Puma-threads follow-up (review §2A / D2).
    module Resilience
      # Raised when a breaker is open. The web layer maps this to 503/504 (+ alert).
      class CircuitOpenError < StandardError; end

      # Infra failures that trip a breaker. A cache miss (get -> nil) is NOT an error and must
      # never count. Redis connection/timeout errors count; Redis::CommandError (a real command
      # problem, not an outage) does not.
      REDIS_ERRORS = [Redis::BaseConnectionError].freeze

      # SPARQL 5xx + transport/timeout errors count. SPARQL::Client::MalformedQuery / ClientError
      # (a bad query -- a caller bug, not a dependency outage) deliberately do NOT.
      SPARQL_ERRORS = [
        ::SPARQL::Client::ServerError,
        Net::HTTP::Persistent::Error, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error,
        Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, SocketError
      ].freeze

      REDIS_CIRCUIT = 'goo:redis'.freeze

      # Logs a breaker's color transition (green<->red) ONCE per transition -- not per rejected
      # op (review §2A: "Log at state transitions, never per-op"). Calls the optional
      # Resilience.on_state_change hook so a deployment can page / emit a metric.
      class StateNotifier < Stoplight::Notifier::Base
        def notify(light, from_color, to_color, error)
          detail = error ? " (#{error.class}: #{error.message})" : ''
          warn "[goo] circuit '#{light.name}' #{from_color} -> #{to_color}#{detail}"
          Resilience.on_state_change&.call(light.name, from_color, to_color, error)
          "#{light.name}: #{from_color} -> #{to_color}"
        end
      end

      class << self
        # Optional hooks a deployment can set: on_state_change(name, from, to, error) for
        # alerting/metrics; on_invalidation_failure(graph, error) when a cache invalidation is
        # given up on (D4 -- self-heals on the next write).
        attr_accessor :on_state_change, :on_invalidation_failure

        def enabled?
          return @enabled unless @enabled.nil?

          @enabled = %w[1 true yes on].include?(ENV['OP_SPARQL_CIRCUIT_BREAKER'].to_s.strip.downcase)
        end
        attr_writer :enabled

        # Test/boot helper: drop memoized breakers, their in-memory failure counts, and the
        # enabled memo so env changes take effect and breaker state doesn't leak across tests.
        def reset!
          @lights = {}
          @data_store = nil
          @enabled = nil
        end

        # Protect a cache-dependent READ (cache get, or a SPARQL query/update). Fail fast: when
        # the breaker is open, raise CircuitOpenError so the request sheds load (D1/D2) instead of
        # hammering a dead dependency or flooding the store. Below threshold, the raw infra error
        # still propagates (the request fails with the real error, as before).
        def protect_read(name, tracked_errors)
          return yield unless enabled?

          light(name, tracked_errors).run { yield }
        rescue Stoplight::Error::RedLight
          raise CircuitOpenError, "circuit '#{name}' is open"
        end

        # Protect a BEST-EFFORT op (cache store / invalidate): its failure must never fail the
        # request. Returns `fallback` on an open circuit or an infra error (which still counts
        # toward the breaker when enabled). Non-infra errors propagate so real bugs surface.
        def protect_best_effort(name, tracked_errors, fallback = nil)
          if enabled?
            light(name, tracked_errors).run(->(_e) { fallback }) { yield }
          else
            yield
          end
        rescue Stoplight::Error::RedLight, *tracked_errors
          fallback
        end

        def threshold
          (ENV['OP_SPARQL_BREAKER_THRESHOLD'] || 5).to_i
        end

        def cool_off
          (ENV['OP_SPARQL_BREAKER_COOL_OFF'] || 30).to_i
        end

        private

        # One in-memory store shared by all goo breakers (per process). Never Redis-backed --
        # the breaker must work when Redis is down.
        def data_store
          @data_store ||= Stoplight::DataStore::Memory.new
        end

        def light(name, tracked_errors)
          (@lights ||= {})[name] ||= Stoplight(
            name,
            data_store: data_store,
            threshold: threshold,
            cool_off_time: cool_off,
            tracked_errors: tracked_errors,
            notifiers: [StateNotifier.new]
          )
        end
      end
    end
  end
end
