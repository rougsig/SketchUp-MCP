require 'sketchup.rb'
require 'json'
require 'fileutils'
require 'securerandom'
require 'base64'
require 'time'
require_relative 'automation'

module LocalSketchUpMCP
  module Bridge
    extend self
    ROOT = File.expand_path(ENV.fetch('SKETCHUP_MCP_BRIDGE_DIR', File.join(Dir.home, '.sketch-up-mcp')))
    READ_TOOLS = %w[get_model list_entities get_selection get_view].freeze
    WRITE_TOOLS = %w[create_box move_entities resize_entity set_material].freeze

    def atomic_json(path, value)
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.generate(value))
      File.rename(tmp, path)
    end

    def context(model)
      (model.active_path || []).map(&:persistent_id)
    end

    def heartbeat(running)
      model = Sketchup.active_model
      atomic_json(File.join(ROOT, 'status.json'), {
        running: running, session: @session, updated_at: Time.now.to_f,
        model_id: model ? model.object_id.to_s : nil, context: model ? context(model) : [],
        bridge_version: '0.3.0', automation_tools: AUTOMATION_READ + AUTOMATION_WRITE
      })
    end

    def start
      return if @timer
      FileUtils.mkdir_p([File.join(ROOT, 'requests'), File.join(ROOT, 'responses')])
      File.chmod(0700, ROOT) unless Sketchup.platform == :platform_win
      @lock = File.open(File.join(ROOT, 'bridge.lock'), 'a')
      unless @lock.flock(File::LOCK_EX | File::LOCK_NB)
        @lock.close
        @lock = nil
        UI.messagebox('Another SketchUp instance is already using this MCP bridge. Stop that bridge first.')
        return
      end
      @session = SecureRandom.hex(16)
      heartbeat(true)
      @timer = UI.start_timer(0.25, true) { tick }
      Sketchup.status_text = 'Local SketchUp MCP bridge running'
    rescue StandardError => error
      stop
      UI.messagebox("MCP bridge could not start: #{error.message}")
    end

    def stop
      UI.stop_timer(@timer) if @timer
      @timer = nil
      if @lock
        begin
          heartbeat(false)
        ensure
          @lock.flock(File::LOCK_UN)
          @lock.close
          @lock = nil
        end
      end
      Sketchup.status_text = 'Local SketchUp MCP bridge stopped'
    end

    # UI timer callbacks execute API operations on SketchUp's main thread.
    def tick
      return if @busy
      @busy = true
      heartbeat(true)
      # One command per tick keeps the UI responsive between requests.
      path = Dir.glob(File.join(ROOT, 'requests', '*.json')).sort.first
      process(path) if path
      # Remove orphaned replies left by clients that exited or timed out.
      Dir.glob(File.join(ROOT, 'responses', '*.json')).each do |reply|
        File.delete(reply) if Time.now - File.mtime(reply) > 60
      end
    rescue StandardError => error
      warn "Local SketchUp MCP: #{error.class}: #{error.message}"
    ensure
      @busy = false
    end

    def process(path)
      id = File.basename(path, '.json')
      return unless id.match?(/\A[0-9a-f]{32}\z/)
      begin
        request = JSON.parse(File.read(path))
        raise 'Request ID mismatch' unless request['id'] == id
        raise 'Bridge session changed; read the model again' unless request['session'] == @session
        raise 'Request expired; command was not executed' unless request['expires_at'].is_a?(Numeric) && request['expires_at'] > Time.now.to_f
        model = Sketchup.active_model
        raise 'No active model' unless model
        unless request['model_id'] == model.object_id.to_s && request['context'] == context(model)
          raise 'Active model or editing context changed; read the model again'
        end
        args = request.fetch('arguments')
        raise 'Arguments must be an object' unless args.is_a?(Hash)
        result = dispatch(model, request.fetch('tool'), args)
        reply = { result: result }
      rescue StandardError => error
        reply = { error: "#{error.class}: #{error.message}" }
      ensure
        File.delete(path) if File.exist?(path)
      end
      atomic_json(File.join(ROOT, 'responses', "#{id}.json"), reply)
    end

    def vector(value, positive = false)
      unless value.is_a?(Array) && value.length == 3 && value.all? { |n| n.is_a?(Numeric) && n.finite? && (!positive || n > 0) }
        raise 'Expected three finite millimeter values' + (positive ? ' greater than zero' : '')
      end
      value.map { |n| n.to_f / 25.4 }
    end

    def bounded_integer(value, minimum, maximum)
      raise 'Integer out of range' unless value.is_a?(Integer) && value.between?(minimum, maximum)
      value
    end

    def mm(point)
      point.to_a.map { |n| (n.to_f * 25.4).round(6) }
    end

    def describe(entity)
      result = { id: entity.persistent_id, type: entity.typename }
      result[:name] = entity.name if entity.respond_to?(:name)
      result[:definition_name] = entity.definition.name if entity.is_a?(Sketchup::ComponentInstance)
      result[:material] = entity.material && entity.material.name if entity.respond_to?(:material)
      result[:tag] = entity.layer.name if entity.respond_to?(:layer)
      result[:hidden] = entity.hidden? if entity.respond_to?(:hidden?)
      if entity.respond_to?(:bounds) && !entity.bounds.empty?
        bounds = entity.bounds
        result[:bounds_mm] = { min: mm(bounds.min), max: mm(bounds.max),
                               dimensions: mm([bounds.width, bounds.height, bounds.depth]) }
      end
      if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        result[:locked] = entity.locked?
        result[:child_count] = children(entity).length
      end
      result
    end

    def children(entity)
      return entity.entities if entity.is_a?(Sketchup::Group)
      return entity.definition.entities if entity.is_a?(Sketchup::ComponentInstance)
      raise 'parent_id must refer to a group or component'
    end

    def find(model, id)
      raise 'Entity ID must be a positive integer' unless id.is_a?(Integer) && id > 0
      entity = model.find_entity_by_persistent_id(id)
      raise "Entity #{id} no longer exists" unless entity && entity.valid?
      entity
    end

    def editable(model, ids)
      raise 'Expected 1 to 1000 entity IDs' unless ids.is_a?(Array) && ids.length.between?(1, 1000)
      ids.uniq.map do |id|
        entity = find(model, id)
        unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          raise 'Only groups and component instances can be edited by this bridge'
        end
        raise 'Open the entity parent editing context first' unless model.active_entities.include?(entity)
        raise 'Entity is locked' if entity.locked?
        entity
      end
    end

    def operation(model, name)
      model.start_operation("MCP: #{name}", true)
      begin
        result = yield
        model.commit_operation
        result
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    def dispatch(model, tool, args)
      raise 'Finish dragging the artifact before automation writes' if @artifact_drag_active && WRITE_TOOLS.include?(tool)
      return automation_dispatch(model, tool, args) if (AUTOMATION_READ + AUTOMATION_WRITE).include?(tool)
      raise 'Unknown tool' unless (READ_TOOLS + WRITE_TOOLS).include?(tool)
      case tool
      when 'get_model'
        bounds = model.bounds
        { title: model.title, path: model.path, units: 'mm', context: context(model),
          entity_count: model.entities.length, active_entity_count: model.active_entities.length,
          bounds_mm: bounds.empty? ? nil : { min: mm(bounds.min), max: mm(bounds.max) },
          materials: model.materials.map { |m| { name: m.name, color_rgb: [m.color.red, m.color.green, m.color.blue], opacity: m.alpha } } }
      when 'list_entities'
        entities = args.key?('parent_id') ? children(find(model, args['parent_id'])) : model.active_entities
        offset = bounded_integer(args.fetch('offset', 0), 0, 2**31 - 1)
        limit = bounded_integer(args.fetch('limit', 100), 1, 500)
        page = entities.to_a.slice(offset, limit) || []
        { total: entities.length, offset: offset, entities: page.map { |e| describe(e) },
          next_offset: offset + page.length < entities.length ? offset + page.length : nil,
          coordinate_space: 'parent', context: context(model) }
      when 'get_selection'
        { context: context(model), entities: model.selection.map { |e| describe(e) } }
      when 'get_view'
        width = bounded_integer(args.fetch('width', 1280), 64, 2048)
        height = bounded_integer(args.fetch('height', 960), 64, 2048)
        image_path = File.join(ROOT, "view-#{SecureRandom.hex(16)}.png")
        begin
          ok = model.active_view.write_image(filename: image_path, width: width, height: height, antialias: true)
          raise 'SketchUp could not capture the view' unless ok && File.exist?(image_path)
          { png_base64: Base64.strict_encode64(File.binread(image_path)) }
        ensure
          File.delete(image_path) if File.exist?(image_path)
        end
      when 'create_box'
        x, y, z = vector(args.fetch('origin_mm', [0, 0, 0]))
        width, depth, height = vector(args.fetch('dimensions_mm'), true)
        name = args.fetch('name', 'MCP Box')
        raise 'Name must be a string up to 256 characters' unless name.is_a?(String) && name.length <= 256
        operation(model, 'Create box') do
          group = model.active_entities.add_group
          group.name = name
          face = group.entities.add_face([0, 0, 0], [width, 0, 0], [width, depth, 0], [0, depth, 0])
          raise 'Dimensions are too small to create a face' unless face
          face.reverse! if face.normal.z < 0
          face.pushpull(height)
          group.transform!(Geom::Transformation.translation([x, y, z]))
          { entity: describe(group) }
        end
      when 'move_entities'
        entities = editable(model, args.fetch('entity_ids'))
        translation = Geom::Transformation.translation(vector(args.fetch('delta_mm')))
        operation(model, 'Move entities') do
          model.active_entities.transform_entities(translation, entities)
          { entities: entities.map { |e| describe(e) } }
        end
      when 'resize_entity'
        entity = editable(model, [args.fetch('entity_id')]).first
        target = vector(args.fetch('dimensions_mm'), true)
        bounds = entity.bounds
        sizes = [bounds.width.to_f, bounds.height.to_f, bounds.depth.to_f]
        raise 'Cannot resize an entity with a zero bounding-box dimension' if sizes.any? { |n| n <= 0 }
        factors = target.zip(sizes).map { |desired, current| desired / current }
        transform = Geom::Transformation.scaling(bounds.min, *factors)
        operation(model, 'Resize entity') do
          entity.transform!(transform)
          { entity: describe(entity) }
        end
      when 'set_material'
        entities = editable(model, args.fetch('entity_ids'))
        name = args.fetch('material_name')
        raise 'Material name must be a string or null' unless name.nil? || name.is_a?(String)
        material = name.nil? ? nil : model.materials[name]
        raise 'Material not found; use a name from get_model' if name && !material
        operation(model, 'Set material') do
          entities.each { |entity| entity.material = material }
          { entities: entities.map { |e| describe(e) } }
        end
      end
    end

    unless file_loaded?(__FILE__)
      menu = UI.menu('Extensions').add_submenu('Local SketchUp MCP')
      menu.add_item('Start bridge') { start }
      menu.add_item('Stop bridge') { stop }
      menu.add_item('Add automation folder') do
        folder = UI.select_directory(title: 'Folder for MCP imports, generators and exports')
        if folder
          roots = file_roots + [File.realpath(folder)]
          atomic_json(File.join(ROOT,'automation-folders.json'), roots.uniq)
        end
      end
      menu.add_item('Bridge status') do
        UI.messagebox("Bridge: #{@timer ? 'running' : 'stopped'}\nDirectory: #{ROOT}\nOnly one SketchUp instance per bridge directory.")
      end
      file_loaded(__FILE__)
    end
  end
end
