namespace :adaki do
  namespace :audit do
    desc 'Export append-only audit chain for an account to JSONL (legal retention)'
    task :export, [:account_id] => :environment do |_t, args|
      account = Account.find(args[:account_id])
      Adaki::AuditLogEntry.verify_chain!(account)

      path = Rails.root.join("tmp/adaki-audit-#{account.id}-#{Time.current.strftime('%Y%m%dT%H%M%SZ')}.jsonl")
      File.open(path, 'w') do |f|
        Adaki::AuditLogEntry.for_account(account).find_each(order: :asc) do |e|
          f.puts(e.attributes.to_json)
        end
      end

      digest = Digest::SHA256.file(path).hexdigest
      File.write("#{path}.sha256", "#{digest}  #{File.basename(path)}\n")

      puts "Exported #{path}"
      puts "SHA256: #{digest}"
    end

    desc 'Verify audit chain integrity for all accounts'
    task verify_all: :environment do
      Account.find_each do |account|
        Adaki::AuditLogEntry.verify_chain!(account)
        puts "OK  account=#{account.id}"
      rescue StandardError => e
        warn "FAIL account=#{account.id}: #{e.message}"
      end
    end
  end
end
