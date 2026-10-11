# Math, generators, file restrictions and operation replay; no claim to simulate native SketchUp geometry.
require_relative 'test_bridge'
require 'matrix'
module Geom
  class Vector3d
    attr_reader :values
    def initialize(*values); @values=values.flatten.map(&:to_f); end
    def to_a; @values; end
    def cross(other)
      a=to_a;b=other.to_a
      Vector3d.new(a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
    end
    def length; Math.sqrt(to_a.sum { |n| n*n }); end
    def normalize!; len=length;@values.map! { |n| n/len };self;end
    def dot(other); to_a.zip(other.to_a).sum { |a,b| a*b }; end
  end
  class Point3d
    def initialize(*values);@values=values.flatten.map(&:to_f);end
    def to_a;@values;end
    def -(other);Vector3d.new(to_a.zip(other.to_a).map { |a,b| a-b });end
    def transform(t);Point3d.new((t.matrix*Vector[*to_a,1]).to_a.first(3));end
  end
  class Transformation
    attr_reader :matrix
    def initialize(matrix=Matrix.identity(4));@matrix=matrix;end
    def *(other);Transformation.new(matrix*other.matrix);end
    def inverse;Transformation.new(matrix.inverse);end
    def origin;Point3d.new(matrix[0,3],matrix[1,3],matrix[2,3]);end
    def self.translation(values)
      a=values.respond_to?(:to_a) ? values.to_a : values
      m=Matrix[[1,0,0,a[0]],[0,1,0,a[1]],[0,0,1,a[2]],[0,0,0,1]]
      new(m)
    end
    def self.rotation(center,axis,angle)
      a=axis.respond_to?(:to_a) ? axis.to_a : axis
      raise 'Test rotation only implements Z' unless a==[0,0,1]
      c=Math.cos(angle);s=Math.sin(angle)
      t=translation(center)
      t*new(Matrix[[c,-s,0,0],[s,c,0,0],[0,0,1,0],[0,0,0,1]])*t.inverse
    end
  end
end

class AutomationTests < Minitest::Test
  Bridge=LocalSketchUpMCP::Bridge
  def setup
    Sketchup.active_model=ModelStub.new
    Bridge.instance_variable_set(:@session,'automation-test')
  end

  def corners(min,max,angle=0)
    c=Math.cos(angle);s=Math.sin(angle)
    8.times.map do |i|
      x=(i&1)==0 ? min[0] : max[0];y=(i&2)==0 ? min[1] : max[1];z=(i&4)==0 ? min[2] : max[2]
      Geom::Point3d.new(x*c-y*s,x*s+y*c,z)
    end
  end

  def test_sat_detects_overlap_touch_and_rotated_separation
    a={corners:corners([0,0,0],[1,1,1])}
    assert Bridge.box_intersects?(a,{corners:corners([0.5,0.5,0.5],[1.5,1.5,1.5])},0)
    refute Bridge.box_intersects?(a,{corners:corners([1,0,0],[2,1,1])},0)
    refute Bridge.box_intersects?(a,{corners:corners([3,0,0],[4,1,1],Math::PI/4)},0)
    assert Bridge.box_intersects?(a,{corners:corners([0,0,0],[1,1,1],Math::PI/4)},0)
  end

  def test_parametric_width_keeps_panel_thickness_and_rejects_bad_shelves
    [300,320,750].each do |width|
      spec,p=Bridge.cabinet_spec({'width_mm'=>width,'depth_mm'=>720,'height_mm'=>2600,'panel_mm'=>18,'shelves_mm'=>[800,1800]},'Test')
      sides=spec['shapes'].select { |shape| shape['name'].include?('боковина') }
      assert_equal [18,18],sides.map { |shape| shape['size'][0] }
      assert_equal width-36,spec['shapes'].find { |shape| shape['name']=='Дно' }['size'][0]
    end
    assert_raises(RuntimeError) { Bridge.cabinet_spec({'width_mm'=>30,'depth_mm'=>720,'height_mm'=>950},'Bad') }
    assert_raises(RuntimeError) { Bridge.cabinet_spec({'width_mm'=>300,'depth_mm'=>720,'height_mm'=>950,'shelves_mm'=>[800,805]},'Bad') }
  end

  def test_current_project_primitive_files_normalize
    project=File.expand_path('..',__dir__)
    Dir.glob(File.join(project,'artifacts/*/model-primitives.json')).each do |file|
      data=Bridge.normalize_assembly({'json_path'=>file})
      keys=data['groups'].map { |group| group['key'] }+['Root']
      assert data['shapes'].all? { |shape| keys.include?(shape.fetch('group','Root')) },file
      assert data['materials'].all? { |material| material['rgb'].length==3 },file
    end
  end

  def test_file_guard_rejects_symlink_escape_and_unconfigured_files
    Dir.mktmpdir do |directory|
      Dir.mktmpdir do |outside|
        file=File.join(outside,'escape.rb');File.write(file,'puts 1')
        link=File.join(directory,'escape.rb');File.symlink(file,link)
        Bridge.stub(:file_roots,[File.realpath(directory)]) do
          assert_raises(RuntimeError) { Bridge.automation_file(link) }
          assert_raises(RuntimeError) { Bridge.automation_file(file) }
          assert_equal File.join(File.realpath(directory),'new.skp'),Bridge.automation_file(File.join(directory,'new.skp'),true)
        end
      end
    end
  end

  def test_replay_executes_once_and_changed_payload_is_rejected
    id='test-'+SecureRandom.hex(8);calls=0;model=Sketchup.active_model
    handler=lambda { |m,t,a| calls+=1;{entity_id:123} }
    Bridge.stub(:automation_execute,handler) do
      first=Bridge.automation_dispatch(model,'transform_object',{'operation_id'=>id,'path'=>[1],'translation_mm'=>[0,0,0]})
      second=Bridge.automation_dispatch(model,'transform_object',{'operation_id'=>id,'translation_mm'=>[0,0,0],'path'=>[1]})
      assert_equal 123,first[:entity_id]
      assert_equal true,second['replayed']
      assert_equal 1,calls
      assert_equal [:start,:commit],model.events
      assert_equal 'completed',Bridge.operation_status(id)['status']
      assert_raises(RuntimeError) { Bridge.automation_dispatch(model,'transform_object',{'operation_id'=>id,'path'=>[2]}) }
    end
  end

  def test_failure_aborts_and_does_not_repeat_or_cross_model
    id='failure-'+SecureRandom.hex(8);calls=0;model=Sketchup.active_model
    Bridge.stub(:automation_execute,lambda { |*args| calls+=1;raise 'bad geometry' }) do
      2.times { assert_raises(RuntimeError) { Bridge.automation_dispatch(model,'transform_object',{'operation_id'=>id,'path'=>[1]}) } }
      assert_equal 1,calls
      assert_equal [:start,:abort],model.events
      assert_equal 'failed',Bridge.operation_status(id)['status']
    end
    assert_raises(RuntimeError) { Bridge.automation_dispatch(ModelStub.new,'transform_object',{'operation_id'=>id,'path'=>[1]}) }
  end

  def test_path_remapping_uses_longest_prefix
    Bridge.instance_variable_set(:@path_remap,{[1,2]=>[1,20],[1,2,3]=>[1,20,30]})
    assert_equal [1,20,30,4],Bridge.remapped_path([1,2,3,4])
  ensure
    Bridge.instance_variable_set(:@path_remap,nil)
  end

  def test_world_and_parent_translation_on_rotated_parent
    parent=Geom::Transformation.translation([100/25.4,200/25.4,0])*Geom::Transformation.rotation([0,0,0],[0,0,1],Math::PI/2)
    object=Struct.new(:transformation).new(Geom::Transformation.translation([10/25.4,0,0]))
    Bridge.edit_transform(object,parent,{'translation_mm'=>[0,-100,0],'space'=>'world'})
    actual=(parent*object.transformation).origin.to_a.map { |n| n*25.4 }
    assert_in_delta 100,actual[0],1e-8
    assert_in_delta 110,actual[1],1e-8
    object.transformation=Geom::Transformation.translation([10/25.4,0,0])
    Bridge.edit_transform(object,parent,{'translation_mm'=>[0,-100,0],'space'=>'parent'})
    actual=(parent*object.transformation).origin.to_a.map { |n| n*25.4 }
    assert_in_delta 200,actual[0],1e-8
    assert_in_delta 210,actual[1],1e-8
  end

  def test_absolute_world_placement_and_rotation_pivot
    parent=Geom::Transformation.translation([10,20,0])
    object=Struct.new(:transformation).new(Geom::Transformation.translation([1,2,0]))
    Bridge.edit_transform(object,parent,{'translation_mm'=>[750,0,150],'space'=>'world','absolute'=>true})
    world=parent*object.transformation
    assert_in_delta 750,world.origin.to_a[0]*25.4,1e-8
    assert_in_delta 150,world.origin.to_a[2]*25.4,1e-8
    Bridge.edit_transform(object,parent,{'rotation_degrees'=>90,'rotation_axis'=>[0,0,1],'pivot_mm'=>[0,0,0],'space'=>'world'})
    world=parent*object.transformation
    assert_in_delta 0,world.origin.to_a[0]*25.4,1e-8
    assert_in_delta 750,world.origin.to_a[1]*25.4,1e-8
  end

  def test_running_journal_does_not_reexecute_after_interruption
    id='running-'+SecureRandom.hex(8);args={'operation_id'=>id,'path'=>[1]};model=Sketchup.active_model
    fingerprint=Digest::SHA256.hexdigest(JSON.generate(Bridge.canonical({'tool'=>'transform_object','arguments'=>args})))
    Bridge.atomic_json(Bridge.journal_path(id),{'status'=>'running','fingerprint'=>fingerprint,'session'=>'automation-test','model_id'=>model.object_id.to_s})
    Bridge.stub(:automation_execute,lambda { |*_| raise 'must not execute' }) do
      error=assert_raises(RuntimeError) { Bridge.automation_dispatch(model,'transform_object',args) }
      assert_match(/running or outcome is unknown/,error.message)
      assert_empty model.events
    end
  end
end
