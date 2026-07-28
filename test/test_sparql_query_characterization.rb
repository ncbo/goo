require_relative 'test_case'
require_relative 'models'

# Characterization (golden) tests for the SPARQL strings goo generates.
#
# Purpose: pin the EXACT query text produced for representative query shapes so the
# sparql-client de-fork migration (docs/sparql-client-defork-proposal.md, Phase 0) is
# provably behavior-preserving. The same strings must come out before and after the
# forked gem is swapped for vanilla upstream + goo bolt-ons. If one of these assertions
# changes, the wire output to the triple store changed -- that must be a conscious,
# reviewed decision, not an accident of the migration.
#
# These tests are OFFLINE by construction: they intercept
# Goo::SPARQL::SolutionMapper#map_each_solutions to capture the built query (`select.to_s`)
# and skip execution, so no triple store is required. That makes them fast, deterministic,
# and runnable anywhere (unlike the rest of the suite, which needs a live backend).
#
# Coverage focus: the union-with-bind feature (`optional_union_with_bind_as`) is the
# highest-risk thing leaving the gem, and it has two distinct code paths -- a BIND variant
# for 4store/GraphDB and a FILTER variant for every other backend
# (lib/goo/sparql/query_builder.rb#union_bind_in_where). Both are exercised here.
class TestSparqlQueryCharacterization < Goo::TestCase
  ORIGINAL_MAP = Goo::SPARQL::SolutionMapper.instance_method(:map_each_solutions)

  def teardown
    # Always restore the real mapper and the configured backend, even on failure.
    # (No backend/Redis connection needed -- these tests never touch the network.)
    Goo::SPARQL::SolutionMapper.send(:define_method, :map_each_solutions, ORIGINAL_MAP)
    # Restore :main to the REAL configured backend (env-driven), not the dummy URL used for
    # offline capture -- otherwise a later test file inherits a bogus endpoint. No connection
    # is made here (we only rebuild the client objects).
    s = Goo.settings
    Goo.add_sparql_backend(:main,
                           backend_name: s.goo_backend_name,
                           query:  "http://#{s.goo_host}:#{s.goo_port}#{s.goo_path_query}",
                           data:   "http://#{s.goo_host}:#{s.goo_port}#{s.goo_path_data}",
                           update: "http://#{s.goo_host}:#{s.goo_port}#{s.goo_path_update}",
                           options: { rules: :NONE })
  end

  # Build the SPARQL goo would send for `backend`, capturing it instead of executing.
  def sparql_for(backend)
    use_backend(backend)
    captured = nil
    Goo::SPARQL::SolutionMapper.send(:define_method, :map_each_solutions) do |select, *_|
      captured = select.to_s
      {} # processor expects a models_by_id hash; empty is fine, we never map results
    end
    yield
    captured
  end

  def use_backend(name)
    Goo.add_sparql_backend(:main,
                           backend_name: name,
                           query:  "http://localhost:9000/sparql/",
                           data:   "http://localhost:9000/data/",
                           update: "http://localhost:9000/update/",
                           options: { rules: :NONE })
  end

  # --- baseline shapes (backend-agnostic) ---------------------------------------

  def test_simple_where_is_backend_agnostic
    expected =
      'SELECT DISTINCT ?id FROM <http://goo.org/default/University> ' \
      'WHERE { ?id a <http://goo.org/default/University> . ' \
      '?id <http://goo.org/default/name> "Stanford" . }'
    %w[4store virtuoso allegrograph graphdb].each do |backend|
      got = sparql_for(backend) { University.where(name: "Stanford").all }
      assert_equal expected, got, "simple WHERE should not vary by backend (#{backend})"
    end
  end

  # --- union-with-bind: BIND branch (4store / GraphDB) --------------------------

  def test_include_direct_uses_bind_on_4store
    expected =
      'SELECT DISTINCT ?id ?attributeProperty ?attributeObject ' \
      'FROM <http://goo.org/default/University> ' \
      'WHERE { ?id a <http://goo.org/default/University> . ' \
      '?id <http://goo.org/default/name> "Stanford" . ' \
      'OPTIONAL { { ?id <http://goo.org/default/name> ?attributeObject . ' \
      'BIND( "name" as ?attributeProperty) } } }'
    got = sparql_for("4store") { University.where(name: "Stanford").include(:name).all }
    assert_equal expected, got
  end

  def test_include_inverse_uses_bind_on_4store
    expected =
      'SELECT DISTINCT ?id ?attributeProperty ?attributeObject ?inverseAttributeObject ' \
      'FROM <http://goo.org/default/University> FROM <http://goo.org/default/Program> ' \
      'WHERE { ?id a <http://goo.org/default/University> . ' \
      '?id <http://goo.org/default/name> "Stanford" . ' \
      'OPTIONAL { { ?attributeObject <http://goo.org/default/university> ?id . ' \
      'BIND( "programs" as ?attributeProperty) } } }'
    got = sparql_for("4store") { University.where(name: "Stanford").include(:programs).all }
    assert_equal expected, got
  end

  def test_include_mixed_unions_bind_on_4store
    expected =
      'SELECT DISTINCT ?id ?attributeProperty ?attributeObject ?inverseAttributeObject ' \
      'FROM <http://goo.org/default/University> FROM <http://goo.org/default/Program> ' \
      'WHERE { ?id a <http://goo.org/default/University> . ' \
      '?id <http://goo.org/default/name> "Stanford" . ' \
      'OPTIONAL { { ?id <http://goo.org/default/name> ?attributeObject . ' \
      'BIND( "name" as ?attributeProperty) } UNION  ' \
      '{ ?attributeObject <http://goo.org/default/university> ?id . ' \
      'BIND( "programs" as ?attributeProperty) } } }'
    got = sparql_for("4store") { University.where(name: "Stanford").include(:name, :programs).all }
    assert_equal expected, got
  end

  def test_include_direct_uses_bind_on_graphdb
    # GraphDB takes the same BIND branch as 4store (query_builder.rb#union_bind_in_where);
    # lock the pair so a backend-dispatch regression can't silently move it (review T-12).
    expected =
      'SELECT DISTINCT ?id ?attributeProperty ?attributeObject ' \
      'FROM <http://goo.org/default/University> ' \
      'WHERE { ?id a <http://goo.org/default/University> . ' \
      '?id <http://goo.org/default/name> "Stanford" . ' \
      'OPTIONAL { { ?id <http://goo.org/default/name> ?attributeObject . ' \
      'BIND( "name" as ?attributeProperty) } } }'
    got = sparql_for("graphdb") { University.where(name: "Stanford").include(:name).all }
    assert_equal expected, got
  end

  # --- union-with-bind: FILTER branch (every other backend) ---------------------

  def test_include_direct_uses_filter_on_virtuoso
    expected =
      'SELECT DISTINCT ?id ?attributeProperty ?attributeObject ' \
      'FROM <http://goo.org/default/University> ' \
      'WHERE { ?id a <http://goo.org/default/University> . ' \
      '?id <http://goo.org/default/name> "Stanford" . ' \
      'OPTIONAL { { ?id ?attributeProperty ?attributeObject . ' \
      'FILTER(?attributeProperty = <http://goo.org/default/name>)  } } }'
    got = sparql_for("virtuoso") { University.where(name: "Stanford").include(:name).all }
    assert_equal expected, got
  end

  def test_include_mixed_unions_filter_on_virtuoso
    expected =
      'SELECT DISTINCT ?id ?attributeProperty ?attributeObject ?inverseAttributeObject ' \
      'FROM <http://goo.org/default/University> FROM <http://goo.org/default/Program> ' \
      'WHERE { ?id a <http://goo.org/default/University> . ' \
      '?id <http://goo.org/default/name> "Stanford" . ' \
      'OPTIONAL { { ?id ?attributeProperty ?attributeObject . ' \
      'FILTER(?attributeProperty = <http://goo.org/default/name>)  } UNION  ' \
      '{ ?inverseAttributeObject ?attributeProperty ?id . ' \
      'FILTER(?attributeProperty = <http://goo.org/default/university>)  } } }'
    got = sparql_for("virtuoso") { University.where(name: "Stanford").include(:name, :programs).all }
    assert_equal expected, got
  end

  def test_include_direct_uses_filter_on_allegrograph
    # AllegroGraph takes the FILTER branch like Virtuoso; lock it (review T-12).
    expected =
      'SELECT DISTINCT ?id ?attributeProperty ?attributeObject ' \
      'FROM <http://goo.org/default/University> ' \
      'WHERE { ?id a <http://goo.org/default/University> . ' \
      '?id <http://goo.org/default/name> "Stanford" . ' \
      'OPTIONAL { { ?id ?attributeProperty ?attributeObject . ' \
      'FILTER(?attributeProperty = <http://goo.org/default/name>)  } } }'
    got = sparql_for("allegrograph") { University.where(name: "Stanford").include(:name).all }
    assert_equal expected, got
  end

  def test_filter_and_include_order_filter_before_union_bind
    # A real FILTER plus an include: the union-with-bind OPTIONAL must render AFTER the
    # filter (locks the ordering preserved by QueryBuilder#apply_union_with_bind).
    expected =
      'SELECT DISTINCT ?id ?attributeProperty ?attributeObject ?inverseAttributeObject ' \
      'FROM <http://goo.org/default/University> FROM <http://goo.org/default/Program> ' \
      'WHERE { ?id a <http://goo.org/default/University> . ' \
      '?id <http://goo.org/default/name> ?internal_join_var_0 . ' \
      'FILTER(str(?internal_join_var_0) =  "Stanford") ' \
      'OPTIONAL { { ?attributeObject <http://goo.org/default/university> ?id . ' \
      'BIND( "programs" as ?attributeProperty) } } }'
    got = sparql_for("4store") do
      University.where.filter(Goo::Filter.new(:name) == "Stanford").include(:programs).all
    end
    assert_equal expected, got
  end

  # --- additional baseline shapes (backend-agnostic) ----------------------------
  # These don't touch the union-with-bind branches, so they're asserted on one backend.
  # They broaden the golden contract to joins, filters, ordering, counting, paging.

  def test_nested_join_introduces_internal_join_var
    expected =
      'SELECT DISTINCT ?id ' \
      'FROM <http://goo.org/default/Program> FROM <http://goo.org/default/University> ' \
      'WHERE { ?id a <http://goo.org/default/Program> . ' \
      '?id <http://goo.org/default/university> ?internal_join_var_0 . ' \
      '?internal_join_var_0 <http://goo.org/default/name> "Stanford" . }'
    got = sparql_for("4store") { Program.where(university: [name: "Stanford"]).all }
    assert_equal expected, got
  end

  def test_filter_equality
    expected =
      'SELECT DISTINCT ?id FROM <http://goo.org/default/University> ' \
      'WHERE { ?id a <http://goo.org/default/University> . ' \
      '?id <http://goo.org/default/name> ?internal_join_var_0 . ' \
      'FILTER(str(?internal_join_var_0) =  "Stanford") }'
    got = sparql_for("4store") { University.where.filter(Goo::Filter.new(:name) == "Stanford").all }
    assert_equal expected, got
  end

  def test_filter_regex
    expected =
      'SELECT DISTINCT ?id FROM <http://goo.org/default/University> ' \
      'WHERE { ?id a <http://goo.org/default/University> . ' \
      '?id <http://goo.org/default/name> ?internal_join_var_0 . ' \
      'FILTER(REGEX(STR(?internal_join_var_0) , "Stan", "i")) }'
    got = sparql_for("4store") { University.where.filter(Goo::Filter.new(:name).regex("Stan")).all }
    assert_equal expected, got
  end

  def test_order_by
    expected =
      'SELECT DISTINCT ?id FROM <http://goo.org/default/University> ' \
      'WHERE { ?id a <http://goo.org/default/University> . ' \
      'OPTIONAL { ?id <http://goo.org/default/name> ?name . } } ORDER BY ASC(?name)'
    got = sparql_for("4store") { University.where.order_by(name: :asc).all }
    assert_equal expected, got
  end

  def test_count
    expected =
      'SELECT  ( COUNT(DISTINCT ?id) AS ?count_var ) ' \
      'FROM <http://goo.org/default/University> ' \
      'WHERE { ?id a <http://goo.org/default/University> . }'
    got = sparql_for("4store") { University.where.count }
    assert_equal expected, got
  end

  def test_pagination_id_query_is_backend_agnostic
    # page(1,10).all issues a paged id-fetch (then loads those ids); we pin the id-fetch.
    expected =
      'SELECT DISTINCT ?id FROM <http://goo.org/default/University> ' \
      'WHERE { ?id a <http://goo.org/default/University> . } OFFSET 0 LIMIT 10'
    %w[4store virtuoso].each do |backend|
      got = sparql_for(backend) { University.where.include(:name).page(1, 10).all }
      assert_equal expected, got, "paged id-fetch should not vary by backend (#{backend})"
    end
  end
end
