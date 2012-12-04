 source "http://rubygems.org"
 
gem "activerecord", "~> 2.3.0"
gem 'ruby_parser', '2.0.6'
gem 'ruby2ruby', '1.2.5'
group :test do
  gem 'rake'
  gem "rspec", "~> 2.12.0"
  gem 'mysql', '~> 2.8.1'
  gem 'mysql2', '>= 0.2.7', '< 0.3'
  gem 'pg', '>= 0.10.1'
  gem 'sqlite3', '>= 1.3.6'
end
