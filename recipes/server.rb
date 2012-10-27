#
# Author:: Jesse Nelson <spheromak@gmail.com>
# Author:: Matt Ray <matt@opscode.com>
# Cookbook Name:: dhcp
# Recipe:: server
#
# Copyright 2011, Opscode, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe "helpers"


# assumes dns is working and this is a dhcp server for its dns domain.
dhcp_service = node[:dhcp][:service_name]
dhcp_dir = node[:dhcp][:dir]

package node[:dhcp][:package_name]

dhcp_failover = node[:dhcp][:failover]

directory dhcp_dir

# find masters and slave
if dhcp_failover 
  # are we master
  if node[:roles].include?("dhcp_master") 
    Chef::Log.info "Setting node to DHCP master"
    failover_role = "primary"
    slaves = scoped_search("domain", :node, "role:dhcp_slave")
    
    # disable failover if no slaves
    if slaves.blank?
      Chef::Log.info "No DHCP slaves found, disabling replication"
      dhcp_failover = nil
    else
      failover_peer = slaves.sort.first.ipaddress 
      Chef::Log.info "Found DHCP peer: #{failover_peer}"
    end
    
  else # nope we are a slave
    Chef::Log.info "Setting node to DHCP slave"
    failover_role = "secondary"
    master = scoped_search("domain", :node, "role:dhcp_master")
    
    # disable failover if no master
    if master.blank?
      Chef::Log.info "No DHCP masters found, disabling replicatoin"
      dhcp_failover = nil 
    else
      failover_peer =  master.sort.first.ipaddress 
      Chef::Log.info "Found DHCP peer: #{failover_peer}"
    end
  end
end


service dhcp_service do
  supports :restart => true, :status => true, :reload => true
  action [ :enable ]
  # use upstart on ubuntu > 9.10
  case node[:platform]
  when "ubuntu"
    if node[:platform_version].to_f >= 9.10
      provider Chef::Provider::Service::Upstart
    end
  end
end

template node[:dhcp][:init_config] do
  owner "root"
  group "root"
  mode 0644
  source "init_config.erb"
  variables(
    :interfaces => node['dhcp']['interfaces'],
    :var  =>  "DHCPDARGS"
  )
end

# setup global options for this dc/server 
# we have to have a DC bag cause it calls out the subnets that we should manage.
# as well as global dc_data["dhcpd"]s for said DC
Chef::Log.debug "Loading datacenters #{node[:domain]}"
dc_data = data_bag_item('datacenters', data_bag_fqdn(node[:domain]))
Chef::Log.debug "DCDATA: #{dc_data.inspect}"



# merge allows from bag  into node data, and sort
allows = node['dhcp']['allows'] || []
allows.push(dc_data['dhcpd']['allows']).flatten!
allows.uniq!
allows.sort!
Chef::Log.debug "allows: #{allows}"

# merge this out to Helpers lib 
# TODO: add something like this to Chef::Attribute
def merge_and_flatten(attribs, data)
  parameters = []
  parametersh = {}
  attribs.each {|k, v| parametersh[k] = v}
  parametersh.merge!(data)
  parametersh.each {|k, v| parameters.push("#{k} #{v}")}
  parameters.sort!
end

parameters = merge_and_flatten(node['dhcp']['parameters'], dc_data['dhcpd']['parameters'] )
# merge and collapse bag params into node params
Chef::Log.debug "parameters: #{parameters}"

options = merge_and_flatten(node[:dhcp][:options], dc_data['dhcpd']['options'] )
Chef::Log.debug "options: #{options}"

# for all the zones this dc has pull in the rndc_keys and push them out to dhcp config
# as well as the zone master ip for ddns to work
ddns = {}
rndc_keys = {}
dc_data["zones"].each do |zone|
  # load the zone 
  zone_data = data_bag_item('dns_zones', escape_bagname(zone) )
  name = zone_data["zone_name"]
  ddns[name] ||= {}
  
  # pull the master ip out 
  ddns[name]["master"] = zone_data["master_address"] 
end

template node[:dhcp][:config_file] do
  owner "root"
  group "root"
  mode 0644
  source "dhcpd.conf.erb"
  variables(
    :allows => allows,
    :parameters => parameters,
    :options => options,
    :ddns => ddns,
    :failover => dhcp_failover,
    :role => failover_role,
    :my_ip => node[:ipaddress],
    :peer_ip => failover_peer
    )
  action :create
  notifies :restart, resources(:service => dhcp_service), :delayed
end

directory "#{dhcp_dir}/groups.d"

# pull and setup groups
groups = []
unless dc_data["groups"].nil? or  dc_data["groups"].empty?
  dc_data["groups"].each do  |group|
    groups << group
    group_data = data_bag_item('dhcp_groups', group)
    
    Chef::Log.debug "Setting up Group: #{group_data.inspect}" 
    dhcp_group group do 
      parameters  group_data["parameters"]  || []
      hosts       group_data["hosts"] || [] 
      conf_dir  dhcp_dir
    end
  end 
end

template "#{dhcp_dir}/groups.d/group_list.conf" do
  owner "root"
  group "root"
  mode 0644
  source "list.conf.erb"
  variables(
    :item => "groups",
    :items => groups
    )
  action :create
  notifies :restart, resources(:service => dhcp_service), :delayed
end


directory "#{dhcp_dir}/subnets.d"

subnets = []
dc_data["subnets"].each do |net|
  net_bag = data_bag_item('dhcp_networks', escape_bagname(net) )
 
  # push this net onto the subnets 
  subnets << net_bag["address"]  
  
  Chef::Log.debug "Setting up Subnet: #{net_bag.inspect}" 
  # run the lwrp with the bag data
  dhcp_subnet net_bag["address"] do 
    broadcast net_bag["broadcast"]  
    netmask   net_bag["netmask"]
    routers   net_bag["routers"] || []
    options   net_bag["options"] || []
    range     net_bag["range"] || ""
    conf_dir  dhcp_dir
    peer  node[:domain] if dhcp_failover 
  end
end


# generate the config that links it all 
directory "#{dhcp_dir}/subnets.d"
template "#{dhcp_dir}/subnets.d/subnet_list.conf" do
  owner "root"
  group "root"
  mode 0644
  source "list.conf.erb"
  variables(
    :item => "subnets",
    :items => subnets.sort
    )
  action :create
  notifies :restart, resources(:service => dhcp_service), :delayed
end

# Hosts
# Grab called out hosts for datacenter and itterate/build each one
#
hosts = []
unless dc_data["hosts"].nil? or  dc_data["hosts"].empty?

  # special key to just use all hosts in dhcp_hosts databag
  # figure which hosts to load
  host_list = dc_data["hosts"]
  if dc_data["hosts"].downcase == "all" 
    host_list = data_bag('dhcp_hosts')
  end

  host_list.each do  |host|
    hosts << host
    host_data = data_bag_item('dhcp_hosts', host)

    Chef::Log.debug "Setting up Host: #{host_data.inspect}"
    dhcp_host host do
      hostname   host_data["hostname"] 
      macaddress host_data["macaddress"] 
      ipaddress  host_data["ipaddress"] 
      options    host_data["options"] || []
      conf_dir  dhcp_dir 
    end
  end
end

directory "#{dhcp_dir}/hosts.d"
template "#{dhcp_dir}/hosts.d/host_list.conf" do
  owner "root"
  group "root"
  mode 0644
  source "list.conf.erb"
  variables(
    :item => "hosts",
    :items => hosts
    )
  action :create
  notifies :restart, resources(:service => dhcp_service), :delayed
end
