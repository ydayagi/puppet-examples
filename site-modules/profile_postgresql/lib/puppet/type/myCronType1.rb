Puppet::Type.newtype(:myCronType1) do
  @doc = "Manages a cron entry that runs a command on a schedule"

  ensurable

  newparam(:name, :namevar => true) do
    desc "Name of the cron entry"
  end

  newparam(:command) do
    desc "Command to run"
    validate do |value|
      raise ArgumentError, "command must not be empty" if value.to_s.empty?
    end
  end

  newparam(:hour) do
    desc "Hour to run at"
    defaultto '2'
  end

  newparam(:minute) do
    desc "Minute to run at"
    defaultto '30'
  end
end
