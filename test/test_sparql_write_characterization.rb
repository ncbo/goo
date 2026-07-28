require_relative 'test_case'
require_relative 'models'

# Characterization (golden) tests for the WRITE path -- the INSERT serialization and the
# backend-specific quirks that move to Goo::SPARQL::Ext::VirtuosoCompat in the de-fork
# migration (docs/sparql-client-defork-proposal.md, §3.4 / Phase 5).
#
# Two quirks are pinned here:
#   1. INSERT vs INSERT DATA -- goo passes `use_insert_data: !Goo.backend_vo?` on save
#      (lib/goo/base/resource.rb:297). Virtuoso needs plain `INSERT` (openlink #126);
#      every other backend gets `INSERT DATA`.
#   2. xsd:string forcing -- 4store and Virtuoso require an explicit ^^xsd:string datatype
#      on string literals (SPARQL::Client.serialize_patterns).
#
# Offline by construction: we build the triples from an in-memory model and the update/
# serialization objects directly, so nothing is sent to a triple store. After the quirks
# move into a goo bolt-on, these same strings must still be produced.
class TestSparqlWriteCharacterization < Goo::TestCase
  # Shared GRAPH body for the INSERT assertions: `{ GRAPH <g> { <triples> }}` + newline.
  GRAPH_BODY =
    "{ GRAPH <http://goo.org/default/University> {\n" \
    "<http://goo.org/default/university/Stanford> " \
    "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type> " \
    "<http://goo.org/default/University> .\n" \
    "<http://goo.org/default/university/Stanford> " \
    "<http://goo.org/default/name> \"Stanford\" .\n" \
    "}}\n"

  def insert_data(use_insert_data)
    u = University.new(name: "Stanford")
    triples, = Goo::SPARQL::Triples.model_update_triples(u)
    SPARQL::Client::Update::InsertData.new(triples.to_a,
                                           graph: u.graph,
                                           use_insert_data: use_insert_data).to_s
  end

  # --- INSERT vs INSERT DATA toggle (Virtuoso quirk) ----------------------------

  def test_insert_data_for_non_virtuoso_backends
    assert_equal "INSERT DATA #{GRAPH_BODY}", insert_data(true)
  end

  def test_plain_insert_for_virtuoso
    assert_equal "INSERT  #{GRAPH_BODY}", insert_data(false)
  end

  def test_toggle_is_the_only_difference
    # The `DATA` keyword is the sole change between the two forms; the GRAPH body is identical.
    assert_equal insert_data(false), insert_data(true).sub("INSERT DATA", "INSERT ")
  end

  # --- xsd:string forcing (4store / Virtuoso quirk) -----------------------------

  def serialize(object)
    SPARQL::Client.serialize_patterns([[RDF::URI('http://s'), RDF::URI('http://p'), object]])
  end

  def test_plain_string_literal_is_not_typed
    assert_equal ['<http://s> <http://p> "hi" .'], serialize(RDF::Literal.new("hi"))
  end

  def test_xsd_typed_string_literal_keeps_explicit_datatype
    expected = ['<http://s> <http://p> "hi"^^<http://www.w3.org/2001/XMLSchema#string> .']
    assert_equal expected, serialize(RDF::Literal.new("hi", datatype: RDF::XSD.string))
  end
end
