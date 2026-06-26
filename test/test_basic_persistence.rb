require_relative 'test_case'

module Dep
  class Ontology < Goo::Base::Resource
    model :ontology, name_with: :name
    attribute :name, enforce: [:existence, :unique]
    attribute :metric, enforce: [:existence, :unique, :metric]
  end
  class Metric < Goo::Base::Resource
    model :metric, name_with: :code
    attribute :code, enforce: [:existence, :unique]
    attribute :value, enforce: [:existence, :unique]
  end
end

class ArrayValues < Goo::Base::Resource
  model :array_values, name_with: :name
  attribute :name, enforce: [ :existence, :unique ]
  attribute :many, enforce: [ :list, :string ]
end

class StatusPersistent < Goo::Base::Resource
  model :status_persistent, name_with: :description
  attribute :description, enforce: [ :existence, :unique]
  attribute :active, enforce: [ :existence, :boolean ], namespace: :omv
  attribute :code, enforce: [:unique]

  def initialize(attributes = {})
    super(attributes)
  end
end

CONTACT_DATA = Struct.new(:line1,:line2)
class PersonPersistent < Goo::Base::Resource
  model :person_persistent, name_with: :name
  attribute :name, enforce: [ :existence, :string, :unique]
  attribute :multiple_values, enforce: [ :list, :existence, :integer, :min_3, :max_5 ]
  attribute :one_number, enforce: [ :existence, :integer ] #by default not a list
  attribute :birth_date, enforce: [ :existence, :date_time ]
  
  attribute :contact_data, enforce: [ :list, CONTACT_DATA]

  attribute :created, enforce: [ DateTime ],
            default: lambda { |record| DateTime.now },
            namespace: :omv
            
  attribute :friends, enforce: [ :list, PersonPersistent ]
  attribute :status, enforce: [ :status_persistent ],
  			default: lambda { |record| StatusPersistent.find("single").first }

  def initialize(attributes = {})
    super(attributes)
  end
end

class TestBasicPersistence < Goo::TestCase
  def initialize(*args)
    super(*args)
  end

  def _purge
    objects = [ArrayValues, PersonPersistent, StatusPersistent]
    objects.each do |obj|
      obj.where.all.each do |st|
        st.delete
      end
    end
  end

  def setup
    _purge
  end

  def teardown
    _purge
  end

  def test_simple_save_delete
    st = StatusPersistent.new(description: "some text", active: true)
    assert_equal("some text", st.description)
    assert st.valid?
    refute st.persistent?
    assert st.modified?
    refute st.exist?
    assert_equal st, st.save 
    assert st.persistent?
    refute st.modified?
    assert_nil st.delete
    refute st.exist?
    refute st.persistent?
    refute st.modified?
  end

  def test_unique_duplicates_error
    StatusPersistent.where.all.each do |st|
      st.delete
    end
    st = StatusPersistent.new(description: "some text", active: true)
    assert st.valid?
    st.save
    st = StatusPersistent.new(description: "some text", active: true)
    refute st.valid?
    assert_instance_of String, st.errors[:description][:duplicate]
    st = StatusPersistent.new(description: "some text 2", active: true)
    assert st.valid?
    st.save
    StatusPersistent.where.all.each do |st|
      st.delete
    end
  end

  def test_multiple_unique_attributes
    st = StatusPersistent.new(description: "some text", active: true, code: "001")
    assert st.valid?
    st.save

    #same object but new. We cannot a save duplicate id.
    #code should not contains errors because we cannot tell apart the resources.
    st = StatusPersistent.new(description: "some text", active: true, code: "001")
    refute st.valid?
    assert_instance_of String, st.errors[:description][:duplicate]
    assert_nil st.errors[:code]

    #here a differente description therefore a different resource.
    #code should contain a duplication error.
    st = StatusPersistent.new(description: "some text 2", active: true, code: "001")
    refute st.valid?
    assert_instance_of String, st.errors[:code][:unique]

    st = StatusPersistent.new(description: "some text 2", active: true, code: "002")
    assert st.valid?
    st.save
  end

  def test_not_valid_save
    st = StatusPersistent.new({ description: "some text", active: "true" })
    assert_raises Goo::Base::NotValidException do
      st.save
    end
    refute st.persistent?
  end

  def test_find
    st = StatusPersistent.new({ description: "some text", active: true })
    st.save
    assert st.persistent?
    
    id = st.id
    st_from_backend = StatusPersistent.find(id).first
    assert_instance_of StatusPersistent, st_from_backend
    assert_kind_of Goo::Base::Resource, st_from_backend
    assert_equal id, st_from_backend.id

    st.class.attributes.each do |attr|
      assert_raises Goo::Base::AttributeNotLoaded do
        st_from_backend.send("#{attr}")
      end
    end

    assert st_from_backend.persistent?
    refute st_from_backend.modified?

    assert_nil st_from_backend.delete
    refute st_from_backend.exist?

    not_existent_id = RDF::URI("http://some.bogus.id/x")
    st_from_backend = StatusPersistent.find(not_existent_id).first
    assert_nil st_from_backend
  end

  def test_find_load_all
    st = StatusPersistent.new({ description: "some text", active: true })
    st.save
    assert st.persistent?
    
    id = st.id
    st_from_backend = StatusPersistent.find(id).include(StatusPersistent.attributes).first
    assert (st_from_backend.persistent?)
    assert (!st_from_backend.modified?)

    st.class.attributes.each do |attr|
      expected = st.send("#{attr}")
      actual = st_from_backend.send("#{attr}")
      # minitest 6 rejects assert_equal(nil, ...); branch so a nil expected value still compares
      expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
    end
    assert st_from_backend.fully_loaded?
    assert (st_from_backend.missing_load_attributes.length == 0)

    assert_nil st_from_backend.delete
    refute st_from_backend.exist?
  end

  def test_find_load_some
    st = StatusPersistent.new({ description: "some text", active: true })
    st.save
    assert st.persistent?
    
    id = st.id
    st_from_backend = StatusPersistent.find(id).include(:active).first
    assert (st_from_backend.persistent?)
    assert (!st_from_backend.modified?)

    assert (st_from_backend.active == true)
    assert_raises Goo::Base::AttributeNotLoaded do
      st_from_backend.description
    end

    refute st_from_backend.fully_loaded?
    assert (st_from_backend.missing_load_attributes.length == 2)
    assert (st_from_backend.missing_load_attributes.include?(:description))

    assert_nil st_from_backend.delete
    refute st_from_backend.exist?
  end

  def test_update_name_with_attribute
    #fail when updating a unique field
    st = StatusPersistent.new({ description: "some text", active: true })
    st.save
    assert st.persistent?

    assert_raises ArgumentError do
      st.description = "x"
    end

    from_backend = StatusPersistent.find(st.id).first
    assert_raises ArgumentError do
      from_backend.description = "x"
    end
  end

  def test_find_with_string
    st = StatusPersistent.new({ description: "some text", active: true })
    st.save
    assert st.persistent?
    st_from_backend = StatusPersistent.find("some text").include(:active).first
    assert_instance_of(StatusPersistent, st_from_backend)
    assert_equal(st.id, st_from_backend.id)
    assert(st_from_backend.active)
    st_from_backend.delete

    st_from_backend = StatusPersistent.find("not there").first
    assert_nil st_from_backend
  end

  def test_update
    st = StatusPersistent.new({ description: "some text", active: true })
    st.save
    assert st.persistent?

    st.active = false
    assert(st.modified?)
    st.save
    refute(st.modified?)

    st_from_backend = StatusPersistent.find(st.id).include(:active).first
    assert (st_from_backend.persistent?)
    refute st_from_backend.modified?
    refute(st_from_backend.active)

    assert_nil st_from_backend.delete
    refute st_from_backend.exist?
  end

  def test_update_array_values
    # Object should always return frozen arrays, so that we detect the set
    arr = ArrayValues.new(name: "x" , many: ["a", "b"])
    assert arr.valid?
    arr.save
    assert arr.persistent?
    assert arr.exist?

    arr_from_backend = ArrayValues.find(arr.id).include(ArrayValues.attributes).first
    assert_equal ["a", "b"], arr_from_backend.many.sort

    assert_raises FrozenError do
      arr_from_backend.many << "c"
    end

    arr_from_backend.many = ["A", "B", "C"]
    arr_from_backend.save

    arr_from_backend = ArrayValues.find(arr.id).include(ArrayValues.attributes).first
    assert_equal ["A", "B", "C"], arr_from_backend.many.sort

    arr_from_backend.delete
    refute arr_from_backend.exist?
  end

  def test_person_save
    st = StatusPersistent.new(description: "single", active: true)
    st = st.exist? ? StatusPersistent.find("single").first : st.save

    person = PersonPersistent.new
    person.name = "John"
    person.multiple_values = [1,2,3,4]
    person.one_number = 99
    person.birth_date = DateTime.parse('2001-02-03T04:05:06.12')
    assert person.valid?
    person.save
    assert person.persistent?
    refute person.modified?

    assert_nil person.friends

    #default st and created
    assert_instance_of(StatusPersistent, person.status)
    assert_instance_of(DateTime, person.created)
    assert_nil person.friends

    person_from_backend = PersonPersistent.find("John").include(PersonPersistent.attributes).first
    assert_equal(person.status.id, person_from_backend.status.id)
    assert_equal([], person_from_backend.friends)
    assert_equal(person.name, person_from_backend.name)
    assert_equal(person.multiple_values.sort, person_from_backend.multiple_values.sort)
    assert_equal(person.birth_date.xmlschema, person_from_backend.birth_date.xmlschema)
    assert_equal(person.created.xmlschema, person_from_backend.created.xmlschema)

    person_from_backend.delete
    refute person_from_backend.exist?
    st.delete
  end

  def test_friends
    st = StatusPersistent.new(description: "single", active: true)
    st = st.exist? ? StatusPersistent.find("single").first : st.save
    person1 = PersonPersistent.new(name: "John", multiple_values: [1,2,3,4], one_number: 99,
                                   birth_date: DateTime.parse('2001-02-03T04:05:06.12'))

    person2 = PersonPersistent.new(name: "Rick", multiple_values: [1,2,3,4], one_number: 99,
                               birth_date: DateTime.parse('2001-02-03T04:05:06.12'))
    person2.friends = [person1]

    #dependent objects must be persistant
    refute person2.valid?
    assert person2.errors[:friends][:person_persistent]

    person1.save

    assert person2.valid?
    person2.save

    from_backend = PersonPersistent.find(person2.id).include(:friends)
    assert_equal 1, person2.friends.length
    assert_equal person1.id, person2.friends.first.id


    person1.delete
    assert_equal 0, GooTest.triples_for_subject(person1.id)
    person2.delete
    assert_equal 0, GooTest.triples_for_subject(person2.id)
  end

  def test_empty_list
    person1 = PersonPersistent.new(name: "John", multiple_values: [1,2,3,4], one_number: 99,
                                   birth_date: DateTime.parse('2001-02-03T04:05:06.12'))
    person1.save
    assert_equal 0, PersonPersistent.find(person1.id).include(:friends).first.friends.length
    person1.delete
  end

  def test_range
    assert_equal PersonPersistent, PersonPersistent.range(:friends)
    assert_equal StatusPersistent, PersonPersistent.range(:status)
    assert_kind_of Struct, PersonPersistent.range(:contact_data).new
  end

  def test_bnode

    st = StatusPersistent.new(description: "single", active: true)
    st = st.exist? ? StatusPersistent.find("single").first : st.save
    person1 = PersonPersistent.new(name: "John", multiple_values: [1,2,3,4], one_number: 99,
                                   birth_date: DateTime.parse('2001-02-03T04:05:06.12'))
    person1.contact_data= [CONTACT_DATA.new("line1 value","line2 value")]
    assert person1.valid?
    person1.save

    from_backend = PersonPersistent.find("John").include(:birth_date, :contact_data).first
    assert_instance_of Array, from_backend.contact_data
    assert_equal 1, from_backend.contact_data.length
    assert_equal "line1 value", from_backend.contact_data.first.line1
    assert_equal "line2 value", from_backend.contact_data.first.line2

    person2 = PersonPersistent.new(name: "Lewis", multiple_values: [1,2,3,4], one_number: 99,
                                   birth_date: DateTime.parse('2001-02-03T04:05:06.12'))

    person2.contact_data= [CONTACT_DATA.new("p2 line1 value","p2 line2 value"),
                            CONTACT_DATA.new("p2 line1 value X","p2 line2 value Y")]
    person2.save

    pps = PersonPersistent.where.include(:name,:contact_data).all
    pps.each do |pp|
      if pp.name == "John"
        assert_equal 1, pp.contact_data.length
        assert_equal "line1 value", pp.contact_data.first.line1
        assert_equal "line2 value", pp.contact_data.first.line2
      elsif pp.name == "Lewis"
        assert_equal 2, pp.contact_data.length
        pp.contact_data.each do |s|
          assert (s.line1 == "p2 line1 value" && s.line2 == "p2 line2 value") ||
                    (s.line1 == "p2 line1 value X" && s.line2 == "p2 line2 value Y")
        end
      else
        flunk "unexpected person: #{pp.name}"
      end
    end

    pps.each do |p|
      p.delete
    end

    assert_equal 0, GooTest.triples_for_subject(person1.id)
    assert_equal 0, GooTest.triples_for_subject(person2.id)
    assert_equal 0, GooTest.count_pattern("?p #{Goo.vocabulary(nil)[:line1].to_ntriples} ?o")
    assert_equal 0, GooTest.count_pattern("?p #{Goo.vocabulary(nil)[:line2].to_ntriples} ?o")
    st.delete
  end

  def test_dependency_delete
    Dep::Ontology.all.each do |x|
      x.delete 
    end
    Dep::Metric.all.each do |x|
      x.delete 
    end

    ont = Dep::Ontology.new
    ont.name = "test"
    met = Dep::Metric.new
    met.code = "X"
    met.value = "val"
    met.save
    ont.metric = met
    ont.save
    assert_equal 1, Dep::Ontology.all.length
    assert_equal 1, Dep::Metric.all.length

    ont = Dep::Ontology.where.include(:metric, :name).all.first   
    
    #some other process deletes the metric
    Dep::Metric.all.first.delete

    ont.metric.delete
    ont.delete

    assert_equal 0, Dep::Ontology.all.length
    assert_equal 0, Dep::Metric.all.length

  end

end

