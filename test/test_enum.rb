require_relative 'test_case'

module TestEnum
  VALUES = ["uploaded","removed","archived"]

  class Status < Goo::Base::Resource
    model :status, name_with: :description
    attribute :description, enforce: [:existence, :unique]

    enum VALUES 
  end 

  class TestEnum < Goo::TestCase
    def initialize(*args)
      super(*args)
    end

    def test_enum
      status = Status.where.include(:description).to_a
      assert_equal 3, status.length
      assert status.sort_by { |x| x.description }.map { |y| y.description } == VALUES.sort
      VALUES.each do |x|
        st = Status.find(x).include(:description).to_a.first
        assert_equal(x,st.description)
      end
    end
  end
end
