# Run with the five editable project artifacts loaded, outside component editing.
# Exercises actual screen picking and mouse callbacks; restores part positions.
module LocalSketchUpMCP
  module DragSmoke
    extend self

    def assert(condition,message)
      raise 'Drag smoke: '+message unless condition
    end

    def part(root,key)
      Bridge.children(root).find { |entry| Bridge.container?(entry) && entry.get_attribute(Bridge::ATTRIBUTE,'part_key')==key }
    end

    def drag(root,key,front,goal,cancel=false)
      model=Sketchup.active_model;view=model.active_view
      moving=part(root,key)
      leaf=Bridge.children(moving).find { |entry| Bridge.container?(entry) && entry.name.include?(front) }
      face=Bridge.children(leaf).grep(Sketchup::Face).find { |entry| entry.normal.y < -0.9 }
      path=[root.persistent_id,moving.persistent_id,leaf.persistent_id]
      _,world=Bridge.resolve_path(model,path)
      view.refresh
      screen=view.screen_coords(face.bounds.center.transform(world))
      tool=Class.new(ArtifactInteractionTool) do
        def report_error(error);raise error;end
      end.new
      before=moving.transformation.to_a
      tool.onLButtonDown(0,screen.x,screen.y,view)
      state=tool.instance_variable_get(:@drag)
      assert(state && state[:entity].get_attribute(Bridge::ATTRIBUTE,'part_key')==key,'picked requested part')
      motion=state[:motion]
      # SketchUp pick rays quantize screen coordinates to pixels.
      pixel_length=view.pixels_to_model(2,state[:grab].transform(state[:reference]))
      tolerance=if motion['translation_mm']
        pixel_length/state[:length]
      else
        pixel_length/(state[:grab]-state[:center]).length/state[:angle].abs
      end
      [(goal+state[:initial_fraction])/2,goal].each do |fraction|
        delta=fraction-state[:initial_fraction]
        point=if motion['translation_mm']
          offset=Bridge.vector(motion['translation_mm']).map { |n| n*delta }
          state[:grab].transform(Geom::Transformation.translation(offset))
        else
          state[:grab].transform(Geom::Transformation.rotation([0,0,0],motion['rotation_axis'],motion['rotation_degrees']*delta*Math::PI/180))
        end
        screen=view.screen_coords(point.transform(state[:reference]))
        tool.onMouseMove(0,screen.x,screen.y,view)
      end
      if cancel
        tool.onCancel(0,view)
        assert(part(root,key).transformation.to_a==before,'cancel restores original transform')
      else
        tool.onLButtonUp(0,screen.x,screen.y,view)
        actual=Bridge.artifact_fraction(part(root,key))
        assert((actual-Bridge.clamp_artifact_fraction(goal)).abs<tolerance,"requested partial position #{key}: actual=#{actual}, goal=#{goal}")
      end
      assert(!Bridge.instance_variable_get(:@artifact_drag_active),'drag lock released')
      Bridge.artifact_fraction(part(root,key))
    ensure
      tool.cancel_drag if tool
    end

    def run
      model=Sketchup.active_model
      raise 'Exit component editing before drag smoke test' if model.active_path
      roots=model.entities.select { |entry| Bridge.container?(entry) }
      cabinet=roots.find { |entry| entry.get_attribute(Bridge::ATTRIBUTE,'key')=='artifact-detergent-cabinet' }
      dryer=roots.find { |entry| entry.get_attribute(Bridge::ATTRIBUTE,'key')=='artifact-dryer' }
      assert(cabinet && dryer,'load editable drawer and hatch artifacts first')
      camera=model.active_view.camera
      saved=[[cabinet,'Drawer1'],[dryer,'Door']].map do |root,key|
        entity=part(root,key)
        [root,key,entity.transformation.to_a,entity.get_attribute(Bridge::ATTRIBUTE,'open'),entity.get_attribute(Bridge::ATTRIBUTE,'motion_fraction')]
      end
      checks=[]
      Bridge.operation(model,'Drag smoke setup') do
        Bridge.set_artifact_fraction(part(cabinet,'Drawer1'),0)
        Bridge.set_artifact_fraction(part(dryer,'Door'),0)
      end
      Bridge.apply_camera(model,{'camera'=>{'eye_mm'=>[7300,-5000,2100],'target_mm'=>[5250,-200,990],'perspective'=>false,'height_mm'=>1700}})
      fraction=drag(cabinet,'Drawer1','фасад',137/400.0)
      checks << {drawer_mm:fraction*400}
      Sketchup.undo
      assert(Bridge.artifact_fraction(part(cabinet,'Drawer1')).abs<1e-8,'one Undo restores entire gesture')
      Sketchup.redo
      assert((Bridge.artifact_fraction(part(cabinet,'Drawer1'))-fraction).abs<1e-8,'Redo restores partial position')
      checks << 'one Undo + Redo'
      drag(cabinet,'Drawer1','фасад',275/400.0)
      checks << 'resume from partial position'
      drag(cabinet,'Drawer1','фасад',1.25)
      checks << 'drawer end stop 400 mm'
      drag(cabinet,'Drawer1','фасад',0.2,true)
      checks << 'Esc cancels unfinished drag'
      Bridge.apply_camera(model,{'camera'=>{'eye_mm'=>[4400,-4500,2100],'target_mm'=>[2400,0,430],'perspective'=>false,'height_mm'=>1600}})
      fraction=drag(dryer,'Door','стекло',0.37)
      checks << {door_degrees:fraction*100}
      drag(dryer,'Door','стекло',0.61)
      checks << 'resume hinge from partial angle'
      drag(dryer,'Door','стекло',0.12,true)
      checks << 'cancel hinge movement'
      {status:'passed',checks:checks}
    ensure
      if saved
        Bridge.operation(model,'Restore drag smoke positions') do
          saved.each do |root,key,transform,opened,fraction|
            entity=part(root,key)
            entity.transformation=Geom::Transformation.new(transform)
            entity.set_attribute(Bridge::ATTRIBUTE,'open',opened)
            entity.set_attribute(Bridge::ATTRIBUTE,'motion_fraction',fraction)
          end
        end
      end
      model.active_view.camera=camera if camera
    end
  end
end
LocalSketchUpMCP::DragSmoke.instance_variable_set(:@last_result,LocalSketchUpMCP::DragSmoke.run)
