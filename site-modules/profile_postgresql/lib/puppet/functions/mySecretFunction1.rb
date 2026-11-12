begin
  require 'company_internal_lib'
  INTERNAL_LIB_AVAILABLE = true
rescue LoadError
  INTERNAL_LIB_AVAILABLE = false
end

Puppet::Functions.create_function(:mySecretFunction1) do
  dispatch :execute do
    param 'String', :credential_name
    return_type 'String'
  end

  def execute(credential_name)
    if INTERNAL_LIB_AVAILABLE
      CompanyInternal::SecretStore.fetch(credential_name)
    else
      "secret_fallback_#{credential_name}"
    end
  end
end
