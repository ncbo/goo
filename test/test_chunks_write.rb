require_relative 'test_case'

module TestChunkWrite
  ONT_ID = "http://example.org/data/nemo"
  ONT_ID_EXTRA = "http://example.org/data/nemo/extra"

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

    def setup
      self.class._delete
    end


    def self._delete
      graphs = [ONT_ID, ONT_ID_EXTRA]
      graphs.each { |graph| Goo.sparql_data_client.delete_graph(graph) }
    end

    def test_put_data
      graph = ONT_ID
      ntriples_file_path = "./test/data/nemo_ontology.ntriples"
      triples_no_bnodes = 25256

      Goo.sparql_data_client.put_triples(graph, ntriples_file_path, mime_type="application/x-turtle")

      count = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID}> { ?s ?p ?o }}"
      Goo.sparql_query_client.query(count).each do |sol|
        assert_equal triples_no_bnodes, sol[:c].object
      end

      count = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID}> { ?s ?p ?o . FILTER(isBlank(?s)) }}"
      Goo.sparql_query_client.query(count).each do |sol|
        assert_equal 0, sol[:c].object
      end
    end

    def test_put_delete_data
      graph = ONT_ID
      ntriples_file_path = "./test/data/nemo_ontology.ntriples"
      triples_no_bnodes = 25256

      Goo.sparql_data_client.put_triples(graph, ntriples_file_path, mime_type="application/x-turtle")

      count = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID}> { ?s ?p ?o }}"
      Goo.sparql_query_client.query(count).each do |sol|
        assert_equal triples_no_bnodes, sol[:c].object
      end

      puts "Starting deletion"
      Goo.sparql_data_client.delete_graph(graph)
      puts "Deletion complete"

      count = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID}> { ?s ?p ?o }}"
      Goo.sparql_query_client.query(count).each do |sol|
        assert_equal 0, sol[:c].object
      end
    end

    def test_reentrant_queries
      ntriples_file_path = "./test/data/nemo_ontology.ntriples"

      # Bypass in chunks
      params = self.class.params_for_backend(:post, ONT_ID, ntriples_file_path)
      RestClient::Request.execute(params)

      tput = Thread.new {
        Goo.sparql_data_client.put_triples(ONT_ID_EXTRA, ntriples_file_path, mime_type="application/x-turtle")
      }

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
      assert_equal 5, count_queries
      tput.join


      count = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID_EXTRA}> { ?s ?p ?o }}"
      Goo.sparql_query_client.query(count).each do |sol|
        assert_includes [25256, 50512], sol[:c].object
      end

      tdelete = Thread.new {
        Goo.sparql_data_client.delete_graph(ONT_ID_EXTRA)
      }

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
      tdelete.join
      assert_equal 5, count_queries

      count = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID_EXTRA}> { ?s ?p ?o }}"
      Goo.sparql_query_client.query(count).each do |sol|
        assert_equal 0, sol[:c].object
      end
    end

    def test_query_flood
      ntriples_file_path = "./test/data/nemo_ontology.ntriples"
      params = self.class.params_for_backend(:post, ONT_ID, ntriples_file_path)
      RestClient::Request.execute(params)

      tput = Thread.new {
        Goo.sparql_data_client.put_triples(ONT_ID_EXTRA, ntriples_file_path, mime_type="application/x-turtle")
      }
      
      threads = []
      25.times do |i|
        threads << Thread.new {
          50.times do |j|
            # The query WHERE { ?s a ?o } does not specify a graph, so it runs against the default graph.
            # In AllegroGraph, the default graph is empty by default and does not include named graphs.
            # In 4store/Virtuoso, the default graph is effectively a union of named graphs,
            # so the original query works. Therefore, in AllegroGraph the count returns 0, causing
            # refute_equal 0 to fail. This commit adds a named graph to the query.
            oq = "SELECT (count(?s) as ?c) WHERE { GRAPH <#{ONT_ID}> { ?s a ?o } }"
            Goo.sparql_query_client.query(oq).each do |sol|
              refute_equal 0, sol[:c].to_i
            end
          end
        }
      end

      threads.each(&:join)

      if Goo.backend_4s?
        log_status = []
        Thread.new {
          10.times do |i|
            log_status << Goo.sparql_query_client.status
          end
        }

        threads.each do |t|
          t.join
        end
        tput.join

        assert log_status.map { |x| x[:outstanding] }.max > 0
        assert_equal 16, log_status.map { |x| x[:running] }.max
      end
    end

    def self.params_for_backend(method, graph_name, ntriples_file_path = nil)
      Goo.sparql_data_client.params_for_backend(graph_name, File.read(ntriples_file_path), "text/turtle", method)
    end

  end
end
