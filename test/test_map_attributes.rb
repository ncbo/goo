require_relative "test_case"
require_relative './app/models'

# Shapes that Resource.map_attributes gives each kind of value, with and without
# include_languages. The data goes through the triplestore so the unmapped
# values have the shapes the language filter really produces: a Hash keyed by
# language for plain and language-tagged literals, an Array for typed literals
# and URIs.
class MapAttrsThing < Goo::Base::Resource
  model :map_attrs_thing, namespace: :bioportal, name_with: lambda { |k| k.id },
        collection: :db
  attribute :db, enforce: [:database]

  # single-valued
  attribute :deprecated # typed literal
  attribute :seeAlso    # URI
  attribute :prefLabel  # language-tagged literal
  attribute :status     # plain literal
  attribute :code       # typed literal, only through an equivalent predicate

  # list
  attribute :counts, enforce: [:list]      # typed literals
  attribute :related, enforce: [:list]     # URIs
  attribute :synonym, enforce: [:list]     # language-tagged literals
  attribute :allSynonyms, enforce: [:list] # two equivalent predicates, both language maps
  attribute :scores, enforce: [:list]      # two equivalent predicates, one typed, one tagged
end

class TestMapAttributes < Goo::TestCase
  THING_ID = RDF::URI.new("http://data.bioontology.org/map_attrs_1")
  # only has :scores, whose sub-properties give an Array and a Hash
  MIXED_THING_ID = RDF::URI.new("http://data.bioontology.org/map_attrs_2")

  def before_all
    @@graph = RDF::URI.new(Test::Models::DATA_ID)
    database = Test::Models::Database.new
    database.id = @@graph
    database.name = "map_attributes test data"
    database.save unless database.exist?
    @@db = Test::Models::Database.find(@@graph).first

    Goo.sparql_data_client.put_triples(@@graph, "./test/data/map_attributes.nt", "application/x-turtle")
  end

  def after_all
    Goo.sparql_data_client.delete_graph(@@graph)
    database = Test::Models::Database.find(@@graph).first
    database.delete if database
    RequestStore.store[:requested_lang] = Goo.main_languages.first
  end

  def setup
    RequestStore.store[:requested_lang] = Goo.main_languages.first
  end

  def test_include_languages_keeps_single_values_single
    RequestStore.store[:requested_lang] = :ALL
    thing = mapped_thing(include_languages: true)

    assert_equal true, thing.deprecated
    assert_equal RDF::URI.new("http://example.org/see_also"), thing.seeAlso
    assert_equal "A01", thing.code
    # one value per language, as the language filter gives loaded models
    assert_equal({ en: "Label" }, thing.prefLabel(include_languages: true))
    assert_equal "Label", thing.prefLabel
    assert_equal({ "@none" => "true" }, thing.status(include_languages: true))
    assert_equal "true", thing.status
  end

  def test_include_languages_list_values
    RequestStore.store[:requested_lang] = :ALL
    thing = mapped_thing(include_languages: true)

    assert_equal [1, 2], thing.counts.sort
    assert_equal %w[http://example.org/related_a http://example.org/related_b],
                 thing.related.map(&:to_s).sort
    assert_equal({ en: ["colour"], fr: ["couleur"] }, thing.synonym(include_languages: true))
    assert_equal %w[colour couleur], thing.synonym.sort
  end

  def test_include_languages_merges_equivalent_predicates
    RequestStore.store[:requested_lang] = :ALL
    thing = mapped_thing(include_languages: true)

    # both sub-properties contribute, not only the first one found
    assert_equal({ en: %w[exact related], "@none" => ["untagged"] },
                 sorted_language_map(thing.allSynonyms(include_languages: true)))
  end

  def test_include_languages_merges_typed_and_tagged_equivalent_predicates
    RequestStore.store[:requested_lang] = :ALL
    thing = mapped_thing(MIXED_THING_ID, include_languages: true)

    # a typed sub-property next to a language-tagged one goes under "@none"
    assert_equal({ "@none" => [7], en: ["seven"] }, thing.scores(include_languages: true))
  end

  def test_default_portal_language
    thing = mapped_thing

    assert_default_single_values(thing)
    assert_equal ["colour"], thing.synonym
    assert_equal %w[exact related untagged], thing.allSynonyms.sort
    assert_equal ["7", "seven"], mapped_thing(MIXED_THING_ID).scores.map(&:to_s).sort
  end

  def test_default_all_languages
    RequestStore.store[:requested_lang] = :ALL
    thing = mapped_thing

    assert_default_single_values(thing)
    assert_equal %w[colour couleur], thing.synonym.sort
    assert_equal %w[exact related untagged], thing.allSynonyms.sort
    assert_equal ["7", "seven"], mapped_thing(MIXED_THING_ID).scores.map(&:to_s).sort
  end

  private

  def mapped_thing(id = THING_ID, **options)
    where = MapAttrsThing.find(id).in(@@db).include(:unmapped)
    thing = where.first
    refute_nil thing
    MapAttrsThing.map_attributes(thing, where.equivalent_predicates, **options)
    thing
  end

  def assert_default_single_values(thing)
    assert_equal true, thing.deprecated
    assert_equal RDF::URI.new("http://example.org/see_also"), thing.seeAlso
    assert_equal "Label", thing.prefLabel
    assert_equal "true", thing.status
    assert_equal "A01", thing.code
    assert_equal [1, 2], thing.counts.sort
    assert_equal %w[http://example.org/related_a http://example.org/related_b],
                 thing.related.map(&:to_s).sort
  end

  def sorted_language_map(map)
    map.transform_values(&:sort)
  end
end
