CONFIGS = YAML.load_file(File.expand_path(File.dirname(__FILE__) + '/../database.yml'))[ENV["DB_CONFIG"] || "test"]
ADAPTERS = [:mysql, :mysql2, :postgresql, :sqlite3]

def each_adapter
  ADAPTERS.each do |adapter_name|
    context "under #{adapter_name}" do
      let(:adapter) { adapter_name }
      instance_eval &Proc.new
    end
  end
end

shared_context "hairtrigger utils" do
  def reset_tmp(options = {})
    options[:migration_glob] ||= '*'
    HairTrigger.model_path = 'tmp/models'
    HairTrigger.migration_path = 'tmp/migrations'
    FileUtils.rm_rf('tmp') if File.directory?('tmp')
    FileUtils.mkdir_p(HairTrigger.model_path)
    FileUtils.mkdir_p(HairTrigger.migration_path)
    FileUtils.cp_r('spec/models', 'tmp')
    FileUtils.cp_r(Dir.glob("spec/migrations#{ActiveRecord::VERSION::STRING < "3.1." ? "-pre-3.1" : ""}/#{options[:migration_glob]}"), HairTrigger.migration_path)
  end

  def initialize_db
    ActiveRecord::Base.clear_all_connections!
    config = CONFIGS[adapter.to_s].merge({:adapter => adapter.to_s})
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
    migrate_db
    ActiveRecord::SchemaDumper.previous_schema = nil
  end

  def migrate_db
    ActiveRecord::Migration.verbose = false
    ActiveRecord::Migrator.migrate(HairTrigger.migration_path)
  end

  def dump_schema
    io = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, io)
    io.rewind
    io.read
  end

  def db_triggers
    ActiveRecord::Base.connection.triggers.values
  end

  def replace_file_contents(path, source, replacement)
    contents = File.read(path)
    File.open(path, 'w') { |f| f.write contents.sub(source, replacement) }
  end
end
