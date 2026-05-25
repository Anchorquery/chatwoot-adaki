# frozen_string_literal: true

module CustomExceptions::Platform
  class MissingCredential < CustomExceptions::Base
    def message
      I18n.t('errors.platform.missing_credential')
    end
  end

  class InvalidCredential < CustomExceptions::Base
    def message
      I18n.t('errors.platform.invalid_credential')
    end
  end
end
