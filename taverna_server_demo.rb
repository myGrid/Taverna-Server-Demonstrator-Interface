# Copyright (c) 2010, University of Manchester, UK
# 
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
# 
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above
#       copyright notice, this list of conditions and the following
#       disclaimer in the documentation and/or other materials provided
#       with the distribution.
#     * Neither the name of the University of Manchester nor the names
#       of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written
#       permission. 
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require 'rubygems'

require 'open-uri'
require 'libxml'

require 'sinatra'
require 'haml'

gem 'taverna-t2flow'

require 't2flow/model'
require 't2flow/parser'

require 't2server'

require 'mimemagic'

require 'ftools'

include LibXML

require 'yaml'

$server = nil;
$server_uri = ""

# Change this value to allow users to upload new workflows
$allow_upload = false;

def get_name(model)
      return nil if model.nil?
      if model.annotations.name.empty? || model.annotations.name=~/^(workflow|dataflow)\d*$/i
        if model.annotations.titles.nil? || model.annotations.titles.empty?
          return model.main.name
        else
          model.annotations.titles[0]
        end
      else
        model.annotations.name
      end
    end

def fetch_workflows()
  packWorkflows = open("http://www.myexperiment.org/pack.xml?id=122&elements=internal-pack-items").read
  packWorkflowsXml = XML::Parser.string(packWorkflows).parse
  packWorkflowsXml.find("//workflow").each { |packItem|
    packItemUrl =  packItem.attributes["uri"]
    packItemText = open(packItemUrl).read
    packItemXml = XML::Parser.string(packItemText).parse
    packItemXml.find("//workflow").each { |workflowItem|
      workflowItemUrl = workflowItem.attributes["uri"]
      workflowItemText = open(workflowItemUrl).read
      workflowItemXml = XML::Parser.string(workflowItemText).parse
      workflowId = workflowItemXml.find_first("//id").content
      workflowItemXml.find("//content-uri").each { |workflowUri|
        workflowText = open(workflowUri.content).read
    	File.open(@workflowsDirectoryPath + "/" + workflowId + ".t2flow", 'w') { |f| f.write(workflowText)}    
      }
    }
  }
end

def check_server()
  if (!defined?($server) || ($server == nil)) then
    settings = YAML.load(IO.read(File.join(File.dirname(__FILE__), "config.yaml")))
    if settings
      $server_uri = settings['server_uri']
      begin
       $server = T2Server::Server.connect($server_uri)
      rescue Exception => e  
        $server = nil
        redirect '/no_configuration'
      end
    else
      redirect '/no_configuration'
    end
  end
end

get '/no_configuration' do
  haml :no_configuration, :locals => {:title => "No configuration"}
end

get '/' do
#  check_server()
  haml :index, :locals => {:title => "Taverna Server"}
end

get '/workflows' do
  begin
    @workflowsDirectoryPath = Dir.getwd() + "/workflows"
    workflowsDirectory = Dir.open(@workflowsDirectoryPath)
  rescue SystemCallError
    workflowsDirectory = Dir.mkdir(@workflowsDirectoryPath)
  end
  workflowMap = {}
  workflows = Dir.glob(@workflowsDirectoryPath + "/*.t2flow")
  if (workflows.empty?) then
    fetch_workflows()
    workflows = Dir.glob(@workflowsDirectoryPath + "/*.t2flow")
  end  
  workflows.each {|f|
    model = T2Flow::Parser.new.parse(File.open(f))
    name = get_name(model)
    number = f[(f.rindex('/') + 1) .. (f.length() -8)]
    workflowMap[name] = number;
  }
  haml :workflows, :locals => {:title => "Workflows", :workflow_map => workflowMap}
end

post '/workflows' do
  workflow = params[:workflow]
  tempfile = workflow[:tempfile]
  filename = workflow[:filename]
  @workflowsDirectoryPath = Dir.getwd() + "/workflows"
  File.open(@workflowsDirectoryPath + "/" + filename, 'w') { |f| f.write(tempfile.read) }
  redirect '/workflows'
end

get '/runs' do
  check_server()
  current_runs = []
  finished_runs = []
  $server.runs.each { |r|
    if (r.finished?) then
      finished_runs.push(r)
    else
      current_runs.push(r)
    end
  }
  current_runs.sort! {|x,y| y.create_time().to_s <=> x.create_time().to_s}
  finished_runs.sort! {|x,y| y.create_time() <=> x.create_time()}
  haml :runs, :locals => {:title => "Runs", :current_runs => current_runs, :finished_runs => finished_runs, :refresh => true}
end

get '/workflow/:number' do
  check_server()
  filePath = Dir.getwd() + "/workflows/" + params[:number] + ".t2flow";
  model = T2Flow::Parser.new.parse(File.open(filePath))
  name = get_name(model)
  annotation = model.main.annotations
  p $fred
  haml :workflow, :locals => {:title => name, :name => name, :annotation => annotation, :number => params[:number]}
end

get '/workflow/:number/newrun' do
  check_server()
  filePath = Dir.getwd() + "/workflows/" + params[:number] + ".t2flow";
  workflowContent =  open(filePath).read
  model = T2Flow::Parser.new.parse(File.open(filePath))
  if (model.all_sources().size == 0) then
    run = $server.create_run(workflowContent)
    run.start()
    redirect "/run/#{run.uuid}"
  else 
    name = get_name(model)
    sources = {}
    model.all_sources().each { |source|
      example_values = source.example_values
      if (defined?(example_values) && (example_values.size == 1)) then
        sources[source.name] = example_values[0]
      else
        sources[source.name] = ""
      end
    }
    haml :newrun, :locals => {:title => "New run of " + name, :name => name, :sources => sources}
  end
end

post '/workflow/:number/newrun' do
  check_server()
  filePath = Dir.getwd() + "/workflows/" + params[:number] + ".t2flow";
  workflowContent =  open(filePath).read
  model = T2Flow::Parser.new.parse(File.open(filePath))
  run = $server.create_run(workflowContent)
  model.all_sources().each { |source|
    tf = Tempfile.new("t2server")
    tf.write(params[source.name])
    tf.close
    run.upload_input_file(source.name, tf.path)
  }
  run.start()
  redirect "/run/#{run.uuid}"
end

get '/run/:runid' do
  check_server()
  run = $server.run(params[:runid])
  haml :run, :locals => {:title => "Run " + run.uuid, :run => run, :refresh => true}
end

get '/run/:runid/delete' do
  check_server()
  begin
    $server.delete_run(params[:runid])
  rescue Exception => e
    # Do not know what to do
  end
  redirect '/runs'
end

get '/runs/delete_all' do
  check_server()
  $server.delete_all_runs()
  redirect '/runs'
end

def get_results(run, dir="")
  result = {}
  dirs,files = run.ls("out#{dir}")
  dirs.each {|d| result[d] = get_results(run, "#{dir}/#{d}") }
  files.each do |f|
    if dir == ""
      output_name = f
    else
      output_name = "#{dir[1..-1]}/#{f}"
    end
    result [f] = output_name
  end
  result
end

get '/run/:runid/resultset' do
  check_server()
  run = $server.run(params[:runid])
  begin
    resultMap = get_results(run)
  rescue Exception => e
    resultMap = {}
  end
  sinks = {}
  resultMap.each { |k, v| sinks[k] = v }
  runid = params[:runid]
  haml :resultset, :locals => {:title => "Results for run " + runid, :runid => runid, :sinks => sinks}
end

get '/run/:runid/error' do
  check_server()
  runid = params[:runid]
  run = $server.run(runid)
  error = run.stderr
  haml :run_error, :locals => {:title => "Server error for run " + runid, :error => error}
end

get '/run/:runid/result/*' do
  check_server()
  run = $server.run(params[:runid])
  value = run.get_output(params[:splat][0])
  mimetype = MimeMagic.by_magic(value.to_s)
  if (mimetype == nil) then
    mimetype = 'text/plain'
  end
  content_type mimetype.to_s, :charset => 'utf-8'
  value
end

get '/configuration' do
  haml :configuration, :locals => {:title => "Configuration", :server_uri => $server_uri}
end

get '/badconfiguration' do
  haml :configuration, :locals => {:title => "Configuration", :server_uri => $server_uri, :problem => true}
end

post '/configuration' do
  $server_uri = params['server_uri']
  if ($server_uri =~ /.*\/$/) then
    $server_uri = $server_uri[0..$server_uri.length-2]
  end
  if ($server_uri =~ /.*\/rest$/) then
    $server_uri = $server_uri[0..$server_uri.length-6]
  end
  begin
    $server = T2Server::Server.connect($server_uri)
  rescue Exception => e
    $server = nil
    redirect '/badconfiguration'
  end    
  settings_hash = {}
  settings_hash['server_uri'] = $server_uri
  File.open(File.join(File.dirname(__FILE__), "config.yaml"), 'w') do |fout|
    YAML.dump(settings_hash, fout)
  end
  redirect '/'
end

