require 'sketchup.rb'
require 'extensions.rb'

module LocalSketchUpMCP
  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new('Local SketchUp MCP', 'sketch_up_mcp/bridge')
    extension.description = 'Local file bridge for an MCP assistant. Start from Extensions > Local SketchUp MCP.'
    extension.version = '0.2.0'
    extension.creator = 'Local SketchUp MCP'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
