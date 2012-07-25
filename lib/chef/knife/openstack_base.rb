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
        command_line_config[key] || Chef::Config[:knife][key] || config[key]
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


      def command_line_config
        if !@command_line_config
          @command_line_config = {}

          alt_regex = /\[(.*)\]/
          options.each do |opt_name, opt_def|
            boolean_value = nil
            arg_index = nil

            if opt_def[:long]
              arg_index = ARGV.index(opt_def[:long].split(/\s/).first.gsub(alt_regex,''))
              if arg_index
                boolean_value = true
              else
                arg_index = ARGV.index(opt_def[:long].split(/\s/).first.gsub(alt_regex,'\1')) if opt_def[:long]
                boolean_value = false
              end
            else
              arg_index = ARGV.index(opt_def[:short].split(/\s/).first) if opt_def[:short]
            end

            if arg_index
              opt_value = opt_def[:boolean] ? boolean_value : ARGV[arg_index + 1]
              @command_line_config[opt_name] = opt_value
              Chef::Log.debug("***command line override*** #{opt_name}: #{opt_value}")
            end
          end
        end
        @command_line_config
      end
    end
  end
end


