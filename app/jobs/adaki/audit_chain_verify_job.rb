class Adaki::AuditChainVerifyJob < ApplicationJob
  queue_as :low

  def perform
    failures = []
    Account.find_each do |account|
      Adaki::AuditLogEntry.verify_chain!(account)
    rescue StandardError => e
      Rails.logger.warn "[AdakiAuditChainVerify] account=#{account.id} FAIL #{e.message}"
      failures << { account_id: account.id, error: e.message }
      ChatwootExceptionTracker.new(e, account: account).capture_exception if defined?(ChatwootExceptionTracker)
    end

    return if failures.empty?

    raise "Audit chain verification failed for #{failures.size} accounts: #{failures.map { |f| f[:account_id] }.join(', ')}"
  end
end
