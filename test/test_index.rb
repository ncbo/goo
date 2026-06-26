require_relative 'test_case'
require_relative './app/models'

module TestIndex

  class TestSchemaless < Goo::TestCase

    def initialize(*args)
      super(*args)
    end

    def setup
    end

    def before_all
      graph = RDF::URI.new(Test::Models::DATA_ID)

      database = Test::Models::Database.new
      database.id = graph
      database.name = "Census tiger 2002"
      database.save

      ntriples_file_path = "./test/data/TGR06001.nt"

      result = Goo.sparql_data_client.put_triples(
                            graph,
                            ntriples_file_path,
                            mime_type="application/x-turtle")
    end

    def after_all
      graph = RDF::URI.new(Test::Models::DATA_ID)
      result = Goo.sparql_data_client.delete_graph(graph)
      database = Test::Models::Database.find(RDF::URI.new(Test::Models::DATA_ID)).first
      database.delete if database
    end


    def test_find_with_bnodes
      db = Test::Models::Database.find(RDF::URI.new(Test::Models::DATA_ID)).first
      res_id = RDF::URI.new "http://www.census.gov/tiger/2002/tlid/124988547"
      l = Test::Models::Line.find(res_id).in(db).first
      assert l.id == res_id      
      l = Test::Models::Line.find(res_id).in(db).include(:start,:end).first
      assert l.start.tiger_lat == "37.614888"
      assert l.start.tiger_long == "-121.749163"
      assert l.end.tiger_lat == "37.608914"
      assert l.end.tiger_long == "-121.745853"
    end

    def test_index
      db = Test::Models::Database.find(RDF::URI.new(Test::Models::DATA_ID)).first
      page = Test::Models::Line.in(db).index_as("line_collection")
      
      res_from_index = Test::Models::Line.where
                .in(db)
                .with_index("line_collection")
                .include(:start,:end)
                .page(2,10).all

      res_not_index = Test::Models::Line.where
                .in(db)
                .include(:start,:end)
                .page(2,10).all

      res_not_index.each_index do |x|
        assert res_not_index[x].start == res_from_index[x].start
      end
    end

    def test_page_all_lines
      skip "enable for benchmark"
      db = Test::Models::Database.find(RDF::URI.new(Test::Models::DATA_ID)).first
      page = Test::Models::Line.in(db).page(1,5).all
      assert page.length == 5
      assert page.aggregate == 62420
      assert page.total_pages == (page.aggregate / 5.0).ceil
      assert page.page_number == 1
      assert page.next?
      assert !page.prev?

      page = Test::Models::Line.in(db).page(1,5).include(:start,:end).all
      page.each do |line|
        assert line.start.is_a?(Struct)
        assert line.end.is_a?(Struct)
      end

      page_i = 1
      total = 0
      pagination = Test::Models::Line.in(db).include(:start,:end).page(page_i,100)
      begin
        t0 = Time.now
        page = pagination.page(page_i).all
        t1 = Time.now
        puts "Page elapsed elapsed #{(t1 - t0)} sec."
        total += page.length
        page_i += 1
      end while page.next?
      assert total == 62420

    end
  end
end

