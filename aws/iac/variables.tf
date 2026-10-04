variable "region" {
  default = "ap-south-1"
}

variable "my_ip" {
  description = "Your public IP with /32, e.g. 203.0.113.4/32"
}

variable "key_name" {
  description = "Name of an EC2 key pair you created in the console"
}

variable "instance_type" {
  default = "t3.small" # used for both servers; t3.micro (1 GB RAM) is too small
}

variable "db_instance_class" {
  default = "db.t3.micro"
}

variable "db_password" {
  sensitive = true
}

variable "cohere_key" {
  sensitive = true
}

variable "slack_url" {
  sensitive = true
}

variable "grafana_password" {
  sensitive = true
}
