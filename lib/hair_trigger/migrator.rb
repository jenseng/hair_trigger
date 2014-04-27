module HairTrigger
  module Migrator
    def proper_table_name_with_hash_awareness(*args)
      name = args.first
      return name if name.is_a?(Hash)
      proper_table_name_without_hash_awareness(*args)
    end

    class << self
      def extended(base)
        base.class_eval do
          class << self
            alias_method_chain :proper_table_name, :hash_awareness
          end
        end
      end

      def included(base)
        base.instance_eval do
          alias_method_chain :proper_table_name, :hash_awareness
        end
      end
    end
  end
end
