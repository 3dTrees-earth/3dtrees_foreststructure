.PHONY: build test

build:
	docker build --tag 3dtrees-foreststructure:local .

test:
	bash tests/test_container.sh

