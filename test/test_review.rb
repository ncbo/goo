require_relative 'test_case'

class Review < Goo::Base::Resource
      model :review
      validates :creator, :presence => true, :cardinality => { :maximum => 1 }
      validates :created, :date_time_xsd => true, :presence => true, :cardinality => { :maximum => 1 }
      validates :body, :presence => true, :cardinality => { :maximum => 1 }
      validates :ontologyReviewed, :presence => true, :cardinality => { :maximum => 1 }
      validates :usabilityRating, :cardinality => { :maximum => 1 }
      validates :coverageRating, :cardinality => { :maximum => 1 }
      validates :qualityRating, :cardinality => { :maximum => 1 }
      validates :formalityRating, :cardinality => { :maximum => 1 }
      validates :documentationRating, :cardinality => { :maximum => 1 }

      def initialize(attributes = {})
        super(attributes)
      end
end

class TestReview < Test::Unit::TestCase

  def initialize(*args)
    super(*args)
    # Setup repo connection
    if Goo.store().nil?
      Goo.configure do |conf|
        conf[:stores] = [ { :name => :main , :host => "localhost", :port => 8080 , :options => { } } ]
      end
    else
      return
    end

    # Setup Goo
    vocabs = Goo::Naming::Vocabularies.new()

    # Any property no defined in a prefix space
    # will fall under this namespace
    vocabs.default = "http://data.bioontology.org/metadata/"

    vocabs.register(:metadata, "http://data.bioontology.org/metadata/", [])
    vocabs.register_model(:metadata, :review, Review)

    Goo::Naming.register_vocabularies(vocabs)
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
