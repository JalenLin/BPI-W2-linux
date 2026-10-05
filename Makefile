# The BPI-W2 (RTD1296) kernel: docs/kernel-build.md
.PHONY: builder kernel-sources kernel dtbs

builder:
	docker build -t bpiw2-kernel/builder:trixie -f docker/builder.Dockerfile docker/

kernel-sources:
	scripts/fetch-kernel.sh

kernel:
	scripts/build-kernel.sh

dtbs:
	TARGETS=dtbs scripts/build-kernel.sh
