require 'company_internal_lib'

Puppet::Functions.create_function(:mySecretFunction1) do
  dispatch :execute do
    param 'String', :credential_name
    return_type 'String'
  end

  def execute(credential_name)
    CompanyInternal::SecretStore.fetch(credential_name)
  end
end
