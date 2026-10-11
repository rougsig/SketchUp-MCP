# Native artifact controls. Parts remain ordinary editable SketchUp components.
module LocalSketchUpMCP
  class ArtifactInteractionTool
    def activate
      Sketchup.status_text='Зажмите дверцу или ящик и потяните. Отпустите для фиксации. Esc — отмена.'
    end

    def picked_motion(view,x,y)
      bridge=LocalSketchUpMCP::Bridge
      picker=view.pick_helper;picker.do_pick(x,y)
      leaf=picker.picked_face || picker.picked_edge
      index=(0...picker.count).find { |i| leaf && picker.leaf_at(i)==leaf }
      return nil unless index
      prefix=(Sketchup.active_model.active_path || []).map(&:persistent_id)
      route=picker.path_at(index).select { |entity| bridge.container?(entity) }
      length=route.length.downto(1).find { |n| route[n-1].get_attribute(bridge::ATTRIBUTE,'motion') }
      return nil unless length
      path=prefix+route.first(length).map(&:persistent_id)
      context=Geom::Transformation.new
      (Sketchup.active_model.active_path || []).each { |entity| context=context*entity.transformation }
      transform=context*picker.transformation_at(index)
      point=if leaf.is_a?(Sketchup::Face)
        points=leaf.vertices.first(3).map { |vertex| vertex.position.transform(transform) }
        normal=(points[1]-points[0]).cross(points[2]-points[0])
        Geom.intersect_line_plane(view.pickray(x,y),[points[0],normal])
      end
      point ||= leaf.bounds.center.transform(transform)
      {path:path,point:point}
    end

    def motion_path(view,x,y)
      picked_motion(view,x,y)&.fetch(:path)
    end

    def report_error(error)
      UI.messagebox(error.message)
    end

    def local_hit(view,x,y)
      ray=view.pickray(x,y)
      ray=[ray[0].transform(@drag[:inverse]),ray[1].transform(@drag[:inverse])]
      Geom.intersect_line_plane(ray,@drag[:plane])
    end

    def onLButtonDown(_flags,x,y,view)
      return if @drag
      picked=picked_motion(view,x,y);return unless picked
      model=Sketchup.active_model;bridge=LocalSketchUpMCP::Bridge
      model.start_operation('MCP: Потянуть дверцу / ящик',true)
      @operation_model=model
      bridge.instance_variable_set(:@artifact_drag_active,true)
      bridge.instance_variable_set(:@path_remap,{})
      entity,world,_,path=bridge.writable_path(model,picked[:path])
      motion=bridge.artifact_motion(entity)
      closed=Geom::Transformation.new(entity.get_attribute(bridge::ATTRIBUTE,'closed_transform'))
      reference=world*entity.transformation.inverse*closed
      inverse=reference.inverse
      grab=picked[:point].transform(inverse)
      fraction=bridge.artifact_fraction(entity)
      @drag={entity:entity,path:path,motion:motion,inverse:inverse,reference:reference,
        fraction:fraction,initial_fraction:fraction,last_mouse:[x,y],grab:grab}
      if motion['translation_mm']
        stroke=Geom::Vector3d.new(bridge.vector(motion['translation_mm']))
        @drag[:length]=stroke.length;axis=stroke.clone;axis.normalize!
        direction=view.camera.direction.transform(inverse)
        projection=direction.dot(axis)
        normal=Geom::Vector3d.new(direction.to_a.zip(axis.to_a).map { |a,b| a-b*projection })
        @drag[:axis]=axis
        if normal.length>1e-6
          normal.normalize!;@drag[:plane]=[grab,normal]
          @drag[:start_hit]=local_hit(view,x,y)
        else
          @drag[:fallback]=true
          @drag[:pixels_per_fraction]=stroke.transform(reference).length/view.pixels_to_model(1,picked[:point])
        end
      else
        axis=Geom::Vector3d.new(motion['rotation_axis']);axis.normalize!
        height=Geom::Vector3d.new(grab.to_a).dot(axis)
        center=Geom::Point3d.new(axis.to_a.map { |n| n*height })
        @drag[:axis]=axis;@drag[:plane]=[center,axis];@drag[:center]=center
        hit=local_hit(view,x,y)
        @drag[:radial]=hit-center if hit && (hit-center).length>1e-6
        @drag[:angle]=motion['rotation_degrees']*Math::PI/180
      end
      show_position
    rescue StandardError => error
      cancel_drag
      report_error(error)
    end

    def update_drag(x,y,view)
      return unless @drag
      fraction=@drag[:fraction]
      if @drag[:motion]['translation_mm']
        if @drag[:fallback]
          fraction+=(y-@drag[:last_mouse][1])/@drag[:pixels_per_fraction]
        else
          hit=local_hit(view,x,y)
          return unless hit && @drag[:start_hit]
          fraction=@drag[:initial_fraction]+(hit-@drag[:start_hit]).dot(@drag[:axis])/@drag[:length]
        end
      else
        hit=local_hit(view,x,y)
        radial=hit-@drag[:center] if hit
        if radial && radial.length>1e-6 && @drag[:radial]
          previous=@drag[:radial]
          angle=Math.atan2(@drag[:axis].dot(previous.cross(radial)),previous.dot(radial))
          fraction+=angle/@drag[:angle]
          @drag[:radial]=radial
        else
          # Edge-on hinge planes cannot be intersected reliably. Use the
          # projected rotational tangent, or a vertical gesture at singularity.
          point=@drag[:grab]
          axis=@drag[:axis]
          rotation=Geom::Transformation.rotation([0,0,0],axis,@drag[:angle]*(fraction-@drag[:initial_fraction]))
          current=point.transform(rotation)
          next_point=current.transform(Geom::Transformation.rotation([0,0,0],axis,0.01))
          a=view.screen_coords(current.transform(@drag[:reference]))
          b=view.screen_coords(next_point.transform(@drag[:reference]))
          tangent=[(b.x-a.x)/0.01,(b.y-a.y)/0.01]
          mouse=[x-@drag[:last_mouse][0],y-@drag[:last_mouse][1]]
          squared=tangent.sum { |n| n*n }
          fraction+=if squared>1
            mouse.zip(tangent).sum { |u,v| u*v }/squared/@drag[:angle]
          else
            mouse[1]/180.0
          end
          @drag[:radial]=radial if radial && radial.length>1e-6
        end
      end
      fraction=LocalSketchUpMCP::Bridge.clamp_artifact_fraction(fraction)
      LocalSketchUpMCP::Bridge.set_artifact_fraction(@drag[:entity],fraction)
      @drag[:fraction]=fraction;@drag[:last_mouse]=[x,y]
      show_position
      view.invalidate
    end

    def show_position
      motion=@drag[:motion]
      value=if motion['translation_mm']
        length=Math.sqrt(motion['translation_mm'].sum { |n| n*n })
        format('%.1f мм',length*@drag[:fraction])
      else
        format('%.1f°',motion['rotation_degrees'].abs*@drag[:fraction])
      end
      Sketchup.status_text=@drag[:entity].name+': '+value+' — отпустите для фиксации, Esc — отмена'
    end

    def onMouseMove(_flags,x,y,view)
      if @drag
        update_drag(x,y,view)
      else
        path=motion_path(view,x,y)
        if path
          entity,=LocalSketchUpMCP::Bridge.resolve_path(Sketchup.active_model,path)
          view.tooltip='Потянуть: '+entity.name
        else
          view.tooltip='Зажмите дверцу или ящик и потяните'
        end
      end
    rescue StandardError => error
      cancel_drag
      report_error(error)
    end

    def onLButtonUp(_flags,x,y,view)
      return unless @drag
      update_drag(x,y,view)
      finish_drag
      activate
    rescue StandardError => error
      cancel_drag
      report_error(error)
    end

    def finish_drag
      return unless @operation_model
      if @drag && (@drag[:fraction]-@drag[:initial_fraction]).abs>1e-8
        @operation_model.commit_operation
      else
        @operation_model.abort_operation
      end
    ensure
      clear_drag
    end

    def cancel_drag
      @operation_model.abort_operation if @operation_model
    ensure
      clear_drag
    end

    def clear_drag
      @operation_model=nil;@drag=nil
      LocalSketchUpMCP::Bridge.instance_variable_set(:@artifact_drag_active,false)
      LocalSketchUpMCP::Bridge.instance_variable_set(:@path_remap,nil)
    end

    def deactivate(_view);cancel_drag;end
    def suspend(_view);finish_drag;end
    def resume(_view);activate;end
    def onCancel(_reason,_view)
      cancel_drag
      Sketchup.active_model.select_tool(nil)
    end
  end

  module Bridge
    extend self

    def clamp_artifact_fraction(value)
      raise 'Invalid artifact position' unless value.is_a?(Numeric) && value.finite?
      [[value,0.0].max,1.0].min
    end

    def artifact_motion(entity)
      motion=JSON.parse(entity.get_attribute(ATTRIBUTE,'motion'))
      raise 'Drag supports one translation or one rotation' unless motion.key?('translation_mm') != motion.key?('rotation_degrees')
      if motion['translation_mm']
        vector(motion['translation_mm'])
        raise 'Zero drawer travel' unless motion['translation_mm'].sum { |n| n*n }>0
      else
        motion['rotation_axis'] ||= [0,0,1]
        vector(motion['rotation_axis'])
        angle=motion['rotation_degrees']
        raise 'Invalid hinge rotation' unless angle.is_a?(Numeric) && angle.finite? && angle.abs>1e-8 && motion['rotation_axis'].sum { |n| n*n }>0
      end
      motion
    end

    def artifact_fraction(entity)
      motion=artifact_motion(entity)
      closed=Geom::Transformation.new(entity.get_attribute(ATTRIBUTE,'closed_transform'))
      relative=closed.inverse*entity.transformation
      fraction=if motion['translation_mm']
        travel=vector(motion['translation_mm'])
        relative.origin.to_a.zip(travel).sum { |a,b| a*b }/travel.sum { |n| n*n }
      else
        axis=motion['rotation_axis'];length=Math.sqrt(axis.sum { |n| n*n });axis=axis.map { |n| n/length }
        m=relative.to_a
        sine=axis.zip([m[6]-m[9],m[8]-m[2],m[1]-m[4]]).sum { |a,b| a*b }/2
        cosine=(m[0]+m[5]+m[10]-1)/2
        Math.atan2(sine,cosine)/(motion['rotation_degrees']*Math::PI/180)
      end
      clamp_artifact_fraction(fraction)
    end

    def set_artifact_fraction(entity,fraction)
      fraction=clamp_artifact_fraction(fraction)
      motion=artifact_motion(entity)
      closed=Geom::Transformation.new(entity.get_attribute(ATTRIBUTE,'closed_transform'))
      delta=if motion['translation_mm']
        Geom::Transformation.translation(vector(motion['translation_mm']).map { |n| n*fraction })
      else
        Geom::Transformation.rotation([0,0,0],motion['rotation_axis'],motion['rotation_degrees']*fraction*Math::PI/180)
      end
      entity.transformation=closed*delta
      entity.set_attribute(ATTRIBUTE,'motion_fraction',fraction)
      entity.set_attribute(ATTRIBUTE,'open',fraction>1e-8)
      fraction
    end

    def artifact_control_paths(model,kind)
      prefix=(model.active_path || []).map(&:persistent_id)
      selected=model.selection.select { |entity| container?(entity) }
      roots=selected.map { |entity| prefix+[entity.persistent_id] }
      roots=[prefix] if roots.empty? && !prefix.empty?
      paths=[]
      visit=lambda do |path,depth|
        raise 'Component hierarchy too deep' if depth>32
        entity,=resolve_path(model,path)
        matches=case kind
        when 'motion' then entity.get_attribute(ATTRIBUTE,'motion')
        when 'zones' then zone?(entity)
        when 'cutaway' then entity.get_attribute(ATTRIBUTE,'part_key')=='RightSide'
        else raise 'Unknown artifact control'
        end
        if matches
          paths << path
        else
          children(entity).select { |child| container?(child) }.each do |child|
            visit.call(path+[child.persistent_id],depth+1)
          end
        end
      end
      roots.each { |path| visit.call(path,0) }
      # A selected handle or panel may be inside a moving door/drawer.
      if paths.empty? && kind=='motion'
        prefix.length.downto(1) do |length|
          path=prefix.first(length);entity,=resolve_path(model,path)
          if entity.get_attribute(ATTRIBUTE,'motion');paths << path;break;end
        end
      end
      paths.uniq
    end

    def apply_artifact_control(model,paths,kind)
      raise 'Finish dragging the artifact first' if @artifact_drag_active
      raise 'Select an artifact or a moving part first' if paths.empty?
      model.active_path=nil if model.active_path
      @path_remap={}
      operation(model,'Artifact '+kind) do
        entities=paths.map { |path| resolve_path(model,path).first }
        if kind=='motion'
          opened=!entities.all? { |entity| artifact_fraction(entity)>=1-1e-8 }
        else
          hidden=!entities.all?(&:hidden?)
        end
        paths.each do |path|
          entity,=writable_path(model,path)
          if kind=='motion'
            set_artifact_fraction(entity,opened ? 1.0 : 0.0)
          else
            entity.hidden=hidden
          end
        end
        model.active_view.refresh
        {count:paths.length,kind:kind,open:opened,hidden:hidden}
      end
    ensure
      @path_remap=nil
    end

    def artifact_control(model,kind)
      apply_artifact_control(model,artifact_control_paths(model,kind),kind)
    end

    def artifact_control_ui(kind)
      artifact_control(Sketchup.active_model,kind)
    rescue StandardError => error
      UI.messagebox(error.message)
    end

    def start_artifact_interaction
      model=Sketchup.active_model
      model.active_path=nil if model.active_path
      model.select_tool(LocalSketchUpMCP::ArtifactInteractionTool.new)
    end

    if defined?(UI) && UI.respond_to?(:add_context_menu_handler) && !@artifact_controls_registered
      @artifact_controls_registered=true
      labels={'motion'=>'Открыть / закрыть','zones'=>'Показать / скрыть зоны','cutaway'=>'Снять / вернуть боковину'}
      UI.add_context_menu_handler do |menu|
        model=Sketchup.active_model
        available=labels.keys.select { |kind| !artifact_control_paths(model,kind).empty? }
        unless available.empty?
          submenu=menu.add_submenu('Артефакт MCP')
          available.each { |kind| submenu.add_item(labels[kind]) { artifact_control_ui(kind) } }
        end
      rescue StandardError => error
        warn "Artifact controls: #{error.message}"
      end
      submenu=UI.menu('Extensions').add_submenu('Артефакты MCP')
      labels.each { |kind,label| submenu.add_item(label) { artifact_control_ui(kind) } }
    end

    if defined?(UI::Command) && defined?(UI::Toolbar) && !@artifact_interaction_tool_registered
      @artifact_interaction_tool_registered=true
      command=UI::Command.new('Дверцы и ящики — перетаскивание') { start_artifact_interaction }
      command.tooltip='Дверцы и ящики — потянуть мышью'
      command.status_bar_text='Зажмите дверцу или ящик и потяните до нужного положения. Esc — отмена.'
      @artifact_command=command
      if Sketchup.platform==:platform_win
        icon=File.join(__dir__,'icons','interact.svg')
        command.small_icon=icon;command.large_icon=icon
      end
      UI.menu('Extensions').add_item(command)
      @artifact_toolbar=UI::Toolbar.new('Артефакты MCP')
      @artifact_toolbar.add_item(command)
      @artifact_toolbar.restore
    end
  end
end
