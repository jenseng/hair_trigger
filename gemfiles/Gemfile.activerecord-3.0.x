 source "http://rubygems.org"
 
gem "activerecord", "~> 3.0.0"
gem 'ruby_parser', '~> 3.0'
gem 'ruby2ruby', '~> 2.0.4'
group :test do
  gem 'rake'
  gem "rspec", "~> 2.12.0"
  gem 'mysql', '~> 2.8.1'
  gem 'mysql2', '>= 0.2.7', '< 0.3'
  gem 'pg', '>= 0.10.1'
  gem 'sqlite3', '>= 1.3.6'
end
