Gem::Specification.new do |s|
  s.name = 'goo'
  s.version = '0.0.2'
  s.date = '2012-11-21'
  s.summary = ""
  s.authors = ["Manuel Salvadores", "Paul Alexander"]
  s.email = 'manuelso@stanford.edu'
  s.files = Dir['lib/**/*.rb']
  s.homepage = 'http://github.com/ncbo/goo'
  s.add_dependency("activemodel")
  s.add_dependency("uuid")
  s.add_dependency("rake")
end
