Gem::Specification.new do |s|
  s.name = "goo"
  s.version = "0.0.2"
  s.summary = "Graph Oriented Objects (GOO) for Ruby. A RDF/SPARQL based ORM."
  s.authors = ["Manuel Salvadores", "Paul Alexander"]
  s.email = "manuelso@stanford.edu"
  s.files = Dir["lib/**/*.rb"]
  s.homepage = "http://github.com/ncbo/goo"
  s.add_dependency("activesupport")   # lib/goo/base/settings/settings.rb (core_ext/object/blank)
  s.add_dependency("addressable", "~> 2.8")
  s.add_dependency("pry")
  s.add_dependency("rdf")
  s.add_dependency("rdf-vocab")
  s.add_dependency("rdf-rdfxml")
  s.add_dependency("rdf-raptor")
  s.add_dependency("redis")
  s.add_dependency("request_store") # per-request memoization + SPARQL query count (lib/goo.rb)
  s.add_dependency("rest-client")
  s.add_dependency("rsolr")
  s.add_dependency("sparql-client", "= 3.2.2") # bolt-ons in lib/goo/sparql/ext assume 3.2.2 internals (to_s, make_post_request, parse_json_value); re-review on bump
  s.add_dependency("stoplight", "~> 5.0") # circuit breaker for Redis cache + SPARQL endpoint
  s.add_dependency("uuid")
end
