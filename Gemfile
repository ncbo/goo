source 'https://rubygems.org'

gemspec

gem 'rake'
gem "uuid", "~> 2.3.5"
gem 'pry'

# NCBO gems (can be from a local dev path or from rubygems/git)
gemfile_local = File.expand_path("../Gemfile.local", __FILE__)
if File.exists?(gemfile_local)
  self.instance_eval(Bundler.read_file(gemfile_local))
else
  gem 'sparql_http', :git => 'https://github.com/ncbo/sparql_http.git'
end
