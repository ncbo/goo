require_relative '../test_case'

class TestHookModel < Goo::Base::Resource
  model :test_hook, name_with: lambda { |s| RDF::URI.new("http://example.org/test/#{rand(1000)}") }
  after_save :update_count, :update_count_2
  after_destroy :decrease_count_2
  attribute :name, enforce: [:existence, :unique]

  attr_reader :count, :count2

  def update_count
    @count ||= 0
    @count += 1
  end

  def update_count_2
    @count2 ||= 0
    @count2 += 2
  end

  def decrease_count_2
    @count2 -= 2
  end

end

class TestHooksSetting < Goo::TestCase

  def test_model_hooks
    TestHookModel.find("test").first&.delete

    model = TestHookModel.new(name: "test").save

    assert_equal 1, model.count
    assert_equal 2, model.count2

    model.name = "test2"
    model.save

    assert_equal 2, model.count
    assert_equal 4, model.count2


    model.delete

    assert_equal 2, model.count
    assert_equal 2, model.count2

  end
end
