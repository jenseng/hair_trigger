module HairTrigger
  module Migration
    attr_reader :trigger_builders

    def method_missing_with_trigger_building(method, *arguments, &block)
      if extract_trigger_builders
        extract_this_trigger = extract_all_triggers
        trigger = if method.to_sym == :create_trigger
          arguments.unshift({}) if arguments.empty?
          arguments.unshift(nil) if arguments.first.is_a?(Hash)
          extract_this_trigger ||= arguments[1].delete(:generated)
          arguments[1][:compatibility] ||= HairTrigger::Builder.base_compatibility
          ::HairTrigger::Builder.new(*arguments)
        elsif method.to_sym == :drop_trigger
          extract_this_trigger ||= arguments[2].delete(:generated) if arguments[2]
          ::HairTrigger::Builder.new(arguments[0], {:table => arguments[1], :drop => true})
        end
        (@trigger_builders ||= []) << trigger if trigger && extract_this_trigger
        trigger

        # normally we would fall through to the connection for everything
        # else, but we don't want to do that since we are not actually
        # running the migration
      else
        method_missing_without_trigger_building(method, *arguments, &block)
      end
    end

    def self.extended(base)
      base.class_eval do
        class << self
          alias_method_chain :method_missing, :trigger_building
          cattr_accessor :extract_trigger_builders
          cattr_accessor :extract_all_triggers
        end
      end
    end
  end
end