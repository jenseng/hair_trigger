require 'spec_helper'

HairTrigger::Builder.show_warnings = false

class MockAdapter
  attr_reader :adapter_name
  def initialize(type, methods = {})
    @adapter_name = type
    methods.each do |key, value|
      instance_eval("def #{key}; #{value.inspect}; end")
    end
  end

  def quote_table_name(table)
    table
  end
end

def builder(name = nil)
  HairTrigger::Builder.new(name, :adapter => @adapter)
end

describe "builder" do
  context "chaining" do
    it "should use the last redundant chained call" do
      @adapter = MockAdapter.new("mysql")
      expect(builder.where(:foo).where(:bar).options[:where]).to be(:bar)
    end
  end

  context "generation" do
    it "should tack on a semicolon if none is provided" do
      @adapter = MockAdapter.new("mysql")
      expect(builder.on(:foos).after(:update){ "FOO " }.generate.
        grep(/FOO;/).size).to eql(1)
    end

    it "should work with frozen strings" do
      @adapter = MockAdapter.new("mysql")
      expect {
        builder.on(:foos).after(:update){ "FOO".freeze }.generate
    }.not_to raise_error
    end
  end

  context "comparison" do
    it "should view identical triggers as identical" do
      @adapter = MockAdapter.new("mysql")
      expect(builder.on(:foos).after(:update){ "FOO" }).
        to eql(builder.on(:foos).after(:update){ "FOO" })
    end

    it "should view incompatible triggers as different" do
      @adapter = MockAdapter.new("mysql")
      expect(HairTrigger::Builder.new(nil, :adapter => @adapter, :compatibility => 0).on(:foos).after(:update){ "FOO" }).
        not_to eql(builder.on(:foos).after(:update){ "FOO" })
    end
  end

  describe "name" do
    it "should be inferred if none is provided" do
      expect(builder.on(:foos).after(:update){ "foo" }.prepared_name).
        to eq "foos_after_update_row_tr"
    end

    it "should respect the last chained name" do
      expect(builder("lolwut").on(:foos).after(:update){ "foo" }.prepared_name).
        to eq "lolwut"
      expect(builder("lolwut").on(:foos).name("zomg").after(:update).name("yolo"){ "foo" }.prepared_name).
        to eq "yolo"
    end
  end

  describe "`of' columns" do
    it "should be disallowed for non-update triggers" do
      expect {
        builder.on(:foos).after(:insert).of(:bar, :baz){ "BAR" }
      }.to raise_error /of may only be specified on update triggers/
    end
  end

  describe "groups" do
    it "should allow chained methods" do
      triggers = builder.on(:foos){ |t|
        t.where('bar=1').name('bar'){ 'BAR;' }
        t.where('baz=1').name('baz'){ 'BAZ;' }
      }.triggers
      triggers.map(&:prepare!)
      expect(triggers.map(&:prepared_name)).to eq ['bar', 'baz']
      expect(triggers.map(&:prepared_where)).to eq ['bar=1', 'baz=1']
      expect(triggers.map(&:prepared_actions)).to eq ['BAR;', 'BAZ;']
    end
  end

  context "adapter-specific actions" do
    before(:each) do
      @adapter = MockAdapter.new("mysql")
    end

    it "should generate the appropriate trigger for the adapter" do
      sql = builder.on(:foos).after(:update).where('BAR'){
        {:default => "DEFAULT", :mysql => "MYSQL"}
      }.generate

      expect(sql.grep(/DEFAULT/).size).to eql(0)
      expect(sql.grep(/MYSQL/).size).to eql(1)

      sql = builder.on(:foos).after(:update).where('BAR'){
        {:default => "DEFAULT", :postgres => "POSTGRES"}
      }.generate

      expect(sql.grep(/POSTGRES/).size).to eql(0)
      expect(sql.grep(/DEFAULT/).size).to eql(1)
    end

    it "should complain if no actions are provided for this adapter" do
      expect {
        builder.on(:foos).after(:update).where('BAR'){ {:postgres => "POSTGRES"} }.generate
      }.to raise_error /no actions specified/
    end
  end

  context "mysql" do
    before(:each) do
      @adapter = MockAdapter.new("mysql")
    end

    it "should create a single trigger for a group" do
      trigger = builder.on(:foos).after(:update){ |t|
        t.where('BAR'){ 'BAR' }
        t.where('BAZ'){ 'BAZ' }
      }
      expect(trigger.generate.grep(/CREATE.*TRIGGER/).size).to eql(1)
    end

    it "should disallow nested groups" do
      expect {
        builder.on(:foos){ |t|
          t.after(:update){ |t|
            t.where('BAR'){ 'BAR' }
            t.where('BAZ'){ 'BAZ' }
          }
        }.generate
      }.to raise_error /trigger group must specify timing and event/
    end

    it "should warn on explicit subtrigger names and no group name" do
      trigger = builder.on(:foos){ |t|
        t.where('bar=1').name('bar'){ 'BAR;' }
        t.where('baz=1').name('baz'){ 'BAZ;' }
      }
      expect(trigger.warnings.size).to eq 1
      expect(trigger.warnings.first.first).to match /nested triggers have explicit names/
    end

    it "should accept security" do
      expect(builder.on(:foos).after(:update).security(:definer){ "FOO" }.generate.
        grep(/DEFINER/).size).to eql(0) # default, so we don't include it
      expect(builder.on(:foos).after(:update).security("CURRENT_USER"){ "FOO" }.generate.
        grep(/DEFINER = CURRENT_USER/).size).to eql(1)
      expect(builder.on(:foos).after(:update).security("'user'@'host'"){ "FOO" }.generate.
        grep(/DEFINER = 'user'@'host'/).size).to eql(1)
    end

    it "should infer `if' conditionals from `of' columns" do
      expect(builder.on(:foos).after(:update).of(:bar){ "BAZ" }.generate.join("\n")).
        to include("IF NEW.bar <> OLD.bar OR (NEW.bar IS NULL) <> (OLD.bar IS NULL) THEN")
    end

    it "should merge `where` and `of` into an `if` conditional" do
      expect(builder.on(:foos).after(:update).of(:bar).where("lol"){ "BAZ" }.generate.join("\n")).
        to include("IF (lol) AND (NEW.bar <> OLD.bar OR (NEW.bar IS NULL) <> (OLD.bar IS NULL)) THEN")
    end

    it "should reject :invoker security" do
      expect {
        builder.on(:foos).after(:update).security(:invoker){ "FOO" }.generate
      }.to raise_error /doesn't support invoker/
    end

    it "should reject for_each :statement" do
      expect {
        builder.on(:foos).after(:update).for_each(:statement){ "FOO" }.generate
      }.to raise_error /don't support FOR EACH STATEMENT triggers/
    end

    it "should reject multiple events" do
      expect {
        builder.on(:foos).after(:update, :delete){ "FOO" }.generate
      }.to raise_error /triggers may not be shared by multiple actions/
    end

    it "should reject truncate" do
      expect {
        builder.on(:foos).after(:truncate){ "FOO" }.generate
      }.to raise_error /do not support truncate triggers/
    end

    describe "#to_ruby" do
      it "should fully represent the builder" do
        code = <<-CODE.strip.gsub(/^ +/, '')
          on("foos").
          security(:definer).
          for_each(:row).
          before(:update) do |t|
            t.where("NEW.foo") do
              "FOO;"
            end
          end
        CODE
        b = builder
        b.instance_eval(code)
        expect(b.to_ruby.strip.gsub(/^ +/, '')).to be_include(code)
      end
    end
  end

  context "postgresql" do
    before(:each) do
      @adapter = MockAdapter.new("postgresql", :postgresql_version => 94000)
    end

    it "should create multiple triggers for a group" do
      trigger = builder.on(:foos).after(:update){ |t|
        t.where('BAR'){ 'BAR' }
        t.where('BAZ'){ 'BAZ' }
      }
      expect(trigger.generate.grep(/CREATE.*TRIGGER/).size).to eql(2)
    end

    it "should allow nested groups" do
      trigger = builder.on(:foos){ |t|
        t.after(:update){ |t|
          t.where('BAR'){ 'BAR' }
          t.where('BAZ'){ 'BAZ' }
        }
        t.after(:insert){ 'BAZ' }
      }
      expect(trigger.generate.grep(/CREATE.*TRIGGER/).size).to eql(3)
    end

    it "should warn on an explicit group names and no subtrigger names" do
      trigger = builder.on(:foos).name('foos'){ |t|
        t.where('bar=1'){ 'BAR;' }
        t.where('baz=1'){ 'BAZ;' }
      }
      expect(trigger.warnings.size).to eq 1
      expect(trigger.warnings.first.first).to match /trigger group has an explicit name/
    end

    it "should accept `of' columns" do
      trigger = builder.on(:foos).after(:update).of(:bar, :baz){ "BAR" }
      expect(trigger.generate.grep(/AFTER UPDATE OF bar, baz/).size).to eql(1)
    end

    it "should reject use of referencing pre-10.0" do
      expect {
        builder.on(:foos).after(:update).new_as("new_table").old_as("old_table"){ "FOO" }.generate
      }.to raise_error /referencing can only be used on postgres 10.0 and greater/
    end

    it "should accept security" do
      expect(builder.on(:foos).after(:update).security(:invoker){ "FOO" }.generate.
        grep(/SECURITY/).size).to eql(0) # default, so we don't include it
      expect(builder.on(:foos).after(:update).security(:definer){ "FOO" }.generate.
        grep(/SECURITY DEFINER/).size).to eql(1)
    end

    it "should reject arbitrary user security" do
      expect {
        builder.on(:foos).after(:update).security("'user'@'host'"){ "FOO" }.
        generate
      }.to raise_error /doesn't support arbitrary users for trigger security/
    end

    it "should accept multiple events" do
      expect(builder.on(:foos).after(:update, :delete){ "FOO" }.generate.
        grep(/UPDATE OR DELETE/).size).to eql(1)
    end

    it "should reject long names" do
      expect {
        builder.name('A'*65).on(:foos).after(:update){ "FOO" }.generate
      }.to raise_error /trigger name cannot exceed/
    end

    it "should allow truncate with for_each statement" do
      expect(builder.on(:foos).after(:truncate).for_each(:statement){ "FOO" }.generate.
        grep(/TRUNCATE.*FOR EACH STATEMENT/m).size).to eql(1)
    end

    it "should reject truncate with for_each row" do
      expect {
        builder.on(:foos).after(:truncate){ "FOO" }.generate
      }.to raise_error /FOR EACH ROW triggers may not be triggered by truncate events/
    end

    it "should add a return statement if none is provided" do
      expect(builder.on(:foos).after(:update){ "FOO" }.generate.
        grep(/RETURN NULL;/).size).to eql(1)
    end

    it "should not wrap the action in a function" do
      expect(builder.on(:foos).after(:update).nowrap{ 'existing_procedure()' }.generate.
        grep(/CREATE FUNCTION/).size).to eql(0)
    end

    it "should reject combined use of security and nowrap" do
      expect {
        builder.on(:foos).after(:update).security("'user'@'host'").nowrap{ "FOO" }.generate
      }.to raise_error /doesn't support arbitrary users for trigger security/
    end

    it "should allow variable declarations" do
      expect(builder.on(:foos).after(:insert).declare("foo INT"){ "FOO" }.generate.join("\n")).
        to match(/DECLARE\s*foo INT;\s*BEGIN\s*FOO/)
    end

    context ">= 10.0" do
      before(:each) do
        @adapter = MockAdapter.new("postgresql", :postgresql_version => 100000)
      end

      it "should accept `new_as' and `old_as' tables" do
        trigger = builder.on(:foos).after(:update).new_as("new_table").old_as("old_table"){ "FOO" }
        expect(trigger.generate.grep(/REFERENCING NEW TABLE AS new_table OLD TABLE AS old_table/).size).to eql(1)
      end
    end

    context "legacy" do
      it "should reject truncate pre-8.4" do
        @adapter = MockAdapter.new("postgresql", :postgresql_version => 80300)
        expect {
          builder.on(:foos).after(:truncate).for_each(:statement){ "FOO" }.generate
        }.to raise_error /truncate triggers are only supported/
      end

      it "should use conditionals pre-9.0" do
        @adapter = MockAdapter.new("postgresql", :postgresql_version => 80400)
        expect(builder.on(:foos).after(:insert).where("BAR"){ "FOO" }.generate.
          grep(/IF BAR/).size).to eql(1)
      end

      it "should reject combined use of where and nowrap pre-9.0" do
        @adapter = MockAdapter.new("postgresql", :postgresql_version => 80400)
        expect {
          builder.on(:foos).after(:insert).where("BAR").nowrap{ "FOO" }.generate
        }.to raise_error /where can only be used in conjunction with nowrap/
      end

      it "should infer `if' conditionals from `of' columns on pre-9.0" do
        @adapter = MockAdapter.new("postgresql", :postgresql_version => 80400)
        expect(builder.on(:foos).after(:update).of(:bar){ "BAZ" }.generate.join("\n")).
          to include("IF NEW.bar <> OLD.bar OR (NEW.bar IS NULL) <> (OLD.bar IS NULL) THEN")
      end
    end

    describe "#to_ruby" do
      it "should fully represent the builder" do
        code = <<-CODE.strip.gsub(/^ +/, '')
          on("foos").
          of("bar").
          security(:invoker).
          for_each(:row).
          before(:update) do |t|
            t.where("NEW.foo").declare("row RECORD") do
              "FOO;"
            end
          end
        CODE
        b = builder
        b.instance_eval(code)
        expect(b.to_ruby.strip.gsub(/^ +/, '')).to be_include(code)
      end
    end
  end

  context "sqlite" do
    before(:each) do
      @adapter = MockAdapter.new("sqlite")
    end

    it "should create multiple triggers for a group" do
      trigger = builder.on(:foos).after(:update){ |t|
        t.where('BAR'){ 'BAR' }
        t.where('BAZ'){ 'BAZ' }
      }
      expect(trigger.generate.grep(/CREATE.*TRIGGER/).size).to eql(2)
    end

    it "should allow nested groups" do
      trigger = builder.on(:foos){ |t|
        t.after(:update){ |t|
          t.where('BAR'){ 'BAR' }
          t.where('BAZ'){ 'BAZ' }
        }
        t.after(:insert){ 'BAZ' }
      }
      expect(trigger.generate.grep(/CREATE.*TRIGGER/).size).to eql(3)
    end

    it "should warn on an explicit group names and no subtrigger names" do
      trigger = builder.on(:foos).name('foos'){ |t|
        t.where('bar=1'){ 'BAR;' }
        t.where('baz=1'){ 'BAZ;' }
      }
      expect(trigger.warnings.size).to eq 1
      expect(trigger.warnings.first.first).to match /trigger group has an explicit name/
    end

    it "should accept `of' columns" do
      trigger = builder.on(:foos).after(:update).of(:bar, :baz){ "BAR" }
      expect(trigger.generate.grep(/AFTER UPDATE OF bar, baz/).size).to eql(1)
    end

    it "should reject security" do
      expect {
        builder.on(:foos).after(:update).security(:definer){ "FOO" }.generate
      }.to raise_error /doesn't support trigger security/
    end

    it "should reject for_each :statement" do
      expect {
        builder.on(:foos).after(:update).for_each(:statement){ "FOO" }.generate
      }.to raise_error /don't support FOR EACH STATEMENT triggers/
    end

    it "should reject multiple events" do
      expect {
        builder.on(:foos).after(:update, :delete){ "FOO" }.generate
      }.to raise_error /triggers may not be shared by multiple actions/
    end

    it "should reject truncate" do
      expect {
        builder.on(:foos).after(:truncate){ "FOO" }.generate
      }.to raise_error /do not support truncate triggers/
    end

    describe "#to_ruby" do
      it "should fully represent the builder" do
        code = <<-CODE.strip.gsub(/^ +/, '')
          on("foos").
          of("bar").
          before(:update) do |t|
            t.where("NEW.foo") do
              "FOO;"
            end
          end
        CODE
        b = builder
        b.instance_eval(code)
        expect(b.to_ruby.strip.gsub(/^ +/, '')).to be_include(code)
      end
    end
  end
end
