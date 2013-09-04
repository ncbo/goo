require_relative 'test_case'

GooTest.configure_goo

module TestChunkWrite

  ONT_ID = "http:://example.org/data/nemo"
  ONT_ID_EXTRA = "http:://example.org/data/nemo/extra"

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
        graphs = [ONT_ID,ONT_ID_EXTRA]
        url = Goo.sparql_data_client.url
        graphs.each do |graph|
          #this bypasses the chunks stuff
          params = {
            method: :delete,
            url: "#{url.to_s}#{graph.to_s}",
            timeout: -1
          }
        RestClient::Request.execute(params)
        end
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

    def test_reentrant_queries
      ntriples_file_path = "./test/data/nemo_ontology.ntriples"
      #by pass in chunks
      url = Goo.sparql_data_client.url
      params = {
        method: :put,
        url: "#{url.to_s}#{ONT_ID}",
        payload: File.read(ntriples_file_path),
        headers: {content_type: "application/x-turtle"},
        timeout: -1
      }
      RestClient::Request.execute(params)

      tput = Thread.new {
        result = Goo.sparql_data_client.put_triples(
                            ONT_ID_EXTRA,
                            ntriples_file_path,
                            mime_type="application/x-turtle")
      }
      sleep(1.5)
      count_queries = 0
      tq = Thread.new { 
       5.times do 
         oq = "SELECT (count(?s) as ?c) WHERE { ?s a ?o }"
         Goo.sparql_query_client.query(oq).each do |sol|
           assert sol[:c].object > 0
         end
         count_queries += 1
       end
      }
 
      tq.join
      assert tput.alive?
      assert count_queries == 5
      tput.join
 
      triples_no_bnodes = 25293
      count = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID_EXTRA}> { ?s ?p ?o }}"
      Goo.sparql_query_client.query(count).each do |sol|
        assert sol[:c].object == triples_no_bnodes
      end
 
      tdelete = Thread.new {
        Goo.sparql_data_client.delete_graph(ONT_ID_EXTRA)
      }
      sleep(1.5)
      count_queries = 0
      tq = Thread.new { 
       5.times do 
         oq = "SELECT (count(?s) as ?c) WHERE { ?s a ?o }"
         Goo.sparql_query_client.query(oq).each do |sol|
           assert sol[:c].object > 0
         end
         count_queries += 1
       end
      }
      tq.join
      assert tdelete.alive?
      assert count_queries == 5
      tdelete.join
      count = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID_EXTRA}> { ?s ?p ?o }}"
      puts "deleted completed"
      Goo.sparql_query_client.query(count).each do |sol|
        assert sol[:c].object == 0
      end
    end

  end
end
