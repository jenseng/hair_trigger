module HairTrigger
  module Schema
    attr_reader :info
    def define_with_no_save(info={}, &block)
      instance_eval(&block)
      @info = info
    end

    def self.extended(base)
      base.instance_eval do
        class << self
          alias_method_chain :define, :no_save
        end
      end
    end
  end
end