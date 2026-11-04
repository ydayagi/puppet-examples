Puppet::Type.newtype(:mySecretType1) do
  @doc = "Registers a server in the proprietary Enterprise Scheduler platform"

  ensurable

  newparam(:name, :namevar => true) do
    desc "Name of the registered server"
  end

  newparam(:schedule) do
    desc "Schedule assigned to the registered server"
  end
end
