require_relative 'test_case'

class Review < Goo::Base::Resource
      model :review
      attribute :creator, :cardinality => { :max => 1, :min => 1 }
      attribute :created, :date_time_xsd => true, :cardinality => { :max => 1, :min => 1 }
      attribute :body, :cardinality => { :max => 1, :min => 1}
      attribute :ontologyReviewed, :cardinality => { :max => 1, :min => 1 }
      attribute :usabilityRating, :cardinality => { :max => 1 }
      attribute :coverageRating, :cardinality => { :max => 1 }
      attribute :qualityRating, :cardinality => { :max => 1 }
      attribute :formalityRating, :cardinality => { :max => 1 }
      attribute :documentationRating, :cardinality => { :max => 1 }

      def initialize(attributes = {})
        super(attributes)
      end
end

class TestReview < Test::Unit::TestCase

  def initialize(*args)
    super(*args)
    if Goo.store().nil?
      Goo.configure do |conf|
        conf[:stores] = [ { :name => :main , :host => "localhost", :port => 8080 , :options => { } } ]
        conf[:namespaces] = {
          :metadata => "http://data.bioontology.org/metadata/",
          :default => :metadata,
        }
      end
    end
  end

  def test_valid_review
    r = Review.new
    assert (not r.valid?)

    r.creator = "paul"
    r.created = DateTime.parse("2012-10-04T07:00:00.000Z")
    assert (not r.valid?)

    r.body = "This is a test review"
    r.ontologyReviewed = "SNOMED"
    assert r.valid?
  end

  def test_review_save
    r = Review.new({
        :creator => "paul",
        :created => DateTime.parse("2012-10-04T07:00:00.000Z"),
        :body => "This is a test review",
        :ontologyReviewed => "SNOMED"
      })

    assert_equal false, r.exist?(reload=true)
    r.save
    assert_equal true, r.exist?(reload=true)
    r.delete
    assert_equal false, r.exist?(reload=true)
  end

end
