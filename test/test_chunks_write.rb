require_relative 'test_case'

GooTest.configure_goo

module TestChunkWrite

  ONT_ID = "http:://example.org/data/nemo"

  class TestChunkWrite < MiniTest::Unit::TestCase

    def initialize(*args)
      super(*args)
    end


    def self.before_suite
      _delete
    end

    def self.after_suite
      _delete
    end

    def self._delete
        graph = ONT_ID
        url = Goo.sparql_data_client.url

        #this bypasses the chunks stuff
        params = {
          method: :delete,
          url: "#{url.to_s}#{graph.to_s}",
          timeout: -1
        }
        RestClient::Request.execute(params)
    end

    def test_put_data
      graph = ONT_ID
      ntriples_file_path = "./test/data/nemo_ontology.ntriples"

      result = Goo.sparql_data_client.put_triples(
                            graph,
                            ntriples_file_path,
                            mime_type="application/x-turtle")

      triples_no_bnodes = 25293
      count = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID}> { ?s ?p ?o }}"
      Goo.sparql_query_client.query(count).each do |sol|
        assert sol[:c].object == triples_no_bnodes
      end
      count = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID}> { ?s ?p ?o ."
      count += " FILTER(bnode(?s)) }}"
      Goo.sparql_query_client.query(count).each do |sol|
        binding.pry
        assert sol[:c].object == 0
      end
    end

    def test_put_delete_data
      graph = ONT_ID
      ntriples_file_path = "./test/data/nemo_ontology.ntriples"

      result = Goo.sparql_data_client.put_triples(
                            graph,
                            ntriples_file_path,
                            mime_type="application/x-turtle")

      triples_no_bnodes = 25293
      count = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID}> { ?s ?p ?o }}"
      Goo.sparql_query_client.query(count).each do |sol|
        assert sol[:c].object == triples_no_bnodes
      end
      puts "starting to delete"
      result = Goo.sparql_data_client.delete_graph(graph)
      count = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID}> { ?s ?p ?o }}"
      puts "deleted completed"
      Goo.sparql_query_client.query(count).each do |sol|
        assert sol[:c].object == 0
      end
    end

  end
end
