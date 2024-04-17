require_relative 'test_case'

#collection on attribute
class Issue < Goo::Base::Resource
  model :issue, collection: :owner, name_with: :description
  attribute :description, enforce: [ :existence, :unique]
  attribute :owner, enforce: [:user]

  def initialize(attributes = {})
    super(attributes)
  end
end

class User < Goo::Base::Resource
  model :user, name_with: :name
  attribute :name, enforce: [ :existence, :unique ]
  attribute :issues, inverse: { on: Issue, attribute: :owner }
end

class TestCollection < MiniTest::Unit::TestCase
  def initialize(*args)
    super(*args)
  end

  def test_collection
    john = User.find("John").include(:name).first || 
      User.new(name: "John").save()
    issue = Issue.find("issue1", collection: john).first || 
      Issue.new(description: "issue1", owner: john).save()
    assert !Issue.find("issue1", collection: john).nil?
    assert_raises ArgumentError do
      Issue.find("issue1").first
    end
    assert issue.owner.id == john.id

    #same reference
    assert john.object_id == Issue.find("issue1",collection: john).first.owner.object_id
    owner = Issue.find("issue1",collection: john).first.owner

    assert_equal(1,
      GooTest.count_pattern(
        "GRAPH #{owner.id.to_ntriples} { #{issue.id.to_ntriples} a ?x }" ))
    assert_equal(0,
      GooTest.count_pattern(
        "GRAPH #{owner.id.to_ntriples} { #{issue.id.to_ntriples} #{issue.class.attribute_uri(:owner).to_ntriples} ?x }" ))

    issue.delete
    assert_equal(0,
      GooTest.count_pattern(
        "GRAPH #{owner.id.to_ntriples} { #{issue.id.to_ntriples} a ?x }" ))

    john.delete
    assert_equal(0,
      GooTest.count_pattern(
        "#{john.id.to_ntriples} ?y ?x " ))
  end

  def test_unique_per_collection
    #exist? should use collection
    #same ids in different collections can save
    #different  
    john = User.find("John").include(:name).first || 
      User.new(name: "John").save()
    less = User.find("Less").include(:name).first || 
      User.new(name: "Less").save()

    issue = Issue.find("issue1", collection: john).first || 
      Issue.new(description: "issue1", owner: john).save()
    assert_equal(1,
      GooTest.count_pattern(
        "GRAPH #{john.id.to_ntriples} { #{issue.id.to_ntriples} a ?x }" ))

    assert !Issue.new(description: "issue1", owner: less).exist?
    #different owner
    issue = Issue.find("issue1", collection: less).first || 
      Issue.new(description: "issue1", owner: less).save()
    assert_equal(1,
      GooTest.count_pattern(
        "GRAPH #{less.id.to_ntriples} { #{issue.id.to_ntriples} a ?x }" ))

    assert Issue.find("issue1", collection: less).first.exist?
    assert Issue.find("issue1", collection: john).first.exist?
    Issue.find("issue1", collection: john).first.delete
    Issue.find("issue1", collection: less).first.delete
    john.delete
    less.delete
  end

  def test_inverse_on_collection
    skip "Not supported inverse on collection"

    john = User.find("John").include(:name).first || User.new(name: "John").save

    5.times do |i|
      Issue.find("issue_#{i}").in(john) || Issue.new(description: "issue_#{i}", owner: john).save
    end

    issues = User.find("John").include(:issues).first.issues
    assert_equal 5, issues.size

    issues.each do |issue|
      assert_equal "issue_#{i}", issue.description
      assert_equal john, issue.collection
    end
  end

end
