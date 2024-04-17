require_relative 'test_case'

module TestSchemaless

  ONT_ID = "http:://example.org/data/nemo"

  class Ontology < Goo::Base::Resource
    model :ontology, name_with: lambda { |k| k.id }
    attribute :name
  end 

  class Klass < Goo::Base::Resource
    model :class, namespace: :owl, name_with: :id,
           collection: :ontology
    attribute :ontology, enforce: [:ontology]

    attribute :label, namespace: :skos, property: :prefLabel, alias: true
    attribute :synonym, namespace: :skos, property: :altLabel, enforce: [:list], alias: true
    attribute :definition, namespace: :skos, enforce: [:list], alias: true
    attribute :comment, namespace: :nemo, enforce: [:list]
    attribute :onto_definition, namespace: :nemo, enforce: [:list]
    attribute :parents, namespace: :rdfs, property: :subClassOf,
                        enforce: [:class, :list]
  end

  class TestSchemaless < MiniTest::Unit::TestCase

    def initialize(*args)
      super(*args)
    end


    def self.before_suite
      _delete
      graph = RDF::URI.new(ONT_ID)

      ont = Ontology.new
      ont.id = RDF::URI.new ONT_ID
      ont.name = "some ont"
      ont.save unless ont.exist?

      ntriples_file_path = "./test/data/nemo_ontology.ntriples"

      result = Goo.sparql_data_client.put_triples(
                            graph,
                            ntriples_file_path,
                            mime_type="application/x-turtle")

      col = Goo::Collection.new(graph)
      col.alias_attributes(Goo.vocabulary(:nemo)[:pref_label], Goo.vocabulary(:metadata)[:prefLabel])
      col.alias_attributes(Goo.vocabulary(:metadata)[:prefLabel], Goo.vocabulary(:skos)[:prefLabel])

      col.alias_attributes(Goo.vocabulary(:nemo)[:synonym], Goo.vocabulary(:metadata)[:synonym])
      col.alias_attributes(Goo.vocabulary(:metadata)[:synonym], Goo.vocabulary(:skos)[:altLabel])

      col.alias_attributes(Goo.vocabulary(:nemo)[:definition], Goo.vocabulary(:skos)[:definition])
    end

    def self._delete
      graph = RDF::URI.new(ONT_ID)
      result = Goo.sparql_data_client.delete_graph(graph)
      ont = Ontology.find(ONT_ID).first
      ont.delete if ont
    end

    def self.after_suite
      _delete
    end

    def test_alias_props
      ontology = Ontology.find(RDF::URI.new(ONT_ID)).first
      cognition_term = RDF::URI.new( 
          "http://purl.bioontology.org/NEMO/ontology/NEMO.owl#NEMO_5400000")
      k = Klass.find(cognition_term).in(ontology).include(:label,:synonym,:definition).first
      assert k.label == nil #it has rdfs:label but no nemo:pref_label
      assert k.definition == ["a cognitive_process is a mental process engaging one or more systems in the intermediary or integrative processing of signals from the internal (visceral) and external (somatic) environments. It is often the result of a sensory_process (bottom-up cognition). It may be mediated by an emotion_process (motivated cognition) or by another cognitive_process, such as memory or expectancy based on prior experience (top-down cognition)."]

      assert k.synonym.sort == 
            ["http://ontology.neuinfo.org/NIF/Function/NIF-Function.owl#birnlex_1800",
             "cognition"].sort

      pato = RDF::URI.new("http://purl.org/obo/owl/PATO#PATO_0000051")
      k = Klass.find(pato).in(ontology).include(:label,:synonym,:definition).first
      assert k.label == "morphology"
      assert k.definition == ["A quality of a single physical entity inhering in the bearer by virtue of the bearer's size, shape and structure."]
      assert k.synonym == []
    end

    def test_find_include_schemaless
      ontology = Ontology.find(RDF::URI.new(ONT_ID)).first
      cognition_term = RDF::URI.new( 
          "http://purl.bioontology.org/NEMO/ontology/NEMO.owl#NEMO_5400000")
      k = Klass.find(cognition_term).in(ontology).first
      assert k.id.to_s == cognition_term 
      assert_raises Goo::Base::AttributeNotLoaded do
        k.label
      end
      k = Klass.find(cognition_term).in(ontology).include(:label).first
      assert k.ontology.id == ONT_ID
      assert k.id.to_s == cognition_term 
      assert k.label == nil
      assert_raises Goo::Base::AttributeNotLoaded do
        k.definition
      end
      k = Klass.find(cognition_term).in(ontology).include(Klass.attributes).first
      assert k.label == nil
      assert k.definition.length == 1
      assert k.definition.first["a cognitive_process is a mental process"]
      assert k.synonym.sort == ["cognition",
 "http://ontology.neuinfo.org/NIF/Function/NIF-Function.owl#birnlex_1800"]
      assert k.comment == []
      assert k.parents.length == 1
      assert k.parents.first.id.to_s == 
        "http://purl.bioontology.org/NEMO/ontology/NEMO.owl#NEMO_4320000"

      where = Klass.find(cognition_term).in(ontology).include(:unmapped)
      k =  where.first
      enter = 0

      assert k.unmapped.keys.include?(Goo.vocabulary(:nemo)[:definition])

      k.unmapped.each do |p,vals|
        if p.to_s == Goo.vocabulary(:nemo)[:synonym].to_s
          enter += 1
          vals.map { |sy| sy.object }.sort == 
            ["cognition",
             "http://ontology.neuinfo.org/NIF/Function/NIF-Function.owl#birnlex_1800"]
        end
        if p.to_s == Goo.vocabulary(:nemo)[:onto_definition].to_s
          enter += 1
          vals.first.object == 
            "mental_process is a brain_physiological_process that...[incomplete]"
        end
        if p.to_s == Goo.vocabulary(:rdfs)[:label].to_s
          vals.first.object == "working_memory"
          enter += 1
        end
      end
      assert enter == 3
      assert_raises Goo::Base::AttributeNotLoaded do
        k.label
      end
      Klass.map_attributes(k,where.equivalent_predicates)
      assert k.label == nil
      assert k.definition.length == 1
      assert k.definition.first["a cognitive_process is a mental process"]
      assert k.onto_definition.first["mental_process is a brain_ph"]
      assert k.synonym.sort == ["cognition",
 "http://ontology.neuinfo.org/NIF/Function/NIF-Function.owl#birnlex_1800"]
      assert k.comment == []
      assert k.parents.length == 1
      assert_instance_of Klass, k.parents.first
      assert k.parents.first.id.to_s == 
        "http://purl.bioontology.org/NEMO/ontology/NEMO.owl#NEMO_4320000"

    end


    def test_find_parent_labels
      ontology = Ontology.find(RDF::URI.new(ONT_ID)).first
      cognition_term = 
        RDF::URI.new "http://purl.bioontology.org/NEMO/ontology/NEMO.owl#NEMO_5400000"
      k = Klass.find(cognition_term).in(ontology).include(parents: [:label]).first
      assert k.parents.first.label == nil
    end


    def test_index_order_by
      #TODO: index not supported
      return

      ontology = Ontology.find(RDF::URI.new(ONT_ID)).first

      Klass.in(ontology).order_by(label: :asc).index_as("my_ontology_by_labels")

      first_page = Klass
                      .in(ontology)
                      .with_index("my_ontology_by_labels")
                      .include(:label, :synonym)
                      .page(1, 100).all

      prev_label = nil
      first_page.each do |k|
        (assert prev_label <= k.label) if prev_label
        prev_label = k.label
      end

    end
    
    def test_all_pages_loop
      ontology = Ontology.find(RDF::URI.new(ONT_ID)).first
      page = 1
      count = 0
      begin
        paging = Klass.in(ontology).page(page,50).all
        count += paging.size
        page = paging.next_page if paging.next?
      end while(paging.next?)

      assert_equal count, Klass.in(ontology).count
    end
    def test_page_reuse_predicates
      ontology = Ontology.find(RDF::URI.new(ONT_ID)).first
      paging = Klass.in(ontology).include(:unmapped).page(1,100)
      predicates_array = nil
      total = 0
      all_ids = []
      begin
        if paging.instance_variable_get("@page_i") > 1
          #we test that the predicates array is always the same object.
          assert predicates_array.object_id == 
            paging.instance_variable_get("@predicates").object_id
        end

        page = paging.to_a

        if paging.instance_variable_get("@page_i") == 1
          predicates_array = paging.instance_variable_get("@predicates")
        end
        page.each do |k|
          all_ids << k.id
        end
        total += page.length
        paging.page(page.next_page, 100) if page.next?
        assert page.aggregate == 1713
      end while(page.next?)
      assert all_ids.length == all_ids.uniq.length
      assert total == 1713
    end

    def test_index_roots
      #TODO: index not supported
      return
      ontology = Ontology.find(RDF::URI.new(ONT_ID)).first
      f = Goo::Filter.new(:parents).unbound
      Klass.in(ontology)
                .filter(f)
                .index_as("my_ontology_roots")

      roots = Klass.in(ontology)
                .with_index("my_ontology_roots")
                .include(:label)
                .all
      roots.each do |r|
        #roots have no parents
        assert Klass.find(r.id).in(ontology).include(:parents).first.parents == []
      end
    end
  end
end
