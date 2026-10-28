Puppet::Type.newtype(:myFormatType1) do
  @doc = "Manages entries in the proprietary CompanyApp settings format (!key=value lines)"

  ensurable

  newparam(:entry, :namevar => true) do
    desc "Name of the settings entry to manage"
    validate do |value|
      raise ArgumentError, "entry must not be empty" if value.to_s.empty?
    end
  end

  newparam(:file) do
    desc "Path to the CompanyApp settings file"
    defaultto '/etc/company/app.conf'
  end

  newproperty(:value) do
    desc "Value to set for the entry"
  end
end
