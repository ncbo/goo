require_relative 'test_case'

class NameWith < Goo::Base::Resource
  model :name_with, name_with: lambda { |s| id_generator(s) } 
  attribute :name, enforce: [ :existence, :string, :unique ]

  def self.id_generator(inst)
    return RDF::URI.new("http://example.org/" + inst.name + "/bla")
  end
end

class NameWithAttribute < Goo::Base::Resource
  model :name_with_attribute, name_with: :name
  attribute :name, enforce: [ :existence, :string, :unique ]
end

class TestNameWith < Goo::TestCase
  def initialize(*args)
    super(*args)
  end
  
  def setup
    teardown
  end

  def teardown
    NameWith.where.all.each do |x|
      x.delete
    end
    NameWithAttribute.where.all.each do |x|
      x.delete
    end
  end

  def test_name_with
    nw = NameWith.new(name: "John")
    refute nw.exist?
    assert_instance_of(RDF::URI, nw.id)
    assert_equal("http://example.org/John/bla",nw.id.to_s)
    refute nw.exist?
    nw.save

    from_backend = NameWith.find(RDF::URI.new("http://example.org/John/bla"), include: [:name]).to_a[0]
    assert_equal("John", from_backend.name)

    another = NameWith.new(name: "John")
    assert_instance_of(RDF::URI, another.id)
    assert another.exist?
    assert_raises Goo::Base::NotValidException do
      another.save
    end

    from_backend.delete
    refute(from_backend.exist?)
    assert 0, GooTest.triples_for_subject(from_backend.id)
  end

  def test_name_with_attribute
    nw = NameWithAttribute.new(name: "John")
    assert_instance_of(RDF::URI, nw.id)
    assert_equal("http://goo.org/default/name_with_attribute/John",nw.id.to_s)
    refute nw.exist?
    nw.save

    from_backend = NameWithAttribute.find(
      RDF::URI.new("http://goo.org/default/name_with_attribute/John"),
                                 include: [:name]).to_a[0]
    assert_equal("John", from_backend.name)

    another = NameWithAttribute.new(name: "John")
    assert_instance_of(RDF::URI, another.id)
    assert another.exist?
    assert_raises Goo::Base::NotValidException do
      another.save
    end

    from_backend.delete
    refute(from_backend.exist?)
    assert 0, GooTest.triples_for_subject(from_backend.id)
  end

end
