require_relative 'test_case'

GooTest.configure_goo

require_relative 'models'

class TestWhere < MiniTest::Unit::TestCase

  def initialize(*args)
    super(*args)
  end

  def self.before_suite
    begin
      GooTestData.create_test_case_data
    rescue Exception => e
      binding.pry
    end
  end

  def self.after_suite
    GooTestData.delete_test_case_data
  end

  def test_where_simple
    assert University.range(:programs) == Program

    st = University.where(name: "Stanford")
    assert st.length == 1
    st = st.first
    assert st.instance_of?(University)

    st.bring(programs: [:credits])
    assert st.programs.length == 3
    st.programs.each do |p|
      assert_instance_of Fixnum, p.credits
    end

    #nothing is loaded
    st.class.attributes.each do |attr|
      assert_raises Goo::Base::AttributeNotLoaded do
        st.send("#{attr}")
      end
    end

    st = University.where(name: "Stanford").include(University.attributes).all
    assert st.length == 1
    st = st.first
    assert assert st.instance_of?(University)
    assert st.name == "Stanford"
    assert_raises Goo::Base::AttributeNotLoaded do
      st.programs
    end
    #
    #all includes inverse
    st = University.where(name: "Stanford").include(University.attributes(:all)).all
    assert st.length == 1
    st = st.first
    assert st.instance_of?(University)
    assert st.name == "Stanford"
    assert st.programs.length == 3
    #programs here are not loaded
    pr = st.programs[0]
    pr.class.attributes.each do |attr|
      assert_raises Goo::Base::AttributeNotLoaded do
        pr.send("#{attr}")
      end
    end
    program_ids = ["http://example.org/program/Stanford/BioInformatics",
 "http://example.org/program/Stanford/CompSci",
 "http://example.org/program/Stanford/Medicine"]
   assert st.programs.map { |x| x.id.to_s }.sort == program_ids

  end

  def test_all
    cats = Category.where().include(Category.attributes).all
    cats.each do |cats|
      assert_instance_of String, cats.code
    end
    #equivalent
    cats = Category.where.include(Category.attributes).all
    cats.each do |cats|
      assert_instance_of String, cats.code
    end
    assert University.where().length == 3
    assert Address.where().length == 3
    assert Category.where().length == 7
  end

  def test_where_1levels
    programs = Program.where(name: "BioInformatics", university: [ name: "Stanford"  ]).all
    assert programs.length == 1
    assert programs.first.id.to_s["Stanford/BioInformatics"]
  end

  def test_where_2levels
    programs = Program.where(name: "BioInformatics", university: [ address: [ country: "US" ]]).all
    assert programs.length == 1
    assert programs.first.id.to_s["Stanford/BioInformatics"]
    programs = Program.where(name: "BioInformatics", university: [ address: [ country: "UK" ]]).all
    assert programs.length == 1
    assert programs.first.id.to_s["Southampton/BioInformatics"]
   
    #any program from universities in the US
    programs = Program.where(university: [ address: [ country: "US" ]]).include([:name]).all
    assert programs.length == 3
    assert programs.map { |p| p.name }.sort == ["BioInformatics", "CompSci", "Medicine"]
  end

  def test_where_2levels_inverse
    unis = University.where(address: [country: "US"], programs: [category: [code: "Biology"]]).all
    assert unis.length == 1
    assert unis.first.id.to_s == "http://goo.org/default/university/Stanford"
    unis = University.where(programs: [category: [code: "Biology"]]).include(:name).all
    assert unis.length == 3
    assert unis.map { |u| u.name }.sort == ["Southampton", "Stanford", "UPM"]

    #equivalent
    unis = University.where(address: [country: "US"])
                   .and(programs: [category: [code: "Biology"]]).all
    assert unis.length == 1
    assert unis.first.id.to_s == "http://goo.org/default/university/Stanford"
  end

  def test_embed_include
    programs = Program.where.include(:name)
                  .include(university: [:name])
                  .include(category: [:code]).all

    assert programs.length == 9
    programs.each do |p|
      assert_instance_of String, p.name
      assert_instance_of University, p.university
      assert_instance_of Array, p.category
      assert p.category.length == p.category.select { |x| x.instance_of? Category }.length
      assert_instance_of String, p.university.name
      assert p.id.to_s[p.university.name]
      PROGRAMS_AND_CATEGORIES.each do |x|
        if p.id.to_s[x[0]]
          assert x[2].length == p.category.length
          p.category.each do |c|
            assert_instance_of String, c.code
            assert (x[2].index c.code)
          end
          break
        end
      end
    end
  end

  def test_embed_include_with_inverse
    unis = University.where.include(:name, programs: [:name]).all
    unis.each do |u|
      assert_instance_of String, u.name
      assert_instance_of Array, u.programs
      u.programs.each do |p|
        assert_instance_of String, p.name
      end
    end
  end

  def test_iterative_include_in_place
    unis = University.where.all
    unis_return = University.where.models(unis).include(programs: [:name]).to_a
    assert unis_return.object_id == unis.object_id
    assert unis.length == unis_return.length
    return_object_id = unis.map { |x| x.object_id }.uniq.sort
    unis_object_id = unis.map { |x| x.object_id }.uniq.sort
    assert return_object_id == unis_object_id
    unis.each do |u|
      u.programs.each do |p|
        assert_instance_of String, p.name
      end
    end

    #two levels
    unis = University.where.all
    unis_return = University.where.models(unis)
                    .include(programs: [:name, students: [:name]]).to_a
    assert unis_return.object_id == unis.object_id
    return_object_id = unis.map { |x| x.object_id }.uniq.sort
    unis_object_id = unis.map { |x| x.object_id }.uniq.sort
    assert return_object_id == unis_object_id
    st_count = 0
    unis.each do |u|
      u.programs.each do |p|
        assert_instance_of String, p.name
        assert p.students.length
        p.students.each do |s|
          st_count += 1
          assert_instance_of String, s.name
        end
      end
    end
    assert st_count == Student.all.length + 1 #one student is enrolled in two programs
    
    #two levels in steps
    unis = University.where.all

    #first step
    unis_return = University.where.models(unis).include(programs: [:name]).to_a
    assert unis_return.object_id == unis.object_id
    assert unis.length == unis_return.length
    return_object_id = unis.map { |x| x.object_id }.uniq.sort
    unis_object_id = unis.map { |x| x.object_id }.uniq.sort
    assert return_object_id == unis_object_id
    p_step_one_ids = Set.new
    unis.each do |u|
      u.programs.each do |p|
        p_step_one_ids << p.object_id
      end
    end


    #second step 
    unis_return = University.where.models(unis).include(programs: [students: [:name]]).to_a
    assert unis_return.object_id == unis.object_id
    assert unis.length == unis_return.length
    return_object_id = unis.map { |x| x.object_id }.uniq.sort
    unis_object_id = unis.map { |x| x.object_id }.uniq.sort
    assert return_object_id == unis_object_id
    p_step_two_ids = Set.new
    unis.each do |u|
      u.programs.each do |p|
        p_step_two_ids << p.object_id
      end
    end

    #nested object ids have to be the same in the second loading
    assert p_step_one_ids == p_step_two_ids
    st_count = 0
    unis.each do |u|
      u.programs.each do |p|
        assert_instance_of String, p.name
        assert p.students.length
        p.students.each do |s|
          assert_instance_of String, s.name
          st_count += 1
        end
      end
    end
    assert st_count == Student.all.length + 1 #one student is enrolled in two programs

  end

  def test_embed_two_levels
    unis = University.where.include(:name, programs: [:name, category: [:code]]).all
    unis.each do |u|
      assert_instance_of String, u.name
      assert_instance_of Array, u.programs
      u.programs.each do |p|
        assert_instance_of String, p.name
        assert_instance_of Array, p.category
        p.category.each do |c|
          assert_instance_of String, c.code
        end
      end
    end
  end


  def test_unique_object_references

    #NOTE: unique references does not apply across different slice loading
    return if Goo.slice_loading_size < 100

    #students enrolled in a specific program
    students = Student.where(enrolled: 
                             Program.find(RDF::URI.new("http://example.org/program/Stanford/BioInformatics")).first)
                  .include(:name, :birth_date, enrolled: [:name]).all
    assert students.length == 2
    assert students.map { |x| x.name }.sort == ["Daniel","Susan"]
    
    #if programs have the same id then the share the same memory reference
    programs = []
    students.each do |st|
      programs.concat(st.enrolled)
    end
    assert programs.length == 3
    programs.each do |p|
      assert_instance_of String, p.name
      programs.each do |p2|
        if p.id == p2.id
          assert p.object_id == p2.object_id
        end
      end
    end
    assert programs.uniq.length == 2

    #Students in a university
    students = Student.where(
      enrolled: [ university: University.find("Stanford").first ])
      .include(:name, :birth_date, enrolled: [category: [:code ]]).all
    assert students.length == 3
    assert students.map { |x| x.name }.sort == ["Daniel","John","Susan"]
    students = students.sort_by { |x| x.name  }
    daniel = students.first
    assert daniel.enrolled.map { |p| p.category.map { |c| c.code }.sort }.sort == [
      ["Biology", "Computer Science", "Medicine"],
      ["Computer Science", "Electronics", "Engineering", "Mathematics"]]
    john = students[1]
    assert john.enrolled.map { |p| p.category.map { |c| c.code }.sort }.sort == [
      ["Computer Science", "Electronics", "Engineering", "Mathematics"]]
    susan = students.last
    assert susan.enrolled.map { |p| p.category.map { |c| c.code }.sort }.sort == [
      ["Biology", "Computer Science", "Medicine"]]

    categories = []
    students.each do |st|
      categories.concat(st.enrolled.map { |p| p.category }.flatten)
    end
    assert categories.length == 14
    uniq_object_refs = categories.map { |x| x.object_id }.uniq
    assert uniq_object_refs.length == 6

  end

  def test_complex_include
    #Students in a university by name
    students = Student.where(enrolled: [university: [name: "Stanford"]])
                .include(:name)
                .include(enrolled: [:name, university: [ :address ]]).all

    assert students.map { |x| x.name }.sort == ["Daniel","John","Susan"]
    students.each do |s|
      s.enrolled do |p|
        assert_instance_of String, p.name
        assert_instance_of University, p.university
        assert_instance_of Array, p.university.addresses
        assert_instance_of Address, p.university.addresses.first
        assert_raises Goo::Base::AttributeNotLoaded do 
          p.university.addresses.first.country
        end
      end
    end
  end

  def test_where_join_pattern
    #louis ok
    students = Student.where(enrolled: [category: [ code: "Biology" ]])
                        .and(enrolled: [category: [ code: "Chemistry" ]]).all

    assert students.map { |x| x.id.to_s } == ["http://goo.org/default/student/Louis"] 

    #daniel, robert, tim and john ok
    students = Student.where(enrolled: [category: [ code: "Mathematics" ]])
                          .and(enrolled: [category: [ code: "Engineering" ]]).all
    assert students.map { |x| x.id.to_s }.sort == ["http://goo.org/default/student/Daniel",
    "http://goo.org/default/student/John","http://goo.org/default/student/Robert",
    "http://goo.org/default/student/Tim"] 


    pattern = Goo::Base::Pattern.new(category: [ code: "Mathematics" ])
            .join(category: [ code: "Medicine" ])
    #daniel ko. a program with both categories not a student with both categories
    #no one
    students = Student.where(enrolled: pattern).all
    assert students.length == 0

  end

  def test_where_join_3patterns
    #students in two programs from soton and stanford
    #louis ok
    students = Student.where(enrolled: [category: [ code: "Biology" ]])
                        .and(enrolled: [category: [ code: "Chemistry" ]])
                        .and(enrolled: [category: [ code: "Biology" ]])
                        .all
    assert students.map { |x| x.id.to_s } == ["http://goo.org/default/student/Louis"] 

  end

  def test_where_union_pattern
    #programs in medicine or engineering
    prs = Program.where(category: [code: "Medicine"])
                        .or(category: [code: "Engineering"]).all
    #all of them 9
    assert prs.length == 9
   
    #programs in medicine or engineering
    prs = Program.where(category: [code: "Medicine"])
                        .or(category: [code: "Chemistry"]).all
    prs.each do |p|
      assert p.id.to_s["BioInformatics"] || p.id.to_s["Medicine"]
    end
    assert prs.length == 6
  end

  def test_where_direct_attributes
    st = Student.where(name: "Daniel")
                  .or(name: "Louis")
                  .or(name: "Lee")
                  .or(name: "John").all
    assert st.length == 4

    st = Student.where(name: "Daniel")
                  .and(name: "John").all
    assert st.length == 0

    st = Student.where(name: "Daniel")
                  .and(birth_date: DateTime.parse('1978-01-04')).all
    assert st.length == 1
    assert st.first.id.to_s["Daniel"]

    st = Student.where(name: "Daniel")
                  .or(name: "Louis")
                  .and(birth_date: DateTime.parse('1978-01-04'))
    assert st.length == 1
    assert st.first.id.to_s["Daniel"]

  end

  def test_where_pattern_union_combined_with_join
    st = Student.where(name: "Daniel")
                  .or(name: "Louis")
                  .or(name: "Lee")
                  .or(name: "John")
                  .and(enrolled: [category: [ code: "Medicine" ]])
                  .and(enrolled: [category: [ code: "Chemistry" ]]).all
    
    assert st.length == 1
    assert st.first.id.to_s["Louis"]
  end

  def test_combine_where_patterns_with_include
    st = Student.where(name: "Daniel")
                       .or(name: "Susan")
                       .and(enrolled: [ category: [ code: "Medicine" ]]).all
    st.length == 2
    st.each do |p|
      assert (p.id.to_s["Susan"] || p.id.to_s["Daniel"])
    end

    st = Student.where(name: "Daniel")
                       .or(name: "Susan")
                       .and(enrolled: [ category: [ code: "Medicine" ]]) 
                          .include(:name, enrolled: [ university: [ address: [ :country ]]]).all
    assert st.length == 2
    assert st.first.name != st[1].name
    st.each do |p|
      assert (p.name == "Susan" || p.name == "Daniel")
      assert Array, p.enrolled
      assert (p.name == "Susan" && p.enrolled.length == 1) || 
        (p.name == "Daniel" && p.enrolled.length == 2) 
      assert String, p.enrolled.first.university.address.first.country
    end
  end

  def test_filter
    #current limitation filter applies only to one attribute only.
    #filter_birth_date = Goo::Filter.new(:birth_date) > DateTime.parse('2001-02-03')

    f = Goo::Filter.new(:birth_date) > DateTime.parse('1978-01-03')
    st = Student.where.filter(f).all
    assert st.map { |x| x.id.to_s }.sort == ["http://goo.org/default/student/Daniel",
 "http://goo.org/default/student/Lee",
 "http://goo.org/default/student/Louis",
 "http://goo.org/default/student/Robert"]

    f = (Goo::Filter.new(:birth_date) <= DateTime.parse('1978-01-01'))
          .or(Goo::Filter.new(:birth_date) >= DateTime.parse('1978-01-07'))
    st = Student.where.filter(f).all
    assert st.map { |x| x.id.to_s }.sort == [
 "http://goo.org/default/student/Robert",
 "http://goo.org/default/student/Susan"]

    f = (Goo::Filter.new(:birth_date) <= DateTime.parse('1978-01-01'))
          .or(Goo::Filter.new(:name) == "Daniel")
    st = Student.where.filter(f).all
    assert st.map { |x| x.id.to_s }.sort == [
 "http://goo.org/default/student/Daniel",
 "http://goo.org/default/student/Susan"]

    f = (Goo::Filter.new(:birth_date) > DateTime.parse('1978-01-02'))
          .and(Goo::Filter.new(:birth_date) < DateTime.parse('1978-01-06'))
    st = Student.where.filter(f).all
    assert st.map { |x| x.id.to_s }.sort == [
 "http://goo.org/default/student/Daniel",
 "http://goo.org/default/student/Louis",
 "http://goo.org/default/student/Tim"]


    f = Goo::Filter.new(enrolled: [ :credits ]) > 8
    st = Student.where.filter(f).all
    assert st.map { |x| x.id.to_s } == ["http://goo.org/default/student/Louis"]

    #students without awards
    f = Goo::Filter.new(:awards).unbound
    st = Student.where.filter(f)
                      .include(:name)
                      .all
    assert st.map { |x| x.name }.sort == ["John","Tim","Louis","Lee","Robert"].sort

    #unbound on some non existing property
    f = Goo::Filter.new(enrolled: [ :xxx ]).unbound
    st = Student.where.filter(f).all
    assert st.length == 7
  end

  def test_aggregated
    #students and awards default
    sts = Student.where.include(:name).aggregate(:count,:awards).all
    assert sts.length == 7
    sts.each do |st|
      agg = st.aggregates.first
      assert agg.attribute == :awards
      assert agg.aggregate == :count
      if st.name == "Susan"
        assert agg.value == 1
      elsif st.name == "Daniel"
        assert agg.value == 2
      else
        assert agg.value == 0
      end
    end

    sts = Student.where.include(:name).aggregate(:count, :enrolled).all
    sts.each do |st|
      assert (st.name == "Daniel" && st.aggregates.first.value == 2) ||
                st.aggregates.first.value == 1
    end

    #students enrolled in more than 1 program and get the programs name
    sts = Student.where.include(:name).aggregate(:count, :enrolled)
                    .all
                    .select { |x| x.aggregates.first.value > 1 }

    assert sts.length == 1
    assert sts.first.name == "Daniel"

    #Categories per student program categories
    sts = Student.where.include(:name).aggregate(:count, enrolled: [:category]).all
    assert sts.length == 7
    data = { "Tim" => 4, "John" => 4, "Susan" => 3, 
      "Daniel" => 6, "Louis" => 3, "Lee" => 3, "Robert" => 4 }
    sts.each do |st|
      assert st.aggregates.first.value == data[st.name]
    end
    
    
    #Inverse
    #universities with more than 3 programs
    us = University.where.include(:name).aggregate(:count, :programs).all
    assert us.length == 3
    us.each do |u|
      assert u.aggregates.first.value == 3
    end

    #double inverse
    us = University.where.include(:name).aggregate(:count, programs: [:students]).all
    us.each do |u|
      assert (u.name == "UPM" &&  u.aggregates.first.value == 2) ||
          (u.aggregates.first.value == 3)
    end

  end

  ##
  # more optimized way of counting that does not create objects
  def test_count
    programs = Program.where(name: "BioInformatics", university: [ address: [ country: "US" ]]).all
    assert programs.length == Program.where(name: "BioInformatics", university: [ address: [ country: "US" ]]).count

    assert 9 == Program.where.count
  end

  def test_include_inverse_with_find
    id = University.all.first.id

    u = University.find(id).include(programs: [:name]).first
    u.programs.each do |p|
      assert_instance_of String, p.name
    end

    u = University.find(id).include(programs: [:students]).first
    u.programs.each do |p|
      assert_instance_of Array, p.students
      p.students.each do |s|
        assert_instance_of Student, s
      end

    end

    u = University.find(id).include(programs: [:category]).first
    u.programs.each do |p|
      assert_instance_of Array, p.category
      p.category.each do |c|
        assert_instance_of Category, c
      end
    end
  end

end
