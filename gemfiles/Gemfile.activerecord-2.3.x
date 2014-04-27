source "http://rubygems.org"
 
gem "activerecord", "~> 2.3.0"
gem 'ruby_parser', '>= 3.5'
gem 'ruby2ruby', '~> 2.0.6'
group :test do
  gem 'rake', '<= 10.1.1'
  gem "rspec", "~> 2.14.0"
  gem 'mysql', '~> 2.8.1'
  gem 'mysql2', '>= 0.2.7', '< 0.3'
  gem 'pg', '>= 0.10.1'
  gem 'sqlite3', '>= 1.3.6'
end
