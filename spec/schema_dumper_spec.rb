require 'spec_helper'

# for this spec to work, you need to have postgres and mysql installed (in
# addition to the gems), and you should make sure that you have set up
# appropriate users and permissions. see database.yml for more info

describe "schema dumping" do
  include_context "hairtrigger utils"

  each_adapter do
    before do
      reset_tmp
      initialize_db
      migrate_db
      expect(db_triggers.grep(/bob_count \+ 1/).size).to eql(1)
    end

    shared_examples_for 'filterable' do
      it 'should take in consideration active record schema dumper ignore_tables option with regexp' do
        ActiveRecord::SchemaDumper.ignore_tables = [/users/]

        expect(dump_schema).not_to match(/create_trigger/)
      end

      it 'should take in consideration active record schema dumper ignore_tables option with string' do
        ActiveRecord::SchemaDumper.ignore_tables = ['users']

        expect(dump_schema).not_to match(/create_trigger/)
      end

      it 'should take in consideration active record schema dumper ignore_tables option with partial string' do
        ActiveRecord::SchemaDumper.ignore_tables = ['user']

        expect(dump_schema).to match(/create_trigger/)
      end

      it 'should ignore configured ignore_tables option with regexp' do
        allow(HairTrigger::SchemaDumper::Configuration).to receive(:ignore_tables).and_return([/users/])

        expect(dump_schema).not_to match(/create_trigger/)
      end

      it 'should ignore configured ignore_tables option with string' do
        allow(HairTrigger::SchemaDumper::Configuration).to receive(:ignore_tables).and_return(['users'])

        expect(dump_schema).not_to match(/create_trigger/)
      end

      it 'should not ignore configured ignore_tables option with partial string' do
        allow(HairTrigger::SchemaDumper::Configuration).to receive(:ignore_tables).and_return(['user'])

        expect(dump_schema).to match(/create_trigger/)
      end

      it 'should ignore configured ignore_triggers option with regexp' do
        allow(HairTrigger::SchemaDumper::Configuration).to receive(:ignore_triggers).and_return([/bob/])

        expect(dump_schema).not_to match(/trigger.+bob/i)
      end

      it 'should ignore configured ignore_triggers option with string' do
        allow(HairTrigger::SchemaDumper::Configuration).to receive(:ignore_triggers).and_return(['users_after_insert_row_when_new_name_bob__tr'])

        expect(dump_schema).not_to match(/trigger.+bob/i)
      end

      it 'should not ignore configured ignore_triggers option with partial string' do
        allow(HairTrigger::SchemaDumper::Configuration).to receive(:ignore_triggers).and_return(['users_after_insert_row_when_new_name_bob'])

        expect(dump_schema).to match(/trigger.+bob/i)
      end

      it 'should allow configured allow_tables option with regexp' do
        allow(HairTrigger::SchemaDumper::Configuration).to receive(:allow_tables).and_return([/users/])

        expect(dump_schema).to match(/create_trigger/)
      end

      it 'should allow configured allow_tables option with string' do
        allow(HairTrigger::SchemaDumper::Configuration).to receive(:allow_tables).and_return(['users'])

        expect(dump_schema).to match(/create_trigger/)
      end

      it 'should not allow configured allow_tables option with partial string' do
        allow(HairTrigger::SchemaDumper::Configuration).to receive(:allow_tables).and_return(['user'])

        expect(dump_schema).not_to match(/create_trigger/)
      end

      it 'should allow configured allow_triggers option with regexp' do
        allow(HairTrigger::SchemaDumper::Configuration).to receive(:allow_triggers).and_return([/bob/])

        expect(dump_schema).to match(/trigger.+bob/i)
      end

      it 'should allow configured allow_triggers option with string' do
        allow(HairTrigger::SchemaDumper::Configuration).to receive(:allow_triggers).and_return(['users_after_insert_row_when_new_name_bob__tr'])

        expect(dump_schema).to match(/trigger.+bob/i)
      end

      it 'should not allow configured allow_triggers option with partial string' do
        allow(HairTrigger::SchemaDumper::Configuration).to receive(:allow_triggers).and_return(['users_after_insert_row_when_new_name_bob'])

        expect(dump_schema).not_to match(/trigger.+bob/i)
      end
    end

    context "without schema.rb" do
      it "should work" do
        schema_rb = dump_schema
        expect(schema_rb).to match(/create_trigger\("users_after_insert_row_when_new_name_bob__tr", :generated => true, :compatibility => 1\)/)
        expect(schema_rb).to match(/create_trigger\("users_after_update_row_when_new_name_joe__tr", :compatibility => 1\)/)
      end

      it "should create adapter-specific triggers if no migrations exist" do
        FileUtils.rm_rf(Dir.glob('tmp/migrations/*rb'))
        schema_rb = dump_schema
        expect(schema_rb).not_to match(/create_trigger\(/)
        expect(schema_rb).to match(/no candidate create_trigger statement could be found, creating an adapter-specific one/)
      end

      it "should not dump triggers in migrations that haven't run" do
        # edit our model trigger, generate a new migration
        replace_file_contents HairTrigger.model_path + '/user.rb',
          '"UPDATE user_groups SET bob_count = bob_count + 1"',
          '{:default => "UPDATE user_groups SET bob_count = bob_count + 2"}'
        reset_models

        expect(HairTrigger).not_to be_migrations_current
        migration = HairTrigger.generate_migration
        expect(HairTrigger).to be_migrations_current

        schema_rb = dump_schema
        expect(schema_rb).to match(/bob_count \+ 1/)
        expect(schema_rb).not_to match(/bob_count \+ 2/)
      end

      it_should_behave_like 'filterable'
    end

    context "with schema.rb" do
      before do
        ActiveRecord::SchemaDumper.previous_schema = dump_schema
      end

      it "should work" do
        schema_rb = dump_schema
        expect(schema_rb).to match(/create_trigger\("users_after_insert_row_when_new_name_bob__tr", :generated => true, :compatibility => 1\)/)
        expect(schema_rb).to match(/create_trigger\("users_after_update_row_when_new_name_joe__tr", :compatibility => 1\)/)
      end

      it "should still work even if migrations have been deleted" do
        FileUtils.rm_rf(Dir.glob('tmp/migrations/*rb'))
        schema_rb = dump_schema
        expect(schema_rb).to match(/create_trigger\("users_after_insert_row_when_new_name_bob__tr", :generated => true, :compatibility => 1\)/)
        expect(schema_rb).to match(/create_trigger\("users_after_update_row_when_new_name_joe__tr", :compatibility => 1\)/)
      end

      it "should evaluate all migrations even if they haven't run" do
        # edit our model trigger, generate a new migration
        replace_file_contents HairTrigger.model_path + '/user.rb',
          '"UPDATE user_groups SET bob_count = bob_count + 1"',
          '{:default => "UPDATE user_groups SET bob_count = bob_count + 2"}'
        reset_models

        expect(HairTrigger).not_to be_migrations_current
        migration = HairTrigger.generate_migration
        expect(HairTrigger).to be_migrations_current

        schema_rb = dump_schema
        expect(schema_rb).to match(/bob_count \+ 1/)
        expect(schema_rb).not_to match(/bob_count \+ 2/)
      end

      it_should_behave_like 'filterable'
    end

  end
end
