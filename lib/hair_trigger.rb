module HairTrigger
  def self.current_triggers
    # see what the models say there should be
    canonical_triggers = []
    Dir['app/models/*rb'].each do |model|
      class_name = model.sub(/\A.*\/(.*?)\.rb\z/, '\1').camelize
      begin
        klass = Kernel.const_get(class_name)
      rescue
        raise "unable to load #{class_name} and its trigger(s)"  if File.read(model) =~ /^\s*trigger[\.\(]/
        next
      end
      canonical_triggers += klass.triggers if klass < ActiveRecord::Base && klass.triggers
    end
    canonical_triggers.each(&:prepare!) # interpolates any vars so we match the migrations
  end

  def self.current_migrations
    ActiveRecord::Migration.verbose = false
    ActiveRecord::Migration.extract_trigger_builders = true
    
    # see what generated triggers are defined by the migrations
    migrations = []
    migrator = ActiveRecord::Migrator.new(:up, 'db/migrate')
    migrator.migrations.select{ |migration|
      File.read(migration.filename) =~ /(create|drop)_trigger.*:generated *=> *true/
    }.each do |migration|
      migration.migrate(:up)
      migration.trigger_builders.each do |new_trigger|
        # if there is already a trigger with this name, delete it since we are
        # either dropping it or replacing it
        migrations.delete_if{ |(n, t)| t.prepared_name == new_trigger.prepared_name }
        migrations << [migration.name, new_trigger] unless new_trigger.options[:drop]
      end
    end
    migrations.each{ |(n, t)| t.prepare! }
  ensure
    ActiveRecord::Migration.verbose = true
    ActiveRecord::Migration.extract_trigger_builders = false
  end

  def self.migrations_current?
    current_migrations.map(&:last).sort == current_triggers.sort
  end
end

ActiveRecord::Base.send :extend, HairTrigger::Base
ActiveRecord::Migration.send :extend, HairTrigger::Migration
ActiveRecord::MigrationProxy.send :delegate, :trigger_builders, :to=>:migration
ActiveRecord::ConnectionAdapters::AbstractAdapter.class_eval { include HairTrigger::Adapter }
