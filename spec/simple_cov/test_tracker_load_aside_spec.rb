# frozen_string_literal: true

require "helper"
require "coverage"
require "pathname"
require "tmpdir"

RSpec.describe SimpleCov::TestTracker do
  subject(:tracker) { described_class.new(root_regex: %r{\A/proj/}) }

  let(:file) { "/proj/app/models/room.rb" }

  def peeks(*counts)
    allow(Coverage).to receive(:peek_result).and_return(*counts.map { |lines| {file => {lines: lines}} })
  end

  def covering(line) = tracker.recorded_map.covering(file, line)

  describe "#aside" do
    context "with a load in the middle of a test" do
      before do
        # test opens, aside opens boot, aside reopens the test, the map flushes
        peeks([0, 0, 0], [1, 0, 0], [1, 1, 0], [1, 1, 1])
        tracker.track("t") { tracker.aside("(boot)") { :loaded } }
      end

      it "keeps what the test ran before and after the load" do
        expect([covering(1), covering(3)]).to eq([["t"], ["t"]])
      end

      it "charges what ran during the load to the other context" do
        expect(covering(2)).to eq(["(boot)"])
      end
    end

    it "answers the block's value" do
      peeks([0, 0, 0], [0, 0, 0], [0, 0, 0])
      tracker.track("t") {}

      expect(tracker.aside("(boot)") { :loaded }).to eq(:loaded)
    end

    it "does nothing before any segment is open" do
      allow(Coverage).to receive(:peek_result)
      tracker.aside("(boot)") { :loaded }

      expect(Coverage).not_to have_received(:peek_result)
    end

    it "does nothing when the open segment is the one asked for" do
      peeks([0, 0, 0], [0, 0, 0])
      tracker.track("(boot)") {}
      tracker.aside("(boot)") { :loaded }

      expect(Coverage).to have_received(:peek_result).once
    end

    it "leaves the segment alone for a thread that runs no test" do
      peeks([0, 0, 0], [1, 1, 0], [1, 1, 1])
      tracker.track("t") { Thread.new { tracker.aside("(boot)") { :loaded } }.join }

      expect(covering(2)).to eq(["t"])
    end

    it "leaves the segment alone once the load poisons the recording" do
      peeks([0, 0, 0], [0, 0, 0], [0, 0, 0])
      tracker.track("t") { tracker.aside("(boot)") { tracker.send(:poison) } }

      expect(Coverage).to have_received(:peek_result).twice
    end

    it "stops once the recording is poisoned" do
      peeks([0, 0, 0], [0, 0, 0])
      tracker.track("t") {}
      tracker.send(:poison)
      tracker.aside("(boot)") { :loaded }

      expect(Coverage).to have_received(:peek_result).once
    end
  end

  describe "#loading" do
    let(:unloaded) { "/proj/lib/unloaded.rb" }

    before do
      allow($LOAD_PATH).to receive(:resolve_feature_path).and_call_original
      allow($LOAD_PATH).to receive(:resolve_feature_path).with("unloaded").and_return([:rb, unloaded])
      allow(Coverage).to receive(:peek_result).and_return({})
    end

    # A test's track takes one peek; a load set aside takes two more, one to
    # open boot's segment and one to reopen the test's.
    def require_in_test(feature)
      tracker.track("t") { tracker.loading(feature, :require) { true } }
    end

    it "runs a Ruby file's first require inside a test in boot's segment" do
      require_in_test("unloaded")

      expect(Coverage).to have_received(:peek_result).exactly(3).times
    end

    it "answers what the load answers" do
      expect(tracker.track("t") { tracker.loading("unloaded", :require) { :required } }).to eq(:required)
    end

    it "leaves a require in boot's own segment where it is" do
      tracker.track("(boot)") { tracker.loading("unloaded", :require) { true } }

      expect(Coverage).to have_received(:peek_result).once
    end

    it "leaves a require before tracking opens any segment where it is" do
      tracker.loading("unloaded", :require) { true }

      expect(Coverage).not_to have_received(:peek_result)
    end

    context "with a feature already loaded, required twice" do
      before { 2.times { tracker.track("t") { tracker.loading("json", :require) { false } } } }

      it "leaves the require where it is" do
        expect(Coverage).to have_received(:peek_result).once
      end

      it "resolves it once" do
        expect($LOAD_PATH).to have_received(:resolve_feature_path).with("json").once
      end
    end

    it "remembers a first require that loaded nothing" do
      2.times { tracker.track("t") { tracker.loading("unloaded", :require) { false } } }

      expect(Coverage).to have_received(:peek_result).exactly(3).times
    end

    it "leaves a feature that does not resolve to require itself" do
      require_in_test("no/such/feature")

      expect(Coverage).to have_received(:peek_result).exactly(1).times
    end

    it "leaves a feature that resolves to a compiled extension where it is" do
      require_in_test("etc")

      expect(Coverage).to have_received(:peek_result).exactly(1).times
    end

    it "reads a feature given as a path object" do
      require_in_test(Pathname("unloaded"))

      expect(Coverage).to have_received(:peek_result).exactly(3).times
    end

    it "leaves a feature that is no name at all to require itself" do
      require_in_test(42)

      expect(Coverage).to have_received(:peek_result).exactly(1).times
    end

    it "runs RSpec's load of a spec file in that file's segment" do
      allow(described_class).to receive(:rspec_spec_file).with("/proj/spec/a_spec.rb").and_return("spec/a_spec.rb")
      allow(Coverage).to receive(:peek_result).and_return({file => {lines: [0]}}, {file => {lines: [0]}},
        {file => {lines: [1]}}, {file => {lines: [1]}})
      tracker.track("(boot)") { tracker.loading("/proj/spec/a_spec.rb", :load) { true } }

      expect(covering(1)).to eq(["spec/a_spec.rb"])
    end

    it "runs only the first load of a path in boot's segment" do
      2.times { tracker.track("t") { tracker.loading("/proj/lib/script.rb", :load) { true } } }

      expect(Coverage).to have_received(:peek_result).exactly(3).times
    end
  end

  context "with a real file required inside a test" do
    let(:root) { Dir.mktmpdir }
    let(:lazy) { File.join(root, "lazy_in_test.rb") }
    let(:tracker) { described_class.new(root_regex: /\A#{Regexp.escape(root)}/) }

    before do
      stub_const("LazyInTest", Module.new)
      File.write(lazy, "module LazyInTest\n  def self.call\n    :called\n  end\nend\n")
      tracker.track("(boot)") {}
      tracker.track("spec/lazy_spec.rb:1") do
        tracker.loading(lazy, :require) { require lazy }
        LazyInTest.call
      end
    end

    after do
      $LOADED_FEATURES.delete(lazy)
      FileUtils.rm_rf(root)
    end

    it "charges its class body to boot" do
      expect(tracker.recorded_map.covering(lazy, 1)).to eq(["(boot)"])
    end

    it "charges the method the test called to the test" do
      expect(tracker.recorded_map.covering(lazy, 3)).to eq(["spec/lazy_spec.rb:1"])
    end
  end

  describe ".rspec_spec_file" do
    let(:files) { ["spec/a_spec.rb", "/elsewhere/b_spec.rb"] }
    let(:rspec) do
      list = files
      class_double(RSpec, configuration: instance_double(RSpec::Core::Configuration, files_to_run: list))
    end

    after { described_class.instance_variable_set(:@rspec_spec_files, nil) }

    it "names a spec file RSpec runs the way its examples do" do
      expect(described_class.rspec_spec_file(File.expand_path("spec/a_spec.rb"), rspec)).to eq("spec/a_spec.rb")
    end

    it "keeps a spec file outside the working directory absolute" do
      expect(described_class.rspec_spec_file("/elsewhere/b_spec.rb", rspec)).to eq("/elsewhere/b_spec.rb")
    end

    it "names no other file" do
      expect(described_class.rspec_spec_file(File.expand_path("lib/a.rb"), rspec)).to be_nil
    end

    it "names nothing without RSpec" do
      expect(described_class.rspec_spec_file(File.expand_path("spec/a_spec.rb"), nil)).to be_nil
    end

    it "reads a new list once RSpec has one" do
      described_class.rspec_spec_file(File.expand_path("lib/a.rb"), rspec)
      files.replace(["spec/c_spec.rb"])
      allow(rspec.configuration).to receive(:files_to_run).and_return(files.dup)

      expect(described_class.rspec_spec_file(File.expand_path("spec/c_spec.rb"), rspec)).to eq("spec/c_spec.rb")
    end
  end

  describe SimpleCov::TestTracker::LoadHook do
    let(:kernel) do
      Module.new do
        private

        def load(file, *) = [:load, file]

        def require(feature) = [:require, feature]
      end
    end
    let(:host) do
      described_class.install(kernel)
      mod = kernel
      Class.new { include mod }.new
    end
    let(:live) { instance_double(SimpleCov::TestTracker) }

    def with_tracker
      allow(live).to receive(:loading) { |*, &block| block.call }
      SimpleCov.instance_variable_set(:@test_tracker, live)
      yield
    ensure
      SimpleCov.remove_instance_variable(:@test_tracker)
    end

    it "hands a require to the tracker" do
      with_tracker { host.send(:require, "lib/a") }

      expect(live).to have_received(:loading).with("lib/a", :require)
    end

    it "hands a load to the tracker" do
      with_tracker { host.send(:load, "lib/a.rb", true) }

      expect(live).to have_received(:loading).with("lib/a.rb", :load)
    end

    it "answers what the load answers" do
      expect(with_tracker { host.send(:load, "/proj/a.rb", true) }).to eq([:load, "/proj/a.rb"])
    end

    it "passes loads straight through without a tracker" do
      expect([host.send(:load, "a.rb"), host.send(:require, "b")]).to eq([[:load, "a.rb"], [:require, "b"]])
    end

    it "installs once" do
      2.times { described_class.install(kernel) }
      mod = kernel

      expect(Class.new { include mod }.new.send(:require, "b")).to eq([:require, "b"])
    end

    # Zeitwerk aliases `require` as it loads and handles a namespace directory
    # itself, passing the rest to what it aliased.
    def wrap_like_zeitwerk
      kernel.module_eval do
        alias_method :zeitwerk_original_require, :require
        define_method(:require) { |feature| feature.end_with?("/namespace") ? :autovivified : zeitwerk_original_require(feature) }
      end
    end

    it "stays in the chain when a library wraps require after it" do
      host && wrap_like_zeitwerk

      expect(with_tracker { [host.send(:require, "/gems/x/namespace"), host.send(:require, "/proj/a.rb")] })
        .to eq([:autovivified, [:require, "/proj/a.rb"]])
    end
  end
end
