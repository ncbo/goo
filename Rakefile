require 'rake/testtask'

Rake::TestTask.new do |t|
  t.libs = []
  t.test_files = FileList['test/test*.rb']
end

Rake::TestTask.new do |t|
  t.libs = []
  t.name = "test:persistent"
  t.test_files = FileList['test/test_model_persistence.rb']
end

Rake::TestTask.new do |t|
  t.libs = []
  t.name = "test:person"
  t.test_files = FileList['test/test_model_person.rb']
end

Rake::TestTask.new do |t|
  t.libs = []
  t.name = "test:anon"
  t.test_files = FileList['test/test_model_bnodes.rb']
end

Rake::TestTask.new do |t|
  t.libs = []
  t.name = "test:dependent"
  t.test_files = FileList['test/test_model_dependent.rb']
end
