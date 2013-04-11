require_relative 'test_case'

TestInit.configure_goo

class NoUniqueFailInFind < Goo::Base::Resource
  attribute :x
  attribute :y

  def initialize(attributes = {})
    super(attributes)
  end
end

class SomethingWithIRI < Goo::Base::Resource
  attribute :name , :unique => true
  attribute :some_iri, :instance_of => { :with => RDF::IRI }
  attribute :iri_one, :instance_of => { :with => RDF::IRI }, :single_value => true

end

class TwoUniquesWrong < Goo::Base::Resource
  attribute :x , :unique => true
  attribute :y , :unique => true

  def initialize(attributes = {})
    super(attributes)
  end
end

class StatusPersist < Goo::Base::Resource
  model :status, :schemaless => :true
  attribute :description, :unique => true

  def initialize(attributes = {})
    super(attributes)
  end
end

class PersonPersist < Goo::Base::Resource
  model :person_persist, :schemaless => true
  attribute :name, :unique => true
  attribute :multiple_vals, :cardinality => { :maximum => 2 }
  attribute :birth_date, :date_time_xsd => true, :cardinality => { :max => 1, :min => 1  }
  attribute :created, :date_time_xsd => true, :cardinality => { :min => 1  },
            :single_value=> true, :default => lambda { |record| DateTime.now }
  attribute :friends, :not_nil => false
  attribute :status ,  :default => lambda { |record| StatusPersist.find("single") }, :single_value=> true, :instance_of => { :with => :status }

  def initialize(attributes = {})
    super(attributes)
  end
end

class University < Goo::Base::Resource
  model :university, :schemaless => :true
  attribute :name, :unique => true
  attribute :location,  :instance_of => { :with => :location }
  attribute :students,  :instance_of => { :with => :person_persist }
  attribute :status,  :instance_of => { :with => :status }
  attribute :iri_value, :instance_of => { :with => RDF::IRI }, :single_value  => true
end

class Location < Goo::Base::Resource
  model :location, :schemaless => :true
end

class TestModelPersonPersistB < TestCase

  def initialize(*args)
    super(*args)
 end

  def test_person_save
    data = PersonPersist.all
    data.each do |p|
      p.load(nil,load_attrs: :all)
      p.delete
    end
    person = PersonPersist.new({:name => 'Goo " Fernandez',
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
      person_copy.load(person.resource_id,load_attrs: :all)
      person_copy.delete
      no_triples_for_subject(person.resource_id)
    end
    assert_equal false, person.exist?(reload=true)
    person.save
    assert_raises Goo::Base::KeyFieldUpdateError do
      person_update = PersonPersist.new()
      person_update.load(person.resource_id, load_attrs: :all)
      person_update.name = "changed name"
    end
    person = PersonPersist.find( "Goo Fernandez",  load_attrs: :all)
    person.delete
    no_triples_for_subject(person.resource_id)
  end

  def test_person_update_status
    init_status
    person = PersonPersist.new({:name => "Goo Fernandez",
                        :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                        :some_stuff => [1]})

    #default value must saved on nil
    assert person.created.nil?
    assert person.status.nil?

    if person.exist?
      person_copy = PersonPersist.new
      person_copy.load(person.resource_id)
      person_copy.delete
    end
    assert_equal false, person.exist?(reload=true)
    person.save
    assert_instance_of StatusPersist, person.status
    assert_equal 1, count_pattern("#{person.resource_id.to_turtle} <http://goo.org/default/status> ?value .")
    assert_instance_of DateTime, person.created

    #modify status
    person.status = StatusPersist.find("married")
    person.save

    person = PersonPersist.find("Goo Fernandez", load_attrs: :all)
    person.status.load
    assert_equal "married", person.status.description

    person.delete
    assert_equal false, person.exist?(reload=true)
    no_triples_for_subject(person.resource_id)
  end

  def test_person_update_date
    person = PersonPersist.new({:name => "Goo Fernandez",
                        :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                        :some_stuff => [1]})

    #default value must saved on nil
    assert person.created.nil?

    if person.exist?
      person_copy = PersonPersist.new
      person_copy.load(person.resource_id)
      person_copy.delete
    end
    assert_equal false, person.exist?(reload=true)
    person.save
    person_update = PersonPersist.new()
    person_update.load(person.resource_id, load_attrs: :all)

    #default value is there
    created_time = person_update.created
    assert_equal 1, count_pattern("#{person_update.resource_id.to_turtle} <http://goo.org/default/created> ?value .")
    assert_instance_of DateTime, created_time.parsed_value

    #update field
    person_update.birth_date = DateTime.parse("2013-01-01T07:00:00.000Z")

    person_update.save
    assert_equal 1, count_pattern("#{person_update.resource_id.to_turtle} a ?type .")
    assert_equal DateTime.parse("2013-01-01T07:00:00.000Z"), person_update.birth_date
    #reload
    person_update = PersonPersist.new()
    person_update.load(person.resource_id, load_attrs: :all)
    assert_equal DateTime.parse("2013-01-01T07:00:00.000Z"), person_update.birth_date
    assert_equal "Goo Fernandez", person_update.name

    #making sure default values do not change in an update
    assert_equal created_time.parsed_value.xmlschema, person_update.created.parsed_value.xmlschema

    person_update.delete
    assert_equal false, person_update.exist?(reload=true)
    assert_equal 0, count_pattern("#{person_update.resource_id.to_turtle} a ?type .")
    no_triples_for_subject(person_update.resource_id)
  end

  def test_person_default_value_and_validation
    person = PersonPersist.new({:name => "Goo Fernandez",
                    :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                    :some_stuff => [1]})
    if person.exist?
      person_copy = PersonPersist.new
      person_copy.load(person.resource_id)
      person_copy.delete
    end
    assert(person.valid?)
    assert(person.errors[:created].nil?)
    no_triples_for_subject(person.resource_id)
  end

  def test_person_add_remove_property
    person = PersonPersist.new({:name => "Goo Fernandez",
                        :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                        :some_stuff => [1]})
    if person.exist?
      person_copy = PersonPersist.new
      person_copy.load(person.resource_id)
      value = person_copy.delete
      assert(value.nil?)
    end
    assert_equal false, person.exist?(reload=true)
    person.save
    person_update = PersonPersist.new()
    person_update.load(person.resource_id, :load_attrs => :all)
    person_update.some_date =  DateTime.parse("2013-01-01T07:00:00.000Z")
    assert_equal true, person_update.valid?
    person_update.save
    assert_equal 1, count_pattern("#{person_update.resource_id.to_turtle} <#{person_update.class.uri_for_predicate(:some_date)}> ?type .")
    #reload
    person_update = PersonPersist.new()
    person_update.load(person.resource_id, load_attrs: :all)
    assert_instance_of(PersonPersist, person_update)
    assert [DateTime.parse("2013-01-01T07:00:00.000Z")] == person_update.some_date
    #equivalent to remove
    person_update.some_date = []
    x = person_update.save
    assert_instance_of(PersonPersist, x)
    assert_equal(x, person_update)
    person_update = PersonPersist.new()
    same_inst = person_update.load(person.resource_id, :load_attrs => :all)
    assert_equal(same_inst, person_update)
    assert_equal nil, person_update.some_date
    xx = person_update.delete
    assert(xx.nil?)
    assert_equal false, person_update.exist?(reload=true)
    no_triples_for_subject(person_update.resource_id)
  end

  def init_status
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
    return statuses
  end

  def test_person_dependent_persisted
    statuses = init_status
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
      cpy = person_copy.load(person.resource_id)
      assert_instance_of(PersonPersist,cpy)
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
      rid = t.resource_id
      t.delete
      assert_equal 0, count_pattern("#{rid.to_turtle} a ?type .")
    end
    no_triples_for_subject(person.resource_id)
  end

  def test_model_by_def_name
    cls = Goo.find_model_by_name(:person_persist)
    assert (cls == PersonPersist)
    cls = Goo.find_model_by_name(:status)
    assert (cls == StatusPersist)
  end

  def test_dependent_model_already_exists_fail
    University.all.each do |u|
      u.load
      u.delete
    end
    PersonPersist.all.each do |u|
      u.load
      u.delete
    end

    u = University.new(name: "Stanford")
    assert u.valid?
    u.save

    p = PersonPersist.new(name: "Goo Sanchez", birth_date: DateTime.parse("2012-10-04T07:00:00.000Z"))
    p.studiesAt = University.new(name: "Stanford")
    assert !p.valid?
    assert p.errors[:studiesAt]
    p.studiesAt= University.find("Stanford")
    assert p.valid?

    p.studiesAt=u
    assert p.valid?

  end

  def test_instance_of_with_model_definitions
    University.all.each do |u|
      u.load
      u.delete
    end
    PersonPersist.all.each do |u|
      u.load
      u.delete
    end
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
    u.students = [person]
    u.iri_value = RDF::IRI.new("http://some.org/iri")
    u.status = StatusPersist.new({:description => "OK" })
    assert(u.valid?)
    u.save
    assert u.resource_id.value["university"]
    assert person.resource_id.value["person_persist"]
    u.xxxx = "xxxx"
    assert(u.valid?)
    u.save
    u = University.find("Stanford")
    assert (not u.nil?)

    stanford = University.find("Stanford")
    students = stanford.students
    students.each do |s|
      s.load
      assert s.some_stuff.length == 1
    end

    models = [University, PersonPersist, StatusPersist]
    models.each do |m|
      m.all.each do |i|
        i.load(nil, load_attrs: :all)
        i.delete
        no_triples_for_subject(i.resource_id)
      end
    end

  end

  def test_exception_on_get_lazy_load
    person = PersonPersist.new({:name => "Goo Fernandez",
                        :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                        :some_stuff => [1]})
    if person.exist?
      person_copy = PersonPersist.new
      person_copy.load(person.resource_id,load_attrs: :all)
      person_copy.delete
    end
    assert_equal false, person.exist?(reload=true)
    person.save

    PersonPersist.all.each do |p|
      x = p.name
      assert_instance_of(String, p.name.parsed_value)
    end
    PersonPersist.all.each do |p|
      p.load(nil,load_attrs: :all)
      p.delete
    end
  end

  def test_list_university_load_attrs
    University.all.each do |u|
      u.load
      u.delete
    end

    person1 = PersonPersist.new({:name => "person1",
                         :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                         :some_stuff => [1]})

    person2 = PersonPersist.new({:name => "person2",
                         :birth_date => DateTime.parse("2013-10-04T07:00:00.000Z"),
                         :some_stuff => [2,3]})

    locs = [ ["California", "US"], ["Boston", "US"], ["Oxford", "UK"] , ["Cambridge","UK"] ,["Soton","UK"] ]
    unis = ["Stanford", "Harvard", "Oxford", "Cambridge", "Southampton"]
    unis.each_index do |i|
      u = University.new(:name => unis[i], :location => Location.new(:state =>  locs[i][0], :country => locs[i][1]))
      if (i == 0) or (i == 3)
        st_desc = "description for status"
        u.status = StatusPersist.find(st_desc) || StatusPersist.new(:description => st_desc)
      end
      if (i == 2)
        u.bogus = "bla"
      end
      if i == 0
        u.students = [person1.exist? ? PersonPersist.find("person1") : person1, person2.exist? ? PersonPersist.find("person2") : person2]
      end
      u.save
    end

    #test with no nested attr
    data = University.all :load_attrs => [:name => true, :bogus => :optional, :status => true]
    assert_equal 5, data.length
    data.each do |u|
      correct = ((!u.bogus.nil? and (u.name.value == "Oxford")) or (u.name.value != "Oxford"))
      assert(correct)
      if u.name == "Stanford" || u.name == "Cambridge"
        #lazy loading here just this attribute
        st = u.status
        assert st.length == 1
        assert_instance_of Array, st
        assert_instance_of StatusPersist, st[0]
        desc = st[0].description
        assert desc.value == "description for status"
      end
    end

    data = University.all :load_attrs => [:status]
    data.each do |u|
      if u.name == "Stanford" || u.name == "Cambridge"
        #lazy loading here just this attribute
        st = u.status
        assert_instance_of Array, st
        assert_instance_of StatusPersist, st[0]
        desc = st[0].description
        assert desc.value == "description for status"
      end
    end



    data = University.all :load_attrs => [:name => true]
    assert_equal 5, data.length
    data.each do |u|
      assert ((unis.index u.name.value) != nil)
    end

    data = University.all :load_attrs => [:name => true, :bogus => true]
    assert_equal 5, data.length
    u =  (data.select { |u| !u.bogus.empty? })[0]
    correct = (!u.bogus.empty? and (u.name.value == "Oxford"))
    assert correct

    data.each do |u|
      assert ((unis.index u.name.value) != nil)
    end

    data = University.where :name => "Oxford", :load_attrs => [:bogus => true]
    assert_equal 1, data.length
    assert_equal "bla", data[0].bogus[0].value
    assert !(data[0].attr_loaded? :name)
    assert (data[0].attr_loaded? :bogus)
    assert !(data[0].attr_loaded? :status)

    data = University.where :name => "Oxford", :load_attrs => [:name => true]
    assert_equal 1, data.length
    assert_equal "Oxford", data[0].name.value


    data = University.where :name => "Stanford", :load_attrs => [:name => true]
    assert_equal 1, data.length
    assert_equal "Stanford", data[0].name.value
    stanford = data[0]
    students = stanford.students
    students.each do |student|
      assert_instance_of String , student.name.value
    end

    University.all.each do |u|
      u.load(nil,load_attrs: :all)
      u.delete
    end
  end

  def test_too_many_unique
    t = TwoUniquesWrong.new
    t.x = 1
    t.x = 0
    begin
      t.valid?
      assert(1 == 0)
    rescue => e
      assert_instance_of(Goo::Naming::InvalidResourceId, e)
    end
  end

  def test_no_unique_fail_find
    begin
      NoUniqueFailInFind.find("bogus")
      assert(1 == 0)
    rescue => e
      assert_instance_of ArgumentError, e
    end
  end

  def test_encoded_find_and_where
    University.all.each do |u|
      u.load
      u.delete
    end
    name = "some nasty name !@\#$%^&*()_+"
    u = University.new(name: name)
    assert u.valid?
    u.save

    x = University.find(name)
    x.load unless x.loaded?
    assert x.name.parsed_value == name

    l = University.where name: name
    assert_equal 1, l.length
    x.load unless x.loaded?
    assert x.name.parsed_value == name

  end

  def test_something_with_iris
    SomethingWithIRI.all.each do |u|
      u.load
      u.delete
    end

    iri1 = RDF::IRI.new("http://foo.com/baa/1")
    iri2 = RDF::IRI.new("http://foo.com/baa/2")
    iri3 = RDF::IRI.new("http://foo.com/baa/3")

    ss = SomethingWithIRI.new(name: "uri_name", :some_iri => [iri1, iri2], iri_one: iri3)
    assert ss.valid?
    ss.save
    loaded = SomethingWithIRI.find("uri_name")
    assert (ss.iri_one.kind_of? RDF::IRI)
    assert (ss.some_iri[0].kind_of? RDF::IRI)
    assert (ss.some_iri[1].kind_of? RDF::IRI)

    loaded = SomethingWithIRI.where(name: "uri_name")[0]
    assert (ss.iri_one.kind_of? RDF::IRI)
    assert (ss.some_iri[0].kind_of? RDF::IRI)
    assert (ss.some_iri[1].kind_of? RDF::IRI)

    SomethingWithIRI.all.each do |u|
      u.load
      u.delete
    end

  end

end
