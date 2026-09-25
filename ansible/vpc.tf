variable "ssh_key" {
  default = "<YOUR HOME DIR>/.ssh/id_rsa.pub"
}

variable "ssh_private_key" {
  default = "<YOUR HOME DIR>/.ssh/id_rsa"
}

variable "ssh_user" {
  default = "<YOUR ID on VM>"
}
provider "google" {
  credentials = file("key.json")
  project    = "<YOUR GCP PROJECT NAME>"
  region     = "us-east4"
}

resource "google_compute_address" "example_ip" {
  name = "example-ip"
}
resource "google_compute_instance" "example" {
  name         = "example-instance"
  machine_type = "n1-standard-1"
  zone         = "us-east4-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  #network_interface {
  #  network = "default"
  #}

  # Associate the external IP with the instance
  network_interface {
    network = "default"
    access_config {
      nat_ip = google_compute_address.example_ip.address
    }
  }

  // Create a new SSH user and add their public key
  metadata = {
    ssh-keys                = "${var.ssh_user}:${file("${var.ssh_key}")}"
    enable-guest-attributes = "TRUE"
  }
}

output "instance_ip" {
  value = google_compute_instance.example.network_interface[0].network_ip
}

output "instance_fip" {
  value = google_compute_instance.example.network_interface[0].access_config[0].nat_ip
}


########################################
# create an inventory file for Ansible #
########################################
resource "local_file" "inventory" {
  content = templatefile("clusterinventory.tpl",
    {
      ansible_sshkey    = var.ssh_private_key
      ansible_user      = var.ssh_user
      server_private_ip = google_compute_instance.example.network_interface[0].network_ip
      server_public_ip  = google_compute_instance.example.network_interface[0].access_config[0].nat_ip
  })
  filename        = "cluster.inventory"
  file_permission = "0666"
}
