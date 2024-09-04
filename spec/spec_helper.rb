require 'rspec'
require 'erb'
require 'active_record'
require 'logger'
require 'hair_trigger'
require 'yaml'
require 'shellwords'

database_yml_contents = ERB.new(File.read(File.expand_path(File.dirname(__FILE__) + '/../database.yml'))).result(binding)

CONFIGS = if Psych::VERSION >= '4.0'
  YAML.safe_load(database_yml_contents, aliases: true)[ENV["DB_CONFIG"] || "test"]
else
  YAML.safe_load(database_yml_contents, [], [], true)[ENV["DB_CONFIG"] || "test"]
end

ADAPTERS = [:mysql2, :postgresql, :sqlite3]

def each_adapter(&block)
  require 'active_record/connection_adapters/postgresql_adapter'
  require 'active_record/connection_adapters/mysql2_adapter'
  require 'active_record/connection_adapters/sqlite3_adapter'
  require 'mysql2'

  ADAPTERS.each do |adapter_name|
    context "under #{adapter_name}" do
      let(:adapter) { adapter_name }
      instance_eval &Proc.new(&block)
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
    FileUtils.cp_r(Dir.glob("spec/migrations/#{options[:migration_glob]}"), HairTrigger.migration_path)
  end

  def initialize_db
    if ActiveRecord::VERSION::STRING > "7.0."
      ActiveRecord::Base.connection_handler.clear_all_connections!
    else
      ActiveRecord::Base.clear_all_connections!
    end
    config = CONFIGS[adapter.to_s].merge({:adapter => adapter.to_s})
    case adapter
      when :mysql2
        command = "mysql"
        command << " -u #{Shellwords.escape(config['username'])}" if config['username']
        command << " -P #{Shellwords.escape(config['port'])}" if config['port']
        command << " -p#{Shellwords.escape(config['password'])}" if config['password']
        command << " -h #{Shellwords.escape(config['host'])}" if config['host']
        ret = `echo "drop database if exists #{Shellwords.escape(config['database'])}; create database #{Shellwords.escape(config['database'])} collate utf8_general_ci;" | #{command} 2>&1`
        raise "error creating database: #{ret}" unless $?.exitstatus == 0
      when :postgresql
        command = "%s"
        command = "PGPASSWORD=#{Shellwords.escape(config['password'])} #{command}" if config['password']
        command << " -U #{Shellwords.escape(config['username'])}" if config['username']
        command << " -p #{Shellwords.escape(config['port'])}" if config['port']
        command << " -h #{Shellwords.escape(config['host'])}" if config['host']
        `#{command % "dropdb"} #{config['database']} &>/dev/null`
        ret = `#{command % "createdb"} #{config['database']} 2>&1`
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
    if ActiveRecord::VERSION::STRING > "7.0."
      ActiveRecord::MigrationContext.new(HairTrigger.migration_path).migrate
    else
      ActiveRecord::MigrationContext.new(HairTrigger.migration_path, ActiveRecord::SchemaMigration).migrate
    end
  end

  def dump_schema
    io = StringIO.new
    connection = if Gem::Version.new("7.2.0") <= ActiveRecord.gem_version
                   ActiveRecord::Base.connection_pool
                 else
                   ActiveRecord::Base.connection
                 end

    ActiveRecord::SchemaDumper.dump(connection, io)

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
