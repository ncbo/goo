require 'test/unit'

require_relative "../lib/goo.rb"


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
    if Goo.store().nil?
      Goo.configure do |conf|
        conf[:stores] = [ { :name => :main , :host => "localhost", :port => 8080 , :options => { } } ]
        conf[:namespaces] = {
          :omv => "http://omv.org/ontology/",
          :goo => "http://goo.org/default/",
          :foaf => "http://xmlns.com/foaf/0.1/",
          :default => :goo,
        }
      end
      epr = Goo.store()
      #just testing that sparql_http is integrated
      assert_instance_of SparqlRd::Store::HttpStore::Client, epr
    end
  end
end
