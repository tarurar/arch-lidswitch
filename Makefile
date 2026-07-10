.PHONY: build check check-generated check-syntax

build:
	./scripts/build-installer.sh

check: check-generated check-syntax

check-generated:
	./scripts/build-installer.sh --check

check-syntax:
	bash -n install-hyprland-lid-switch.sh runtime/lid-switch.sh.in runtime/lid-monitor.sh scripts/build-installer.sh
