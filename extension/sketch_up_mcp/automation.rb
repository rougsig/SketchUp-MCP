# Native automation. All public lengths are millimeters; instance paths disambiguate shared definitions.
require 'digest'
require 'stringio'
require_relative 'interactions'
module LocalSketchUpMCP
  module Bridge
    AUTOMATION_READ = %w[get_capabilities find_objects inspect_object measure_objects check_collisions check_motion get_operation_status list_scenes list_tags].freeze
    AUTOMATION_WRITE = %w[build_assembly create_sphere create_cone create_furniture update_furniture import_component transform_object copy_object set_object_properties delete_objects create_material paint_object set_tags set_camera create_scene activate_scene create_scene_variants add_annotation save_model export_component export_scene eval_ruby run_ruby_script batch_edit].freeze
    ATTRIBUTE = 'LocalSketchUpMCP'.freeze

    def file_roots
      settings = File.join(ROOT,'automation-folders.json')
      saved = File.exist?(settings) ? JSON.parse(File.read(settings)) : []
      project = File.expand_path('../..',__dir__)
      defaults = File.exist?(File.join(project,'server/server.py')) ? [project] : []
      (saved + defaults + ENV.fetch('SKETCHUP_MCP_ALLOWED_ROOTS','').split(File::PATH_SEPARATOR)).reject(&:empty?).map { |p| File.realpath(p) }.uniq
    end

    def automation_file(path, writing=false)
      raise 'Expected an absolute file path' unless path.is_a?(String) && File.absolute_path(path)==path
      canonical = writing && !File.exist?(path) ? File.join(File.realpath(File.dirname(path)),File.basename(path)) : File.realpath(path)
      raise 'File is outside configured automation folders. Use Extensions > Local SketchUp MCP > Add automation folder.' unless file_roots.any? { |root| canonical.start_with?(root+File::SEPARATOR) }
      canonical
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.each_with_object({}) { |key,out| out[key]=canonical(value[key]) }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def journal_path(id)
      raise 'operation_id must contain 1..512 characters' unless id.is_a?(String) && id.length.between?(1,512)
      directory=File.join(ROOT,'operations');FileUtils.mkdir_p(directory)
      File.join(directory,Digest::SHA256.hexdigest(id)+'.json')
    end

    def operation_status(id)
      path=journal_path(id)
      File.exist?(path) ? JSON.parse(File.read(path)) : { 'operation_id'=>id,'status'=>'not_received' }
    end

    def automation_dispatch(model, tool, args)
      return automation_execute(model,tool,args) if AUTOMATION_READ.include?(tool)
      raise 'Finish dragging the artifact before automation writes' if @artifact_drag_active
      id=args.fetch('operation_id');path=journal_path(id)
      fingerprint=Digest::SHA256.hexdigest(JSON.generate(canonical({'tool'=>tool,'arguments'=>args})))
      if File.exist?(path)
        record=JSON.parse(File.read(path))
        raise 'operation_id already used with different arguments' unless record['fingerprint']==fingerprint
        raise 'Operation belongs to another SketchUp session/model; inspect its status before editing' unless record['session']==@session && record['model_id']==model.object_id.to_s
        return record.fetch('result').merge('replayed'=>true) if record['status']=='completed'
        raise(record['error'] || 'Operation is running or outcome is unknown; inspect before retrying')
      end
      record={'operation_id'=>id,'tool'=>tool,'fingerprint'=>fingerprint,'session'=>@session,'model_id'=>model.object_id.to_s,'status'=>'running','started_at'=>Time.now.to_f}
      atomic_json(path,record)
      begin
        @path_remap = {}
        result = if %w[run_ruby_script save_model export_component export_scene].include?(tool) || (tool=='eval_ruby' && args.fetch('transaction','managed')=='script_owned')
          automation_execute(model,tool,args)
        else
          operation(model,tool) { automation_execute(model,tool,args) }
        end
        result=result.merge(operation_id:id)
        record.merge!('status'=>'completed','result'=>result,'finished_at'=>Time.now.to_f)
        atomic_json(path,record)
        result
      rescue StandardError => error
        record.merge!('status'=>%w[run_ruby_script eval_ruby export_scene].include?(tool) ? 'failed_possible_partial_changes' : 'failed','error'=>"#{error.class}: #{error.message}",'finished_at'=>Time.now.to_f)
        atomic_json(path,record)
        raise
      ensure
        @path_remap = nil
      end
    end

    def container?(entity)
      entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
    end

    def resolve_path(model, ids)
      raise 'Expected a nonempty instance path' unless ids.is_a?(Array) && !ids.empty? && ids.length<=32
      entities=model.entities;chain=[];transform=Geom::Transformation.new
      ids.each_with_index do |id,index|
        entity=entities.find { |entry| entry.persistent_id==id }
        raise "Invalid instance path at #{id}" unless entity && container?(entity)
        chain << entity
        transform=transform*entity.transformation
        entities=children(entity) if index<ids.length-1
      end
      [chain.last,transform,chain]
    end

    # Making ancestors unique can change descendant persistent IDs. Return the new path to callers.
    def writable_path(model, ids)
      raise 'Exit group/component editing for automation writes' if model.active_path
      current=remapped_path(ids)
      current.length.times do |index|
        entity,_,chain=resolve_path(model,current[0..index])
        raise 'Object or ancestor is locked' if chain.any?(&:locked?)
        next unless index<current.length-1
        definition=children(entity).parent
        next unless definition.instances.length>1
        before=children(entity).to_a
        indices=[];remaining=current[(index+1)..-1];list=before
        remaining.each_with_index do |id,offset|
          pos=list.index { |entry| entry.persistent_id==id }
          raise 'Descendant not found' unless pos
          indices << pos;list=children(list[pos]).to_a if offset<remaining.length-1
        end
        original_prefix=current[0..index]
        entity.make_unique
        map_copied_paths(before,children(entity).to_a,original_prefix,original_prefix)
        list=children(entity).to_a
        indices.each_with_index do |pos,offset|
          child=list[pos];current[index+1+offset]=child.persistent_id
          list=children(child).to_a if offset<indices.length-1
        end
      end
      entity,world,chain=resolve_path(model,current)
      [entity,world,chain,current]
    end

    def remapped_path(ids)
      return ids.dup unless @path_remap
      current=ids.dup
      32.times do
        entry=@path_remap.keys.select { |prefix| current[0,prefix.length]==prefix }.max_by(&:length)
        break unless entry
        replacement=@path_remap[entry]+current[entry.length..-1]
        break if replacement==current
        current=replacement
      end
      current
    end

    def map_copied_paths(before,after,old_prefix,new_prefix,depth=0)
      return unless @path_remap
      raise 'Component hierarchy too deep' if depth>32
      before.zip(after).each do |a,b|
        next unless a && b && container?(a) && container?(b)
        old_path=old_prefix+[a.persistent_id];new_path=new_prefix+[b.persistent_id]
        @path_remap[old_path]=new_path unless old_path==new_path
        map_copied_paths(children(a).to_a,children(b).to_a,old_path,new_path,depth+1)
      end
    end

    def bounds_hash(bounds)
      return nil if bounds.empty?
      {min:mm(bounds.min),max:mm(bounds.max),dimensions:mm([bounds.width,bounds.height,bounds.depth])}
    end

    def transformed_bounds(bounds, transform)
      result=Geom::BoundingBox.new
      8.times { |i| result.add(bounds.corner(i).transform(transform)) } unless bounds.empty?
      result
    end

    def inspect_path(model, path)
      entity,world,chain=resolve_path(model,path)
      own=entity.is_a?(Sketchup::Group) ? entity.entities.parent.bounds : entity.definition.bounds
      matrix_mm=world.to_a
      (12..14).each { |i| matrix_mm[i]*=25.4 }
      describe(entity).merge(path:path,world_bounds_mm:bounds_hash(transformed_bounds(own,world)),
        physical_world_bounds_mm:bounds_hash(physical_bounds(model,path)),
        local_bounds_mm:bounds_hash(own),world_transform_mm:matrix_mm,
        origin_world_mm:mm(world.origin),axes_world:[world.xaxis.to_a,world.yaxis.to_a,world.zaxis.to_a],
        key:entity.get_attribute(ATTRIBUTE,'key'),role:entity.get_attribute(ATTRIBUTE,'role'),
        parameters:entity.get_attribute(ATTRIBUTE,'parameters'),
        visible:model.drawing_element_visible?(Sketchup::InstancePath.new(chain)),
        manifold:entity.respond_to?(:manifold?) ? entity.manifold? : nil,
        children:children(entity).select { |entry| container?(entry) }.map { |child| {id:child.persistent_id,name:child.name,path:path+[child.persistent_id]} })
    end

    def zone?(entity)
      role=entity.get_attribute(ATTRIBUTE,'role').to_s
      %w[Zones Access Clearances Service].include?(role) || entity.get_attribute(ATTRIBUTE,'primitive')=='rectangle'
    end

    def physical_bounds(model,path,include_zones=false)
      entity,world,=resolve_path(model,path);box=Geom::BoundingBox.new
      visit=lambda do |node,transform,depth|
        raise 'Geometry nesting exceeds 32 levels' if depth>32
        next if !include_zones && zone?(node)
        children(node).each do |child|
          if container?(child)
            visit.call(child,transform*child.transformation,depth+1)
          elsif child.is_a?(Sketchup::Face)
            child.vertices.each { |vertex| box.add(vertex.position.transform(transform)) }
          end
        end
      end
      visit.call(entity,world,0);box
    end

    def walk_instances(entities, path=[], transform=Geom::Transformation.new, depth=0, &block)
      raise 'Instance hierarchy exceeds 32 levels' if depth>32
      entities.each do |entity|
        next unless container?(entity)
        branch=path+[entity.persistent_id];world=transform*entity.transformation
        yield(entity,branch,world)
        walk_instances(children(entity),branch,world,depth+1,&block)
      end
    end

    def primitive_box?(entity)
      return false unless entity.get_attribute(ATTRIBUTE,'primitive')=='box'
      faces=children(entity).grep(Sketchup::Face);edges=children(entity).grep(Sketchup::Edge)
      return false unless faces.length==6 && edges.length==12
      vertices=edges.flat_map(&:vertices).uniq
      return false unless vertices.length==8
      bounds=entity.is_a?(Sketchup::Group) ? entity.entities.parent.bounds : entity.definition.bounds
      vertices.all? { |vertex| 3.times.all? { |axis| [bounds.min.to_a[axis],bounds.max.to_a[axis]].any? { |n| (vertex.position.to_a[axis]-n).abs<1e-7 } } }
    end

    def leaves(model, path, extra=Geom::Transformation.new)
      root,world,chain=resolve_path(model,path);result=[]
      visit=lambda do |entity,ids,transform,ancestors|
        next if zone?(entity)
        next unless model.drawing_element_visible?(Sketchup::InstancePath.new(ancestors))
        children_instances=children(entity).select { |child| container?(child) }
        faces=children(entity).grep(Sketchup::Face)
        unless faces.empty?
          points=faces.flat_map { |face| face.vertices.map { |vertex| vertex.position.transform(transform) } }
          box=Geom::BoundingBox.new;points.each { |p| box.add(p) }
          local=entity.is_a?(Sketchup::Group) ? entity.entities.parent.bounds : entity.definition.bounds
          result << {path:ids,bounds:box,box:children_instances.empty? && primitive_box?(entity),corners:8.times.map { |i| local.corner(i).transform(transform) }}
        end
        children_instances.each { |child| visit.call(child,ids+[child.persistent_id],transform*child.transformation,ancestors+[child]) }
      end
      visit.call(root,path,extra*world,chain)
      raise 'Too many geometry leaves (limit 2000)' if result.length>2000
      result
    end

    def gap_info(a,b)
      aa=[a.min.to_a,a.max.to_a];bb=[b.min.to_a,b.max.to_a]
      signed=3.times.map { |i| [bb[0][i]-aa[1][i],aa[0][i]-bb[1][i]].max*25.4 }
      {axis_gaps_mm:signed,distance_mm:Math.sqrt(signed.sum { |gap| [gap,0].max**2 }),aabb_overlap:signed.all? { |gap| gap<0 }}
    end

    def box_intersects?(a,b,tolerance)
      pa=a[:corners];pb=b[:corners]
      # BoundingBox corners: 0=min, 1=X, 2=Y, 4=Z; affine transforms can include skew.
      ea=[1,2,4].map { |i| pa[i]-pa[0] };eb=[1,2,4].map { |i| pb[i]-pb[0] }
      axes=[ea[0].cross(ea[1]),ea[1].cross(ea[2]),ea[2].cross(ea[0]),eb[0].cross(eb[1]),eb[1].cross(eb[2]),eb[2].cross(eb[0])]+ea.product(eb).map { |u,v| u.cross(v) }
      # SketchUp Length comparisons use model tolerance, which can retain zero axes.
      axes.reject { |axis| axis.length.to_f<1e-10 }.all? do |axis|
        axis.normalize!;va=pa.map { |p| p.to_a.zip(axis.to_a).sum { |x,y| x*y } };vb=pb.map { |p| p.to_a.zip(axis.to_a).sum { |x,y| x*y } }
        [va.max,vb.max].min-[va.min,vb.min].max > tolerance/25.4
      end
    end

    def collisions_between(a,b,tolerance,maximum)
      hits=[];tested=0
      a.each do |left|
        b.each do |right|
          next if left[:path]==right[:path]
          tested+=1;raise 'Collision pair limit exceeded; inspect smaller subassemblies' if tested>maximum
          gaps=gap_info(left[:bounds],right[:bounds])
          next unless gaps[:axis_gaps_mm].all? { |gap| gap < -tolerance }
          exact=left[:box] && right[:box]
          next if exact && !box_intersects?(left,right,tolerance)
          hits << {a:left[:path],b:right[:path],status:exact ? 'confirmed_box_intersection' : 'possible_bounds_overlap',axis_gaps_mm:gaps[:axis_gaps_mm]}
        end
      end
      {pairs_tested:tested,hits:hits,clear_at_checked_resolution:hits.empty?,method:'SAT for verified native boxes; other leaf AABBs are inconclusive'}
    end

    def material_from(model,spec)
      name=spec['name'] || spec.fetch('key');rgb=spec.fetch('rgb')
      raise 'RGB must be three numbers 0..255' unless rgb.length==3 && rgb.all? { |n| n.is_a?(Numeric) && n.finite? && n.between?(0,255) }
      opacity=spec.fetch('opacity',1);raise 'Opacity must be 0..1' unless opacity.is_a?(Numeric) && opacity.finite? && opacity.between?(0,1)
      material=model.materials[name] || model.materials.add(name)
      material.color=Sketchup::Color.new(*rgb);material.alpha=opacity;material
    end

    def native_part(entities,shape,materials)
      group=entities.add_group;group.name=shape.fetch('name',shape.fetch('type'))
      type=shape.fetch('type');group.set_attribute(ATTRIBUTE,'primitive',type)
      case type
      when 'sphere','cone'
        vertices,faces=round_primitive_mesh(shape)
        faces.each do |indices|
          face=group.entities.add_face(indices.map { |i| vector(vertices[i]) })
          raise "Could not create #{type} face" unless face
          # SketchUp can choose the opposite winding when closing a solid.
          a,b,c=indices.first(3).map { |i| Geom::Point3d.new(vector(vertices[i])) }
          expected=(b-a).cross(c-a)
          face.reverse! if face.normal.dot(expected)<0
        end
        group.entities.grep(Sketchup::Edge).each do |edge|
          next unless edge.faces.length==2
          next if type=='cone' && edge.faces.any? { |face| face.vertices.length>3 }
          edge.soft=true;edge.smooth=true
        end
      when 'box','plate_hole'
        x,y,z=vector(shape.fetch('origin'));w,d,h=vector(shape.fetch('size'),true)
        face=group.entities.add_face([x,y,z],[x+w,y,z],[x+w,y+d,z],[x,y+d,z])
        raise 'Could not create panel' unless face
        face.reverse! if face.normal.z<0
        cut_hole(group,shape.fetch('hole_center'),[0,0,1],shape.fetch('radius')) if type=='plate_hole'
        face=group.entities.grep(Sketchup::Face).max_by(&:area)
        face.pushpull(h)
      when 'rectangle'
        vertices=shape.fetch('vertices');raise 'Rectangle requires exactly 4 vertices' unless vertices.length==4
        raise 'Could not create clearance plane' unless group.entities.add_face(vertices.map { |p| vector(p) })
      when 'circle','cylinder','ring','tube'
        center=shape.fetch('center')
        axis=shape.fetch('axis',type=='cylinder' || type=='ring' ? 'Y' : 'Z')
        normal=shape.fetch('normal',{'X'=>[1,0,0],'Y'=>[0,1,0],'Z'=>[0,0,1]}.fetch(axis))
        radius=shape.fetch('radius',shape['outer']);positive_number(radius,'radius')
        raise 'Zero circle normal' if normal.sum { |n| n*n }<=0
        edges=group.entities.add_circle(vector(center),normal,radius/25.4)
        face=group.entities.add_face(edges);raise 'Could not create circle face' unless face
        face.reverse! if face.normal.dot(Geom::Vector3d.new(normal))<0
        inner=shape.fetch('inner',0)
        if inner>0
          raise 'Inner radius must be smaller than outer' unless inner<radius
          cut_hole(group,center,normal,inner);face=group.entities.grep(Sketchup::Face).max_by(&:area)
        end
        length=shape.fetch('length',shape.fetch('depth',0))
        positive_number(length,'length') unless type=='circle'
        face.pushpull(length/25.4) if length>0
      else raise "Unknown primitive #{type}"
      end
      if shape['material']
        material=materials.fetch(shape['material'])
        paint_faces(group,material,true)
      end
      group
    end

    # Closed outward-wound meshes, in public millimeters. Pole vertices are unique.
    def round_primitive_mesh(shape)
      type=shape.fetch('type');raise 'Expected sphere or cone' unless %w[sphere cone].include?(type)
      center=shape.fetch('center',[0,0,0]);vector(center)
      radius=shape.fetch('radius');positive_number(radius,'radius')
      segments=shape.fetch('segments',32)
      raise 'Unsupported segments' unless [12,16,24,32,48,64,96,128].include?(segments)
      if type=='sphere'
        rings=segments/2;vertices=[[0,0,-radius]];faces=[]
        (1...rings).each do |j|
          latitude=-Math::PI/2+Math::PI*j/rings
          segments.times do |i|
            angle=2*Math::PI*i/segments
            vertices << [radius*Math.cos(latitude)*Math.cos(angle),radius*Math.cos(latitude)*Math.sin(angle),radius*Math.sin(latitude)]
          end
        end
        north=vertices.length;vertices << [0,0,radius]
        segments.times do |i|
          next_i=(i+1)%segments
          faces << [0,1+next_i,1+i]
          (0...rings-2).each do |j|
            a=1+j*segments+i;b=1+j*segments+next_i;c=a+segments;d=b+segments
            faces << [a,b,d];faces << [a,d,c]
          end
          faces << [1+(rings-2)*segments+i,1+(rings-2)*segments+next_i,north]
        end
      else
        height=shape.fetch('length',shape['depth']);positive_number(height,'height')
        axis=shape.fetch('axis','Z');raise 'Invalid cone axis' unless %w[X Y Z].include?(axis)
        vertices=segments.times.map { |i| a=2*Math::PI*i/segments;[radius*Math.cos(a),radius*Math.sin(a),0] }
        vertices << [0,0,height]
        faces=[(0...segments).to_a.reverse]+segments.times.map { |i| [i,(i+1)%segments,segments] }
        vertices=vertices.map { |x,y,z| axis=='X' ? [z,x,y] : axis=='Y' ? [y,z,x] : [x,y,z] }
      end
      [vertices.map { |p| p.zip(center).map { |a,b| a+b } },faces]
    end

    def positive_number(n,name)
      raise "#{name} must be positive and finite" unless n.is_a?(Numeric) && n.finite? && n>0
      n
    end

    def cut_hole(group,center,normal,radius)
      positive_number(radius,'hole radius')
      p=Geom::Point3d.new(vector(center));face=group.entities.grep(Sketchup::Face).max_by(&:area)
      raise 'Hole center must be inside the planar face' unless face.classify_point(p)==Sketchup::Face::PointInside
      edges=group.entities.add_circle(p,normal,radius/25.4)
      hole=edges.first.faces.find { |f| f.area<=Math::PI*(radius/25.4)**2*1.01 }
      raise 'Circular hole could not be created' unless hole
      hole.erase!
    end

    def paint_faces(entity,material,recursive)
      entity.material=material
      return unless recursive
      entity.make_unique if children(entity).parent.instances.length>1
      children(entity).each do |child|
        if child.is_a?(Sketchup::Face)
          child.material=material;child.back_material=material
        elsif container?(child)
          paint_faces(child,material,true)
        end
      end
    end

    # COLLADA supplies one material per surface. SketchUp's DAE importer leaves
    # reverse sides unpainted, including single clearance/reference planes.
    def paint_imported_back_faces(definition,seen={})
      return if seen[definition.object_id]
      seen[definition.object_id]=true
      definition.entities.each do |entity|
        if entity.is_a?(Sketchup::Face)
          entity.back_material=entity.material if entity.material && !entity.back_material
        elsif container?(entity)
          nested=entity.is_a?(Sketchup::Group) ? entity.entities.parent : entity.definition
          paint_imported_back_faces(nested,seen)
        end
      end
    end

    def normalize_assembly(args)
      raise 'Specify assembly or json_path, not both' if args['assembly'] && args['json_path']
      data=args['assembly'] || JSON.parse(File.read(automation_file(args.fetch('json_path'))))
      data=JSON.parse(JSON.generate(data))
      if data['groups'].is_a?(Hash)
        anchors={}
        (data.fetch('drawers',[])+data.fetch('doors',[])).each { |p| anchors[p.fetch('group')]=p['anchor_mm'] || p['hinge_mm'] }
        anchors['UpperDoor']=data['upper_door_hinge_mm'] if data['upper_door_hinge_mm']
        data['groups']=data['groups'].map do |key,name|
          door=data.fetch('doors',[]).find { |entry| entry['group']==key }
          drawer=data.fetch('drawers',[]).find { |entry| entry['group']==key }
          motion=if door
            {'rotation_axis'=>door.fetch('rotation_axis',[0,0,1]),'rotation_degrees'=>door.fetch('angle_degrees',-100)}
          elsif drawer
            {'translation_mm'=>[0,-drawer.fetch('travel_mm',400),0]}
          end
          motion=data.fetch('motions',{}).fetch(key,motion)
          { 'key'=>key,'name'=>name,'component'=>true,'anchor_mm'=>anchors.fetch(key,[0,0,0]),'role'=>key,'motion'=>motion }
        end
      end
      if data['materials'].is_a?(Hash)
        data['materials']=data['materials'].map { |key,rgb| { 'key'=>key,'name'=>key=='yellow' ? 'My Yellow' : 'MCP '+key,'rgb'=>rgb,'opacity'=>key=='red' ? data.fetch('zone_opacity',0.18) : 1 } }
      end
      raise 'Assembly shapes missing or too many' unless data['shapes'].is_a?(Array) && data['shapes'].length.between?(1,10000)
      data['groups'] ||= data['shapes'].map { |shape| shape.fetch('group','Root') }.uniq.reject { |key| key=='Root' }.map { |key| {'key'=>key,'name'=>key,'component'=>true} }
      data['materials'] ||= []
      raise 'Too many groups/materials' if data['groups'].length>1000 || data['materials'].length>100
      data
    end

    def build_native(model,args)
      raise 'Exit group/component editing before building' if model.active_path
      key=args.fetch('key');old=model.entities.find { |e| container?(e) && e.get_attribute(ATTRIBUTE,'key')==key }
      raise 'Stable key already exists; set replace:true' if old && !args.fetch('replace',false)
      raise 'Existing assembly is locked' if old && old.locked?
      data=normalize_assembly(args);materials={}
      data['materials'].each { |spec| materials[spec.fetch('key')]=material_from(model,spec) }
      group=model.entities.add_group;group.name=data.fetch('name',key)
      containers={'Root'=>group};specs=data['groups'].dup
      until specs.empty?
        progress=false
        specs.dup.each do |spec|
          id=spec.fetch('key');raise 'Duplicate group key' if containers.key?(id)
          parent=containers[spec.fetch('parent','Root')];next unless parent
          child=parent.entities.add_group;child.name=spec.fetch('name',id)
          child.set_attribute(ATTRIBUTE,'role',spec.fetch('role',id));child.set_attribute(ATTRIBUTE,'part_key',id)
          child.layer=model.layers.add(spec['tag']) if spec['tag']
          containers[id]=child;specs.delete(spec);progress=true
        end
        raise 'Unknown/cyclic group parent' unless progress
      end
      data['shapes'].each { |shape| native_part(containers.fetch(shape.fetch('group','Root')).entities,shape,materials) }
      # Child groups are built in their parent axes; geometry is shifted to each requested anchor.
      data['groups'].reverse_each do |spec|
        child=containers.fetch(spec.fetch('key'));anchor=vector(spec.fetch('anchor_mm',[0,0,0]))
        child.entities.transform_entities(Geom::Transformation.translation(anchor.map { |n| -n }),child.entities.to_a) unless child.entities.length.zero?
        child.transformation=Geom::Transformation.translation(anchor)
        if spec.fetch('component',true)
          child=child.to_component;child.name=spec.fetch('name',spec['key']);child.definition.name=child.name
        end
        child.set_attribute(ATTRIBUTE,'part_key',spec['key']);child.set_attribute(ATTRIBUTE,'role',spec.fetch('role',spec['key']))
        child.set_attribute(ATTRIBUTE,'closed_transform',child.transformation.to_a)
        if spec['motion']
          child.set_attribute(ATTRIBUTE,'motion',JSON.generate(spec['motion']))
          child.set_attribute(ATTRIBUTE,'open',false)
          child.set_attribute(ATTRIBUTE,'motion_fraction',0.0)
        end
      end
      component=group.to_component;component.name=data.fetch('name',key);component.definition.name=data.fetch('name',key)
      component.set_attribute(ATTRIBUTE,'key',key);component.set_attribute(ATTRIBUTE,'role','assembly')
      component.set_attribute(ATTRIBUTE,'version',Time.now.utc.iso8601) if Time.now.respond_to?(:iso8601)
      component.set_attribute(ATTRIBUTE,'assembly_spec',JSON.generate(data))
      component.transformation=old ? old.transformation : Geom::Transformation.translation(vector(args.fetch('origin_mm',[0,0,0])))
      component.layer=old.layer if old
      old.erase! if old
      info=inspect_path(model,[component.persistent_id])
      expected=args['expected_dimensions_mm'] || data['expected_dimensions_mm']
      if expected
        actual=info[:local_bounds_mm][:dimensions]
        raise "Assembly dimensions #{actual} differ from expected #{expected}" unless actual.zip(expected).all? { |a,b| (a-b).abs<0.1 }
      end
      {entity:info,part_count:data['shapes'].length}
    end

    def cabinet_spec(parameters,name)
      p={'panel_mm'=>18,'base_mm'=>0,'back_mm'=>0,'shelves_mm'=>[]}.merge(parameters)
      w=positive_number(p.fetch('width_mm'),'width');d=positive_number(p.fetch('depth_mm'),'depth');h=positive_number(p.fetch('height_mm'),'height');t=positive_number(p['panel_mm'],'panel')
      base=p['base_mm'];back=p['back_mm']
      raise 'Invalid cabinet clear space/base/back' unless base.is_a?(Numeric) && base.finite? && base>=0 && back.is_a?(Numeric) && back.finite? && back>=0 && w>2*t && d>back && h>base+2*t
      shapes=[]
      add=lambda { |label,origin,size| shapes << {'type'=>'box','name'=>label,'origin'=>origin,'size'=>size,'group'=>'Frame','material'=>'yellow'} }
      add.call('Левая боковина',[0,0,base],[t,d,h-base]);add.call('Правая боковина',[w-t,0,base],[t,d,h-base])
      add.call('Дно',[t,0,base],[w-2*t,d,t]);add.call('Верх',[t,0,h-t],[w-2*t,d,t])
      add.call('Цоколь',[t,[60,d/2].min,0],[w-2*t,t,base]) if base>0
      add.call('Задняя стенка',[t,d-back,base+t],[w-2*t,back,h-base-2*t]) if back>0
      occupied=[]
      p['shelves_mm'].each do |z|
        raise 'Shelf falls outside clear space or overlaps another shelf' unless z.is_a?(Numeric) && z.finite? && z>=base+t && z+t<=h-t && occupied.all? { |other| (other-z).abs>=t }
        occupied << z;add.call('Полка',[t,0,z],[w-2*t,d-back,t])
      end
      [{'name'=>name,'materials'=>[{'key'=>'yellow','name'=>'My Yellow','rgb'=>[254,227,0]}],
        'groups'=>[{'key'=>'Frame','name'=>'Корпус','component'=>true}], 'shapes'=>shapes,'expected_dimensions_mm'=>[w,d,h]},p]
    end

    def edit_transform(entity,parent_world,args)
      space=args.fetch('space','world')
      reference=case space
      when 'world' then Geom::Transformation.new
      when 'parent' then parent_world
      when 'local' then parent_world*entity.transformation
      else raise 'Unknown transform space'
      end
      delta=Geom::Transformation.new
      if args.key?('rotation_degrees')
        axis=args.fetch('rotation_axis',[0,0,1]);raise 'Zero rotation axis' if axis.sum { |n| n*n }==0
        pivot=args.fetch('pivot_mm',space=='world' ? mm((parent_world*entity.transformation).origin) : [0,0,0])
        delta=Geom::Transformation.rotation(vector(pivot),axis,args['rotation_degrees']*Math::PI/180)
      end
      if args['translation_mm']
        delta=Geom::Transformation.translation(vector(args['translation_mm']))*delta
      end
      if args.fetch('absolute',false)
        raise 'Absolute placement requires world space and translation_mm; rotation is local Z' unless space=='world' && args['translation_mm'] && !args['pivot_mm']
        placement=Geom::Transformation.translation(vector(args['translation_mm']))
        placement=placement*Geom::Transformation.rotation([0,0,0],args.fetch('rotation_axis',[0,0,1]),args.fetch('rotation_degrees',0)*Math::PI/180)
        entity.transformation=parent_world.inverse*placement
      else
        entity.transformation=parent_world.inverse*reference*delta*reference.inverse*parent_world*entity.transformation
      end
    end

    def deep_unique(entity,depth=0)
      raise 'Component tree exceeds limit' if depth>32
      entity.make_unique
      children(entity).select { |child| container?(child) }.each { |child| deep_unique(child,depth+1) }
    end

    def apply_camera(model,args)
      spec=args['camera']
      if spec
        eye=Geom::Point3d.new(vector(spec.fetch('eye_mm')));target=Geom::Point3d.new(vector(spec.fetch('target_mm')))
        raise 'Camera eye equals target' if eye.distance(target)<1e-8
        up=spec.fetch('up',[0,0,1]);raise 'Camera up vector is zero or parallel to view' if Geom::Vector3d.new(up).cross(target-eye).length<1e-8
        camera=Sketchup::Camera.new(eye,target,up,spec.fetch('perspective',false))
        camera.height=positive_number(spec.fetch('height_mm',2000),'camera height')/25.4 unless camera.perspective?
        model.active_view.camera=camera
      elsif args['paths']
        box=Geom::BoundingBox.new
        args['paths'].each do |path|
          entity,world,=resolve_path(model,path);bounds=entity.is_a?(Sketchup::Group) ? entity.entities.parent.bounds : entity.definition.bounds
          box.add(transformed_bounds(bounds,world))
        end
        raise 'No geometry to fit camera' if box.empty?
        target=box.center;span=[box.width,box.height,box.depth,1.0].max
        eye=target+Geom::Vector3d.new(span*1.5,-span*2.0,span*1.4)
        camera=Sketchup::Camera.new(eye,target,[0,0,1],false)
        # Conservative fit accounting for the viewport's aspect ratio.
        aspect=model.active_view.vpwidth.to_f/[model.active_view.vpheight,1].max
        camera.height=box.diagonal*1.3/[aspect,1.0].min
        model.active_view.camera=camera
      else raise 'Specify camera or paths'
      end
      {eye_mm:mm(model.active_view.camera.eye),target_mm:mm(model.active_view.camera.target),perspective:model.active_view.camera.perspective?}
    end

    def save_scene(model,args)
      apply_camera(model,args) if args['camera']
      args.fetch('visible_tags',[]).each { |name| (model.layers[name] || model.layers.add(name)).visible=true }
      args.fetch('hidden_tags',[]).each { |name| (model.layers[name] || model.layers.add(name)).visible=false }
      page=model.pages.find { |entry| entry.name==args.fetch('name') } || model.pages.add(args.fetch('name'))
      page.use_camera=true;page.use_hidden_layers=true
      page.use_hidden_objects=false if page.respond_to?(:use_hidden_objects=)
      page.use_hidden_geometry=false if page.respond_to?(:use_hidden_geometry=)
      page.use_axes=false;page.use_rendering_options=false;page.use_shadow_info=false;page.use_section_planes=false
      page.update(PAGE_USE_CAMERA | PAGE_USE_LAYER_VISIBILITY);page.transition_time=0
      {scene_id:page.persistent_id,name:page.name}
    end

    def automation_execute(model,tool,args)
      case tool
      when 'get_capabilities'
        {version:'0.3.0',automation_tools:AUTOMATION_READ+AUTOMATION_WRITE,automation_folders:file_roots,
          primitive_types:%w[box rectangle cylinder ring tube plate_hole circle sphere cone],
          export_formats:%w[skp obj dae stl png jpg jpeg],
          session:@session,model_id:model.object_id.to_s,context:context(model),
          collision_methods:['exact SAT on verified box leaves','conservative bounds on other geometry'],
          scene_transforms:'Use create_scene_variants; ordinary scenes do not store object transformations'}
      when 'get_operation_status'
        operation_status(args.fetch('operation_id'))
      when 'find_objects'
        result=[];limit=args.fetch('max_results',100)
        walk_instances(model.entities) do |entity,path,_|
          next if args['name'] && !entity.name.downcase.include?(args['name'].downcase)
          next if args['role'] && entity.get_attribute(ATTRIBUTE,'role')!=args['role']
          next if args['key'] && entity.get_attribute(ATTRIBUTE,'key')!=args['key']
          result << inspect_path(model,path) if result.length<=limit
        end
        {objects:result.first(limit),truncated:result.length>limit}
      when 'inspect_object'
        inspect_path(model,args.fetch('path'))
      when 'measure_objects'
        objects=args.fetch('paths').map { |path| inspect_path(model,path) };box=Geom::BoundingBox.new
        measured=args.fetch('paths').map { |path| physical_bounds(model,path,args.fetch('include_zones',false)) }
        measured.each do |bounds|
          next if bounds.empty?
          box.add(bounds)
        end
        pairs=args['paths'].each_index.to_a.combination(2).map do |i,j|
          measured[i].empty? || measured[j].empty? ? {a:args['paths'][i],b:args['paths'][j],empty:true} : gap_info(measured[i],measured[j]).merge(a:args['paths'][i],b:args['paths'][j])
        end
        result={objects:objects,combined_world_bounds_mm:bounds_hash(box),pairs:pairs,include_zones:args.fetch('include_zones',false),measurement:'physical world axis-aligned bounds; not exact surface clearance'}
        if args['available_dimensions_mm'] && !box.empty?
          sizes=mm([box.width,box.height,box.depth]);available=args['available_dimensions_mm']
          result[:remaining_mm]=available.zip(sizes).map { |a,b| a-b };result[:fits]=result[:remaining_mm].all? { |n| n>=-0.01 }
        end
        result
      when 'check_collisions'
        paths=args.fetch('paths');raise 'Need at least two assembly paths' unless paths.length>=2
        maximum=args.fetch('max_pairs',20000);tolerance=args.fetch('tolerance_mm',0.1);raise 'Tolerance must be nonnegative' if tolerance<0
        results=[];remaining=maximum
        paths.combination(2).each do |a,b|
          raise 'Overlapping ancestor paths are not separate obstacles' if a[0,b.length]==b || b[0,a.length]==a
          left=leaves(model,a);right=leaves(model,b)
          raise 'Selected assembly has no visible physical geometry; activate its scene first' if left.empty? || right.empty?
          result=collisions_between(left,right,tolerance,remaining)
          remaining-=result[:pairs_tested];results << result.merge(a:a,b:b)
        end
        {checks:results,clear:results.all? { |r| r[:hits].empty? }}
      when 'check_motion'
        path=args.fetch('path');_,world,=resolve_path(model,path)
        obstacles=args.fetch('obstacles');raise 'Moving object cannot be its own obstacle' if obstacles.any? { |p| p[0,path.length]==path || path[0,p.length]==p }
        fixed=obstacles.flat_map { |p| leaves(model,p) };steps=args.fetch('steps',11);samples=[]
        raise 'Moving object or obstacles have no visible physical geometry' if fixed.empty? || leaves(model,path).empty?
        raise 'Specify translation or rotation' unless args['translation_mm'] || args.key?('rotation_degrees')
        steps.times do |i|
          fraction=i.to_f/(steps-1);delta=Geom::Transformation.new
          if args.key?('rotation_degrees')
            pivot=vector(args.fetch('pivot_mm',mm(world.origin)));axis=args.fetch('rotation_axis',[0,0,1]);raise 'Zero rotation axis' if axis.sum { |n| n*n }==0
            delta=Geom::Transformation.rotation(pivot,axis,args['rotation_degrees']*fraction*Math::PI/180)
          end
          delta=Geom::Transformation.translation(vector(args['translation_mm']).map { |n| n*fraction })*delta if args['translation_mm']
          result=collisions_between(leaves(model,path,delta),fixed,0.1,20000)
          samples << result.merge(fraction:fraction) unless result[:hits].empty?
        end
        {samples_checked:steps,collisions:samples,clear_at_samples:samples.empty?,continuous_motion_verified:false,model_changed:false}
      when 'build_assembly'
        build_native(model,args)
      when 'create_sphere','create_cone'
        type=tool=='create_sphere' ? 'sphere' : 'cone'
        shape={'type'=>type,'center'=>[0,0,0],'radius'=>args.fetch('radius_mm'),'segments'=>args.fetch('segments',32)}
        if type=='cone'
          shape.merge!('length'=>args.fetch('height_mm'),'axis'=>args.fetch('axis','Z'))
        end
        build_native(model,{'key'=>args.fetch('key'),'replace'=>args.fetch('replace',false),
          'origin_mm'=>args.fetch('center_mm',[0,0,0]),'assembly'=>{'name'=>args.fetch('name',type),'shapes'=>[shape]}})
      when 'create_furniture','update_furniture'
        if tool=='update_furniture'
          entity,_,_,path=writable_path(model,args.fetch('path'))
          raise 'Parametric update supports root cabinet shells only' unless path.length==1 && entity.get_attribute(ATTRIBUTE,'generator')=='cabinet-shell-v1'
          previous=JSON.parse(entity.get_attribute(ATTRIBUTE,'parameters'));parameters=previous.merge(args.fetch('parameters'))
          key=entity.get_attribute(ATTRIBUTE,'key');name=entity.name
        else
          parameters=args.fetch('parameters');key=args.fetch('key');name=args.fetch('name','Параметрический шкаф')
        end
        spec,p=cabinet_spec(parameters,name)
        result=build_native(model,{'assembly'=>spec,'key'=>key,'origin_mm'=>args.fetch('origin_mm',[0,0,0]),'replace'=>true})
        object=find(model,result[:entity][:id]);object.set_attribute(ATTRIBUTE,'generator','cabinet-shell-v1');object.set_attribute(ATTRIBUTE,'parameters',JSON.generate(p))
        result[:entity]=inspect_path(model,[object.persistent_id]);result
      when 'import_component'
        raise 'Exit component editing before importing' if model.active_path
        file=automation_file(args.fetch('file_path'));suffix=File.extname(file).downcase
        raise 'Import supports .skp and .dae' unless %w[.skp .dae].include?(suffix)
        key=args.fetch('key');old=model.entities.find { |e| container?(e) && e.get_attribute(ATTRIBUTE,'key')==key }
        raise 'Key already exists; use replace:true' if old && !args.fetch('replace',false)
        raise 'Existing object is locked' if old && old.locked?
        if suffix=='.skp'
          definition=model.definitions.load(file);raise 'SKP load failed' unless definition
        else
          # Model#import activates interactive placement for DAE. Import the
          # definition directly so the bridge owns instance placement.
          definition=model.definitions.import(file)
          raise 'DAE import failed or created empty geometry' unless definition && definition.entities.length>0
          paint_imported_back_faces(definition)
        end
        placement=old ? old.transformation : Geom::Transformation.translation(vector(args.fetch('origin_mm',[0,0,0])))
        placement=placement*Geom::Transformation.rotation([0,0,0],[0,0,1],args.fetch('rotation_degrees',0)*Math::PI/180) if args.key?('rotation_degrees')
        instance=model.entities.add_instance(definition,placement);instance.name=File.basename(file,'.'+suffix.delete('.'))
        instance.set_attribute(ATTRIBUTE,'key',key);instance.set_attribute(ATTRIBUTE,'source_file',file)
        instance.layer=old.layer if old;old.erase! if old
        {entity:inspect_path(model,[instance.persistent_id])}
      when 'transform_object'
        entity,world,_,path=writable_path(model,args.fetch('path'))
        parent=world*entity.transformation.inverse
        edit_transform(entity,parent,args)
        {entity:inspect_path(model,path)}
      when 'copy_object'
        original,world,chain=resolve_path(model,args.fetch('path'))
        raise 'Exit component editing' if model.active_path
        raise 'Source or ancestor is locked' if chain.any?(&:locked?)
        # Copies are placed at model root; source parent geometry is never edited.
        definition=original.is_a?(Sketchup::Group) ? original.entities.parent : original.definition
        placement=Geom::Transformation.translation(vector(args.fetch('delta_mm',[0,0,0])))*world
        copy=model.entities.add_instance(definition,placement);copy.name=original.name+' — копия'
        deep_unique(copy) if args.fetch('independent',true)
        copy.set_attribute(ATTRIBUTE,'key',args['key']) if args['key']
        {entity:inspect_path(model,[copy.persistent_id])}
      when 'set_object_properties'
        # Allow explicitly unlocking the selected object; locked ancestors remain protected.
        if args['locked']==false
          target,_,chain=resolve_path(model,remapped_path(args.fetch('path')))
          raise 'Ancestor is locked' if chain[0...-1].any?(&:locked?)
          target.locked=false
        end
        entity,_,_,path=writable_path(model,args.fetch('path'))
        entity.name=args['name'] if args.key?('name')
        %w[role key].each { |key| entity.set_attribute(ATTRIBUTE,key,args[key]) if args.key?(key) }
        entity.layer=model.layers.add(args['tag']) if args['tag']
        entity.hidden=args['hidden'] if args.key?('hidden');entity.locked=args['locked'] if args.key?('locked')
        {entity:inspect_path(model,path)}
      when 'delete_objects'
        paths=args.fetch('paths');raise 'Delete parent or child, not both in one command' if paths.combination(2).any? { |a,b| a[0,b.length]==b || b[0,a.length]==a }
        # Resolve before mutation; deletion of siblings must not invalidate later paths through uniquification.
        deleted=[]
        paths.sort_by(&:length).reverse_each do |path|
          entity,_,_,new_path=writable_path(model,path);entity.erase!;deleted << new_path
        end
        {deleted_paths:deleted}
      when 'create_material'
        m=material_from(model,{'key'=>args.fetch('name'),'name'=>args['name'],'rgb'=>args.fetch('rgb'),'opacity'=>args.fetch('opacity',1)})
        {name:m.name,opacity:m.alpha}
      when 'paint_object'
        material=model.materials[args.fetch('material_name')];raise 'Material does not exist' unless material
        entity,_,_,path=writable_path(model,args.fetch('path'));paint_faces(entity,material,args.fetch('recursive',false))
        {entity:inspect_path(model,path)}
      when 'set_tags'
        args.fetch('tags').each { |spec| tag=model.layers[spec.fetch('name')] || model.layers.add(spec['name']);tag.visible=spec['visible'] if spec.key?('visible') }
        {tags:model.layers.map { |tag| {name:tag.name,visible:tag.visible?} }}
      when 'list_tags'
        {tags:model.layers.map { |tag| {name:tag.name,visible:tag.visible?} }}
      when 'set_camera'
        apply_camera(model,args)
      when 'create_scene'
        save_scene(model,args)
      when 'list_scenes'
        {scenes:model.pages.map { |page| {scene_id:page.persistent_id,name:page.name} }}
      when 'activate_scene'
        page=model.pages.find { |entry| args['scene_id'] ? entry.persistent_id==args['scene_id'] : entry.name==args.fetch('name') };raise 'Scene not found' unless page
        model.pages.selected_page=page;{scene_id:page.persistent_id,name:page.name}
      when 'create_scene_variants'
        create_variants(model,args)
      when 'add_annotation'
        raise 'Exit component editing before adding dimensions' if model.active_path
        start=Geom::Point3d.new(vector(args.fetch('start_mm')))
        item=if args.fetch('kind')=='dimension'
          finish=Geom::Point3d.new(vector(args.fetch('end_mm')));raise 'Dimension length is zero' if start.distance(finish)<1e-8
          model.entities.add_dimension_linear(start,finish,Geom::Vector3d.new(vector(args.fetch('offset_mm',[0,-100,0]))))
        else model.entities.add_text(args.fetch('text'),start)
        end
        item.layer=model.layers.add(args['tag']) if args['tag'];{id:item.persistent_id}
      when 'save_model'
        file=automation_file(args.fetch('file_path'),true);raise 'Save requires .skp' unless File.extname(file).downcase=='.skp'
        ok=args.fetch('copy',true) ? model.save_copy(file) : model.save(file)
        raise 'Model save failed' unless ok;{file_path:file,copy:args.fetch('copy',true),bytes:File.size(file)}
      when 'export_component'
        entity,=resolve_path(model,args.fetch('path'));file=automation_file(args.fetch('file_path'),true)
        raise 'Export requires .skp' unless File.extname(file).downcase=='.skp'
        definition=entity.is_a?(Sketchup::Group) ? entity.entities.parent : entity.definition
        raise 'Component save failed' unless definition.save_as(file)
        {file_path:file,bytes:File.size(file)}
      when 'export_scene'
        export_scene(model,args)
      when 'eval_ruby'
        raise 'Exit component editing before executing Ruby' if model.active_path
        code=args.fetch('code');raise 'Ruby code must contain 1..100000 characters' unless code.is_a?(String) && code.length.between?(1,100000)
        mode=args.fetch('transaction','managed');raise 'Invalid Ruby transaction mode' unless %w[managed script_owned].include?(mode)
        stdout=StringIO.new;stderr=StringIO.new
        old_stdout=$stdout;old_stderr=$stderr
        begin
          $stdout=stdout;$stderr=stderr
          value=TOPLEVEL_BINDING.dup.eval(code,'(SketchUp MCP eval_ruby)',1)
        rescue SyntaxError => error
          raise "Ruby syntax error: #{error.message}\nstdout: #{stdout.string}\nstderr: #{stderr.string}"
        rescue StandardError => error
          raise "#{error.class}: #{error.message}\nstdout: #{stdout.string}\nstderr: #{stderr.string}"
        ensure
          $stdout=old_stdout;$stderr=old_stderr
        end
        # Preserve JSON data; SketchUp objects and other non-JSON values use Ruby inspection.
        result=if value.nil? || value==true || value==false || value.is_a?(Numeric) || value.is_a?(String) || value.is_a?(Array) || value.is_a?(Hash)
          begin JSON.parse(JSON.generate(value));rescue JSON::GeneratorError,TypeError,SystemStackError;value.inspect;end
        else value.inspect
        end
        {result:result,result_type:value.class.name,stdout:stdout.string,stderr:stderr.string,
          transaction:mode,code_sha256:Digest::SHA256.hexdigest(code)}
      when 'run_ruby_script'
        raise 'Exit component editing before executing a generator' if model.active_path
        file=automation_file(args.fetch('file_path'));raise 'Script must be .rb' unless File.extname(file).downcase=='.rb'
        source=File.binread(file);raise 'Script SHA256 mismatch' unless Digest::SHA256.hexdigest(source)==args.fetch('sha256')
        before=model.entities.to_a.map(&:persistent_id)
        # Evaluate the checked bytes, avoiding a load-after-hash file race. Retains __FILE__ for generators.
        TOPLEVEL_BINDING.eval(source.force_encoding('UTF-8'),file,1)
        created=model.entities.select { |entry| container?(entry) && !before.include?(entry.persistent_id) }
        {file_path:file,sha256:args['sha256'],created:created.map { |entry| inspect_path(model,[entry.persistent_id]) },transaction:'script_owned'}
      when 'batch_edit'
        commands=args.fetch('commands');allowed=%w[transform_object set_object_properties paint_object delete_objects add_annotation]
        raise 'Unsupported batch command' unless commands.all? { |command| allowed.include?(command['tool']) }
        {results:commands.map { |command| automation_execute(model,command.fetch('tool'),command.fetch('arguments')) }}
      else raise "Unknown automation tool #{tool}"
      end
    end

    def export_scene(model,args)
      file=automation_file(args.fetch('file_path'),true)
      format=File.extname(file).downcase.delete_prefix('.')
      images=%w[png jpg jpeg]
      raise 'Export supports SKP, OBJ, DAE, STL, PNG and JPEG' unless (%w[skp obj dae stl]+images).include?(format)
      image_keys=%w[width height transparent compression]
      raise 'Image options only apply to PNG/JPEG exports' if !images.include?(format) && image_keys.any? { |key| args.key?(key) }
      raise 'Transparent background requires PNG' if format!='png' && args.fetch('transparent',false)
      raise 'render_compatible only applies to DAE' if args.key?('render_compatible') && format!='dae'
      paths=args['paths'];selected=nil
      if paths
        raise 'Object selection export supports OBJ, DAE and STL; use export_component for SKP' unless %w[obj dae stl].include?(format)
        raise 'Exit component editing before selection export' if model.active_path
        raise 'Export paths must be nonempty root paths; export nested components as SKP using export_component' unless paths.is_a?(Array) && !paths.empty? && paths.all? { |path| path.is_a?(Array) && path.length==1 }
        selected=paths.map { |path| resolve_path(model,path).first }.uniq
      end
      if images.include?(format)
        width=bounded_integer(args.fetch('width',1920),64,16000)
        height=bounded_integer(args.fetch('height',1080),64,16000)
        compression=args.fetch('compression',0.95)
        raise 'Compression must be 0..1' unless compression.is_a?(Numeric) && compression.finite? && compression.between?(0,1)
        model.active_view.refresh
        ok=model.active_view.write_image(filename:file,width:width,height:height,antialias:true,
          transparent:args.fetch('transparent',false),compression:compression)
      elsif format=='skp'
        ok=model.save_copy(file)
      else
        options={show_summary:false,selectionset_only:!selected.nil?}
        if format=='stl'
          options.merge!(units:'mm',format:'binary',swap_yz:false)
        else
          options.merge!(triangulated_faces:true,doublesided_faces:false,edges:false,texture_maps:true)
          options.merge!(units:'mm',swap_yz:false) if format=='obj'
          options.merge!(preserve_instancing:true,hidden_geometry:false) if format=='dae'
          options.merge!(preserve_instancing:false,texture_maps:false) if args.fetch('render_compatible',false)
        end
        if selected
          previous=model.selection.to_a.dup
          begin
            model.selection.clear;model.selection.add(selected)
            ok=model.export(file,options)
          ensure
            model.selection.clear;model.selection.add(previous.select(&:valid?))
          end
        else
          ok=model.export(file,options)
        end
      end
      raise "#{format.upcase} export failed; check SketchUp exporter availability" unless ok && File.file?(file) && File.size(file)>0
      {file_path:file,format:format,bytes:File.size(file),paths:paths,render_compatible:args.fetch('render_compatible',false)}
    end

    def create_variants(model,args)
      raise 'Exit component editing before creating variants' if model.active_path
      raise 'Specify 1..20 scene variants' unless args.fetch('variants').length.between?(1,20)
      source,world,chain=resolve_path(model,args.fetch('path'));raise 'Source or ancestor is locked' if chain.any?(&:locked?)
      definition=source.is_a?(Sketchup::Group) ? source.entities.parent : source.definition
      variants=[];tags=[]
      args.fetch('variants').each do |spec|
        instance=model.entities.add_instance(definition,world);instance.name=spec.fetch('name')
        # Variants remain independent even when the user edits nested geometry later.
        deep_unique(instance)
        tag=model.layers.add('MCP — '+spec.fetch('name'));instance.layer=tag;tags << tag
        instance.set_attribute(ATTRIBUTE,'role','scene_variant')
        relative=lambda do |ids|
          # Persistent IDs can change after root make_unique: map source child positions into the copied tree.
          src=children(source).to_a;dst=children(instance).to_a;result=[instance.persistent_id]
          ids.each_with_index do |id,index|
            pos=src.index { |entry| entry.persistent_id==id };raise 'Variant part path not found in source' unless pos
            child=dst[pos];result << child.persistent_id
            if index<ids.length-1;src=children(src[pos]).to_a;dst=children(child).to_a;end
          end
          result
        end
        spec.fetch('transforms',[]).each do |edit|
          path=relative.call(edit.fetch('path'));entity,transform,_,=writable_path(model,path)
          edit_transform(entity,transform*entity.transformation.inverse,edit.merge('space'=>edit.fetch('space','local')))
        end
        # Hiding leaves preserves indexing for other relative paths and does not mutate source definitions.
        spec.fetch('omit_paths',[]).each do |ids|
          entity,_,_,=writable_path(model,relative.call(ids));entity.hidden=true
        end
        variants << {instance:instance,tag:tag,name:spec['name']}
      end
      # Hide source via a dedicated tag so scenes never show both source and variant.
      old_tag=source.layer;source_tag=model.layers.add('MCP — source '+source.persistent_id.to_s);source.layer=source_tag
      source_tag.visible=false
      apply_camera(model,{'paths'=>variants.map { |v| [v[:instance].persistent_id] }}) unless variants.empty?
      scenes=variants.map do |entry|
        tags.each { |tag| tag.visible=tag==entry[:tag] }
        result=save_scene(model,{'name'=>entry[:name]})
        result.merge(path:[entry[:instance].persistent_id],tag:entry[:tag].name)
      end
      tags.each_with_index { |tag,index| tag.visible=index.zero? }
      {scenes:scenes,source_tag:source_tag.name,previous_source_tag:old_tag.name,transforms_saved:'independent assembly variants with visibility scenes'}
    end
  end
end
