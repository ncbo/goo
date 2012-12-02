require_relative 'test_case'

TestInit.configure_goo

class CustomValidator < Goo::Validators::Validator 
  def validate_each(record, attribute, value)
    return if value.nil? #other validators will take care of Cardinality.
    values = value
    if not (value.kind_of? Array)
      values = [value]
    end
    values.each do |v|
      if v.kind_of? Fixnum and v > options[:with_max]
        record.errors[attribute] << \
         (options[:message] || "#{attribute} cannot contain values > #{options[:with_max]}.")
      end
    end
  end
end

#zero conf model
class ContactData < Goo::Base::Resource
  def initialize(attributes = {})
    super(attributes)
  end
end

class Person < Goo::Base::Resource
  model :PersonResource, :namespace => :metadata
  attribute :name, :namespace => :omv, :unique => true
  attribute :multiple_vals, :cardinality => { :max => 2 }
  attribute :birth_date, :date_time_xsd => true, :single_value => true , :not_nil => :true
  attribute :contact_data , :instance_of => { :with => :contact_data }, :optional =>true
  attribute :custom_values , :custom => { :with_max => 999 }
  attribute :numbers , :instance_of => { :with => Fixnum }

  def initialize(attributes = {})
    super(attributes)
  end
end

class TestModelPersonA < TestCase

  def initialize(*args)
    super(*args)
  end

  def test_person
    person = Person.new({:name => "Goo Fernandez", :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"), :some_stuff => [1]})
    assert_instance_of Hash, person.class.goop_settings
    assert_equal :PersonResource, person.class.goop_settings[:model]
    assert_equal "Goo Fernandez", person.name
    assert_equal [1], person.some_stuff 
    assert_equal DateTime.parse("2012-10-04T07:00:00.000Z"), person.birth_date
    assert_equal true, person.valid?
  end
  
  def test_cardinality
    person = Person.new({:name => "Goo Fernandez", :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"), :some_stuff => [1]})
    person.multiple_vals= 1 
    person.multiple_vals << 2 
    assert_equal true, person.valid?
    person.multiple_vals << 3 
    assert_equal [1,2,3], person.multiple_vals
    assert_equal false, person.valid?
    assert_instance_of String, person.errors[:multiple_vals][0]
  end

  def test_valid_date
    person = Person.new({:name => "Goo Fernandez", :birth_date => "xxxx", :some_stuff => [1]})
    assert_equal false, person.valid?
    assert_instance_of String, person.errors[:birth_date][0]
  end

  def test_person_modify
    person = Person.new({:name => "Goo Fernandez", :some_stuff => [1]})
    person.name= "changed named"
    assert_equal "changed named", person.name
    begin 
      #cardinality error
      person.name= ["a","b"]
      #unreachable
      assert_equal 1, 0 
    rescue => e
      assert_instance_of ArgumentError, e
    end
    person.some_stuff[0] = 2
    assert_equal [2], person.some_stuff
    person.some_stuff << 123
    assert_equal [2, 123], person.some_stuff
    person.some_stuff= []
    assert_equal [], person.some_stuff 
  end

  def test_person_multiple_unique_error
    begin
      person = Person.new({:name => ["Goo Fernandez", "Value2]"] })
    rescue => e
      assert_instance_of ArgumentError, e 
    end
  end

  def test_person_unique_for_multiple_error
    begin
      person = Person.new({:name => "Unique", :some => 1 })
    rescue => e
      assert_instance_of ArgumentError, e 
    end
  end

  def test_validate_instance_of
    person = Person.new({:name => "Goo Fernandez", :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"),
                         :contact_data => ["a", "b"] })
    assert_equal false, person.valid?
    assert_equal 2, person.errors[:contact_data].length
    contact1 = ContactData.new({ :email => ["a@s.com"], :type => ["email"] })
    contact2 = ContactData.new({ :phone => ["123-123-22-22"], :type => ["phone"] })
    person = Person.new({:name => "Goo Fernandez", :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"), 
                         :contact_data => [contact1, contact2] })
    person = Person.new({:name => "Goo Fernandez", 
                         :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z") })
    person.contact_data = [contact1]
    assert_equal true, person.valid? 
    person.contact_data << contact2
    assert_equal true, person.valid? 
    person.contact_data << 10
    assert_equal false, person.valid? 
    assert_equal 1, person.errors[:contact_data].length
  end

  def test_custom_validator
    person = Person.new({:name => "Goo Fernandez", :birth_date => DateTime.parse("2012-10-04T07:00:00.000Z") })
    person.custom_values= [ 1, 2, 3]
    assert_equal true, person.valid?
    person.custom_values << 100000 
    assert_equal false, person.valid?
    assert_equal 1, person.errors[:custom_values].length
  end

  def test_multiple_valuues
    person = Person.new({:name => "Goo Fernandez"})
    person.numbers= [50,2]
    assert_equal 50, person.numbers[0]
    person.birth_date= DateTime.parse("2012-10-04T07:00:00.000Z")
    assert_equal true, person.valid?
    person.numbers << "a"
    assert_equal false, person.valid?
    assert_equal 1,person.errors[:numbers].length
  end
end
