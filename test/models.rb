
PROGRAMS_AND_CATEGORIES = [ ["BioInformatics", 8, ["Medicine","Biology","Computer Science"]],
            ["CompSci", 5, ["Engineering","Mathematics","Computer Science", "Electronics"]],
            ["Medicine",10, ["Medicine", "Chemistry", "Biology"]]]

STUDENTS = [
  ["Susan", DateTime.parse('1978-01-01'), [["BioInformatics", "Stanford"]] ],
  ["John", DateTime.parse('1978-01-02'), [["CompSci", "Stanford"]] ],
  ["Tim", DateTime.parse('1978-01-03'), [["CompSci", "UPM"]] ],
  ["Daniel", DateTime.parse('1978-01-04'), [["CompSci", "Southampton"], ["BioInformatics", "Stanford"]] ],
  ["Louis", DateTime.parse('1978-01-05'), [["Medicine", "Southampton"]]],
  ["Lee", DateTime.parse('1978-01-06'), [["BioInformatics", "Southampton"]]],
  ["Robert", DateTime.parse('1978-01-07'), [["CompSci", "UPM"]]]
]

#collection on attribute
class University < Goo::Base::Resource
  model :university, name_with: :name
  attribute :name, enforce: [ :existence, :unique]
  attribute :programs, inverse: { on: :program, attribute: :university }
  attribute :address, enforce: [ :existence, :min_1, :list, :address]

  def initialize(attributes = {})
    super(attributes)
  end
end

class Address < Goo::Base::Resource
  model :address, name_with: lambda { |p| id_generator(p) }
  attribute :line1, enforce: [ :existence ]
  attribute :line2
  attribute :country, enforce: [ :existence ]
  def self.id_generator(p)
    return RDF::URI.new("http://example.org/address/#{p.line1}+#{p.line2}+#{p.country}")
  end
end

class Program < Goo::Base::Resource
  model :program, name_with: lambda { |p| id_generator(p) } 
  attribute :name, enforce: [ :existence ]
  attribute :students, inverse: { on: :student, attribute: :enrolled }
  attribute :university, enforce: [ :existence, :university ]
  attribute :category, enforce: [ :existence, :category, :list ]
  attribute :credits, enforce: [ :existence, :integer]
  def self.id_generator(p)
    return RDF::URI.new("http://example.org/program/#{p.university.name}/#{p.name}")
  end
  def initialize(*args)
    super(*args)
  end
end

class Category < Goo::Base::Resource
  model :category, name_with: :code
  attribute :code, enforce: [ :existence, :unique ]
end

class Student < Goo::Base::Resource
  model :student, name_with: :name
  attribute :name, enforce: [ :existence, :unique ]
  attribute :enrolled, enforce: [:list, :program]
  attribute :birth_date, enforce: [:date_time, :existence]
  attribute :awards, enforce: [:list]
end

module GooTestData
  TRACKED_FIXTURE_MODELS = [Student, University, Program, Category, Address].freeze

  def self.safe_model_count(model)
    model.where.include(model.attributes).all.length
  rescue StandardError => e
    warn "[GooTestData] count failed for #{model.name}: #{e.class}: #{e.message}"
    -1
  end

  def self.log_fixture_counts(stage)
    summary = TRACKED_FIXTURE_MODELS.map { |m| "#{m.name}=#{safe_model_count(m)}" }.join(", ")
    puts "[GooTestData] #{stage}: #{summary}"
  end

  def self.create_test_case_data
    log_fixture_counts("before create_test_case_data")
    addresses = {}
    addresses["Stanford"] = [Address.where(line1: "bla", line2: "foo", country: "US").first || Address.new(line1: "bla", line2: "foo", country: "US").save]
    addresses["Southampton"] = [Address.where(line1: "bla", line2: "foo", country: "UK").first || Address.new(line1: "bla", line2: "foo", country: "UK").save]
    addresses["UPM"] = [Address.where(line1: "bla", line2: "foo", country: "SP").first || Address.new(line1: "bla", line2: "foo", country: "SP").save]
    ["Stanford", "Southampton", "UPM"].each do |uni_name|
      if University.find(uni_name).nil?
        University.new(name: uni_name, address: addresses[uni_name]).save
        PROGRAMS_AND_CATEGORIES.each do |p,credits,cs|
          categories = []
          cs.each do |c|
            categories << (Category.find(c).first || Category.new(code: c).save)
          end
          prg = Program.new(name: p, category: categories, credits: credits,
                            university: University.find(uni_name).include(:name).first )
          unless prg.valid?
            raise "Program fixture is invalid for university=#{uni_name.inspect}, program=#{p.inspect}. Errors: #{prg.errors.inspect}"
          end
          prg.save if !prg.exist?
        end
      end
    end
    STUDENTS.each do |st_data|
      st = Student.new(name: st_data[0], birth_date: st_data[1])
      if st.name["Daniel"] || st.name["Susan"]
        st.awards = st.name["Daniel"] ? ["award1" , "award2"] : ["award1"]
      end
      programs = []
      st_data[2].each do |pr|
        pr = Program.where(name: pr[0], university: [name: pr[1] ])
        pr = pr.first
        programs << pr
      end
      st.enrolled= programs
      begin
        st.save
      rescue StandardError => e
        raise "#{e.class}: failed saving student fixture #{st_data[0].inspect}. #{e.message}"
      end
    end
    log_fixture_counts("after create_test_case_data")
  end

  def self.delete_test_case_data
    log_fixture_counts("before delete_test_case_data")
    delete_all [Student, University, Program, Category, Address]
    log_fixture_counts("after delete_test_case_data")
  end

  def self.delete_all(objects)
    objects.each do |obj|
      obj.where.include(obj.attributes).each do |i|
        i.delete
      end
    end
  end
end
