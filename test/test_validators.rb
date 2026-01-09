require_relative 'test_case'

require_relative 'models'

class Person < Goo::Base::Resource
  model :person_model_validators, name_with: :name
  attribute :name, enforce: [:string, :existence]
  attribute :username, enforce: [:string, :existence, :username]
  attribute :last_name, enforce: [:string]
  attribute :multiple_values, enforce: [ :list, :integer]
  attribute :one_number, enforce: [ :integer ]
  attribute :birth_date, enforce: [ :date_time ]
  attribute :male, enforce: [:boolean]
  attribute :social, enforce: [:uri]
  attribute :email, enforce: [:email]
  attribute :socials, enforce: [:uri, :list]
  attribute :weight, enforce: [:float]
  attribute :friends, enforce: [Person, :list]
end

class SafeTextTestModel < Goo::Base::Resource
  model :safe_text_test_model, name_with: :name
  attribute :first_name, enforce: [:safe_text_5, :existence]
  attribute :last_name, enforce: [:safe_text_8, :existence]
  attribute :description, enforce: [:safe_text, :existence]
end

class RangeTestModel < Goo::Base::Resource
  model :range_test_model, name_with: :name
  attribute :name, enforce: [:string, :existence, :min_3, :max_5]
  attribute :multiple_values, enforce: [ :list, :integer, :min_3, :max_5 ]
  attribute :one_number, enforce: [ :integer,  :min_3, :max_5]
  attribute :weight, enforce: [:float, :min_3, :max_5]
end

class SymmetricTestModel < Goo::Base::Resource
  model :symmetric_test_model, name_with: :name
  attribute :name, enforce: [:unique, :existence]
  attribute :friend, enforce: [SymmetricTestModel, :symmetric]
  attribute :friends, enforce: [SymmetricTestModel, :symmetric, :list]
end

class DistinctOfTestModel < Goo::Base::Resource
  model :distinct_of_test_model, name_with: :name
  attribute :name, enforce: [:unique, :existence, :string]
  attribute :last_name, enforce: [:distinct_of_name, :string]
  attribute :names, enforce: [:list, :string]
  attribute :last_names, enforce: [:list, :distinct_of_names, :string]
end

class SuperiorToTestModel < Goo::Base::Resource
  model :superior_to_test_model, name_with: :name
  attribute :name, enforce: [:unique, :existence, :string]
  attribute :birth_date, enforce: [:date_time]
  attribute :death_date, enforce: [:superior_equal_to_birth_date, :date_time]
end

class InverseOfTestModel < Goo::Base::Resource
  model :inverse_test_model_one, name_with: :name
  attribute :name, enforce: [:unique, :existence, :string]
  attribute :state, enforce: [InverseOfTestModel]
  attribute :city, enforce: [:inverse_of_state, InverseOfTestModel]
  attribute :states, enforce: [InverseOfTestModel, :list]
  attribute :cities, enforce: [:inverse_of_states, InverseOfTestModel, :list]
end


class ProcValidatorsTestModel < Goo::Base::Resource
  model :proc_validator_test_model, name_with: :name
  attribute :name, enforce: [:unique, :equal_to_test]
  attribute :last_name, enforce: [:unique, ->(inst, attr) {  equal_to_test_2(inst, attr)}]


  def self.equal_to_test_2(inst, attr)
    value = inst.send(attr)

    return nil if value && value.eql?('test 2')

    [:equal_to_test_2, "#{attr} need to be equal to `test 2`"]
  end

  def equal_to_test(inst, attr)
    value = inst.send(attr)

    return nil if  value && value.eql?('test')

    [:equal_to_test, "#{attr} need to be equal to `test`"]
  end
end

class TestValidators < MiniTest::Unit::TestCase

  def self.before_suite
    begin
      GooTestData.create_test_case_data
    rescue Exception => e
      puts e.message
    end
  end

  def self.after_suite
    GooTestData.delete_test_case_data
    GooTestData.delete_all [SymmetricTestModel, InverseOfTestModel]
  end

  def test_unique_validator

    s = Student.new
    s.birth_date = DateTime.parse('1978-01-01')

    s.name = "Susan"

    refute s.valid?

    s.name = "new"

    assert s.valid?
  end

  def test_username_validator
    p = Person.new
    p.name = "Susan"
    p.username = "goodusername"
    assert p.valid?

    p.username = "good_username"
    assert p.valid?

    p.username = "good.username"
    assert p.valid?

    p.username = "bad-username"
    refute p.valid?

    p.username = "1badusername"
    refute p.valid?

    p.username = "badusername with spaces"
    refute p.valid?

    p.username = "<input type=\"text\" value=\"jaVasCript:/*-/*`/*\\`/*'/*\"/**/(/* */oNcliCk=alert(1) )//%0D%0A%0d%0a//</stYle/</titLe/</teXtarEa/</scRipt/--!>\\x3csVg/<sVg/oNloAd=alert(2)//>\\x3e\"></input>"
    refute p.valid?
  end

  def test_safe_text_validator
    m = SafeTextTestModel.new
    m.first_name = 'Susan'
    m.last_name = 'Johnson'
    m.description = 'The name Susan carries a rich history and evokes a sense of grace, warmth, and intelligence. While its popularity has somewhat declined, it remains a classic name with a positive reputation and a strong legacy of accomplished individuals associated with it.'
    assert m.valid?

    m.first_name = 'Michael'
    refute m.valid?
    assert_equal 1, m.errors.keys.length
    assert m.errors[:first_name][:safe_text_5].include?('and must not exceed 5 characters')

    m.first_name = 'Joe'
    m.description = 'The name Susan 🌍 carries a rich history'
    refute m.valid?
    assert_equal 1, m.errors.keys.length
    assert_equal :description, m.errors.keys[0]

    m.description = "I am a valid description"
    assert m.valid?

    m.description = "临床表现"
    assert m.valid?

    m.description = "This string contains\na newline"
    refute m.valid?

    m.description = "This string has a tab\tcharacter"
    refute m.valid?

    m.description = "Price is < than $1!"
    refute m.valid?

    m.description = "This has\u200Bhidden content"
    refute m.valid?

    m.description = "Normal text\u202Eevil.com"
    refute m.valid?
  end

  def test_existence_validator
    s = Student.new

    refute s.valid?

    assert s.errors[:name][:existence]
    assert s.errors[:birth_date][:existence]


    s.name = ''
    s.birth_date = ''
    assert s.errors[:name][:existence]
    assert s.errors[:birth_date][:existence]


    s.name = 'new'
    s.birth_date = DateTime.parse('1978-01-01')

    assert s.valid?
  end

  def test_datatype_validators
    p = Person.new
    p.name =  'test'
    p.username = 'test_username'
    #nil  values are valid
    assert p.valid?

    p.last_name =  false
    p.multiple_values = "hello"
    p.one_number = "hello"
    p.birth_date = 100
    p.male =  "ok"
    p.social =  100
    p.socials =  [100]
    p.weight =  100
    p.email = "test@test"
    #wrong types are not valid
    refute p.valid?
    assert p.errors[:last_name][:string]
    assert p.errors[:multiple_values][:list]
    assert p.errors[:multiple_values][:integer]
    assert p.errors[:one_number][:integer]
    assert p.errors[:birth_date][:date_time]
    assert p.errors[:male][:boolean]
    assert p.errors[:social][:uri]
    assert p.errors[:email][:email]

    p.last_name =  "hello"
    p.multiple_values = [22,11]
    p.one_number = 12
    p.birth_date = DateTime.parse('1978-01-01')
    p.male =  true
    p.social = RDF::URI.new('https://test.com/')
    p.socials = [RDF::URI.new('https://test.com/'), RDF::URI.new('https://test.com/')]
    p.weight =  100.0
    p.email = "test@test.hi.com"
    #good types are  valid
    assert p.valid?
  end

  def test_uri_datatype_validator
    p = Person.new
    p.name =  'test'
    p.username = 'test_username'
    assert p.valid?

    p.social =  RDF::URI.new('') #empty uri
    refute p.valid?

    p.social =  RDF::URI.new('wrong/uri')
    refute p.valid?

    p.social =  RDF::URI.new('https://test.com/')
    assert p.valid?
  end

  def test_object_type_validator
    p = Person.new
    p.name =  'test'
    p.username = 'test_username'
    p.friends = [1]

    refute p.valid?

    new_person = Person.new
    p.friends = [new_person]

    refute p.valid?

    new_person.persistent = true
    p.friends = [new_person]

    assert p.valid?
  end

  def test_value_range_validator
    p = RangeTestModel.new

    p.name =  "h"
    p.multiple_values = [22,11]
    p.one_number = 1
    p.weight = 1.1

    refute p.valid?
    assert p.errors[:name][:min]
    assert p.errors[:multiple_values][:min]
    assert p.errors[:one_number][:min]
    assert p.errors[:weight][:min]

    p.name =  "hello hello"
    p.multiple_values = [22,11,11,33,44, 55, 66]
    p.one_number = 12
    p.weight = 12.1

    refute p.valid?
    assert p.errors[:name][:max]
    assert p.errors[:multiple_values][:max]
    assert p.errors[:one_number][:max]
    assert p.errors[:weight][:max]

    p.name =  "hello"
    p.multiple_values = [22,11,11,3]
    p.one_number = 4
    p.weight = 3.1

    assert p.valid?

  end

  def test_symmetric_validator_no_list
    p1 = SymmetricTestModel.new
    p2 = SymmetricTestModel.new
    p3 = SymmetricTestModel.new
    p1.name = "p1"
    p2.name = "p2"
    p3.name = "p3"

    p2.save
    p3.save

    p1.friend = p2

    refute p1.valid?
    assert p1.errors[:friend][:symmetric]

    p3.friend = p1

    refute p1.valid?

    p2.friend = p1
    p1.friend = p2

    assert p1.valid?

    p1.save

    assert p2.valid?
    GooTestData.delete_all [SymmetricTestModel]
  end

  def test_symmetric_validator_list
    p1 = SymmetricTestModel.new
    p2 = SymmetricTestModel.new
    p3 = SymmetricTestModel.new
    p4 = SymmetricTestModel.new
    p1.name = "p1"
    p2.name = "p2"
    p3.name = "p3"
    p4.name = "p4"

    p2.save
    p3.save
    p4.save

    p1.friends = [p2, p3]

    refute p1.valid?
    assert p1.errors[:friends][:symmetric]

    p2.friends = [p1, p3, p4]
    p3.friends = [p2]
    p4.friends = [p2]

    refute p1.valid?
    refute p2.valid?


    p3.friends = [p2, p1]

    assert p1.valid?
    p1.save

    assert p3.valid?
    p3.save


    assert p2.valid?

    p2.save

    assert p4.valid?
    GooTestData.delete_all [SymmetricTestModel]
  end

  def test_distinct_of_validator
    p = DistinctOfTestModel.new
    p.name = "p1"
    p.last_name = "p1"
    p.names = ["p1", "p2"]
    p.last_names = ["p1", "p2"]


    refute p.valid?

    p.last_name = "last name"
    p.last_names = ["last name 1", "last name 2"]

    assert p.valid?

    p.last_name = "last name"
    p.last_names = ["last name 1", "p2"]

    refute p.valid?

    p.last_name = ""
    p.last_names = []

    assert p.valid?
  end

  def test_superior_equal_to_validator
    p = SuperiorToTestModel.new
    p.name = "p"
    p.birth_date = DateTime.parse('1998-12-02')
    p.death_date = DateTime.parse('1995-12-02')

    refute p.valid?
    assert p.errors[:death_date][:superior_equal_to_birth_date]

    p.death_date = DateTime.parse('2023-12-02')

    assert p.valid?

    p.birth_date = nil

    assert p.valid?
  end

  def test_inverse_of_validator_no_list
    GooTestData.delete_all [InverseOfTestModel]
    p1 = InverseOfTestModel.new
    p2 = InverseOfTestModel.new

    p1.name = 'p1'
    p2.name = 'p2'


    p2.save

    p1.city = p2

    refute p1.valid?
    assert p1.errors[:city][:inverse_of_state]


    p2.state = p1

    assert p1.valid?

  end

  def test_inverse_of_validator_list
    GooTestData.delete_all [InverseOfTestModel]
    p1 = InverseOfTestModel.new
    p2 = InverseOfTestModel.new
    p3 = InverseOfTestModel.new
    p4 = InverseOfTestModel.new

    p1.name = 'p1'
    p2.name = 'p2'
    p3.name = 'p3'
    p4.name = 'p4'

    p2.save
    p3.save

    p1.cities = [p2,p3]

    refute p1.valid?
    assert p1.errors[:cities][:inverse_of_states]

    p2.states = [p1, p4]
    p3.states = [p2, p4]

    refute p1.valid?
    assert p1.errors[:cities][:inverse_of_states]

    p3.states = [p2, p4, p1]

    assert p1.valid?

  end


  def test_proc_validators
    p = ProcValidatorsTestModel.new
    p.name = "hi"
    p.last_name = "hi"

    refute p.valid?
    assert p.errors[:name][:equal_to_test]
    assert p.errors[:last_name][:equal_to_test_2]

    p.name = "test"
    p.last_name = "test 2"

    assert p.valid?
  end
end
