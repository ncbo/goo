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
  t.test_files = FileList['test/test_model_unnamed.rb']
end

Rake::TestTask.new do |t|
  t.libs = []
  t.name = "test:review"
  t.test_files = FileList['test/test_review.rb']
end

Rake::TestTask.new do |t|
  t.libs = []
  t.name = "test:dependent"
  t.test_files = FileList['test/test_model_dependent.rb']
end

Rake::TestTask.new do |t|
  t.libs = []
  t.name = "test:find"
  t.test_files = FileList['test/test_model_find.rb']
end

desc "Run test coverage analysis"
task :coverage do
  puts "Code coverage reports will be visible in the /coverage folder"
  ENV["COVERAGE"] = "true"
  Rake::Task["test"].invoke
end

