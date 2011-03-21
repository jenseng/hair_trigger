module HairTrigger
  module Adapter
    def create_trigger(name = nil, options = {})
      if name.is_a?(Hash)
        options = name
        name = nil
      end
      ::HairTrigger::Builder.new(name, options.merge(:execute => true))
    end

    def drop_trigger(name, table, options = {})
      ::HairTrigger::Builder.new(name, options.merge(:execute => true, :drop => true, :table => table)){}
    end
  end
end
