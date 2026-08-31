.PHONY: build build-julia-memory-safe test test-julia-memory-safe test-copc-all-instance-dimensions test-dataset150 test-julia-memory-safe-dataset150 test-julia-memory-safe-dataset150-operational-aoi build-original-order-copc test-valid-updated-copc-alignment test-valid-updated-cohort test-valid-updated-oracle-cohort

IMAGE ?= 3dtrees-foreststructure:local
VCS_REF ?= $(shell git rev-parse HEAD 2>/dev/null || printf unknown)
IMAGE_VERSION ?= local
JULIA_MEMORY_SAFE_IMAGE ?= 3dtrees-foreststructure:julia-memory-safe-local
JULIA_ORIGINAL_SCRIPT ?= reference/Indices_Final_run.R

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

test-copc-all-instance-dimensions:
	FORESTSTRUCTURE_JULIA_IMAGE="$(JULIA_MEMORY_SAFE_IMAGE)" \
	bash tests/test_copc_all_instance_dimensions.sh

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

test-valid-updated-copc-alignment:
	FORESTSTRUCTURE_JULIA_IMAGE="$(JULIA_MEMORY_SAFE_IMAGE)" \
	bash tests/test_valid_updated_copc_alignment.sh \
		"$(DATASET_ID)" \
		"$(COPC_LAZ)" \
		"$(AOI_GEOJSON)" \
		"$(VALID_UPDATED_DIR)" \
		"$(INSTANCE_DIMENSION)" \
		"$(ORIGINAL_LAZ)"

build-original-order-copc:
	FORESTSTRUCTURE_JULIA_IMAGE="$(JULIA_MEMORY_SAFE_IMAGE)" \
	bash tests/build_original_order_copc.sh \
		"$(ORIGINAL_LAZ)" \
		"$(COPC_LAZ)"

test-valid-updated-cohort:
	FORESTSTRUCTURE_JULIA_IMAGE="$(JULIA_MEMORY_SAFE_IMAGE)" \
	bash tests/test_valid_updated_cohort.sh \
		"$(or $(COHORT_MANIFEST),tests/fixtures/valid_updated_cohort15.tsv)"

test-valid-updated-oracle-cohort:
	FORESTSTRUCTURE_JULIA_IMAGE="$(JULIA_MEMORY_SAFE_IMAGE)" \
	bash tests/test_valid_updated_oracle_cohort.sh \
		"$(or $(COHORT_MANIFEST),tests/fixtures/valid_updated_cohort20_new.tsv)"
