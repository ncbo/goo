require_relative 'test_case'
require 'request_store'

# Unit tests for the per-request equivalent-predicates (sub-property) map cache in
# Goo::Base::Where#retrieve_equivalent_predicates. Building a large class tree issues many
# aliased/unmapped loads against the same graph; each one used to re-fetch the sub-property
# tuples and re-run #closure. Inside a request (RequestStore.active?, armed by
# RequestStore::Middleware in the API) the map must be computed once per graph and shared;
# outside a request (cron, scripts) it must recompute each time -- no behavior change there.
# These tests spy on Goo::SPARQL::Queries.sub_property_predicates -- the store-bound call
# the fix elides -- so they need no live backend.
class TestEquivalentPredicatesCache < Goo::TestCase

  class EqCacheProbe < Goo::Base::Resource
    model :eq_cache_probe, name_with: :id
    attribute :name
  end

  Collection = Struct.new(:id)

  def teardown
    RequestStore.end!
    RequestStore.clear!
  end

  # A Where set up so retrieve_equivalent_predicates takes the :unmapped branch for `graph`.
  def where_for(graph)
    where = Goo::Base::Where.new(EqCacheProbe)
    where.instance_variable_set(:@include, [:unmapped])
    where.instance_variable_set(:@where_options_load,
                                { collection: [Collection.new(RDF::URI.new(graph))] })
    where
  end

  # Replace the store-bound sub_property_predicates with a spy that records each call and
  # returns no tuples (an empty map is enough to exercise the caching path), restoring the
  # original afterward. Yields the array of recorded calls.
  def with_sub_property_spy
    calls = []
    original = Goo::SPARQL::Queries.method(:sub_property_predicates)
    Goo::SPARQL::Queries.define_singleton_method(:sub_property_predicates) do |*graphs|
      calls << graphs
      []
    end
    yield calls
  ensure
    Goo::SPARQL::Queries.define_singleton_method(:sub_property_predicates, original)
  end

  def test_map_computed_once_per_graph_inside_request
    RequestStore.begin!
    with_sub_property_spy do |calls|
      maps = Array.new(5) { where_for("http://example.org/eqcache/g1").retrieve_equivalent_predicates }
      assert_equal 1, calls.length,
                   "inside a request the sub-property map must be computed once, not per load"
      assert maps.all? { |map| map.equal?(maps.first) },
             "inside a request every load must get the same cached map instance"
    end
  end

  def test_map_recomputed_each_time_outside_request
    refute RequestStore.active?, "test precondition: no active request scope"
    with_sub_property_spy do |calls|
      5.times { where_for("http://example.org/eqcache/g2").retrieve_equivalent_predicates }
      assert_equal 5, calls.length,
                   "outside a request scope each load recomputes the map (prior behavior; cron must not see a stale map)"
    end
  end

  def test_distinct_graphs_are_cached_separately
    RequestStore.begin!
    with_sub_property_spy do |calls|
      where_for("http://example.org/eqcache/a").retrieve_equivalent_predicates
      where_for("http://example.org/eqcache/b").retrieve_equivalent_predicates
      where_for("http://example.org/eqcache/a").retrieve_equivalent_predicates
      assert_equal 2, calls.length,
                   "each distinct graph is computed once; a repeat graph is served from the cache"
    end
  end

  def test_cache_does_not_survive_request_end
    RequestStore.begin!
    with_sub_property_spy do |calls|
      where_for("http://example.org/eqcache/g3").retrieve_equivalent_predicates
      RequestStore.end!
      RequestStore.clear!
      RequestStore.begin!
      where_for("http://example.org/eqcache/g3").retrieve_equivalent_predicates
      assert_equal 2, calls.length,
                   "a new request must not see the previous request's cached map"
    end
  end
end
