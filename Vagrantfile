# -*- mode: ruby -*-
# vi: set ft=ruby :

# Vagrantfile API/syntax version. Don't touch unless you know what you're doing!
VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|

  #
  # Centos-6:
  #
  config.vm.define "centos6", autostart: true do |centos6|
    centos6.vm.box = "fbarriere/nge-centos-6"

    # Mount the sources folder to cache source packages
    centos6.vm.synced_folder ".", "/bugzilla"
      
    centos6.vm.network :forwarded_port, guest: 80, host: 8888

    centos6.vm.provider "virtualbox" do |vb|
      vb.memory = 1024
    end
  end

end
