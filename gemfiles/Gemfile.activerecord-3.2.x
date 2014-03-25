source "http://rubygems.org"
 
gem "activerecord", "~> 3.2.0"
gem 'ruby_parser', '>= 3.5'
gem 'ruby2ruby', '~> 2.0.6'
group :test do
  gem 'rake'
  gem "rspec", "~> 2.12.0"
  gem 'mysql', '~> 2.8.1'
  gem 'mysql2', '>= 0.3.11'
  gem 'pg', '>= 0.15.1'
  gem 'sqlite3', '>= 1.3.7'
end
