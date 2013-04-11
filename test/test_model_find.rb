require_relative 'test_case'

TestInit.configure_goo

class Color < Goo::Base::Resource
  model :color
  attribute :code, :unique => true

  def initialize(attributes = {})
    super(attributes)
  end
end

class ToyFeature < Goo::Base::Resource
  model :toy_feature
  attribute :color,  :instance_of => { :with => :color }
  attribute :description, :cardinality => { :min => 1, :max => 1 }

  def initialize(attributes = {})
    super(attributes)
  end
end

class ToyPart < Goo::Base::Resource
  attribute :feature,  :instance_of => { :with => :toy_feature }
  attribute :name,  :cardinality => { :min => 1, :max => 1 }

  def initialize(attributes = {})
    super(attributes)
  end
end

class ToyObject < Goo::Base::Resource
  attribute :part, :instance_of => { :with => :toy_part }
  attribute :name, :unique => true
  attribute :all_prop
  attribute :name_even
  attribute :name_odd
  attribute :name_x
  attribute :category

  def initialize(attributes = {})
    super(attributes)
  end
end

class TestModelwhere < TestCase

  def initialize(*args)
    super(*args)
  end
  def delete_toys()
    list = ToyObject.all
    list.each do |c|
      assert c.lazy_loaded?
      c.load(nil,load_attrs: :all)
      c.delete
    end
    list = ToyPart.all
    list.each do |c|
      assert c.lazy_loaded?
      c.load(nil,load_attrs: :all)
      c.delete
    end
    list = ToyFeature.all
    list.each do |f|
      f.load(nil,load_attrs: :all)
      f.delete
    end
    list = Color.all
    list.each do |c|
      assert c.lazy_loaded?
      c.load(nil,load_attrs: :all)
      c.delete
    end

  end

  def create_toy_parts()

    blue = Color.new({:code => "blue"})
    red = Color.new({:code => "red"})
    white = Color.new()
    white.code = "white"

    wheel_blue = ToyFeature.new(:description => "wheel", :color => [white])
    wheel_red = ToyFeature.new(:description => "wheel", :color => [red])
    engine = ToyFeature.new()
    engine.description = "engine"
    engine.color = [blue, red]

    wheel_blue.save
    wheel_red.save
    engine.save
    list = ToyFeature.all
    assert_equal 3, list.length
    list = Color.all
    assert_equal 3, list.length
  end

  def create_toys(max)
    delete_toys()
    create_toy_parts()
    (0..max-1).each do |n|
      toy = ToyObject.new
      toy.name = "some value for #{n}"
      toy.all_prop = "common"

      if n % 2 == 0
        toy.name_even = n
        toy.name_x = "x"

        #two different ways of whereing for features
        white = Color.where(:code => "white")[0]
        white_wheel = ToyFeature.where(:description => "wheel" , :color => white)
        red_wheel = ToyFeature.where(:description => "wheel" , :color => { :code => "red"})
        assert red_wheel.length > 0
        toy_part = ToyPart.new({:name => "toypart#{n}", :feature => [white_wheel[0],red_wheel[0]] })
        toy.part= toy_part
        toy.category = "even"
      else
        toy.name_odd = n
        engine_blue = ToyFeature.where(:color => { :code => "blue"})[0]
        assert !engine_blue.nil?
        #the only blue thing is an engine
        assert_equal "engine", engine_blue.description.value

        toy_part = ToyPart.new({:name => "toypart#{n}", :feature => [engine_blue] })
        toy.part = toy_part
        toy.category = "odd"
      end
      if toy.exist?
        toy_copy = ToyObject.new
        toy_copy.load(toy.resource_id)
        toy_copy.delete
      end
      assert_equal false, toy.exist?(reload=true)
      toy.save
      assert_equal true, toy.exist?(reload=true)
      assert_equal 1, count_pattern("#{toy.resource_id.to_turtle} a ?type .")
    end
  end

  def test_search_simple
    max = 6
    create_toys(max)

    #get them all
    toys = ToyObject.all
    assert_equal max, toys.length
    lits = Set.new
    toys.each do |t|
      t.load
      lits << t.name
    end
    (0..max-1).each do |n|
      assert_equal true, (lits.select { |l| l.value == "some value for #{n}"}).length > 0
    end

    #issue 75. Nil pointer with nested objects and unknown attributes
    assert_raises ArgumentError do
      ToyObject.where(:name_xxxx => { xxx: 1 } )
    end
    assert_raises ArgumentError do
      ToyObject.where(:name_xxxx => nil )
    end
    assert_raises ArgumentError do
    ToyObject.where(:name_x => { xxx: 1 })
    end
    toys = ToyObject.where(:name_x => "x", :only_known => false)
    assert_equal max/2, toys.length
    toys.each do |t|
      assert_instance_of Fixnum, t.name_even[0].parsed_value
      assert_equal 0, t.name_even[0].parsed_value % 2
    end
    with_names = ToyObject.where(:name_x => "x", :only_known => false, :load_attrs => [:name])
    with_names.each do |c|
      assert c.name != nil
      assert_raises NoMethodError do
        c.xxxxxx
      end
    end

    without_names = ToyObject.where(name_x: :unbound, load_attrs: { name: true, part: { name: true } })
    without_names.each do |t|
      assert !t.attributes[:name].nil?
      assert t.attributes[:name_x].nil?
      assert !t.attributes[:part].nil?
      assert !t.attributes[:part].first.attributes[:name].nil?
    end

    #search for a feature with ToyPart that has white_wheel and white_wheel
    white = Color.where(:code => "white")[0]
    white_wheel = ToyFeature.where(:description => "wheel" , :color => white)[0]
    red_wheel = ToyFeature.where(:description => "wheel" , :color => { :code => "red"})[0]
    mult = ToyPart.where feature: [white_wheel, red_wheel]
    mult.each do |x|
      assert (mult[0].name.value[-1].to_i % 2 == 0)
    end

    toys = ToyObject.all :load_attrs => :defined
    toys.each do |t|
      assert t.loaded?
      t.delete
    end
    toys = ToyObject.all
    assert_equal 0, toys.length

    delete_toys()
  end

  def test_where_with_nested
    max = 6
    create_toys(max)

    #things that have a part with a name that is toypart
    list = ToyObject.where(:part => { :name => "toypart0"})
    assert_equal 1, list.length
    blues = Color.where(:code => "blue")
    assert_equal 1, blues.length
    blue = blues[0]
    list = ToyObject.where(:part => { :feature => { :color => blue }})
    assert_equal 3, list.length
    list = ToyObject.where( :part => {
                            :feature => { :color => blue  }},
                            :all_prop => "common" , :only_known => false)
    assert_equal 3, list.length
    list.each do |x|
      assert_equal "common", x.all_prop[0].parsed_value
      assert_equal 1, x.part.length
      x.part.each do |p|
        p.load
        assert_equal 1, p.feature.length
        p.feature.each do |f|
          f.load
          assert_equal "engine", f.description.value
        end
      end
    end

    delete_toys()
  end


  def test_find
    max = 6
    create_toys(max)
    white = Color.find("white")
    assert_instance_of Color, white
    assert white.resource_id.value.end_with? "white"
    assert_equal "white", white.code.parsed_value

    iri_blue = Color.prefix + Color.goo_name.to_s + "/blue"
    blue = Color.find(RDF::IRI.new(iri_blue))
    assert_instance_of Color, blue
    assert blue.resource_id.value.end_with? "blue"
    assert_equal "blue", blue.code.parsed_value

    not_exist = Color.find("xxxxxxxxx")
    assert not_exist.nil?


    delete_toys()
  end

  def test_search_pages
    max = 16
    create_toys(max)

    #preload options in page
    ld = { :name => true, :part => true }
    page = ToyObject.page category: "even", page: 1, size: 4, load_attrs: ld
    assert page.length == 4
    assert page.next_page
    page.each do |t|
      assert t.attributes[:name].class == SparqlRd::Resultset::StringLiteral
      assert t.attributes.keys.sort == [:name, :part, :internals].sort
      assert t.attributes[:part].first.class == ToyPart
      #nothing is loaded
      assert t.attributes[:part].first.attributes.keys.sort == [:uuid, :internals].sort
    end

    ld = { :name => true, :part => { :name => true } }
    page = ToyObject.page category: "even", page: 1, size: 4, load_attrs: ld
    assert page.length == 4
    assert page.next_page
    page.each do |t|
      assert t.attributes[:name].class == SparqlRd::Resultset::StringLiteral
      assert t.attributes.keys.sort == [:name, :part, :internals].sort
      assert t.attributes[:part].first.class == ToyPart
      assert t.attributes[:part].first.attributes.keys.sort == [:name, :uuid, :internals].sort
    end

    nums_even = [0,2,4,6,8,10,12,14]
    page_to_load = 1
    load_iterations = 0
    load_nums = []
    while page_to_load do
      page = ToyObject.page category: "even", page: page_to_load, size: 3
      load_iterations += 1
      assert page.length == 3 || (page.page == 3 && page.length == 2)
      assert page.page_count == 3
      page.each do |t|
        i = t.name.value[-2..-1].to_i
        load_nums << i
        assert i % 2 == 0
      end
      page_to_load = page.next_page
    end
    assert load_nums.sort == nums_even

    #one big page
    page = ToyObject.page category: "even", page: 1, size: 100
    load_nums = []
    assert page.length == nums_even.length
    assert !page.next_page
    assert page.page_count == 1
    page.each do |t|
      i = t.name.value[-2..-1].to_i
      load_nums << i
      assert i % 2 == 0
    end
    assert load_nums.sort == nums_even

    #next page empty
    page = ToyObject.page category: "even", page: 2, size: 100
    assert !page.next_page
    assert page.length == 0
    assert page.page_count == 1

    #page with no data
    page = ToyObject.page category: "NO DATA", page: 1, size: 100
    assert !page.next_page
    assert page.length == 0
    assert page.page_count == 0




    delete_toys()
  end

end


