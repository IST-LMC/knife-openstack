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
