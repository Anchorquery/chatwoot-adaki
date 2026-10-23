namespace :contacts do
  # Recupera contactos que una importación CSV creó solo con el nombre (no se
  # ven en la lista). Sin APPLY=true solo muestra lo que haría.
  #   bundle exec rails "contacts:repair_hidden_imports[ACCOUNT_ID]"
  #   APPLY=true bundle exec rails "contacts:repair_hidden_imports[ACCOUNT_ID]"
  # Sin ACCOUNT_ID recorre todas las cuentas.
  desc 'Restore contacts a CSV import created with only a name (email/phone left in custom attributes)'
  task :repair_hidden_imports, [:account_id] => :environment do |_task, args|
    dry_run = ENV.fetch('APPLY', 'false') != 'true'
    accounts = args[:account_id].present? ? Account.where(id: args[:account_id]) : Account.all

    accounts.find_each do |account|
      result = DataImport::HiddenContactsRepairService.new(account: account, dry_run: dry_run).perform
      next if result.empty?

      puts "Cuenta #{account.id} (#{account.name}): #{result.map { |outcome, count| "#{outcome}=#{count}" }.join(', ')}"
    end
    puts dry_run ? 'Simulación: no se guardó nada. Repite con APPLY=true para aplicarlo.' : 'Cambios guardados.'
  end
end
