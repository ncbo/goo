require_relative 'test_case'

class Named < Goo::Base::Resource
  model :named
  validates :name, :presence => true, :cardinality => { :maximum => 1 }
  validates :hasUnnammed, :instance_of => { :with => :unnamed } 

  unique :name

  def initialize(attributes = {})
    super(attributes)
  end
end

class Unnamed < Goo::Base::Resource
  model :unnamed
  validates :name, :presence => true, :cardinality => { :maximum => 1 }

  def initialize(attributes = {})
    super(attributes)
  end
end

class TestModelUnnamed < TestCase

  def initialize(*args)
    super(*args)
    voc = Goo::Naming.get_vocabularies
    if not voc.is_type_registered? :unnamed
      voc.register_model(:foaf, :unnamed, Unnamed)
      voc.register_model(:foaf, :named, Named)
    else
      raise StandarError, "Error conf unit test" if :unnamed != voc.get_model_registry(Unnamed)[:type]
      raise StandarError, "Error conf unit test" if :named != voc.get_model_registry(Named)[:type]
    end
  end

  def test_unnamed_save
    obj = Unnamed.new
    obj.name = "some value"
    obj.prop1 = 1
    obj.save
    assert_equal true, obj.exist?(reload=true)
    load_obj = Unnamed.new
    load_obj.load(obj.resource_id)
    assert_equal obj.prop1, load_obj.prop1
    assert_equal obj.name, load_obj.name
    load_obj.name= "changed value"
    load_obj.save
    load_obj = Unnamed.new
    load_obj.load(obj.resource_id)
    assert_equal obj.prop1, load_obj.prop1
    assert_equal "changed value", load_obj.name
    assert_equal obj.resource_id.value, load_obj.resource_id.value
    load_obj.delete
    assert_equal false, load_obj.exist?(reload=true)
  end

  def test_named_new_from_hash
    list = Unnamed.search({})
    list.each do |u|
      u.load
      u.delete
    end
    list = Unnamed.search({})
    assert_equal 0, list.length
    unn = Unnamed.new({:name => "some value"})
    unn.save
    list = Unnamed.search({})
    assert_equal 1, list.length
    list.each do |u|
      u.load
      u.delete
    end
    list = Unnamed.search({})
    assert_equal 0, list.length
  end

  def test_named_depends_on_unnnamed
    unn = Unnamed.new
    unn.name = "some value"
    unn.prop1 = 1

    named = Named.new({:name => "some other value", :hasUnnammed => [unn]})
    if named.exist?
      item = Goo::Base::Resource.load(named.resource_id)
      item.delete
      assert_equal false, item.exist?(reload=true)
    end
    named.save
    assert_equal true, named.exist?(reload=true)
    assert_equal 1, count_pattern("#{named.resource_id.to_turtle} a ?type .")
    assert_equal 1, count_pattern("#{unn.resource_id.to_turtle} a ?type .")
    named.delete
    assert_equal false, named.exist?(reload=true)
    assert_equal 0, count_pattern("#{named.resource_id.to_turtle} a ?type .")
    assert_equal 0, count_pattern("#{unn.resource_id.to_turtle} a ?type .")
  end
end
