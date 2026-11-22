require "fileutils"
require "open3"
require "pathname"
require "tmpdir"

module Cove
  # WireGuard keys, two kinds, two lifetimes (spec §2).
  #
  #   ROUTER — the Manager generates it, hands it to the Router at launch, and KEEPS
  #            it: a Router relaunch must re-handshake and not re-key the fleet
  #            (§5, §13). It persists in state/keys/router.key at 0600. Here the
  #            state directory stands in for the Manager's database, which is the
  #            one place the spec allows a secret to live.
  #
  #   POD    — generated at the moment the Manager peers the pod, written to a
  #            throwaway 0600 file only because `wg set private-key` wants a path,
  #            set on the interface from the host side, and deleted. The Manager
  #            keeps the PUBLIC key and nothing else. A reborn pod therefore cannot
  #            inherit its predecessor's identity; there is nothing to inherit.
  module Keys
    Ephemeral = Struct.new(:path, :pubkey, keyword_init: true)

    class << self
      def dir = Cove.state_dir.join("keys")
      def router_key_path = dir.join("router.key")

      def genkey
        raw, err, st = Open3.capture3("wg", "genkey")
        raise Cove::DocumentError, "wg genkey failed: #{err.strip}" unless st.success?

        raw
      end

      def pubkey_of(private_b64)
        out, err, st = Open3.capture3("wg", "pubkey", stdin_data: private_b64)
        raise Cove::DocumentError, "wg pubkey failed: #{err.strip}" unless st.success?

        out.strip
      end

      def ensure_router!
        FileUtils.mkdir_p(dir, mode: 0o700)
        File.chmod(0o700, dir)
        unless router_key_path.exist?
          raw = genkey
          # Not Cove.write_atomic: that path creates a world-readable temp file
          # first. A private key is created secret and never otherwise.
          File.open(router_key_path.to_s, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
            f.write(raw)
            f.flush
            f.fsync
          end
        end
        File.chmod(0o600, router_key_path)
        router_key_path
      end

      def router_pubkey = pubkey_of(File.read(ensure_router!))

      # A pod's keypair, alive only as long as the attach that uses it.
      def ephemeral
        raw = genkey
        dir = Dir.mktmpdir("cove-key-")
        path = Pathname.new(dir).join("pod.key")
        File.open(path.to_s, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
          f.write(raw)
        end
        Ephemeral.new(path: path.to_s, pubkey: pubkey_of(raw))
      end

      def discard(ephemeral)
        return if ephemeral.nil?

        parent = File.dirname(ephemeral.path.to_s)
        FileUtils.remove_entry(parent) if File.basename(parent).start_with?("cove-key-")
      end
    end
  end
end
