# Copyright (c) 2010-2012, University of Manchester, UK
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
require "bundler/setup"
require 'open-uri'
require 'libxml'
require 'sinatra'
require 'haml'
require 't2flow/model'
require 't2flow/parser'
require 't2-server'
require 'mimemagic'
require 'ftools'
require 'yaml'
require 'atom'

include LibXML

set :port, 9494

$server = nil;
$server_uri = ""
$feed_uri = ""
$feed_ns = "http://ns.taverna.org.uk/2012/interaction"

$credentials = T2Server::HttpBasic.new("taverna", "taverna")

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
  packWorkflows = open("http://www.myexperiment.org/pack.xml?id=192&elements=internal-pack-items").read
  packWorkflowsXml = XML::Parser.string(packWorkflows).parse
  i = 1
  packWorkflowsXml.find("//workflow").each { |packItem|
    packItemUrl =  packItem.attributes["uri"]
    packItemText = open(packItemUrl).read
    packItemXml = XML::Parser.string(packItemText).parse
    packItemXml.find("//workflow").each { |workflowItem|
      workflowItemUrl = workflowItem.attributes["uri"]
      workflowItemText = open(workflowItemUrl).read
      workflowItemXml = XML::Parser.string(workflowItemText).parse
      workflowId = i
      i = i.next
      workflowItemXml.find("//content-uri").each { |workflowUri|
        workflowText = open(workflowUri.content).read
    	File.open(@workflowsDirectoryPath + "/" + workflowId.to_s + ".t2flow", 'w') { |f| f.write(workflowText)}    
      }
    }
  }
end

def show_port_value(portValue)
  if (portValue.error?) then
    portValue.error
  else
    value = portValue.value
    mimetype = MimeMagic.by_magic(value.to_s)
    if (mimetype == nil) then
      mimetype = 'text/plain'
    end
    content_type mimetype.to_s, :charset => 'utf-8'
    value
  end
end

def check_server()
  if (!defined?($server) || ($server == nil)) then
    settings = YAML.load(IO.read(File.join(File.dirname(__FILE__), "config.yaml")))
    if settings
      $server_uri = settings['server_uri']
      $feed_uri = settings['feed_uri'] + "?limit=1000"
      begin
       $server = T2Server::Server.new($server_uri)
      rescue Exception => e  
        $server = nil
        redirect '/no_configuration'
      end
    else
      redirect '/no_configuration'
    end
  end
end

def add_security(run)
  run.add_password_credential("http://heater.cs.man.ac.uk:7070/#Example+HTTP+BASIC+Authentication", "testuser", "testpasswd")
  run.add_password_credential("https://heater.cs.man.ac.uk:7070/#Example+HTTP+BASIC+Authentication", "testuser", "testpasswd")
  run.add_password_credential("https://heater.cs.man.ac.uk:7443/axis/services/HelloService-PlaintextPassword?wsdl", "testuser", "testpasswd")
  run.add_trust(Dir.getwd() + "/certificates/tomcat_heater_certificate.pem")
end

# This method simply returns the *first* entry in the interaction feed unless it
# is a reply - it is a MASSIVE BODGE.
def get_interaction(since)
  feed = Atom::Feed.load_feed(URI.parse($feed_uri))
  interaction = nil

  # Go through all the entries in reverse order and return the first which
  # does not have a reply.
  feed.each_entry do |entry|
    r_id = entry[$feed_ns, "in-reply-to"]
    if r_id.empty?
      interaction = entry
      puts "Found interaction " + interaction[$feed_ns, "id"][0]
    end
    break
  end

  # Return nil if there are no interactions
  return [nil, nil] if interaction.nil?

  # Get the interaction link from the feed entry
  interaction.links.each do |link|
    if link.rel == "presentation"
      return [interaction[$feed_ns, "id"][0], link.to_s]
    end
  end

  # Should not get here but return nil just in case...
  [nil, nil]
end

def check_for_reply(id)
  feed = Atom::Feed.load_feed(URI.parse($feed_uri))
  feed.each_entry do |entry|
    return true if entry[$feed_ns, "in-reply-to"][0] == id
  end

  false
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
  puts $server
  puts $credentials
  all_runs = $server.runs($credentials)
  all_runs.each { |r|
    if (r.finished?) then
      finished_runs.push(r)
    else
      current_runs.push(r)
    end
  }
  current_runs.sort! {|x,y| y.create_time().to_s <=> x.create_time().to_s}
  finished_runs.sort! {|x,y| y.create_time().to_s <=> x.create_time().to_s}
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
  if (model.sources().size == 0) then
    run = $server.create_run(workflowContent, $credentials)
    add_security(run)
    run.start()
    redirect "/run/#{run.identifier}"
  else 
    name = get_name(model)
    sources = {}
    model.sources().each { |source|
      example_values = source.example_values
      if ((!example_values.nil?) && (example_values.size == 1)) then
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
  run = $server.create_run(workflowContent, $credentials)
  model.sources().each { |source|
    run.input_port(source.name).value = params[source.name]
  }
  add_security(run)
  run.start()
  redirect "/run/#{run.identifier}"
end

get '/run/:runid' do
  check_server()
  run = $server.run(params[:runid], $credentials)

  interaction_id, interaction_uri = get_interaction(run.start_time)

  haml :run, :locals => {:title => "Run " + run.identifier, :run => run, :run_id => run.identifier,
    :interaction_id => interaction_id, :interaction_uri => interaction_uri,
    :refresh => true}
end

get '/run/:runid/delete' do
  check_server()
  begin
    $server.delete_run(params[:runid], $credentials)
  rescue Exception => e
    # Do not know what to do
  end
  redirect '/runs'
end

get '/runs/delete_all' do
  check_server()
  $server.delete_all_runs($credentials)
  redirect '/runs'
end

get '/run/:runid/resultset' do
  check_server()
  run = $server.run(params[:runid], $credentials)
  runid = params[:runid]
  haml :resultset, :locals => {:title => "Results for run " + runid, :runid => runid, :outputs => run.output_ports}
end

get '/run/:runid/error' do
  check_server()
  runid = params[:runid]
  run = $server.run(runid, $credentials)
  error = run.stderr
  haml :run_error, :locals => {:title => "Server error for run " + runid, :error => error}
end

get '/run/:runid/result/:portname' do
  check_server()
  run = $server.run(params[:runid], $credentials)
  puts "portname is " + params[:portname]
  o = run.output_ports[params[:portname]]
  show_port_value(o)
end

get '/run/:runid/result/:portname/:indices' do
  check_server()
  run = $server.run(params[:runid], $credentials)
  o = run.output_ports[params[:portname]]
  indices = params[:indices]
  if indices.match(/^-/)
    indices = indices[1..-1]
  end
  indices.split('-').each do |i|
    puts "i is "
    puts i
    puts o
    o = o[i.to_i]
  end
  show_port_value(o)
end

get '/configuration' do
  haml :configuration, :locals => {:title => "Configuration", :server_uri => $server_uri, :feed_uri => $feed_uri}
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
    puts $server_uri
    $server = T2Server::Server.new($server_uri)
  rescue Exception => e
    puts e.message
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

get '/:runid/interaction/:intid' do
  run = $server.run(params[:runid], $credentials)

  top_id, top_url = get_interaction(run.start_time)

  unless top_id == params[:intid]
    headers["X-taverna-superseded"] = "true"
  end

  204
end
