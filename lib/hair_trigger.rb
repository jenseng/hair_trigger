require 'ostruct'
require 'hair_trigger/base'
require 'hair_trigger/builder'
require 'hair_trigger/migration'
require 'hair_trigger/adapter'
require 'hair_trigger/schema_dumper'
require 'hair_trigger/schema'

module HairTrigger
  def self.current_triggers
    # see what the models say there should be
    canonical_triggers = []
    Dir[model_path + '/*rb'].each do |model|
      class_name = model.sub(/\A.*\/(.*?)\.rb\z/, '\1').camelize
      begin
        require model unless klass = Kernel.const_get(class_name) rescue nil
        klass = Kernel.const_get(class_name)
      rescue StandardError, LoadError
        raise "unable to load #{class_name} and its trigger(s)" if File.read(model) =~ /^\s*trigger[\.\(]/
        next
      end
      canonical_triggers += klass.triggers if klass < ActiveRecord::Base && klass.triggers
    end
    canonical_triggers.each(&:prepare!) # interpolates any vars so we match the migrations
  end

  def self.current_migrations(options = {})
    if options[:in_rake_task]
      options[:include_manual_triggers] = true
      options[:schema_rb_first] = true
      options[:skip_pending_migrations] = true
    end

    prev_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    ActiveRecord::Migration.extract_trigger_builders = true
    ActiveRecord::Migration.extract_all_triggers = options[:include_manual_triggers] || false
    
    # if we're in a db:schema:dump task (explict or kicked off by db:migrate),
    # we evaluate the previous schema.rb (if it exists), and then all applied
    # migrations in order (even ones older than schema.rb). this ensures we
    # handle db:migrate:down scenarios correctly
    #
    # if we're not in such a rake task (i.e. we just want to know what
    # triggers are defined, whether or not they are applied in the db), we
    # evaluate all migrations along with schema.rb, ordered by version
    migrator = ActiveRecord::Migrator.new(:up, migration_path)
    migrated = migrator.migrated rescue []
    migrations = migrator.migrations.select{ |migration|
      (options[:skip_pending_migrations] ? migrated.include?(migration.version) : true)
    }.each{ |migration|
      migration.migrate(:up)
    }

    if options.has_key?(:previous_schema)
      eval(options[:previous_schema]) if options[:previous_schema]
    elsif File.exist?(schema_rb_path)
      load(schema_rb_path)
    end
    if ActiveRecord::Schema.info && ActiveRecord::Schema.trigger_builders
      migrations.unshift OpenStruct.new({:version => ActiveRecord::Schema.info[:version], :trigger_builders => ActiveRecord::Schema.trigger_builders})
    end
    migrations = migrations.sort_by(&:version) unless options[:schema_rb_first]

    all_builders = []
    migrations.each do |migration|
      next unless migration.trigger_builders
      migration.trigger_builders.each do |new_trigger|
        # if there is already a trigger with this name, delete it since we are
        # either dropping it or replacing it
        new_trigger.prepare!
        all_builders.delete_if{ |(n, t)| t.prepared_name == new_trigger.prepared_name }
        all_builders << [migration.name, new_trigger] unless new_trigger.options[:drop]
      end
    end

    all_builders

  ensure
    ActiveRecord::Migration.verbose = prev_verbose
    ActiveRecord::Migration.extract_trigger_builders = false
    ActiveRecord::Migration.extract_all_triggers = false
  end

  def self.migrations_current?
    current_migrations.map(&:last).sort.eql? current_triggers.sort
  end

  def self.generate_migration(silent = false)
    begin
      canonical_triggers = current_triggers
    rescue 
      $stderr.puts $!
      exit 1
    end

    migrations = current_migrations
    migration_names = migrations.map(&:first)
    existing_triggers = migrations.map(&:last)

    up_drop_triggers = []
    up_create_triggers = []
    down_drop_triggers = []
    down_create_triggers = []

    existing_triggers.each do |existing|
      unless canonical_triggers.any?{ |t| t.prepared_name == existing.prepared_name }
        up_drop_triggers += existing.drop_triggers
        down_create_triggers << existing
      end
    end

    (canonical_triggers - existing_triggers).each do |new_trigger|
      up_create_triggers << new_trigger
      down_drop_triggers += new_trigger.drop_triggers
      if existing = existing_triggers.detect{ |t| t.prepared_name == new_trigger.prepared_name }
        # it's not sufficient to rely on the new trigger to replace the old
        # one, since we could be dealing with trigger groups and the name
        # alone isn't sufficient to know which component triggers to remove
        up_drop_triggers += existing.drop_triggers
        down_create_triggers << existing
      end
    end

    unless up_drop_triggers.empty? && up_create_triggers.empty?
      migration_base_name = if up_create_triggers.size > 0
        ("create trigger#{up_create_triggers.size > 1 ? 's' : ''} " +
         up_create_triggers.map{ |t| [t.options[:table], t.options[:events].join(" ")].join(" ") }.join(" and ")
        ).downcase.gsub(/[^a-z0-9_]/, '_').gsub(/_+/, '_').camelize
      else
        ("drop trigger#{up_drop_triggers.size > 1 ? 's' : ''} " +
         up_drop_triggers.map{ |t| t.options[:table] }.join(" and ")
        ).downcase.gsub(/[^a-z0-9_]/, '_').gsub(/_+/, '_').camelize
      end

      name_version = nil
      while migration_names.include?("#{migration_base_name}#{name_version}")
        name_version = name_version.to_i + 1
      end
      migration_name = "#{migration_base_name}#{name_version}"
      migration_version = ActiveRecord::Base.timestamped_migrations ?
        Time.now.getutc.strftime("%Y%m%d%H%M%S") :
        Dir.glob(migration_path + '/*rb').map{ |f| f.gsub(/.*\/(\d+)_.*/, '\1').to_i}.inject(0){ |curr, i| i > curr ? i : curr }
      file_name = migration_path + '/' + migration_version + "_" + migration_name.underscore + ".rb"
      File.open(file_name, "w"){ |f| f.write <<-MIGRATION }
# This migration was auto-generated via `rake db:generate_trigger_migration'.
# While you can edit this file, any changes you make to the definitions here
# will be undone by the next auto-generated trigger migration.

class #{migration_name} < ActiveRecord::Migration
  def self.up
    #{(up_drop_triggers + up_create_triggers).map{ |t| t.to_ruby('    ') }.join("\n\n").lstrip}
  end

  def self.down
    #{(down_drop_triggers + down_create_triggers).map{ |t| t.to_ruby('    ') }.join("\n\n").lstrip}
  end
end
      MIGRATION
      file_name
    end
  end

  class << self
    attr_writer :model_path, :schema_rb_path, :migration_path

    def model_path
      @model_path ||= 'app/models'
    end

    def schema_rb_path
      @schema_rb_path ||= 'db/schema.rb'
    end

    def migration_path
      @migration_path ||= 'db/migrate'
    end
  end
end

ActiveRecord::Base.send :extend, HairTrigger::Base
ActiveRecord::Migration.send :extend, HairTrigger::Migration
ActiveRecord::MigrationProxy.send :delegate, :trigger_builders, :to=>:migration
ActiveRecord::ConnectionAdapters::AbstractAdapter.class_eval { include HairTrigger::Adapter }
ActiveRecord::SchemaDumper.class_eval { include HairTrigger::SchemaDumper }
ActiveRecord::Schema.send :extend, HairTrigger::Schema
