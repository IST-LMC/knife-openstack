#
# Author:: Seth Chisamore (<schisamo@opscode.com>)
# Copyright:: Copyright (c) 2011 Opscode, Inc.
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

require 'chef/knife/openstack_base'

class Chef
  class Knife
    class OpenstackServerCreate < Knife

      include Knife::OpenstackBase

      deps do
        require 'fog'
        require 'readline'
        require 'chef/json_compat'
        require 'chef/knife/bootstrap'
        Chef::Knife::Bootstrap.load_deps
      end

      banner "knife openstack server create (options)"

      attr_accessor :initial_sleep_delay

      option :flavor,
        :short => "-f FLAVOR",
        :long => "--flavor FLAVOR",
        :description => "The flavor of server (m1.small, m1.medium, etc)",
        :proc => Proc.new { |f| Chef::Config[:knife][:flavor] = f }

      option :image,
        :short => "-I IMAGE",
        :long => "--image IMAGE",
        :description => "The AMI for the server",
        :proc => Proc.new { |i| Chef::Config[:knife][:image] = i }

      option :security_groups,
        :short => "-G X,Y,Z",
        :long => "--groups X,Y,Z",
        :description => "The security groups for this server",
        :default => ["default"],
        :proc => Proc.new { |groups| groups.split(',') }

      option :availability_zone,
        :short => "-Z ZONE",
        :long => "--availability-zone ZONE",
        :description => "The Availability Zone",
        :proc => Proc.new { |key| Chef::Config[:knife][:availability_zone] = key }

      option :chef_node_name,
        :short => "-N NAME",
        :long => "--node-name NAME",
        :description => "The Chef node name for your new node"

      option :ssh_key_name,
        :short => "-S KEY",
        :long => "--ssh-key KEY",
        :description => "The OpenStack SSH key id",
        :proc => Proc.new { |key| Chef::Config[:knife][:openstack_ssh_key_id] = key }

      option :ssh_user,
        :short => "-x USERNAME",
        :long => "--ssh-user USERNAME",
        :description => "The ssh username",
        :proc => Proc.new { |user| Chef::Config[:knife][:ssh_user] = user },
        :default => "root"

      option :ssh_password,
        :short => "-P PASSWORD",
        :long => "--ssh-password PASSWORD",
        :description => "The ssh password"

      option :identity_file,
        :short => "-i IDENTITY_FILE",
        :long => "--identity-file IDENTITY_FILE",
        :description => "The SSH identity file used for authentication"

      option :prerelease,
        :long => "--prerelease",
        :description => "Install the pre-release chef gems"

      option :bootstrap_version,
        :long => "--bootstrap-version VERSION",
        :description => "The version of Chef to install",
        :proc => Proc.new { |v| Chef::Config[:knife][:bootstrap_version] = v }

      option :distro,
        :short => "-d DISTRO",
        :long => "--distro DISTRO",
        :description => "Bootstrap a distro using a template",
        :proc => Proc.new { |d| Chef::Config[:knife][:distro] = d },
        :default => "ubuntu10.04-gems"

      option :template_file,
        :long => "--template-file TEMPLATE",
        :description => "Full path to location of template to use",
        :proc => Proc.new { |t| Chef::Config[:knife][:template_file] = t },
        :default => false

      option :run_list,
        :short => "-r RUN_LIST",
        :long => "--run-list RUN_LIST",
        :description => "Comma separated list of roles/recipes to apply",
        :proc => lambda { |o| o.split(/[\s,]+/) },
        :default => []

      option :no_host_key_verify,
        :long => "--no-host-key-verify",
        :description => "Disable host key verification",
        :boolean => true,
        :default => false

      option :ssh_gateway,
        :short => "-G GATEWAY",
        :long => "--ssh-gateway GATEWAY",
        :description => "The ssh gateway",
        :proc => Proc.new { |g| Chef::Config[:knife][:ssh_gateway] = g },
        :default => nil

      def tcp_test_ssh(hostname)
        tcp_socket = nil
        readable = false
        banner = nil

        # Initialize the SSH gateway if it has been specified in knife.rb
        ensure_configured_gateway

        if @default_gateway
          # Shuts down the local port after the block is run
          begin
            Chef::Log.debug("ssh connecting... (#{hostname}, #{locate_config_value(:ssh_user)}, #{Chef::Config[:knife][:ssh_identity_file]})")
            @default_gateway.ssh(hostname, locate_config_value(:ssh_user), :timeout => 5, :keys => [ Chef::Config[:knife][:ssh_identity_file] ]) do |ssh|
              Chef::Log.debug("ssh connected: #{readable}")
              readable = true
            end
          rescue Net::SSH::Disconnect => e
            # TODO: Make this a lot more elegant
            #
            # The gateway gets messed up in this case, but if we do connect via ssh, we guarantee that the connection's good...
            # So really, we should be establishing the gateway, doing the check, and shutting it down every time. And all that's
            # probably best done in a gateway_test_ssh method, separate from this one.
            #
            # The one downside is that we may give misleading error messages when ssh keys, etc. are bad, because the TCP socket
            # method does not require them and explicitly tests the connection. The problem with it is that it's not good at
            # indicating connection problems through the gateway.
            @default_gateway = nil
            ensure_configured_gateway
            Chef::Log.debug("ssh disconnected: #{e}")
            sleep 2
            return false
          rescue Timeout::Error => e
            Chef::Log.debug("ssh disconnected: #{e}")
            sleep 2
            return false
          end
        else
          tcp_socket = TCPSocket.new(hostname, 22)
          readable = IO.select([tcp_socket], nil, nil, 5)
          banner = tcp_socket.gets if readable
        end
        
        if readable
          gateway_info = @default_gateway ? " via gateway: #{locate_config_value(:ssh_gateway)}" : ""
          Chef::Log.debug("sshd accepting connections on #{hostname}#{gateway_info}, banner is #{banner}")
          
          # Need to do this before the yield block so that we don't shut the potential gateway connection down 
          # partway through. If using a gateway, it will ensure that the local port is shut down.
          unless @default_gateway
            tcp_socket && tcp_socket.shutdown rescue nil
          end

          yield

          true
        else
          false
        end
      rescue Errno::ETIMEDOUT
        false
      rescue Errno::EPERM
        false
      rescue Errno::ECONNREFUSED
        sleep 2
        false
      rescue Errno::EHOSTUNREACH
        sleep 2
        false
      rescue SocketError => e
        sleep 2
        false
      ensure
        unless @default_gateway
          tcp_socket && tcp_socket.shutdown rescue nil
        end
      end

      def ensure_configured_gateway
        gateway_config = locate_config_value(:ssh_gateway)
        if gateway_config && !@default_gateway
          gw_host, gw_user = gateway_config.split('@').reverse
          gw_host, gw_port = gw_host.split(':')
          gw_opts = gw_port ? { :port => gw_port } : {}

          @default_gateway = Net::SSH::Gateway.new(gw_host, gw_user || locate_config_value(:ssh_user), gw_opts)
        end
      end

      def run
        $stdout.sync = true

        validate!

        connection = Fog::Compute.new(
          :provider => 'AWS',
          :aws_access_key_id => Chef::Config[:knife][:openstack_access_key_id],
          :aws_secret_access_key => Chef::Config[:knife][:openstack_secret_access_key],
          :endpoint => Chef::Config[:knife][:openstack_api_endpoint],
          :region => locate_config_value(:region)
        )

        server_def = {
          :image_id => locate_config_value(:image),
          :groups => config[:security_groups],
          :flavor_id => locate_config_value(:flavor),
          :key_name => Chef::Config[:knife][:openstack_ssh_key_id],
          :availability_zone => Chef::Config[:knife][:availability_zone]
        }

        server = connection.servers.create(server_def)

        msg_pair("Instance ID", server.id)
        msg_pair("Flavor", server.flavor_id)
        msg_pair("Image", server.image_id)
        msg_pair("Region", connection.instance_variable_get(:@region))
        msg_pair("Availability Zone", server.availability_zone)
        msg_pair("Security Groups", server.groups.join(", "))
        msg_pair("SSH Key", server.key_name)

        print "\n#{ui.color("Waiting for server", :magenta)}"

        # wait for it to be ready to do stuff
        server.wait_for { print "."; ready? }

        puts("\n")

        msg_pair("Public DNS Name", server.dns_name)
        msg_pair("Public IP Address", server.public_ip_address)
        msg_pair("Private DNS Name", server.private_dns_name)
        msg_pair("Private IP Address", server.private_ip_address)

        print "\n#{ui.color("Waiting for sshd", :magenta)}"

        print(".") until tcp_test_ssh(server.dns_name) {
          sleep @initial_sleep_delay ||= 10
          puts("done")
        }
        
        bootstrap_retries = 3
        begin
          bootstrap_for_node(server).run
        rescue Net::SSH::Disconnect => e
          bootstrap_retries -= 1
          if bootstrap_retries >= 0
            puts "disconnected... retrying bootstrap (attempts left: #{bootstrap_retries})"
            sleep 5
            retry
          else
            raise e
          end
        end

        puts "\n"
        msg_pair("Instance ID", server.id)
        msg_pair("Flavor", server.flavor_id)
        msg_pair("Image", server.image_id)
        msg_pair("Region", connection.instance_variable_get(:@region))
        msg_pair("Availability Zone", server.availability_zone)
        msg_pair("Security Groups", server.groups.join(", "))
        msg_pair("SSH Key", server.key_name)
        msg_pair("Public DNS Name", server.dns_name)
        msg_pair("Public IP Address", server.public_ip_address)
        msg_pair("Private DNS Name", server.private_dns_name)
        msg_pair("Private IP Address", server.private_ip_address)
        msg_pair("Environment", config[:environment] || '_default')
        msg_pair("Run List", config[:run_list].join(', '))

        @default_gateway.shutdown! if @default_gateway.active?
      end

      def bootstrap_for_node(server)
        bootstrap = Chef::Knife::Bootstrap.new
        bootstrap.name_args = [server.dns_name]
        bootstrap.config[:run_list] = config[:run_list]
        bootstrap.config[:ssh_user] = locate_config_value(:ssh_user)
        bootstrap.config[:identity_file] = config[:identity_file]
        bootstrap.config[:chef_node_name] = config[:chef_node_name] || server.id
        bootstrap.config[:prerelease] = config[:prerelease]
        bootstrap.config[:bootstrap_version] = locate_config_value(:bootstrap_version)
        bootstrap.config[:distro] = locate_config_value(:distro)
        bootstrap.config[:use_sudo] = true unless locate_config_value(:ssh_user) == 'root'
        bootstrap.config[:template_file] = locate_config_value(:template_file)
        bootstrap.config[:environment] = config[:environment]
        # may be needed for vpc_mode
        bootstrap.config[:no_host_key_verify] = config[:no_host_key_verify]
        bootstrap
      end

      def ami
        @ami ||= connection.images.get(locate_config_value(:image))
      end

      def validate!

        super([:image, :openstack_ssh_key_id, :openstack_access_key_id, :openstack_secret_access_key, :openstack_api_endpoint])

        if ami.nil?
          ui.error("You have not provided a valid image (AMI) value.  Please note the short option for this value recently changed from '-i' to '-I'.")
          exit 1
        end
      end

    end
  end
end
