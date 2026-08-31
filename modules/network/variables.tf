variable "org_prefix" {
  description = "Organisation prefix, e.g. \"eaf\". No default — an organisation-wide fact must be supplied."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,11}$", var.org_prefix))
    error_message = "org_prefix must be 2-12 characters, lowercase alphanumeric, starting with a letter."
  }
}

variable "environment" {
  description = "Environment this network belongs to. Part of every resource name."
  type        = string

  validation {
    condition     = contains(["dev", "test", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, staging, prod."
  }
}

variable "owner" {
  description = "Team or person accountable for this network. Surfaced as a tag."
  type        = string
}

# ── Addressing ────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be large enough to carve az_count public and az_count private subnets at subnet_newbits."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }

  validation {
    # Guarded with can(), and defers to `true` when the CIDR is malformed.
    #
    # Terraform evaluates every validation block. Without the guard, a value like
    # "not-a-cidr" makes split("/", ...)[1] raise "Invalid index" — so a caller
    # passing obvious nonsense gets an error about collection indexing instead of
    # the message telling them it is not a CIDR. A validation that crashes is worse
    # than no validation, because it hides the one that would have been useful.
    #
    # Each block checks exactly one thing and lets the block that owns a failure
    # report it.
    condition     = can(cidrnetmask(var.vpc_cidr)) ? tonumber(split("/", var.vpc_cidr)[1]) <= 20 : true
    error_message = "vpc_cidr must be /20 or larger. EKS pod IPs come from these subnets, so a small VPC becomes a hard pod ceiling."
  }
}

variable "az_count" {
  description = "Number of availability zones to spread across. One public and one private subnet per AZ."
  type        = number
  default     = 2

  validation {
    # EKS requires subnets in at least two different availability zones.
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count must be between 2 and 6. EKS requires subnets in at least two different availability zones."
  }
}

variable "subnet_newbits" {
  description = <<-EOT
    Bits added to the VPC prefix to size each subnet. With a /16 VPC:
      4  -> /20 subnets, 4,091 usable addresses each   (default, recommended)
      8  -> /24 subnets,   251 usable addresses each

    Why the default is generous. Pod IP addresses come from these subnets, and with
    prefix delegation enabled the VPC CNI reserves /28 blocks per node. A node at
    the full 110-pod cap can hold around 112 addresses, so three such nodes want
    ~336 addresses — more than a /24 provides. The planned workload is far below
    that density, but a /20 removes the interaction entirely and costs nothing: a
    /16 yields 16 /20s and only four are used at az_count = 2.
  EOT
  type        = number
  default     = 4

  validation {
    condition     = var.subnet_newbits >= 2 && var.subnet_newbits <= 12
    error_message = "subnet_newbits must be between 2 and 12."
  }

  # The next two checks live HERE rather than as lifecycle preconditions on the VPC,
  # and the reason is ordering. `locals` calls cidrsubnet() to compute the subnet
  # CIDRs, and Terraform evaluates locals before resource preconditions. So an
  # impossible plan fails inside cidrsubnet with "prefix extension of 2 does not
  # accommodate a subnet numbered 10" — accurate, but it points at a local
  # expression instead of at the input that was wrong.
  #
  # Variable validation runs before locals, so the caller gets told which input to
  # change. Both reference other variables, which needs Terraform >= 1.9.

  validation {
    condition = (
      can(cidrnetmask(var.vpc_cidr))
      ? pow(2, var.subnet_newbits) >= var.az_count * 2
      : true
    )
    error_message = "subnet_newbits is too small for az_count: the VPC cannot be divided into az_count public plus az_count private subnets. Increase subnet_newbits."
  }

  validation {
    condition = (
      can(cidrnetmask(var.vpc_cidr))
      ? pow(2, 32 - tonumber(split("/", var.vpc_cidr)[1]) - var.subnet_newbits) >= 32
      : true
    )
    error_message = "subnet_newbits is too large: subnets would be smaller than /27. AWS reserves 5 addresses per subnet and EKS requires at least 6 free, recommending 16."
  }
}

# ── NAT ───────────────────────────────────────────────────────────────────────

variable "single_nat_gateway" {
  description = <<-EOT
    true  — one NAT gateway shared by every private subnet. Cheaper, and a single
            availability-zone failure removes outbound internet for all nodes.
    false — one NAT gateway per AZ. Resilient, and multiplies the hourly cost by
            az_count.

    Defaults to true because dev is disposable. Prod should pass false.
  EOT
  type        = bool
  default     = true
}

# ── Tagging ───────────────────────────────────────────────────────────────────

variable "extra_tags" {
  description = "Additional tags applied to every resource. The mandatory set cannot be overridden."
  type        = map(string)
  default     = {}
}
