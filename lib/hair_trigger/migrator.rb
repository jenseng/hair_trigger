module HairTrigger
  module Migrator
    def proper_table_name_with_hash_awareness(*args)
      name = args.first
      return name if name.is_a?(Hash)
      proper_table_name_without_hash_awareness(*args)
    end

    class << self
      def extended(base)
        base.send :alias_method, :proper_table_name_without_hash_awareness, :proper_table_name
        base.send :alias_method, :proper_table_name, :proper_table_name_with_hash_awareness
      end
      alias_method :included, :extended
    end
  end
end
