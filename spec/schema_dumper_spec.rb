require 'active_record'
require 'logger'
require 'active_record/connection_adapters/postgresql_adapter'
require 'active_record/connection_adapters/mysql_adapter'
require 'active_record/connection_adapters/sqlite3_adapter'
require 'mysql2'
require 'rspec'
require 'hair_trigger'
require 'yaml'

# for this spec to work, you need to have postgres and mysql installed (in
# addition to the gems), and you should make sure that you have set up
# appropriate users and permissions. see database.yml for more info

describe "schema" do
  def reset_tmp
    HairTrigger.model_path = 'tmp/models'
    HairTrigger.migration_path = 'tmp/migrations'
    FileUtils.rm_rf('tmp') if File.directory?('tmp')
    FileUtils.mkdir_p(HairTrigger.model_path)
    FileUtils.mkdir_p(HairTrigger.migration_path)
    FileUtils.cp_r('spec/models', 'tmp')
    FileUtils.cp_r(Dir.glob("spec/migrations#{ActiveRecord::VERSION::STRING < "3.1." ? "-pre-3.1" : ""}/*"), HairTrigger.migration_path)
  end
  
  def initialize_db(adapter)
    reset_tmp
    config = @configs[adapter.to_s].merge({:adapter => adapter.to_s})
    case adapter
      when :mysql, :mysql2
        ret = `echo "drop database if exists #{config['database']}; create database #{config['database']};" | mysql -u #{config['username']}`
        raise "error creating database: #{ret}" unless $?.exitstatus == 0
      when :postgresql
        `dropdb -U #{config['username']} #{config['database']} &>/dev/null`
        ret = `createdb -U #{config['username']} #{config['database']} 2>&1`
        raise "error creating database: #{ret}" unless $?.exitstatus == 0
    end
    # Arel has an issue in that it keeps using original connection for quoting,
    # etc. (which breaks stuff) unless you do this:
    Arel::Visitors::ENGINE_VISITORS.delete(ActiveRecord::Base) if defined?(Arel)
    ActiveRecord::Base.establish_connection(config)
    ActiveRecord::Base.logger = Logger.new('/dev/null')
    ActiveRecord::Migrator.migrate(HairTrigger.migration_path)
  end

  before :all do
    @configs = YAML.load_file(File.expand_path(File.dirname(__FILE__) + '/../database.yml'))
    @configs = @configs[ENV["DB_CONFIG"] || "test"]
  end

  [:mysql, :mysql2, :postgresql, :sqlite3].each do |adapter|
    it "should correctly dump #{adapter}" do
      ActiveRecord::Migration.verbose = false
      initialize_db(adapter)
      ActiveRecord::Base.connection.triggers.values.grep(/bob_count \+ 1/).size.should eql(1)

      # schema dump w/o previous schema.rb
      ActiveRecord::SchemaDumper.previous_schema = nil
      io = StringIO.new
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, io)
      io.rewind
      schema_rb = io.read
      schema_rb.should match(/create_trigger\("users_after_insert_row_when_new_name_bob__tr", :generated => true, :compatibility => 1\)/)
      schema_rb.should match(/create_trigger\("users_after_update_row_when_new_name_joe__tr", :compatibility => 1\)/)

      # schema dump w/ schema.rb
      ActiveRecord::SchemaDumper.previous_schema = schema_rb
      io = StringIO.new
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, io)
      io.rewind
      schema_rb2 = io.read
      schema_rb2.should eql(schema_rb)

      # edit our model trigger, generate and apply a new migration
      user_model = File.read(HairTrigger.model_path + '/user.rb')
      File.open(HairTrigger.model_path + '/user.rb', 'w') { |f|
        f.write user_model.sub('"UPDATE groups SET bob_count = bob_count + 1"', '{:default => "UPDATE groups SET bob_count = bob_count + 2"}')
      }
      migration = HairTrigger.generate_migration
      ActiveRecord::Migrator.migrate(HairTrigger.migration_path)
      HairTrigger.should be_migrations_current
      ActiveRecord::Base.connection.triggers.values.grep(/bob_count \+ 1/).size.should eql(0)
      ActiveRecord::Base.connection.triggers.values.grep(/bob_count \+ 2/).size.should eql(1)
      
      # schema dump, should have the updated trigger
      ActiveRecord::SchemaDumper.previous_schema = schema_rb2
      io = StringIO.new
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, io)
      io.rewind
      schema_rb3 = io.read
      schema_rb3.should_not eql(schema_rb2)
      schema_rb3.should match(/create_trigger\("users_after_insert_row_when_new_name_bob__tr", :generated => true, :compatibility => 1\)/)
      schema_rb3.should match(/UPDATE groups SET bob_count = bob_count \+ 2/)

      # undo migration, schema dump should be back to previous version
      ActiveRecord::Migrator.rollback(HairTrigger.migration_path)
      ActiveRecord::SchemaDumper.previous_schema = schema_rb3
      io = StringIO.new
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, io)
      io.rewind
      schema_rb4 = io.read
      schema_rb4.should_not eql(schema_rb3)
      schema_rb4.should eql(schema_rb2)
      ActiveRecord::Base.connection.triggers.values.grep(/bob_count \+ 1/).size.should eql(1)

      # delete our migrations, it should still dump correctly
      FileUtils.rm_rf(Dir.glob('tmp/migrations/*rb'))
      ActiveRecord::SchemaDumper.previous_schema = schema_rb4
      io = StringIO.new
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, io)
      io.rewind
      schema_rb5 = io.read
      schema_rb5.should eql(schema_rb4)

      # "delete" schema.rb too, now it should have adapter-specific triggers
      ActiveRecord::SchemaDumper.previous_schema = nil
      io = StringIO.new
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, io)
      io.rewind
      schema_rb6 = io.read
      schema_rb6.should_not match(/create_trigger\(/)
      schema_rb6.should match(/no candidate create_trigger statement could be found, creating an adapter-specific one/)
    end
  end
end