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

require 'test/unit'

require_relative "../lib/goo.rb"

module TestInit
  def self.configure_goo
    if Goo.store().nil?
      Goo.configure do |conf|
        conf[:stores] = [ { :name => :main , :host => "localhost", :port => 9000 , :options => { } } ]
        conf[:namespaces] = {
          :omv => "http://omv.org/ontology/",
          :goo => "http://goo.org/default/",
          :metadata => "http://goo.org/metadata/",
          :foaf => "http://xmlns.com/foaf/0.1/",
          :default => :goo,
        }
      end
    end
  end
end

class TestCase < Test::Unit::TestCase
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
