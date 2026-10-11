# Optional end-to-end example, called through run_ruby_script after the MCP upgrade.
# Creates/updates our five native models outside current model bounds; preserves existing placement on updates.
require 'json'
bridge=LocalSketchUpMCP::Bridge
model=Sketchup.active_model
raise 'Exit component editing before assembling' if model.active_path
workspace=File.expand_path('..',__dir__)
key_prefix='laundry-demo-'
existing=model.entities.find { |item| bridge.container?(item) && item.get_attribute(bridge::ATTRIBUTE,'key')==key_prefix+'sink' }
origin=existing ? bridge.mm(existing.transformation.origin) : (model.entities.length.zero? ? [0,0,0] : [model.bounds.max.x.to_mm+500,0,model.bounds.min.z.to_mm])
modules=[['sink','laundry-sink',[0,0,0]],['detergent','detergent-cabinet',[750,0,0]],
         ['tower','laundry-tower',[1088,0,0]],['washer','washing-machine',[1088,0,150]],['dryer','dryer',[1088,0,1038]]]
results={}
# Building all five modules shares one Undo operation; native builders do not open nested transactions here.
begin
model.start_operation('MCP — собрать постирочную 1726 мм',true)
started=true
modules.each do |key,folder,offset|
  location=origin.zip(offset).map { |a,b| a+b }
  result=bridge.automation_execute(model,'build_assembly',{'key'=>key_prefix+key,'replace'=>true,
    'json_path'=>File.join(workspace,'artifacts',folder,'model-primitives.json'),'origin_mm'=>location})
  results[key]=[result[:entity][:id]]
end
measurement=bridge.automation_execute(model,'measure_objects',{'paths'=>%w[sink detergent tower].map { |name| results[name] },'available_dimensions_mm'=>[1750,735,2750]})
raise 'Laundry row does not fit expected envelope' unless measurement[:fits]
raise 'Unexpected laundry row width' unless (measurement[:combined_world_bounds_mm][:dimensions][0]-1726).abs<0.1
bridge.automation_execute(model,'set_camera',{'paths'=>results.values})
scene=bridge.automation_execute(model,'create_scene',{'name'=>'Постирочная — ряд 1726 мм'})
bridge.automation_execute(model,'add_annotation',{'kind'=>'dimension','start_mm'=>origin,'end_mm'=>[origin[0]+1726,origin[1],origin[2]],'offset_mm'=>[0,-750,0],'tag'=>'Постирочная — Размеры'})
model.commit_operation;started=false
puts JSON.pretty_generate({modules:results,measurement:measurement,scene:scene})
rescue StandardError
  model.abort_operation if started
  raise
end
