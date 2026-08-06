require_relative 'test_case'
require_relative 'models'

# Isolated unit tests for Goo::SPARQL::Cache and the de-fork transport/serialization seams
# (de-fork review §3: T-1..T-5, T-7..T-10, T-13..T-18, T-22, T-24). Unlike test_cache.rb, these
# never issue a triplestore round-trip -- they exercise the cache/serialization contracts
# directly (redis only; several are pure).
class TestCacheUnit < Goo::TestCase
  GRAPH_A = 'http://goo.org/default/UnitCacheA'.freeze
  GRAPH_B = 'http://goo.org/default/UnitCacheB'.freeze
  QUERY = 'SELECT ?s WHERE { ?s ?p ?o }'.freeze

  def setup
    @redis = Goo.redis_client
    @redis.flushdb
    @cache = Goo::SPARQL::Cache.new(redis_cache: @redis)
  end

  def teardown
    @redis.flushdb
    Goo.use_cache = false
  end

  def solutions(value = 'x')
    RDF::Query::Solutions.new([RDF::Query::Solution.new(s: RDF::Literal.new(value))])
  end

  # --- key generation (T-5) ---------------------------------------------------------------

  def test_generate_cache_key_multi_graph_sorted_uniq
    key = Goo::SPARQL::Cache.generate_cache_key('q', [GRAPH_B, GRAPH_A, GRAPH_A])
    digest = Digest::MD5.hexdigest('q')
    assert_equal "sparql:#{GRAPH_A}:#{GRAPH_B}:#{digest}", key[:query]
    assert_equal ["sparql:graph:#{GRAPH_A}", "sparql:graph:#{GRAPH_B}"], key[:graphs]
  end

  # --- store / get contract (T-14, T-15) --------------------------------------------------

  def test_store_get_round_trip_and_graph_membership
    value = solutions('Stanford')
    @cache.store(QUERY, { graphs: [GRAPH_A] }, value)
    keys = Goo::SPARQL::Cache.generate_cache_key(QUERY, [GRAPH_A])
    assert @redis.exists?(keys[:query])
    assert @redis.sismember("sparql:graph:#{GRAPH_A}", keys[:query])

    got = @cache.get(QUERY, graphs: [GRAPH_A])
    assert_kind_of RDF::Query::Solutions, got
    assert_equal 'Stanford', got.first[:s].to_s
  end

  def test_inert_without_redis
    inert = Goo::SPARQL::Cache.new
    assert_nil inert.get(QUERY, graphs: [GRAPH_A])
    inert.store(QUERY, { graphs: [GRAPH_A] }, solutions) # no-op, must not raise
    inert.invalidate(GRAPH_A)                            # no-op, must not raise
    assert_equal 0, @redis.dbsize
  end

  # --- read options (T-1, T-2) ------------------------------------------------------------

  def test_reload_cache_deletes_entry_and_misses
    @cache.store(QUERY, { graphs: [GRAPH_A] }, solutions)
    keys = Goo::SPARQL::Cache.generate_cache_key(QUERY, [GRAPH_A])
    assert @redis.exists?(keys[:query])

    assert_nil @cache.get(QUERY, graphs: [GRAPH_A], reload_cache: true)
    refute @redis.exists?(keys[:query]), 'reload_cache must delete the stored entry'
  end

  def test_bypass_cache_skips_read
    @cache.store(QUERY, { graphs: [GRAPH_A] }, solutions)
    query = QUERY.dup
    def query.options
      { bypass_cache: true }
    end
    assert_nil @cache.get(query, graphs: [GRAPH_A])
  end

  # --- stale eviction: the allkeys-lru fail-safe (T-4) ------------------------------------

  def test_stale_entry_evicted_on_graph_membership_miss
    @cache.store(QUERY, { graphs: [GRAPH_A] }, solutions)
    keys = Goo::SPARQL::Cache.generate_cache_key(QUERY, [GRAPH_A])
    # Simulate an LRU-evicted / pruned graph set: entry present, membership gone.
    @redis.srem("sparql:graph:#{GRAPH_A}", keys[:query])

    assert_nil @cache.get(QUERY, graphs: [GRAPH_A])
    refute @redis.exists?(keys[:query]), 'stale entry must be deleted on membership miss'
  end

  # --- large-entry guard (T-3) ------------------------------------------------------------

  def test_entries_over_the_marshal_size_guard_are_not_cached
    big = solutions('x' * 51_000_000) # Marshal.dump > 50e6 bytes
    @cache.store(QUERY, { graphs: [GRAPH_A] }, big)
    assert_equal 0, @redis.dbsize, 'entries over the 50MB marshal guard must not be written'
  end

  # --- cache scope matches the fork (T-7 / review D3) -------------------------------------

  def test_store_scope_solutions_and_ask_booleans_only
    graph_result = RDF::Graph.new << RDF::Statement.new(RDF::URI('http://s'),
                                                        RDF::URI('http://p'),
                                                        RDF::URI('http://o'))
    @cache.store('CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o }', { graphs: [GRAPH_A] }, graph_result)
    assert_equal 0, @redis.dbsize,
                 'CONSTRUCT/DESCRIBE graph results must not be cached (fork parity, D3)'

    ask = 'ASK { ?s ?p ?o }'
    @cache.store(ask, { graphs: [GRAPH_A] }, true)
    # assert_same: the exact boolean must round-trip (a truthy check could mask a wrong value)
    assert_same true, @cache.get(ask, graphs: [GRAPH_A]), 'ASK booleans are cacheable'
  end

  # --- invalidation mechanics + failure path (T-16, T-10) ---------------------------------

  def test_invalidate_scalar_array_and_prefix_normalization
    @cache.store(QUERY, { graphs: [GRAPH_A, GRAPH_B] }, solutions)
    @cache.invalidate(GRAPH_A) # scalar, unprefixed
    refute @redis.exists?("sparql:graph:#{GRAPH_A}")
    assert @redis.exists?("sparql:graph:#{GRAPH_B}")

    @cache.invalidate(["sparql:graph:#{GRAPH_B}"]) # array, pre-prefixed
    refute @redis.exists?("sparql:graph:#{GRAPH_B}")

    # both graph sets gone => the entry fails membership on the next read (stale miss)
    assert_nil @cache.get(QUERY, graphs: [GRAPH_A, GRAPH_B])
  end

  def test_invalidation_del_failure_warns_and_moves_on
    # A failed DEL logs + is swallowed (review D4) -- invalidation must never fail the write.
    # A non-connection error (Redis::BaseError) is not retried, so it can't hit any backoff sleep.
    @cache.store(QUERY, { graphs: [GRAPH_A] }, solutions)
    @redis.define_singleton_method(:del) { |*_| raise Redis::BaseError, 'boom' }
    started = Time.now
    assert_output(nil, /cache invalidation failed/) { @cache.invalidate(GRAPH_A) }
    assert_operator Time.now - started, :<, 2, 'a non-retryable DEL failure must not sleep/back off'
  ensure
    @redis.singleton_class.send(:remove_method, :del)
  end

  # --- Marshal round-trip fidelity (T-17) -------------------------------------------------

  def test_solutions_marshal_round_trip
    sols = RDF::Query::Solutions.new(
      [RDF::Query::Solution.new(s: RDF::URI('http://s'), name: RDF::Literal.new('Stanford'))]
    )
    restored = Marshal.load(Marshal.dump(sols))
    assert_equal sols.variable_names.sort, restored.variable_names.sort
    assert_equal 'Stanford', restored.first[:name].to_s
  end

  # --- backend-quirk seams (T-8, T-9) ------------------------------------------------------

  def test_parse_json_value_tolerates_empty_binding
    assert_nil SPARQL::Client.parse_json_value({})
  end

  def test_serialize_value_forces_xsd_string_only_when_explicit
    typed = SPARQL::Client.serialize_value(RDF::Literal.new('hi', datatype: RDF::XSD.string))
    assert_equal '"hi"^^<http://www.w3.org/2001/XMLSchema#string>', typed
    assert_equal '"hi"', SPARQL::Client.serialize_value(RDF::Literal.new('hi'))
  end

  # --- form-urlencoded transport (T-18) ----------------------------------------------------

  def test_make_post_request_form_urlencodes_protocol_11
    client = Goo::SPARQL::Client.new('http://localhost:9000/sparql/',
                                     protocol: '1.1',
                                     headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                                     validate: false)
    request = client.make_post_request(QUERY)
    assert_equal 'application/x-www-form-urlencoded', request['Content-Type']
    assert_equal 'query=SELECT+%3Fs+WHERE+%7B+%3Fs+%3Fp+%3Fo+%7D', request.body
  end

  # --- ungraphed update under caching raises (T-13 / review D8) ----------------------------

  def test_update_without_graph_raises_when_caching_on
    client = Goo.sparql_update_client
    client.redis_cache = @redis
    # Plain string update: goo cannot know which graph to invalidate -> fork-parity raise
    # (happens BEFORE any HTTP, so no triplestore is touched).
    err = assert_raises(Exception) { client.update('DELETE WHERE { ?s ?p ?o }') }
    assert_equal 'Unsupported cacheable query', err.message
  ensure
    client.redis_cache = nil
  end

  # --- UnionWithBind element contract (T-22) -----------------------------------------------

  def test_union_with_bind_empty_and_rdf_type_rendering
    assert_predicate Goo::SPARQL::Ext::UnionWithBind.new(nil), :empty?
    assert_predicate Goo::SPARQL::Ext::UnionWithBind.new([]), :empty?

    uwb = Goo::SPARQL::Ext::UnionWithBind.new(
      [[[[:s, RDF.type, RDF::URI('http://goo.org/default/University')]],
        { binds: [{ value: 'name', as: :attributeProperty }] }]]
    )
    refute_predicate uwb, :empty?
    expected = 'OPTIONAL { { ?s a <http://goo.org/default/University> . ' \
               'BIND( "name" as ?attributeProperty) } }'
    assert_equal expected, uwb.to_s
  end

  # --- use_cache kill-switch authority (T-24 / review D5) ----------------------------------

  def test_use_cache_flag_is_authoritative_over_configuration_order
    Goo.use_cache = false
    # test_reset rebuilds the :main clients; construction injects the live @@redis_client, so
    # without the D5 fix this would leave caching silently ON despite use_cache=false.
    TestHelpers.test_reset
    assert_nil Goo.sparql_query_client.cache.redis_cache,
               'use_cache=false must win over construction-time redis injection'

    Goo.use_cache = true
    refute_nil Goo.sparql_query_client.cache.redis_cache
  ensure
    Goo.use_cache = false
  end
end
