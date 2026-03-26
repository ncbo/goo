require_relative 'test_case'

module TestSearch

  class TermSearch < Goo::Base::Resource
    model :term_search, name_with: lambda { |resource| uuid_uri_generator(resource) }
    attribute :prefLabel, enforce: [:existence]
    attribute :synonym, enforce: [:list] # array of strings
    attribute :definition  # array of strings
    attribute :submissionAcronym, enforce: [:existence]
    attribute :submissionId, enforce: [:existence, :integer]

    # Dummy attributes to validate non-searchable files
    attribute :semanticType
    attribute :cui

    enable_indexing(:term_search) do | schema_generator |
      schema_generator.add_field(:prefLabel, 'text_general', indexed: true, stored: true, multi_valued: false)
      schema_generator.add_field(:synonym, 'text_general', indexed: true, stored: true, multi_valued: true)
      schema_generator.add_field(:definition, 'string', indexed: true, stored: true, multi_valued: true)
      schema_generator.add_field(:submissionAcronym, 'string', indexed: true, stored: true, multi_valued: false)
      schema_generator.add_field(:submissionId, 'pint', indexed: true, stored: true, multi_valued: false)
      schema_generator.add_field(:cui, 'text_general', indexed: true, stored: true, multi_valued: true)
      schema_generator.add_field(:semanticType, 'text_general', indexed: true, stored: true, multi_valued: true)

      # Copy fields for term search
      schema_generator.add_copy_field('prefLabel', '_text_')
      # for exact search
      schema_generator.add_copy_field('prefLabel', 'prefLabelExact')

      # Matches whole terms in the suggest text
      schema_generator.add_copy_field('prefLabel', 'prefLabelSuggest')

      # Will match from the left of the field, e.g. if the document field
      # is "A brown fox" and the query is "A bro", it will match, but not "brown"
      schema_generator.add_copy_field('prefLabel', 'prefLabelSuggestEdge')

      # Matches any word in the input field, with implicit right truncation.
      # This means that the field "A brown fox" will be matched by query "bro".
      # We use this to get partial matches, but these would be boosted lower than exact and left-anchored
      schema_generator.add_copy_field('prefLabel', 'prefLabelSuggestNgram')

      schema_generator.add_copy_field('synonym', '_text_')
      schema_generator.add_copy_field('synonym', 'synonymExact')
      schema_generator.add_copy_field('synonym', 'synonymSuggest')
      schema_generator.add_copy_field('synonym', 'synonymSuggestEdge')
      schema_generator.add_copy_field('synonym', 'synonymSuggestNgram')
    end

    def index_id()
      "#{self.id.to_s}_#{self.submissionAcronym}_#{self.submissionId}"
    end

    def index_doc(to_set = nil)
      self.to_hash
    end
  end

  class TermSearch2 < Goo::Base::Resource
    model :term_search2, name_with: :prefLabel
    attribute :prefLabel, enforce: [:existence], fuzzy_search: true
    attribute :synonym, enforce: [:list]
    attribute :definition
    attribute :submissionAcronym, enforce: [:existence]
    attribute :submissionId, enforce: [:existence, :integer]
    attribute :private, enforce: [:boolean], default: false, index: false
    # Dummy attributes to validate non-searchable files
    attribute :semanticType
    attribute :cui

    enable_indexing(:test_solr)
  end

  class TermSearch3 < Goo::Base::Resource
    model :term_search3, name_with: :prefLabel
    attribute :prefLabel, enforce: [:existence]
    attribute :synonym, enforce: [:list]
    attribute :definition
    attribute :submissionAcronym, enforce: [:existence]
    attribute :submissionId, enforce: [:existence, :integer]
    attribute :private, enforce: [:boolean], default: false, index: false
    # Dummy attributes to validate non-searchable files
    attribute :semanticType
    attribute :cui

    attribute :object, enforce: [:term_search]
    attribute :object_list, enforce: [:term_search, :list]


    enable_indexing(:test_solr)
  end

  class TestModelSearch < MiniTest::Unit::TestCase

    def self.before_suite
      Goo.init_search_connections(true)
    end
    def setup
      @terms = [
        TermSearch.new(
          id: RDF::URI.new("http://ncicb.nci.nih.gov/xml/owl/EVS/Thesaurus.owl#Melanoma"),
          prefLabel: "Melanoma",
          synonym: [
            "Cancerous Melanoma",
            "Skin Cancer",
            "Malignant Melanoma"
          ],
          definition: "Melanoma refers to a malignant skin cancer",
          submissionAcronym: "NCIT",
          submissionId: 2,
          semanticType: "Neoplastic Process",
          cui: "C0025202"
        ),
        TermSearch.new(
          id: RDF::URI.new("http://ncicb.nci.nih.gov/xml/owl/EVS/Thesaurus.owl#Neoplasm"),
          prefLabel: "Neoplasm",
          synonym: [
            "tumor",
            "肿瘤",
            "Neoplasms",
            "NEOPLASMS BENIGN",
            "MALIGNANT AND UNSPECIFIED (INCL CYSTS AND POLYPS)",
            "Neoplasia",
            "Neoplastic Growth"
          ],
          definition: "A benign or malignant tissue growth resulting from uncontrolled cell proliferation. "\
            "Benign neoplastic cells resemble normal cells without exhibiting significant cytologic atypia, while "\
            "malignant cells exhibit overt signs such as dysplastic features, atypical mitotic figures, necrosis, "\
            "nuclear pleomorphism, and anaplasia. Representative examples of benign neoplasms include papillomas, "\
            "cystadenomas, and lipomas; malignant neoplasms include carcinomas, sarcomas, lymphomas, and leukemias.",
          submissionAcronym: "NCIT",
          submissionId: 2,
          semanticType: "Neoplastic Process",
          cui: "C0375111"
        ),
        TermSearch.new(
          id: RDF::URI.new("http://ncicb.nci.nih.gov/xml/owl/EVS/Thesaurus.owl#Melanoma2"),
          prefLabel: "Melanoma with cutaneous melanoma syndrome",
          synonym: [
            "Cutaneous Melanoma",
            "Melanocytes Skin Cancer",
            "Malignant Melanoma"
          ],
          definition: "Melanoma refers to a malignant skin cancer",
          submissionAcronym: "NCIT",
          submissionId: 2,
          semanticType: "Neoplastic Process",
          cui: "C0025202"
        ),
      ]
    end

    def initialize(*args)
      super(*args)
    end

    def test_search_collection_target_defaults_to_logical_name
      assert_equal :term_search, Goo.search_collection_target(:term_search)
    end

    def test_search_collection_target_can_be_overridden
      Goo.add_search_connection(:logical_search_test, :main, target_collection: :physical_search_test)

      assert_equal :physical_search_test, Goo.search_collection_target(:logical_search_test)

      Goo.set_search_collection_target(:logical_search_test, :physical_search_test_v2)

      assert_equal :physical_search_test_v2, Goo.search_collection_target(:logical_search_test)
    end

    def test_promote_search_alias_retargets_logical_connection
      logical_collection = :logical_alias_search
      alias_name = :logical_alias_search_active
      initial_collection = :logical_alias_search_v1
      promoted_collection = :logical_alias_search_v2

      Goo.add_search_connection(logical_collection, :main, target_collection: alias_name)
      admin_connector = SOLR::SolrConnector.new(Goo.search_conf, alias_name)

      begin
        admin_connector.delete_alias(alias_name)
        admin_connector.delete_collection(initial_collection)
        admin_connector.delete_collection(promoted_collection)
        admin_connector.create_collection(initial_collection)
        admin_connector.create_collection(promoted_collection)

        Goo.init_search_connection(logical_collection, :main, nil, force: true, target_collection: initial_collection)
        assert_equal initial_collection, Goo.search_client(logical_collection).collection_name.to_sym

        Goo.promote_search_alias(logical_collection, promoted_collection, alias_name: alias_name)

        assert_equal [promoted_collection.to_s], admin_connector.resolve_alias(alias_name)
        assert_equal alias_name, Goo.search_collection_target(logical_collection)
        assert_equal alias_name, Goo.search_client(logical_collection).collection_name.to_sym
      ensure
        Goo.reset_search_connection(logical_collection)
        admin_connector.delete_alias(alias_name)
        admin_connector.delete_collection(initial_collection)
        admin_connector.delete_collection(promoted_collection)
      end
    end

    def test_search
      TermSearch.indexClear()
      @terms[1].index()
      TermSearch.indexCommit()
      resp = TermSearch.search(@terms[1].prefLabel)
      assert_equal(1, resp["response"]["docs"].length)
      assert_equal @terms[1].prefLabel, resp["response"]["docs"][0]["prefLabel"]
    end

    def test_search_filters
      TermSearch.indexClear
      @terms[0].index
      @terms[1].index
      @terms[2].index
      TermSearch.indexCommit
      params = {"defType"=>"edismax",
                 "stopwords"=>"true",
                 "lowercaseOperators"=>"true",
                 "qf"=>"prefLabelExact^100 prefLabelSuggestEdge^50 synonymSuggestEdge^10 prefLabelSuggestNgram synonymSuggestNgram resource_id cui semanticType",
                 "pf"=>"prefLabelSuggest^50",
                 }
      resp = TermSearch.search("Cutaneous Melanoma", params)
      assert_equal(2, resp["response"]["numFound"])
      assert_equal @terms[2].prefLabel, resp["response"]["docs"][0]["prefLabel"]

      # test NOT filtering out unicode characters
      resp = TermSearch.search("肿瘤", params)
      assert_equal(1, resp["response"]["numFound"])
      assert_equal @terms[1].prefLabel, resp["response"]["docs"][0]["prefLabel"]
    end

    def test_search_exact_filter
      TermSearch.indexClear
      @terms[0].index
      @terms[1].index
      @terms[2].index
      TermSearch.indexCommit
      params = {"defType"=>"edismax",
                "stopwords"=>"true",
                "lowercaseOperators"=>"true",
                "qf"=>"prefLabelExact",
      }
      resp = TermSearch.search("Melanoma", params)
      assert_equal(1, resp["response"]["numFound"])
      assert_equal @terms[0].prefLabel, resp["response"]["docs"][0]["prefLabel"]
    end

    def test_search_suggest_edge_filter
      TermSearch.indexClear
      @terms[0].index
      @terms[1].index
      @terms[2].index
      TermSearch.indexCommit
      params = {"defType"=>"edismax",
                "stopwords"=>"true",
                "lowercaseOperators"=>"true",
                "qf"=>"prefLabelSuggestEdge",
      }
      resp = TermSearch.search("Melanoma with", params)
      assert_equal(1, resp["response"]["numFound"])
      assert_equal @terms[2].prefLabel, resp["response"]["docs"][0]["prefLabel"]

      resp = TermSearch.search("Melanoma", params)
      assert_equal(2, resp["response"]["numFound"])
      assert_equal @terms[0].prefLabel, resp["response"]["docs"][0]["prefLabel"]
    end

    def test_search_suggest_ngram_filter
      TermSearch.indexClear
      @terms[0].index
      @terms[1].index
      @terms[2].index
      TermSearch.indexCommit

      params = {"defType"=>"edismax",
                "stopwords"=>"true",
                "lowercaseOperators"=>"true",
                "qf"=>"prefLabelSuggestNgram",
      }
      resp = TermSearch.search("cutaneous", params)
      assert_equal(1, resp["response"]["numFound"])
      assert_equal @terms[2].prefLabel, resp["response"]["docs"][0]["prefLabel"]

      resp = TermSearch.search("eous", params)
      assert_equal(0, resp["response"]["numFound"])
    end

    def test_search_suggest_filter
      TermSearch.indexClear
      @terms[0].index
      @terms[1].index
      @terms[2].index
      TermSearch.indexCommit
      params = {"defType"=>"edismax",
                "stopwords"=>"true",
                "lowercaseOperators"=>"true",
                "qf"=>"prefLabelSuggest",
      }
      resp = TermSearch.search("cutaneous test with Neoplasm Melanoma", params)
      assert_equal(3, resp["response"]["numFound"])


      resp = TermSearch.search("mel", params)
      assert_equal(0, resp["response"]["numFound"])
    end

    def test_unindex
      TermSearch.indexClear()
      @terms[1].index()
      TermSearch.indexCommit()
      resp = TermSearch.search(@terms[1].prefLabel)
      assert_equal(1, resp["response"]["docs"].length)

      @terms[1].unindex()
      TermSearch.indexCommit()
      resp = TermSearch.search(@terms[1].prefLabel)
      assert_equal(0, resp["response"]["docs"].length)
    end

    def test_unindexByQuery
      TermSearch.indexClear()
      @terms[1].index()
      TermSearch.indexCommit()
      resp = TermSearch.search(@terms[1].prefLabel)
      assert_equal 1, resp["response"]["docs"].length

      query = "submissionAcronym:" + @terms[1].submissionAcronym
      TermSearch.unindexByQuery(query)
      TermSearch.indexCommit()

      resp = TermSearch.search(@terms[1].prefLabel)
      assert_equal 0, resp["response"]["docs"].length
    end

    def test_index
      TermSearch.indexClear()
      @terms[0].index()
      TermSearch.indexCommit()
      resp = TermSearch.search(@terms[0].prefLabel)
      assert_equal 1, resp["response"]["docs"].length
      assert_equal @terms[0].prefLabel, resp["response"]["docs"][0]["prefLabel"]
    end

    def test_indexBatch
      TermSearch.indexClear()
      TermSearch.indexBatch(@terms)
      TermSearch.indexCommit()
      resp = TermSearch.search("*:*")
      assert_equal @terms.size, resp["response"]["docs"].length
    end

    def test_unindexBatch
      TermSearch.indexClear()
      TermSearch.indexBatch(@terms)
      TermSearch.indexCommit()
      resp = TermSearch.search("*:*")
      assert_equal @terms.size, resp["response"]["docs"].length

      TermSearch.unindexBatch(@terms)
      TermSearch.indexCommit()
      resp = TermSearch.search("*:*")
      assert_equal 0, resp["response"]["docs"].length
    end

    def test_indexClear
      TermSearch.indexClear()
      TermSearch.indexCommit()
      resp = TermSearch.search("*:*")
      assert_equal 0, resp["response"]["docs"].length
    end

    def test_index_on_save_delete
      TermSearch2.find("test").first&.delete
      TermSearch3.find("test2").first&.delete

      term = TermSearch2.new(prefLabel: "test",
                            submissionId: 1,
                            definition: "definition of test",
                            synonym: ["synonym1", "synonym2"],
                            submissionAcronym: "test",
                            private: true
      )

      term2 = TermSearch3.new(prefLabel: "test2",
                              submissionId: 1,
                              definition: "definition of test2",
                              synonym: ["synonym1", "synonym2"],
                              submissionAcronym: "test",
                              private: true,
                              object: TermSearch.new(prefLabel: "test", submissionAcronym: 'acronym', submissionId: 1 ).save,
                              object_list: [TermSearch.new(prefLabel: "test2",submissionAcronym: 'acronym2', submissionId: 2).save,
                                            TermSearch.new(prefLabel: "test3", submissionAcronym: 'acronym3', submissionId: 3).save]
      )

      term.save
      term2.save

      # set as not indexed in model definition
      refute_includes TermSearch2.search_client.fetch_all_fields.map{|f| f["name"]}, "private_b"
      refute_includes TermSearch2.search_client.fetch_all_fields.map{|f| f["name"]}, "private_b"


      indexed_term = TermSearch2.search("id:#{term.id.to_s.gsub(":", "\\:")}")["response"]["docs"].first
      indexed_term2 = TermSearch3.search("id:#{term2.id.to_s.gsub(":", "\\:")}")["response"]["docs"].first

      term.indexable_object.each do |k, v|
        assert_equal v, indexed_term[k.to_s]
      end

      term2.indexable_object.each do |k, v|
        assert_equal v, indexed_term2[k.to_s]
      end

      term2.definition = "new definition of test2"
      term2.synonym = ["new synonym1", "new synonym2"]
      term2.save

      indexed_term2 = TermSearch3.search("id:#{term2.id.to_s.gsub(":", "\\:")}")["response"]["docs"].first

      term2.indexable_object.each do |k, v|
        assert_equal v, indexed_term2[k.to_s]
      end

      term2.delete
      term.delete

      indexed_term = TermSearch2.submit_search_query("id:#{term.id.to_s.gsub(":", "\\:")}")["response"]["docs"].first
      indexed_term2 = TermSearch3.submit_search_query("id:#{term2.id.to_s.gsub(":", "\\:")}")["response"]["docs"].first

      assert_nil indexed_term
      assert_nil indexed_term2

    end
  end

end
