# Container registries. Kubernetes pulls images from here.
#
# An image that is absent produces ImagePullBackOff, which reads as a broken deployment
# rather than an empty registry — so these exist before anything references them, and they
# keep existing after the cluster is gone.
#
# ALL THREE ARE IMMUTABLE, which fixes a defect this repository already had. The previous
# eaf/agent was IMMUTABLE while its build workflow pushed both :$${sha} and :latest on every
# run: an immutable repository refuses to move an existing tag, so the first push succeeded
# and every one after it failed. The tools/* repositories had the mirror-image problem —
# MUTABLE with :latest, so nothing recorded which image was running.
#
# The resolution is not a middle setting. Nothing deploys :latest; every reference is a
# commit SHA or a digest. That is Property 5, and IMMUTABLE enforces it rather than
# documenting it.

module "ecr" {
  source   = "../../../modules/ecr-repository"
  for_each = toset(var.repositories)

  name = each.key

  org_prefix  = var.org_prefix
  environment = var.environment
  owner       = var.owner

  # False, unlike the platform layer's earlier setting. A destroy that refuses to proceed
  # while images are present is the guard working, not an obstacle: this layer exists so
  # the images survive.
  force_delete = var.force_delete

  # Basic scanning — free, per-repository, and it happens at push time, which is the only
  # moment a scan reliably runs. Enhanced scanning through Inspector is a registry-wide
  # account setting and not this layer's business.
  scan_on_push = true

  # Both rules matter on an immutable repository. The untagged rule alone would rarely
  # fire, because an immutable tag is never orphaned by a re-push; the count rule alone
  # leaves no bound, because every build adds a tag that is never replaced.
  untagged_image_expiry_days = var.untagged_image_expiry_days
  max_tagged_images          = var.max_tagged_images

  # No expirable_tag_prefixes: every image in a dev registry is disposable, so the count
  # applies to all of them.
}
