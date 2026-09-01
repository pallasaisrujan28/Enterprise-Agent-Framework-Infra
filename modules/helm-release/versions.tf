# Reusable module: minimums only. The choice of major belongs to the root module.
#
# The floor is 3.0.0 rather than 2.x deliberately. The v3 provider moved from Plugin SDKv2
# to the Plugin Framework, which changed `set`, `set_sensitive` and `postrender` from nested
# BLOCKS into typed ATTRIBUTES. A module written against v2 syntax fails to even parse under
# v3, so a floor that admits both majors would be a floor that guarantees nothing.
#
# This module sidesteps that break entirely by never using `set` — values go in as one YAML
# document. See the note in main.tf.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0"
    }
  }
}
