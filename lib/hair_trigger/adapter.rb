module HairTrigger
  module Adapter
    def create_trigger(name = nil, options = {})
      if name.is_a?(Hash)
        options = name
        name = nil
      end
      ::HairTrigger::Builder.new(name, options.merge(:execute => true, :adapter => self))
    end

    def drop_trigger(name, table, options = {})
      ::HairTrigger::Builder.new(name, options.merge(:execute => true, :drop => true, :table => table, :adapter => self)).all{}
    end

    def triggers(options = {})
      triggers = {}
      name_clause = options[:only] ? "IN ('" + options[:only].join("', '") + "')" : nil
      adapter_name = HairTrigger.adapter_name_for(self)
      case adapter_name
        when :sqlite
          select_rows("SELECT name, sql FROM sqlite_master WHERE type = 'trigger' #{name_clause ? " AND name " + name_clause : ""}").each do |(name, definition)|
            triggers[name] = definition + ";\n"
          end
        when :mysql
          select_rows("SHOW TRIGGERS").each do |(name, event, table, actions, timing, created, sql_mode, definer)|
            next if options[:only] && !options[:only].include?(name)
            triggers[name.strip] = <<-SQL
CREATE #{definer != "#{@config[:username] || 'root'}@#{@config[:host] || 'localhost'}" ? "DEFINER = #{definer} " : ""}TRIGGER #{name} #{timing} #{event} ON #{table}
FOR EACH ROW
#{actions}
            SQL
          end
        when :postgresql, :postgis
          function_conditions = "(SELECT typname FROM pg_type WHERE oid = prorettype) = 'trigger'"
          function_conditions << <<-SQL unless options[:simple_check]
            AND oid IN (
              SELECT tgfoid
              FROM pg_trigger
              WHERE NOT tgisinternal AND tgconstrrelid = 0 AND tgrelid IN (
                SELECT oid FROM pg_class WHERE relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
              )
            )
          SQL
          function_conditions = 
          sql = <<-SQL
            SELECT tgname::varchar, pg_get_triggerdef(oid, true)
            FROM pg_trigger
            WHERE NOT tgisinternal AND tgconstrrelid = 0 AND tgrelid IN (
              SELECT oid FROM pg_class WHERE relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
            )
            
            #{name_clause ? " AND tgname::varchar " + name_clause : ""}
            UNION
            SELECT proname || '()', pg_get_functiondef(oid)
            FROM pg_proc
            WHERE #{function_conditions}
              #{name_clause ? " AND (proname || '()')::varchar " + name_clause : ""}
          SQL
          select_rows(sql).each do |(name, definition)|
            triggers[name] = definition
          end
        else
          raise "don't know how to retrieve #{adapter_name} triggers yet"
      end
      triggers
    end
  end
end
