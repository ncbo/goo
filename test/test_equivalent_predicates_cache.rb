require_relative 'test_case'

# Unit tests for the per-request equivalent-predicates (sub-property) map cache in
# Goo::Base::Where#retrieve_equivalent_predicates. Building a large class tree issues many
# aliased/unmapped loads against the same graph; each one used to re-fetch the sub-property
# tuples and re-run #closure. When a request arms the cache (Goo::Debug), the map must be
# computed once per graph and shared, otherwise it must recompute each time (no behavior
# change outside a request). These tests spy on Goo::SPARQL::Queries.sub_property_predicates
# -- the store-bound call the fix elides -- so they need no live backend.
class TestEquivalentPredicatesCache < Goo::TestCase

  class EqCacheProbe < Goo::Base::Resource
    model :eq_cache_probe, name_with: :id
    attribute :name
  end

  Collection = Struct.new(:id)

  def teardown
    Thread.current[:goo_equivalent_predicates_cache] = nil
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

  def test_map_computed_once_per_graph_when_armed
    Thread.current[:goo_equivalent_predicates_cache] = {}
    with_sub_property_spy do |calls|
      maps = Array.new(5) { where_for("http://example.org/eqcache/g1").retrieve_equivalent_predicates }
      assert_equal 1, calls.length,
                   "an armed request must compute the sub-property map once, not per load"
      assert maps.all? { |map| map.equal?(maps.first) },
             "an armed request must hand every load the same cached map instance"
    end
  end

  def test_map_recomputed_each_time_when_not_armed
    Thread.current[:goo_equivalent_predicates_cache] = nil
    with_sub_property_spy do |calls|
      5.times { where_for("http://example.org/eqcache/g2").retrieve_equivalent_predicates }
      assert_equal 5, calls.length,
                   "without an armed cache each load recomputes the map (prior behavior, no request scope)"
    end
  end

  def test_distinct_graphs_are_cached_separately
    Thread.current[:goo_equivalent_predicates_cache] = {}
    with_sub_property_spy do |calls|
      where_for("http://example.org/eqcache/a").retrieve_equivalent_predicates
      where_for("http://example.org/eqcache/b").retrieve_equivalent_predicates
      where_for("http://example.org/eqcache/a").retrieve_equivalent_predicates
      assert_equal 2, calls.length,
                   "each distinct graph is computed once; a repeat graph is served from the cache"
    end
  end
end
