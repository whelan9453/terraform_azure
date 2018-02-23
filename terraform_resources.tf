# Configure the Azure Provider
provider "azurerm" { }

# Create a resource group
resource "azurerm_resource_group" "terraform_rg" {
  name     = "terraform_WeiLun"
  location = "South East Asia"
}

# Create a virtual network within the resource group
resource "azurerm_virtual_network" "terraform_rg" {
  name                = "terraform-network"
  address_space       = ["10.0.0.0/16"]
  location            = "${azurerm_resource_group.terraform_rg.location}"
  resource_group_name = "${azurerm_resource_group.terraform_rg.name}"

  #subnet {
  #  name           = "subnet"
  #  address_prefix = "10.0.0.0/24"
  #}
}

resource "azurerm_subnet" "terraform_rg" {
  name                 = "terraform_subnet"
  resource_group_name  = "${azurerm_resource_group.terraform_rg.name}"
  virtual_network_name = "${azurerm_virtual_network.terraform_rg.name}"
  address_prefix       = "10.0.0.0/24"
}

resource "azurerm_public_ip" "terraform_rg" {
  name                         = "terraform-ip"
  location                     = "${azurerm_resource_group.terraform_rg.location}"
  resource_group_name          = "${azurerm_resource_group.terraform_rg.name}"
  public_ip_address_allocation = "Dynamic"
  idle_timeout_in_minutes      = 30
  domain_name_label            = "terraform-dn"

  tags {
    environment = "staging"
  }
}

resource "azurerm_network_security_group" "terraform_rg" {
  name                = "terraform_security_group"
  location            = "${azurerm_resource_group.terraform_rg.location}"
  resource_group_name = "${azurerm_resource_group.terraform_rg.name}"

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
    environment = "staging"
  }
}

resource "azurerm_network_interface" "terraform_rg" {
  name                = "terraform_net_interface"
  location            = "${azurerm_resource_group.terraform_rg.location}"
  resource_group_name = "${azurerm_resource_group.terraform_rg.name}"
  network_security_group_id = "${azurerm_network_security_group.terraform_rg.id}"

  ip_configuration {
    name                          = "terraform_ip_conf"
    subnet_id                     = "${azurerm_subnet.terraform_rg.id}"
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = "${azurerm_public_ip.terraform_rg.id}"
  }
}

resource "azurerm_managed_disk" "terraform_rg" {
  name                 = "terraform_datadisk_existing"
  location             = "${azurerm_resource_group.terraform_rg.location}"
  resource_group_name  = "${azurerm_resource_group.terraform_rg.name}"
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = "260"
}

resource "azurerm_virtual_machine" "terraform_rg" {
  name                  = "terraform_vm"
  location              = "${azurerm_resource_group.terraform_rg.location}"
  resource_group_name   = "${azurerm_resource_group.terraform_rg.name}"
  network_interface_ids = ["${azurerm_network_interface.terraform_rg.id}"]
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
    name              = "terraform-os-disk"
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
    name            = "${azurerm_managed_disk.terraform_rg.name}"
    managed_disk_id = "${azurerm_managed_disk.terraform_rg.id}"
    create_option   = "Attach"
    lun             = 0
    disk_size_gb    = "${azurerm_managed_disk.terraform_rg.disk_size_gb}"
  }

  os_profile {
    computer_name  = "terraform-alis"
    admin_username = "alis"
    # admin_password = "terraform.ALIS"
  }

  os_profile_linux_config {
    # disable_password_authentication = false
    disable_password_authentication = true
    ssh_keys = [{
      path     = "/home/alis/.ssh/authorized_keys"
      key_data = "${file("~/.ssh/id_rsa.pub")}"
    }]
  }

  tags {
    environment = "staging"
  }

  provisioner "remote-exec" {
    inline = [
      "sgdisk --new=0:0:0 /dev/sdc",
      "mkfs.xfs -f /dev/sdc",
      "printf '[Unit]\nDescription=Mount for data storage\n[Mount]\nWhat=/dev/sdc\nWhere=/mnt/data\nType=xfs\nOptions=noatime\n[Install]\nWantedBy = multi-user.target \n' | sudo tee /etc/systemd/system/mnt-data.mount",
      "systemctl start mnt-data.mount",
      "systemctl start mnt-data.mount",
      "systemctl enable mnt-data.mount"
    ]
  }
}
