# Exercise bridge control flow without claiming to simulate SketchUp geometry.
require 'tmpdir'
require 'minitest/autorun'
ROOT = File.expand_path('..', __dir__)
$LOADED_FEATURES << 'sketchup.rb'
def file_loaded?(_path); true; end
ENV['SKETCHUP_MCP_BRIDGE_DIR'] = Dir.mktmpdir('sketchup-mcp-ruby-test')
module Sketchup
  class << self
    attr_accessor :active_model
  end
end
require File.join(ROOT, 'extension/sketch_up_mcp/bridge')

class ModelStub
  attr_reader :events
  def initialize; @events = []; end
  def active_path; nil; end
  def start_operation(name, disable_ui); @events << :start; end
  def commit_operation; @events << :commit; end
  def abort_operation; @events << :abort; end
end

class BridgeTests < Minitest::Test
  Bridge = LocalSketchUpMCP::Bridge
  def setup
    Sketchup.active_model = ModelStub.new
    FileUtils.mkdir_p(File.join(Bridge::ROOT, 'requests'))
    FileUtils.mkdir_p(File.join(Bridge::ROOT, 'responses'))
    Bridge.instance_variable_set(:@session, 'test-session')
  end

  def test_success_commits_and_failure_aborts
    model = Sketchup.active_model
    assert_equal 42, Bridge.operation(model, 'Test') { 42 }
    assert_equal [:start, :commit], model.events
    assert_raises(RuntimeError) { Bridge.operation(model, 'Fail') { raise 'geometry error' } }
    assert_equal [:start, :commit, :start, :abort], model.events
  end

  def test_invalid_vectors_rejected_and_mm_converted
    Bridge.vector([25.4, 50.8, 76.2]).zip([1.0, 2.0, 3.0]).each do |actual, expected|
      assert_in_delta expected, actual, 1e-12
    end
    assert_raises(RuntimeError) { Bridge.vector([0, 1, 2], true) }
    assert_raises(RuntimeError) { Bridge.vector([Float::INFINITY, 1, 2]) }
  end

  def test_expired_and_changed_model_requests_do_not_dispatch
    [ { 'expires_at' => Time.now.to_f - 1 }, { 'model_id' => 'different-model' },
      { 'session' => 'old-session' }, { 'context' => [123] } ].each do |override|
      id = SecureRandom.hex(16)
      request = { 'id' => id, 'session' => 'test-session', 'model_id' => Sketchup.active_model.object_id.to_s,
                  'context' => [], 'expires_at' => Time.now.to_f + 10, 'tool' => 'create_box',
                  'arguments' => { 'dimensions_mm' => [100, 100, 100] } }.merge(override)
      path = File.join(Bridge::ROOT, 'requests', "#{id}.json")
      File.write(path, JSON.generate(request))
      Bridge.process(path)
      reply_path = File.join(Bridge::ROOT, 'responses', "#{id}.json")
      assert JSON.parse(File.read(reply_path)).key?('error')
      refute File.exist?(path)
      assert_empty Sketchup.active_model.events
    end
  end
end
Minitest.after_run { FileUtils.remove_entry(ENV['SKETCHUP_MCP_BRIDGE_DIR']) }
