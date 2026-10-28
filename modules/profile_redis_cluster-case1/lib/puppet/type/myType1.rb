Puppet::Type.newtype(:myType1) do
  @doc = "Simple HTTP endpoint resource type"

  ensurable

  newparam(:url, :namevar => true) do
    desc "The target URL to query"
    validate do |value|
      raise ArgumentError, "Invalid HTTP/HTTPS URL" unless value =~ %r{\Ahttps?://}
    end
  end
end
