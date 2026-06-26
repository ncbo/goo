require_relative 'test_case'

class Task < Goo::Base::Resource
  model :task, name_with: :description
  attribute :description, enforce: [ :existence, :unique]

  #one task can be linked to many projects
  attribute :project, enforce: [ :list, :project ] 

  def initialize(attributes = {})
    super(attributes)
  end
end

class Project < Goo::Base::Resource
  model :project, name_with: :name
  attribute :name, enforce: [ :existence, :unique ]
  attribute :active, enforce: [ :boolean ]
  attribute :tasks, inverse: { on: Task, attribute: :project }
end



class TestInverse < Goo::TestCase

  def initialize(*args)
    super(*args)
  end

  def before_all
    Task.all.each do |x|
      x.delete
    end
    Project.all.each do |x|
      x.delete
    end
  end

  def after_all
    Task.all.each do |x|
      x.delete
    end
    Project.all.each do |x|
      x.delete
    end
  end

  def test_inverse_retrieval
    assert Project.range(:tasks) == Task
    assert Task.range(:project) == Project
    assert Goo.models[:task] == Task
    assert Goo.models[:project] == Project
    assert Project.attributes(:list).include?(:tasks)

    project = Project.new(name: "Goo")
    Project.find("Goo").first.delete if project.exist?
    assert project.valid?
    project.save
    assert Project.where.include(:tasks).all.first.tasks == []
    assert project.persistent?
    assert_equal(0,
      GooTest.count_pattern(
        "#{project.id.to_ntriples} #{project.class.attribute_uri(:tasks).to_ntriples} ?x " ))

    5.times do |i|
      task = Task.new(description: "task_#{i}", project: [ project ])
      Task.find("task_#{i}").first.delete if task.exist?
      assert task.valid?
      task.save
    end

    #task => project
    5.times do |i|
      task = Task.find("task_#{i}").include(:project).first
      assert task.project.first.id == project.id
    end

    #project => task
    project = Project.find("Goo").include(:tasks).first
    assert_equal(5, project.tasks.length)
    assert project.tasks.map { |x| x.id.to_s[33].to_i }.sort == [0,1,2,3,4]


    #do not allow to assign inverse properties
    assert_raises ArgumentError do
      project.tasks = Task.find("task_1")
    end

    3.times do |i|
      Task.find("task_#{i}").first.delete()
    end

    project = Project.find("Goo").include(Project.attributes(:all)).first
    assert_equal(2, project.tasks.length)
    
    #on save no persist inverse
    project.active = true
    project.save
    assert_equal(2, project.tasks.length)
    assert_equal(0,
      GooTest.count_pattern(
        "#{project.id.to_ntriples} #{project.class.attribute_uri(:tasks).to_ntriples} ?x " ))

    Task.find("task_3").first.delete()
    Task.find("task_4").first.delete()
    assert_equal(2, project.tasks.length)
    assert project.tasks.map { |x| x.id.to_s[33].to_i }.sort == [3,4]
    project = Project.find("Goo").include(:tasks).first
    project.delete

  end

end
