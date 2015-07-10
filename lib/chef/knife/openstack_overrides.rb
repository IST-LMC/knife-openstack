require 'chef/knife'
require 'chef/knife/ssh'
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
          (addresses.values.first || []).find { |x| x['addr'] !~ /^10\..*$/ } || {}
        end

        def private_ip_address
          (addresses.values.first || []).find { |x| x['addr'] =~ /^10\..*$/ } || {}
        end
      end
    end
  end
end

# Grab the --pass-openstack-environment option from the command line if it's there,
# and set that on Chef::Config[:knife] so that we can access it in our redefinition
# of Net::SSH.configuration_for below.
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
          Chef::Config[:knife][:pass_openstack_environment] = if config[:pass_openstack_environment]
            config[:pass_openstack_environment]
          else
            Chef::Config[:knife][:pass_openstack_environment]
          end
          ssh_command_without_environment_variables(command, subsession)
        end
        alias_method :ssh_command_without_environment_variables, :ssh_command
        alias_method :ssh_command, :ssh_command_with_environment_variables
      end
    end
  end
end

# Add OS_* to the SendEnv ssh option if we've turned on the knife option to pass
# the OpenStack environment.
module Net
  module SSH
    class << self
      if !method_defined?(:configuration_for_with_environment_variables)
        def configuration_for_with_environment_variables(host, use_ssh_config=true)
          ssh_config = configuration_for_without_environment_variables(host, use_ssh_config)
          if Chef::Config[:knife][:pass_openstack_environment]
            ssh_config[:send_env] = ssh_config[:send_env] + [/^OS_.*$/]
          end
          ssh_config
        end
        alias_method :configuration_for_without_environment_variables, :configuration_for
        alias_method :configuration_for, :configuration_for_with_environment_variables
      end
    end
  end
end
