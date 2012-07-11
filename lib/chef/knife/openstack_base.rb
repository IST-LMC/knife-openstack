#
# Author:: Seth Chisamore (<schisamo@opscode.com>)
# Author:: Matt Ray (<matt@opscode.com>)
# Copyright:: Copyright (c) 2011-2012 Opscode, Inc.
# License:: Apache License, Version 2.0
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

require 'chef/knife'
require 'fog'
require 'fog/compute/models/server'
require 'fog/openstack/models/compute/server'

# Implementation Note!!!
#
# This is a horrible but necessary patch of the fog 1.4 gem, which tries to work around
# the fact that OpenStack Essex doesn't return public/private IPs separately by assuming
# that if there's no addresses['public'] and addresses['private'] in the returned JSON
# after creating a server, that there will be an addresses['internet'] hash. (See here
# for further details: https://github.com/fog/fog/pull/933). There actually doesn't seem
# to be any standard at all as to what key your network address falls under, as it is
# just a label that can be set arbitrarily when creating the network. Furthermore, there's
# an assumption being made that the first address will be private and the last public (and
# consequently that there will only ever be 2 addresses in the list). Our solution below
# isn't much better, but it looks a little more explicitly for a "private" style address,
# which, at least in all of our implementations, always starts with a "10.". This is not
# something we'd even expect to be accepted upstream, of course, as it is fairly dependent
# on our own standard implementation details and not necessarily ones shared by the rest
# of the OpenStack community.
#
# Ideally, there should be a more explicit way to tell whether an address is public/private
# being returned from the OpenStack api call. Here's where the addresses are getting flattened:
# https://github.com/openstack/nova/blob/bb867ce3948ddc23cf928ca3dda100a1a977896a/nova/api/openstack/compute/views/addresses.py#L43
# This is probably also where an extra attribute could be added to allow you to "unflatten" them
# when necessary, and this could then be used to reliably separate public and private IP
# in the fog gem.
#
# TODO: Figure out the best place(s) to start this discussion.
module Fog
  module Compute
    class OpenStack
      class Server < Fog::Compute::Server
        def public_ip_address
          addresses.values.first.find { |x| x['addr'] !~ /^10\..*$/ } || {}
        end

        def private_ip_address
          addresses.values.first.find { |x| x['addr'] =~ /^10\..*$/ } || {}
        end
      end
    end
  end
end

class Chef
  class Knife
    module OpenstackBase

      # :nodoc:
      # Would prefer to do this in a rational way, but can't be done b/c of
      # Mixlib::CLI's design :(
      def self.included(includer)
        includer.class_eval do

          deps do
            require 'fog'
            require 'readline'
            require 'chef/json_compat'
          end

          option :openstack_username,
            :short => "-A USERNAME",
            :long => "--openstack-username KEY",
            :description => "Your OpenStack Username",
            :proc => Proc.new { |key| Chef::Config[:knife][:openstack_username] = key }

          option :openstack_password,
            :short => "-K SECRET",
            :long => "--openstack-password SECRET",
            :description => "Your OpenStack Password",
            :proc => Proc.new { |key| Chef::Config[:knife][:openstack_password] = key }

          option :openstack_tenant,
            :short => "-T NAME",
            :long => "--openstack-tenant NAME",
            :description => "Your OpenStack Tenant NAME",
            :proc => Proc.new { |key| Chef::Config[:knife][:openstack_tenant] = key }

          option :openstack_auth_url,
            :long => "--openstack-api-endpoint ENDPOINT",
            :description => "Your OpenStack API endpoint",
            :proc => Proc.new { |endpoint| Chef::Config[:knife][:openstack_auth_url] = endpoint }
        end
      end

      def connection
        Chef::Log.debug("openstack_username #{Chef::Config[:knife][:openstack_username]}")
        Chef::Log.debug("openstack_auth_url #{Chef::Config[:knife][:openstack_auth_url]}")
        Chef::Log.debug("openstack_tenant #{Chef::Config[:knife][:openstack_tenant]}")
        @connection ||= begin
          connection = Fog::Compute.new(
            :provider => 'OpenStack',
            :openstack_username => Chef::Config[:knife][:openstack_username],
            :openstack_api_key => Chef::Config[:knife][:openstack_password],
            :openstack_auth_url => Chef::Config[:knife][:openstack_auth_url],
            :openstack_tenant => Chef::Config[:knife][:openstack_tenant]
          )
        end
      end

      def locate_config_value(key)
        key = key.to_sym
        Chef::Config[:knife][key] || config[key]
      end

      def msg_pair(label, value, color=:cyan)
        if value && !value.to_s.empty?
          puts "#{ui.color(label, color)}: #{value}"
        end
      end

      def validate!(keys=[:openstack_username, :openstack_password, :openstack_auth_url])
        errors = []

        keys.each do |k|
          pretty_key = k.to_s.gsub(/_/, ' ').gsub(/\w+/){ |w| (w =~ /(ssh)|(aws)/i) ? w.upcase  : w.capitalize }
          if Chef::Config[:knife][k].nil?
            errors << "You did not provided a valid '#{pretty_key}' value."
          end
        end

        if errors.each{|e| ui.error(e)}.any?
          exit 1
        end
      end

    end
  end
end


