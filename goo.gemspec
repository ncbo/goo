Gem::Specification.new do |s|
  s.name = 'goo'
  s.version = '0.0.2'
  s.date = '2012-11-21'
  s.summary = ""
  s.authors = ["Manuel Salvadores", "Paul Alexander"]
  s.email = 'manuelso@stanford.edu'
  s.files = Dir['lib/**/*.rb']
  s.homepage = 'http://github.com/ncbo/goo'
  s.add_dependency("uuid")
  s.add_dependency("systemu") # remove when https://github.com/ahoward/macaddr/pull/20 is resolved
  s.add_dependency("rsolr")
  s.add_dependency("rdf", "= 1.0.8")
  s.add_dependency("sparql-client")
  s.add_dependency("addressable", "= 2.3.5")
  s.add_dependency("rest-client")
  s.add_dependency("redis")
  s.add_dependency("pry")
end
