# credential_ledger_proof.rb — served proof of the credential ledger.
#
# Run: cd manager && RAILS_ENV=test bin/rails runner ../test/proof/credential_ledger_proof.rb
#
# Exercises the REAL mint path (Provisioner, ssh_key service type), the REAL
# revocation paths (teardown, orphan, boot reconciliation), and a real
# filesystem credential. No network service is contacted; the ledger's
# network-backed revokers are covered by unit tests with a fake HTTP client.
#
# Every check prints PASS/FAIL; exits non-zero on any FAIL.

require "fileutils"

PASS = 0
FAIL = 0
def ok(msg)   = (puts "PASS  #{msg}")
def bad(msg)  = (puts "FAIL  #{msg}")
def check(msg)
  if yield
    ok(msg)
  else
    bad(msg)
  end
end

root = Dir.mktmpdir("ledger-proof")
keys_dir = File.join(root, "ssh-keys")
FileUtils.mkdir_p(keys_dir)

# Point the Manager's ssh-key surface at the disposable dir.
Surface.singleton_class.send(:define_method, :ssh_keys_dir) { keys_dir }

service = ServiceType.find_or_initialize_by(name: "ssh-proof")
service.update!(provision_type: "ssh_key", wg_ip: "10.0.0.2", notes: "ledger proof")
AgentConfig.delete_all
AgentConfig.create!(identity: "proofagent", model: "test",
                    base_services: ["ssh-proof"])

CredentialCheckout.delete_all
AuditLog.delete_all

puts "--- 1. mint: a real credential, a ledger row, no secret in the row"
result = Provisioner.provision(service, instance_name: "proofagent-one",
                                ssh_pubkey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIproof only")
authorized = File.join(keys_dir, "proofagent-one", "authorized_keys")
row = CredentialCheckout.open_for("proofagent-one").first

check("ssh key file exists on disk")                 { File.read(authorized).include?("ssh-ed25519") }
check("provision result returned the ssh endpoint")   { result[:port] == 22 }
check("exactly one checkout row was recorded")        { CredentialCheckout.open_for("proofagent-one").count == 1 }
check("row scope is ssh-key")                         { row&.scope == "ssh-key" }
check("row launch_ref names this Manager boot")       { row&.launch_ref&.start_with?(Surface.boot_id) }
check("row revoke_handle is a locator, not a secret") { row&.revoke_handle == "file:#{File.join(keys_dir, 'proofagent-one')}" }

# A secret-shaped string must appear in NO column of any row.
SECRET_RE = /(BEGIN [A-Z ]*PRIVATE KEY|ssh-ed25519 AAAA|token=[A-Za-z0-9]|sha1:)/.freeze
row_text = CredentialCheckout.all.map { |r| r.attributes.values.compact.map(&:to_s).join("|") }.join("\n")
check("no ledger column carries a secret value") { row_text !~ SECRET_RE }

puts "--- 2. teardown: revoke by instance, credential really gone"
counts = CredentialRevoker.revoke_all("proofagent-one", reason: "teardown")
check("revoke_all reported one revoked")          { counts[:revoked] == 1 }
check("the ssh key directory is gone")            { !File.exist?(File.join(keys_dir, "proofagent-one")) }
check("the row is closed with its reason")        { row.reload.revoked_at && row.revoked_reason == "teardown" }
check("re-revoking an instance is a no-op")       { CredentialRevoker.revoke_all("proofagent-one", reason: "teardown")[:revoked].zero? }

puts "--- 3. orphan: a pod we cannot adopt loses its credentials"
Provisioner.provision(service, instance_name: "proofagent-orphan",
                      ssh_pubkey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIproof only")
orphan_row = CredentialCheckout.open_for("proofagent-orphan").first
check("orphan credential exists before cleanup")  { File.exist?(File.join(keys_dir, "proofagent-orphan", "authorized_keys")) }

# Make it look like a previous boot's row so the boot reconciler owns it.
orphan_row.update!(launch_ref: "previousboot:proofagent-orphan")
CredentialReconciler.inventory_override = []
recon_counts = CredentialReconciler.reconcile!
CredentialReconciler.inventory_override = nil

check("reconciler revoked the stale row")          { recon_counts[:revoked] >= 1 }
check("orphan row is closed by boot-reconcile")    { orphan_row.reload.revoked_reason == "boot-reconcile" }
check("orphan ssh key directory is gone")          { !File.exist?(File.join(keys_dir, "proofagent-orphan")) }

puts "--- 4. a live pod keeps its credentials across reconciliation"
Provisioner.provision(service, instance_name: "proofagent-live",
                      ssh_pubkey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIproof only")
live_row = CredentialCheckout.open_for("proofagent-live").first
live_row.update!(launch_ref: "previousboot:proofagent-live")
CredentialReconciler.inventory_override = ["proofagent-live"]
CredentialReconciler.reconcile!
CredentialReconciler.inventory_override = nil
check("live pod's row stays open")                 { live_row.reload.revoked_at.nil? }
check("live pod's key file still exists")          { File.exist?(File.join(keys_dir, "proofagent-live", "authorized_keys")) }

puts "--- 5. unrevocable credentials are reported, never silently closed"
CredentialCheckout.issue!(scope: "generic-token", instance_name: "proofagent-generic",
                          revoke_handle: "generic:/api/v1/tokens",
                          launch_ref: "previousboot:proofagent-generic", unrevocable: true)
gen_counts = CredentialReconciler.reconcile!
check("reconciler counted it unrevocable")         { gen_counts[:unrevocable] == 1 }
check("unrevocable row remains open, visibly")     { CredentialCheckout.open.where(instance_name: "proofagent-generic").count == 1 }

puts "--- ledger (no secret values by construction)"
CredentialCheckout.order(:instance_name, :scope).each do |r|
  puts format("  %-20s %-14s %-22s %s",
              r.instance_name, r.scope, r.revoked_reason || "OPEN",
              r.revoked_at ? "revoked #{r.revoked_at.utc.iso8601}" : "launch #{r.launch_ref}")
end

puts "--- audit rows written"
AuditLog.order(:id).each { |a| puts "  #{a.event} #{a.instance_name} #{a.detail}" }

# Leave nothing behind that would confuse the next run.
CredentialCheckout.delete_all
AuditLog.delete_all
AgentConfig.delete_all
service.destroy
FileUtils.rm_rf(root)

puts "---"
puts "PASS=#{PASS} FAIL=#{FAIL}"
exit(FAIL.zero? ? 0 : 1)
