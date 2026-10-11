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
    def initialize(matrix=Matrix.identity(4))
      @matrix=matrix.is_a?(Array) ? Matrix.rows(matrix.each_slice(4).to_a).transpose : matrix
    end
    def to_a;matrix.transpose.to_a.flatten;end
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
    Dir.glob(File.join(project,'artifacts/*/cache/model-primitives.json')).each do |file|
      data=Bridge.normalize_assembly({'json_path'=>file})
      keys=data['groups'].map { |group| group['key'] }+['Root']
      assert data['shapes'].all? { |shape| keys.include?(shape.fetch('group','Root')) },file
      assert data['materials'].all? { |material| material['rgb'].length==3 },file
    end
  end

  def test_artifact_motion_metadata_includes_hatches_drawers_and_doors
    project=File.expand_path('..',__dir__)
    expected={'washing-machine'=>1,'dryer'=>1,'laundry-tower'=>2,'laundry-sink'=>2,'detergent-cabinet'=>5}
    expected.each do |folder,count|
      file=File.join(project,'artifacts',folder,'cache','model-primitives.json')
      next unless File.exist?(file)
      data=Bridge.normalize_assembly({'json_path'=>file})
      moving=data['groups'].select { |group| group['motion'] }
      assert_equal count,moving.length,folder
      assert moving.all? { |group| group['anchor_mm'].length==3 },folder
    end
  end

  def motion_entity(motion,closed)
    entity=Struct.new(:transformation,:attributes).new(closed,{
      'motion'=>JSON.generate(motion),'closed_transform'=>closed.to_a,'open'=>false})
    def entity.get_attribute(_dictionary,key,default=nil);attributes.fetch(key,default);end
    def entity.set_attribute(_dictionary,key,value);attributes[key]=value;end
    entity
  end

  def test_partial_drawer_position_limits_and_repeated_drag_without_drift
    closed=Geom::Transformation.translation([10,20,30])*Geom::Transformation.rotation([0,0,0],[0,0,1],Math::PI/4)
    entity=motion_entity({'translation_mm'=>[0,-400,0]},closed)
    [-1,0,0.3425,0.75,1,2].each do |requested|
      expected=[[requested,0].max,1].min
      Bridge.set_artifact_fraction(entity,requested)
      assert_in_delta expected,Bridge.artifact_fraction(entity),1e-10
      offset=(closed.inverse*entity.transformation).origin.to_a
      assert_in_delta -400*expected/25.4,offset[1],1e-10
      assert_in_delta 0,offset[0],1e-10
      assert_in_delta 0,offset[2],1e-10
    end
    100.times { |i| Bridge.set_artifact_fraction(entity,(i%17)/16.0) }
    Bridge.set_artifact_fraction(entity,0)
    assert_equal closed.to_a,entity.transformation.to_a
    # An existing component moved outside this tool is read from its actual transform.
    entity.transformation=closed*Geom::Transformation.translation([0,-137/25.4,0])
    assert_in_delta 137/400.0,Bridge.artifact_fraction(entity),1e-10
  end

  def test_partial_hinge_angle_and_exact_closed_position
    closed=Geom::Transformation.translation([4,5,6])
    entity=motion_entity({'rotation_axis'=>[0,0,1],'rotation_degrees'=>-100},closed)
    [0,0.1,0.37,0.5,1].each do |fraction|
      Bridge.set_artifact_fraction(entity,fraction)
      assert_in_delta fraction,Bridge.artifact_fraction(entity),1e-10
      assert_equal closed.origin.to_a,entity.transformation.origin.to_a
    end
    Bridge.set_artifact_fraction(entity,0)
    assert_equal closed.to_a,entity.transformation.to_a
    assert_raises(RuntimeError) { Bridge.set_artifact_fraction(entity,Float::NAN) }
  end

  def test_automation_writes_are_rejected_during_native_drag
    Bridge.instance_variable_set(:@artifact_drag_active,true)
    assert_raises(RuntimeError) { Bridge.automation_dispatch(Sketchup.active_model,'eval_ruby',{'code'=>'nil','operation_id'=>'drag-conflict'}) }
    assert_raises(RuntimeError) { Bridge.dispatch(Sketchup.active_model,'create_box',{'dimensions_mm'=>[1,1,1]}) }
  ensure
    Bridge.instance_variable_set(:@artifact_drag_active,false)
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

  def test_round_primitives_are_closed_outward_and_keep_millimeter_bounds
    %w[sphere cone].each do |type|
      %w[X Y Z].each do |axis|
        vertices,faces=Bridge.round_primitive_mesh({'type'=>type,'center'=>[10,20,30],'radius'=>100,'length'=>200,'axis'=>axis,'segments'=>32})
        edges=Hash.new { |h,k| h[k]=[] }
        volume=0.0
        faces.each do |face|
          face.each_with_index { |a,i| b=face[(i+1)%face.length];edges[[a,b].sort] << [a,b] }
          (1...face.length-1).each do |i|
            a,b,c=[face[0],face[i],face[i+1]].map { |j| Vector[*vertices[j]] }
            cross=(b-a).cross(c-a)
            assert_operator cross.magnitude,:>,1e-8
            volume+=a.dot(b.cross(c))/6
          end
        end
        assert edges.values.all? { |pair| pair.length==2 && pair[0]==pair[1].reverse },"#{type}: watertight winding"
        assert_operator volume,:>,0
        expected=type=='sphere' ? 4*Math::PI*100**3/3 : Math::PI*100**2*200/3
        assert_in_delta expected,volume,expected*0.03
        dims=3.times.map { |i| vertices.map { |p| p[i] }.max-vertices.map { |p| p[i] }.min }
        dims.each { |dimension| assert_in_delta 200,dimension,1e-7 }
        if type=='sphere'
          vertices.each { |p| assert_in_delta 100,Math.sqrt(p.zip([10,20,30]).sum { |a,b| (a-b)**2 }),1e-7 }
        else
          i=%w[X Y Z].index(axis)
          assert_in_delta [10,20,30][i]+200,vertices[-1][i],1e-7
        end
      end
    end
    assert_raises(RuntimeError) { Bridge.round_primitive_mesh({'type'=>'sphere','radius'=>0}) }
    assert_raises(RuntimeError) { Bridge.round_primitive_mesh({'type'=>'cone','radius'=>10,'length'=>0}) }
    assert_raises(RuntimeError) { Bridge.round_primitive_mesh({'type'=>'sphere','radius'=>10,'segments'=>13}) }
  end

  def test_eval_ruby_preserves_json_result_and_replays_without_execution
    model=Sketchup.active_model
    id='eval-'+SecureRandom.hex(8)
    args={'code'=>'$sketchup_mcp_eval_count = ($sketchup_mcp_eval_count || 0) + 1; {count: $sketchup_mcp_eval_count, values: [1, true, nil]}','operation_id'=>id}
    first=Bridge.automation_dispatch(model,'eval_ruby',args)
    second=Bridge.automation_dispatch(model,'eval_ruby',args)
    assert_equal({'count'=>1,'values'=>[1,true,nil]},first[:result])
    assert_equal true,second['replayed']
    assert_equal 1,$sketchup_mcp_eval_count
    assert_equal [:start,:commit],model.events
    assert_equal 'managed',first[:transaction]
  ensure
    $sketchup_mcp_eval_count=nil
  end

  def test_eval_ruby_failure_and_script_owned_transaction
    model=Sketchup.active_model
    args={'code'=>'def broken(','operation_id'=>'syntax-'+SecureRandom.hex(8)}
    assert_raises(RuntimeError) { Bridge.automation_dispatch(model,'eval_ruby',args) }
    assert_equal [:start,:abort],model.events
    assert_equal 'failed_possible_partial_changes',Bridge.operation_status(args['operation_id'])['status']
    refute Bridge.operation_status(args['operation_id']).key?('code')
    owned=ModelStub.new
    result=Bridge.automation_dispatch(owned,'eval_ruby',{'code'=>'21 * 2','transaction'=>'script_owned','operation_id'=>'owned-'+SecureRandom.hex(8)})
    assert_equal 42,result[:result]
    assert_empty owned.events
    assert_equal 'script_owned',result[:transaction]
  end

  def test_eval_ruby_captures_output_and_restores_streams_after_errors
    before_stdout=$stdout;before_stderr=$stderr
    result=Bridge.automation_execute(Sketchup.active_model,'eval_ruby',{'code'=>'puts "hello"; warn "notice"; 42'})
    assert_equal "hello\n",result[:stdout]
    assert_equal "notice\n",result[:stderr]
    assert_equal 42,result[:result]
    error=assert_raises(RuntimeError) { Bridge.automation_execute(Sketchup.active_model,'eval_ruby',{'code'=>'puts "before error"; raise "bad"'}) }
    assert_match(/before error/,error.message)
    assert_same before_stdout,$stdout
    assert_same before_stderr,$stderr
  end

  def test_selected_exports_restore_selection_even_when_exporter_raises
    model=ModelStub.new
    entity=Struct.new(:id) { def valid?;true;end }.new(123)
    old=Struct.new(:id) { def valid?;true;end }.new(456)
    selection=[old]
    selection.define_singleton_method(:add) { |items| concat(items) }
    model.define_singleton_method(:selection) { selection }
    calls=[]
    model.define_singleton_method(:export) { |file,options| calls << [selection.dup,options];File.write(file,'mesh');true }
    Dir.mktmpdir do |directory|
      Bridge.stub(:file_roots,[directory]) do
        Bridge.stub(:resolve_path,lambda { |*_| [entity] }) do
          args={'file_path'=>File.join(directory,'selected.dae'),'paths'=>[[123]],'render_compatible'=>true}
          Bridge.export_scene(model,args)
          assert_equal [old],selection
          assert_equal [entity],calls[0][0]
          assert calls[0][1][:selectionset_only]
          refute calls[0][1][:preserve_instancing]
          refute calls[0][1][:texture_maps]
          model.define_singleton_method(:export) { |*_| raise 'exporter failed' }
          assert_raises(RuntimeError) { Bridge.export_scene(model,args) }
          assert_equal [old],selection
          assert_raises(RuntimeError) { Bridge.export_scene(model,args.merge('paths'=>[[123,456]])) }
          assert_raises(RuntimeError) { Bridge.export_scene(model,args.merge('file_path'=>File.join(directory,'bad.png'))) }
          assert_empty model.events
        end
      end
    end
  end

  def test_export_formats_use_native_options_and_do_not_save_active_model
    model=ModelStub.new;calls=[]
    model.define_singleton_method(:export) { |file,options| calls << [:export,options];File.write(file,'mesh');true }
    model.define_singleton_method(:save_copy) { |file| calls << [:copy];File.write(file,'skp');true }
    view=Object.new
    view.define_singleton_method(:refresh) { }
    view.define_singleton_method(:write_image) { |options| calls << [:image,options];File.write(options[:filename],'image');true }
    model.define_singleton_method(:active_view) { view }
    Dir.mktmpdir do |directory|
      Bridge.stub(:file_roots,[directory]) do
        %w[obj dae stl png jpg skp].each do |extension|
          file=File.join(directory,"export.#{extension}")
          args={'file_path'=>file,'operation_id'=>'export-'+SecureRandom.hex(8)}
          args.merge!('width'=>640,'height'=>480) if %w[png jpg].include?(extension)
          result=Bridge.automation_dispatch(model,'export_scene',args)
          assert_equal extension,result[:format]
          assert_operator result[:bytes],:>,0
          assert_empty model.events
          if %w[obj stl].include?(extension)
            assert_equal 'mm',calls.last[1][:units]
            refute calls.last[1][:show_summary]
          elsif extension=='dae'
            assert calls.last[1][:preserve_instancing]
          elsif %w[png jpg].include?(extension)
            assert_equal 640,calls.last[1][:width]
            assert calls.last[1][:antialias]
          else
            assert_equal [:copy],calls.last
          end
        end
        assert_raises(RuntimeError) { Bridge.export_scene(model,{'file_path'=>File.join(directory,'bad.jpg'),'transparent'=>true}) }
        assert_raises(RuntimeError) { Bridge.export_scene(model,{'file_path'=>File.join(directory,'bad.stl'),'width'=>640}) }
        assert_raises(RuntimeError) { Bridge.export_scene(model,{'file_path'=>File.join(directory,'bad.xyz')}) }
        model.define_singleton_method(:export) { |*_args| false }
        assert_raises(RuntimeError) { Bridge.export_scene(model,{'file_path'=>File.join(directory,'failed.dae')}) }
      end
    end
  end
end
