require_relative 'test_case'


require_relative 'models'

class TestUpdateCallBack < Goo::Base::Resource
  model :update_callback_model, name_with: :code
  attribute :code, enforce: [:string, :existence]
  attribute :name, enforce: [:string, :existence]
  attribute :first_name, onUpdate: :update_name
  attribute :last_name, onUpdate: :update_name


  def update_name(inst, attr)
    self.name = self.first_name + self.last_name
  end
end

class TestUpdateCallBacks < MiniTest::Unit::TestCase

  def self.before_suite
    GooTestData.delete_all [TestUpdateCallBack]
  end

  def self.after_suite
    GooTestData.delete_all [TestUpdateCallBack]
  end


  def test_update_callback
    p = TestUpdateCallBack.new
    p.code = "1"
    p.name = "name"
    p.first_name = "first_name"
    p.last_name = "last_name"

    assert p.valid?
    p.save

    p.bring_remaining

    assert_equal p.first_name + p.last_name, p.name

    p.last_name = "last_name2"
    p.save

    p.bring_remaining
    assert_equal  "last_name2",  p.last_name
    assert_equal p.first_name + p.last_name, p.name
  end

end

