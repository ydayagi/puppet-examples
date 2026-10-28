Puppet::Type.newtype(:myDeploy1) do
  @doc = "Manages an application deployment tracked by a version file"

  ensurable

  newparam(:name, :namevar => true) do
    desc "Application name"
  end

  newparam(:version) do
    desc "Desired application version"
    validate do |value|
      raise ArgumentError, "version must not be empty" if value.to_s.empty?
    end
  end

  newparam(:url) do
    desc "Artifact download URL"
    validate do |value|
      raise ArgumentError, "Invalid HTTP/HTTPS URL" unless value =~ %r{\Ahttps?://}
    end
  end

  newparam(:install_dir) do
    desc "Installation directory"
  end
end
