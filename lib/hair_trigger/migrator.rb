module HairTrigger
  module Migrator
    def proper_table_name_with_hash_awareness(name)
      name.is_a?(Hash) ? name : proper_table_name_without_hash_awareness(name)
    end
    def self.extended(base)
      base.class_eval do
        class << self
          alias_method_chain :proper_table_name, :hash_awareness
        end
      end
    end
  end
end
