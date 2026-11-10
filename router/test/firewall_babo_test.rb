#!/usr/bin/env ruby
# Focused test: the Router's Babo forward rules.
#
# Run: ruby -Irouter/src router/test/firewall_babo_test.rb
# No Rails, no network, no root — Firewall renders nftables text; this reads it.
#
# The bug this guards: the Babo→Manager rule used the Router's OWN API port
# (router.api_port, 8080) instead of the Manager's HTTP port (9200), so the
# office UI's only path to the Manager pointed at a closed port.

require "minitest/autorun"
require_relative "../src/firewall"

class FirewallBaboTest < Minitest::Test
  def base_config(overrides = {})
    cfg = {
      "router"  => { "api_port" => 8080, "babo_port" => 8843 },
      "network" => {
        "host_ip" => "10.0.0.2",
        "manager_ip" => "10.0.0.3",
        "hub_ip" => "10.0.0.4",
        "babo_ip" => "10.0.0.5",
        "agent_subnet" => "10.1.0.0/16",
        "user_subnet" => "10.2.0.0/16"
      }
    }
    overrides.each { |k, v| cfg[k] = cfg[k].merge(v) }
    cfg
  end

  def rules(cfg)
    Firewall.new(cfg).babo_forward_rules
  end

  def test_babo_reaches_the_manager_http_port_not_the_router_api_port
    out = rules(base_config)
    assert_includes out, "ip saddr 10.0.0.5 ip daddr 10.0.0.3 tcp dport 9200 accept"
    refute_includes out, "tcp dport 8080 accept",
                    "Babo must not be allowed to the Router's own API port as if it were the Manager"
  end

  def test_manager_port_is_configurable_and_rendered
    out = rules(base_config("network" => { "manager_port" => 9443 }))
    assert_includes out, "tcp dport 9443 accept"
    refute_includes out, "tcp dport 9200 accept"
  end

  def test_host_may_reach_only_the_babo_ui_port
    out = rules(base_config)
    assert_includes out, "ip saddr 10.0.0.2 ip daddr 10.0.0.5 tcp dport 8843 accept"
    assert_equal 2, out.lines.size, "exactly two forward rules: host->UI, babo->Manager"
  end

  def test_no_babo_peer_means_no_rules_at_all
    out = rules(base_config("network" => { "babo_ip" => nil }))
    assert_equal "# no babo peer configured", out.strip
  end

  # init_base! shells out to nft; capture the rendered text instead of running it.
  def test_babo_rules_are_in_the_forward_chain_not_input
    fw = Firewall.new(base_config)
    captured = nil
    fw.define_singleton_method(:nft!) { |cmd| captured = cmd }
    fw.init_base!

    assert captured, "init_base! rendered nothing"
    start = captured.index("chain forward {")
    stop  = captured.index("goto agents")
    assert start && stop && stop > start, "forward chain not delimited by 'chain forward' -> 'goto agents'"
    forward = captured[start...stop]

    assert_includes forward, "10.0.0.2 ip daddr 10.0.0.5 tcp dport 8843 accept"
    assert_includes forward, "ip saddr 10.0.0.5 ip daddr 10.0.0.3 tcp dport 9200 accept"
  end
end
