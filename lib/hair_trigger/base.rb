module HairTrigger
  module Base
    attr_reader :triggers

    def trigger(name = nil, options = {})
      if name.is_a?(Hash)
        options = name
        name = nil
      end
      @triggers ||= []
      trigger = ::HairTrigger::Builder.new(name, options)
      @triggers << trigger
      trigger.on(table_name)
    end
  end
end