namespace :db do
  desc "Creates a database migration for any newly created/modified/deleted triggers in the models"
  task :generate_trigger_migration => :environment do
    if file_name = HairTrigger.generate_migration
      puts "Generated #{file_name}"
    else
      puts "Nothing to do"
    end
  end

  namespace :schema do
    desc "Create a db/schema.rb file that can be portably used against any DB supported by AR"
    task :dump => :environment do
      require 'active_record/schema_dumper'

      databases = ActiveRecord::Tasks::DatabaseTasks.setup_initial_database_yaml

      ActiveRecord::Tasks::DatabaseTasks.for_each(databases) do |name|
        filename = name == 'primary' ? "#{Rails.root}/db/schema.rb" : "#{Rails.root}/db/#{name}_schema.rb"

        ActiveRecord::SchemaDumper.previous_schema = File.exist?(filename) ? File.read(filename) : nil

        db_config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: name)
        connection_pool = ActiveRecord::Base.establish_connection(db_config)

        File.open(filename, "w") do |file|
          ActiveRecord::SchemaDumper.dump(connection_pool.connection, file)
        end
      end

      Rake::Task["db:schema:dump"].reenable
    end
  end
end
