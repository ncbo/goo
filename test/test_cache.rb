require_relative 'test_case'
require_relative 'models'

class TestCache < Goo::TestCase

  def initialize(*args)
    super(*args)
  end

  def before_all
    Goo.use_cache=false
    GooTestData.create_test_case_data
    redis = Goo.redis_client
    if redis.dbsize > 100
      raise "This redis needs to point to testing server"
    end
    redis.flushdb
  end

  def after_all
    Goo.use_cache=false
    GooTestData.delete_test_case_data
  end

  def test_cache_invalidate
    address = Address.all.first
    Goo.use_cache = true
    puts "save 1"
    University.new(name: 'test', address: [address]).save
    u2 = University.new(name: 'test', address: [address])
    puts "request 1"
    refute u2.valid?
    expected_error = { :name => { :duplicate => "There is already a persistent resource with id `http://goo.org/default/university/test`" } }
    assert_equal expected_error, u2.errors
    Goo.use_cache = false
  end

  def test_cache_models
    redis = Goo.redis_client
    redis.flushdb
    refute Goo.use_cache?
    Goo.use_cache=true
    assert Goo.use_cache?
    programs = Program.where(name: "BioInformatics", university: [ name: "Stanford"  ]).all
    assert_equal 1, programs.length
    assert programs.first.id.to_s["Stanford/BioInformatics"]
    assert redis.exists("sparql:graph:http://goo.org/default/Program")
    queries = redis.smembers("sparql:graph:http://goo.org/default/Program")
    count = 0
    key = nil
    queries.each do |q|
      if q["Program"]
        count += 1
        key = q
      end
    end
    assert_equal 1, count
    refute_nil key
    assert redis.exists(key)


    prg = programs.first
    prg.bring_remaining
    prg.credits = 999
    prg.save

    #invalidated ?
    refute redis.sismember("sparql:graph:http://goo.org/default/Program",key)
    programs = Program.where(name: "BioInformatics", university: [ name: "Stanford"  ]).all
    assert_equal 1, programs.length
    prg = programs.first
    prg.bring_remaining

    #change comes back ?
    assert_equal 999, prg.credits
    Goo.use_cache=false
  end

  def test_cache_models_back_door
    redis = Goo.redis_client
    redis.flushdb
    refute Goo.use_cache?
    Goo.use_cache=true
    assert Goo.use_cache?
    programs = Program.where(name: "BioInformatics", university: [ name: "Stanford"  ])
                          .include(:students).all
    assert_equal 1, programs.length
    key = nil
    queries = redis.smembers("sparql:graph:http://goo.org/default/Program")
    count = 0
    queries.each do |q|
      if q["Program"]
        count += 1
        key = q
      end
    end
    assert_equal 1, count
    refute_nil key
    assert redis.exists(key)
    assert redis.sismember("sparql:graph:http://goo.org/default/Program",key)

    prg = programs.first
    assert_equal 2, prg.students.length
    prg.students.each do |st|
      st.bring(:name)
    end
    assert_equal ["Daniel","Susan"], prg.students.map { |x| x.name }.sort

    data = "<http://goo.org/default/student/Tim> " +
           "<http://goo.org/default/enrolled> " +
           "<http://example.org/program/Stanford/BioInformatics> ."

    Goo.sparql_data_client.append_triples(Student.type_uri,data,"application/x-turtle")
    programs = Program.where(name: "BioInformatics", university: [ name: "Stanford"  ])
                          .include(:students).all
    prg = programs.first
    assert_equal 3, prg.students.length
    prg.students.each do |st|
      st.bring(:name)
    end
    assert_equal ["Daniel","Susan","Tim"], prg.students.map { |x| x.name }.sort
    Goo.use_cache=false
  end

  def test_cache_successful_hit
    redis = Goo.redis_client
    redis.flushdb
    refute Goo.use_cache?
    Goo.use_cache=true
    assert Goo.use_cache?
    programs = Program.where(name: "BioInformatics", university: [ name: "Stanford"  ])
                          .include(:students).all
    x = Goo.sparql_query_client
    def x.response_backup *args
      self.response(*args)
    end
    def x.response *args
      raise Exception, "Should be a successful hit"
    end
    begin
      programs = Program.where(name: "BioInformatics", university: [ name: "Stanford"  ])
                          .include(:students).all
    rescue Exception
      flunk "should be cached"
    end

    #from cache
    assert_equal 1, programs.length
    assert_raises Exception do
      #different query
      programs = Program.where(name: "BioInformatics X", university: [ name: "Stanford"  ]).all
    end
    TestHelpers.test_reset
    Goo.use_cache=false
  end


end
