source 'https://rubygems.org'

gemspec

gem "activesupport"
gem "cube-ruby", require: "cube"
gem "faraday", '~> 1.9'
gem "rake"
gem "uuid"

group :test do
  gem "minitest", '< 6.0'
  gem "pry"
  gem 'simplecov'
  gem 'simplecov-cobertura' # for submitting code coverage results to codecov.io
end

group :profiling do
  gem "rack-accept"
  gem "rack-post-body-to-params"
  gem "sinatra"
  gem "thin"
end

gem 'sparql-client', github: 'ncbo/sparql-client', branch: 'master'
