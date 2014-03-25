require 'spec_helper'

# for this spec to work, you need to have postgres and mysql installed (in
# addition to the gems), and you should make sure that you have set up
# appropriate users and permissions. see database.yml for more info

describe "migrations" do
  include_context "hairtrigger utils"

  describe "migrations_current?" do
    let(:adapter) { :sqlite3 }

    it "should return false if there are pending model triggers" do
      reset_tmp(:migration_glob => "*initial_tables*")
      initialize_db
      HairTrigger.should_not be_migrations_current
    end

    it "should return true if migrations are current" do
      # just one trigger migration
      reset_tmp(:migration_glob => "20110331212*")
      initialize_db
      migrate_db
      HairTrigger.should be_migrations_current

      # or multiple
      reset_tmp
      initialize_db
      migrate_db
      HairTrigger.should be_migrations_current
    end

    it "should return true even if migrations haven't run" do
      reset_tmp
      initialize_db
      migrate_db
      HairTrigger.should be_migrations_current
    end
  end
end
