# Start simplecov if this is a coverage task or if it is run in the CI pipeline
if ENV["COVERAGE"] == "true" || ENV["CI"] == "true"
  require "simplecov"
  require "simplecov-cobertura"
  # https://github.com/codecov/ruby-standard-2
  # Generate HTML and Cobertura reports which can be consumed by codecov uploader
  SimpleCov.formatters = SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::CoberturaFormatter
  ])
  SimpleCov.start do
    add_filter "/test/"
    add_filter "app.rb"
    add_filter "init.rb"
    add_filter "/config/"
  end
end

require 'minitest/autorun'
require 'minitest/hooks/test' # before_all/after_all: per-suite (once) setup/teardown

require_relative "../lib/goo.rb"
require_relative '../lib/goo/test_helpers' # Goo::TestHelpers: assert_max/assert_sparql_queries
require_relative '../config/config.test'

# Safety guard for destructive tests: ensure test targets are safe (localhost or -ut suffix)
module TestSafety
  SAFE_HOSTS = Regexp.new(/localhost|-ut/)
  MAX_REDIS_KEYS = 10

  def self.safe_host?(value)
    value = value.to_s
    return false if value.empty?
    !!(value =~ SAFE_HOSTS)
  end

  def self.targets
    {
      triplestore: Goo.settings.goo_host.to_s,
      search: Goo.settings.search_server_url.to_s,
      redis: Goo.settings.goo_redis_host.to_s
    }
  end

  def self.unsafe_targets?
    t = targets
    unsafe = !safe_host?(t[:triplestore]) || !safe_host?(t[:search]) || !safe_host?(t[:redis])
    [unsafe, t]
  end

  def self.ensure_safe_test_targets!
    return if @safety_checked
    unsafe, t = unsafe_targets?
    return if !unsafe || ENV['CI'] == 'true'

    if $stdin.tty?
      puts "\n\n================================== WARNING ==================================\n"
      puts "** TESTS CAN BE DESTRUCTIVE -- YOU ARE POINTING TO A POTENTIAL PRODUCTION/STAGE SERVER **"
      puts "Servers:"
      puts "triplestore -- #{t[:triplestore]}"
      puts "search -- #{t[:search]}"
      puts "redis -- #{t[:redis]}"
      print "Type 'y' to continue: "
      $stdout.flush
      confirm = $stdin.gets
      abort('Canceling tests...') unless confirm && confirm.strip == 'y'
      puts 'Running tests...'
      $stdout.flush
    else
      abort('Aborting tests: non-whitelisted targets and non-interactive session.')
    end
  ensure
    @safety_checked = true
  end

  def self.ensure_safe_redis_size!
    redis = Goo.redis_client
    return unless redis
    count = redis.dbsize
    return if count <= MAX_REDIS_KEYS
    abort("Aborting tests: redis has #{count} keys, expected <= #{MAX_REDIS_KEYS} for a test instance.")
  end
end

TestSafety.ensure_safe_test_targets!

module Goo
  # Per-test SPARQL query-count capture (opt-in: OP_SPARQL_QUERY_COUNTS=1). Records each test's
  # store-bound query delta so we can spot outliers and diff counts between optimization runs.
  # Console gets a top-15; a full name-sorted file (OP_SPARQL_QUERY_COUNTS_FILE, default
  # sparql_query_counts.txt) is written for diffing two runs line-by-line. The per-test count
  # spans before_setup..after_teardown, so it includes the test's own fixture/setup queries.
  module SparqlQueryStats
    @counts = {}
    class << self
      def enabled?
        %w[1 true yes on].include?(ENV['OP_SPARQL_QUERY_COUNTS'].to_s.strip.downcase)
      end

      def record(test_id, count)
        @counts[test_id] = count
      end

      def report(io: $stderr)
        return if @counts.empty?

        total = @counts.values.sum
        io.puts "\n[goo] per-test SPARQL query counts: #{@counts.size} tests, " \
                "#{total} store-bound queries"
        io.puts '[goo] top 15 by query count:'
        @counts.sort_by { |_, c| -c }.first(15).each { |id, c| io.puts format('  %6d  %s', c, id) }

        file = ENV['OP_SPARQL_QUERY_COUNTS_FILE'] || 'sparql_query_counts.txt'
        File.open(file, 'w') { |f| @counts.sort.each { |id, c| f.puts "#{c}\t#{id}" } }
        io.puts "[goo] full per-test counts (name-sorted, diffable) -> #{file}"
      end
    end
  end

  # Base class for goo's tests. Includes Minitest::Hooks so suites can define
  # before_all/after_all (run once per suite) — the idiomatic replacement for the
  # old GooTest::Unit#_run_suite before_suite/after_suite.
  class TestCase < Minitest::Test
    include Minitest::Hooks
    include Goo::TestHelpers # assert_max_sparql_queries / assert_sparql_queries (query budgets)

    def before_setup
      super
      @__sparql_q0 = Goo.query_count_total if Goo::SparqlQueryStats.enabled?
    end

    def after_teardown
      if Goo::SparqlQueryStats.enabled? && @__sparql_q0
        Goo::SparqlQueryStats.record("#{self.class}##{name}",
                                     Goo.query_count_total.to_i - @__sparql_q0.to_i)
      end
      super
    end
  end
end

# Minitest has no "before all suites" hook: arm the store-bound SPARQL tally at load time (this
# file is required before autorun's at_exit fires) and print the run totals in Minitest.after_run.
Goo.enable_query_count_total
Minitest.after_run do
  warn "\n[goo] SPARQL during test run: #{Goo.query_count_total} store-bound queries, " \
       "#{Goo.cache_hit_total} cache hits"
  Goo::SparqlQueryStats.report if Goo::SparqlQueryStats.enabled?
end

# Test runs must not depend on Solr state left behind by previous (possibly
# interrupted) runs: rebuild each search collection's schema on its first
# initialization in this process. Collections init lazily (on first use), so
# this is a flag rather than an eager call — models register their collections
# when their test file loads, which can be after this file is required.
Goo.force_rebuild_search_schema = true

module TestHelpers
  def self.test_reset
    TestSafety.ensure_safe_test_targets!
    TestSafety.ensure_safe_redis_size!
    Goo.class_variable_set(:@@sparql_backends, {})
    Goo.add_sparql_backend(:main,
                            backend_name: Goo.settings.goo_backend_name,
                            query: "http://#{Goo.settings.goo_host}:#{Goo.settings.goo_port}#{Goo.settings.goo_path_query}",
                            data: "http://#{Goo.settings.goo_host}:#{Goo.settings.goo_port}#{Goo.settings.goo_path_data}",
                            update: "http://#{Goo.settings.goo_host}:#{Goo.settings.goo_port}#{Goo.settings.goo_path_update}",
                            options: { rules: :NONE })
  end
end

class GooTest

  def self.triples_for_subject(resource_id)
    rs = Goo.sparql_query_client.query("SELECT * WHERE { #{resource_id.to_ntriples} ?p ?o . }")
    count = 0
    rs.each_solution do |sol|
      count += 1
    end
    return count
  end

  def self.count_pattern(pattern)
    q = "SELECT * WHERE { #{pattern} }"
    rs = Goo.sparql_query_client.query(q)
    count = 0
    rs.each_solution do |sol|
      count += 1
    end
    return count
  end

end
