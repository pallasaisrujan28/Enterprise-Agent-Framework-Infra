# Unit tests for modules/network.
#
# command = plan throughout. No credentials, no resources, a few seconds.
# Verified to pass with AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# AWS_SESSION_TOKEN, AWS_PROFILE and AWS_DEFAULT_REGION all unset.
#
# data.aws_availability_zones is mocked, so the tests do not depend on which zones
# a particular region happens to expose today.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
    }
  }

  # Subnet ids are computed at apply time, so a plan-only assertion comparing a NAT
  # gateway's subnet_id against a subnet's id has two unknowns and cannot evaluate.
  # Overriding the ids makes the relationship checkable without an apply.
  override_resource {
    target          = aws_subnet.public[0]
    override_during = plan
    values          = { id = "subnet-public-0" }
  }

  override_resource {
    target          = aws_subnet.private[0]
    override_during = plan
    values          = { id = "subnet-private-0" }
  }
}

variables {
  org_prefix  = "eaf"
  environment = "dev"
  owner       = "platform-team"
}

# ── Addressing ────────────────────────────────────────────────────────────────

run "default_carves_slash20_subnets" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == "10.0.0.0/16"
    error_message = "unexpected VPC CIDR"
  }

  # /16 + 4 newbits = /20. Public takes blocks 0..az_count-1, private the next.
  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.0.0.0/20"
    error_message = "public[0] should be 10.0.0.0/20, got ${aws_subnet.public[0].cidr_block}"
  }

  assert {
    condition     = aws_subnet.public[1].cidr_block == "10.0.16.0/20"
    error_message = "public[1] should be 10.0.16.0/20, got ${aws_subnet.public[1].cidr_block}"
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.0.32.0/20"
    error_message = "private[0] should be 10.0.32.0/20, got ${aws_subnet.private[0].cidr_block}"
  }

  assert {
    condition     = aws_subnet.private[1].cidr_block == "10.0.48.0/20"
    error_message = "private[1] should be 10.0.48.0/20, got ${aws_subnet.private[1].cidr_block}"
  }
}

run "public_and_private_ranges_do_not_overlap" {
  command = plan

  variables {
    az_count = 3
  }

  # cidrsubnet indices 0,1,2 for public and 3,4,5 for private cannot overlap by
  # construction. Asserted anyway, because an off-by-one in the offset would be
  # silent and catastrophic.
  assert {
    condition = length(setintersection(
      toset([for s in aws_subnet.public : s.cidr_block]),
      toset([for s in aws_subnet.private : s.cidr_block])
    )) == 0
    error_message = "public and private subnet CIDRs overlap"
  }

  assert {
    condition     = length(aws_subnet.public) == 3 && length(aws_subnet.private) == 3
    error_message = "az_count = 3 should produce 3 public and 3 private subnets"
  }
}

run "subnet_newbits_8_gives_slash24" {
  command = plan

  variables {
    subnet_newbits = 8
  }

  assert {
    condition     = aws_subnet.private[0].cidr_block == "10.0.2.0/24"
    error_message = "with subnet_newbits = 8 private[0] should be 10.0.2.0/24, got ${aws_subnet.private[0].cidr_block}"
  }
}

# ── EKS requirements that are not optional ───────────────────────────────────

run "dns_support_is_always_on" {
  command = plan

  # AWS: without DNS hostname and DNS resolution support, nodes cannot register
  # with the cluster. Not configurable, so assert it cannot be turned off.
  assert {
    condition     = aws_vpc.this.enable_dns_support == true
    error_message = "enable_dns_support must be true or nodes cannot register"
  }

  assert {
    condition     = aws_vpc.this.enable_dns_hostnames == true
    error_message = "enable_dns_hostnames must be true or nodes cannot register"
  }
}

run "load_balancer_discovery_tags_are_present" {
  command = plan

  assert {
    condition     = aws_subnet.public[0].tags["kubernetes.io/role/elb"] == "1"
    error_message = "public subnets need kubernetes.io/role/elb = 1 or the load balancer controller cannot discover them"
  }

  assert {
    condition     = aws_subnet.private[0].tags["kubernetes.io/role/internal-elb"] == "1"
    error_message = "private subnets need kubernetes.io/role/internal-elb = 1 for internal load balancers"
  }
}

run "public_subnets_auto_assign_public_ips" {
  command = plan

  assert {
    condition     = aws_subnet.public[0].map_public_ip_on_launch == true
    error_message = "AWS requires auto-assign public IPv4 on public subnets used by managed node groups"
  }

  assert {
    condition     = aws_subnet.private[0].map_public_ip_on_launch != true
    error_message = "private subnets must not auto-assign public IPs"
  }
}

run "obsolete_vpc_cluster_tag_is_not_set" {
  command = plan

  # The previous configuration set kubernetes.io/cluster/<name> = "shared" on the
  # VPC, believing EKS needed it for subnet discovery. AWS states it applied only
  # to Kubernetes 1.14 and earlier and is unused from 1.15. Subnet discovery uses
  # the role tags on the subnets.
  assert {
    condition = length([
      for k, _ in aws_vpc.this.tags : k if startswith(k, "kubernetes.io/cluster/")
    ]) == 0
    error_message = "the VPC should carry no kubernetes.io/cluster/* tag — it is obsolete from Kubernetes 1.15"
  }
}

# ── Tagging ───────────────────────────────────────────────────────────────────

run "mandatory_tags_cannot_be_overridden" {
  command = plan

  variables {
    extra_tags = { ManagedBy = "definitely-not-terraform", CostCentre = "CC-1001" }
  }

  assert {
    condition     = aws_vpc.this.tags["ManagedBy"] == "terraform"
    error_message = "extra_tags overrode a mandatory tag"
  }

  assert {
    condition     = aws_vpc.this.tags["CostCentre"] == "CC-1001"
    error_message = "extra_tags should still be merged for non-mandatory keys"
  }

  assert {
    condition     = aws_vpc.this.tags["Name"] == "eaf-dev-vpc"
    error_message = "name should be generated as org_prefix-environment-vpc, got ${aws_vpc.this.tags["Name"]}"
  }
}

# ── NAT topology ─────────────────────────────────────────────────────────────

run "single_nat_by_default_shared_by_all_private_subnets" {
  command = plan

  variables {
    az_count = 3
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "single_nat_gateway defaults to true, so exactly one NAT gateway"
  }

  assert {
    condition     = length(aws_eip.nat) == 1
    error_message = "one Elastic IP per NAT gateway"
  }

  # One route table per private subnet even when sharing a NAT, so flipping
  # single_nat_gateway later changes routes rather than restructuring tables.
  assert {
    condition     = length(aws_route_table.private) == 3
    error_message = "one private route table per AZ regardless of NAT count"
  }
}

run "nat_per_az_when_requested" {
  command = plan

  variables {
    az_count           = 3
    single_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3
    error_message = "single_nat_gateway = false should give one NAT per AZ"
  }

  assert {
    condition     = length(aws_eip.nat) == 3
    error_message = "one Elastic IP per NAT gateway"
  }
}

run "nat_gateways_live_in_public_subnets" {
  command = plan

  # A NAT gateway in a private subnet has no path to the internet. The failure is
  # not a validation error — it is traffic silently going nowhere.
  assert {
    condition     = aws_nat_gateway.this[0].subnet_id == aws_subnet.public[0].id
    error_message = "NAT gateway must be in a public subnet"
  }
}

# ── Rejections ───────────────────────────────────────────────────────────────

run "reject_single_az" {
  command = plan

  variables {
    az_count = 1
  }

  # EKS requires subnets in at least two different availability zones.
  expect_failures = [var.az_count]
}

run "reject_vpc_cidr_too_small" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/24"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_malformed_cidr" {
  command = plan

  variables {
    vpc_cidr = "not-a-cidr"
  }

  expect_failures = [var.vpc_cidr]
}

run "reject_subnet_plan_that_cannot_fit" {
  command = plan

  variables {
    az_count       = 3
    subnet_newbits = 2 # 4 blocks available, but 6 subnets needed
  }

  # Caught on the variable, not by a resource precondition — locals call
  # cidrsubnet() and are evaluated first, so a precondition would never be reached.
  expect_failures = [var.subnet_newbits]
}

run "reject_more_azs_than_the_region_has" {
  command = plan

  variables {
    az_count = 4 # the mock exposes three
  }

  # This one CAN only be a resource precondition: it depends on a data source, so
  # the answer is not knowable from the inputs alone.
  expect_failures = [aws_vpc.this]
}

run "reject_subnets_smaller_than_slash27" {
  command = plan

  variables {
    subnet_newbits = 12 # /16 + 12 = /28, only 11 usable after AWS reserves 5
  }

  expect_failures = [var.subnet_newbits]
}

run "reject_bad_org_prefix" {
  command = plan

  variables {
    org_prefix = "EAF_Platform"
  }

  expect_failures = [var.org_prefix]
}

run "reject_unknown_environment" {
  command = plan

  variables {
    environment = "sandbox"
  }

  expect_failures = [var.environment]
}

# ── Inventory ────────────────────────────────────────────────────────────────

run "inventory_reports_the_real_pod_ip_budget" {
  command = plan

  # /20 = 4096 addresses, minus the 5 AWS reserves.
  assert {
    condition     = output.inventory.usable_ips_per_subnet == 4091
    error_message = "expected 4091 usable addresses in a /20, got ${output.inventory.usable_ips_per_subnet}"
  }

  assert {
    condition     = length(output.inventory.private_subnets) == 2
    error_message = "inventory should list both private subnets"
  }
}
