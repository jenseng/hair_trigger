require 'rspec'
require 'active_record'
require 'logger'
require 'hair_trigger'
require 'yaml'

CONFIGS = YAML.load_file(File.expand_path(File.dirname(__FILE__) + '/../database.yml'))[ENV["DB_CONFIG"] || "test"]
ADAPTERS = [:mysql2, :postgresql, :sqlite3]
ADAPTERS.unshift :mysql if ActiveRecord::VERSION::STRING < "5"

def each_adapter
  require 'active_record/connection_adapters/postgresql_adapter'
  require 'active_record/connection_adapters/mysql_adapter' if ADAPTERS.include? :mysql
  require 'active_record/connection_adapters/mysql2_adapter'
  require 'active_record/connection_adapters/sqlite3_adapter'
  require 'mysql2'

  ADAPTERS.each do |adapter_name|
    context "under #{adapter_name}" do
      let(:adapter) { adapter_name }
      instance_eval &Proc.new
    end
  end
end

shared_context "hairtrigger utils" do

  def reset_models
    User.send :remove_instance_variable, :@triggers if Object.const_defined?('User')
    load './tmp/models/user.rb' # since some tests modify it
  end

  def reset_tmp(options = {})
    options[:migration_glob] ||= '*'
    HairTrigger.model_path = 'tmp/models'
    HairTrigger.migration_path = 'tmp/migrations'
    FileUtils.rm_rf('tmp') if File.directory?('tmp')
    FileUtils.mkdir_p(HairTrigger.model_path)
    FileUtils.mkdir_p(HairTrigger.migration_path)
    FileUtils.cp_r('spec/models', 'tmp')
    reset_models
    FileUtils.cp_r(Dir.glob("spec/migrations#{migrations_sufix}/#{options[:migration_glob]}"), HairTrigger.migration_path)
  end

  def migrations_sufix
    if ActiveRecord::VERSION::STRING < '3.1.'
      '-pre-3.1'
    elsif ActiveRecord::VERSION::STRING < '5.0'
      '-3.2'
    else
      ''
    end
  end

  def initialize_db
    ActiveRecord::Base.clear_all_connections!
    config = CONFIGS[adapter.to_s].merge({:adapter => adapter.to_s})
    case adapter
      when :mysql, :mysql2
        ret = `echo "drop database if exists #{config['database']}; create database #{config['database']};" | mysql -u #{config['username']}`
        raise "error creating database: #{ret}" unless $?.exitstatus == 0
      when :postgresql
        user_arg = "-U #{config['username']}" if config['username']
        `dropdb #{user_arg} #{config['database']} &>/dev/null`
        ret = `createdb #{user_arg} #{config['database']} 2>&1`
        raise "error creating database: #{ret}" unless $?.exitstatus == 0
    end
    # Arel has an issue in that it keeps using original connection for quoting,
    # etc. (which breaks stuff) unless you do this:
    Arel::Visitors::ENGINE_VISITORS.delete(ActiveRecord::Base) if defined?(Arel::Visitors::ENGINE_VISITORS)
    ActiveRecord::Base.establish_connection(config)
    ActiveRecord::Base.logger = Logger.new('/dev/null')
    ActiveRecord::SchemaDumper.previous_schema = nil
  end

  def migrate_db
    ActiveRecord::Migration.verbose = false
    if ActiveRecord::VERSION::STRING >= "6.0"
      ActiveRecord::MigrationContext.new(HairTrigger.migration_path, ActiveRecord::SchemaMigration).migrate
    elsif ActiveRecord::VERSION::STRING >= "5.2"
      ActiveRecord::MigrationContext.new(HairTrigger.migration_path).migrate
    else
      ActiveRecord::Migrator.migrate(HairTrigger.migration_path)
    end
  end

  def dump_schema
    io = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, io)
    io.rewind
    io.read
  end

  def trigger(*args)
    HairTrigger::Builder.new(*args)
  end

  def conn
    ActiveRecord::Base.connection
  end

  def db_triggers
    conn.triggers.values
  end

  def replace_file_contents(path, source, replacement)
    contents = File.read(path)
    File.open(path, 'w') { |f| f.write contents.sub(source, replacement) }
  end
end
