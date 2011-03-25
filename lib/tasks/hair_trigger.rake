namespace :db do
  desc "Creates a database migration for any newly created/modified/deleted triggers in the models"
  task :generate_trigger_migration => :environment do

    begin
      canonical_triggers = HairTrigger::current_triggers
    rescue 
      $stderr.puts $!
      exit 1
    end

    migrations = HairTrigger::current_migrations
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
      file_name = 'db/migrate/' + Time.now.getutc.strftime("%Y%m%d%H%M%S") + "_" + migration_name.underscore + ".rb"
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
      puts "Generated #{file_name}"
    else
      puts "Nothing to do"
    end
  end
end
