.PHONY: build build-julia-memory-safe test test-julia-memory-safe test-dataset150 test-julia-memory-safe-dataset150 test-julia-memory-safe-dataset150-operational-aoi

IMAGE ?= 3dtrees-foreststructure:local
VCS_REF ?= $(shell git rev-parse HEAD 2>/dev/null || printf unknown)
IMAGE_VERSION ?= local
JULIA_MEMORY_SAFE_IMAGE ?= 3dtrees-foreststructure:julia-memory-safe-local

build:
	docker build \
		--build-arg VCS_REF="$(VCS_REF)" \
		--build-arg IMAGE_VERSION="$(IMAGE_VERSION)" \
		--tag "$(IMAGE)" .

build-julia-memory-safe:
	docker build \
		--file Dockerfile.julia-memory-safe \
		--build-arg VCS_REF="$(VCS_REF)" \
		--build-arg IMAGE_VERSION="julia-memory-safe-$(IMAGE_VERSION)" \
		--tag "$(JULIA_MEMORY_SAFE_IMAGE)" .

test:
	bash tests/test_container.sh

test-julia-memory-safe:
	FORESTSTRUCTURE_JULIA_IMAGE="$(JULIA_MEMORY_SAFE_IMAGE)" \
	bash tests/test_julia_memory_safe.sh

test-dataset150:
	bash tests/test_dataset150.sh "$(DATASET150_LAZ)"

test-julia-memory-safe-dataset150:
	FORESTSTRUCTURE_JULIA_IMAGE="$(JULIA_MEMORY_SAFE_IMAGE)" \
	bash tests/test_julia_memory_safe_dataset150.sh \
		"$(DATASET150_LAZ)" \
		"$(DATASET150_GPKG)" \
		"$(JULIA_ORIGINAL_SCRIPT)"

test-julia-memory-safe-dataset150-operational-aoi:
	FORESTSTRUCTURE_JULIA_IMAGE="$(JULIA_MEMORY_SAFE_IMAGE)" \
	bash tests/test_julia_memory_safe_dataset150_operational_aoi.sh \
		"$(DATASET150_LAZ)" \
		"$(DATASET150_OPERATIONAL_AOI)" \
		"$(JULIA_ORIGINAL_SCRIPT)"
