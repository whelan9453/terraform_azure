variable "azure_sub_id" {}
variable "azure_cli_id" {}
variable "azure_cli_secret" {}
variable "azure_tenant_id" {}

# Configure the Azure Provider
provider "azurerm" {
  subscription_id = "${var.azure_sub_id}"
  client_id       = "${var.azure_cli_id}"
  client_secret   = "${var.azure_cli_secret}"
  tenant_id       = "${var.azure_tenant_id}"
}

variable "rg_name" {
  default = "terraform_open_vpn_server"
}

#variable "rg_location" {default="South East Asia"}
variable "rg_location" {
  default = "eastasia"
}

variable "env_tag_name" {
  default = "testing"
}

variable "rc_count" {}

# Create a resource group
resource "azurerm_resource_group" "rg" {
  name     = "${var.rg_name}"
  location = "${var.rg_location}"
}

variable "vnet_name" {
  default = "terrafrom-vnet"
}

# Create a virtual network within the resource group
resource "azurerm_virtual_network" "vn" {
  name                = "${var.vnet_name}"
  address_space       = ["10.0.0.0/16"]
  location            = "${azurerm_resource_group.rg.location}"
  resource_group_name = "${azurerm_resource_group.rg.name}"

  #subnet {
  #  name           = "subnet"
  #  address_prefix = "10.0.0.0/24"
  #}
}

resource "azurerm_subnet" "subnet" {
  name                 = "terraform_subnet"
  resource_group_name  = "${azurerm_resource_group.rg.name}"
  virtual_network_name = "${azurerm_virtual_network.vn.name}"
  address_prefix       = "10.0.0.0/24"
}

variable "pubip_name" {
  default = "open_vpn_server_ip"
}

variable "domain_label" {}

resource "azurerm_public_ip" "pubip" {
  name                         = "${var.pubip_name}"
  location                     = "${azurerm_resource_group.rg.location}"
  resource_group_name          = "${azurerm_resource_group.rg.name}"
  public_ip_address_allocation = "Dynamic"
  idle_timeout_in_minutes      = 30
  domain_name_label            = "${var.domain_label}"

  tags {
    environment = "${var.env_tag_name}"
  }
}

resource "azurerm_network_security_group" "nsg" {
  name                = "terraform_security_group"
  location            = "${azurerm_resource_group.rg.location}"
  resource_group_name = "${azurerm_resource_group.rg.name}"

  security_rule {
    name                       = "default-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "openVPN"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "9194"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags {
    environment = "${var.env_tag_name}"
  }
}

resource "azurerm_network_interface" "netface" {
  name                      = "terraform_net_interface"
  location                  = "${azurerm_resource_group.rg.location}"
  resource_group_name       = "${azurerm_resource_group.rg.name}"
  network_security_group_id = "${azurerm_network_security_group.nsg.id}"

  ip_configuration {
    name                          = "terraform_ip_conf"
    subnet_id                     = "${azurerm_subnet.subnet.id}"
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = "${azurerm_public_ip.pubip.id}"
  }
}

resource "azurerm_managed_disk" "mandisk" {
  name                 = "terraform_datadisk_existing"
  location             = "${azurerm_resource_group.rg.location}"
  resource_group_name  = "${azurerm_resource_group.rg.name}"
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = "260"
}

variable "vm_admin_user" {
  default = "openvpn"
}

variable "vm_admin_pwd" {}

variable "vm_name" {
  default = "terraform_vpn"
}

variable "ssh_pub_key" {}

#variable "os_computer_name" {default="megatron"}

resource "azurerm_virtual_machine" "vm" {
  name                  = "${var.vm_name}"
  location              = "${azurerm_resource_group.rg.location}"
  resource_group_name   = "${azurerm_resource_group.rg.name}"
  network_interface_ids = ["${azurerm_network_interface.netface.id}"]
  vm_size               = "Standard_DS1_v2"

  # Uncomment this line to delete the OS disk automatically when deleting the VM
  delete_os_disk_on_termination = true

  # Uncomment this line to delete the data disks automatically when deleting the VM
  # delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04-LTS"
    version   = "latest"
  }
  storage_os_disk {
    name              = "os-disk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Premium_LRS"
  }

  # Optional data disks
  # storage_data_disk {
  #   name              = "datadisk_new"
  #   managed_disk_type = "Standard_LRS"
  #   create_option     = "Empty"
  #   lun               = 0
  #   disk_size_gb      = "1023"
  # }

  storage_data_disk {
    name            = "${azurerm_managed_disk.mandisk.name}"
    managed_disk_id = "${azurerm_managed_disk.mandisk.id}"
    create_option   = "Attach"
    lun             = 0
    disk_size_gb    = "${azurerm_managed_disk.mandisk.disk_size_gb}"
  }
  os_profile {
    computer_name  = "${var.domain_label}"
    admin_username = "${var.vm_admin_user}"
    admin_password = "${var.vm_admin_pwd}"
  }
  # NOTE:會直接拿本地的~/.ssh/id_rsa.pub作為連線的依據
  os_profile_linux_config {
    # disable_password_authentication = false
    disable_password_authentication = true

    ssh_keys = [{
      path     = "/home/${var.vm_admin_user}/.ssh/authorized_keys"
      key_data = "${file("~/.ssh/id_rsa.pub")}"
    }]
  }
  tags {
    environment = "${var.env_tag_name}"
  }
  connection {
    type = "ssh"
    host = "${var.domain_label}.${var.rg_location}.cloudapp.azure.com"
    user = "${var.vm_admin_user}"

    # password = "${var.vm_admin_pwd}"

    private_key = "${file("~/.ssh/id_rsa")}"
  }

  #provisioner "file" {
  #  source      = "scripts/post_install.sh"
  #  destination = "/tmp/post_install.sh"
  #}

  provisioner "remote-exec" {
    inline = [
      "printf 'https://www.digitalocean.com/community/tutorials/how-to-set-up-an-openvpn-server-on-ubuntu-16-04'",
      "printf 'Starting mounting data disk...\n'",
      "sudo sgdisk --new=0:0:0 /dev/sdc",
      "sudo mkfs.xfs -f /dev/sdc",
      "printf '[Unit]\nDescription=Mount for data storage\n[Mount]\nWhat=/dev/sdc\nWhere=/mnt/data\nType=xfs\nOptions=noatime\n[Install]\nWantedBy = multi-user.target \n' | sudo tee /etc/systemd/system/mnt-data.mount",
      "sudo systemctl start mnt-data.mount",
      "sudo systemctl enable mnt-data.mount",
      "printf 'starting setting up open vpn...'",
      "printf 'Step 1: Install OpenVPN\n'",
      "sudo apt-get update",
      "sudo apt-get -y install openvpn easy-rsa",
      "printf 'Step 2: Set Up the CA Directory\n'",
      "make-cadir ~/openvpn-ca",
      "cd ~/openvpn-ca",
      "printf 'Step 3: Configure the CA Variables\n'",
      "sed -i -e 's/KEY_COUNTRY=\"US\"/KEY_COUNTRY=\"TW\"/g' vars",
      "sed -i -e 's/KEY_PROVINCE=\"CA\"/KEY_PROVINCE=\"TW\"/g' vars",
      "sed -i -e 's/KEY_CITY=\"SanFrancisco\"/KEY_CITY=\"Taipei\"/g' vars",
      "sed -i -e 's/KEY_ORG=\"Fort-Funston\"/KEY_ORG=\"ASUS\"/g' vars",
      "sed -i -e 's/KEY_EMAIL=\"me@myhost.mydomain\"/KEY_EMAIL=\"wei-lun_ting@asus.com\"/g' vars",
      "sed -i -e 's/KEY_OU=\"MyOrganizationalUnit\"/KEY_OU=\"AMACS\"/g' vars",
      "sed -i -e 's/KEY_NAME=\"EasyRSA\"/KEY_NAME=\"amacs-hybrid-vpn-server\"/g' vars",
      "printf 'Step 4: Build the Certificate Authority\n'",
      "cd ~/openvpn-ca",
      "printf 'Current path\n'",
      "pwd",
      ". ./vars",
      "printenv",
      "./clean-all",
      "sed -i -e 's/--interact//g' build-ca",
      "./build-ca",
      "printf 'Step 5: Create the Server Certificate, Key, and Encryption Files\n'",
      "sed -i -e 's/--interact//g' build-key-server",
      "./build-key-server amacs-hybrid-vpn-server",
      "./build-dh",
      "openvpn --genkey --secret keys/ta.key",
      "printf 'Step 6: Generate a Client Certificate and Key Pair\n'",
      ". ~/openvpn-ca/vars",
      "cd ~/openvpn-ca",
      "sed -i -e 's/--interact//g' build-key",
      "for i in `seq 0 ${var.rc_count}`; do ./build-key amacs-hybrid-vpn-client$$i; done",
      "printf 'Step 7: Configure the OpenVPN Service\n'",
      "cd ~/openvpn-ca/keys",
      "sudo cp ca.crt amacs-hybrid-vpn-server.crt amacs-hybrid-vpn-server.key ta.key dh2048.pem /etc/openvpn",
      "gunzip -c /usr/share/doc/openvpn/examples/sample-config-files/server.conf.gz | sudo tee /etc/openvpn/amacs-hybrid-vpn-server.conf",
      "sudo sed -i -e 's/;tls-auth/tls-auth/g' /etc/openvpn/amacs-hybrid-vpn-server.conf",
      "sudo sed -i '/tls-auth/a key-direction 0' /etc/openvpn/amacs-hybrid-vpn-server.conf",
      "sudo sed -i -e 's/;cipher AES-128-CBC/cipher AES-128-CBC/g' /etc/openvpn/amacs-hybrid-vpn-server.conf",
      "sudo sed -i '/cipher AES-128-CBC/a auth SHA256' /etc/openvpn/amacs-hybrid-vpn-server.conf",
      "sudo sed -i -e 's/;user nobody/user nobody/g' /etc/openvpn/amacs-hybrid-vpn-server.conf",
      "sudo sed -i -e 's/;group nogroup/group nogroup/g' /etc/openvpn/amacs-hybrid-vpn-server.conf",
      "sudo sed -i -e 's/port 1194/port 9194/g' /etc/openvpn/amacs-hybrid-vpn-server.conf",
      "printf 'Step 8: Adjust the Server Networking Configuration\n'",
      "sudo sed -i -e's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf",
      "sudo sysctl -p",
      "PUB_FACE_NAME=`ip route | grep default | cut -d' ' -f5`",
      "sudo sed -i -e '/#   ufw-before-forward/a #START OPENVPN RULES\n#NAT table rules\n*nat\n:POSTROUTING ACCEPT [0:0]\n#Allow traffic from OpenVPN client to $${PUB_FACE_NAME}\n-A POSTROUTING -s 10.8.0.0/8 -o eth0 -j MASQUERADE\nCOMMIT\n# END OPENVPN RULES\n' /etc/ufw/before.rules",
      "sudo sed -i 's/DEFAULT_FORWARD_POLICY=\"DROP\"/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/g' /etc/default/ufw",
      "sudo ufw allow 9194/udp",
      "sudo ufw allow OpenSSH",
      "sudo ufw disable",
      "sudo ufw --force enable",
      "printf 'Step 9: Start and Enable the OpenVPN Service\n'",
      "sudo sed -i -e's/cert server.crt/cert amacs-hybrid-vpn-server.crt/g' /etc/openvpn/amacs-hybrid-vpn-server.conf",
      "sudo sed -i -e's/key server.key/key amacs-hybrid-vpn-server.key/g' /etc/openvpn/amacs-hybrid-vpn-server.conf",
      "sudo systemctl start openvpn@amacs-hybrid-vpn-server",
      "ip addr show tun0",
      "sudo systemctl enable openvpn@amacs-hybrid-vpn-server",
      "printf 'Step 10: Create Client Configuration Infrastructure\n'",
      "mkdir -p ~/client-configs/files",
      "chmod 700 ~/client-configs/files",
      "cp /usr/share/doc/openvpn/examples/sample-config-files/client.conf ~/client-configs/base.conf",
      "sed -i 's/remote my-server-1 1194/remote ${var.domain_label}.${var.rg_location}.cloudapp.azure.com 9194/g' ~/client-configs/base.conf",
      "sed -i 's/;user nobody/user nobody/g' ~/client-configs/base.conf",
      "sed -i 's/;group nogroup/group nogroup/g' ~/client-configs/base.conf",
      "sed -i 's/ca ca.crt/#ca ca.crt/g' ~/client-configs/base.conf",
      "sed -i 's/cert client.crt/#cert client.crt/g' ~/client-configs/base.conf",
      "sed -i 's/key client.key/#key client.key/g' ~/client-configs/base.conf",
      "sed -i 's/;cipher x/cipher AES-128-CBC/g' ~/client-configs/base.conf",
      "sed -i '/cipher AES-128-CBC/a auth SHA256' ~/client-configs/base.conf",
      "sed -i '/auth SHA256/a key-direction 1' ~/client-configs/base.conf",
      "sed -i '/key-direction 1/a # script-security 2' ~/client-configs/base.conf",
      "sed -i '/script-security 2/a # up /etc/openvpn/update-resolv-conf' ~/client-configs/base.conf",
      "sed -i '/# up \\/etc\\/openvpn\\/update-resolv-conf/a # down /etc/openvpn/update-resolv-conf' ~/client-configs/base.conf",
      "touch ~/client-configs/make_config.sh",
      "echo '#!/bin/bash' >> ~/client-configs/make_config.sh",
      "echo '# First argument: Client identifier' >> ~/client-configs/make_config.sh",
      "echo 'KEY_DIR=~/openvpn-ca/keys' >> ~/client-configs/make_config.sh",
      "echo 'OUTPUT_DIR=~/client-configs/files' >> ~/client-configs/make_config.sh",
      "echo 'BASE_CONFIG=~/client-configs/base.conf' >> ~/client-configs/make_config.sh",
      "echo 'cat $${BASE_CONFIG} \\' >> ~/client-configs/make_config.sh",
      "echo \"    <(echo -e '<ca>') \\\\\" >> ~/client-configs/make_config.sh",
      "echo '    $${KEY_DIR}/ca.crt \\' >> ~/client-configs/make_config.sh",
      "echo \"    <(echo -e '</ca>\\\\n<cert>') \\\\\" >> ~/client-configs/make_config.sh",
      "echo '    $${KEY_DIR}/$${1}.crt \\' >> ~/client-configs/make_config.sh",
      "echo \"    <(echo -e '</cert>\\\\n<key>') \\\\\" >> ~/client-configs/make_config.sh",
      "echo '    $${KEY_DIR}/$${1}.key \\' >> ~/client-configs/make_config.sh",
      "echo \"    <(echo -e '</key>\\\\n<tls-auth>') \\\\\" >> ~/client-configs/make_config.sh",
      "echo '    $${KEY_DIR}/ta.key \\' >> ~/client-configs/make_config.sh",
      "echo \"    <(echo -e '</tls-auth>') \\\\\" >> ~/client-configs/make_config.sh",
      "echo '    >$${OUTPUT_DIR}/$${1}.ovpn' >> ~/client-configs/make_config.sh",
      "chmod 700 ~/client-configs/make_config.sh",
      "printf 'Step 11: Generate Client Configurations\n'",
      "cd ~/client-configs",
      "for i in `seq 0 ${var.rc_count}`; do ./make_config.sh amacs-hybrid-vpn-client$$i; done",
      "ls ~/client-configs/files",
      "echo ${var.ssh_pub_key} >> ~/.ssh/authorized_keys",
    ]
  }
}
