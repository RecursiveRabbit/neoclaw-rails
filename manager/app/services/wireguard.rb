# WireGuard keypair generation — the only WG operation the Manager does locally.
# All peer management is delegated to the Router via RouterClient.

class WireGuard
  class << self
    def generate_keypair
      private_key = `wg genkey`.strip
      public_key = IO.popen("wg pubkey", "r+") { |io|
        io.write(private_key)
        io.close_write
        io.read.strip
      }
      { private: private_key, public: public_key }
    end
  end
end
