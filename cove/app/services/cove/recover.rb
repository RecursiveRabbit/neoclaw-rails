module Cove
  # A pod's peer identity, recovered from the pod.
  #
  # A pod's private key is generated at launch, used by `wg set private-key` from a
  # throwaway path, and discarded (spec §2/§13: "a reborn pod cannot inherit its
  # predecessor's identity; there is nothing to inherit"). The Manager therefore keeps
  # only the PUBLIC half, in the sheet — and the sheet is a document, which means it can
  # be wrong, blank, or truncated by a partial write.
  #
  # When that happens the consequence is not a cosmetic one. `Plan.network_map` renders a
  # peer only when the sheet has BOTH an address and a public key, so a sheet that loses
  # its key renders as absent, the Router subtracts the peer on the next apply, and a
  # LIVE pod goes dark. Measured on z620 2026-11-22: blanking one sheet's `pubkey` with
  # its pod running took `router.conf` from 1 peer to 0 — twice, on two consecutive
  # renders — with the pod still up and no error reported anywhere. Nothing on this board
  # otherwise costs production state when it fails.
  #
  # And the loss is recoverable, because the pod is the only authority on its own public
  # key: `wg show wg0 public-key` inside the pod returns exactly the value the sheet lost.
  # Measured: writing that answer back into the sheet and re-rendering restored the peer,
  # the handshake and the tunnel in one apply.
  #
  # So the Manager asks before it renders. This is the only place in the Manager that
  # reads a pod's device state in order to repair a document, and it earns that place
  # because `RouterConfig.write!` is the one function every intent change passes through:
  # a recovery that some caller can forget is a recovery that will be forgotten.
  #
  # Cost when nothing is wrong: one pass over the sheets in memory. The pod is only
  # touched for a sheet that actually has an address and no public key.
  module Recover
    # Cove's device inside every pod is renamed to wg0 by Network.attach
    # (lib/cove/network.rb:125). It is not configurable and must not be: the pod's
    # resolver, its default route and its door rules are all written against that name.
    WG_IFACE = "wg0"

    class << self
      # Heals in place and returns a list of "slug=first8…" for what it recovered, so a
      # caller can say so. Silence here would be the same fault as an empty refusal
      # reason: a repair nobody announced is a repair nobody can audit.
      def identities!(sheets)
        healed = []
        sheets.each do |sheet|
          next unless sheet.pubkey.to_s.empty?
          next if sheet.pod_ip.to_s.empty?

          key = live_pubkey(sheet.pod_name)
          next if key.nil?

          sheet.assign("pubkey" => key)
          sheet.save!
          healed << "#{sheet.slug}=#{key[0, 8]}…"
        end
        healed
      end

      private

      # nil means "the pod could not be asked", which is NOT the same as "the pod has no
      # key" — and the distinction matters, because healing a pod that is mid-teardown
      # would put a peer back for something about to be removed. Every path that cannot
      # answer returns nil and the sheet is left exactly as it was.
      def live_pubkey(pod_name)
        pid = Podman.sudo("podman", "inspect", "-f", "{{.State.Pid}}", pod_name)
        return nil unless pid.ok?

        p = pid.stdout.to_s.strip
        return nil if p.empty? || p == "0"

        out = Network.sudo("nsenter", "-t", p, "-n", "wg", "show", WG_IFACE, "public-key")
        return nil unless out.ok?

        key = out.stdout.to_s.strip
        key.empty? ? nil : key
      rescue StandardError
        nil
      end
    end
  end
end
