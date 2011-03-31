module HairTrigger
  module SchemaDumper
    def trailer_with_triggers(stream)
      triggers(stream)
      trailer_without_triggers(stream)
    end

    def triggers(stream)
      @connection = ActiveRecord::Base.connection
      @adapter_name = @connection.adapter_name.downcase.to_sym

      db_triggers = @connection.triggers; nil
      db_trigger_warnings = {}

      migration_triggers = HairTrigger.current_migrations(:in_rake_task => true, :previous_schema => self.class.previous_schema).map do |(name, builder)|
        definitions = []
        builder.generate.each do |statement|
          if statement =~ /\ACREATE(.*TRIGGER| FUNCTION) ([^ \n]+)/
            definitions << [$2, statement, $1 == ' FUNCTION' ? :function : :trigger]
          end
        end
        {:builder => builder, :definitions => definitions}
      end

      migration_triggers.each do |migration|
        next unless migration[:definitions].all? do |(name, definition, type)|
          db_triggers[name] && (db_trigger_warnings[name] = true) && db_triggers[name] == normalize_trigger(name, definition, type)
        end
        migration[:definitions].each do |(name, trigger, type)|
          db_triggers.delete(name)
          db_trigger_warnings.delete(name)
        end

        stream.print migration[:builder].to_ruby('  ', false) + "\n\n"
      end

      db_triggers.to_a.sort_by{ |t| (t.first + 'a').sub(/\(/, '_') }.each do |(name, definition)|
        if db_trigger_warnings[name]
          stream.puts "  # WARNING: generating adapter-specific definition for #{name} due to a mismatch."
          stream.puts "  # either there's a bug in hairtrigger or you've messed up your migrations and/or db :-/"
        else
          stream.puts "  # no candidate create_trigger statement could be found, creating an adapter-specific one"
        end
        if definition =~ /\n/
          stream.print "  execute(<<-TRIGGERSQL)\n#{definition.rstrip}\n  TRIGGERSQL\n\n"
        else
          stream.print "  execute(#{definition.inspect})\n\n"
        end
      end
    end

    def normalize_trigger(name, definition, type)
      @connection = ActiveRecord::Base.connection
      @adapter_name = @connection.adapter_name.downcase.to_sym

      return definition unless @adapter_name == :postgresql
      begin
        # because postgres does not preserve the original CREATE TRIGGER/
        # FUNCTION statements, its decompiled reconstruction will not match
        # ours. we work around it by creating our generated trigger/function,
        # asking postgres for its definition, and then rolling back.
        begin
          @connection.transaction do
            chars = ('a'..'z').to_a + ('0'..'9').to_a + ['_']
            test_name = '_hair_trigger_test_' + (0..43).map{ chars[(rand * chars.size).to_i] }.join
            test_name << (type == :function ? '()' : '')
            @connection.execute(definition.sub(name, test_name))
            definition = @connection.triggers(:only => [test_name], :simple_check => true).values.first
            definition.sub!(test_name, name)
            raise
          end
        rescue
        end
      end
      definition
    end

    def self.included(base)
      base.class_eval do
        alias_method_chain :trailer, :triggers
        class << self
          attr_accessor :previous_schema
        end
      end
    end
  end
end