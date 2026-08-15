.PHONY: build test test-dataset150

IMAGE ?= 3dtrees-foreststructure:local
VCS_REF ?= $(shell git rev-parse HEAD 2>/dev/null || printf unknown)
IMAGE_VERSION ?= local

build:
	docker build \
		--build-arg VCS_REF="$(VCS_REF)" \
		--build-arg IMAGE_VERSION="$(IMAGE_VERSION)" \
		--tag "$(IMAGE)" .

test:
	bash tests/test_container.sh

test-dataset150:
	bash tests/test_dataset150.sh "$(DATASET150_LAZ)"
