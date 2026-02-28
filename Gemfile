source 'https://rubygems.org'

gemspec

gem "activesupport"
gem "rake"
gem "uuid"
gem "request_store"

group :test do
  gem "minitest", '< 5.0'
  gem "pry"
  gem 'simplecov'
  gem 'simplecov-cobertura' # for submitting code coverage results to codecov.io
  gem 'ontoportal_testkit', github: 'alexskr/ontoportal_testkit', branch: 'main'
end

group :profiling do
  gem "rack-accept"
  gem "rack-post-body-to-params"
  gem "sinatra"
  gem "thin"
end

gem 'sparql-client', github: 'ncbo/sparql-client', branch: 'ontoportal-lirmm-development'
gem "rdf-raptor", github: "ruby-rdf/rdf-raptor", ref: "6392ceabf71c3233b0f7f0172f662bd4a22cd534" # use version 3.3.0 when available
gem 'net-ftp'
