plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  # "deep checking" is off. It calls AWS to verify that referenced resources exist,
  # which needs credentials and makes the lint result depend on account state. Lint
  # should be a property of the code alone.
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

# Every variable and output must have a description. Enforced because this
# repository uses descriptions to carry the reasoning, and an undocumented variable
# is where the next wrong assumption gets made.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

# snake_case for names.
rule "terraform_naming_convention" {
  enabled = true
}

# OFF, deliberately.
#
# It wants every module pinned to a version. There are no external modules here yet,
# and turning it on now would only produce noise for local paths.
rule "terraform_module_pinned_source" {
  enabled = false
}
