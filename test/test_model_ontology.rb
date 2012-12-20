require_relative 'test_case'

TestInit.configure_goo

class Ontology < Goo::Base::Resource
  attribute :acronym, :unique => true, :cardinality => { :max => 1, :min => 1 }
  attribute :name, :cardinality => { :max => 1, :min => 1 }
  attribute :projects , :inverse_of => { :with => :project , :attribute => :ontologyUsed }
end

class Project < Goo::Base::Resource
  attribute :name, :cardinality => { :max => 1, :min => 1 }
  attribute :ontologyUsed, :instance_of => { :with => :ontology }, :cardinality => { :min => 1 }
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
           :ontologyUsed => [Ontology.new(acronym: "SNOMED", name: "SNOMED CT")]
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
      ont = Ontology.new(acronym: "SNOMED", name: "SNOMED CT")
      p = Project.new({
          :name => "Great Project",
          :ontologyUsed => [ont]
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
          :ontologyUsed => [ont]
      })
      p2.save
      assert_equal true, p2.exist?(reload=true)
      projects = ont.projects
      assert(!projects.nil?)
      assert_equal 2, projects.length
      projects.each do |p|
        assert_instance_of Project, p
        p.load
        assert_instance_of String, p.name
      end

      ont_search = Ontology.where(:projects => p)
      assert_instance_of Array, ont_search
      assert_equal 1, ont_search.length
      ont_search.each do |o|
        o.load
        assert_equal "SNOMED", o.acronym
      end
      flush()
      assert_equal 0, Project.all.length
      assert_equal 0, Ontology.all.length
    end
end
