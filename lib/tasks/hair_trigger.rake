namespace :db do
  desc "Creates a database migration for any newly created/modified/deleted triggers in the models"
  task :generate_trigger_migration => :environment do
    if file_name = HairTrigger.generate_migration
      puts "Generated #{file_name}"
    else
      puts "Nothing to do"
    end
  end
end
