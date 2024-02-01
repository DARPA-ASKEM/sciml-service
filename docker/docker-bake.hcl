variable "DOCKER_REGISTRY" {
  default = "ghcr.io"
}
variable "DOCKER_ORG" {
  default = "darpa-askem"
}
variable "VERSION" {
  default = "local"
}

# ----------------------------------------------------------------------------------------------------------------------

function "tag" {
  params = [image_name, prefix, suffix]
  result = [ "${DOCKER_REGISTRY}/${DOCKER_ORG}/${image_name}:${check_prefix(prefix)}${VERSION}${check_suffix(suffix)}" ]
}

function "check_prefix" {
  params = [tag]
  result = notequal("",tag) ? "${tag}-": ""
}

function "check_suffix" {
  params = [tag]
  result = notequal("",tag) ? "-${tag}": ""
}

# ----------------------------------------------------------------------------------------------------------------------

group "prod" {
  targets = ["sciml-service"]
}

group "default" {
  targets = ["sciml-service-base"]
}

# ----------------------------------------------------------------------------------------------------------------------

target "_platforms" {
  platforms = ["linux/amd64", "linux/arm64"]
}

target "sciml-service-base" {
	context = "."
	tags = tag("sciml-service", "", "")
	dockerfile = "docker/Dockerfile.api"
}

target "sciml-service" {
  inherits = ["_platforms", "sciml-service-base"]
}