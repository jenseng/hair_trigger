# Rails 2 Installation

To get HairTrigger working in Rails 2, you need to:

## Add it to your project

Put hairtrigger in your Gemfile, or if you're not using bundler, you can
`gem install hairtrigger` and then put hairtrigger in environment.rb

## Set up a rake task

Create lib/tasks/hair_trigger.rake with the following:

```ruby
$VERBOSE = nil
Dir["#{Gem::Specification.find_by_name('hairtrigger').full_gem_path}/lib/tasks/*.rake"].each { |ext| load ext }
```

This will give you the `db:generate_trigger_migration` task, and will ensure
that hairtrigger hooks into `db:schema:dump`.

If you are unpacking the gem in vendor/plugins, this step is not needed
(though you'll then want to delete its Gemfile to avoid possible conflicts).


