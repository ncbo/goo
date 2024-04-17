require_relative 'test_case'

module TestComplex

class Submission < Goo::Base::Resource
  model :submission, name_with: :name
  attribute :name , enforce: [:existence, :unique]
end

class Term < Goo::Base::Resource
  model :term,
        namespace: :owl,
        collection: :submission,
        name_with: :id,
        rdf_type: lambda { |x| self.class_rdf_type(x) }

  attribute :submission, enforce: [:existence]
  attribute :prefLabel, namespace: :skos, enforce: [:existence]
  attribute :synonym, namespace: :skos, property: :altLabel, enforce: [:list]
  attribute :definition, namespace: :skos, enforce: [:list]
  attribute :deprecated, namespace: :owl

  attribute :parents, 
            namespace: :rdfs, 
            property: lambda { |x| tree_property(x) },
            enforce: [:list, :term]

  attribute :ancestors, 
            namespace: :rdfs, 
            property: lambda { |x| tree_property(x) },
            enforce: [:list, :term], transitive: true

  attribute :children, 
            namespace: :rdfs, 
            property: lambda { |x| tree_property(x) },
            inverse: { on: :term , attribute: :parents }

  attribute :descendants, 
            namespace: :rdfs, 
            property: lambda { |x| tree_property(x) },
            inverse: { on: :term , attribute: :parents },
            transitive: true

  def self.tree_property(*args)
    collection = args.flatten.first
    if collection.id.to_s["submission1"]
      return RDF::RDFS[:subClassOf]
    end
    return RDF::SKOS[:broader]
  end

  def self.class_rdf_type(*args)
    collection = args.flatten.first
    if collection.id.to_s["submission1"]
      return RDF::OWL[:Class]
    end
    return RDF::SKOS[:Concept]
  end

  attribute :methodBased, namespace: :rdfs, property: :subClassOf, handler: :dataMethod
  def dataMethod
    return "aaaa"
  end

end

class TestModelComplex < MiniTest::Unit::TestCase


  def initialize(*args)
    super(*args)
  end

  def self.before_suite
    Goo.use_cache = false
    if GooTest.count_pattern("?s ?p ?o") > 100000
      raise Exception, "Too many triples in KB, does not seem right to run tests"
    end

    Goo.sparql_data_client.delete_graph(Submission.uri_type.to_s)
  end

  def self.after_suite
    Goo.use_cache = false
    Goo.sparql_data_client.delete_graph(Submission.uri_type.to_s)
  end

  def test_method_handler
    x = Term.new 
    y = x.methodBased
    x.methodBased
    assert y == "aaaa"
    assert_raises ArgumentError do
      x.methodBased= "aaaa"
    end
    sub = Submission.new(name: "submissionX").save
    x.submission = sub
    x.id = RDF::URI.new "http://someiri.org/term/x"
    x.prefLabel = "x"
    x.save
    assert_raises ArgumentError do
      y = Term.find(x.id).in(sub).include(:methodBased).first
    end
    assert_raises ArgumentError do
      y = Term.find(x.id).in(sub).include(methodBased: [:prefLabel]).first
    end
    assert_raises ArgumentError do
      y = Term.where.in(sub).include(:methodBased).all
    end
    y = Term.find(x.id).in(sub).first
    assert_raises ArgumentError do
      y.bring(:methodBased)
    end
    y.delete
    sub.delete
  end

  def test_multiple_collection()
    submissions = [Submission.new(name: "submission1"),
                   Submission.new(name: "submission2"),
                   Submission.new(name: "submission3")]

    submissions.each do |submission|
      unless submission.exist?
        submission.save
      else
        submission = Submission.find("submission1").first
      end
    end
    submissions = Submission.where.include(:name).all

    submissions.each do |submission|
      terms = Term.where.in(submission).to_a
      terms.each do |t|
        t.delete
      end
    end

    10.times do |x|
      vehicle = Term.new
      s = (x % 3) + 1
      vehicle.submission = submissions.select {|x| x.name == "submission#{s}" }.first
      vehicle.prefLabel = "vehicle#{x}"
      vehicle.synonym = ["transport#{x}", "vehicles#{x}"]
      vehicle.definition = ["vehicle def 1", "vehicle def 2"]
      assert !vehicle.valid?
      assert !vehicle.errors[:id].nil?
      vehicle.id = RDF::URI.new "http://someiri.org/vehicle/#{x}"
      assert vehicle.valid?
      vehicle.save
    end
    ss1 = submissions.select {|x| x.name == "submission1" }.first
    ss2 = submissions.select {|x| x.name == "submission2" }.first
    ss3 = submissions.select {|x| x.name == "submission3" }.first

    assert_equal 4, GooTest.count_pattern(
      "GRAPH #{ss1.id.to_ntriples} { ?s a #{Term.type_uri(ss1).to_ntriples} . }")

    res =  Term.find("http://someiri.org/vehicle/0").in(ss1).first
    assert res.id == RDF::URI.new("http://someiri.org/vehicle/0")

    Term.where.in([ss1,ss2]).include(:prefLabel,:synonym).all.each do |term|
      assert [0,1,3,4,6,7,9].index(term.id.to_s[-1].to_i)
      assert term.prefLabel.to_s[-1].to_i == term.id.to_s[-1].to_i
      term.synonym.each do |sy|
        assert sy.to_s[-1].to_i == term.id.to_s[-1].to_i
      end
    end
    
    Term.where.in([ss3]).include(:prefLabel,:synonym).all.each do |term|
      assert [2,5,8].index(term.id.to_s[-1].to_i)
      assert term.prefLabel.to_s[-1].to_i == term.id.to_s[-1].to_i
      term.synonym.each do |sy|
        assert sy.to_s[-1].to_i == term.id.to_s[-1].to_i
      end
    end

    Goo.sparql_data_client.delete_graph(ss1.id)
    Goo.sparql_data_client.delete_graph(ss2.id)
    Goo.sparql_data_client.delete_graph(ss3.id)
    Goo.sparql_data_client.delete_graph(Submission.type_uri)

  end

  def test_collection()

    # This call is not usually necessary as it is usually covered by
    # the model declaration above.  See the explanation in
    # https://github.com/ncbo/goo/commit/0e09816b121750b3bb875a5c24cb79865287fcf4#commitcomment-90304626
    Goo.add_model(:class, Term)

    submission = Submission.new(name: "submission1")
    unless submission.exist?
      submission.save
    else
      submission = Submission.find("submission1").first
    end

    terms = Term.where.in(submission).to_a
    terms.each do |t|
      t.delete
    end

    vehicle = Term.new
    vehicle.submission = submission
    vehicle.prefLabel = "vehicle"
    vehicle.synonym = ["transport", "vehicles"]
    vehicle.definition = ["vehicle def 1", "vehicle def 2"]
    assert !vehicle.valid?
    assert !vehicle.errors[:id].nil?
    vehicle.id = RDF::URI.new "http://someiri.org/vehicle"
    assert vehicle.valid?
    vehicle.save
    assert_equal 1, GooTest.count_pattern("GRAPH #{submission.id.to_ntriples} { #{vehicle.id.to_ntriples} a ?type . }")

    #where should not accept resource id
    assert_raises ArgumentError do
      Term.where(id: "http://someiri.org/vehicle").in(submission).all
    end

    res =  Term.find("http://someiri.org/vehicle").in(submission).first
    assert res.id == RDF::URI.new("http://someiri.org/vehicle")

    #nil
    res =  Term.find("http://xxx").in(submission).first
    assert res.nil?

    #should fail no collection 
    assert_raises ArgumentError do
      Term.find(RDF::URI.new("xx")).first
    end

    #single term retrieval with include
    ts = Term.find(RDF::URI.new("http://someiri.org/vehicle")).in(submission)
          .include(:synonym, :prefLabel)
          .first

    assert_instance_of Term, ts
    assert "vehicle" == ts.prefLabel
    assert ts.synonym.length == 2
    assert (ts.synonym.select { |s| s == "transport"}).length == 1
    assert (ts.synonym.select { |s| s == "vehicles"}).length == 1
    
    #all terms for a collection
    terms = Term.where.in(submission).include(Term.attributes).all
    assert terms.length == 1
    term = terms[0]
    term.submission.id == RDF::URI.new("http://goo.org/default/submission/submission1")
    term.deprecated = false
    term.save
    assert_equal 1, GooTest.count_pattern("GRAPH #{submission.id.to_ntriples} { #{vehicle.id.to_ntriples} a ?type . }")

    terms = Term.where.in(submission).all
    terms.each do |t|
      t.delete
    end
    assert_equal 0, GooTest.count_pattern("GRAPH #{submission.id.to_ntriples} { #{vehicle.id.to_ntriples} ?p ?o . }")
    submission.delete
  end

  def test_two_resources_same_id
    s1 = Submission.new(name: "sub1")
    if s1.exist?
      s1 = Submission.find("sub1").first
    else
      s1.save
    end
    s2 = Submission.new(name: "sub2")
    if s2.exist?
      s2 = Submission.find("sub2").first
    else
      s2.save
    end

    [s1, s2].each do |s|
      terms = Term.where.in(s).all
      terms.each do |t|
        t.delete
      end
    end

    t0 = Term.new( prefLabel: "labelX" )
    t0.id = RDF::URI.new("http://someiri.org/term0")
    t1 = Term.new( prefLabel: "label1" )
    t1.id = RDF::URI.new("http://someiri.org/term")
    t0.submission = s1
    t1.submission = s1
    t2 = Term.new( prefLabel: "label2" )
    t2.id = RDF::URI.new("http://someiri.org/term")
    t2.submission = s2

    assert t0.valid?
    assert t1.valid?
    assert t2.valid?

    t0.save
    t1.save
    t2.save

   t1x = Term.find(RDF::URI.new("http://someiri.org/term")).in(s1).include(Term.attributes).first
   assert t1x.prefLabel ==  "label1"
   t2x = Term.find(RDF::URI.new("http://someiri.org/term")).in(s2).include(Term.attributes).first
   assert t2x.prefLabel ==  "label2"

   termsS2 = Term.where.in(s2).all
   assert termsS2.length == 1
   termsS1 = Term.where.in(s1).all
   assert termsS1.length == 2
   [s1, s2].each do |s|
     terms = Term.where.in(s).all
     terms.each do |t|
       t.delete
     end
   end

  end

  def test_parents_inverse_children

    # This call is not usually necessary as it is usually covered by
    # the model declaration above.  See the explanation in
    # https://github.com/ncbo/goo/commit/0e09816b121750b3bb875a5c24cb79865287fcf4#commitcomment-90304626
    Goo.add_model(:class, Term)

    submission = Submission.new(name: "submission1")
    unless submission.exist?
      submission.save
    else
      submission = Submission.find("submission1").first
    end


    terms = Term.in(submission)
    terms.each do |t|
      t.delete
      assert_equal 0, GooTest.count_pattern("GRAPH #{t.id.to_ntriples} { #{t.id.to_ntriples} ?p ?o . }")
    end

    vehicle = Term.new
    vehicle.id = RDF::URI.new "http://someiri.org/vehicle"
    vehicle.submission = submission
    vehicle.prefLabel = "vehicle"
    vehicle.synonym = ["transport", "vehicles"]
    vehicle.definition = ["vehicle def 1", "vehicle def 2"]
    assert vehicle.valid?
    vehicle.save

    van = Term.new
    van.submission = submission
    van.id = RDF::URI.new "http://someiri.org/van"
    van.prefLabel = "van"
    van.synonym = ["cargo", "syn van"]
    van.definition = ["vehicle def 1", "vehicle def 2"]
    van.parents = [vehicle]
    assert van.valid?, "Invalid term: [id: #{van.id}, errors: #{van.errors}]"
    van.save

    assert_equal 1, GooTest.count_pattern(
      "GRAPH #{submission.id.to_ntriples} { #{van.id.to_ntriples} #{RDF::RDFS[:subClassOf].to_ntriples} ?p . }")
    cargo = Term.new
    cargo.submission = submission
    cargo.id = RDF::URI.new "http://someiri.org/cargo"
    cargo.prefLabel = "cargo"
    cargo.synonym = ["cargo yy", "cargo xx"]
    cargo.definition = ["cargo def 1", "cargo def 2"]
    cargo.parents = [vehicle]
    assert cargo.valid?
    cargo.save

    minivan = Term.new
    minivan.submission = submission
    minivan.id = RDF::URI.new "http://someiri.org/minivan"
    minivan.prefLabel = "minivan"
    minivan.synonym = ["mini-van", "syn minivan"]
    minivan.definition = ["minivan def 1", "minivan def 2"]
    minivan.parents = [van]
    assert minivan.valid?
    minivan.save


    cargovan = Term.new
    cargovan.submission = submission
    cargovan.id = RDF::URI.new "http://someiri.org/cargovan"
    cargovan.prefLabel = "cargovan"
    cargovan.synonym = ["cargo van", "syn cargovan"]
    cargovan.definition = ["cargovan def 1", "cargovan def 2"]
    cargovan.parents = [cargo, van]
    assert cargovan.valid?
    cargovan.save

    assert_raises ArgumentError do
      #children as inverse cannot be assigned
      minivan.children = cargovan
    end


    vehicle = Term.find(RDF::URI.new("http://someiri.org/vehicle")).in(submission)
                .include(:children,:parents).first
    ch = vehicle.children
    assert ch.length == 2
    (ch.select { |c| c.id.to_s == "http://someiri.org/van" }).length == 1
    (ch.select { |c| c.id.to_s == "http://someiri.org/cargo" }).length == 1
    assert vehicle.parents == []



    assert cargovan.parents.length == 2
    #this is confussing

    Term.where.models([ cargovan ]).in(submission).include(:children).all
    assert cargovan.children == []

    #preload attrs
    terms = Term.in(Submission.find("submission1").first).include(:parents,:synonym,:definition)
    terms.each do |t|
      if t.id.to_s == "http://someiri.org/cargovan"
        assert_instance_of Array, t.parents
        obj_sy = t.synonym.sort
        assert obj_sy.first == "cargo van"
        assert obj_sy[1] == "syn cargovan"
        assert (Set.new t.parents).length == t.parents.length
        assert t.parents.length == 2
        assert t.definition.length == 2
        assert t.parents[0].kind_of?(Term)
        assert t.parents[1].kind_of?(Term)
        assert (t.parents.select { |x| x.id.to_s == "http://someiri.org/cargo" }).length == 1
        assert (t.parents.select { |x| x.id.to_s == "http://someiri.org/van" }).length == 1
      end
      if t.id.to_s == "http://someiri.org/minivan"
        assert_instance_of Array, t.parents
        obj_sy = t.synonym.sort
        assert obj_sy.first == "mini-van"
        assert obj_sy[1] == "syn minivan"
        assert t.parents.length == 1
        assert t.parents[0].kind_of?(Term)
        assert t.parents[0].id.to_s == "http://someiri.org/van"
      end
      if t.id.to_s == "http://someiri.org/vehicle"
        assert t.parents == []
      end
    end
    assert terms.length == 5

    terms = Term.in(submission)
    terms.each do |t|
      t.delete
      assert_equal 0, GooTest.count_pattern("GRAPH #{submission.id.to_ntriples} { #{t.id.to_ntriples} ?p ?o . }")
    end
    submission.delete
  end

  def test_empty_attributes
    submission = Submission.new(name: "submission1")
    unless submission.exist?
      submission.save
    else
      submission = Submission.find("submission1").first
    end

    terms = Term.in(submission)
    terms.each do |t|
      t.delete
      assert_equal 0, GooTest.count_pattern("GRAPH #{t.id.to_ntriples} { #{t.id.to_ntriples} ?p ?o . }")
    end

    vehicle = Term.new
    vehicle.id = RDF::URI.new "http://someiri.org/vehicle"
    vehicle.submission = submission
    vehicle.prefLabel = "vehicle"
    vehicle.synonym = ["transport", "vehicles"]
    assert vehicle.valid?
    vehicle.save

    #on demand
    terms = Term.in(submission).include(:synonym,:definition).all
    assert terms.length == 1
    assert terms.first.synonym.sort ==  ["transport", "vehicles"]
    assert terms.first.definition ==  []

    #preload
    terms = Term.in(submission).include(:synonym, :definition).all
    assert terms.length == 1
    assert terms.first.synonym.sort ==  ["transport", "vehicles"]
    assert terms.first.definition ==  []

    #with find
    term = Term.find(RDF::URI.new("http://someiri.org/vehicle")).in(submission).include(:prefLabel, :synonym, :definition).first
    assert term.synonym.sort ==  ["transport", "vehicles"]
    assert term.definition ==  []
    assert term.prefLabel == "vehicle"

  end

  def test_aggregate
    skip "Transitive closure doesn't work yet.  AllegroGraph?"
    submission = Submission.new(name: "submission1")
    unless submission.exist?
      submission.save
    else
      submission = Submission.find("submission1").first
    end
    
    terms = Term.in(submission)
    terms.each do |t|
      t.delete
      assert_equal 0, GooTest.count_pattern("GRAPH #{submission.id.to_ntriples} { #{t.id.to_ntriples} ?p ?o . }")
    end
    
    terms = []
    10.times do |i|
      term = Term.new
      term.id = RDF::URI.new("http://someiri.org/term/#{i}")
      term.submission = submission
      term.prefLabel = "term #{i}"
      term.synonym = ["syn A #{i}", "syn B #{i}"]
      if i >= 1 && i < 5
        term.parents = [terms[0]]
      elsif i == 5
        term.parents = [terms[1]]
      elsif i > 5 && i < 9
        term.parents = [terms[2], terms[3]]
      elsif i > 0
        term.parents = [terms[5]]
      end
      assert term.valid?, "Invalid term: [id: #{term.id}, errors: #{term.errors}]"
      term.save
      terms << term
    end

    terms = Term.in(submission).aggregate(:count, :children).all
    terms = terms.sort_by { |x| x.id }
    assert_equal 4, terms[0].aggregates.first.value
    assert_equal 1, terms[1].aggregates.first.value
    assert_equal 3, terms[2].aggregates.first.value
    assert_equal 3, terms[3].aggregates.first.value
    assert_equal 0, terms[-1].aggregates.first.value

    page = Term.in(submission).include(:synonym, :prefLabel).aggregate(:count, :children).page(1)
    page.each do |t|
      if t.id.to_s.include? "term/0"
        assert_equal 4, t.aggregates.first.value
      elsif t.id.to_s.include? "term/1"
        assert_equal 1, t.aggregates.first.value
      elsif t.id.to_s.include? "term/2"
        assert_equal 3, t.aggregates.first.value
      elsif t.id.to_s.include? "term/3"
        assert_equal 3, t.aggregates.first.value
      elsif t.id.to_s.include? "term/9"
        assert_equal 0, t.aggregates.first.value
      end
    end

    # With a parent
    page = Term.where(parents: terms[0]).in(submission)
               .include(:synonym, :prefLabel).aggregate(:count, :children).page(1)
    assert_equal 4, page.length
    page.each do |t|
      if t.id.to_s.include? "term/1"
        assert_equal 1, t.aggregates.first.value
      elsif t.id.to_s.include? "term/2"
        assert_equal 3, t.aggregates.first.value
      elsif t.id.to_s.include? "term/3"
        assert_equal 3, t.aggregates.first.value
      elsif t.id.to_s.include? "term/4"
        assert_equal 0, t.aggregates.first.value
      else
        assert 1 == 0
      end
    end

    # With parent and query options
    page = Term.where(ancestors: terms[0]).in(submission)
               .include(:synonym, :prefLabel).aggregate(:count, :children).page(1)
    assert_equal 9, page.count
    page.each do |t|
      if t.id.to_s.include? "term/1"
        assert_equal 1, t.aggregates.first.value
      elsif t.id.to_s.include? "term/2"
        assert_equal 3, t.aggregates.first.value
      elsif t.id.to_s.include? "term/3"
        assert_equal 3, t.aggregates.first.value
      elsif t.id.to_s.include? "term/4"
        assert_equal 0, t.aggregates.first.value
      elsif t.id.to_s.include? "term/5"
        assert_equal 1, t.aggregates.first.value
      elsif t.id.to_s.include? "term/6"
        assert_equal 0, t.aggregates.first.value
      elsif t.id.to_s.include? "term/7"
        assert_equal 0, t.aggregates.first.value
      elsif t.id.to_s.include? "term/8"
        assert_equal 0, t.aggregates.first.value
      elsif t.id.to_s.include? "term/9"
        assert_equal 0, t.aggregates.first.value
      else
        assert 1 == 0
      end
    end

    # The other direction UP, and query options, and read only
    page = Term.where(descendants: terms[9]).in(submission)
               .include(:synonym, :prefLabel).aggregate(:count, :children).page(1)
    assert_equal 3, page.count
    page.each do |t|
      if t.id.to_s.include? "term/0"
        assert_equal 4, t.aggregates.first.value
      elsif t.id.to_s.include? "term/5"
        assert_equal 1, t.aggregates.first.value
      elsif t.id.to_s.include? "term/1"
        assert_equal 1, t.aggregates.first.value
      else
        assert 1 == 0
      end
    end

    # With read only
    ts = Term.where(descendants: terms[9]).in(submission).include(:synonym, :prefLabel).read_only
    assert_equal 3, ts.length
    ts.each do |t|
      assert_instance_of String, t.prefLabel
      assert_equal Term, t.klass
      assert_equal RDF::URI, t.id.class
      assert_instance_of Array, t.synonym
    end

    # Read_only + page
    ts = Term.where(descendants: terms[9]).in(submission).include(:synonym, :prefLabel).read_only.page(1)
    assert_equal 3, ts.length
    ts.each do |t|
      assert_instance_of String, t.prefLabel
      assert t.klass == Term
      assert t.id.class == RDF::URI
      assert_instance_of Array, t.synonym
    end

    page = Term.where(descendants: terms[9]).in(submission)
               .include(:synonym, :prefLabel).aggregate(:count, :children).read_only.page(1)
    assert_equal 3, page.count
    page.each do |t|
      if t.id.to_s.include? "term/0"
        assert_equal 4, t.aggregates.first.value
      elsif t.id.to_s.include? "term/5"
        assert_equal 1, t.aggregates.first.value
      elsif t.id.to_s.include? "term/1"
        assert_equal 1, t.aggregates.first.value
      else
        assert 1 == 0
      end
    end
  end


  def test_empty_pages
    submission = Submission.new(name: "submission1")
    unless submission.exist?
      submission.save
    else
      submission = Submission.find("submission1").first
    end

    terms = Term.in(submission)
    terms.each do |t|
      t.delete
      assert_equal 0, GooTest.count_pattern("GRAPH #{submission.id.to_ntriples} { #{t.id.to_ntriples} ?p ?o . }")
    end

    # This call is not usually necessary as it is usually covered by
    # the model declaration above.  See the explanation in
    # https://github.com/ncbo/goo/commit/0e09816b121750b3bb875a5c24cb79865287fcf4#commitcomment-90304626
    Goo.add_model(:class, Term)

    terms = []
    10.times do |i|
      term = Term.new
      term.id = RDF::URI.new("http://someiri.org/term/#{i}")
      term.submission = submission
      term.prefLabel = "term #{i}"
      if i >= 1 && i < 5
        term.parents = [terms[0]]
      end
      assert term.valid?, "Invalid term: [id: #{term.id}, errors: #{term.errors}]"
      term.save
      terms << term
    end

    term = Term.find(RDF::URI.new("http://someiri.org/term/8"))
                .in(submission)
                .first
    page_terms = Term.where(parents: term)
                 .in(submission)
                 .include(Term.attributes)
                 .page(1)
                 .all
    assert_equal 0, page_terms.length
  end

  def test_readonly_pages_with_include

    # This call is not usually necessary as it is usually covered by
    # the model declaration above.  See the explanation in
    # https://github.com/ncbo/goo/commit/0e09816b121750b3bb875a5c24cb79865287fcf4#commitcomment-90304626
    Goo.add_model(:class, Term)

    submission = Submission.new(name: "submission1")
    unless submission.exist?
      submission.save
    else
      submission = Submission.find("submission1").first
    end
    terms = Term.in(submission)
    terms.each do |t|
      t.delete
      assert_equal(0,
       GooTest.count_pattern("GRAPH #{submission.id.to_ntriples} { #{t.id.to_ntriples} ?p ?o . }"))
    end

    terms = []
    10.times do |i|
      term = Term.new
      term.id = RDF::URI.new("http://someiri.org/term/#{i}")
      term.submission = submission
      term.prefLabel = "term #{i}"
      if i >= 1 && i < 5
        term.parents = [terms[0]]
      elsif i >= 2
        term.parents = [terms[1]]
      end
      assert term.valid?, "Invalid term: [id: #{term.id}, errors: #{term.errors}]"
      term.save
      terms << term
    end

    #just one attr + embed
    page_terms = Term.in(submission)
                 .include(ancestors: [:prefLabel])
                 .page(1,5)
                 .read_only
                 .all
    page_terms.each do |c|
      if c.ancestors.first
        assert_instance_of String, c.ancestors.first.prefLabel
      end
    end

    #two attributes
    page_terms = Term.in(submission)
                 .include(:prefLabel, ancestors: [:prefLabel])
                 .page(1,5)
                 .read_only
                 .all
    page_terms.each do |c|
      assert_instance_of String, c.prefLabel
      if c.ancestors.first
        assert_instance_of String, c.ancestors.first.prefLabel
      end
    end
  end

  def test_nil_attributes
    t = Term.new
    assert_raises NoMethodError do
      t.my_new_attr = "bla"
    end
  end

end
end

