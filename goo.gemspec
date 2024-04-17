Gem::Specification.new do |s|
  s.name = "goo"
  s.version = "0.0.2"
  s.summary = "Graph Oriented Objects (GOO) for Ruby. A RDF/SPARQL based ORM."
  s.authors = ["Manuel Salvadores", "Paul Alexander"]
  s.email = "manuelso@stanford.edu"
  s.files = Dir["lib/**/*.rb"]
  s.homepage = "http://github.com/ncbo/goo"

  s.add_dependency("addressable", "~> 2.8")
  s.add_dependency("pry")
  s.add_dependency("rdf", "= 1.0.8")
  s.add_dependency("redis")
  s.add_dependency("rest-client")
  s.add_dependency("rsolr")
  s.add_dependency("sparql-client")
  s.add_dependency("uuid")
end
