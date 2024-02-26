data "azurerm_client_config" "current" {}

# Resource group for ALL resources
resource "azurerm_resource_group" "boundary" {
  name     = local.resource_group_name
  location = var.location
}

module "vnet" {
  source              = "Azure/vnet/azurerm"
  version             = "~> 2.0"
  resource_group_name = azurerm_resource_group.boundary.name
  vnet_name           = azurerm_resource_group.boundary.name
  address_space       = var.address_space
  subnet_prefixes     = var.subnet_prefixes
  subnet_names        = var.subnet_names

}
resource "azurerm_network_security_group" "backend_net" {
  name                = local.backend_net_nsg
  location            = var.location
  resource_group_name = azurerm_resource_group.boundary.name
}
resource "azurerm_network_security_group" "backend_nics" {
  name                = local.backend_nic_nsg
  location            = var.location
  resource_group_name = azurerm_resource_group.boundary.name
}
resource "azurerm_subnet_network_security_group_association" "controller" {
  subnet_id                 = module.vnet.vnet_subnets[0]
  network_security_group_id = azurerm_network_security_group.backend_net.id
}


// This resource initially returns in a Pending state, because its application_id is required to complete acceptance of the connection.
resource "hcp_azure_peering_connection" "peer" {
  hvn_link                 = data.terraform_remote_state.boundary_demo_init.outputs.hvn_self_link
  peering_id               = "boundary-demo-cluster"
  peer_vnet_name           = module.vnet.vnet_name
  peer_subscription_id     = azurerm_client_config.current.subscription_id
  peer_tenant_id           = azurerm_client_config.current.tenant_id
  peer_resource_group_name = azurerm_resource_group.boundary.name
  peer_vnet_region         = var.location
}

// This data source is the same as the resource above, but waits for the connection to be Active before returning.
data "hcp_azure_peering_connection" "peer" {
  hvn_link              = data.terraform_remote_state.boundary_demo_init.outputs.hvn_self_link
  peering_id            = hcp_azure_peering_connection.peer.peering_id
  wait_for_active_state = true
}

// The route depends on the data source, rather than the resource, to ensure the peering is in an Active state.
resource "hcp_hvn_route" "route" {
  hvn_link         = data.terraform_remote_state.boundary_demo_init.outputs.hvn_self_link
  hvn_route_id     = "azure-route"
  destination_cidr = "172.31.0.0/16"
  target_link      = data.hcp_azure_peering_connection.peer.self_link
}

data "azurerm_subscription" "sub" {
  subscription_id = azurerm_client_config.current.subscription_id
}


// The principal deploying the `azuread_service_principal` resource below requires
// API Permissions as described here: https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/service_principal.
// The principal deploying the `azurerm_role_definition` and `azurerm_role_assigment`
// resources must have Owner or User Access Administrator permissions over an appropriate
// scope that includes your Virtual Network.
resource "azuread_service_principal" "principal" {
  application_id = hcp_azure_peering_connection.peer.application_id
}

resource "azurerm_role_definition" "definition" {
  name  = "hcp-hvn-peering-access"
  scope = module.vnet.vnet_id

  assignable_scopes = [
    module.vnet.vnet_id
  ]

  permissions {
    actions = [
      "Microsoft.Network/virtualNetworks/peer/action",
      "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/read",
      "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/write"
    ]
  }
}

resource "azurerm_role_assignment" "assignment" {
  principal_id       = azuread_service_principal.principal.id
  scope              = module.vnet.vnet_id
  role_definition_id = azurerm_role_definition.definition.role_definition_resource_id
}

# # Create EC2 key pair using public key provided in variable
# resource "aws_key_pair" "boundary_ec2_keys" {
#   key_name   = "boundary-demo-ec2-key"
#   public_key = var.public_key
# }

# # Create VPC for AWS resources
# module "boundary-eks-vpc" {
#   source  = "terraform-aws-modules/vpc/aws"
#   version = "5.5.0"

#   name = "boundary-demo-eks-vpc"

#   cidr = "10.0.0.0/16"
#   azs  = slice(data.aws_availability_zones.available.names, 0, 2)

#   private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]
#   public_subnets  = ["10.0.21.0/24", "10.0.22.0/24"]

#   enable_nat_gateway   = true
#   enable_dns_hostnames = true
# }

### Create peering connection to Vault HVN 
# resource "hcp_aws_network_peering" "vault" {
#   project_id      = data.terraform_remote_state.boundary_demo_init.outputs.hcp_project_id
#   hvn_id          = data.terraform_remote_state.boundary_demo_init.outputs.hvn_id
#   peering_id      = "boundary-demo-cluster"
#   peer_vpc_id     = module.boundary-eks-vpc.vpc_id
#   peer_account_id = module.boundary-eks-vpc.vpc_owner_id
#   peer_vpc_region = data.aws_arn.peer_vpc.region
# }

# resource "aws_vpc_peering_connection_accepter" "peer" {
#   vpc_peering_connection_id = hcp_aws_network_peering.vault.provider_peering_id
#   auto_accept               = true
# }

# resource "time_sleep" "wait_60s" {
#   depends_on = [
#     aws_vpc_peering_connection_accepter.peer
#   ]
#   create_duration = "60s"
# }

# resource "aws_vpc_peering_connection_options" "dns" {
#   depends_on = [
#     time_sleep.wait_60s
#   ]
#   vpc_peering_connection_id = hcp_aws_network_peering.vault.provider_peering_id
#   accepter {
#     allow_remote_vpc_dns_resolution = true
#   }
# }

# resource "hcp_hvn_route" "hcp_vault" {
#   hvn_link         = data.terraform_remote_state.boundary_demo_init.outputs.hvn_self_link
#   hvn_route_id     = "vault-to-internal-clients"
#   destination_cidr = module.boundary-eks-vpc.vpc_cidr_block
#   target_link      = hcp_aws_network_peering.vault.self_link
# }

# resource "aws_route" "vault" {
#   # for_each = toset(module.boundary-vpc.private_route_table_ids)
#   for_each = {
#     for idx, rt_id in module.boundary-eks-vpc.private_route_table_ids : idx => rt_id
#   }
#   route_table_id            = each.value
#   destination_cidr_block    = data.terraform_remote_state.boundary_demo_init.outputs.hvn_cidr
#   vpc_peering_connection_id = hcp_aws_network_peering.vault.provider_peering_id
# }

# resource "aws_iam_instance_profile" "ssm_write_profile" {
#   name = "ssm-write-profile"
#   role = aws_iam_role.ssm_write_role.name
# }

# data "aws_iam_policy_document" "ssm_write_policy" {
#   statement {
#     effect    = "Allow"
#     actions   = ["ssm:PutParameter"]
#     resources = ["*"]
#   }
# }

# resource "aws_iam_policy" "ssm_policy" {
#   name        = "boundary-demo-ssm-policy"
#   description = "Policy used in Boundary demo to write kube info to SSM"
#   policy      = data.aws_iam_policy_document.ssm_write_policy.json
# }

# resource "aws_iam_role" "ssm_write_role" {

#   name = "ssm_write_role"
#   path = "/"

#   assume_role_policy = <<EOF
# {
#     "Version": "2012-10-17",
#     "Statement": [
#         {
#             "Effect": "Allow",
#             "Action": [
#                 "sts:AssumeRole"
#             ],
#             "Principal": {
#                 "Service": [
#                     "ec2.amazonaws.com"
#                 ]
#             }
#         }
#     ]
# }
# EOF
# }

# resource "aws_iam_policy_attachment" "ssm_write_policy" {
#   name       = "boundary-demo-ssm-policy-attachment"
#   roles      = [aws_iam_role.ssm_write_role.name]
#   policy_arn = aws_iam_policy.ssm_policy.arn
# }

# # Create Parameter store entries so that TF can delete them on teardown

# resource "aws_ssm_parameter" "cert" {
#   lifecycle {
#     ignore_changes = [value]
#   }
#   name  = "cert"
#   type  = "String"
#   value = "placeholder"
# }

# resource "aws_ssm_parameter" "token" {
#   lifecycle {
#     ignore_changes = [value]
#   }
#   name  = "token"
#   type  = "String"
#   value = "placeholder"
# }

# # Create bucket for session recording
# resource "random_string" "boundary_bucket_suffix" {
#   length  = 6
#   special = false
#   upper   = false
# }

# resource "aws_s3_bucket" "boundary_recording_bucket" {
#   bucket        = "boundary-recording-bucket-${random_string.boundary_bucket_suffix.result}"
#   force_destroy = true
# }
