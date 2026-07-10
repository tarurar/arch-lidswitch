.PHONY: build check check-generated check-syntax test

build:
	./scripts/build-installer.sh

check: check-generated check-syntax test

check-generated:
	./scripts/build-installer.sh --check

check-syntax:
	bash -n install-hyprland-lid-switch.sh src/install-hyprland-lid-switch.sh.in runtime/lid-switch.sh.in runtime/lid-monitor.sh scripts/build-installer.sh tests/run tests/fakes/effect

test:
	./tests/run
