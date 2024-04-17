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
require_relative '../config/config'

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

