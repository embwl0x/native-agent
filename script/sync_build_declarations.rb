#!/usr/bin/env ruby
# Package.swift owns external requirements; project.yml owns installed assembly.
# Materialize their shared declarations so plain SwiftPM/XcodeGen need no extra reader.
# Source files are UTF-8 whatever the shell's locale (a C/ASCII locale crashed every build).
Encoding.default_external = Encoding::UTF_8
require 'json'
require 'yaml'
require 'open3'
require 'find'

ROOT = ARGV[0] == '--verify-resources' ? File.realpath(ARGV.fetch(1)) : File.expand_path('..', __dir__)
def replace_generated(path, label, body)
  path = File.join(ROOT, path)
  source = File.read(path)
  pattern = /^([ \t]*)(?:\/\/|#) BEGIN generated #{label}[^\n]*\n.*?^\1(?:\/\/|#) END generated #{label}$/m
  raise "missing generated #{label} section in #{path}" unless source.match?(pattern)
  updated = source.sub(pattern) do |section|
    lines = section.lines
    lines.first + body + lines.last
  end
  File.write(path, updated) unless source == updated
end

spec = YAML.safe_load(File.read(File.join(ROOT, 'project.yml')))
app = spec.fetch('targets').fetch('NativeAgent')
resources = spec.fetch('targets').fetch('NativeAgent_NativeAgentApp').fetch('sources')
if ARGV[0] == '--verify-resources'
  destination = ARGV[2]
  abort "symlinked resource root: #{destination}" if destination && File.symlink?(destination)
  destination = File.realpath(destination) if destination
  [[resources, 'NativeAgent_NativeAgentApp.bundle/Contents/Resources'], [app.fetch('sources'), '']].each do |entries, subdir|
    entries.each do |entry|
      phase = entry['buildPhase']
      next unless phase == 'resources' || phase.is_a?(Hash) && phase.dig('copyFiles', 'destination') == 'resources'
      path = entry.fetch('path')
      target = File.join(subdir, phase.is_a?(Hash) ? phase.fetch('copyFiles').fetch('subpath', '') : '', File.basename(path))
      source = File.join(ROOT, path)
      Find.find(source, ignore_error: false) do |file|
        abort "symlinked resource: #{file}" unless File.realpath(file) == file
        abort "invalid resource: #{file}" unless File.directory?(file) || File.file?(file) && File.size(file) > 0
        next unless destination
        staged = File.join(destination, target + file.delete_prefix(source))
        abort "symlinked resource: #{staged}" unless File.realpath(staged) == staged
        abort "altered resource: #{staged}" unless File.directory?(file) ? File.directory?(staged) : File.file?(staged) && File.binread(staged) == File.binread(file)
      end
    end
  end
  puts '[resources] verified assembly-declared resources'
  exit
end
body = "            dependencies: [\n"
app.fetch('dependencies').each do |entry|
  next unless entry.key?('package') # Embedded targets stay in Xcode.
  products = entry.key?('products') ? entry.fetch('products') : [entry.fetch('product')]
  products.each { |product| body += "                .product(name: #{product.to_json}, package: #{entry.fetch('package').to_json}),\n" }
end
source = app.fetch('sources').find { |entry| entry['type'] == 'syncedFolder' }.fetch('path')
body += "            ],\n            path: #{source.to_json},\n            resources: [\n"
resources.each { |entry| body += "                .copy(#{('../../' + entry.fetch('path')).to_json}),\n" }
body += "            ]\n"
replace_generated('Package.swift', 'app declarations', body)

manifest, error, status = Open3.capture3('swift', 'package', '--package-path', ROOT, 'dump-package')
abort error unless status.success?
dependencies = JSON.parse(manifest).fetch('dependencies').map { |entry| entry['sourceControl']&.first }.compact
packages = ''
grpc = ''
dependencies.each do |dependency|
  url = dependency.fetch('location').fetch('remote').first.fetch('urlString')
  name = File.basename(url, '.git')
  requirement = dependency.fetch('requirement')
  if requirement.key?('exact')
    version = requirement.fetch('exact').first
    packages += "  #{name}:\n    url: #{url}\n    exactVersion: #{version}\n"
    grpc += "        .package(url: #{url.to_json}, exact: #{version.to_json}),\n" if url.start_with?('https://github.com/grpc/')
  else
    range = requirement.fetch('range').first
    lower, upper = range.fetch_values('lowerBound', 'upperBound')
    bounds = upper == "#{Integer(lower.split('.').first) + 1}.0.0" ? "from: #{lower}" : "minVersion: #{lower}\n    maxVersion: #{upper}"
    packages += "  #{name}:\n    url: #{url}\n    #{bounds}\n"
  end
end
replace_generated('project.yml', 'package requirements', packages)
replace_generated('Modules/NativeAgentCore/Package.swift', 'gRPC requirements', grpc)
