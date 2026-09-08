source 'https://rubygems.org'

group :development do
  gem 'juwelier', '~> 2.0'
  gem 'rspec_junit_formatter'
  gem 'pry-byebug'
end

group :test, :development do
  gem 'rake', '>= 10.0'
  gem 'rspec', '~> 3.1'

  unless ENV['NO_ACTIVERECORD']
    gem 'activerecord', '>= 7.0', '< 8.1'
    gem 'activerecord-oracle_enhanced-adapter', '>= 7.0', '< 8.1'
    gem 'simplecov', '>= 0'
  end

  platforms :ruby, :mswin, :mingw do
    gem 'ruby-oci8', '~> 2.2'
  end
end
