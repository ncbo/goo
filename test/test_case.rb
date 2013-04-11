# Start simplecov if this is a coverage task
if ENV["COVERAGE"].eql?("true")
  require 'simplecov'
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

class GooUnit < MiniTest::Unit
  def before_suites
    # code to run before the first test (gets inherited in sub-tests)
  end

  def after_suites
    # code to run after the last test (gets inherited in sub-tests)
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
    begin
      suite.before_suite if suite.respond_to?(:before_suite)
      super(suite, type)
    ensure
      suite.after_suite if suite.respond_to?(:after_suite)
    end
  end
end

GooUnit.runner = GooUnit.new


module TestInit
  def self.configure_goo
    if Goo.store().nil?
      Goo.configure do |conf|
        #  :rules => :NONE is a 4store specific param.
        conf[:stores] = [ { :name => :main , :host => "localhost", :port => 9000 , :options => { :rules => :NONE } } ]
        conf[:namespaces] = {
          :omv => "http://omv.org/ontology/",
          :skos => "http://www.w3.org/2004/02/skos/core#",
          :owl => "http://www.w3.org/2002/07/owl#",
          :rdfs => "http://www.w3.org/2000/01/rdf-schema#",
          :goo => "http://goo.org/default/",
          :metadata => "http://goo.org/metadata/",
          :foaf => "http://xmlns.com/foaf/0.1/",
          :rdf => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
          :default => :goo,
        }
        conf[:search_conf] = { :search_server => 'http://ncbo-dev-app-02.stanford.edu:8080/solr/' }
      end
    end
  end
end

class TestCase < MiniTest::Unit::TestCase
  def no_triples_for_subject(resource_id)
    rs = Goo.store().query("SELECT * WHERE { #{resource_id.to_turtle} ?p ?o }")
    rs.each_solution do |sol|
      #unreachable
      assert_equal 1,0
    end
  end

  def count_pattern(pattern)
    q = "SELECT * WHERE { #{pattern} }"
    rs = Goo.store().query(q)
    count = 0
    rs.each_solution do |sol|
      count = count + 1
    end
    return count
  end

  def initialize(*args)
    super(*args)
  end
end
