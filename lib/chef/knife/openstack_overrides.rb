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

# Add functionality which allows us to pass along the OpenStack environment that's set up
# via the knife.rb configuration and set it as environment variables that live only for
# the scope of the knife ssh or knife bootstrap run (unless one of those starts chef-client
# in a periodic daemonized mode).
class Chef
  class Knife
    class Ssh < Knife      
      option :pass_openstack_environment,
        :long => "--pass-openstack-environment",
        :description => "Pass the openstack environment (defined in your knife.rb) along as environment variables when running chef-client through knife ssh",
        :boolean => true,
        :default => false
      
      if !method_defined?(:ssh_command_with_environment_variables)
        def ssh_command_with_environment_variables(command, subsession=nil)
          pass_openstack_environment = config[:pass_openstack_environment] || Chef::Config[:knife][:pass_openstack_environment]
          if !pass_openstack_environment
            ssh_command_without_environment_variables(command, subsession)
          else
            environment_settings = [
              "OS_PASSWORD=#{Chef::Config[:knife][:openstack_password]}",
              "OS_AUTH_URL=#{Chef::Config[:knife][:openstack_auth_url]}",
              "OS_USERNAME=#{Chef::Config[:knife][:openstack_username]}",
              "OS_TENANT_NAME=#{Chef::Config[:knife][:openstack_tenant]}"
            ]

            # Bootstrap calls will run as the root user with this command, and the chef-client call is made
            # inside the bootstrap script, so we want to export the environment variables for that.
            augmented_command = environment_settings.map { | env_setting | "export #{env_setting}; " }.join
            # Regular knife ssh calls from the command line may not start out as the root user and instead
            # sudo the chef-client command. In this case, make sure to make settings that will be picked up
            # by ruby before any call.
            augmented_command += command.gsub("chef-client", "#{environment_settings.join(' ')} chef-client")
          
            ssh_command_without_environment_variables(augmented_command, subsession)
          end
        end
        alias_method :ssh_command_without_environment_variables, :ssh_command
        alias_method :ssh_command, :ssh_command_with_environment_variables
      end
    end
  end
end