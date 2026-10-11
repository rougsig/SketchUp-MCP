"""Typed tools for native assemblies, instance paths and verification (millimeters)."""
NUM={'type':'number'}
STR={'type':'string','maxLength':512}
V={'type':'array','items':NUM,'minItems':3,'maxItems':3}
PATH={'type':'array','items':{'type':'integer','minimum':1},'minItems':1,'maxItems':32}
PATHS={'type':'array','items':PATH,'minItems':1,'maxItems':100}
BOOL={'type':'boolean'}
POS={'type':'number','exclusiveMinimum':0}
SEGMENTS={'type':'integer','enum':[12,16,24,32,48,64,96,128]}
def enum(*values): return {'type':'string','enum':list(values)}
def obj(properties,required=()): return {'type':'object','properties':properties,'required':list(required),'additionalProperties':False}
def arr(item,maximum=10000): return {'type':'array','items':item,'maxItems':maximum}
PARAMS=obj({'width_mm':NUM,'depth_mm':NUM,'height_mm':NUM,'panel_mm':NUM,'base_mm':NUM,'shelves_mm':arr(NUM,30),'back_mm':NUM})
PRIMITIVE=obj({'type':enum('box','rectangle','cylinder','ring','tube','plate_hole','circle','sphere','cone'),
 'name':STR,'group':STR,'material':STR,'origin':V,'size':V,'vertices':arr(V,100),
 'center':V,'radius':NUM,'outer':NUM,'inner':NUM,'length':NUM,'depth':NUM,'axis':enum('X','Y','Z'),
 'hole_center':V,'normal':V,'segments':SEGMENTS},['type'])
GROUP=obj({'key':STR,'name':STR,'parent':STR,'component':BOOL,'anchor_mm':V,'tag':STR,'role':STR})
ASSEMBLY=obj({'name':STR,'groups':arr(GROUP,1000),'shapes':arr(PRIMITIVE),
 'materials':arr(obj({'key':STR,'name':STR,'rgb':V,'opacity':NUM},['key','rgb']),100),
 'expected_dimensions_mm':V})
CAMERA=obj({'eye_mm':V,'target_mm':V,'up':V,'perspective':BOOL,'height_mm':NUM},['eye_mm','target_mm'])
TRANSFORM=obj({'path':PATH,'translation_mm':V,'rotation_axis':V,'rotation_degrees':NUM,'pivot_mm':V,
 'space':enum('world','parent','local'),'absolute':BOOL},['path'])
TOOLS=[]
def add(name,description,properties={},required=(),write=False,open_world=False):
 TOOLS.append({'name':name,'description':description,'inputSchema':obj(properties,required),
  'annotations':{'readOnlyHint':not write,'destructiveHint':write,'openWorldHint':open_world}})
add('get_capabilities','Bridge version, supported tools, automation folders and model revision.')
add('find_objects','Search recursive instance paths by name, role or stable key. Results include world bounds.',{'name':STR,'role':STR,'key':STR,'max_results':{'type':'integer','minimum':1,'maximum':500}})
add('inspect_object','Local and world bounds, transform, attributes, solid status and children for an unambiguous instance path.',{'path':PATH},['path'])
add('measure_objects','Physical world bounds, closest AABB distance, signed axis gaps and fit within optional limits. Clearance planes are excluded by default; AABB results are conservative, not exact geometry.',{'paths':PATHS,'available_dimensions_mm':V,'include_zones':BOOL},['paths'])
add('check_collisions','Check leaf solid boxes with separating axes; other overlapping leaf bounds are explicitly inconclusive. Tags/hidden objects respected.',{'paths':PATHS,'tolerance_mm':NUM,'max_pairs':{'type':'integer','minimum':1,'maximum':20000}},['paths'])
add('check_motion','Sample drawer or door movement against explicit obstacles without changing the model. Returns conservative collision evidence; sampling is not a continuous proof.',{'path':PATH,'obstacles':PATHS,'translation_mm':V,'rotation_axis':V,'rotation_degrees':NUM,'pivot_mm':V,'steps':{'type':'integer','minimum':2,'maximum':101}},['path','obstacles'])
add('get_operation_status','Read durable operation outcome by caller-supplied operation ID. Retry a write using the same ID to avoid duplicate execution.',{'operation_id':STR},['operation_id'])
add('list_scenes','List scene IDs and names.')
add('list_tags','List tags and visibility.')
add('build_assembly','Build native components, panels, circles, tubes, spheres and cones in one Undo operation. Updates stable key preserving placement. Optional JSON primitive file accepts existing project generators.',{'assembly':ASSEMBLY,'json_path':STR,'key':STR,'origin_mm':V,'replace':BOOL,'expected_dimensions_mm':V,'operation_id':STR},['key','operation_id'],True)
add('create_sphere','Create a closed smooth sphere component. Radius and center are millimeters; stable key supports replacement preserving placement.',{'key':STR,'name':STR,'center_mm':V,'radius_mm':POS,'segments':SEGMENTS,'replace':BOOL,'operation_id':STR},['key','radius_mm','operation_id'],True)
add('create_cone','Create a closed smooth cone component. center_mm is the base center, height_mm extends along positive axis (default Z). Millimeters.',{'key':STR,'name':STR,'center_mm':V,'radius_mm':POS,'height_mm':POS,'axis':enum('X','Y','Z'),'segments':SEGMENTS,'replace':BOOL,'operation_id':STR},['key','radius_mm','height_mm','operation_id'],True)
add('create_furniture','Parametric cabinet shell: panels, base, shelves and optional back. Existing key updates preserve placement and panel thickness.',{'key':STR,'name':STR,'parameters':PARAMS,'origin_mm':V,'operation_id':STR},['key','parameters','operation_id'],True)
add('update_furniture','Rebuild a cabinet shell using changed parameters, retaining placement. Only components created by create_furniture are supported.',{'path':PATH,'parameters':PARAMS,'operation_id':STR},['path','parameters','operation_id'],True)
add('import_component','Load SKP or import DAE into a component and place it, with stable identity and optional replacement.',{'file_path':STR,'key':STR,'origin_mm':V,'rotation_degrees':NUM,'replace':BOOL,'operation_id':STR},['file_path','key','operation_id'],True)
add('transform_object','Translate or rotate any nested instance by explicit path, in world, parent or local coordinates. Ancestors are made unique before nested edits.',dict(TRANSFORM['properties'],operation_id=STR),['path','operation_id'],True)
add('copy_object','Copy an instance with optional independent nested definitions and world translation.',{'path':PATH,'delta_mm':V,'independent':BOOL,'key':STR,'operation_id':STR},['path','operation_id'],True)
add('set_object_properties','Set name, stable role/key, tag, hidden or locked state by instance path.',{'path':PATH,'name':STR,'role':STR,'key':STR,'tag':STR,'hidden':BOOL,'locked':BOOL,'operation_id':STR},['path','operation_id'],True)
add('delete_objects','Delete explicitly listed object paths. One Undo operation.',{'paths':PATHS,'operation_id':STR},['paths','operation_id'],True)
add('create_material','Create/update a named material with RGB and opacity.',{'name':STR,'rgb':V,'opacity':NUM,'operation_id':STR},['name','rgb','operation_id'],True)
add('paint_object','Paint a nested component, optionally including its faces and descendants.',{'path':PATH,'material_name':STR,'recursive':BOOL,'operation_id':STR},['path','material_name','operation_id'],True)
add('set_tags','Create tags and set visibility in one operation.',{'tags':arr(obj({'name':STR,'visible':BOOL},['name']),100),'operation_id':STR},['tags','operation_id'],True)
add('set_camera','Set an explicit camera or fit specified object paths. get_view then captures the resulting native SketchUp view.',{'camera':CAMERA,'paths':PATHS,'operation_id':STR},['operation_id'],True)
add('create_scene','Save current camera and tag visibility, optionally setting them first. Does not record component transformations.',{'name':STR,'camera':CAMERA,'visible_tags':arr(STR,100),'hidden_tags':arr(STR,100),'operation_id':STR},['name','operation_id'],True)
add('activate_scene','Activate an existing scene.',{'scene_id':{'type':'integer','minimum':1},'name':STR,'operation_id':STR},['operation_id'],True)
add('create_scene_variants','Create independent assembly copies with drawer/door transforms and omitted parts; save scene visibility. Each edit uses paths relative to the source root.',{'path':PATH,'variants':arr(obj({'name':STR,'transforms':arr(TRANSFORM,100),'omit_paths':arr(PATH,100)},['name']),20),'operation_id':STR},['path','variants','operation_id'],True)
add('add_annotation','Add a dimension or text label using explicit world points.',{'kind':enum('dimension','text'),'start_mm':V,'end_mm':V,'offset_mm':V,'text':STR,'tag':STR,'operation_id':STR},['kind','start_mm','operation_id'],True)
add('save_model','Save a copy of the active model, or explicitly save the current model. Paths must be in configured automation folders.',{'file_path':STR,'copy':BOOL,'operation_id':STR},['file_path','operation_id'],True)
add('export_component','Save one component definition as standalone SKP.',{'path':PATH,'file_path':STR,'operation_id':STR},['path','file_path','operation_id'],True)
add('export_scene','Export active model to SKP/OBJ/DAE/STL or current view to PNG/JPEG. Optional paths select explicit root objects for OBJ/DAE/STL, restoring UI selection afterwards. DAE render_compatible exports diffuse colors without textures. Format follows file extension; output must be in configured automation folders.',{'file_path':STR,'paths':PATHS,'render_compatible':BOOL,'width':{'type':'integer','minimum':64,'maximum':16000},'height':{'type':'integer','minimum':64,'maximum':16000},'transparent':BOOL,'compression':{'type':'number','minimum':0,'maximum':1},'operation_id':STR},['file_path','operation_id'],True)
add('eval_ruby','Execute Ruby source directly in SketchUp (full Ruby access). Managed mode wraps geometry edits in one Undo; do not start/commit operations in that mode. Use script_owned for code managing its own operations. Files/system effects are not rolled back. Return the last expression; retry only with the same operation_id.',{'code':{'type':'string','minLength':1,'maxLength':100000},'transaction':enum('managed','script_owned'),'operation_id':STR},['code','operation_id'],True,True)
add('run_ruby_script','Execute a reviewed local Ruby file from configured automation folders. Requires SHA256 of exact file contents. Script owns Undo operations; no wrapper transaction.',{'file_path':STR,'sha256':{'type':'string','pattern':'^[a-f0-9]{64}$'},'operation_id':STR},['file_path','sha256','operation_id'],True)
add('batch_edit','Apply typed object transforms, properties, paint, deletes and annotations as one Undo operation. No scripts/import/save/nested batches.',{'commands':arr(obj({'tool':enum('transform_object','set_object_properties','paint_object','delete_objects','add_annotation'),'arguments':{'type':'object','additionalProperties':True}},['tool','arguments']),100),'operation_id':STR},['commands','operation_id'],True)
