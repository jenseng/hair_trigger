require 'spec_helper'

# for this spec to work, you need to have postgres and mysql installed (in
# addition to the gems), and you should make sure that you have set up
# appropriate users and permissions. see database.yml for more info

describe "adapter" do
  include_context "hairtrigger utils"

  describe ".triggers" do
    before do
      reset_tmp(:migration_glob => "*initial_tables*")
      initialize_db
      migrate_db
    end

    shared_examples_for "mysql" do
      # have to stub SHOW TRIGGERS to get back a '%' host, since GRANTs
      # and such get a little dicey for testing (local vs travis, etc.)
      it "matches the generated trigger with a '%' grant" do
        conn.instance_variable_get(:@config)[:host] = "somehost" # wheeeee!
        implicit_definer = "'root'@'somehost'"
        show_triggers_definer = "root@%"

        builder = trigger.on(:users).before(:insert){ "UPDATE foos SET bar = 1" }
        triggers = builder.generate.select{|t|t !~ /\ADROP/}
        expect(conn).to receive(:implicit_mysql_definer).and_return(implicit_definer)
        expect(conn).to receive(:select_rows).with("SHOW TRIGGERS").and_return([
          ['users_before_insert_row_tr', 'INSERT', 'users', "BEGIN\n    UPDATE foos SET bar = 1;\nEND", 'BEFORE', 'NULL', 'STRICT_ALL_TABLES', show_triggers_definer]
        ])

        expect(db_triggers).to eq(triggers)
      end
    end

    context "mysql" do
      let(:adapter) { :mysql }
      it_behaves_like "mysql"
    end

    context "mysql2" do
      let(:adapter) { :mysql2 }
      it_behaves_like "mysql"
    end
  end
end

