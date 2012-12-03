class ManualUserTrigger < ActiveRecord::Migration
  def self.up
    create_trigger(:compatibility => 1).
        on("users").
        after(:update).
        where("NEW.name = 'joe'") do
      "UPDATE groups SET updated_joe_count = updated_joe_count + 1"
    end
  end
end
