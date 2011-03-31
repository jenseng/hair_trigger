module HairTrigger
  module Migration
    attr_reader :trigger_builders

    def method_missing_with_trigger_building(method, *arguments, &block)
      if extract_trigger_builders
        if method.to_sym == :create_trigger && (extract_all_triggers || arguments[1].delete(:generated))
          arguments.unshift(nil) if arguments.first.is_a?(Hash)
          arguments[1][:compatibility] ||= 0
          trigger = ::HairTrigger::Builder.new(*arguments)
          (@trigger_builders ||= []) << trigger
          trigger
        elsif method.to_sym == :drop_trigger && (extract_all_triggers || arguments[2] && arguments[2].delete(:generated))
          trigger = ::HairTrigger::Builder.new(arguments[0], {:table => arguments[1], :drop => true})
          (@trigger_builders ||= []) << trigger
          trigger
        end
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