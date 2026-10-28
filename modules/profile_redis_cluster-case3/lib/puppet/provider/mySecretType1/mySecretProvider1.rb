Puppet::Type.type(:mySecretType1).provide(:mySecretProvider1) do
  desc "Registers servers in the Enterprise Scheduler platform via the proprietary schedulerctl CLI"

  commands :schedulerctl => '/usr/local/bin/schedulerctl'

  def exists?
    schedulerctl('query', resource[:name])
  rescue Puppet::ExecutionFailure
    false
  end

  def create
    schedulerctl('register', resource[:name], '--schedule', resource[:schedule])
  end

  def destroy
    schedulerctl('unregister', resource[:name])
  end
end
