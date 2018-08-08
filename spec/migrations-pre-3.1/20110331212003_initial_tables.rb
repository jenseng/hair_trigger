class InitialTables < ActiveRecord::Migration
  def self.up
    create_table "users" do |t|
      t.integer  "user_group_id"
      t.string   "name"
    end

    create_table "user_groups" do |t|
      t.integer  "bob_count", :default => 0
      t.integer  "updated_joe_count", :default => 0
    end
  end

  def self.down
    drop_table "users"
    drop_table "user_groups"
  end
end
