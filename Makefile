LUAC ?= luac

.PHONY: build check check-generated check-syntax test

build:
	./scripts/build-installer.sh

check: check-generated check-syntax test

check-generated:
	./scripts/build-installer.sh --check

check-syntax:
	bash -n install-hyprland-lid-switch.sh src/install-hyprland-lid-switch.sh.in runtime/lid-state.sh runtime/monitor-state.sh runtime/lid-switch.sh.in runtime/lid-switch-doctor.sh runtime/lid-monitor.sh runtime/lid-resume-monitor.sh runtime/lid-session-bridge.sh scripts/build-installer.sh scripts/check-hyprlock-config.sh scripts/package-release.sh tests/run tests/fakes/effect
	$(LUAC) -p runtime/arch_lidswitch/session.lua

test:
	./tests/run
