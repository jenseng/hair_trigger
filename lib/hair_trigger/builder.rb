require 'hair_trigger/version'

module HairTrigger
  class Builder
    class DeclarationError < StandardError; end
    class GenerationError < StandardError; end
  
    attr_accessor :options
    attr_reader :triggers # nil unless this is a trigger group
    attr_reader :prepared_actions, :prepared_where # after delayed interpolation

    def initialize(name = nil, options = {})
      @adapter = options[:adapter]
      @compatibility = options.delete(:compatibility) || self.class.compatibility
      @options = {}
      @chained_calls = []
      @errors = []
      set_name(name) if name
      {:timing => :after, :for_each => :row}.update(options).each do |key, value|
        if respond_to?("set_#{key}")
          send("set_#{key}", *Array[value])
        else
          @options[key] = value
        end
      end
    end

    def initialize_copy(other)
      @trigger_group = other
      @triggers = nil
      @chained_calls = []
      @errors = []
      @options = @options.dup
      @options.delete(:name) # this will be inferred (or set further down the line)
      @options.each do |key, value|
        @options[key] = value.dup rescue value
      end
    end

    def drop_triggers
      all_names.map{ |name| self.class.new(name, {:table => options[:table], :drop => true}) }
    end

    def name(name)
      @errors << ["trigger name cannot exceed 63 for postgres", :postgresql] if name.to_s.size > 63
      options[:name] = name.to_s
    end

    def on(table)
      raise DeclarationError, "table has already been specified" if options[:table]
      options[:table] = table.to_s
    end

    def for_each(for_each)
      @errors << ["sqlite and mysql don't support FOR EACH STATEMENT triggers", :sqlite, :mysql] if for_each == :statement
      raise DeclarationError, "invalid for_each" unless [:row, :statement].include?(for_each)
      options[:for_each] = for_each.to_s.upcase
    end

    def before(*events)
      set_timing(:before)
      set_events(*events)
    end

    def after(*events)
      set_timing(:after)
      set_events(*events)
    end

    def where(where)
      options[:where] = where
    end

    # noop, just a way you can pass a block within a trigger group
    def all
    end

    def security(user)
      unless [:invoker, :definer].include?(user) || user.to_s =~ /\A'[^']+'@'[^']+'\z/ || user.to_s.downcase =~ /\Acurrent_user(\(\))?\z/
        raise DeclarationError, "trigger security should be :invoker, :definer, CURRENT_USER, or a valid user (e.g. 'user'@'host')"
      end
      # sqlite default is n/a, mysql default is :definer, postgres default is :invoker
      @errors << ["sqlite doesn't support trigger security", :sqlite]
      @errors << ["postgresql doesn't support arbitrary users for trigger security", :postgresql] unless [:definer, :invoker].include?(user)
      @errors << ["mysql doesn't support invoker trigger security", :mysql] if user == :invoker
      options[:security] = user
    end

    def timing(timing)
      raise DeclarationError, "invalid timing" unless [:before, :after].include?(timing)
      options[:timing] = timing.to_s.upcase
    end

    def events(*events)
      events << :insert if events.delete(:create)
      events << :delete if events.delete(:destroy)
      raise DeclarationError, "invalid events" unless events & [:insert, :update, :delete, :truncate] == events
      @errors << ["sqlite and mysql triggers may not be shared by multiple actions", :mysql, :sqlite] if events.size > 1
      @errors << ["sqlite and mysql do not support truncate triggers", :mysql, :sqlite] if events.include?(:truncate)
      options[:events] = events.map{ |e| e.to_s.upcase }
    end

    def raw_actions
      @raw_actions ||= prepared_actions.is_a?(Hash) ? prepared_actions[adapter_name] || prepared_actions[:default] : prepared_actions
    end

    def prepared_name
      @prepared_name ||= options[:name] ||= infer_name
    end

    def all_names
      [prepared_name] + (@triggers ? @triggers.map(&:prepared_name) : [])
    end

    def self.chainable_methods(*methods)
      methods.each do |method|
        class_eval <<-METHOD
          alias #{method}_orig #{method}
          def #{method}(*args)
            @chained_calls << :#{method}
            if @triggers || @trigger_group
              @errors << ["mysql doesn't support #{method} within a trigger group", :mysql] unless [:name, :where, :all].include?(:#{method})
            end
            set_#{method}(*args, &(block_given? ? Proc.new : nil))
          end
          def set_#{method}(*args)
            if @triggers # i.e. each time we say t.something within a trigger group block
              @chained_calls.pop # the subtrigger will get this, we don't need it
              @chained_calls = @chained_calls.uniq
              @triggers << trigger = clone
              trigger.#{method}(*args, &Proc.new)
            else
              #{method}_orig(*args)
              maybe_execute(&Proc.new) if block_given?
              self
            end
          end
        METHOD
      end
    end
    chainable_methods :name, :on, :for_each, :before, :after, :where, :security, :timing, :events, :all

    def create_grouped_trigger?
      adapter_name == :mysql
    end

    def prepare!
      @triggers.each(&:prepare!) if @triggers
      @prepared_where = options[:where] = interpolate(options[:where]) if options[:where]
      if @actions
        @prepared_actions = @actions.is_a?(Hash) ?
          @actions.inject({}){ |hash, (key, value)| hash[key] = interpolate(value).rstrip; hash } :
          interpolate(@actions).rstrip
      end
    end

    def validate!(direction = :down)
      @errors.each do |(error, *adapters)|
        raise GenerationError, error if adapters.include?(adapter_name)
        $stderr.puts "WARNING: " + error if self.class.show_warnings
      end
      if direction != :up
        @triggers.each{ |t| t.validate!(:down) } if @triggers
      end
      if direction != :down
        @trigger_group.validate!(:up) if @trigger_group
      end
    end

    def generate(validate = true)
      validate!(@trigger_group ? :both : :down) if validate

      return @triggers.map{ |t| t.generate(false) }.flatten if @triggers && !create_grouped_trigger?
      prepare!
      raise GenerationError, "need to specify the table" unless options[:table]
      if options[:drop]
        generate_drop_trigger
      else
        raise GenerationError, "no actions specified" if @triggers && create_grouped_trigger? ? @triggers.any?{ |t| t.raw_actions.nil? } : raw_actions.nil?
        raise GenerationError, "need to specify the event(s) (:insert, :update, :delete)" if !options[:events] || options[:events].empty?
        raise GenerationError, "need to specify the timing (:before/:after)" unless options[:timing]

        [generate_drop_trigger] +
        [case adapter_name
          when :sqlite
            generate_trigger_sqlite
          when :mysql
            generate_trigger_mysql
          when :postgresql, :postgis
            generate_trigger_postgresql
          else
            raise GenerationError, "don't know how to build #{adapter_name} triggers yet"
        end].flatten
      end
    end

    def to_ruby(indent = '', always_generated = true)
      prepare!
      if options[:drop]
        str = "#{indent}drop_trigger(#{prepared_name.inspect}, #{options[:table].inspect}"
        str << ", :generated => true" if always_generated || options[:generated]
        str << ")"
      else
        if @trigger_group
          str = "t." + chained_calls_to_ruby + " do\n"
          str << actions_to_ruby("#{indent}  ") + "\n"
          str << "#{indent}end"
        else
          str = "#{indent}create_trigger(#{prepared_name.inspect}"
          str << ", :generated => true" if always_generated || options[:generated]
          str << ", :compatibility => #{@compatibility}"
          str << ").\n#{indent}    " + chained_calls_to_ruby(".\n#{indent}    ")
          if @triggers
            str << " do |t|\n"
            str << "#{indent}  " + @triggers.map{ |t| t.to_ruby("#{indent}  ") }.join("\n\n#{indent}  ") + "\n"
          else
            str << " do\n"
            str << actions_to_ruby("#{indent}  ") + "\n"
          end
          str << "#{indent}end"
        end
      end
    end

    def <=>(other)
      ret = prepared_name <=> other.prepared_name
      return ret unless ret == 0
      hash <=> other.hash
    end

    def ==(other)
      components == other.components
    end

    def eql?(other)
      other.is_a?(HairTrigger::Builder) && self == other
    end

    def hash
      prepare!
      components.hash
    end

    def components
      [self.options, self.prepared_actions, self.prepared_where, self.triggers, @compatibility]
    end

    def errors
      (@triggers || []).inject(@errors){ |errors, t| errors + t.errors }
    end

    private

    def chained_calls_to_ruby(join_str = '.')
      @chained_calls.map { |c|
        case c
          when :before, :after, :events
            "#{c}(#{options[:events].map{|c|c.downcase.to_sym.inspect}.join(', ')})"
          when :on
            "on(#{options[:table].inspect})"
          when :where
            "where(#{prepared_where.inspect})"
          else
            "#{c}(#{options[c].inspect})"
        end
      }.join(join_str)
    end

    def actions_to_ruby(indent = '')
      if prepared_actions.is_a?(String) && prepared_actions =~ /\n/
        "#{indent}<<-SQL_ACTIONS\n#{prepared_actions}\n#{indent}SQL_ACTIONS"
      else
        indent + prepared_actions.inspect
      end
    end

    def maybe_execute(&block)
      if block.arity > 0 # we're creating a trigger group, so set up some stuff and pass the buck
        @errors << ["trigger group must specify timing and event(s) for mysql", :mysql] unless options[:timing] && options[:events]
        @errors << ["nested trigger groups are not supported for mysql", :mysql] if @trigger_group
        @triggers = []
        block.call(self)
        raise DeclarationError, "trigger group did not define any triggers" if @triggers.empty?
      else
        @actions = block.call
        (@actions.is_a?(Hash) ? @actions.values : [@actions]).each do |actions|
          actions.sub!(/(\s*)\z/, ';\1') if actions && actions !~ /;\s*\z/
        end
      end
      # only the top-most block actually executes
      Array(generate).each{ |action| adapter.execute(action)} if options[:execute] && !@trigger_group
      self
    end

    def adapter_name
      @adapter_name ||= HairTrigger.adapter_name_for(adapter)
    end

    def adapter
      @adapter ||= ActiveRecord::Base.connection
    end

    def infer_name
      [options[:table],
       options[:timing],
       options[:events],
       options[:for_each],
       prepared_where ? 'when_' + prepared_where : nil
      ].flatten.compact.
      join("_").downcase.gsub(/[^a-z0-9_]/, '_').gsub(/_+/, '_')[0, 60] + "_tr"
    end

    def generate_drop_trigger
      case adapter_name
        when :sqlite, :mysql
          "DROP TRIGGER IF EXISTS #{prepared_name};\n"
        when :postgresql, :postgis
          "DROP TRIGGER IF EXISTS #{prepared_name} ON #{options[:table]};\nDROP FUNCTION IF EXISTS #{prepared_name}();\n"
        else
          raise GenerationError, "don't know how to drop #{adapter_name} triggers yet"
      end
    end

    def generate_trigger_sqlite
      <<-SQL
CREATE TRIGGER #{prepared_name} #{options[:timing]} #{options[:events].first} ON #{options[:table]}
FOR EACH #{options[:for_each]}#{prepared_where ? " WHEN " + prepared_where : ''}
BEGIN
#{normalize(raw_actions, 1).rstrip}
END;
      SQL
    end

    def generate_trigger_postgresql
      raise GenerationError, "truncate triggers are only supported on postgres 8.4 and greater" if db_version < 80400 && options[:events].include?('TRUNCATE')
      raise GenerationError, "FOR EACH ROW triggers may not be triggered by truncate events" if options[:for_each] == 'ROW' && options[:events].include?('TRUNCATE')
      security = options[:security] if options[:security] && options[:security] != :invoker
      sql = <<-SQL
CREATE FUNCTION #{prepared_name}()
RETURNS TRIGGER AS $$
BEGIN
      SQL
      if prepared_where && db_version < 90000
        sql << normalize("IF #{prepared_where} THEN", 1)
        sql << normalize(raw_actions, 2)
        sql << normalize("END IF;", 1)
      else
        sql << normalize(raw_actions, 1)
      end
      # if no return is specified at the end, be sure we set a sane one
      unless raw_actions =~ /return [^;]+;\s*\z/i
        if options[:timing] == "AFTER" || options[:for_each] == 'STATEMENT'
          sql << normalize("RETURN NULL;", 1)
        elsif options[:events].include?('DELETE')
          sql << normalize("RETURN OLD;", 1)
        else
          sql << normalize("RETURN NEW;", 1)
        end
      end
      sql << <<-SQL
END;
$$ LANGUAGE plpgsql#{security ? " SECURITY #{security.to_s.upcase}" : ""};
      SQL
      [sql, <<-SQL]
CREATE TRIGGER #{prepared_name} #{options[:timing]} #{options[:events].join(" OR ")} ON #{options[:table]}
FOR EACH #{options[:for_each]}#{prepared_where && db_version >= 90000 ? " WHEN (" + prepared_where + ')': ''} EXECUTE PROCEDURE #{prepared_name}();
      SQL
    end

    def generate_trigger_mysql
      security = options[:security] if options[:security] && options[:security] != :definer
      sql = <<-SQL
CREATE #{security ? "DEFINER = #{security} " : ""}TRIGGER #{prepared_name} #{options[:timing]} #{options[:events].first} ON #{options[:table]}
FOR EACH #{options[:for_each]}
BEGIN
      SQL
      (@triggers ? @triggers : [self]).each do |trigger|
        if trigger.prepared_where
          sql << normalize("IF #{trigger.prepared_where} THEN", 1)
          sql << normalize(trigger.raw_actions, 2)
          sql << normalize("END IF;", 1)
        else
          sql << normalize(trigger.raw_actions, 1)
        end
      end
      sql << "END\n";
    end

    def db_version
      @db_version ||= case adapter_name
        when :postgresql, :postgis
          adapter.send(:postgresql_version)
      end
    end

    def interpolate(str)
      eval("%@#{str.gsub('@', '\@')}@")
    end

    def normalize(text, level = 0)
      indent = level * self.class.tab_spacing
      text.gsub!(/\t/, ' ' * self.class.tab_spacing)
      existing = text.split(/\n/).map{ |line| line.sub(/[^ ].*/, '').size }.min
      if existing > indent
        text.gsub!(/^ {#{existing - indent}}/, '')
      elsif indent > existing
        text.gsub!(/^/, ' ' * (indent - existing))
      end
      text.rstrip + "\n"
    end

    class << self
      attr_writer :tab_spacing, :show_warnings, :base_compatibility

      def tab_spacing
        @tab_spacing ||= 4
      end

      def show_warnings
        @show_warnings = true if @show_warnings.nil?
        @show_warnings
      end

      def base_compatibility
        @base_compatibility ||= 0
      end

      def compatibility
        @compatibility ||= begin
          if HairTrigger::VERSION <= "0.1.3"
            0 # initial releases
          else
            1 # postgres RETURN bugfix
          # TODO: add more as we implement things that change the generated
          # triggers (e.g. chained call merging)
          end
        end
      end
    end
  end
end
