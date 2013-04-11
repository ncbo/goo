require_relative 'test_case'

TestInit.configure_goo

class Ontology < Goo::Base::Resource
  model :ontology,  :name_with => lambda { |record| RDF::IRI.new( "http://ontology.org/ont/#{record.acronym }/#{record.submissionId}") }
  attribute :acronym, :not_nil => true, :single_value => true
  attribute :submissionId, :not_nil => true, :single_value => true

  attribute :homePage, :uri => true
  attribute :name, :cardinality => { :max => 1, :min => 1 }
  attribute :projects , :inverse_of => { :with => :project , :attribute => :ontologyUsed }
end

class Project < Goo::Base::Resource
  attribute :name, :cardinality => { :max => 1, :min => 1 }
  attribute :ontologyUsed, :instance_of => { :with => :ontology }, :cardinality => { :min => 1 }
  attribute :some_stuff
end



class TestModelOntology < TestCase

    def initialize(*args)
      super(*args)
    end

    def flush
     Project.all.each do |p|
       p.load
       p.delete
     end
     Ontology.all.each do |o|
       o.load
       o.delete
     end
    end

    def test_valid_save
      flush()
      p = Project.new({
           :name => "Great Project",
           :ontologyUsed => [Ontology.new(acronym: "SNOMED", name: "SNOMED CT", :submissionId => 1)]
         })
      assert_equal false, p.exist?(reload=true)
      p.save
      assert_equal true, p.exist?(reload=true)
      p.delete
      assert_equal false, p.exist?(reload=true)

      flush()
      assert_equal 0, Project.all.length
      assert_equal 0, Ontology.all.length
    end

    def test_inverse_of
      flush()
      ont = Ontology.new(acronym: "SNOMED", name: "SNOMED CT", :submissionId => 1,
                         :homePage => "http://bioportal.bioontology.org/doc")
      p = Project.new({
          :name => "Great Project",
          :ontologyUsed => [ont],
          :some_stuff => [1]
      })

      begin
        #we cannot set inverse properties
        ont.projects = p
        assert(false)
      rescue => e
        assert (e.kind_of? ArgumentError)
      end
      assert_equal false, p.exist?(reload=true)
      p.save
      assert_equal true, ont.exist?(reload=true)
      assert_equal true, p.exist?(reload=true)
      p2 = Project.new({
          :name => "Not So Great",
          :ontologyUsed => [ont],
          :some_stuff => [1]
      })
      p2.save
      assert_equal true, p2.exist?(reload=true)
      projects = ont.projects
      assert(!projects.nil?)
      assert_equal 2, projects.length
      projects.each do |p|
        assert_instance_of Project, p
        assert_instance_of String, p.name.value
      end

      ont_search = Ontology.where(:projects => p)
      assert_instance_of Array, ont_search
      assert_equal 1, ont_search.length
      ont_search.each do |o|
        assert_equal "SNOMED", o.acronym.value
      end

      onts = Ontology.where(acronym: "SNOMED", submissionId: 1)
      onts[0].projects.each do |p|
        assert_raises ArgumentError do
          p.load
        end
        assert p.some_stuff.length == 1
      end

      #preloading inverse attributes in instance variables
      onts = Ontology.where(acronym: "SNOMED", submissionId: 1, load_attrs: { projects: { name: true }, acronym: true })
      project_names = onts.first.projects.map { |p| p.attributes[:name] }
      assert project_names.sort == ['Great Project','Not So Great'].sort

      iri = Ontology.all.first.resource_id
      ont = Ontology.find(iri, load_attrs: { projects: { name: true }, acronym: true })
      project_names = ont.projects.map { |p| p.attributes[:name] }
      assert project_names.sort == ['Great Project','Not So Great'].sort
      flush()
      assert_equal 0, Project.all.length
      assert_equal 0, Ontology.all.length
    end

    def test_delete_on_lazy_load
      flush()
      p = Project.new({
           :name => "Great Project",
           :ontologyUsed => [Ontology.new(acronym: "SNOMED", name: "SNOMED CT", :submissionId => 1)]
     })
     p.save
     ps = Project.where name: "Great Project"
     assert ps.length == 1
     ps = ps[0]
     ps.delete
     assert_equal 0, count_pattern("#{ps.resource_id.to_turtle} ?p ?o .")
     flush()
     assert_equal 0, Project.all.length
     assert_equal 0, Ontology.all.length
    end

    def test_setter_getter_creation_on_load
      flush()
      p = Project.new({
           :name => "Great Project",
           :ontologyUsed => [Ontology.new(acronym: "SNOMED", name: "SNOMED CT", :submissionId => 1)]
     })
     p.save
     assert_equal true, p.exist?(reload=true)
     Project.all.each do |p|
       p.load unless p.loaded?
       assert(p.respond_to? :name)
       assert(p.respond_to? :ontologyUsed)
       assert(!(p.respond_to?(:xxxxx)))
       p.ontologyUsed.each do |o|
         o.load unless o.loaded?
         assert(o.respond_to? :acronym)
         assert(o.respond_to? :name)
         assert(o.respond_to? :projects)
         assert(!(o.respond_to?(:xxxxx)))
       end
     end
     flush()
     assert_equal 0, Project.all.length
     assert_equal 0, Ontology.all.length
    end

    def test_empty_validation
      os = Ontology.new
      os.submissionId = 1
      begin
        assert(!os.valid?)
      rescue => e
        assert(1==0, "An exception should not be thrown here")
      end
    end

    def test_uri_validation
      os = Ontology.new
      os.homePage = ["http://bioportal.bioontology.org/some/valid/uri",
        "http://bioportal.bioontology.org/some/valid/uri2"]
      os.valid?
      assert(os.errors[:homePage].nil?)

      os.homePage = "http://bioportal.bioontology.org/some/valid/uri2"
      os.valid?
      assert(os.errors[:homePage].nil?)
      os.homePage = ["http://bioportal.bioontology.org/some/valid/uri",
        "not a valid uri"]
      os.valid?
      assert(!os.errors[:homePage].nil?)
      os.homePage = "not a valid uri"
      os.valid?
      assert(!os.errors[:homePage].nil?)
    end


    def test_inverse_loading
      flush()
      ont = Ontology.new(acronym: "SNOMED", name: "SNOMED CT", :submissionId => 1)
      ont.save
      p = Project.new({
            :name => "Great Project"
      })
      p.ontologyUsed = ont
      p.save
      assert ont.projects.length == 1
      flush()
    end
end
