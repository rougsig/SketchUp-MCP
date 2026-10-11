# Run AFTER activate.rb in SketchUp. Native API checks roll back all model changes.
require 'json'
module LocalSketchUpMCP
  module Smoke
    extend self
    def assert(condition,message)
      raise "Smoke test failed: #{message}" unless condition
    end
    def run
      model=Sketchup.active_model
      raise 'Exit component editing before smoke test' if model.active_path
      bridge=LocalSketchUpMCP::Bridge
      camera=model.active_view.camera
      initial=model.entities.to_a.map(&:persistent_id)
      model.start_operation('MCP smoke test — rolled back',true)
      started=true
      results=[]
      prefix='smoke-'+Time.now.to_f.to_s
      create=lambda { |key,shapes,groups=[],origin=[0,0,0]| bridge.automation_execute(model,'build_assembly',{'key'=>prefix+key,'assembly'=>{'name'=>key,'shapes'=>shapes,'groups'=>groups},'origin_mm'=>origin}) }
      shape={'type'=>'box','name'=>'Panel','origin'=>[0,0,0],'size'=>[100,200,300]}
      a=create.call('box',[shape]);path=[a[:entity][:id]]
      assert(a[:entity][:world_bounds_mm][:dimensions].zip([100,200,300]).all? { |x,y| (x-y).abs<0.01 },'native box dimensions')
      results << 'native box + world bounds'
      b=create.call('box2',[shape],[],[50,0,0]);other=[b[:entity][:id]]
      collision=bridge.automation_execute(model,'check_collisions',{'paths'=>[path,other]})
      assert(collision[:checks][0][:hits].any? { |hit| hit[:status]=='confirmed_box_intersection' },'exact box collision')
      motion=bridge.automation_execute(model,'check_motion',{'path'=>path,'obstacles'=>[other],'translation_mm'=>[-500,0,0],'steps'=>5})
      assert(motion[:model_changed]==false && !motion[:collisions].empty?,'sampled motion')
      results << 'collision + motion'
      nested=create.call('nested',[shape.merge('group'=>'Drawer')],[{'key'=>'Drawer','name'=>'Drawer','component'=>true,'anchor_mm'=>[0,0,0]}],[500,0,0])
      root=[nested[:entity][:id]];child=nested[:entity][:children][0][:path]
      copied=bridge.automation_execute(model,'copy_object',{'path'=>root,'independent'=>true,'delta_mm'=>[500,0,0]})
      copy_child=copied[:entity][:children][0][:path]
      moved=bridge.automation_execute(model,'transform_object',{'path'=>copy_child,'translation_mm'=>[0,-100,0],'space'=>'world'})
      unchanged=bridge.inspect_path(model,child)
      assert((unchanged[:world_bounds_mm][:min][1]).abs<0.01,'source drawer unchanged')
      assert((moved[:entity][:world_bounds_mm][:min][1]+100).abs<0.01,'nested world move')
      results << 'independent nested copy'
      native_circle=create.call('circle',[{'type'=>'cylinder','center'=>[0,0,0],'radius'=>50,'depth'=>100,'axis'=>'Z'}])
      entity=model.find_entity_by_persistent_id(native_circle[:entity][:id]);leaf=bridge.children(entity).find { |item| bridge.container?(item) }
      assert(bridge.children(leaf).grep(Sketchup::Edge).any? { |edge| edge.curve.is_a?(Sketchup::ArcCurve) },'native circle curve retained')
      plate=create.call('drain',[{'type'=>'plate_hole','origin'=>[0,0,0],'size'=>[200,200,5],'hole_center'=>[100,100,0],'radius'=>25}])
      assert(plate[:part_count]==1,'circular aperture')
      results << 'circle + drain aperture'
      round_paths=[]
      %w[sphere cone].each do |type|
        args={'key'=>prefix+type,'radius_mm'=>50,'center_mm'=>[1500,0,0],'segments'=>32}
        args['height_mm']=100 if type=='cone'
        item=bridge.automation_execute(model,'create_'+type,args)
        round_paths << [item[:entity][:id]]
        assert(item[:entity][:local_bounds_mm][:dimensions].all? { |n| (n-100).abs<0.01 },type+' dimensions')
        entity=model.find_entity_by_persistent_id(item[:entity][:id])
        leaf=bridge.children(entity).find { |part| bridge.container?(part) }
        assert(leaf.manifold?,type+' closed solid')
      end
      ruby=bridge.automation_execute(model,'eval_ruby',{'code'=>'puts "smoke stdout"; warn "smoke stderr"; {answer: 6 * 7}'})
      assert(ruby[:result]['answer']==42 && ruby[:stdout].include?('smoke stdout') && ruby[:stderr].include?('smoke stderr'),'inline Ruby result and output')
      results << 'sphere + cone solids + inline Ruby'
      workspace=File.expand_path('..',__dir__)
      export_directory=File.join(workspace,'artifacts','native-smoke','cache')
      FileUtils.mkdir_p(export_directory)
      bridge.automation_execute(model,'set_camera',{'paths'=>round_paths})
      previous_selection=model.selection.to_a
      %w[dae obj stl png jpg].each do |format|
        options={'file_path'=>File.join(export_directory,'round-primitives.'+format)}
        if %w[dae obj stl].include?(format)
          options['paths']=round_paths
          options['render_compatible']=true if format=='dae'
        else
          options.merge!('width'=>640,'height'=>480)
        end
        export=bridge.automation_execute(model,'export_scene',options)
        assert(export[:bytes]>0,format+' file exported')
        assert(model.selection.to_a==previous_selection,'selection restored after '+format)
      end
      results << 'selected DAE/OBJ/STL + native PNG/JPEG exports'
      cabinet=bridge.automation_execute(model,'create_furniture',{'key'=>prefix+'cabinet','parameters'=>{'width_mm'=>300,'depth_mm'=>720,'height_mm'=>950}})
      updated=bridge.automation_execute(model,'update_furniture',{'path'=>[cabinet[:entity][:id]],'parameters'=>{'width_mm'=>320}})
      assert(JSON.parse(updated[:entity][:parameters])['panel_mm']==18,'panel thickness after width update')
      assert((updated[:entity][:local_bounds_mm][:dimensions][0]-320).abs<0.01,'parametric width')
      results << 'parametric cabinet'
      scene=bridge.automation_execute(model,'create_scene',{'name'=>prefix+'scene'})
      assert(scene[:scene_id]>0,'scene creation')
      variants=bridge.automation_execute(model,'create_scene_variants',{'path'=>root,'variants'=>[
        {'name'=>prefix+'closed'},
        {'name'=>prefix+'open','transforms'=>[{'path'=>[child[-1]],'translation_mm'=>[0,-100,0],'space'=>'parent'}]}
      ]})
      assert(variants[:scenes].length==2,'independent scene variants')
      results << 'scenes + visibility variants'
      modules=[['sink','laundry-sink',[0,0,0]],['detergent','detergent-cabinet',[750,0,0]],
               ['tower','laundry-tower',[1088,0,0]],['washer','washing-machine',[1088,0,150]],['dryer','dryer',[1088,0,1038]]]
      row={}
      modules.each do |key,folder,origin|
        item=bridge.automation_execute(model,'build_assembly',{'key'=>prefix+key,
          'json_path'=>File.join(workspace,'artifacts',folder,'cache','model-primitives.json'),'origin_mm'=>origin})
        row[key]=[item[:entity][:id]]
      end
      measured=bridge.automation_execute(model,'measure_objects',{'paths'=>%w[sink detergent tower].map { |key| row[key] },'available_dimensions_mm'=>[1750,735,2750]})
      assert(measured[:fits],'laundry fits 1750 × 735 × 2750 mm')
      assert((measured[:combined_world_bounds_mm][:dimensions][0]-1726).abs<0.1,'laundry width 1726 mm')
      bridge.automation_execute(model,'set_camera',{'paths'=>row.values})
      bridge.automation_execute(model,'add_annotation',{'kind'=>'dimension','start_mm'=>[0,0,0],'end_mm'=>[1726,0,0],'offset_mm'=>[0,-750,0]})
      results << 'five laundry models + fit + camera + dimension'
      puts JSON.pretty_generate({status:'passed',checks:results,native_sketchup_version:Sketchup.version,changes:'aborted'})
      {status:'passed',checks:results}
    ensure
      model.abort_operation if started
      model.active_view.camera=camera if camera
      if model && initial
        raise 'Smoke cleanup changed original root entities' unless model.entities.to_a.map(&:persistent_id).sort==initial.sort
      end
    end
  end
end
LocalSketchUpMCP::Smoke.instance_variable_set(:@last_result,LocalSketchUpMCP::Smoke.run)
