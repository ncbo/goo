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
      c.load
      c.delete
    end
    list = ToyPart.all
    list.each do |c|
      c.load
      c.delete
    end
    list = ToyFeature.all
    list.each do |f|
      f.load
      f.delete
    end
    list = Color.all
    list.each do |c|
      c.load
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
        toy_part = ToyPart.new({:name => "toypart#{n}", :feature => [white_wheel[0],red_wheel[0]] })
        toy.part= toy_part
      else
        toy.name_odd = n
        engine_blue = ToyFeature.where(:color => { :code => "blue"})[0]
        engine_blue.load
        #the only blue thing is an engine
        assert_equal "engine", engine_blue.description

        toy_part = ToyPart.new({:name => "toypart#{n}", :feature => [engine_blue] })
        toy.part = toy_part
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
      assert_equal true, (lits.include? "some value for #{n}")
    end
    toys = ToyObject.where(:name_x => "x" )
    assert_equal max/2, toys.length
    toys.each do |t|
      t.load
      assert_instance_of Fixnum, t.name_even[0]
      assert_equal 0, t.name_even[0] % 2
    end
    toys = ToyObject.all
    toys.each do |t|
      t.load
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
                            :all_prop => "common" )
    assert_equal 3, list.length
    list.each do |x|
      x.load
      assert_equal "common", x.all_prop[0]
      assert_equal 1, x.part.length
      x.part.each do |p|
        p.load
        assert_equal 1, p.feature.length
        p.feature.each do |f|
          f.load
          assert_equal "engine", f.description
        end
      end
    end

    delete_toys()
  end


  def test_find
    create_toy_parts()
    white = Color.find("white")
    assert_instance_of Color, white
    assert white.resource_id.value.end_with? "white"
    assert_equal "white", white.code

    iri_blue = Color.prefix + "blue"
    blue = Color.find(RDF::IRI.new(iri_blue))
    assert_instance_of Color, blue
    assert blue.resource_id.value.end_with? "blue"
    assert_equal "blue", blue.code

    not_exist = Color.find("xxxxxxxxx")
    assert not_exist.nil?
    delete_toys()
  end
end


