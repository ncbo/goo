require_relative 'test_case'
require_relative 'test_where'

module TestReadOnly

  class TestReadOnlyWithStruct < TestWhere

    def initialize(*args)
      super(*args)
    end

    def setup
    end

    def test_struct
      students = Student.where(enrolled: [university: [name: "Stanford"]])
                .include(:name)
                .read_only
                .all
      students.each do |st|
        st.klass= Student
        assert st.name
        assert st.is_a?Struct
        assert st.id.class == RDF::URI
      end
    end

    def test_struct_find
      st = Student.find(RDF::URI.new("http://goo.org/default/student/Tim"))
                .read_only
                .include(:name,:birth_date)
                .first
      assert st.kind_of?(Struct)
      assert st.id == RDF::URI.new("http://goo.org/default/student/Tim")
      assert st.name == "Tim"
      assert st.birth_date.kind_of?(DateTime)
    end

    def test_embed_struct

      students = Student.where(enrolled: [university: [name: "Stanford"]])
                .include(:name)
                .include(enrolled: [:name, university: [ :address, :name ]])
                .read_only.all

      assert_equal 3, students.size
      students.each do |st|
        assert st.enrolled.any? {|e| e.is_a?(Struct) && e.university.name.eql?('Stanford')}
      end

    end
  end
end
