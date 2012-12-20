require_relative 'test_case'

TestInit.configure_goo

class StatusPersist < Goo::Base::Resource
  model :status
  attribute :description, :unique => true

  def initialize(attributes = {})
    super(attributes)
  end
end

class PersonPersist < Goo::Base::Resource
  attribute :name, :unique => true
  attribute :multiple_vals, :cardinality => { :maximum => 2 }
  attribute :birth_date, :date_time_xsd => true, :cardinality => { :max => 1, :min => 1  }
  attribute :created, :date_time_xsd => true, :single_value=> true, :default => lambda { |record| DateTime.now }
  attribute :friends, :not_nil => false

  def initialize(attributes = {})
    super(attributes)
  end
end

class University < Goo::Base::Resource
  attribute :name, :unique => true
  attribute :students,  :instance_of => { :with => :person_persist }
  attribute :status,  :instance_of => { :with => :status }
end

class TestModelPersonPersistB < TestCase

  def initialize(*args)
    super(*args)
 end

  def test_person_save
    data = PersonPersist.all
    data.each do |p|
      p.load
      p.delete
    end
    person = PersonPersist.new({:name => "Goo Fernandez",
                         :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                         :some_stuff => [1]})
    assert (person.valid?)
    assert_equal false, person.exist?(reload=true)
    person.save
    assert_equal true, person.exist?(reload=true)
    person.delete
    assert_equal false, person.exist?(reload=true)
    no_triples_for_subject(person.resource_id)
  end

  def test_person_update_unique
    person = PersonPersist.new({:name => "Goo Fernandez",
                        :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                        :some_stuff => [1]})
    if person.exist?
      person_copy = PersonPersist.new
      person_copy.load(person.resource_id)
      person_copy.delete
    end
    assert_equal false, person.exist?(reload=true)
    person.save
    begin
    person_update = PersonPersist.new()
    person_update.load(person.resource_id)
    person_update.name = "changed name"
    #unreachable
    assert_equal 1, 0
    rescue => e
      assert_instance_of Goo::Base::KeyFieldUpdateError, e
    end
    person_update.delete
    assert_equal false, person_update.exist?(reload=true)
  end

  def test_person_update_date
    person = PersonPersist.new({:name => "Goo Fernandez",
                        :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                        :some_stuff => [1]})
    if person.exist?
      person_copy = PersonPersist.new
      person_copy.load(person.resource_id)
      person_copy.delete
    end
    assert_equal false, person.exist?(reload=true)
    person.save
    person_update = PersonPersist.new()
    person_update.load(person.resource_id)

    #default value is there
    created_time = person_update.created
    assert_instance_of DateTime, created_time

    #update field
    person_update.birth_date =  DateTime.parse("2013-01-01T07:00:00.000Z")

    person_update.save
    assert_equal 1, count_pattern("#{person_update.resource_id.to_turtle} a ?type .")
    assert_equal DateTime.parse("2013-01-01T07:00:00.000Z"), person_update.birth_date
    #reload
    person_update = PersonPersist.new()
    person_update.load(person.resource_id)
    assert_equal DateTime.parse("2013-01-01T07:00:00.000Z"), person_update.birth_date
    assert_equal "Goo Fernandez", person_update.name

    #making sure default values do not change in an update
    assert_equal created_time.xmlschema, person_update.created.xmlschema

    person_update.delete
    assert_equal false, person_update.exist?(reload=true)
    assert_equal 0, count_pattern("#{person_update.resource_id.to_turtle} a ?type .")
  end

  def test_person_add_remove_property
    person = PersonPersist.new({:name => "Goo Fernandez",
                        :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                        :some_stuff => [1]})
    if person.exist?
      person_copy = PersonPersist.new
      person_copy.load(person.resource_id)
      person_copy.delete
    end
    assert_equal false, person.exist?(reload=true)
    person.save
    person_update = PersonPersist.new()
    person_update.load(person.resource_id)
    person_update.some_date =  DateTime.parse("2013-01-01T07:00:00.000Z")
    assert_equal true, person_update.valid?
    person_update.save
    #reload
    person_update = PersonPersist.new()
    person_update.load(person.resource_id)
    assert_equal [DateTime.parse("2013-01-01T07:00:00.000Z")], person_update.some_date
    #equivalent to remove
    person_update.some_date = []
    person_update.save
    person_update = PersonPersist.new()
    person_update.load(person.resource_id)
    assert_equal nil, person_update.some_date
    person_update.delete
    assert_equal false, person_update.exist?(reload=true)
    no_triples_for_subject(person_update.resource_id)
  end

  def test_static_load
    person = PersonPersist.new({:name => "Goo Fernandez",
                        :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                        :some_stuff => [1]})
    if person.exist?
      person_copy = PersonPersist.new
      person_copy.load(person.resource_id)
      person_copy.delete
    end
    assert_equal false, person.exist?(reload=true)
    person.save
    assert_equal true, person.exist?(reload=true)
    resource_id = person.resource_id

    #static load
    item = Goo::Base::Resource.load(resource_id)
    assert_instance_of person.class, item
    assert_equal person.resource_id.value, item.resource_id.value
    assert_equal person.name, item.name
    person.delete
    assert_equal false, item.exist?(reload=true)

    item = Goo::Base::Resource.load(resource_id)
    assert_equal nil, item
  end

  def test_person_dependent_persisted
    statuses = {}
    ["single","married","divorced"].each do |st|
      st_obj = StatusPersist.new({:description => st })
      if st_obj.exist?
        st_obj = Goo::Base::Resource.load(st_obj.resource_id)
      else
        st_obj.save
      end
      statuses[st] = st_obj
    end
    person = PersonPersist.new({:name => "Goo Fernandez",
                        :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                        :status => [statuses["married"]] },
                         )
    if person.exist?
      person_copy = PersonPersist.new
      person_copy.load(person.resource_id)
      person_copy.delete
      assert_equal 1, count_pattern("#{statuses["married"].resource_id.to_turtle} a ?type .")
    end
    assert_equal false, person.exist?(reload=true)
    person.save
    assert_equal 1, count_pattern("#{statuses["married"].resource_id.to_turtle} a ?type .")
    person.delete
    assert_equal 1, count_pattern("#{statuses["married"].resource_id.to_turtle} a ?type .")
    assert_equal 0, count_pattern("#{person.resource_id.to_turtle} a ?type .")
    sts = StatusPersist.where({})
    sts.each do |t|
      t.load
      rid = t.resource_id
      t.delete
      assert_equal 0, count_pattern("#{rid.to_turtle} a ?type .")
    end
  end

  def test_model_by_def_name
    cls = Goo.find_model_by_name(:person_persist)
    assert (cls == PersonPersist)
    cls = Goo.find_model_by_name(:status)
    assert (cls == StatusPersist)
  end

  def test_instance_of_with_model_definitions
    person = PersonPersist.new({:name => "Goo Fernandez",
                         :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                         :some_stuff => [1]})
    u = University.new
    assert(!u.valid?)
    u.name = "Stanford"
    u.students = [person]
    u.status = StatusPersist.new({:description => "OK" })
    assert(u.valid?)
    u.status = 10
    u.students = ["aaa"]
    assert(!u.valid?)

  end
end
