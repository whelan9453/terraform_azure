# Configure the Azure Provider
provider "azurerm" { }

variable "rg_name" {default="terraform_open_vpn_client"}
variable "rg_location" {default="South East Asia"}
variable "env_tag_name" {default="testing"}

# Create a resource group
resource "azurerm_resource_group" "rg" {
  name     = "${var.rg_name}"
  location = "${var.rg_location}"
}

variable "vnet_name" {default="terrafrom-vnet"}
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

variable "pubip_name" {default="open_vpn_server_ip"}
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
    destination_port_range     = "1194"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags {
    environment = "${var.env_tag_name}"
  }
}

resource "azurerm_network_interface" "netface" {
  name                = "terraform_net_interface"
  location            = "${azurerm_resource_group.rg.location}"
  resource_group_name = "${azurerm_resource_group.rg.name}"
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

variable "vm_admin_user" {default="openvpn"}
variable "vm_admin_pwd" {}
variable "vm_name" {default="terraform_vpn"}

variable "ovpn_svr_uname" {}
variable "ovpn_svr_domain_or_ip" {}
variable "ovpn_cli_cfg_name" {}
#variable "os_computer_name" {default="megatron"}

resource "azurerm_virtual_machine" "vm" {
  name                  = "${var.vm_name}"
  location              = "${azurerm_resource_group.rg.location}"
  resource_group_name   = "${azurerm_resource_group.rg.name}"
  network_interface_ids = ["${azurerm_network_interface.netface.id}"]
  vm_size               = "Standard_DS1_v2"

  # Uncomment this line to delete the OS disk automatically when deleting the VM
  # delete_os_disk_on_termination = true

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
    type     = "ssh"
    host     = "${var.domain_label}.southeastasia.cloudapp.azure.com"
    user     = "${var.vm_admin_user}"
    password = "${var.vm_admin_pwd}"
    #private_key = "${file("~/.ssh/id_rsa.pub")}"
  }

  #provisioner "file" {
  #  source      = "scripts/post_install.sh"
  #  destination = "/tmp/post_install.sh"
  #}

  provisioner "remote-exec" {
    inline = [
      "printf 'Starting mounting data disk...\n'",
      "sudo sgdisk --new=0:0:0 /dev/sdc",
      "sudo mkfs.xfs -f /dev/sdc",
      "printf '[Unit]\nDescription=Mount for data storage\n[Mount]\nWhat=/dev/sdc\nWhere=/mnt/data\nType=xfs\nOptions=noatime\n[Install]\nWantedBy = multi-user.target \n' | sudo tee /etc/systemd/system/mnt-data.mount",
      "sudo systemctl start mnt-data.mount",
      "sudo systemctl enable mnt-data.mount",
      "printf 'starting setting up open vpn...'",
      "printf 'Step 12: Install the Client Configuration\n'",
      "sudo apt-get update",
      "sudo apt-get -y install openvpn",
      "sftp ${$var.ovpn_svr_uname}@{var.ovpn_svr_domain_or_ip}:client-configs/files/${var.ovpn_cli_cfg_name}.ovpn ~/"
    ]
  }
}