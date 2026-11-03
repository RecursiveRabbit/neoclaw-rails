# frozen_string_literal: true

require "open3"

module Network
  # WireGuard key custody for the Manager.
  #
  # The Manager holds the Router's private key and every peer's key
  # material. Private keys live only as files inside the Manager's
  # (mode 0700) state directory and are never written to logs, state
  # JSON, or rendered configs beyond the file that needs them.
  class KeyMaterial
    KeyPair = Struct.new(:private_key_file, :public_key)

    class Error < StandardError; end

    def self.generate!(state_dir, name)
      keys_dir = File.join(state_dir, "keys")
      FileUtils.mkdir_p(keys_dir, mode: 0o700)
      priv = File.join(keys_dir, "#{name}.key")
      FileUtils.touch(priv)
      FileUtils.chmod(0o600, priv)
      out, err, st = Open3.capture3("wg", "genkey")
      raise Error, "wg genkey failed: #{err}" unless st.success?
      File.write(priv, out, mode: "w")
      FileUtils.chmod(0o600, priv)
      pub = derive_public_key(out)
      new(priv, pub)
    end

    def self.read(state_dir, name)
      priv = File.join(state_dir, "keys", "#{name}.key")
      raise Error, "no private key file: #{priv}" unless File.readable?(priv)
      new(priv, derive_public_key(File.read(priv)))
    end

    def self.derive_public_key(private_key)
      out, err, st = Open3.capture3("wg", "pubkey", stdin_data: private_key)
      raise Error, "wg pubkey failed: #{err}" unless st.success?
      out.strip
    end

    attr_reader :private_key_file, :public_key

    def initialize(private_key_file, public_key)
      @private_key_file = private_key_file
      @public_key = public_key
    end
  end
end
