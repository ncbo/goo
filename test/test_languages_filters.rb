require_relative "test_case"
require_relative './app/models'



class ExamplePerson < Goo::Base::Resource
  model :person, namespace: :bioportal, name_with: lambda { |k| k.id },
        collection: :db
  attribute :db, enforce: [ :database ]
  attribute :label, namespace: :rdf, enforce: [ :list ]
end

class ExamplePlace < Goo::Base::Resource
  model :place, namespace: :bioportal, name_with: lambda { |k| k.id },
        collection: :db
  attribute :db, enforce: [ :database ]
  attribute :label, namespace: :rdf, enforce: [ :list ]
end

class TestLanguageFilter < Goo::TestCase
  def before_all
    RequestStore.store[:requested_lang] = Goo.main_languages.first
    graph = RDF::URI.new(Test::Models::DATA_ID)

    database = Test::Models::Database.new
    database.id = graph
    database.name = "Census tiger 2002"
    database.save

    @@db = Test::Models::Database.find(RDF::URI.new(Test::Models::DATA_ID)).first
    @@person_id = RDF::URI.new "http://data.bioontology.org/resource1"


    ntriples_file_path = "./test/data/languages.nt"

    Goo.sparql_data_client.put_triples(
      graph,
      ntriples_file_path,
      mime_type = "application/x-turtle")
  end

  def after_all
    graph = RDF::URI.new(Test::Models::DATA_ID)
    Goo.sparql_data_client.delete_graph(graph)
    database = Test::Models::Database.find(RDF::URI.new(Test::Models::DATA_ID)).first
    database.delete if database
    RequestStore.store[:requested_lang] = Goo.main_languages.first
  end

  def setup
    RequestStore.store[:requested_lang] = Goo.main_languages.first
  end

  def test_one_language
    # by default english and not tagged values
    person = ExamplePerson.find(@@person_id).in(@@db).include(:label).first
    assert_equal ["John Doe", "Juan Pérez"].sort, person.label.sort


    # select french, return french values and not tagged values
    RequestStore.store[:requested_lang] = :fr
    person = ExamplePerson.find(@@person_id).in(@@db).include(:label).first
    assert_equal ["Jean Dupont", "Juan Pérez"].sort, person.label.sort

  end

  def test_multiple_languages
    # select all languages
    RequestStore.store[:requested_lang] = :all
    expected_result = {:en=>["John Doe"], :fr=>["Jean Dupont"], "@none"=>["Juan Pérez"]}
    person = ExamplePerson.find(@@person_id).in(@@db).include(:label).first
    assert_equal expected_result.values.flatten.sort, person.label.sort

    # using include_languages on any attribute returns an hash of {language: values} instead of the array of values
    assert_equal expected_result, person.label(include_languages: true)

    # filter only french, english and not tagged values
    RequestStore.store[:requested_lang] = [:fr, :en]
    person = ExamplePerson.find(@@person_id).in(@@db).include(:label).first
    assert_equal expected_result.values.flatten.sort.sort, person.label.sort
    assert_equal expected_result, person.label(include_languages: true)
  end


  def test_language_not_found
    RequestStore.store[:requested_lang] = :ar
    person = ExamplePerson.find(@@person_id).in(@@db).include(:label).first
    # will return only not tagged values if existent
    assert_equal ["Juan Pérez"], person.label
  end
end
