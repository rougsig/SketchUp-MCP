# One-time upgrade, executed inside SketchUp Ruby Console.
require 'sketchup.rb'
require 'fileutils'
require 'json'
project=File.dirname(__FILE__)
workspace=project
if defined?(LocalSketchUpMCP::Bridge)
  LocalSketchUpMCP::Bridge.stop
end
plugins=Sketchup.find_support_file('Plugins')
raise 'SketchUp Plugins folder not found' unless plugins && File.directory?(plugins)
FileUtils.cp(File.join(project,'extension/sketch_up_mcp.rb'),File.join(plugins,'sketch_up_mcp.rb'))
FileUtils.mkdir_p(File.join(plugins,'sketch_up_mcp'))
Dir.glob(File.join(project,'extension/sketch_up_mcp/*.rb')).each do |source|
  FileUtils.cp(source,File.join(plugins,'sketch_up_mcp',File.basename(source)))
end
if defined?(LocalSketchUpMCP::Bridge)
  # Keep the module object: existing menu callbacks will call its upgraded methods.
  %i[ROOT READ_TOOLS WRITE_TOOLS AUTOMATION_READ AUTOMATION_WRITE ATTRIBUTE].each do |name|
    LocalSketchUpMCP::Bridge.send(:remove_const,name) if LocalSketchUpMCP::Bridge.const_defined?(name,false)
  end
end
$LOADED_FEATURES.delete_if { |file| file.end_with?('/sketch_up_mcp/automation.rb') }
bridge_file=File.join(project,'extension/sketch_up_mcp/bridge.rb')
# Installed menus already exist; avoid duplicating them during an in-session upgrade.
file_loaded(bridge_file) if defined?(LocalSketchUpMCP::Bridge)
load bridge_file
bridge=LocalSketchUpMCP::Bridge
FileUtils.mkdir_p(bridge::ROOT)
folders=bridge.file_roots+[File.realpath(workspace)]
bridge.atomic_json(File.join(bridge::ROOT,'automation-folders.json'),folders.uniq)
bridge.start
puts 'SketchUp MCP 0.3.0 activated: 41 tools. Restart the MCP connection in your AI client to refresh tools.'
puts "Automation folder: #{workspace}"
report_file=File.join(project,'dist','native-smoke-result.json')
begin
  load File.join(project,'tests','sketchup_smoke.rb')
  report=LocalSketchUpMCP::Smoke.instance_variable_get(:@last_result)
rescue StandardError => error
  report={status:'failed',error:"#{error.class}: #{error.message}",backtrace:error.backtrace.first(5)}
  warn "Native verification: #{error.message}. Bridge is activated; report: #{report_file}"
end
report[:sketchup_version]=Sketchup.version
report[:bridge_version]='0.3.0'
report[:verified_at]=Time.now.utc.iso8601
FileUtils.mkdir_p(File.dirname(report_file))
File.write(report_file,JSON.pretty_generate(report))
puts "Native verification report: #{report_file}"
