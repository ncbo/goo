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

require 'minitest/unit'
MiniTest::Unit.autorun

require_relative "../lib/goo.rb"
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

  class Unit < MiniTest::Unit

    def before_suites
    end

    def after_suites
    end

    def _run_suites(suites, type)
      begin
        before_suites
        super(suites, type)
      ensure
        after_suites
      end
    end

    def _run_suite(suite, type)
      ret = []
      [Goo.slice_loading_size].each do |slice_size|
        puts "\nrunning test with slice_loading_size=#{slice_size}"
        Goo.slice_loading_size=slice_size
        begin
          suite.before_suite if suite.respond_to?(:before_suite)
          ret += super(suite, type)
        ensure
          suite.after_suite if suite.respond_to?(:after_suite)
        end
      end
      return ret
    end
  end

  MiniTest::Unit.runner = GooTest::Unit.new

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
