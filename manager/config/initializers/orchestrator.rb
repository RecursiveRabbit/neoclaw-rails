# Run Orchestrator.reconcile! after Rails boots.
# Discovers orphaned agent pods and hot-swaps them with fresh
# Router credentials. Runs in a background thread so it doesn't
# block the Manager from accepting requests.
#
# Only runs in server mode — skip during rake tasks, console, tests.

Rails.application.config.after_initialize do
  if defined?(Puma)
    Thread.new do
      sleep 5
      begin
        Orchestrator.reconcile!
      rescue => e
        Rails.logger.error "Orchestrator boot reconciliation failed: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      end
      begin
        # After pods are adopted, close checkouts no live pod owns.
        CredentialReconciler.reconcile!
      rescue => e
        Rails.logger.error "Credential reconciliation failed: #{e.message}"
      end
    end
  end
end
