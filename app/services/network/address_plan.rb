# frozen_string_literal: true

# NeoClaw address plan (docs/NETWORK.md, commit e482986):
#
#   10.0.0.0/24  infrastructure: Router .1, Host .2, Manager .3
#   10.1.0.0/16  agents (one /32 per agent pod)
#   10.2.0.0/16  users
#
# The Manager owns this plan. The Router is told its address and its
# agent_network string; it is never told what they mean.
module Network
  module AddressPlan
    INFRA_NET  = "10.0.0.0/24"
    AGENT_NET  = "10.1.0.0/16"
    USER_NET   = "10.2.0.0/16"

    ROUTER_IP  = "10.0.0.1"
    HOST_IP    = "10.0.0.2"
    MANAGER_IP = "10.0.0.3"

    WG_PORT    = 51820
    WG_MTU     = 1420

    # First agent address handed out; increments by one per agent.
    FIRST_AGENT_IP = "10.1.0.1"

    class << self
      def next_agent_ip(used_ips)
        base = FIRST_AGENT_IP.split(".").map(&:to_i)
        used = used_ips.to_a
        loop do
          candidate = base.join(".")
          return candidate unless used.include?(candidate)
          base[3] += 1
          raise "agent address space exhausted in /24 slice" if base[3] > 254
        end
      end
    end
  end
end
