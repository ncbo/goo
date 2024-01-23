require_relative 'test_case'

GooTest.configure_goo

class NewPersonModel < Goo::Base::Resource
  model :person_model_new, name_with: :name
  attribute :name, type: :string, enforce: [ :existence, :unique]
  attribute :multiple_values, type: [:list, :integer], enforce: [ :existence, :min_3, :max_5 ]
  attribute :one_number, type: :integer,enforce: [ :existence ] #by default not a list
  attribute :birth_date, type: :date_time, enforce: [ :existence ]

  attribute :created, type: DateTime ,
            default: lambda { |record| DateTime.now },
            namespace: :omv

  attribute :friends, type: NewPersonModel , enforce: [ :existence]
  attribute :status, type: :status, enforce: [ :existence],
            default: lambda { |record| StatusModel.find("single") }
end

class StatusModel < Goo::Base::Resource
  model :status_model, name_with: :name
  attribute :description, enforce: [ :existence, :unique]
  attribute :active, enforce: [ :existence, :boolean ], namespace: :omv

  def initialize(attributes = {})
    super(attributes)
  end
end

class PersonModel < Goo::Base::Resource
  model :person_model, name_with: :name
  attribute :name, enforce: [ :existence, :string, :unique]
  attribute :multiple_values, enforce: [ :list, :existence, :integer, :min_3, :max_5 ]
  attribute :one_number, enforce: [ :existence, :integer ] #by default not a list
  attribute :birth_date, enforce: [ :existence, :date_time ]

  attribute :created, enforce: [ DateTime ],
            default: lambda { |record| DateTime.now },
            namespace: :omv
            
  attribute :friends, enforce: [ :existence , PersonModel]
  attribute :status, enforce: [ :existence, :status ],
  			default: lambda { |record| StatusModel.find("single") }

  def initialize(attributes = {})
    super(attributes)
  end
end

class TestDSLSeeting < MiniTest::Unit::TestCase
  def initialize(*args)
    super(*args)
  end

  def test_data_type_dsl
    _test_attributes_enforce NewPersonModel
  end

  def test_attributes_set_get
    _test_attributes_enforce PersonModel
  end

  def test_default_value
    #default is on save ... returns`
    person = PersonModel.new
    assert_equal nil, person.created
  end


  private
  def _test_attributes_enforce(model)
    person = model.new
    model_key_name = model.model_name
    assert(person.respond_to? :id)
    assert(person.kind_of? Goo::Base::Resource)
    assert !person.valid?

    assert person.errors[:name][:existence]
    assert person.errors[:friends][:existence]
    assert person.errors[:status][:existence]
    assert person.errors[:birth_date][:existence]
    assert person.errors[:one_number][:existence]
    assert !person.errors[:created]

    person.name = "John"
    assert !person.valid?
    assert !person.errors[:name]

    person.name = 1
    assert_equal 1, person.name
    assert !person.valid?
    assert person.errors[:name][:string]
    person.name = "John"

    assert_equal("John", person.name)


    person.birth_date = DateTime.parse('2001-02-03T04:05:06.12')
    assert !person.valid?
    assert !person.errors[:birth_date]

    person.birth_date = "X"
    assert !person.valid?
    assert person.errors[:birth_date][:date_time]

    person.birth_date = DateTime.parse('2001-02-03T04:05:06.12')
    assert_equal(DateTime.parse('2001-02-03T04:05:06.12'), person.birth_date)
    assert !person.valid?
    assert !person.errors[:birth_date]


    person.multiple_values = [1, 2, 3, 4]
    assert !person.valid?
    assert !person.errors[:multiple_values]

    person.multiple_values = [1, 2]
    assert !person.valid?
    assert person.errors[:multiple_values][:min]

    person.multiple_values = [1, 2, 3, 4, 5, 6]
    assert !person.valid?
    assert person.errors[:multiple_values][:max]


    person.multiple_values = [1, 2, 3, "4", 5, 6]
    assert !person.valid?
    assert person.errors[:multiple_values][:max]
    assert person.errors[:multiple_values][:integer]

    person.multiple_values = [1, 2, 3, 4]
    assert !person.valid?
    assert !person.errors[:multiple_values]

    assert_raises FrozenError do
      person.multiple_values << 99
    end

    friends = [model.new , model.new]
    person.friends = friends
    assert !person.valid?
    assert person.errors[:friends][:no_list]
    person.friends = model.new
    assert !person.valid?
    assert person.errors[:friends][model_key_name]
    person.friends = "some one"
    assert !person.valid?
    assert person.errors[:friends][model_key_name]
    person.friends = model.new

    person.one_number = 99
    assert !person.valid?
    assert !person.errors[:one_number]

    person.one_number = "99"
    assert !person.valid?
    assert person.errors[:one_number][:integer]

    person.one_number = [98, 99]
    assert !person.valid?
    assert person.errors[:one_number][:no_list]

    person.one_number = 99
    assert_equal(99, person.one_number)
    assert !person.valid?
    assert !person.errors[:one_number]

    assert person.errors[:status][:existence]
    person.status = StatusModel.new

    #there are assigned objects that are not saved
    assert !person.valid?
  end
end
